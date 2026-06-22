local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local ScreenEffects = require(ReplicatedStorage.Shared.UI.ScreenEffects)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local BombController = require(script.Parent.Parent:WaitForChild("BombController"))
local CameraController = require(script.Parent.Parent:WaitForChild("CameraController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type ThrowState = {
	slot: string,
	definition: AbilityDefinition,
}

type SequenceState = {
	id: number,
	folder: Folder,
	position: Vector3,
	radius: number,
	impactAt: number,
	impacted: boolean,
	flare: Instance?,
	giant: Instance?,
	connections: { RBXScriptConnection },
}

local FatBomb = {} :: AbilityTypes.ClientBehavior
FatBomb.HandlesInputState = true

local VFX_FOLDER_NAME = "FatBombVFX"
local DEFAULT_FLARE_PATH = table.freeze({ "Assets", "Abilities", "FatBomb", "Flare" })
local DEFAULT_FAT_GUY_PATH = table.freeze({ "Assets", "Abilities", "FatBomb", "Fat Guy" })
local DEFAULT_IMPACT_VFX_PATH = table.freeze({ "Assets", "Abilities", "FatBomb", "FatImpact" })
local FAT_GUY_ROTATION = CFrame.Angles(0, 0, math.rad(90))
local FAT_GUY_CENTER_ATTACHMENT_NAME = "Center"
local DEFAULT_FALLING_SPAWN_HEIGHT = 100
local FALLING_END_HEIGHT = 0

local activeThrow: ThrowState? = nil
local predictedCooldownEndsAt = 0
local previewConnection: RBXScriptConnection? = nil
local activeSequences: { [number]: SequenceState } = {}
local warnedMissingImpactTemplate = false
local warnedInvalidImpactTemplate = false

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

local function getDefinitionPath(definition: AbilityDefinition?, key: string, fallback: { string })
	local value = if definition then definition[key] else nil
	return if typeof(value) == "table" then value else fallback
end

local function getServerTime(): number
	return workspace:GetServerTimeNow()
end

local function getVfxRoot(): Folder
	local existing = workspace:FindFirstChild(VFX_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = VFX_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function getInstanceByPath(path: any): Instance?
	if typeof(path) ~= "table" then
		return nil
	end

	local current: Instance? = ReplicatedStorage
	for _, name in ipairs(path) do
		if typeof(name) ~= "string" or name == "" or not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
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

local function getBounds(instance: Instance): (CFrame, Vector3)
	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	end
	local part = instance :: BasePart
	return part.CFrame, part.Size
end

local function pivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function getPivot(instance: Instance): CFrame
	if instance:IsA("Model") then
		return instance:GetPivot()
	elseif instance:IsA("BasePart") then
		return instance.CFrame
	end
	return CFrame.new()
end

local function prepareVisualInstance(instance: Instance)
	for _, part in ipairs(getBaseParts(instance)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.AssemblyLinearVelocity = Vector3.zero
		part.AssemblyAngularVelocity = Vector3.zero
	end
end

local function setDescendantEffectsEnabled(instance: Instance, enabled: boolean)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Beam")
			or descendant:IsA("PointLight")
			or descendant:IsA("SpotLight")
			or descendant:IsA("SurfaceLight")
		then
			descendant.Enabled = enabled
		elseif descendant:IsA("Sound") then
			if enabled and descendant.SoundId ~= "" then
				descendant:Play()
			else
				descendant:Stop()
			end
		end
	end
end

local function emitDescendantEffects(instance: Instance, defaultCount: number)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			local count = descendant:GetAttribute("EmitCount")
			descendant:Emit(if typeof(count) == "number" then math.max(math.floor(count), 1) else defaultCount)
		elseif descendant:IsA("Sound") and descendant.SoundId ~= "" then
			descendant:Play()
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

local function scaleVisualInstance(instance: Instance, scale: number)
	if math.abs(scale - 1) < 0.001 then
		return
	end

	local pivot = getPivot(instance)
	for _, part in ipairs(getBaseParts(instance)) do
		local relative = pivot:ToObjectSpace(part.CFrame)
		local rotation = relative - relative.Position
		part.Size *= scale
		part.CFrame = pivot * CFrame.new(relative.Position * scale) * rotation
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("Attachment") then
			descendant.Position *= scale
		elseif descendant:IsA("ParticleEmitter") then
			descendant.Size = scaleNumberSequence(descendant.Size, scale)
			descendant.Speed = NumberRange.new(descendant.Speed.Min * scale, descendant.Speed.Max * scale)
			descendant.Acceleration *= scale
		elseif descendant:IsA("Trail") then
			descendant.WidthScale = scaleNumberSequence(descendant.WidthScale, scale)
		elseif descendant:IsA("Beam") then
			descendant.Width0 *= scale
			descendant.Width1 *= scale
		elseif descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
			descendant.Range *= scale
		end
	end
end

local function cloneAsset(path: any, name: string): Instance?
	local template = getInstanceByPath(path)
	if not (template and (template:IsA("Model") or template:IsA("BasePart"))) then
		return nil
	end

	local clone = template:Clone()
	clone.Name = name
	prepareVisualInstance(clone)
	setDescendantEffectsEnabled(clone, true)
	return clone
end

local function tween(instance: Instance, info: TweenInfo, goals: { [string]: any }): Tween
	local created = TweenService:Create(instance, info, goals)
	created:Play()
	return created
end

local function makePart(name: string, parent: Instance, size: Vector3, cframe: CFrame, color: Color3, transparency: number, material: Enum.Material?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Size = size
	part.CFrame = cframe
	part.Material = material or Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	part.Parent = parent
	return part
end

local function makeFlatCylinder(name: string, parent: Instance, position: Vector3, radius: number, color: Color3, transparency: number, material: Enum.Material?): Part
	local part = makePart(
		name,
		parent,
		Vector3.new(0.08, radius * 2, radius * 2),
		CFrame.new(position + Vector3.yAxis * 0.08) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		transparency,
		material
	)
	part.Shape = Enum.PartType.Cylinder
	return part
end

local function cleanupSequence(sequence: SequenceState, delaySeconds: number)
	task.delay(math.max(delaySeconds, 0), function()
		if activeSequences[sequence.id] == sequence then
			activeSequences[sequence.id] = nil
		end
		for _, connection in ipairs(sequence.connections) do
			connection:Disconnect()
		end
		table.clear(sequence.connections)
		if sequence.folder.Parent then
			sequence.folder:Destroy()
		end
	end)
end

local function clearPreview()
	if previewConnection then
		previewConnection:Disconnect()
		previewConnection = nil
	end

	BombController:HideAbilityTrajectoryPreview()
end

local function clearHeldVisual()
	if type(BombController.ClearLocalAbilityHeldVisual) == "function" then
		BombController:ClearLocalAbilityHeldVisual()
	end
end

local function updatePreview()
	local state = activeThrow
	if state and not BombController:IsHoldingBomb() then
		activeThrow = nil
		BombController:SetPrimaryBombInputSuppressed(false)
		clearHeldVisual()
		clearPreview()
		return
	end

	if not state then
		clearPreview()
		return
	end

	if not BombController:GetThrowOrigin() then
		activeThrow = nil
		BombController:SetPrimaryBombInputSuppressed(false)
		BombController:CancelAbilityThrowHold()
		clearHeldVisual()
		clearPreview()
		return
	end

	local definition = state.definition
	local speed = getDefinitionNumber(definition, "projectileLaunchSpeed", BombConfig.ProjectileLaunchSpeed)
	local gravityScale = getDefinitionNumber(definition, "projectileGravityScale", BombConfig.ProjectileGravityScale)
	local upwardVelocity = getDefinitionNumber(definition, "projectileUpwardVelocity", BombConfig.ProjectileUpwardVelocity)
	local maxFlightSeconds = math.max(getDefinitionNumber(definition, "projectileMaxFlightSeconds", 4.25), 0.05)
	local color = getDefinitionColor(definition, "previewColor", Color3.fromRGB(255, 92, 36))

	BombController:ShowAbilityTrajectoryPreview({
		launchSpeed = speed,
		upwardVelocity = upwardVelocity,
		gravity = workspace.Gravity * gravityScale,
		maxFlightSeconds = maxFlightSeconds,
		maxPreviewTime = math.min(maxFlightSeconds, BombConfig.PreviewMaxSeconds),
		color = color,
	})
end

local function startPreview()
	clearPreview()
	updatePreview()
	previewConnection = RunService.RenderStepped:Connect(updatePreview)
end

local function stopThrow()
	activeThrow = nil
	clearPreview()
	clearHeldVisual()
	BombController:SetPrimaryBombInputSuppressed(false)
end

local function cancelThrow()
	BombController:CancelAbilityThrowHold()
	stopThrow()
end

local function beginThrow(context: ClientActivateRequestedContext): boolean
	local now = getServerTime()
	if context.controller:GetCooldownRemaining(context.slot) > 0 or predictedCooldownEndsAt > now then
		return true
	end
	if activeThrow then
		return true
	end

	if type(BombController.SetLocalAbilityHeldVisual) == "function" then
		BombController:SetLocalAbilityHeldVisual({
			assetPath = getDefinitionPath(context.definition, "flareVisualAssetPath", DEFAULT_FLARE_PATH),
			name = "FatBombHeldFlareVFX",
			replaceBaseVisual = true,
		})
	end

	BombController:SetPrimaryBombInputSuppressed(true)
	if not BombController:BeginAbilityThrowHold() then
		BombController:SetPrimaryBombInputSuppressed(false)
		clearHeldVisual()
		return true
	end

	activeThrow = {
		slot = context.slot,
		definition = context.definition,
	}
	startPreview()
	return true
end

local function releaseThrow(context: ClientActivateRequestedContext): boolean
	local state = activeThrow
	if not state then
		return true
	end

	clearPreview()
	local released = BombController:ReleaseAbilityThrowHold(function()
		context.controller:SendMessage(state.slot, AbilityConfig.MessageTypes.Activate, {
			aimDirection = BombController:GetThrowAimDirection(),
		})
		predictedCooldownEndsAt = getServerTime() + math.max(getDefinitionNumber(state.definition, "cooldownSeconds", 0), 0)
		stopThrow()
	end)
	if not released then
		cancelThrow()
	end
	return true
end

local function createLandingFlare(sequence: SequenceState, definition: AbilityDefinition?, color: Color3): Instance
	local flare = cloneAsset(getDefinitionPath(definition, "flareVisualAssetPath", DEFAULT_FLARE_PATH), "FatBombLandedFlare")
	if flare then
		flare.Parent = sequence.folder
		pivotTo(flare, CFrame.new(sequence.position + Vector3.yAxis * 0.28) * CFrame.Angles(math.rad(-82), 0, math.rad(10)))
		emitDescendantEffects(flare, 10)
		sequence.flare = flare
		return flare
	end

	local fallback = makePart(
		"FatBombLandedFlareFallback",
		sequence.folder,
		Vector3.new(0.28, 1.45, 0.28),
		CFrame.new(sequence.position + Vector3.yAxis * 0.72) * CFrame.Angles(math.rad(-10), 0, math.rad(8)),
		color,
		0,
		Enum.Material.Neon
	)
	sequence.flare = fallback
	return fallback
end

local function extinguishFlare(sequence: SequenceState)
	local flare = sequence.flare
	if not (flare and flare.Parent) then
		return
	end

	setDescendantEffectsEnabled(flare, false)
	for _, part in ipairs(getBaseParts(flare)) do
		tween(part, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1,
		})
	end
end

local function createGiantFromAsset(sequence: SequenceState, definition: AbilityDefinition?): Instance?
	local giant = cloneAsset(getDefinitionPath(definition, "fallingCharacterAssetPath", DEFAULT_FAT_GUY_PATH), "FatBombFallingGiant")
	if not giant then
		return nil
	end

	scaleVisualInstance(giant, getDefinitionNumber(definition, "fallingCharacterScale", 0.82))
	giant.Parent = sequence.folder
	sequence.giant = giant
	return giant
end

local function getGiantBottomOffset(giant: Instance): number
	local boundsCFrame, boundsSize = getBounds(giant)
	local pivot = getPivot(giant)
	return math.max(pivot.Position.Y - (boundsCFrame.Position.Y - boundsSize.Y * 0.5), 0)
end

local function getCenterLocalOffset(giant: Instance): Vector3?
	local center = giant:FindFirstChild(FAT_GUY_CENTER_ATTACHMENT_NAME, true)
	if center and center:IsA("Attachment") then
		return getPivot(giant):PointToObjectSpace(center.WorldPosition)
	end
	return nil
end

local function setGiantPose(giant: Instance, position: Vector3, height: number)
	local centerLocalOffset = getCenterLocalOffset(giant)
	if centerLocalOffset then
		local targetCenter = position + Vector3.yAxis * height
		local pivotPosition = targetCenter - FAT_GUY_ROTATION:VectorToWorldSpace(centerLocalOffset)
		pivotTo(giant, CFrame.new(pivotPosition) * FAT_GUY_ROTATION)
		return
	end

	local bottomOffset = getGiantBottomOffset(giant)
	pivotTo(giant, CFrame.new(position + Vector3.yAxis * (height + bottomOffset)) * FAT_GUY_ROTATION)
end

local playImpactVisual

local function tweenGiantToImpact(sequence: SequenceState, giant: Instance, definition: AbilityDefinition?, impactAt: number)
	local startAt = getServerTime()
	local fallDuration = math.max(impactAt - startAt, 0.15)
	local startHeight = math.max(getDefinitionNumber(definition, "fallingSpawnHeight", DEFAULT_FALLING_SPAWN_HEIGHT), FALLING_END_HEIGHT)
	local heightValue = Instance.new("NumberValue")
	heightValue.Name = "FatBombFallHeight"
	heightValue.Value = startHeight
	setGiantPose(giant, sequence.position, startHeight)

	table.insert(sequence.connections, heightValue:GetPropertyChangedSignal("Value"):Connect(function()
		if not sequence.impacted and giant.Parent then
			setGiantPose(giant, sequence.position, heightValue.Value)
		end
	end))

	local created = TweenService:Create(heightValue, TweenInfo.new(fallDuration, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
		Value = FALLING_END_HEIGHT,
	})
	created.Completed:Once(function(playbackState)
		heightValue:Destroy()
		if playbackState == Enum.PlaybackState.Completed and activeSequences[sequence.id] == sequence then
			playImpactVisual(sequence, definition)
		end
	end)
	created:Play()
end

local function animateGiant(sequence: SequenceState, definition: AbilityDefinition?, revealDelay: number, impactAt: number)
	task.delay(revealDelay, function()
		if sequence.impacted or not sequence.folder.Parent then
			return
		end

		local giant = createGiantFromAsset(sequence, definition)
		if not giant then
			return
		end

		setDescendantEffectsEnabled(giant, true)
		tweenGiantToImpact(sequence, giant, definition, impactAt)
	end)
end

local function fadeOutInstance(instance: Instance, duration: number)
	setDescendantEffectsEnabled(instance, false)
	for _, part in ipairs(getBaseParts(instance)) do
		tween(part, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1,
		})
	end
end

local function playImpactCamera(position: Vector3, radius: number, definition: AbilityDefinition?)
	if type(CameraController.PlayOrbitalStrikeShake) == "function" then
		CameraController:PlayOrbitalStrikeShake(position, definition)
	elseif type(CameraController.PlayExplosionShake) == "function" then
		CameraController:PlayExplosionShake(position, radius)
	end
	ScreenEffects.FlashColor(Color3.fromRGB(255, 112, 54), 0.12, 0.45)
end

local function cleanupVisualAfterDelay(instance: Instance, cleanupSeconds: number)
	task.delay(math.max(cleanupSeconds, 0), function()
		if instance.Parent then
			instance:Destroy()
		end
	end)
end

local function createImpactAttachmentHolder(position: Vector3): BasePart
	local holder = Instance.new("Part")
	holder.Name = "FatBombImpactVFXHolder"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.CastShadow = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1, 1, 1)
	holder.CFrame = CFrame.new(position)
	holder.Parent = getVfxRoot()
	return holder
end

local function playImpactAssetVfx(sequence: SequenceState, definition: AbilityDefinition?)
	local template = getInstanceByPath(getDefinitionPath(definition, "impactVfxAssetPath", DEFAULT_IMPACT_VFX_PATH))
	if not template then
		if not warnedMissingImpactTemplate then
			warn("[FatBomb] Missing ReplicatedStorage.Assets.Abilities.FatBomb.FatImpact")
			warnedMissingImpactTemplate = true
		end
		return
	end
	if not (template:IsA("Model") or template:IsA("BasePart") or template:IsA("Attachment")) then
		if not warnedInvalidImpactTemplate then
			warn("[FatBomb] Impact VFX asset must be a Model, BasePart, or Attachment")
			warnedInvalidImpactTemplate = true
		end
		return
	end

	local clone = template:Clone()
	clone.Name = "FatBombImpactVFX"
	if clone:IsA("Attachment") then
		scaleVisualInstance(clone, getDefinitionNumber(definition, "impactVfxScale", getDefinitionNumber(definition, "explosionVisualScale", 1)))
		clone.Parent = createImpactAttachmentHolder(sequence.position)
	else
		prepareVisualInstance(clone)
		scaleVisualInstance(clone, getDefinitionNumber(definition, "impactVfxScale", getDefinitionNumber(definition, "explosionVisualScale", 1)))
		pivotTo(clone, CFrame.new(sequence.position))
		clone.Parent = sequence.folder
	end

	local playedSound = false
	local maxSoundDuration = 0
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("Sound") and descendant.SoundId ~= "" then
			descendant.Looped = false
			descendant.TimePosition = 0
			descendant:Stop()
			descendant:Play()
			playedSound = true
			local duration = tonumber(descendant.TimeLength) or 0
			if duration > 0 then
				maxSoundDuration = math.max(maxSoundDuration, duration / math.max(tonumber(descendant.PlaybackSpeed) or 1, 0.01))
			end
		end
	end

	local cleanupRoot = if clone:IsA("Attachment") then clone.Parent else clone
	local cleanupSeconds = math.max(getDefinitionNumber(definition, "impactVisualCleanupSeconds", 5), maxSoundDuration + 0.25, 0.25)
	local ok, env = EmitService.EmitWithResult(clone, "[FatBomb]")
	if ok then
		if typeof(env) == "table" and env.Finished and type(env.Finished.finally) == "function" then
			env.Finished:finally(function()
				if playedSound and maxSoundDuration <= 0 then
					return
				end
				if maxSoundDuration > 0 then
					task.delay(maxSoundDuration + 0.25, function()
						if cleanupRoot and cleanupRoot.Parent then
							cleanupRoot:Destroy()
						end
					end)
				elseif cleanupRoot and cleanupRoot.Parent then
					cleanupRoot:Destroy()
				end
			end):catch(function(err)
				warn("[FatBomb] Impact VFX emit failed: " .. tostring(err))
			end)
		end
	end

	if cleanupRoot then
		cleanupVisualAfterDelay(cleanupRoot, cleanupSeconds)
	end
end

function playImpactVisual(sequence: SequenceState, definition: AbilityDefinition?)
	if sequence.impacted then
		return
	end
	sequence.impacted = true

	playImpactCamera(sequence.position, sequence.radius, definition)
	playImpactAssetVfx(sequence, definition)
	extinguishFlare(sequence)

	local shockwave = makeFlatCylinder(
		"FatBombShockwave",
		sequence.folder,
		sequence.position,
		1.5,
		Color3.fromRGB(255, 244, 214),
		0.46,
		Enum.Material.Neon
	)
	local shockwaveScale = getDefinitionNumber(definition, "impactShockwaveScale", 1.25)
	tween(shockwave, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.08, sequence.radius * shockwaveScale, sequence.radius * shockwaveScale),
		Transparency = 1,
	})

	local giant = sequence.giant
	if giant and giant.Parent then
		setGiantPose(giant, sequence.position, FALLING_END_HEIGHT)
		task.delay(getDefinitionNumber(definition, "exitSeconds", 0.3), function()
			if giant.Parent then
				fadeOutInstance(giant, 0.16)
			end
		end)
	end
end

local function playLandingSequence(payload: any)
	if typeof(payload) ~= "table" or payload.abilityId ~= "FatBomb" then
		return
	end
	if typeof(payload.position) ~= "Vector3" then
		return
	end

	local sequenceId = if typeof(payload.sequenceId) == "number" then payload.sequenceId else math.floor(getServerTime() * 1000)
	if activeSequences[sequenceId] then
		return
	end

	local definition = AbilityConfig.GetDefinition("FatBomb")
	local radius = if typeof(payload.radius) == "number" then math.max(payload.radius, 1) else 28
	local position = payload.position
	local impactAt = if typeof(payload.impactAt) == "number" then payload.impactAt else getServerTime() + 1
	local flareColor = if typeof(payload.flareColor) == "Color3" then payload.flareColor else Color3.fromRGB(255, 86, 28)

	local folder = Instance.new("Folder")
	folder.Name = "FatBombSequence_" .. tostring(sequenceId)
	folder.Parent = getVfxRoot()

	local sequence: SequenceState = {
		id = sequenceId,
		folder = folder,
		position = position,
		radius = radius,
		impactAt = impactAt,
		impacted = false,
		flare = nil,
		giant = nil,
		connections = {},
	}
	activeSequences[sequenceId] = sequence

	local danger = makeFlatCylinder("FatBombDangerCircle", folder, position, radius, Color3.fromRGB(255, 48, 38), 0.56, Enum.Material.Neon)
	local shadow = makeFlatCylinder("FatBombShadow", folder, position, radius * 0.18, Color3.fromRGB(0, 0, 0), 0.62, Enum.Material.SmoothPlastic)
	local flare = createLandingFlare(sequence, definition, flareColor)
	scaleVisualInstance(flare, getDefinitionNumber(definition, "landedFlareScale", 1.15))

	local remaining = math.max(impactAt - getServerTime(), 0.15)
	tween(shadow, TweenInfo.new(remaining, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = Vector3.new(0.08, radius * 1.55, radius * 1.55),
		Transparency = 0.32,
	})
	tween(danger, TweenInfo.new(remaining, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 0.42,
	})
	animateGiant(sequence, definition, math.max(tonumber(payload.revealDelaySeconds) or 0.2, 0), impactAt)

	task.delay(math.max(impactAt - getServerTime() - 0.1, 0), function()
		extinguishFlare(sequence)
	end)

	task.delay(math.max(impactAt - getServerTime(), 0), function()
		if activeSequences[sequenceId] == sequence then
			playImpactVisual(sequence, definition)
		end
	end)

	cleanupSequence(sequence, remaining + 1.15)
end

local function playRemoteImpact(payload: any)
	if typeof(payload) ~= "table" or payload.abilityId ~= "FatBomb" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local sequenceId = if typeof(payload.sequenceId) == "number" then payload.sequenceId else nil
	local sequence = sequenceId and activeSequences[sequenceId] or nil
	if sequence then
		playImpactVisual(sequence, AbilityConfig.GetDefinition("FatBomb"))
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "FatBombLateImpact"
	folder.Parent = getVfxRoot()
	local temp: SequenceState = {
		id = -math.floor(getServerTime() * 1000),
		folder = folder,
		position = payload.position,
		radius = if typeof(payload.radius) == "number" then payload.radius else 28,
		impactAt = getServerTime(),
		impacted = false,
		flare = nil,
		giant = nil,
		connections = {},
	}
	playImpactVisual(temp, AbilityConfig.GetDefinition("FatBomb"))
	cleanupSequence(temp, 0.75)
end

function FatBomb.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	local inputState = context.inputState
	if inputState == nil or inputState == Enum.UserInputState.Begin then
		return beginThrow(context)
	elseif inputState == Enum.UserInputState.End then
		return releaseThrow(context)
	elseif inputState == Enum.UserInputState.Cancel then
		cancelThrow()
		return true
	end

	return true
end

function FatBomb.OnEffect(context: ClientEffectContext)
	if context.effectName == "FatBombFlareLanded" then
		playLandingSequence(context.payload)
	elseif context.effectName == "FatBombImpact" then
		playRemoteImpact(context.payload)
	end
end

return FatBomb
