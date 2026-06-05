local ProjectilePhysics = {}

local EPSILON = 1e-4
local IMPACT_RESPONSE = table.freeze({
	Bounce = "Bounce",
	Sandbag = "Sandbag",
})

ProjectilePhysics.ImpactResponse = IMPACT_RESPONSE

export type PhysicsConfig = {
	radius: number,
	gravity: number,
	postImpactGravity: number,
	launchSpeed: number,
	upwardVelocity: number,
	maxSpeed: number,
	impactResponse: string,
	restitution: number,
	friction: number,
	wallFriction: number,
	floorNormalY: number,
	settleNormalY: number,
	settleSpeed: number,
	settleHorizontalSpeed: number,
	minBounceSpeed: number,
	sandbagHorizontalScale: number,
	sandbagMaxHorizontalSpeed: number,
	sandbagDownwardVelocity: number,
	surfaceOffset: number,
	groundedFrictionPerSecond: number,
	minRollSpeed: number,
	maxCollisionsPerStep: number,
}

export type ProjectileState = {
	position: Vector3,
	velocity: Vector3,
	settled: boolean?,
	hasImpacted: boolean?,
	grounded: boolean?,
}

export type StepResult = {
	position: Vector3,
	velocity: Vector3,
	settled: boolean,
	hit: RaycastResult?,
	hitPosition: Vector3?,
	hitNormal: Vector3?,
	incomingVelocity: Vector3?,
	hasImpacted: boolean?,
	grounded: boolean?,
}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteVector(value: any): boolean
	return typeof(value) == "Vector3"
		and value.X == value.X
		and value.Y == value.Y
		and value.Z == value.Z
		and value.Magnitude < math.huge
end

local function readNumber(source, key: string, fallback: number, minimum: number?, maximum: number?): number
	local value = if typeof(source) == "table" then source[key] else nil
	if not isFiniteNumber(value) then
		value = fallback
	end
	if isFiniteNumber(minimum) then
		value = math.max(value, minimum :: number)
	end
	if isFiniteNumber(maximum) then
		value = math.min(value, maximum :: number)
	end
	return value
end

local function readImpactResponse(source, key: string, fallback: string): string
	local value = if typeof(source) == "table" then source[key] else nil
	if value == IMPACT_RESPONSE.Sandbag or value == IMPACT_RESPONSE.Bounce then
		return value
	end
	return fallback
end

local function getNormal(normal: Vector3?): Vector3
	if isFiniteVector(normal) and normal.Magnitude > EPSILON then
		return normal.Unit
	end
	return Vector3.yAxis
end

function ProjectilePhysics.IsFiniteVector(value: any): boolean
	return isFiniteVector(value)
end

function ProjectilePhysics.ResolvePhysicsConfig(defaults, override): PhysicsConfig
	local fallbackImpactResponse = readImpactResponse(defaults, "impactResponse", IMPACT_RESPONSE.Bounce)
	local fallbackGravity = readNumber(defaults, "gravity", workspace.Gravity, 0, 10000)
	local fallbackPostImpactGravity = readNumber(defaults, "postImpactGravity", fallbackGravity, 0, 10000)
	return {
		radius = readNumber(override, "radius", readNumber(defaults, "radius", 0.8, 0.01, 256), 0.01, 256),
		gravity = readNumber(override, "gravity", fallbackGravity, 0, 10000),
		postImpactGravity = readNumber(override, "postImpactGravity", fallbackPostImpactGravity, 0, 10000),
		launchSpeed = readNumber(override, "launchSpeed", readNumber(defaults, "launchSpeed", 80, 0, 10000), 0, 10000),
		upwardVelocity = readNumber(override, "upwardVelocity", readNumber(defaults, "upwardVelocity", 0, -10000, 10000), -10000, 10000),
		maxSpeed = readNumber(override, "maxSpeed", readNumber(defaults, "maxSpeed", 200, 1, 10000), 1, 10000),
		impactResponse = readImpactResponse(override, "impactResponse", fallbackImpactResponse),
		restitution = readNumber(override, "restitution", readNumber(defaults, "restitution", 0.4, 0, 2), 0, 2),
		friction = readNumber(override, "friction", readNumber(defaults, "friction", 0.15, 0, 1), 0, 1),
		wallFriction = readNumber(override, "wallFriction", readNumber(defaults, "wallFriction", 0.08, 0, 1), 0, 1),
		floorNormalY = readNumber(override, "floorNormalY", readNumber(defaults, "floorNormalY", 0.58, -1, 1), -1, 1),
		settleNormalY = readNumber(override, "settleNormalY", readNumber(defaults, "settleNormalY", 0.68, -1, 1), -1, 1),
		settleSpeed = readNumber(override, "settleSpeed", readNumber(defaults, "settleSpeed", 9, 0, 10000), 0, 10000),
		settleHorizontalSpeed = readNumber(override, "settleHorizontalSpeed", readNumber(defaults, "settleHorizontalSpeed", 7, 0, 10000), 0, 10000),
		minBounceSpeed = readNumber(override, "minBounceSpeed", readNumber(defaults, "minBounceSpeed", 3, 0, 10000), 0, 10000),
		sandbagHorizontalScale = readNumber(override, "sandbagHorizontalScale", readNumber(defaults, "sandbagHorizontalScale", 0.2, 0, 1), 0, 1),
		sandbagMaxHorizontalSpeed = readNumber(override, "sandbagMaxHorizontalSpeed", readNumber(defaults, "sandbagMaxHorizontalSpeed", 16, 0, 10000), 0, 10000),
		sandbagDownwardVelocity = readNumber(override, "sandbagDownwardVelocity", readNumber(defaults, "sandbagDownwardVelocity", 18, 0, 10000), 0, 10000),
		surfaceOffset = readNumber(override, "surfaceOffset", readNumber(defaults, "surfaceOffset", 0.035, 0, 4), 0, 4),
		groundedFrictionPerSecond = readNumber(override, "groundedFrictionPerSecond", readNumber(defaults, "groundedFrictionPerSecond", 1.1, 0, 100), 0, 100),
		minRollSpeed = readNumber(override, "minRollSpeed", readNumber(defaults, "minRollSpeed", 1.25, 0, 10000), 0, 10000),
		maxCollisionsPerStep = math.floor(readNumber(override, "maxCollisionsPerStep", readNumber(defaults, "maxCollisionsPerStep", 3, 1, 12), 1, 12)),
	}
end

function ProjectilePhysics.GetGravity(physics: PhysicsConfig, hasImpacted: boolean?): number
	if hasImpacted == true then
		return physics.postImpactGravity
	end
	return physics.gravity
end

function ProjectilePhysics.GetLaunchVelocity(aimDirection: Vector3, physics: PhysicsConfig): Vector3
	local direction = if isFiniteVector(aimDirection) and aimDirection.Magnitude > EPSILON then aimDirection.Unit else Vector3.zAxis
	return ProjectilePhysics.ClampVelocity(direction * physics.launchSpeed + Vector3.yAxis * physics.upwardVelocity, physics.maxSpeed)
end

function ProjectilePhysics.ClampVelocity(velocity: Vector3, maxSpeed: number): Vector3
	if not isFiniteVector(velocity) then
		return Vector3.zero
	end
	if velocity.Magnitude <= maxSpeed then
		return velocity
	end
	return velocity.Unit * maxSpeed
end

function ProjectilePhysics.Integrate(position: Vector3, velocity: Vector3, dt: number, physics: PhysicsConfig, hasImpacted: boolean?): (Vector3, Vector3)
	local acceleration = Vector3.new(0, -ProjectilePhysics.GetGravity(physics, hasImpacted), 0)
	local nextPosition = position + velocity * dt + acceleration * (0.5 * dt * dt)
	local nextVelocity = ProjectilePhysics.ClampVelocity(velocity + acceleration * dt, physics.maxSpeed)
	return nextPosition, nextVelocity
end

function ProjectilePhysics.Cast(position: Vector3, radius: number, movement: Vector3, params: RaycastParams): RaycastResult?
	if movement.Magnitude <= EPSILON then
		return nil
	end

	local ok, result = pcall(function()
		return workspace:Spherecast(position, radius, movement, params)
	end)
	if ok then
		return result
	end

	return workspace:Raycast(position, movement, params)
end

local function recoverFloorContact(position: Vector3, physics: PhysicsConfig, params: RaycastParams): (Vector3, RaycastResult?, Vector3?)
	local radius = math.max(physics.radius, 0)
	if radius <= EPSILON then
		return position, nil, nil
	end

	local skin = math.max(physics.surfaceOffset, 0)
	local probeUp = math.max(radius * 0.25, skin + 0.05)
	local desiredDistance = radius + skin
	local rayOrigin = position + Vector3.yAxis * probeUp
	local rayDirection = Vector3.yAxis * -(desiredDistance + probeUp)
	local hit = workspace:Raycast(rayOrigin, rayDirection, params)
	if not hit then
		return position, nil, nil
	end

	local normal = getNormal(hit.Normal)
	if normal.Y < physics.floorNormalY then
		return position, nil, nil
	end

	local distanceFromSurface = (position - hit.Position):Dot(normal)
	if distanceFromSurface > desiredDistance + skin then
		return position, nil, nil
	end

	return position + normal * math.max(desiredDistance - distanceFromSurface, 0), hit, normal
end

local function projectOntoPlane(vector: Vector3, normal: Vector3): Vector3
	return vector - normal * vector:Dot(normal)
end

local function applyGroundedFriction(velocity: Vector3, dt: number, physics: PhysicsConfig): Vector3
	if velocity.Magnitude <= physics.minRollSpeed then
		return Vector3.zero
	end

	local frictionAlpha = math.clamp(physics.groundedFrictionPerSecond * dt, 0, 1)
	local speed = velocity.Magnitude * (1 - frictionAlpha)
	if speed <= physics.minRollSpeed then
		return Vector3.zero
	end

	return velocity.Unit * speed
end

local function stepGrounded(position: Vector3, velocity: Vector3, dt: number, physics: PhysicsConfig, params: RaycastParams): StepResult?
	local contactPosition, contactHit, contactNormal = recoverFloorContact(position, physics, params)
	if not (contactHit and contactNormal) then
		return nil
	end

	local floorVelocity = projectOntoPlane(velocity, contactNormal)
	if floorVelocity.Magnitude <= physics.minRollSpeed then
		return {
			position = contactPosition,
			velocity = Vector3.zero,
			settled = true,
			hit = contactHit,
			hitPosition = contactPosition,
			hitNormal = contactNormal,
			incomingVelocity = velocity,
			hasImpacted = true,
			grounded = true,
		}
	end

	floorVelocity = applyGroundedFriction(floorVelocity, dt, physics)
	if floorVelocity.Magnitude <= EPSILON then
		return {
			position = contactPosition,
			velocity = Vector3.zero,
			settled = true,
			hit = contactHit,
			hitPosition = contactPosition,
			hitNormal = contactNormal,
			incomingVelocity = velocity,
			hasImpacted = true,
			grounded = true,
		}
	end

	local nextPosition = contactPosition + floorVelocity * dt
	local movement = nextPosition - contactPosition
	if movement.Magnitude > EPSILON then
		local hit = ProjectilePhysics.Cast(contactPosition, physics.radius, movement, params)
		if hit then
			local normal = getNormal(hit.Normal)
			local incomingVelocity = floorVelocity
			local impactVelocity = ProjectilePhysics.GetImpactVelocity(incomingVelocity, normal, physics)
			local recoveredPosition = contactPosition + movement.Unit * math.max(hit.Distance, 0)

			if normal.Y >= physics.floorNormalY then
				recoveredPosition = recoverFloorContact(recoveredPosition, physics, params)
				impactVelocity = projectOntoPlane(floorVelocity, normal)
				return {
					position = recoveredPosition,
					velocity = applyGroundedFriction(impactVelocity, dt, physics),
					settled = false,
					hit = hit,
					hitPosition = recoveredPosition,
					hitNormal = normal,
					incomingVelocity = incomingVelocity,
					hasImpacted = true,
					grounded = true,
				}
			end

			return {
				position = recoveredPosition + normal * physics.surfaceOffset,
				velocity = impactVelocity,
				settled = impactVelocity.Magnitude <= EPSILON,
				hit = hit,
				hitPosition = recoveredPosition,
				hitNormal = normal,
				incomingVelocity = incomingVelocity,
				hasImpacted = true,
				grounded = false,
			}
		end
	end

	local recoveredPosition, recoveryHit, recoveryNormal = recoverFloorContact(nextPosition, physics, params)
	if recoveryHit and recoveryNormal then
		return {
			position = recoveredPosition,
			velocity = floorVelocity,
			settled = false,
			hit = nil,
			hitPosition = nil,
			hitNormal = nil,
			incomingVelocity = nil,
			hasImpacted = true,
			grounded = true,
		}
	end

	return {
		position = nextPosition,
		velocity = floorVelocity,
		settled = false,
		hit = nil,
		hitPosition = nil,
		hitNormal = nil,
		incomingVelocity = nil,
		hasImpacted = true,
		grounded = false,
	}
end

function ProjectilePhysics.GetBounceVelocity(velocity: Vector3, normal: Vector3, physics: PhysicsConfig): Vector3
	if not isFiniteVector(velocity) or velocity.Magnitude <= EPSILON then
		return Vector3.zero
	end

	local unitNormal = getNormal(normal)
	local normalComponent = unitNormal * velocity:Dot(unitNormal)
	local tangentComponent = velocity - normalComponent
	local friction = if unitNormal.Y >= physics.floorNormalY then physics.friction else physics.wallFriction
	local bouncedVelocity = tangentComponent * math.max(1 - friction, 0) - normalComponent * physics.restitution
	if bouncedVelocity.Magnitude < physics.minBounceSpeed then
		return Vector3.zero
	end

	return ProjectilePhysics.ClampVelocity(bouncedVelocity, physics.maxSpeed)
end

function ProjectilePhysics.GetSandbagVelocity(velocity: Vector3, normal: Vector3, physics: PhysicsConfig): Vector3
	if not isFiniteVector(velocity) or velocity.Magnitude <= EPSILON then
		return Vector3.zero
	end

	local unitNormal = getNormal(normal)
	local tangentComponent = velocity - unitNormal * velocity:Dot(unitNormal)
	local horizontalVelocity = Vector3.new(tangentComponent.X, 0, tangentComponent.Z) * physics.sandbagHorizontalScale
	if horizontalVelocity.Magnitude > physics.sandbagMaxHorizontalSpeed then
		horizontalVelocity = horizontalVelocity.Unit * physics.sandbagMaxHorizontalSpeed
	end

	local verticalVelocity = 0
	if unitNormal.Y < physics.floorNormalY then
		verticalVelocity = math.min(velocity.Y, -physics.sandbagDownwardVelocity)
	end

	local sandbagVelocity = horizontalVelocity + Vector3.yAxis * verticalVelocity
	if sandbagVelocity.Magnitude < physics.minBounceSpeed then
		return Vector3.zero
	end
	return ProjectilePhysics.ClampVelocity(sandbagVelocity, physics.maxSpeed)
end

function ProjectilePhysics.GetImpactVelocity(velocity: Vector3, normal: Vector3, physics: PhysicsConfig): Vector3
	if physics.impactResponse == IMPACT_RESPONSE.Sandbag then
		return ProjectilePhysics.GetSandbagVelocity(velocity, normal, physics)
	end
	return ProjectilePhysics.GetBounceVelocity(velocity, normal, physics)
end

function ProjectilePhysics.ShouldSettle(incomingVelocity: Vector3, bouncedVelocity: Vector3, normal: Vector3, physics: PhysicsConfig): boolean
	local unitNormal = getNormal(normal)
	if unitNormal.Y < physics.settleNormalY then
		return false
	end

	local normalSpeed = math.abs(incomingVelocity:Dot(unitNormal))
	local horizontalVelocity = Vector3.new(bouncedVelocity.X, 0, bouncedVelocity.Z)
	return normalSpeed <= physics.settleSpeed and horizontalVelocity.Magnitude <= physics.settleHorizontalSpeed
end

function ProjectilePhysics.Step(state: ProjectileState, dt: number, physics: PhysicsConfig, params: RaycastParams): StepResult
	if state.settled then
		local position = recoverFloorContact(state.position, physics, params)
		return {
			position = position,
			velocity = Vector3.zero,
			settled = true,
			grounded = true,
		}
	end

	local position = state.position
	local velocity = state.velocity
	local remainingDt = math.max(dt, 0)
	local lastHit: RaycastResult? = nil
	local lastHitPosition: Vector3? = nil
	local lastHitNormal: Vector3? = nil
	local lastIncomingVelocity: Vector3? = nil
	local settled = false
	local hasImpacted = state.hasImpacted == true
	local grounded = state.grounded == true

	if grounded then
		local groundedResult = stepGrounded(position, velocity, remainingDt, physics, params)
		if groundedResult then
			return groundedResult
		end
		grounded = false
	end

	for _ = 1, physics.maxCollisionsPerStep do
		if remainingDt <= EPSILON then
			break
		end

		local nextPosition, nextVelocity = ProjectilePhysics.Integrate(position, velocity, remainingDt, physics, hasImpacted)
		local movement = nextPosition - position
		if movement.Magnitude <= EPSILON then
			position = nextPosition
			velocity = nextVelocity
			break
		end

		local hit = ProjectilePhysics.Cast(position, physics.radius, movement, params)
		if not hit then
			local recoveredPosition, recoveryHit, recoveryNormal = recoverFloorContact(nextPosition, physics, params)
			if recoveryHit and recoveryNormal then
				local impactVelocity = ProjectilePhysics.GetImpactVelocity(nextVelocity, recoveryNormal, physics)

				lastHit = recoveryHit
				lastHitPosition = recoveredPosition
				lastHitNormal = recoveryNormal
				lastIncomingVelocity = nextVelocity
				position = recoveredPosition
				hasImpacted = true

				if recoveryNormal.Y >= physics.floorNormalY then
					grounded = impactVelocity.Magnitude > physics.minRollSpeed
					settled = not grounded
					velocity = if settled then Vector3.zero else impactVelocity
				elseif ProjectilePhysics.ShouldSettle(nextVelocity, impactVelocity, recoveryNormal, physics) then
					velocity = Vector3.zero
					settled = true
				else
					velocity = impactVelocity
					settled = impactVelocity.Magnitude <= EPSILON
				end
			else
				position = nextPosition
				velocity = nextVelocity
			end
			break
		end

		local alpha = math.clamp(hit.Distance / math.max(movement.Magnitude, EPSILON), 0, 1)
		local hitDt = remainingDt * alpha
		local gravity = ProjectilePhysics.GetGravity(physics, hasImpacted)
		local incomingVelocity = ProjectilePhysics.ClampVelocity(velocity + Vector3.new(0, -gravity, 0) * hitDt, physics.maxSpeed)
		local normal = getNormal(hit.Normal)
		local centerAtHit = position + movement.Unit * math.max(hit.Distance, 0)
		local impactVelocity = ProjectilePhysics.GetImpactVelocity(incomingVelocity, normal, physics)

		lastHit = hit
		lastHitPosition = centerAtHit
		lastHitNormal = normal
		lastIncomingVelocity = incomingVelocity
		position = centerAtHit + normal * physics.surfaceOffset
		position = recoverFloorContact(position, physics, params)
		hasImpacted = true

		if normal.Y >= physics.floorNormalY then
			grounded = impactVelocity.Magnitude > physics.minRollSpeed
			if grounded then
				velocity = impactVelocity
			else
				velocity = Vector3.zero
				settled = true
			end
			break
		elseif ProjectilePhysics.ShouldSettle(incomingVelocity, impactVelocity, normal, physics) then
			velocity = Vector3.zero
			settled = true
			break
		else
			velocity = impactVelocity
		end
		remainingDt *= 1 - alpha
		if velocity.Magnitude <= EPSILON then
			settled = normal.Y >= physics.settleNormalY
			break
		end
	end

	return {
		position = position,
		velocity = velocity,
		settled = settled,
		hit = lastHit,
		hitPosition = lastHitPosition,
		hitNormal = lastHitNormal,
		incomingVelocity = lastIncomingVelocity,
		hasImpacted = hasImpacted,
		grounded = grounded,
	}
end

return table.freeze(ProjectilePhysics)
