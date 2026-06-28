local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local CollisionGroupConfig = require(ReplicatedStorage.Shared.Config.CollisionGroupConfig)
local BombLaunchClearance = require(ReplicatedStorage.Shared.Bombs.BombLaunchClearance)
local BombThrowOrigin = require(ReplicatedStorage.Shared.Common.BombThrowOrigin)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)

local BombTrajectoryClient = {}
local BOMB_PROJECTILE_COLLISION_GROUP = CollisionGroupConfig.Groups.BombProjectile

local MIN_AIM_HORIZONTAL = 0.08

local function isTouchAimPreferred(): boolean
	local ok, preferredInput = pcall(function()
		return UserInputService.PreferredInput
	end)
	if ok and typeof(preferredInput) == "EnumItem" then
		return preferredInput.Name == "Touch"
	end

	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

function BombTrajectoryClient.GetHorizontalDirection(direction: Vector3?): Vector3?
	if typeof(direction) ~= "Vector3" then
		return nil
	end

	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	if horizontal.Magnitude <= MIN_AIM_HORIZONTAL then
		return nil
	end

	return horizontal.Unit
end

function BombTrajectoryClient.GetFallbackAimDirection(rootPart: BasePart?): Vector3
	local horizontal = if rootPart then BombTrajectoryClient.GetHorizontalDirection(rootPart.CFrame.LookVector) else nil
	return horizontal or Vector3.new(0, 0, -1)
end

function BombTrajectoryClient.SanitizeAimDirection(direction: Vector3, fallback: Vector3): Vector3
	local horizontal = BombTrajectoryClient.GetHorizontalDirection(direction)
	if not horizontal then
		horizontal = BombTrajectoryClient.GetHorizontalDirection(fallback) or Vector3.new(0, 0, -1)
		direction = Vector3.new(horizontal.X, direction.Y, horizontal.Z)
	end

	direction = Vector3.new(direction.X, math.clamp(direction.Y, BombConfig.MinAimY, BombConfig.MaxAimY), direction.Z)
	if direction.Magnitude < 0.05 then
		return Vector3.new(horizontal.X, 0.15, horizontal.Z).Unit
	end

	return direction.Unit
end

function BombTrajectoryClient.GetAimDirection(rootPart: BasePart?): Vector3
	local camera = workspace.CurrentCamera
	local direction = if camera then camera.CFrame.LookVector else Vector3.new(0, 0.1, -1)
	return BombTrajectoryClient.SanitizeAimDirection(direction, BombTrajectoryClient.GetFallbackAimDirection(rootPart))
end

function BombTrajectoryClient.GetMouseAimDirection(rootPart: BasePart?): Vector3
	if isTouchAimPreferred() then
		return BombTrajectoryClient.GetAimDirection(rootPart)
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return BombTrajectoryClient.GetAimDirection(rootPart)
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	return BombTrajectoryClient.SanitizeAimDirection(ray.Direction, BombTrajectoryClient.GetFallbackAimDirection(rootPart))
end

function BombTrajectoryClient.GetThrowOrigin(rootPart: BasePart): Vector3
	return BombLaunchClearance.ResolveOrigin(rootPart, BombThrowOrigin.GetOrigin(rootPart), {
		character = rootPart:FindFirstAncestorOfClass("Model"),
		radius = BombConfig.SweepRadius,
		collisionGroup = BOMB_PROJECTILE_COLLISION_GROUP,
		respectCanCollide = true,
		ignoreWater = true,
	})
end

function BombTrajectoryClient.CalculateTrajectoryWithConfig(
	origin: Vector3,
	aimDirection: Vector3,
	launchSpeed: number,
	upwardVelocity: number,
	gravity: number,
	maxFlightSeconds: number
)
	return BombTrajectory.CreatePath(
		origin,
		aimDirection,
		launchSpeed,
		upwardVelocity,
		gravity,
		maxFlightSeconds
	)
end

function BombTrajectoryClient.CalculateTrajectory(origin: Vector3, aimDirection: Vector3)
	return BombTrajectoryClient.CalculateTrajectoryWithConfig(
		origin,
		aimDirection,
		BombConfig.ProjectileLaunchSpeed,
		BombConfig.ProjectileUpwardVelocity,
		workspace.Gravity * BombConfig.ProjectileGravityScale,
		BombConfig.ProjectileMaxFlightSeconds
	)
end

local function createPreviewSweepParams(character: Model?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if character then { character } else {}
	params.IgnoreWater = true
	local collisionGroupSet = pcall(function()
		params.CollisionGroup = BOMB_PROJECTILE_COLLISION_GROUP
	end)
	if not collisionGroupSet then
		pcall(function()
			params.CollisionGroup = "Default"
		end)
	end
	params.RespectCanCollide = true
	return params
end

local function sweepPreviewSegment(fromPosition: Vector3, toPosition: Vector3, params: RaycastParams): RaycastResult?
	local direction = toPosition - fromPosition
	if direction.Magnitude <= 0.001 then
		return nil
	end

	local spherecastOk, spherecastResult = pcall(function()
		return workspace:Spherecast(fromPosition, BombConfig.SweepRadius, direction, params)
	end)
	if spherecastOk then
		return spherecastResult
	end

	return workspace:Raycast(fromPosition, direction, params)
end

function BombTrajectoryClient.FindPreviewTrajectoryHit(
	path: BombTrajectory.Path,
	maxPreviewTime: number,
	character: Model?
): (RaycastResult?, number, Vector3?)
	local stepSeconds = if typeof(BombConfig.PreviewStepSeconds) == "number"
		then math.max(BombConfig.PreviewStepSeconds, 1 / 60)
		else 0.08
	local minVisibleSeconds = if typeof(BombConfig.PreviewMinVisibleSeconds) == "number"
		then math.max(BombConfig.PreviewMinVisibleSeconds, 0)
		else 0
	local segmentCount = math.max(1, math.ceil(maxPreviewTime / stepSeconds))
	local params = createPreviewSweepParams(character)

	local previousElapsed = 0
	local previousPosition = BombTrajectory.Evaluate(path, 0)

	for index = 1, segmentCount do
		local elapsed = maxPreviewTime * (index / segmentCount)
		local position = BombTrajectory.Evaluate(path, elapsed / path.duration)
		local hit = sweepPreviewSegment(previousPosition, position, params)
		if hit then
			local segmentLength = (position - previousPosition).Magnitude
			local segmentAlpha = if segmentLength > 0.001
				then math.clamp(hit.Distance / segmentLength, 0, 1)
				else 0
			local hitElapsed = previousElapsed + (elapsed - previousElapsed) * segmentAlpha
			if minVisibleSeconds > 0 and hitElapsed < minVisibleSeconds then
				local displayElapsed = math.min(maxPreviewTime, math.max(minVisibleSeconds, elapsed))
				local displayAlpha = math.clamp(displayElapsed / path.duration, 0, 1)
				return hit, displayElapsed, BombTrajectory.Evaluate(path, displayAlpha)
			end
			return hit, hitElapsed, nil
		end

		previousElapsed = elapsed
		previousPosition = position
	end

	return nil, maxPreviewTime
end

return BombTrajectoryClient
