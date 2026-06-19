local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombController = require(script.Parent.Parent:WaitForChild("BombController"))
local BombTrajectoryClient = require(script.Parent.Parent:WaitForChild("BombTrajectoryClient"))

local LocalPlayer = Players.LocalPlayer

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type ThrowState = {
	slot: string,
	definition: AbilityDefinition,
}

local DrillBomb = {} :: AbilityTypes.ClientBehavior
DrillBomb.HandlesInputState = true

local activeThrow: ThrowState? = nil
local predictedCooldownEndsAt = 0
local previewConnection: RBXScriptConnection? = nil
local drillPreviewPart: Part? = nil

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

local function hideDrillPreview()
	if drillPreviewPart then
		drillPreviewPart:Destroy()
		drillPreviewPart = nil
	end
end

local function showDrillPreview(fromPosition: Vector3, toPosition: Vector3, color: Color3)
	local delta = toPosition - fromPosition
	local distance = delta.Magnitude
	if distance <= 0.05 then
		hideDrillPreview()
		return
	end

	local part = drillPreviewPart
	if not (part and part.Parent) then
		part = Instance.new("Part")
		part.Name = "DrillBombBurrowPreview"
		part.Shape = Enum.PartType.Cylinder
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Material = Enum.Material.Neon
		part.Parent = workspace
		drillPreviewPart = part
	end

	local thickness = 0.42
	part.Color = color
	part.Transparency = 0.38
	part.Size = Vector3.new(thickness, distance, thickness)
	part.CFrame = CFrame.lookAt(fromPosition + delta * 0.5, toPosition) * CFrame.Angles(math.pi / 2, 0, 0)
end

local function updateDrillPreview(
	definition: AbilityDefinition,
	origin: Vector3,
	aimDirection: Vector3,
	launchSpeed: number,
	upwardVelocity: number,
	gravity: number,
	maxFlightSeconds: number,
	previewSeconds: number
)
	local path = BombTrajectoryClient.CalculateTrajectoryWithConfig(
		origin,
		aimDirection,
		launchSpeed,
		upwardVelocity,
		gravity,
		maxFlightSeconds
	)
	local hit, endElapsed = BombTrajectoryClient.FindPreviewTrajectoryHit(path, previewSeconds, LocalPlayer.Character)
	if not hit then
		hideDrillPreview()
		return
	end

	local endAlpha = math.clamp(endElapsed / path.duration, 0, 1)
	local incomingVelocity = BombTrajectory.GetVelocity(path, endAlpha)
	local direction = if incomingVelocity.Magnitude > 0.05 then incomingVelocity.Unit else aimDirection.Unit
	local startInset = getDefinitionNumber(definition, "drillStartInset", 2.2)
	local drillDistance = getDefinitionNumber(definition, "drillBurrowDistance", 42)
	local color = getDefinitionColor(definition, "drillColor", getDefinitionColor(definition, "previewColor", BombConfig.PreviewColor))
	local startPosition = hit.Position + direction * startInset

	showDrillPreview(startPosition, startPosition + direction * drillDistance, color)
end

local function clearPreview()
	if previewConnection then
		previewConnection:Disconnect()
		previewConnection = nil
	end

	hideDrillPreview()
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

	local origin = BombController:GetThrowOrigin()
	if not origin then
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
	local gravity = workspace.Gravity * gravityScale
	local maxFlightSeconds = math.max(
		getDefinitionNumber(definition, "projectileMaxFlightSeconds", BombConfig.FuseSeconds),
		0.05
	)
	local previewSeconds = math.min(maxFlightSeconds, BombConfig.PreviewMaxSeconds)
	local color = getDefinitionColor(definition, "previewColor", BombConfig.PreviewColor)
	local aimDirection = BombController:GetThrowAimDirection()

	BombController:ShowAbilityTrajectoryPreview({
		launchSpeed = speed,
		upwardVelocity = upwardVelocity,
		gravity = gravity,
		maxFlightSeconds = maxFlightSeconds,
		maxPreviewTime = previewSeconds,
		color = color,
		aimDirection = aimDirection,
	})
	updateDrillPreview(definition, origin, aimDirection, speed, upwardVelocity, gravity, maxFlightSeconds, previewSeconds)
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

function DrillBomb.OnActivateRequested(context: ClientActivateRequestedContext): boolean
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

function DrillBomb.OnEffect(_context: ClientEffectContext)
end

return DrillBomb
