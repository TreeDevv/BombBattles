local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombController = require(script.Parent.Parent:WaitForChild("BombController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type ThrowState = {
	slot: string,
	definition: AbilityDefinition,
}

local TripleToss = {} :: AbilityTypes.ClientBehavior
TripleToss.HandlesInputState = true

local activeThrow: ThrowState? = nil
local predictedCooldownEndsAt = 0
local previewConnection: RBXScriptConnection? = nil
local warnedPreviewFailure = false

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

local function getSpreadDirections(centerDirection: Vector3, bombCount: number, spreadDegrees: number): { Vector3 }
	bombCount = math.max(math.floor(bombCount), 1)
	spreadDegrees = math.max(spreadDegrees, 0)
	if centerDirection.Magnitude <= 0.05 then
		centerDirection = Vector3.zAxis
	else
		centerDirection = centerDirection.Unit
	end
	if bombCount == 1 or spreadDegrees <= 0 then
		return { centerDirection }
	end

	local directions = {}
	local step = spreadDegrees / (bombCount - 1)
	local startAngle = -spreadDegrees * 0.5
	for index = 1, bombCount do
		local angle = math.rad(startAngle + step * (index - 1))
		local rotated = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(centerDirection)
		table.insert(directions, if rotated.Magnitude > 0.05 then rotated.Unit else centerDirection)
	end
	return directions
end

local function clearPreview()
	if previewConnection then
		previewConnection:Disconnect()
		previewConnection = nil
	end

	BombController:HideAbilityTrajectoryPreview()
end

local function updatePreview()
	local state = activeThrow
	if state and not BombController:IsHoldingBomb() then
		activeThrow = nil
		BombController:SetPrimaryBombInputSuppressed(false)
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
	local bombCount = getDefinitionNumber(definition, "bombCount", 3)
	local spreadDegrees = getDefinitionNumber(definition, "spreadDegrees", 15)
	local aimDirections = getSpreadDirections(BombController:GetThrowAimDirection(), bombCount, spreadDegrees)

	local shown = BombController:ShowAbilityTrajectoryPreview({
		aimDirections = aimDirections,
		launchSpeed = speed,
		upwardVelocity = upwardVelocity,
		gravity = workspace.Gravity * gravityScale,
		maxFlightSeconds = maxFlightSeconds,
		maxPreviewTime = previewSeconds,
		color = color,
	})
	if shown then
		warnedPreviewFailure = false
	elseif not warnedPreviewFailure then
		warnedPreviewFailure = true
		warn("[TripleToss] Failed to show trajectory preview")
	end
end

local function startPreview()
	clearPreview()
	updatePreview()
	previewConnection = RunService.RenderStepped:Connect(updatePreview)
end

local function stopThrow()
	activeThrow = nil
	clearPreview()
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

function TripleToss.OnActivateRequested(context: ClientActivateRequestedContext): boolean
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

function TripleToss.OnEffect(_context: ClientEffectContext)
end

return TripleToss
