local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local BombController = require(script.Parent.Parent:WaitForChild("BombController"))
local ScreenEffectsController = require(script.Parent.Parent:WaitForChild("ScreenEffectsController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type ThrowState = {
	slot: string,
	definition: AbilityDefinition,
}

local AcidBomb = {} :: AbilityTypes.ClientBehavior
AcidBomb.HandlesInputState = true

local activeThrow: ThrowState? = nil
local predictedCooldownEndsAt = 0
local previewConnection: RBXScriptConnection? = nil
local warnedMissingImpactTemplate = false
local warnedInvalidImpactTemplate = false
local warnedMissingZoneTemplate = false

local VFX_FOLDER_NAME = "AcidBombVFX"

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
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

local function getVfxFolder(): Folder
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

local function setVisualEffectsEnabled(instance: Instance, enabled: boolean)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Beam")
			or descendant:IsA("PointLight")
			or descendant:IsA("SpotLight")
			or descendant:IsA("SurfaceLight")
		then
			descendant.Enabled = enabled
		elseif descendant:IsA("Sound") and enabled then
			descendant:Play()
		end
	end
end

local function prepareAnchoredVisual(instance: Instance, position: Vector3)
	if instance:IsA("Model") then
		instance:PivotTo(CFrame.new(position) * instance:GetPivot().Rotation)
	elseif instance:IsA("BasePart") then
		instance.CFrame = CFrame.new(position) * instance.CFrame.Rotation
	end

	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = false
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

local function cleanupVisualAfterDelay(instance: Instance, cleanupSeconds: number)
	local cleaned = false
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		if instance.Parent then
			instance:Destroy()
		end
	end

	task.delay(cleanupSeconds, cleanup)
end

local function createImpactHolder(position: Vector3): BasePart
	local holder = Instance.new("Part")
	holder.Name = "AcidBombImpactVFX"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.CastShadow = false
	holder.Transparency = 1
	holder.Size = Vector3.new(1, 1, 1)
	holder.CFrame = CFrame.new(position)
	holder.Parent = getVfxFolder()
	return holder
end

local function playImpactEffect(position: Vector3, payload: any, definition: AbilityDefinition?)
	local assetPath = if typeof(payload) == "table" and typeof(payload.impactVfxAssetPath) == "table"
		then payload.impactVfxAssetPath
		else if definition then definition.impactVfxAssetPath else nil
	local template = getInstanceByPath(assetPath)
	if not template then
		if not warnedMissingImpactTemplate then
			warn("[AcidBomb] Missing ReplicatedStorage.Assets.Abilities.AcidBomb.AcidBomb.Impact")
			warnedMissingImpactTemplate = true
		end
		return
	end
	if not template:IsA("Attachment") then
		if not warnedInvalidImpactTemplate then
			warn("[AcidBomb] Impact VFX asset must be an Attachment")
			warnedInvalidImpactTemplate = true
		end
		return
	end

	local holder = createImpactHolder(position)
	local impact = template:Clone()
	impact.Parent = holder

	EmitService.Emit(impact, "[AcidBomb]")

	local cleanupSeconds = math.max(getDefinitionNumber(definition, "impactVisualCleanupSeconds", 3), 0.25)
	cleanupVisualAfterDelay(holder, cleanupSeconds)
end

local function playZoneEffect(position: Vector3, payload: any, definition: AbilityDefinition?)
	local assetPath = if typeof(payload) == "table" and typeof(payload.zoneVfxAssetPath) == "table"
		then payload.zoneVfxAssetPath
		else if definition and typeof(definition.zoneVfxAssetPath) == "table"
			then definition.zoneVfxAssetPath
			else if definition then definition.assetPath else nil
	local template = getInstanceByPath(assetPath)
	if not template then
		if not warnedMissingZoneTemplate then
			warn("[AcidBomb] Missing ReplicatedStorage.Assets.Abilities.AcidBomb.AcidFloor")
			warnedMissingZoneTemplate = true
		end
		return
	end

	local clone = template:Clone()
	clone.Name = "AcidBombZoneVFX"
	prepareAnchoredVisual(clone, position)
	clone.Parent = getVfxFolder()
	setVisualEffectsEnabled(clone, true)

	local durationSeconds = if typeof(payload) == "table" and typeof(payload.durationSeconds) == "number"
		then math.max(payload.durationSeconds, 0)
		else math.max(getDefinitionNumber(definition, "acidDurationSeconds", 7), 0)
	local cleanupSeconds = math.max(getDefinitionNumber(definition, "acidVisualCleanupSeconds", 4), 0.25)
	task.delay(durationSeconds, function()
		if clone.Parent then
			setVisualEffectsEnabled(clone, false)
		end
	end)
	cleanupVisualAfterDelay(clone, durationSeconds + cleanupSeconds)
end

local function playAcidAreaEffect(payload: any)
	local position = if typeof(payload) == "table" then payload.position else nil
	if typeof(position) ~= "Vector3" then
		return
	end

	local definition = AbilityConfig.GetDefinition("AcidBomb")
	playImpactEffect(position, payload, definition)
	playZoneEffect(position, payload, definition)
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
	local maxFlightSeconds = math.max(
		getDefinitionNumber(definition, "projectileMaxFlightSeconds", BombConfig.FuseSeconds),
		0.05
	)
	local previewSeconds = math.min(maxFlightSeconds, BombConfig.PreviewMaxSeconds)
	local color = getDefinitionColor(definition, "previewColor", Color3.fromRGB(116, 255, 72))

	BombController:ShowAbilityTrajectoryPreview({
		launchSpeed = speed,
		upwardVelocity = upwardVelocity,
		gravity = workspace.Gravity * gravityScale,
		maxFlightSeconds = maxFlightSeconds,
		maxPreviewTime = previewSeconds,
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
	local now = workspace:GetServerTimeNow()
	if context.controller:GetCooldownRemaining(context.slot) > 0 or predictedCooldownEndsAt > now then
		return true
	end
	if activeThrow then
		return true
	end
	if not BombController:BeginAbilityThrowHold() then
		return true
	end

	if type(BombController.SetLocalAbilityHeldVisual) == "function" then
		BombController:SetLocalAbilityHeldVisual({
			assetPath = context.definition.travelVfxAssetPath or context.definition.assetPath,
			name = "AcidBombHeldVFX",
			disabledAttachmentName = "Impact",
		})
	end

	activeThrow = {
		slot = context.slot,
		definition = context.definition,
	}
	BombController:SetPrimaryBombInputSuppressed(true)
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
		predictedCooldownEndsAt = workspace:GetServerTimeNow()
			+ math.max(getDefinitionNumber(state.definition, "cooldownSeconds", 0), 0)
		stopThrow()
	end)
	if not released then
		cancelThrow()
	end
	return true
end

local function playAcidScreenEffect(payload: any)
	local duration = if typeof(payload) == "table" and typeof(payload.durationSeconds) == "number"
		then payload.durationSeconds
		else 0.85
	ScreenEffectsController:Apply("Acid", math.max(duration, 0.05), {
		refresh = true,
		intensity = 1,
	})
end

function AcidBomb.OnActivateRequested(context: ClientActivateRequestedContext): boolean
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

function AcidBomb.OnEffect(context: ClientEffectContext)
	local payload = context.payload
	if typeof(payload) ~= "table" or payload.abilityId ~= "AcidBomb" then
		return
	end

	if context.effectName == "AcidBombApplied" then
		playAcidScreenEffect(payload)
	elseif context.effectName == "AcidBombAreaStarted" then
		playAcidAreaEffect(payload)
	end
end

return AcidBomb
