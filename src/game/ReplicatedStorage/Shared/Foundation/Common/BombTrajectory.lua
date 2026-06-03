local BombTrajectory = {}

local EPSILON = 1e-4
local MIN_DURATION = 0.12

export type Path = {
	origin: Vector3,
	initialVelocity: Vector3,
	acceleration: Vector3,
	duration: number,
}

local function isFiniteVector(value: any): boolean
	return typeof(value) == "Vector3"
		and value.X == value.X
		and value.Y == value.Y
		and value.Z == value.Z
		and value.Magnitude < math.huge
end

function BombTrajectory.CreatePath(
	origin: Vector3,
	aimDirection: Vector3,
	launchSpeed: number,
	upwardVelocity: number,
	gravityAcceleration: number,
	maxDuration: number
): Path
	assert(isFiniteVector(origin), "BombTrajectory.CreatePath requires a finite origin")
	assert(isFiniteVector(aimDirection), "BombTrajectory.CreatePath requires a finite aimDirection")

	launchSpeed = math.max(launchSpeed or 0, EPSILON)
	upwardVelocity = math.max(upwardVelocity or 0, 0)
	gravityAcceleration = math.max(gravityAcceleration or workspace.Gravity, EPSILON)
	maxDuration = math.max(maxDuration or MIN_DURATION, MIN_DURATION)

	local direction = if aimDirection.Magnitude > EPSILON then aimDirection.Unit else Vector3.zAxis
	local initialVelocity = direction * launchSpeed + Vector3.yAxis * upwardVelocity
	local acceleration = Vector3.new(0, -gravityAcceleration, 0)

	return {
		origin = origin,
		initialVelocity = initialVelocity,
		acceleration = acceleration,
		duration = maxDuration,
	}
end

function BombTrajectory.FromPayload(payload): Path?
	if typeof(payload) ~= "table" then
		return nil
	end
	if not (
		isFiniteVector(payload.origin)
		and isFiniteVector(payload.initialVelocity)
		and isFiniteVector(payload.acceleration)
		and typeof(payload.duration) == "number"
	) then
		return nil
	end

	return {
		origin = payload.origin,
		initialVelocity = payload.initialVelocity,
		acceleration = payload.acceleration,
		duration = math.max(payload.duration, MIN_DURATION),
	}
end

function BombTrajectory.Evaluate(path: Path, alpha: number): Vector3
	alpha = math.clamp(alpha, 0, 1)
	local elapsed = path.duration * alpha
	return path.origin + path.initialVelocity * elapsed + path.acceleration * (0.5 * elapsed * elapsed)
end

function BombTrajectory.GetTangent(path: Path, alpha: number): Vector3
	alpha = math.clamp(alpha, 0, 1)
	local elapsed = path.duration * alpha
	local velocity = path.initialVelocity + path.acceleration * elapsed
	if velocity.Magnitude < EPSILON then
		return Vector3.zAxis
	end

	return velocity.Unit
end

function BombTrajectory.GetVelocity(path: Path, alpha: number): Vector3
	alpha = math.clamp(alpha, 0, 1)
	local elapsed = path.duration * alpha
	return path.initialVelocity + path.acceleration * elapsed
end

function BombTrajectory.IsFiniteVector(value: any): boolean
	return isFiniteVector(value)
end

return table.freeze(BombTrajectory)
