local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombController = require(script.Parent.Parent:WaitForChild("BombController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type ChargeState = {
	slot: string,
	definition: AbilityDefinition,
	startedAt: number,
}

local ChargeBomb = {} :: AbilityTypes.ClientBehavior
ChargeBomb.HandlesInputState = true

local activeCharge: ChargeState? = nil
local predictedCooldownEndsAt = 0
local previewConnection: RBXScriptConnection? = nil

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

local function lerpNumber(fromValue: number, toValue: number, alpha: number): number
	return fromValue + ((toValue - fromValue) * alpha)
end

local function getChargeAlpha(state: ChargeState): number
	local fullChargeSeconds = math.max(getDefinitionNumber(state.definition, "fullChargeSeconds", 5), 0.05)
	return math.clamp((os.clock() - state.startedAt) / fullChargeSeconds, 0, 1)
end

local function getChargeScale(definition: AbilityDefinition, chargeAlpha: number): number
	return lerpNumber(
		getDefinitionNumber(definition, "minChargeScale", 1),
		getDefinitionNumber(definition, "maxChargeScale", 2.5),
		chargeAlpha
	)
end

local function clearPreview()
	if previewConnection then
		previewConnection:Disconnect()
		previewConnection = nil
	end

	BombController:HideAbilityTrajectoryPreview()
end

local function resetLocalFeedback()
	BombController:ResetLocalHeldBombVisualScale()
	clearPreview()
end

local function updatePreview()
	local state = activeCharge
	if state and not BombController:IsHoldingBomb() then
		activeCharge = nil
		BombController:SetPrimaryBombInputSuppressed(false)
		resetLocalFeedback()
		return
	end

	if not state then
		resetLocalFeedback()
		return
	end

	if not BombController:GetThrowOrigin() then
		activeCharge = nil
		BombController:SetPrimaryBombInputSuppressed(false)
		BombController:CancelAbilityThrowHold()
		resetLocalFeedback()
		return
	end

	local chargeAlpha = getChargeAlpha(state)
	local definition = state.definition
	local chargeScale = getChargeScale(definition, chargeAlpha)
	local color = getDefinitionColor(definition, "previewColor", BombConfig.PreviewColor):Lerp(
		getDefinitionColor(definition, "previewFullChargeColor", Color3.fromRGB(255, 88, 66)),
		chargeAlpha
	)

	BombController:SetLocalHeldBombVisualScale(chargeScale)
	BombController:ShowAbilityTrajectoryPreview({
		launchSpeed = BombConfig.ProjectileLaunchSpeed,
		upwardVelocity = BombConfig.ProjectileUpwardVelocity,
		gravity = workspace.Gravity * BombConfig.ProjectileGravityScale,
		maxFlightSeconds = BombConfig.ProjectileMaxFlightSeconds,
		maxPreviewTime = math.min(BombConfig.FuseSeconds, BombConfig.PreviewMaxSeconds),
		color = color,
	})
end

local function startPreview()
	clearPreview()
	updatePreview()
	previewConnection = RunService.RenderStepped:Connect(updatePreview)
end

local function stopCharge()
	activeCharge = nil
	BombController:SetPrimaryBombInputSuppressed(false)
	resetLocalFeedback()
end

local function cancelCharge(context: ClientActivateRequestedContext?, notifyServer: boolean)
	if context and notifyServer and activeCharge then
		context.controller:SendMessage(activeCharge.slot, AbilityConfig.MessageTypes.Intent, {
			phase = "CancelCharge",
		})
	end
	BombController:CancelAbilityThrowHold()
	stopCharge()
end

local function beginCharge(context: ClientActivateRequestedContext): boolean
	local now = workspace:GetServerTimeNow()
	if context.controller:GetCooldownRemaining(context.slot) > 0 or predictedCooldownEndsAt > now then
		return true
	end
	if activeCharge then
		return true
	end
	if not BombController:BeginAbilityThrowHold() then
		return true
	end

	activeCharge = {
		slot = context.slot,
		definition = context.definition,
		startedAt = os.clock(),
	}
	BombController:SetPrimaryBombInputSuppressed(true)
	context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Intent, {
		phase = "BeginCharge",
	})
	startPreview()
	return true
end

local function releaseCharge(context: ClientActivateRequestedContext): boolean
	local state = activeCharge
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
		stopCharge()
	end)
	if not released then
		cancelCharge(context, true)
	end
	return true
end

function ChargeBomb.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	local inputState = context.inputState
	if inputState == nil or inputState == Enum.UserInputState.Begin then
		return beginCharge(context)
	elseif inputState == Enum.UserInputState.End then
		return releaseCharge(context)
	elseif inputState == Enum.UserInputState.Cancel then
		cancelCharge(context, true)
		return true
	end

	return true
end

function ChargeBomb.OnEffect(context: ClientEffectContext)
	if context.effectName ~= "ChargeBombCancelled" then
		return
	end
	local payload = context.payload
	if payload.player ~= context.localPlayer then
		return
	end

	local state = activeCharge
	if state then
		predictedCooldownEndsAt = workspace:GetServerTimeNow()
			+ math.max(getDefinitionNumber(state.definition, "cooldownSeconds", 0), 0)
	end
	BombController:CancelAbilityThrowHold()
	stopCharge()
end

return ChargeBomb
