local BombTrajectory = {}

local EPSILON = 1e-4
local MIN_DURATION = 0.12

export type Path = {
	origin: Vector3,
	targetPosition: Vector3,
	controlPoint: Vector3,
	duration: number,
	resolvedTargetPosition: Vector3,
}

local function isFiniteVector(value: any): boolean
	return typeof(value) == "Vector3"
		and value.X == value.X
		and value.Y == value.Y
		and value.Z == value.Z
		and value.Magnitude < math.huge
end

local function projectHorizontalDirection(origin: Vector3, targetPosition: Vector3): Vector3?
	local displacement = targetPosition - origin
	local horizontal = Vector3.new(displacement.X, 0, displacement.Z)
	if horizontal.Magnitude <= EPSILON then
		return nil
	end

	return horizontal.Unit
end

function BombTrajectory.ResolveLandingTarget(
	origin: Vector3,
	targetPosition: Vector3,
	useDirectTarget: boolean,
	resolveUp: number,
	resolveDown: number,
	noHitFallbackDistance: number,
	raycast: (Vector3, Vector3) -> RaycastResult?
): (Vector3, boolean)
	assert(isFiniteVector(origin), "BombTrajectory.ResolveLandingTarget requires a finite origin")
	assert(isFiniteVector(targetPosition), "BombTrajectory.ResolveLandingTarget requires a finite targetPosition")

	resolveUp = math.max(resolveUp or 0, 0)
	resolveDown = math.max(resolveDown or 0, 0)
	noHitFallbackDistance = math.max(noHitFallbackDistance or 0, 0)

	if useDirectTarget then
		return targetPosition, true
	end

	local rayOrigin = targetPosition + Vector3.yAxis * resolveUp
	local rayDirection = Vector3.new(0, -(resolveUp + resolveDown), 0)
	local hit = raycast(rayOrigin, rayDirection)
	if hit then
		return hit.Position, true
	end

	local horizontalDirection = projectHorizontalDirection(origin, targetPosition)
		or projectHorizontalDirection(origin, origin + Vector3.zAxis)
		or Vector3.zAxis
	local fallbackTarget = origin + horizontalDirection * noHitFallbackDistance
	local fallbackRayOrigin = fallbackTarget + Vector3.yAxis * resolveUp
	local fallbackHit = raycast(fallbackRayOrigin, rayDirection)
	if fallbackHit then
		return fallbackHit.Position, true
	end

	return origin + horizontalDirection * math.max(noHitFallbackDistance, EPSILON), false
end

function BombTrajectory.CreatePath(
	origin: Vector3,
	targetPosition: Vector3,
	travelSpeed: number,
	arcHeightMin: number,
	arcHeightPerStud: number,
	arcHeightMax: number
): Path
	assert(isFiniteVector(origin), "BombTrajectory.CreatePath requires a finite origin")
	assert(isFiniteVector(targetPosition), "BombTrajectory.CreatePath requires a finite targetPosition")

	travelSpeed = math.max(travelSpeed, EPSILON)
	arcHeightMin = math.max(arcHeightMin or 0, 0)
	arcHeightPerStud = math.max(arcHeightPerStud or 0, 0)
	arcHeightMax = math.max(arcHeightMax or arcHeightMin, arcHeightMin)

	local resolvedTargetPosition = targetPosition
	local displacement = resolvedTargetPosition - origin
	local horizontalDistance = Vector3.new(displacement.X, 0, displacement.Z).Magnitude
	local arcHeight = math.clamp(arcHeightMin + horizontalDistance * arcHeightPerStud, arcHeightMin, arcHeightMax)
	local midpoint = origin:Lerp(resolvedTargetPosition, 0.5)
	local controlPoint = Vector3.new(midpoint.X, math.max(origin.Y, resolvedTargetPosition.Y) + arcHeight, midpoint.Z)
	local duration = math.max(displacement.Magnitude / travelSpeed, MIN_DURATION)

	return {
		origin = origin,
		targetPosition = targetPosition,
		controlPoint = controlPoint,
		duration = duration,
		resolvedTargetPosition = resolvedTargetPosition,
	}
end

function BombTrajectory.FromPayload(payload): Path?
	if typeof(payload) ~= "table" then
		return nil
	end
	local resolvedTargetPosition = if isFiniteVector(payload.resolvedTargetPosition) then payload.resolvedTargetPosition else payload.targetPosition
	if not (
		isFiniteVector(payload.origin)
		and isFiniteVector(payload.targetPosition)
		and isFiniteVector(payload.controlPoint)
		and isFiniteVector(resolvedTargetPosition)
		and typeof(payload.duration) == "number"
	) then
		return nil
	end

	return {
		origin = payload.origin,
		targetPosition = payload.targetPosition,
		controlPoint = payload.controlPoint,
		duration = math.max(payload.duration, MIN_DURATION),
		resolvedTargetPosition = resolvedTargetPosition,
	}
end

function BombTrajectory.Evaluate(path: Path, alpha: number): Vector3
	alpha = math.clamp(alpha, 0, 1)
	local inverse = 1 - alpha
	return path.origin * (inverse * inverse)
		+ path.controlPoint * (2 * inverse * alpha)
		+ path.resolvedTargetPosition * (alpha * alpha)
end

function BombTrajectory.GetTangent(path: Path, alpha: number): Vector3
	alpha = math.clamp(alpha, 0, 1)
	local tangent = (path.controlPoint - path.origin) * (2 * (1 - alpha))
		+ (path.resolvedTargetPosition - path.controlPoint) * (2 * alpha)
	if tangent.Magnitude < EPSILON then
		local fallback = path.resolvedTargetPosition - path.origin
		return if fallback.Magnitude > EPSILON then fallback.Unit else Vector3.zAxis
	end

	return tangent.Unit
end

function BombTrajectory.GetVelocity(path: Path, alpha: number): Vector3
	alpha = math.clamp(alpha, 0, 1)
	local derivative = (path.controlPoint - path.origin) * (2 * (1 - alpha))
		+ (path.resolvedTargetPosition - path.controlPoint) * (2 * alpha)
	return derivative / math.max(path.duration, MIN_DURATION)
end

function BombTrajectory.IsFiniteVector(value: any): boolean
	return isFiniteVector(value)
end

return table.freeze(BombTrajectory)
