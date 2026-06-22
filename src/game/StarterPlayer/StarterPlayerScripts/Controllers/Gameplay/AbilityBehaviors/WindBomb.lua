local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local BombController = require(script.Parent.Parent:WaitForChild("BombController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type ThrowState = {
	slot: string,
	definition: AbilityDefinition,
}

local WindBomb = {} :: AbilityTypes.ClientBehavior
WindBomb.HandlesInputState = true

local activeThrow: ThrowState? = nil
local predictedCooldownEndsAt = 0
local previewConnection: RBXScriptConnection? = nil
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
	local color = getDefinitionColor(definition, "previewColor", BombConfig.PreviewColor)

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
			assetPath = context.definition.assetPath,
			name = "WindBombHeldVFX",
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

local function getImpactTemplate(path: any): Attachment?
	local template = getInstanceByPath(path)
	local impact = template and template:FindFirstChild("Impact")
	if not impact then
		if not warnedMissingImpactTemplate then
			warn("[WindBomb] Missing ReplicatedStorage.Assets.Abilities.WindBomb.WindBomb.Impact")
			warnedMissingImpactTemplate = true
		end
		return nil
	end
	if not impact:IsA("Attachment") then
		if not warnedInvalidImpactTemplate then
			warn("[WindBomb] Impact VFX asset must be an Attachment")
			warnedInvalidImpactTemplate = true
		end
		return nil
	end

	return impact
end

local function getVfxFolder(): Folder
	local existing = workspace:FindFirstChild("WindBombVFX")
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "WindBombVFX"
	folder.Parent = workspace
	return folder
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
	holder.Name = "WindBombImpactVFX"
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

local function playImpactEffect(payload: any)
	local definition = AbilityConfig.GetDefinition("WindBomb")
	local position = if typeof(payload) == "table" then payload.position else nil
	if typeof(position) ~= "Vector3" then
		return
	end

	local assetPath = if typeof(payload) == "table" and typeof(payload.assetPath) == "table"
		then payload.assetPath
		else if definition then definition.assetPath else nil
	local template = getImpactTemplate(assetPath)
	if not template then
		return
	end

	local holder = createImpactHolder(position)
	local impact = template:Clone()
	impact.Parent = holder

	EmitService.Emit(impact, "[WindBomb]")

	cleanupVisualAfterDelay(holder, 3)
end

function WindBomb.OnActivateRequested(context: ClientActivateRequestedContext): boolean
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

function WindBomb.OnEffect(context: ClientEffectContext)
	if context.effectName ~= "WindBombImpact" or context.payload.abilityId ~= "WindBomb" then
		return
	end

	playImpactEffect(context.payload)
end

return WindBomb
