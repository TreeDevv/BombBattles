local MovementMath = {}

function MovementMath.FlattenDirection(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local magnitude = flat.Magnitude
	if magnitude <= 0 then
		return Vector3.zero
	end
	return flat / magnitude
end

function MovementMath.FlattenVelocity(velocity: Vector3): Vector3
	return Vector3.new(velocity.X, 0, velocity.Z)
end

function MovementMath.DirectionToYaw(direction: Vector3): number?
	local flat = MovementMath.FlattenDirection(direction)
	if flat.Magnitude <= 0 then
		return nil
	end

	return math.atan2(-flat.X, -flat.Z)
end

function MovementMath.YawToDirection(yaw: number): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

function MovementMath.ExponentialAlpha(responsiveness: number, dt: number): number
	return 1 - math.exp(-responsiveness * dt)
end

function MovementMath.Smoothstep(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * (3 - (2 * alpha))
end

function MovementMath.SmoothVector(current: Vector3, target: Vector3, responsiveness: number, dt: number): Vector3
	return current:Lerp(target, MovementMath.ExponentialAlpha(responsiveness, dt))
end

function MovementMath.SmoothYaw(current: number, target: number, responsiveness: number, dt: number): number
	local delta = math.atan2(math.sin(target - current), math.cos(target - current))
	return current + (delta * MovementMath.ExponentialAlpha(responsiveness, dt))
end

return MovementMath
