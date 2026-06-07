local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local ProjectilePhysics = require(ReplicatedStorage.Shared.Bombs.ProjectilePhysics)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local AbilityService = require(ServerScriptService.Services.AbilityService)

local RESULT_KIND = AbilityResult.Kind
local DEBUG_REPLAY_EVENTS = false

type HandlerTable = {
	fireEffect: ((effectName: string, payload: any) -> ())?,
	explode: ((owner: Player, position: Vector3, source: string, projectileId: string?, bombSkinId: string?) -> ())?,
}

type ProjectileState = {
	id: string,
	owner: Player,
	bombType: string,
	skinId: string,
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
	groundRollDirection: Vector3,
	physicalProjectile: Instance?,
	physicalRoot: BasePart?,
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

local function explode(owner: Player, position: Vector3, source: string, projectileId: string?, bombSkinId: string?)
	local callback = handlers.explode
	if callback then
		callback(owner, position, source, projectileId, bombSkinId)
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

local function getHorizontalDirection(direction: any): Vector3?
	if typeof(direction) ~= "Vector3" then
		return nil
	end

	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	if horizontal.Magnitude <= 0.05 then
		return nil
	end

	return horizontal.Unit
end

local function getOwnerFacingDirection(owner: Player): Vector3?
	local character = owner.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return getHorizontalDirection(rootPart.CFrame.LookVector)
	end

	return nil
end

local function resolveGroundRollDirection(owner: Player, aimDirection: Vector3): Vector3
	return getHorizontalDirection(aimDirection) or getOwnerFacingDirection(owner) or Vector3.zAxis
end

local function getProjectileFolder(): Folder
	local existing = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = BombConfig.ProjectileFolderName
	folder.Parent = workspace
	return folder
end

local function preparePhysicalProjectile(projectileId: string, owner: Player, bombType: string, skinId: string): (Instance, BasePart)
	local projectile, rootPart = BombVisualUtil.CreateBombVisual(skinId, "BombProjectile_" .. projectileId, {
		anchored = false,
		canCollide = true,
		canQuery = true,
		massless = false,
		effectState = {
			vfx = true,
			fuseSpark = true,
			trail = true,
		},
		visualScale = BombConfig.ProjectileVisualScale,
	})
	projectile.Name = "BombProjectile_" .. projectileId
	if projectile:IsA("Model") then
		projectile.PrimaryPart = rootPart
	end

	projectile:SetAttribute("ProjectileId", projectileId)
	projectile:SetAttribute("OwnerUserId", owner.UserId)
	projectile:SetAttribute("BombType", bombType)
	projectile:SetAttribute("BombSkinId", skinId)
	rootPart:SetAttribute("ProjectileId", projectileId)
	rootPart:SetAttribute("OwnerUserId", owner.UserId)
	rootPart:SetAttribute("BombType", bombType)
	rootPart:SetAttribute("BombSkinId", skinId)
	return projectile, rootPart
end

local function setPhysicalMotion(projectile: Instance, velocity: Vector3, angularVelocity: Vector3)
	for _, descendant in ipairs(projectile:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = velocity
			descendant.AssemblyAngularVelocity = angularVelocity
			pcall(function()
				descendant:SetNetworkOwner(nil)
			end)
		end
	end
	if projectile:IsA("BasePart") then
		projectile.AssemblyLinearVelocity = velocity
		projectile.AssemblyAngularVelocity = angularVelocity
		pcall(function()
			projectile:SetNetworkOwner(nil)
		end)
	end
end

local function destroyPhysicalProjectile(state: ProjectileState?)
	if not state then
		return
	end

	local projectile = state.physicalProjectile
	state.physicalProjectile = nil
	state.physicalRoot = nil
	if projectile and projectile.Parent then
		projectile:Destroy()
	end
end

local function getPhysicalPosition(state: ProjectileState): Vector3
	local rootPart = state.physicalRoot
	if rootPart and rootPart.Parent then
		return rootPart.Position
	end

	return state.position
end

local function getPhysicalVelocity(state: ProjectileState): Vector3
	local rootPart = state.physicalRoot
	if rootPart and rootPart.Parent then
		return rootPart.AssemblyLinearVelocity
	end

	return state.velocity
end

local function spawnPhysicalProjectile(state: ProjectileState): Instance?
	if state.physicalProjectile and state.physicalProjectile.Parent then
		return state.physicalProjectile
	end

	local projectile, rootPart = preparePhysicalProjectile(state.id, state.owner, state.bombType, state.skinId)
	projectile:SetAttribute("FuseStartedAt", state.fuseStartedAt)
	projectile:SetAttribute("FuseEndsAt", state.explodeAt)

	local cframe = CFrame.new(state.position)
	if projectile:IsA("Model") then
		projectile:PivotTo(cframe)
	else
		projectile.CFrame = cframe
	end
	projectile.Parent = getProjectileFolder()

	local velocity = state.velocity
	local radius = math.max(state.physics.radius, 0.1)
	local angularAxis = Vector3.yAxis:Cross(velocity)
	local angularVelocity = if angularAxis.Magnitude > 0.05 then angularAxis.Unit * (velocity.Magnitude / radius) else Vector3.zero
	setPhysicalMotion(projectile, velocity, angularVelocity)

	state.physicalProjectile = projectile
	state.physicalRoot = rootPart
	state.position = rootPart.Position
	state.velocity = rootPart.AssemblyLinearVelocity
	return projectile
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
		bombSkinId = state.skinId,
		position = state.position,
		velocity = state.velocity,
		acceleration = getAcceleration(state.physics, state.hasImpacted),
		serverTime = currentTime,
		remainingFuse = math.max(state.explodeAt - currentTime, 0),
		settled = state.settled,
		grounded = state.grounded,
		radius = state.physics.radius,
		physicalProjectile = state.physicalProjectile,
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
		bombSkinId = state.skinId,
		position = hitPosition,
		projectilePosition = state.position,
		impactNormal = hitNormal,
		impactVelocity = incomingVelocity,
		postImpactVelocity = state.velocity,
		acceleration = getAcceleration(state.physics, state.hasImpacted),
		hitInstance = hit.Instance,
		settled = state.settled,
		physicalProjectile = state.physicalProjectile,
	})
end

local function fireSettle(state: ProjectileState)
	fireEffect("Settle", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		bombSkinId = state.skinId,
		position = state.position,
		velocity = Vector3.zero,
		settled = true,
	})
end

local function dampVector(vector: Vector3, dampingPerSecond: number, dt: number, stopSpeed: number): Vector3
	if vector.Magnitude <= stopSpeed then
		return Vector3.zero
	end

	local dampingAlpha = math.clamp(dampingPerSecond * dt, 0, 1)
	local speed = vector.Magnitude * (1 - dampingAlpha)
	if speed <= stopSpeed then
		return Vector3.zero
	end

	return vector.Unit * speed
end

local function isPhysicalProjectileGrounded(state: ProjectileState, rootPart: BasePart): boolean
	local radius = math.max(state.physics.radius, rootPart.Size.X * 0.5, rootPart.Size.Z * 0.5, 0.1)
	local probeDistance = radius + math.max(state.physics.surfaceOffset, 0) + 0.35
	local hit = workspace:Raycast(rootPart.Position, Vector3.yAxis * -probeDistance, createRaycastParams(state))
	return hit ~= nil and hit.Normal.Y >= state.physics.floorNormalY
end

local function dampGroundedPhysicalProjectile(state: ProjectileState, dt: number)
	if state.bombType ~= BombProjectileConfig.BombType.Normal then
		return
	end

	local projectile = state.physicalProjectile
	local rootPart = state.physicalRoot
	if not (projectile and projectile.Parent and rootPart and rootPart.Parent) then
		return
	end
	if not isPhysicalProjectileGrounded(state, rootPart) then
		state.grounded = false
		return
	end

	state.grounded = true
	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local dampedHorizontal = dampVector(
		horizontalVelocity,
		state.physics.groundedFrictionPerSecond,
		dt,
		state.physics.minRollSpeed
	)

	local verticalSpeed = velocity.Y
	if math.abs(verticalSpeed) <= state.physics.minRollSpeed then
		verticalSpeed = 0
	end

	local radius = math.max(state.physics.radius, 0.1)
	local dampedAngular = dampVector(
		rootPart.AssemblyAngularVelocity,
		state.physics.groundedFrictionPerSecond * 1.35,
		dt,
		state.physics.minRollSpeed / radius
	)
	local dampedVelocity = Vector3.new(dampedHorizontal.X, verticalSpeed, dampedHorizontal.Z)
	setPhysicalMotion(projectile, dampedVelocity, dampedAngular)
	state.position = rootPart.Position
	state.velocity = dampedVelocity

	if dampedHorizontal.Magnitude <= 0 and math.abs(verticalSpeed) <= 0 and dampedAngular.Magnitude <= 0 and not state.settled then
		state.settled = true
		fireSettle(state)
	end
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
			groundedFrictionPerSecond = result.groundedFrictionPerSecond,
			minRollSpeed = result.minRollSpeed,
			minGroundImpactRollSpeed = result.minGroundImpactRollSpeed,
		},
	}
	state.physics = ProjectilePhysics.ResolvePhysicsConfig(state.physics, modifier.physics)
	destroyPhysicalProjectile(state)
	state.position = origin
	state.lastPosition = origin
	state.velocity = ProjectilePhysics.GetLaunchVelocity(aimDirection, state.physics)
	state.launchedAt = currentTime
	state.settled = false
	state.hasImpacted = false
	state.grounded = false
	state.groundRollDirection = resolveGroundRollDirection(state.owner, aimDirection)

	local remainingFuse = math.max(state.explodeAt - currentTime, 0)
	fireEffect("Throw", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		bombSkinId = state.skinId,
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
	state.position = getPhysicalPosition(state)
	destroyPhysicalProjectile(state)
	explode(state.owner, state.position, "Projectile", state.id, state.skinId)
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

	if state.physicalProjectile then
		dampGroundedPhysicalProjectile(state, fixedDt)
		state.position = getPhysicalPosition(state)
		state.velocity = getPhysicalVelocity(state)
		if not handleStepHook(state, state.position + state.velocity * fixedDt, currentTime) then
			return
		end
		if state.destroyed or not state.physicalProjectile then
			return
		end
		fireSnapshot(state, currentTime, false)
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
			if state.grounded then
				spawnPhysicalProjectile(state)
			end
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
	local skinId = BombSkinConfig.NormalizeSkinId(request.skinId)
	if skinId == "" then
		skinId = BombSkinConfig.DefaultSkinId
	end
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
		bombSkinId = skinId,
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
	local groundRollDirection = resolveGroundRollDirection(owner, aimDirection)
	local state: ProjectileState = {
		id = projectileId,
		owner = owner,
		bombType = bombType,
		skinId = skinId,
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
		groundRollDirection = groundRollDirection,
		physicalProjectile = nil,
		physicalRoot = nil,
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
		bombSkinId = skinId,
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
		bombSkinId = skinId,
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
	state.position = getPhysicalPosition(state)
	destroyPhysicalProjectile(state)
	fireEffect("ProjectileDestroy", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		bombSkinId = state.skinId,
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

		local position = if state.physicalProjectile then getPhysicalPosition(state) else state.position
		local velocity = if state.physicalProjectile then getPhysicalVelocity(state) else state.velocity

		table.insert(snapshots, {
			bombId = state.id,
			ownerUserId = ownerUserId,
			bombType = state.bombType,
			bombSkinId = state.skinId,
			cframe = CFrame.new(position),
			assemblyLinearVelocity = velocity,
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
