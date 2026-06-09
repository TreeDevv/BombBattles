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

local Bullet = {} :: AbilityTypes.ClientBehavior
Bullet.HandlesInputState = true

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

local function getChargeAlpha(state: ChargeState): number
	local fullChargeSeconds = math.max(getDefinitionNumber(state.definition, "fullChargeSeconds", 1.75), 0.05)
	return math.clamp((os.clock() - state.startedAt) / fullChargeSeconds, 0, 1)
end

local function lerpNumber(fromValue: number, toValue: number, alpha: number): number
	return fromValue + ((toValue - fromValue) * alpha)
end

local function clearPreview()
	if previewConnection then
		previewConnection:Disconnect()
		previewConnection = nil
	end

	BombController:HideAbilityTrajectoryPreview()
end

local function updatePreview()
	local state = activeCharge
	if state and not BombController:IsHoldingBomb() then
		activeCharge = nil
		BombController:SetPrimaryBombInputSuppressed(false)
		clearPreview()
		return
	end

	if not state then
		clearPreview()
		return
	end

	if not BombController:GetThrowOrigin() then
		if state then
			activeCharge = nil
			BombController:SetPrimaryBombInputSuppressed(false)
			BombController:CancelAbilityThrowHold()
		end
		clearPreview()
		return
	end

	local chargeAlpha = getChargeAlpha(state)
	local definition = state.definition
	local speed = lerpNumber(
		getDefinitionNumber(definition, "minLaunchSpeed", 150),
		getDefinitionNumber(definition, "maxLaunchSpeed", 320),
		chargeAlpha
	)
	local gravityScale = lerpNumber(
		getDefinitionNumber(definition, "maxGravityScale", BombConfig.ProjectileGravityScale),
		getDefinitionNumber(definition, "minGravityScale", 0),
		chargeAlpha
	)
	local upwardVelocity = lerpNumber(
		getDefinitionNumber(definition, "maxUpwardVelocity", BombConfig.ProjectileUpwardVelocity),
		getDefinitionNumber(definition, "minUpwardVelocity", 0),
		chargeAlpha
	)
	local maxRange = math.max(getDefinitionNumber(definition, "maxRange", 450), 1)
	local maxFlightSeconds = math.max(getDefinitionNumber(definition, "maxFlightSeconds", BombConfig.FuseSeconds), 0.05)
	local previewSeconds = math.min(maxFlightSeconds, maxRange / math.max(speed, 1))
	local color = getDefinitionColor(definition, "previewColor", BombConfig.PreviewColor):Lerp(
		getDefinitionColor(definition, "previewFullChargeColor", Color3.fromRGB(113, 223, 255)),
		chargeAlpha
	)

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

local function stopCharge(sendCancel: boolean)
	if sendCancel and activeCharge then
		BombController:SetPrimaryBombInputSuppressed(false)
	end
	activeCharge = nil
	clearPreview()
	BombController:SetPrimaryBombInputSuppressed(false)
end

local function cancelCharge(context: ClientActivateRequestedContext?)
	if context and activeCharge then
		context.controller:SendMessage(activeCharge.slot, AbilityConfig.MessageTypes.Intent, {
			phase = "CancelCharge",
		})
	end
	BombController:CancelAbilityThrowHold()
	stopCharge(false)
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
		stopCharge(false)
	end)
	if not released then
		cancelCharge(context)
	end
	return true
end

function Bullet.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	local inputState = context.inputState
	if inputState == nil or inputState == Enum.UserInputState.Begin then
		return beginCharge(context)
	elseif inputState == Enum.UserInputState.End then
		return releaseCharge(context)
	elseif inputState == Enum.UserInputState.Cancel then
		cancelCharge(context)
		return true
	end

	return true
end

function Bullet.OnEffect(_context: ClientEffectContext)
	-- Projectile visuals are handled by BombController from the normal BombEffect flow.
end

return Bullet
