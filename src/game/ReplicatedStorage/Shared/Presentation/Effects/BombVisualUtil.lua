local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)

local BombVisualUtil = {}

local ROOT_PART_NAME = "BombVisualRoot"
local VISUAL_WELD_NAME = "BombVisualWeld"
local ATTACHMENT_NAMES = table.freeze({
	VFX = "VFX",
	FuseSpark = "FuseSpark",
	Trail = "Trail",
})

local warnedMissingAttachments = {}

local function getAssetsBombsFolder(): Folder?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local bombs = assets and assets:FindFirstChild("Bombs")
	return if bombs and bombs:IsA("Folder") then bombs else nil
end

local function getFirstBasePart(instance: Instance?): BasePart?
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function getBaseParts(instance: Instance): { BasePart }
	local parts = {}
	if instance:IsA("BasePart") then
		table.insert(parts, instance)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function getSkinFolder(skinId: any): Instance?
	local definition = BombSkinConfig.GetDefinition(skinId)
	local bombs = getAssetsBombsFolder()
	if not (definition and bombs) then
		return nil
	end

	return bombs:FindFirstChild(definition.assetFolder)
end

local function getSkinTemplate(skinId: any): Instance?
	local definition = BombSkinConfig.GetDefinition(skinId)
	local folder = getSkinFolder(skinId)
	if not (definition and folder) then
		return nil
	end

	local named = folder:FindFirstChild(definition.assetFolder)
		or folder:FindFirstChild(definition.displayName)
		or folder:FindFirstChild(definition.id)
	if named and (named:IsA("BasePart") or named:IsA("Model")) then
		return named
	end

	for _, child in ipairs(folder:GetChildren()) do
		if child.Name == "Explosion" then
			continue
		end
		if child:IsA("BasePart") or child:IsA("Model") then
			return child
		end
	end

	return nil
end

local function createFallbackVisual(): BasePart
	local part = Instance.new("Part")
	part.Name = BombConfig.RuntimeBombName
	part.Shape = Enum.PartType.Ball
	part.Size = BombConfig.RuntimeBombSize
	part.Material = Enum.Material.Metal
	part.Color = Color3.fromRGB(35, 35, 38)
	return part
end

local function createRootPart(options): Part
	local root = Instance.new("Part")
	root.Name = ROOT_PART_NAME
	root.Shape = Enum.PartType.Ball
	local diameter = math.max((BombConfig.SweepRadius or 1.88) * 2, 0.2)
	root.Size = Vector3.new(diameter, diameter, diameter)
	root.Transparency = if typeof(options) == "table" and options.rootVisible == true then 0.95 else 1
	root.Material = Enum.Material.SmoothPlastic
	root.Color = Color3.fromRGB(35, 35, 38)
	root.Anchored = typeof(options) == "table" and options.anchored == true
	root.CanCollide = typeof(options) == "table" and options.canCollide == true
	root.CanQuery = typeof(options) == "table" and options.canQuery == true
	root.CanTouch = false
	root.CastShadow = false
	root.Massless = typeof(options) == "table" and options.massless == true
	return root
end

local function prepareVisualParts(visual: Instance, rootPart: BasePart)
	for _, part in ipairs(getBaseParts(visual)) do
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true

		local weld = Instance.new("WeldConstraint")
		weld.Name = VISUAL_WELD_NAME
		weld.Part0 = rootPart
		weld.Part1 = part
		weld.Parent = rootPart
	end
end

local function scaleVisual(visual: Instance, rootPart: BasePart, scale: number)
	if math.abs(scale - 1) < 0.001 then
		return
	end

	for _, part in ipairs(getBaseParts(visual)) do
		local relativeCFrame = rootPart.CFrame:ToObjectSpace(part.CFrame)
		local relativeRotation = relativeCFrame - relativeCFrame.Position
		part.Size = part.Size * scale
		part.CFrame = rootPart.CFrame * CFrame.new(relativeCFrame.Position * scale) * relativeRotation
	end

	for _, descendant in ipairs(visual:GetDescendants()) do
		if descendant:IsA("Attachment") then
			descendant.Position = descendant.Position * scale
		end
	end
end

local function setEffectDescendantEnabled(descendant: Instance, enabled: boolean)
	if descendant:IsA("ParticleEmitter")
		or descendant:IsA("Beam")
		or descendant:IsA("Trail")
		or descendant:IsA("PointLight")
		or descendant:IsA("SpotLight")
		or descendant:IsA("SurfaceLight")
	then
		descendant.Enabled = enabled
	end
end

local function setAttachmentEffects(root: Instance, attachmentName: string, enabled: boolean): boolean
	local found = false
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Attachment") and descendant.Name == attachmentName then
			found = true
			for _, effect in ipairs(descendant:GetDescendants()) do
				setEffectDescendantEnabled(effect, enabled)
			end
		end
	end
	return found
end

local function warnMissingAttachment(skinId: string, attachmentName: string)
	local key = skinId .. ":" .. attachmentName
	if warnedMissingAttachments[key] then
		return
	end
	warnedMissingAttachments[key] = true
	warn(("[BombVisualUtil] Bomb skin %s is missing %s attachment"):format(skinId, attachmentName))
end

function BombVisualUtil.SetEffectState(instance: Instance?, state)
	if not instance then
		return
	end

	local skinId = BombSkinConfig.NormalizeSkinId(instance:GetAttribute("BombSkinId"))
	if skinId == "" then
		skinId = BombSkinConfig.DefaultSkinId
	end

	local vfxFound = setAttachmentEffects(instance, ATTACHMENT_NAMES.VFX, state and state.vfx == true)
	local fuseFound = setAttachmentEffects(instance, ATTACHMENT_NAMES.FuseSpark, state and state.fuseSpark == true)
	local trailFound = setAttachmentEffects(instance, ATTACHMENT_NAMES.Trail, state and state.trail == true)

	if not vfxFound then
		warnMissingAttachment(skinId, ATTACHMENT_NAMES.VFX)
	end
	if not fuseFound then
		warnMissingAttachment(skinId, ATTACHMENT_NAMES.FuseSpark)
	end
	if not trailFound then
		warnMissingAttachment(skinId, ATTACHMENT_NAMES.Trail)
	end
end

function BombVisualUtil.CreateBombVisual(skinId: any, name: string?, options): (Model, BasePart, string)
	local resolvedSkinId = BombSkinConfig.NormalizeSkinId(skinId)
	if resolvedSkinId == "" then
		resolvedSkinId = BombSkinConfig.DefaultSkinId
	end

	local model = Instance.new("Model")
	model.Name = name or BombConfig.RuntimeBombName
	model:SetAttribute("BombSkinId", resolvedSkinId)

	local rootPart = createRootPart(options)
	rootPart:SetAttribute("BombSkinId", resolvedSkinId)
	rootPart.Parent = model
	model.PrimaryPart = rootPart

	local template = getSkinTemplate(resolvedSkinId)
	local visual = if template then template:Clone() else createFallbackVisual()
	visual.Name = "BombSkinVisual"
	visual:SetAttribute("BombSkinId", resolvedSkinId)

	local visualScale = if typeof(options) == "table" and typeof(options.visualScale) == "number"
		then math.max(options.visualScale, 0.05)
		else 1

	if visual:IsA("Model") then
		visual:PivotTo(rootPart.CFrame)
	elseif visual:IsA("BasePart") then
		visual.CFrame = rootPart.CFrame
	end
	scaleVisual(visual, rootPart, visualScale)
	visual.Parent = model
	prepareVisualParts(visual, rootPart)

	local effectState = if typeof(options) == "table" and typeof(options.effectState) == "table"
		then options.effectState
		else {
			vfx = true,
			fuseSpark = false,
			trail = false,
		}
	BombVisualUtil.SetEffectState(model, effectState)

	return model, rootPart, resolvedSkinId
end

function BombVisualUtil.GetRootPart(instance: Instance?): BasePart?
	local root = instance and instance:FindFirstChild(ROOT_PART_NAME, true)
	if root and root:IsA("BasePart") then
		return root
	end
	return getFirstBasePart(instance)
end

return table.freeze(BombVisualUtil)
