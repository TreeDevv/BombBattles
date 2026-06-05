local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local ProjectilePhysics = require(ReplicatedStorage.Shared.Bombs.ProjectilePhysics)
local AbilityService = require(ServerScriptService.Services.AbilityService)

local RESULT_KIND = AbilityResult.Kind
local DEBUG_REPLAY_EVENTS = false

type HandlerTable = {
	fireEffect: ((effectName: string, payload: any) -> ())?,
	explode: ((owner: Player, position: Vector3, source: string, projectileId: string?) -> ())?,
}

type ProjectileState = {
	id: string,
	owner: Player,
	bombType: string,
	position: Vector3,
	lastPosition: Vector3,
	velocity: Vector3,
	launchedAt: number,
	fuseStartedAt: number,
	explodeAt: number,
	physics: ProjectilePhysics.PhysicsConfig,
	collision: { [string]: any },
	explosion: { [string]: any },
	visuals: { [string]: any },
	settled: boolean,
	hasImpacted: boolean,
	grounded: boolean,
	destroyed: boolean,
	nextSnapshotAt: number,
	lastImpactAt: number,
}

local BombProjectileService = {}

local handlers: HandlerTable = {}
local activeProjectiles: { [string]: ProjectileState } = {}
local heartbeatConnection: RBXScriptConnection? = nil
local accumulator = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local replayService = nil

local function getReplayService()
	if replayService then
		return replayService
	end

	local services = ServerScriptService:FindFirstChild("Services")
	local replayModule = services and services:FindFirstChild("ReplayService")
	if not (replayModule and replayModule:IsA("ModuleScript")) then
		return nil
	end

	local ok, service = pcall(require, replayModule)
	if ok and typeof(service) == "table" then
		replayService = service
		return replayService
	end

	if DEBUG_REPLAY_EVENTS then
		warn("[BombProjectileService] ReplayService require failed:", service)
	end
	return nil
end

local function recordReplayEvent(eventType: string, payload)
	local service = getReplayService()
	if not (service and type(service.RecordEvent) == "function") then
		return
	end

	local ok, err = pcall(function()
		service.RecordEvent(eventType, payload)
	end)
	if DEBUG_REPLAY_EVENTS and not ok then
		warn("[BombProjectileService] Replay event failed:", eventType, err)
	end
end

local function fireEffect(effectName: string, payload)
	local callback = handlers.fireEffect
	if callback then
		callback(effectName, payload)
	end
end

local function explode(owner: Player, position: Vector3, source: string, projectileId: string?)
	local callback = handlers.explode
	if callback then
		callback(owner, position, source, projectileId)
	end
end

local function isSuppressed(result): boolean
	if typeof(result) ~= "table" then
		return false
	end

	return result.kind == RESULT_KIND.Block or result.kind == RESULT_KIND.Absorb or result.kind == RESULT_KIND.DestroyProjectile
end

local function copyDictionary(source)
	local copy = {}
	if typeof(source) == "table" then
		for key, value in pairs(source) do
			copy[key] = value
		end
	end
	return copy
end

local function mergeDictionary(base, override)
	local merged = copyDictionary(base)
	if typeof(override) == "table" then
		for key, value in pairs(override) do
			merged[key] = value
		end
	end
	return merged
end

local function readFiniteVector(value: any, fallback: Vector3): Vector3
	return if ProjectilePhysics.IsFiniteVector(value) then value else fallback
end

local function readNumber(value: any, fallback: number, minimum: number?, maximum: number?): number
	local numberValue = if typeof(value) == "number" and value == value then value else fallback
	if typeof(minimum) == "number" then
		numberValue = math.max(numberValue, minimum)
	end
	if typeof(maximum) == "number" then
		numberValue = math.min(numberValue, maximum)
	end
	return numberValue
end

local function getBombTypeConfig(bombType: string?)
	return BombProjectileConfig.GetBombTypeConfig(bombType)
end

local function resolveStateConfig(bombType: string?, modifier)
	local bombTypeConfig = getBombTypeConfig(bombType)
	local physics = ProjectilePhysics.ResolvePhysicsConfig(BombProjectileConfig.Defaults, bombTypeConfig.physics)
	local collision = copyDictionary(bombTypeConfig.collision)
	local explosionConfig = copyDictionary(bombTypeConfig.explosion)
	local visuals = copyDictionary(bombTypeConfig.visuals)
	local fuseConfig = copyDictionary(bombTypeConfig.fuse)

	if typeof(modifier) == "table" then
		physics = ProjectilePhysics.ResolvePhysicsConfig(physics, modifier.physics)
		collision = mergeDictionary(collision, modifier.collision)
		explosionConfig = mergeDictionary(explosionConfig, modifier.explosion)
		visuals = mergeDictionary(visuals, modifier.visuals)
		fuseConfig = mergeDictionary(fuseConfig, modifier.fuse)
	end

	return physics, collision, explosionConfig, visuals, fuseConfig
end

local function createRaycastParams(state: ProjectileState): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local excluded = {}
	local character = state.owner.Character
	if character then
		table.insert(excluded, character)
	end

	local projectileFolder = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	if projectileFolder then
		table.insert(excluded, projectileFolder)
	end

	params.FilterDescendantsInstances = excluded
	params.IgnoreWater = state.collision.ignoreWater ~= false
	params.RespectCanCollide = state.collision.respectCanCollide ~= false
	return params
end

local function getAcceleration(physics: ProjectilePhysics.PhysicsConfig, hasImpacted: boolean?): Vector3
	return Vector3.new(0, -ProjectilePhysics.GetGravity(physics, hasImpacted), 0)
end

local function fireSnapshot(state: ProjectileState, currentTime: number, force: boolean?)
	local interval = 1 / math.max(BombProjectileConfig.SnapshotHz, 1)
	if not force and currentTime < state.nextSnapshotAt then
		return
	end

	state.nextSnapshotAt = currentTime + interval
	fireEffect("ProjectileSnapshot", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		position = state.position,
		velocity = state.velocity,
		acceleration = getAcceleration(state.physics, state.hasImpacted),
		serverTime = currentTime,
		remainingFuse = math.max(state.explodeAt - currentTime, 0),
		settled = state.settled,
		grounded = state.grounded,
		radius = state.physics.radius,
	})
end

local function fireImpact(
	state: ProjectileState,
	hit: RaycastResult,
	hitPosition: Vector3,
	hitNormal: Vector3,
	incomingVelocity: Vector3
)
	local currentTime = now()
	if currentTime - state.lastImpactAt < 0.035 then
		return
	end
	state.lastImpactAt = currentTime

	local impactResult = AbilityService:RunHook("OnBeforeProjectileImpact", {
		projectileId = state.id,
		owner = state.owner,
		position = hitPosition,
		normal = hitNormal,
		incomingVelocity = incomingVelocity,
		hit = hit,
		hitInstance = hit.Instance,
		customProjectile = true,
	})
	if impactResult.kind == RESULT_KIND.DestroyProjectile or impactResult.kind == RESULT_KIND.Absorb then
		BombProjectileService:DestroyProjectile(state.id, "Impact")
		return
	end
	if impactResult.kind == RESULT_KIND.Block then
		return
	end
	if typeof(impactResult.position) == "Vector3" then
		hitPosition = impactResult.position
	end
	if typeof(impactResult.normal) == "Vector3" then
		hitNormal = impactResult.normal
	end

	fireEffect("Impact", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		position = hitPosition,
		projectilePosition = state.position,
		impactNormal = hitNormal,
		impactVelocity = incomingVelocity,
		postImpactVelocity = state.velocity,
		acceleration = getAcceleration(state.physics, state.hasImpacted),
		hitInstance = hit.Instance,
		settled = state.settled,
	})
end

local function fireSettle(state: ProjectileState)
	fireEffect("Settle", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		position = state.position,
		velocity = Vector3.zero,
		settled = true,
	})
end

local function redirectProjectile(state: ProjectileState, result, currentTime: number): boolean
	if typeof(result) ~= "table" then
		return false
	end

	local origin = readFiniteVector(result.origin, state.position)
	local aimDirection = readFiniteVector(result.aimDirection, state.velocity)
	if aimDirection.Magnitude <= 0.05 then
		aimDirection = Vector3.zAxis
	end

	if typeof(result.owner) == "Instance" and result.owner:IsA("Player") then
		state.owner = result.owner
	end

	local modifier = {
		physics = {
			launchSpeed = result.launchSpeed,
			upwardVelocity = result.upwardVelocity,
			gravity = result.gravity,
			postImpactGravity = result.postImpactGravity,
			maxSpeed = result.maxSpeed,
			impactResponse = result.impactResponse,
			restitution = result.restitution,
			friction = result.friction,
			wallFriction = result.wallFriction,
			sandbagHorizontalScale = result.sandbagHorizontalScale,
			sandbagMaxHorizontalSpeed = result.sandbagMaxHorizontalSpeed,
			sandbagDownwardVelocity = result.sandbagDownwardVelocity,
		},
	}
	state.physics = ProjectilePhysics.ResolvePhysicsConfig(state.physics, modifier.physics)
	state.position = origin
	state.lastPosition = origin
	state.velocity = ProjectilePhysics.GetLaunchVelocity(aimDirection, state.physics)
	state.launchedAt = currentTime
	state.settled = false
	state.hasImpacted = false
	state.grounded = false

	local remainingFuse = math.max(state.explodeAt - currentTime, 0)
	fireEffect("Throw", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		origin = state.position,
		position = state.position,
		initialVelocity = state.velocity,
		velocity = state.velocity,
		acceleration = getAcceleration(state.physics, state.hasImpacted),
		duration = remainingFuse,
		startedAt = currentTime,
		fuseStartedAt = state.fuseStartedAt,
		remainingFuse = remainingFuse,
		radius = state.physics.radius,
		snapshotHz = BombProjectileConfig.SnapshotHz,
	})
	fireSnapshot(state, currentTime, true)
	return true
end

local function handleStepHook(state: ProjectileState, nextPosition: Vector3, currentTime: number): boolean
	local stepResult = AbilityService:RunHook("OnProjectileStep", {
		projectileId = state.id,
		owner = state.owner,
		position = state.position,
		lastPosition = state.lastPosition,
		nextPosition = nextPosition,
		currentVelocity = state.velocity,
		landed = state.settled,
		settled = state.settled,
		currentTime = currentTime,
		explodeAt = state.explodeAt,
		remainingFuse = math.max(state.explodeAt - currentTime, 0),
		sweepRadius = state.physics.radius,
		customProjectile = true,
	})

	if stepResult.kind == RESULT_KIND.DestroyProjectile or stepResult.kind == RESULT_KIND.Absorb then
		BombProjectileService:DestroyProjectile(state.id, "Step")
		return false
	end
	if stepResult.kind == RESULT_KIND.DeferProjectile and typeof(stepResult.deferSeconds) == "number" then
		state.explodeAt += math.clamp(stepResult.deferSeconds, 0, BombConfig.FuseSeconds)
		return true
	end
	if stepResult.kind == RESULT_KIND.RedirectProjectile then
		return not redirectProjectile(state, stepResult, currentTime)
	end

	return true
end

local function explodeProjectile(state: ProjectileState)
	activeProjectiles[state.id] = nil
	state.destroyed = true
	explode(state.owner, state.position, "Projectile", state.id)
end

local function stepProjectile(state: ProjectileState, fixedDt: number, currentTime: number)
	if state.destroyed then
		return
	end
	if not state.owner.Parent then
		BombProjectileService:DestroyProjectile(state.id, "OwnerRemoved")
		return
	end
	if currentTime >= state.explodeAt then
		explodeProjectile(state)
		return
	end

	local predictedPosition = state.position
	local predictedVelocity = state.velocity
	if not state.settled then
		predictedPosition, predictedVelocity = ProjectilePhysics.Integrate(
			state.position,
			state.velocity,
			fixedDt,
			state.physics,
			state.hasImpacted
		)
	end

	if not handleStepHook(state, predictedPosition, currentTime) then
		return
	end
	if state.destroyed then
		return
	end

	state.lastPosition = state.position
	if not state.settled then
		local result = ProjectilePhysics.Step(state, fixedDt, state.physics, createRaycastParams(state))
		state.position = result.position
		state.velocity = result.velocity
		state.hasImpacted = result.hasImpacted == true
		state.grounded = result.grounded == true
		if result.hit and result.hitPosition and result.hitNormal and result.incomingVelocity then
			fireImpact(state, result.hit, result.hitPosition, result.hitNormal, result.incomingVelocity)
			if state.destroyed then
				return
			end
		end
		if result.settled and not state.settled then
			state.settled = true
			state.grounded = true
			state.velocity = Vector3.zero
			fireSettle(state)
		else
			state.settled = result.settled
		end
	else
		state.velocity = Vector3.zero
	end

	fireSnapshot(state, currentTime, false)

	if currentTime >= state.explodeAt then
		explodeProjectile(state)
	end
end

local function stepAll(fixedDt: number)
	local currentTime = now()
	for _, state in pairs(activeProjectiles) do
		stepProjectile(state, fixedDt, currentTime)
	end
end

function BombProjectileService:IsEnabled(): boolean
	return BombProjectileConfig.Enabled == true
end

function BombProjectileService:SetHandlers(nextHandlers: HandlerTable)
	handlers = nextHandlers or {}
end

function BombProjectileService:Launch(request): boolean
	if not self:IsEnabled() or typeof(request) ~= "table" then
		return false
	end

	local owner = request.owner
	if not (typeof(owner) == "Instance" and owner:IsA("Player")) then
		return false
	end
	local projectileId = request.projectileId
	if typeof(projectileId) ~= "string" or projectileId == "" then
		return false
	end

	local bombType = if typeof(request.bombType) == "string" and request.bombType ~= "" then request.bombType else BombProjectileConfig.BombType.Normal
	local physics, collision, explosionConfig, visuals, fuseConfig = resolveStateConfig(bombType, request.modifier)
	local origin = readFiniteVector(request.origin, Vector3.zero)
	local aimDirection = readFiniteVector(request.aimDirection, Vector3.zAxis)
	local launchTime = readNumber(request.launchedAt, now(), 0, math.huge)
	local fuseStartedAt = readNumber(request.fuseStartedAt, launchTime, 0, math.huge)
	local requestedFuse = readNumber(request.remainingFuse, readNumber(fuseConfig.seconds, BombConfig.FuseSeconds, 0.05, 60), 0.05, 60)

	local launchResult = AbilityService:RunHook("OnBeforeProjectileLaunch", {
		owner = owner,
		projectileId = projectileId,
		bombType = bombType,
		origin = origin,
		aimDirection = aimDirection,
		remainingFuse = requestedFuse,
		physics = physics,
		collision = collision,
		explosion = explosionConfig,
		visuals = visuals,
		customProjectile = true,
	})
	if isSuppressed(launchResult) then
		return false
	end

	if typeof(launchResult.physics) == "table" then
		physics = ProjectilePhysics.ResolvePhysicsConfig(physics, launchResult.physics)
	end
	if typeof(launchResult.collision) == "table" then
		collision = mergeDictionary(collision, launchResult.collision)
	end
	if typeof(launchResult.explosion) == "table" then
		explosionConfig = mergeDictionary(explosionConfig, launchResult.explosion)
	end
	if typeof(launchResult.visuals) == "table" then
		visuals = mergeDictionary(visuals, launchResult.visuals)
	end
	if typeof(launchResult.fuse) == "table" then
		fuseConfig = mergeDictionary(fuseConfig, launchResult.fuse)
	end
	if typeof(launchResult.origin) == "Vector3" then
		origin = launchResult.origin
	end
	if typeof(launchResult.aimDirection) == "Vector3" then
		aimDirection = launchResult.aimDirection
	end
	if typeof(launchResult.remainingFuse) == "number" then
		requestedFuse = readNumber(launchResult.remainingFuse, requestedFuse, 0.05, 60)
	elseif typeof(fuseConfig.seconds) == "number" then
		requestedFuse = math.min(requestedFuse, readNumber(fuseConfig.seconds, requestedFuse, 0.05, 60))
	end

	local initialVelocity = ProjectilePhysics.GetLaunchVelocity(aimDirection, physics)
	local state: ProjectileState = {
		id = projectileId,
		owner = owner,
		bombType = bombType,
		position = origin,
		lastPosition = origin,
		velocity = initialVelocity,
		launchedAt = launchTime,
		fuseStartedAt = fuseStartedAt,
		explodeAt = launchTime + requestedFuse,
		physics = physics,
		collision = collision,
		explosion = explosionConfig,
		visuals = visuals,
		settled = false,
		hasImpacted = false,
		grounded = false,
		destroyed = false,
		nextSnapshotAt = launchTime,
		lastImpactAt = 0,
	}

	activeProjectiles[projectileId] = state
	fireEffect("Throw", {
		player = owner,
		projectileId = projectileId,
		customProjectile = true,
		bombType = bombType,
		origin = origin,
		position = origin,
		initialVelocity = initialVelocity,
		velocity = initialVelocity,
		acceleration = getAcceleration(physics, false),
		duration = requestedFuse,
		startedAt = launchTime,
		fuseStartedAt = fuseStartedAt,
		remainingFuse = requestedFuse,
		radius = physics.radius,
		snapshotHz = BombProjectileConfig.SnapshotHz,
	})
	recordReplayEvent("BombThrown", {
		bombId = projectileId,
		ownerUserId = owner.UserId,
		bombType = bombType,
		position = origin,
		velocity = initialVelocity,
		fuseDuration = requestedFuse,
	})
	fireSnapshot(state, launchTime, true)
	return true
end

function BombProjectileService:DestroyProjectile(projectileId: string, reason: string?): boolean
	local state = activeProjectiles[projectileId]
	if not state then
		return false
	end

	activeProjectiles[projectileId] = nil
	state.destroyed = true
	fireEffect("ProjectileDestroy", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		reason = reason or "Destroyed",
		position = state.position,
	})
	return true
end

function BombProjectileService:ClearPlayerProjectiles(player: Player)
	for projectileId, state in pairs(activeProjectiles) do
		if state.owner == player then
			self:DestroyProjectile(projectileId, "OwnerCleared")
		end
	end
end

function BombProjectileService:GetReplaySnapshots(maxCount: number?)
	local limit = if typeof(maxCount) == "number" then math.max(math.floor(maxCount), 0) else 64
	local defaultRadius = BombProjectileConfig.Defaults.radius
	local snapshots = {}

	for _, state in pairs(activeProjectiles) do
		if #snapshots >= limit then
			break
		end
		if state.destroyed then
			continue
		end

		local owner = state.owner
		local ownerUserId = if owner and owner.Parent then owner.UserId else nil
		local radius = if typeof(state.physics.radius) == "number" then state.physics.radius else nil
		local sizeScale = if radius and typeof(defaultRadius) == "number" and defaultRadius > 0 then radius / defaultRadius else nil

		table.insert(snapshots, {
			bombId = state.id,
			ownerUserId = ownerUserId,
			bombType = state.bombType,
			cframe = CFrame.new(state.position),
			assemblyLinearVelocity = state.velocity,
			radius = radius,
			sizeScale = sizeScale,
			fuseStartedAt = state.fuseStartedAt,
			fuseEndsAt = state.explodeAt,
			settled = state.settled,
		})
	end

	return snapshots
end

function BombProjectileService:OnStart()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
	end

	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if not self:IsEnabled() then
			return
		end

		local fixedDt = BombProjectileConfig.FixedStepSeconds
		local maxSteps = math.max(BombProjectileConfig.MaxStepsPerHeartbeat, 1)
		accumulator += math.min(deltaTime, fixedDt * maxSteps)

		local steps = 0
		while accumulator >= fixedDt and steps < maxSteps do
			accumulator -= fixedDt
			steps += 1
			stepAll(fixedDt)
		end
		if steps >= maxSteps then
			accumulator = 0
		end
	end)
end

function BombProjectileService:OnPlayerRemoving(player: Player)
	self:ClearPlayerProjectiles(player)
end

return BombProjectileService
