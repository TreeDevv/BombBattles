local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombProjectileVisualMotion = require(ReplicatedStorage.Shared.Effects.BombProjectileVisualMotion)

local BombProjectileVisualState = {}

function BombProjectileVisualState.ApplyLaunch(visual, payload, startPosition: Vector3, startedAt: number, reusePredicted: boolean)
	visual.customProjectile = payload.customProjectile == true
	visual.visuals = if typeof(payload.visuals) == "table" then payload.visuals else nil
	visual.visualScale = if typeof(payload.visualScale) == "number" then math.max(payload.visualScale, 0.05) else visual.visualScale

	if not visual.customProjectile then
		return
	end

	local velocity = if typeof(payload.velocity) == "Vector3" then payload.velocity else payload.initialVelocity
	local acceleration = if typeof(payload.acceleration) == "Vector3" then payload.acceleration else Vector3.new(0, -workspace.Gravity, 0)
	local resolvedVelocity = if typeof(velocity) == "Vector3" then velocity else Vector3.zero
	if reusePredicted then
		visual.targetPosition = startPosition
		visual.targetVelocity = resolvedVelocity
		visual.targetAcceleration = acceleration
		visual.targetUpdatedAt = startedAt
	else
		visual.position = startPosition
		visual.velocity = resolvedVelocity
		visual.targetPosition = visual.position
		visual.targetVelocity = visual.velocity
		visual.targetAcceleration = acceleration
		visual.targetUpdatedAt = startedAt
	end
	visual.acceleration = acceleration
	visual.settled = false
end

function BombProjectileVisualState.ApplySnapshot(visual, payload, now: number)
	visual.customProjectile = true
	local wasFrozen = visual.frozen == true
	local frozen = payload.frozen == true
	local timeScale = math.clamp(if typeof(payload.timeScale) == "number" then payload.timeScale else 1, 0.005, 1)
	visual.burrowing = payload.burrowing == true
	visual.frozen = frozen
	visual.frozenUntil = if typeof(payload.frozenUntil) == "number" then payload.frozenUntil else nil
	visual.targetTimeScale = timeScale

	local targetAcceleration = if typeof(payload.acceleration) == "Vector3" and not frozen
		then payload.acceleration
		else Vector3.zero
	local targetVelocity = if frozen then Vector3.zero elseif typeof(payload.velocity) == "Vector3" then payload.velocity else Vector3.zero
	local snapshotTime = if typeof(payload.serverTime) == "number" then payload.serverTime else now
	local agedPosition = payload.position
	local agedVelocity = targetVelocity
	if not (frozen or payload.settled == true or payload.attached == true) then
		agedPosition, agedVelocity = BombProjectileVisualMotion.AdvanceMotion(
			payload.position,
			targetVelocity,
			targetAcceleration,
			now - snapshotTime
		)
	end

	visual.targetPosition = agedPosition
	visual.targetVelocity = agedVelocity
	visual.targetAcceleration = targetAcceleration
	visual.targetUpdatedAt = now
	if payload.attached == true then
		visual.spinLocked = true
	elseif frozen then
		visual.spinLocked = true
	elseif wasFrozen then
		visual.spinLocked = false
	end
	if typeof(payload.acceleration) == "Vector3" then
		visual.acceleration = if frozen then Vector3.zero else payload.acceleration
	end
	visual.settled = frozen or payload.settled == true
	if visual.position == nil or visual.settled or frozen then
		visual.position = payload.position
	end
	if visual.velocity == nil or visual.settled or frozen then
		visual.velocity = visual.targetVelocity
	end
	if wasFrozen and not frozen and typeof(payload.serverTime) == "number" and typeof(payload.remainingFuse) == "number" then
		visual.fuseStartedAt = payload.serverTime
		visual.fuseEndsAt = payload.serverTime + math.max(payload.remainingFuse, 0)
	end
end

function BombProjectileVisualState.ApplyAttach(visual, payload)
	visual.customProjectile = true
	visual.targetPosition = payload.position
	visual.targetVelocity = Vector3.zero
	visual.position = payload.position
	visual.velocity = Vector3.zero
	visual.acceleration = Vector3.zero
	visual.settled = true
	visual.spinLocked = true
end

function BombProjectileVisualState.ApplySettle(visual, position: Vector3)
	visual.customProjectile = true
	visual.targetPosition = position
	visual.targetVelocity = Vector3.zero
	visual.position = position
	visual.velocity = Vector3.zero
	visual.settled = true
end

function BombProjectileVisualState.ApplyImpact(visual, payload)
	local projectilePosition = if typeof(payload.projectilePosition) == "Vector3"
		then payload.projectilePosition
		else payload.position
	local postImpactVelocity = if typeof(payload.postImpactVelocity) == "Vector3"
		then payload.postImpactVelocity
		else payload.impactVelocity
	visual.targetPosition = projectilePosition
	visual.position = projectilePosition
	visual.targetVelocity = if typeof(postImpactVelocity) == "Vector3" then postImpactVelocity else visual.targetVelocity
	if typeof(payload.acceleration) == "Vector3" then
		visual.acceleration = payload.acceleration
	end
end

function BombProjectileVisualState.ApplyBurrowStart(visual, payload)
	visual.burrowing = true
	visual.spinLocked = false
	if typeof(payload.direction) == "Vector3" and payload.direction.Magnitude > 0.05 then
		visual.targetVelocity = payload.direction.Unit * math.max(tonumber(payload.speed) or 60, 1)
	end
end

function BombProjectileVisualState.ApplyBurrowStep(visual, payload)
	visual.burrowing = true
	visual.targetPosition = payload.position
	if typeof(payload.direction) == "Vector3" and payload.direction.Magnitude > 0.05 then
		visual.targetVelocity = payload.direction.Unit * math.max(tonumber(payload.speed) or 60, 1)
	end
end

function BombProjectileVisualState.ApplyBurrowEnd(visual)
	visual.burrowing = false
end

return table.freeze(BombProjectileVisualState)
