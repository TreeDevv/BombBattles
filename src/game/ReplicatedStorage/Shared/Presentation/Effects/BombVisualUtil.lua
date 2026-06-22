local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local InstanceUtil = require(ReplicatedStorage.Shared.Common.InstanceUtil)

local BombVisualUtil = {}

local ROOT_PART_NAME = "BombVisualRoot"
local VISUAL_WELD_NAME = "BombVisualWeld"
local ATTACHMENT_NAMES = table.freeze({
	VFX = "VFX",
	FuseSpark = "FuseSpark",
	Trail = "Trail",
})
local DEFAULT_EXPLOSION_VFX_PATH = table.freeze({ "Assets", "VFX", "Explosion", "Default" })
local DEFAULT_EXPLOSION_CLEANUP_SECONDS = 8
local EXPLOSION_VISUAL_POSITION_OFFSET = Vector3.new(0, -1, 0)

local warnedMissingAttachments = {}

local getBaseParts = InstanceUtil.GetBaseParts

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
		if child.Name == "Explosion" or child.Name == "Beam" then
			continue
		end
		if child:IsA("BasePart") or child:IsA("Model") then
			return child
		end
	end

	return nil
end

local function getDefaultExplosionTemplate(): Instance?
	return InstanceUtil.GetByPath(ReplicatedStorage, DEFAULT_EXPLOSION_VFX_PATH)
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

local function scaleNumberSequence(sequence: NumberSequence, scale: number): NumberSequence
	local keypoints = {}
	for _, keypoint in ipairs(sequence.Keypoints) do
		table.insert(keypoints, NumberSequenceKeypoint.new(
			keypoint.Time,
			keypoint.Value * scale,
			keypoint.Envelope * scale
		))
	end
	return NumberSequence.new(keypoints)
end

local function getEffectPivot(instance: Instance): CFrame?
	if instance:IsA("Model") then
		return instance:GetPivot()
	elseif instance:IsA("BasePart") then
		return instance.CFrame
	end

	local firstPart = getFirstBasePart(instance)
	return if firstPart then firstPart.CFrame else nil
end

local function scaleEffectInstance(instance: Instance, scale: number)
	if math.abs(scale - 1) < 0.001 then
		return
	end

	local pivot = getEffectPivot(instance)
	if not pivot then
		return
	end

	for _, part in ipairs(getBaseParts(instance)) do
		local relativeCFrame = pivot:ToObjectSpace(part.CFrame)
		local relativeRotation = relativeCFrame - relativeCFrame.Position
		part.Size = part.Size * scale
		part.CFrame = pivot * CFrame.new(relativeCFrame.Position * scale) * relativeRotation
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("Attachment") then
			descendant.Position = descendant.Position * scale
		elseif descendant:IsA("ParticleEmitter") then
			descendant.Size = scaleNumberSequence(descendant.Size, scale)
			descendant.Speed = NumberRange.new(descendant.Speed.Min * scale, descendant.Speed.Max * scale)
			descendant.Acceleration = descendant.Acceleration * scale
		elseif descendant:IsA("Beam") then
			descendant.Width0 = descendant.Width0 * scale
			descendant.Width1 = descendant.Width1 * scale
		elseif descendant:IsA("Trail") then
			descendant.WidthScale = scaleNumberSequence(descendant.WidthScale, scale)
		elseif descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
			descendant.Range = descendant.Range * scale
		end
	end
end

local function scaleNumericAttribute(instance: Instance, attributeName: string, scale: number, minimum: number?)
	local value = instance:GetAttribute(attributeName)
	if typeof(value) ~= "number" then
		return
	end

	local scaled = value * scale
	if minimum then
		scaled = math.max(scaled, minimum)
	end
	instance:SetAttribute(attributeName, scaled)
end

local function applyExplosionPlaybackBudget(instance: Instance, options)
	if typeof(options) ~= "table" then
		return
	end

	local soundLightOnly = options.soundLightOnly == true
	local emitCountScale = if typeof(options.emitCountScale) == "number" then math.clamp(options.emitCountScale, 0, 1) else 1

	local function applyToDescendant(descendant: Instance)
		if emitCountScale < 0.999 then
			scaleNumericAttribute(descendant, "EmitCount", emitCountScale, 1)
			scaleNumericAttribute(descendant, "Rate", emitCountScale, 0)
			scaleNumericAttribute(descendant, "Rate_Start", emitCountScale, 0)
			scaleNumericAttribute(descendant, "Rate_End", emitCountScale, 0)
		end

		if not soundLightOnly then
			return
		end

		if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = false
			descendant:SetAttribute("Enabled", false)
		elseif descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end

	applyToDescendant(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		applyToDescendant(descendant)
	end
end

local function pivotVisualToRoot(visual: Instance, rootPart: BasePart)
	if visual:IsA("Model") then
		visual:PivotTo(rootPart.CFrame)
		return
	end

	local firstPart = getFirstBasePart(visual)
	if not firstPart then
		return
	end

	local sourceCFrame = firstPart.CFrame
	for _, part in ipairs(getBaseParts(visual)) do
		local relativeCFrame = sourceCFrame:ToObjectSpace(part.CFrame)
		part.CFrame = rootPart.CFrame * relativeCFrame
	end
end

local function getSoundInstances(instance: Instance): { Sound }
	local sounds = {}
	if instance:IsA("Sound") then
		table.insert(sounds, instance)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("Sound") then
			table.insert(sounds, descendant)
		end
	end
	return sounds
end

local function readSoundDuration(sound: Sound): number
	local timeLength = tonumber(sound.TimeLength) or 0
	if timeLength == timeLength and timeLength > 0 then
		return timeLength / math.max(tonumber(sound.PlaybackSpeed) or 1, 0.01)
	end
	return 0
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

function BombVisualUtil.GetExplosionTemplate(skinId: any): (Instance?, string, boolean)
	local resolvedSkinId = BombSkinConfig.NormalizeSkinId(skinId)
	if resolvedSkinId == "" then
		resolvedSkinId = BombSkinConfig.DefaultSkinId
	end

	local skinFolder = getSkinFolder(resolvedSkinId)
	local skinExplosion = skinFolder and skinFolder:FindFirstChild("Explosion")
	if skinExplosion then
		return skinExplosion, resolvedSkinId, false
	end

	return getDefaultExplosionTemplate(), resolvedSkinId, true
end

function BombVisualUtil.GetSkinTrajectoryBeamTemplate(skinId: any): Instance?
	local resolvedSkinId = BombSkinConfig.NormalizeSkinId(skinId)
	if resolvedSkinId == "" then
		resolvedSkinId = BombSkinConfig.DefaultSkinId
	end

	local skinFolder = getSkinFolder(resolvedSkinId)
	local beam = skinFolder and skinFolder:FindFirstChild("Beam")
	if beam and (beam:IsA("Model") or beam:IsA("BasePart")) then
		return beam
	end

	return nil
end

function BombVisualUtil.PlaceEffectInstance(instance: Instance, position: Vector3)
	local cframe = CFrame.new(position)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanQuery = false
		instance.CanTouch = false
	end
end

function BombVisualUtil.PlaySoundDescendants(instance: Instance): (boolean, number)
	local playedSound = false
	local maxDuration = 0

	for _, sound in ipairs(getSoundInstances(instance)) do
		if sound.SoundId == "" then
			continue
		end
		sound.Looped = false
		sound.TimePosition = 0
		sound:Stop()
		sound:Play()
		playedSound = true
		maxDuration = math.max(maxDuration, readSoundDuration(sound))
	end

	return playedSound, maxDuration
end

function BombVisualUtil.PlayExplosionEffect(options): { [string]: any }
	local result = {
		emitted = false,
		playedSound = false,
		template = nil,
		instance = nil,
		resolvedSkinId = BombSkinConfig.DefaultSkinId,
		usedFallback = false,
	}
	if typeof(options) ~= "table" then
		return result
	end

	local parent = options.parent
	local position = options.position
	if not (typeof(position) == "Vector3" and typeof(parent) == "Instance") then
		return result
	end

	local template
	local resolvedSkinId = BombSkinConfig.DefaultSkinId
	local usedFallback = false
	if typeof(options.assetPath) == "table" then
		template = InstanceUtil.GetByPath(ReplicatedStorage, options.assetPath)
	else
		template, resolvedSkinId, usedFallback = BombVisualUtil.GetExplosionTemplate(options.skinId)
	end
	result.template = template
	result.resolvedSkinId = resolvedSkinId
	result.usedFallback = usedFallback
	if not template then
		return result
	end

	local clone = template:Clone()
	clone.Name = if typeof(options.name) == "string" and options.name ~= "" then options.name else "BombExplosionVFX"
	BombVisualUtil.PlaceEffectInstance(clone, position + EXPLOSION_VISUAL_POSITION_OFFSET)
	local visualScale = if typeof(options.visualScale) == "number" then math.max(options.visualScale, 0.05) else 1
	scaleEffectInstance(clone, visualScale)
	applyExplosionPlaybackBudget(clone, options)
	clone.Parent = parent
	result.instance = clone

	local playedSound, soundDuration = BombVisualUtil.PlaySoundDescendants(clone)
	result.playedSound = playedSound

	local cleanedUp = false
	local function cleanup()
		if cleanedUp then
			return
		end
		cleanedUp = true
		if clone.Parent then
			clone:Destroy()
		end
	end

	local cleanupSeconds = math.max(
		tonumber(options.cleanupSeconds) or DEFAULT_EXPLOSION_CLEANUP_SECONDS,
		if soundDuration > 0 then soundDuration + 0.25 else 0
	)
	local emitModule = options.emitModule
	if options.soundLightOnly == true then
		emitModule = nil
	end
	if emitModule and type(emitModule.emit) == "function" then
		local ok, env = pcall(function()
			return emitModule.emit(clone)
		end)
		if ok then
			result.emitted = true
		end

		if ok and typeof(env) == "table" and env.Finished and type(env.Finished.finally) == "function" then
			env.Finished:finally(function()
				if playedSound and soundDuration <= 0 then
					return
				end
				if soundDuration > 0 then
					task.delay(soundDuration + 0.25, cleanup)
				else
					cleanup()
				end
			end):catch(function(err)
				warn(("%s Explosion VFX emit failed: %s"):format(options.warnPrefix or "[BombVisualUtil]", tostring(err)))
			end)
		elseif not ok then
			warn(("%s Explosion VFX emit failed: %s"):format(options.warnPrefix or "[BombVisualUtil]", tostring(env)))
		end
	end

	task.delay(cleanupSeconds, cleanup)
	return result
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

	pivotVisualToRoot(visual, rootPart)
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
