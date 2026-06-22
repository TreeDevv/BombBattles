local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InstanceUtil = require(ReplicatedStorage.Shared.Common.InstanceUtil)

local AbilityVisualOverlay = {}

local DEFAULT_OVERLAY_NAME = "AbilityVisualOverlay"
local replacementTransparencyByPart = setmetatable({}, { __mode = "k" }) :: { [BasePart]: number }
local warnedMissingTemplates = {} :: { [string]: boolean }

local function getFirstBasePart(instance: Instance?): BasePart?
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function isDescendantOfNamedAttachment(instance: Instance, attachmentName: any): boolean
	if typeof(attachmentName) ~= "string" or attachmentName == "" then
		return false
	end

	local current = instance.Parent
	while current do
		if current:IsA("Attachment") and current.Name == attachmentName then
			return true
		end
		current = current.Parent
	end
	return false
end

local function isSelfOrDescendantOfInstance(instance: Instance, ancestor: Instance?): boolean
	return ancestor ~= nil and (instance == ancestor or instance:IsDescendantOf(ancestor))
end

local function setOverlayEffectsEnabled(instance: Instance, enabled: boolean, disabledAttachmentName: any?)
	for _, descendant in ipairs(instance:GetDescendants()) do
		local descendantEnabled = enabled and not isDescendantOfNamedAttachment(descendant, disabledAttachmentName)
		if descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Beam")
			or descendant:IsA("PointLight")
			or descendant:IsA("SpotLight")
			or descendant:IsA("SurfaceLight")
		then
			descendant.Enabled = descendantEnabled
		elseif descendant:IsA("Sound") and descendantEnabled then
			descendant:Play()
		end
	end
end

local function pivotOverlayToRoot(overlay: Instance, overlayRoot: BasePart, rootPart: BasePart)
	local targetCFrame = rootPart.CFrame
	if overlay:IsA("Model") then
		overlay:PivotTo(targetCFrame)
		return
	end

	local sourceCFrame = overlayRoot.CFrame
	for _, part in ipairs(InstanceUtil.GetBaseParts(overlay)) do
		local relativeCFrame = sourceCFrame:ToObjectSpace(part.CFrame)
		part.CFrame = targetCFrame * relativeCFrame
	end
end

local function setVisualLocalTransparency(instance: Instance?, alpha: number)
	if not instance then
		return
	end

	alpha = math.clamp(alpha, 0, 1)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = alpha
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = alpha
		end
	end
end

local function setReplacementPartHidden(part: BasePart, hidden: boolean)
	if hidden then
		if replacementTransparencyByPart[part] == nil then
			replacementTransparencyByPart[part] = part.Transparency
		end
		part.LocalTransparencyModifier = 1
		part.Transparency = 1
		return
	end

	local originalTransparency = replacementTransparencyByPart[part]
	if originalTransparency ~= nil then
		part.Transparency = originalTransparency
		replacementTransparencyByPart[part] = nil
	end
	part.LocalTransparencyModifier = 0
end

local function setVisualReplacementHiddenExcept(instance: Instance?, hidden: boolean, excluded: Instance?)
	if not instance then
		return
	end

	if instance:IsA("BasePart") and not isSelfOrDescendantOfInstance(instance, excluded) then
		setReplacementPartHidden(instance, hidden)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and not isSelfOrDescendantOfInstance(descendant, excluded) then
			setReplacementPartHidden(descendant, hidden)
		end
	end
end

local function setVisualEffectsEnabledExcept(instance: Instance?, enabled: boolean, excluded: Instance?)
	if not instance then
		return
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if isSelfOrDescendantOfInstance(descendant, excluded) then
			continue
		end

		if descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Beam")
			or descendant:IsA("PointLight")
			or descendant:IsA("SpotLight")
			or descendant:IsA("SurfaceLight")
		then
			descendant.Enabled = enabled
		elseif descendant:IsA("Sound") and not enabled then
			descendant:Stop()
		end
	end
end

local function getTemplateKey(assetPath: any): string
	return if typeof(assetPath) == "table" then table.concat(assetPath, ".") else "unknown"
end

function AbilityVisualOverlay.PrepareHeldVisual(instance: Instance, rootPart: BasePart, weldName: string)
	for _, part in ipairs(InstanceUtil.GetBaseParts(instance)) do
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true

		if part ~= rootPart then
			local weld = Instance.new("WeldConstraint")
			weld.Name = weldName
			weld.Part0 = rootPart
			weld.Part1 = part
			weld.Parent = rootPart
		end
	end
end

function AbilityVisualOverlay.Destroy(visual)
	if visual and visual.abilityVisualOverlay then
		if visual.abilityVisualOverlay.Parent then
			visual.abilityVisualOverlay:Destroy()
		end
		visual.abilityVisualOverlay = nil
	end
end

function AbilityVisualOverlay.Apply(
	visual,
	assetPath: any,
	overlayName: string?,
	disabledAttachmentName: any?
)
	if not (visual and visual.instance and visual.rootPart and visual.rootPart.Parent) then
		return
	end
	if visual.abilityVisualOverlay and visual.abilityVisualOverlay.Parent then
		if visual.abilityVisualOverlay:IsDescendantOf(visual.instance) then
			return
		end
		AbilityVisualOverlay.Destroy(visual)
	end
	if visual.abilityVisualOverlay and visual.abilityVisualOverlay.Parent then
		return
	end

	local template = if typeof(assetPath) == "table" then InstanceUtil.GetByPath(ReplicatedStorage, assetPath) else nil
	if not template then
		local key = getTemplateKey(assetPath)
		if not warnedMissingTemplates[key] then
			warnedMissingTemplates[key] = true
			warn(("[AbilityVisualOverlay] Missing ability visual template: ReplicatedStorage.%s"):format(key))
		end
		return
	end

	local overlay = template:Clone()
	overlay.Name = if typeof(overlayName) == "string" and overlayName ~= "" then overlayName else DEFAULT_OVERLAY_NAME
	local overlayRoot = getFirstBasePart(overlay)
	if not overlayRoot then
		overlay:Destroy()
		return
	end

	pivotOverlayToRoot(overlay, overlayRoot, visual.rootPart)
	for _, part in ipairs(InstanceUtil.GetBaseParts(overlay)) do
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true

		local weld = Instance.new("WeldConstraint")
		weld.Name = DEFAULT_OVERLAY_NAME .. "Weld"
		weld.Part0 = visual.rootPart
		weld.Part1 = part
		weld.Parent = visual.rootPart
	end

	setOverlayEffectsEnabled(overlay, true, disabledAttachmentName)
	overlay.Parent = visual.instance
	visual.abilityVisualOverlay = overlay
end

function AbilityVisualOverlay.SyncFromVisuals(visual)
	local visuals = visual and visual.visuals
	if typeof(visuals) == "table" and visuals.freezeBomb == true then
		AbilityVisualOverlay.Apply(visual, visuals.freezeAssetPath, "FreezeBombVFX")
	elseif typeof(visuals) == "table" and visuals.abilityVisualOverlay == true then
		AbilityVisualOverlay.Apply(
			visual,
			visuals.abilityVisualAssetPath,
			visuals.abilityVisualName,
			visuals.abilityVisualDisabledAttachmentName
		)
	else
		AbilityVisualOverlay.Destroy(visual)
	end
end

function AbilityVisualOverlay.SyncBaseVisual(visual, hideBase: boolean)
	local overlay = if visual then visual.abilityVisualOverlay else nil
	if hideBase then
		if overlay and overlay.Parent and visual then
			setVisualReplacementHiddenExcept(visual.instance, true, overlay)
			setVisualEffectsEnabledExcept(visual.instance, false, overlay)
		elseif visual then
			setVisualReplacementHiddenExcept(visual.instance, true, nil)
			setVisualEffectsEnabledExcept(visual.instance, false, nil)
		end
	else
		setVisualReplacementHiddenExcept(visual and visual.instance or nil, false, nil)
		setVisualLocalTransparency(visual and visual.instance or nil, 0)
	end
	if visual and visual.highlight then
		visual.highlight.Enabled = not hideBase
	end
end

return table.freeze(AbilityVisualOverlay)
