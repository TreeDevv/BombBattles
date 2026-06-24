local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local CollisionGroupConfig = require(ReplicatedStorage.Shared.Config.CollisionGroupConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local ProjectilePhysics = require(ReplicatedStorage.Shared.Bombs.ProjectilePhysics)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local AbilityService = require(ServerScriptService.Services.AbilityService)
local DestructionService = require(ServerScriptService.Services.DestructionService)
local StudioAICombatants = require(ServerScriptService.Services.StudioAICombatants)

local RESULT_KIND = AbilityResult.Kind
local DEBUG_REPLAY_EVENTS = false
local BOMB_PROJECTILE_COLLISION_GROUP = CollisionGroupConfig.Groups.BombProjectile
local PRACTICE_RANGE_BOMB_BARRIER_COLLISION_GROUP = CollisionGroupConfig.Groups.PracticeRangeBombBarrier

type HandlerTable = {
	fireEffect: ((effectName: string, payload: any) -> ())?,
	explode: ((owner: any, position: Vector3, source: string, projectileId: string?, bombSkinId: string?, explosionConfig: { [string]: any }?) -> ())?,
}

type ProjectileAttachment = {
	instance: BasePart?,
	localPosition: Vector3?,
	position: Vector3,
	normal: Vector3,
	targetKind: string?,
}

type ProjectileBurrowState = {
	abilityId: string,
	direction: Vector3,
	startPosition: Vector3,
	startedAt: number,
	endsAt: number,
	remainingDistance: number,
	speed: number,
	carveRadius: number,
	carveStepDistance: number,
	effectInterval: number,
	lastCarvePosition: Vector3,
	nextEffectAt: number,
}

type ProjectileState = {
	id: string,
	owner: any,
	sourceType: string?,
	bombType: string,
	skinId: string,
	rangeOrigin: Vector3,
	maxRange: number,
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
	attached: ProjectileAttachment?,
	destroyed: boolean,
	nextSnapshotAt: number,
	lastImpactAt: number,
	frozenUntil: number?,
	frozenVelocity: Vector3?,
	frozenPosition: Vector3?,
	frozenBy: string?,
	timeScale: number,
	targetTimeScale: number,
	timeScaleSource: string?,
	targetTimeScaleSource: string?,
	timeScaleEnterRate: number?,
	timeScaleExitRate: number?,
	timeScaleStrength: number,
	burrow: ProjectileBurrowState?,
	stepAccumulator: number?,
	lastSnapshotAt: number?,
	lastSnapshotPosition: Vector3?,
	lastSnapshotVelocity: Vector3?,
	lastSnapshotSettled: boolean?,
	lastSnapshotGrounded: boolean?,
	lastSnapshotAttached: boolean?,
	lastSnapshotFrozen: boolean?,
	lastSnapshotBurrowing: boolean?,
}

local BombProjectileService = {}

local handlers: HandlerTable = {}
local activeProjectiles: { [string]: ProjectileState } = {}
local heartbeatConnection: RBXScriptConnection? = nil
local accumulator = 0
local pendingSnapshotPayloads = {}
local pendingSnapshotIndexesByProjectileId = {}
local nextSnapshotBatchFlushAt = 0
local combatantHurtboxCache = {
	updatedAt = 0,
	entries = {},
}
local explodeProjectile
local redirectProjectile
local startBurrowProjectile
local fireSnapshot

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

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

local function clearPendingSnapshot(projectileId: string)
	local index = pendingSnapshotIndexesByProjectileId[projectileId]
	if not index then
		return
	end

	local lastIndex = #pendingSnapshotPayloads
	local lastPayload = pendingSnapshotPayloads[lastIndex]
	if index ~= lastIndex then
		pendingSnapshotPayloads[index] = lastPayload
	end
	pendingSnapshotPayloads[lastIndex] = nil
	pendingSnapshotIndexesByProjectileId[projectileId] = nil
	if index ~= lastIndex and lastPayload and lastPayload.projectileId then
		pendingSnapshotIndexesByProjectileId[lastPayload.projectileId] = index
	end
end

local function queueSnapshotPayload(payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end

	local projectileId = payload.projectileId
	local existingIndex = pendingSnapshotIndexesByProjectileId[projectileId]
	if existingIndex then
		pendingSnapshotPayloads[existingIndex] = payload
		return
	end

	table.insert(pendingSnapshotPayloads, payload)
	pendingSnapshotIndexesByProjectileId[projectileId] = #pendingSnapshotPayloads
end

local function flushSnapshotBatch(currentTime: number, force: boolean?)
	if #pendingSnapshotPayloads == 0 then
		return
	end

	local batchHz = math.max(tonumber(BombProjectileConfig.SnapshotBatchHz) or BombProjectileConfig.SnapshotHz or 12, 1)
	if force ~= true and currentTime < nextSnapshotBatchFlushAt then
		return
	end

	if #pendingSnapshotPayloads == 1 then
		fireEffect("ProjectileSnapshot", pendingSnapshotPayloads[1])
	else
		fireEffect("ProjectileSnapshots", {
			snapshots = table.clone(pendingSnapshotPayloads),
			serverTime = currentTime,
		})
	end
	RuntimeProfiler.Count("Server/BombProjectile/SnapshotFlushes")
	RuntimeProfiler.Count("Server/BombProjectile/SnapshotsSent", #pendingSnapshotPayloads)

	table.clear(pendingSnapshotPayloads)
	table.clear(pendingSnapshotIndexesByProjectileId)
	nextSnapshotBatchFlushAt = currentTime + 1 / batchHz
end

local function explode(owner: any, position: Vector3, source: string, projectileId: string?, bombSkinId: string?, explosionConfig: { [string]: any }?)
	local callback = handlers.explode
	if callback then
		callback(owner, position, source, projectileId, bombSkinId, explosionConfig)
	end
end

local function isValidOwner(owner: any): boolean
	if typeof(owner) == "Instance" then
		return owner:IsA("Player") and owner.Parent == Players
	end

	return StudioAICombatants.IsBotOwner(owner)
end

local function inferAbilityIdFromProjectileId(projectileId: string): string?
	local prefix = string.match(projectileId, "^([A-Za-z][A-Za-z0-9]*)_")
	return if typeof(prefix) == "string" and prefix ~= "" then prefix else nil
end

local function isOwnerActive(owner: any): boolean
	if typeof(owner) == "Instance" then
		return owner:IsA("Player") and owner.Parent == Players
	end
	if not isValidOwner(owner) then
		return false
	end

	local character = owner.Character
	if typeof(character) ~= "Instance" or not character:IsA("Model") or not character.Parent then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function getOwnerUserId(owner: any): number
	return if typeof(owner) == "table" and typeof(owner.UserId) == "number" then owner.UserId else owner.UserId
end

local function getOwnerVisualIdentity(owner: any): (number?, string?)
	local ownerIdentity = StudioAICombatants.GetOwnerIdentity(owner)
	local ownerUserId = if ownerIdentity and typeof(ownerIdentity.userId) == "number"
		then ownerIdentity.userId
		else getOwnerUserId(owner)
	local ownerTeam = if ownerIdentity
			and typeof(ownerIdentity.teamName) == "string"
			and ownerIdentity.teamName ~= ""
		then ownerIdentity.teamName
		else nil
	return ownerUserId, ownerTeam
end

local function hasTaggedAncestor(instance: Instance, tagName: string): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		if CollectionService:HasTag(current, tagName) then
			return true
		end
		current = current.Parent
	end
	return false
end

local function hasUnsafeTaggedAncestor(instance: Instance): boolean
	for _, tagName in ipairs(UNSAFE_TAGS) do
		if hasTaggedAncestor(instance, tagName) then
			return true
		end
	end
	return false
end

local function hasDestructibleTaggedAncestor(instance: Instance): boolean
	return hasTaggedAncestor(instance, DestructionConfig.Tag)
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

local function getOwnerFacingDirection(owner: any): Vector3?
	local character = owner.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return getHorizontalDirection(rootPart.CFrame.LookVector)
	end

	return nil
end

local function closestPointOnSegment(fromPosition: Vector3, toPosition: Vector3, point: Vector3): Vector3
	local segment = toPosition - fromPosition
	local lengthSquared = segment:Dot(segment)
	if lengthSquared <= 0.0001 then
		return fromPosition
	end

	local alpha = math.clamp((point - fromPosition):Dot(segment) / lengthSquared, 0, 1)
	return fromPosition + segment * alpha
end

local function getPartContactRadius(part: BasePart): number
	return math.clamp(math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.5, 0.35, 3)
end

local function getClosestPointDistance(fromPosition: Vector3, toPosition: Vector3, point: Vector3): number
	return (point - closestPointOnSegment(fromPosition, toPosition, point)).Magnitude
end

local function addCombatantHurtbox(entries, model: Model, userId: number?, teamName: string?, isBot: boolean)
	if typeof(userId) ~= "number" then
		return
	end

	local rootPart = model:FindFirstChild("HumanoidRootPart")
	local center = if rootPart and rootPart:IsA("BasePart") then rootPart.Position else model:GetPivot().Position
	local parts = {}
	local broadRadius = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		if not descendant:IsA("BasePart") then
			continue
		end

		local radius = getPartContactRadius(descendant)
		broadRadius = math.max(broadRadius, (descendant.Position - center).Magnitude + radius)
		table.insert(parts, {
			part = descendant,
			radius = radius,
		})
	end

	if #parts == 0 then
		return
	end

	table.insert(entries, {
		userId = userId,
		teamName = teamName,
		isBot = isBot,
		center = center,
		broadRadius = broadRadius,
		parts = parts,
	})
end

local function getCombatantHurtboxes(currentTime: number)
	if currentTime - combatantHurtboxCache.updatedAt <= 0.1 then
		return combatantHurtboxCache.entries
	end

	local entries = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character and humanoid and humanoid.Health > 0 then
			addCombatantHurtbox(entries, character, player.UserId, nil, false)
		end
	end

	for _, bot in ipairs(StudioAICombatants.GetAliveBots({})) do
		local userId = if typeof(bot.userId) == "number" then bot.userId else nil
		local teamName = if typeof(bot.teamName) == "string" then bot.teamName else nil
		if bot.model and bot.model:IsA("Model") then
			addCombatantHurtbox(entries, bot.model, userId, teamName, true)
		end
	end

	combatantHurtboxCache.updatedAt = currentTime
	combatantHurtboxCache.entries = entries
	return entries
end

local function findSweptPlayerContact(state: ProjectileState, nextPosition: Vector3, currentTime: number)
	local token = RuntimeProfiler.Begin("Server/BombProjectile/FindSweptPlayerContact")
	if state.collision.playerContactExplodes ~= true and state.collision.playerContactImpacts ~= true then
		RuntimeProfiler.End("Server/BombProjectile/FindSweptPlayerContact", token)
		return nil
	end

	local sweepRadius = math.max(state.physics.radius, 0)
	local scannedParts = 0
	local ownerUserId = getOwnerUserId(state.owner)
	local ownerTeam = nil
	local ownerIdentity = StudioAICombatants.GetOwnerIdentity(state.owner)
	if ownerIdentity then
		ownerTeam = ownerIdentity.teamName
	end

	for _, entry in ipairs(getCombatantHurtboxes(currentTime)) do
		if entry.userId == ownerUserId then
			continue
		end
		if entry.isBot and ownerTeam and entry.teamName == ownerTeam then
			continue
		end
		if getClosestPointDistance(state.position, nextPosition, entry.center) > sweepRadius + entry.broadRadius then
			continue
		end

		for _, hurtbox in ipairs(entry.parts) do
			local descendant = hurtbox.part
			if not (descendant and descendant.Parent) then
				continue
			end

			scannedParts += 1
			local contactPoint = closestPointOnSegment(state.position, nextPosition, descendant.Position)
			local contactRadius = sweepRadius + hurtbox.radius
			if (descendant.Position - contactPoint).Magnitude <= contactRadius then
				local normal = if state.velocity.Magnitude > 0.05 then -state.velocity.Unit else Vector3.yAxis
				RuntimeProfiler.Count("Server/BombProjectile/SweptPlayerPartsScanned", scannedParts)
				RuntimeProfiler.End("Server/BombProjectile/FindSweptPlayerContact", token)
				return {
					position = contactPoint,
					normal = normal,
					hitInstance = descendant,
				}
			end
		end
	end

	RuntimeProfiler.Count("Server/BombProjectile/SweptPlayerPartsScanned", scannedParts)
	RuntimeProfiler.End("Server/BombProjectile/FindSweptPlayerContact", token)
	return nil
end

local function resolveGroundRollDirection(owner: any, aimDirection: Vector3): Vector3
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

local setBasePartTransparency

local function registerCollisionGroup(name: string)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
end

local function setGroupsCollidable(groupA: string, groupB: string, collidable: boolean)
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(groupA, groupB, collidable)
	end)
end

local function configureCollisionGroups()
	registerCollisionGroup(BOMB_PROJECTILE_COLLISION_GROUP)
	registerCollisionGroup(PRACTICE_RANGE_BOMB_BARRIER_COLLISION_GROUP)
	setGroupsCollidable("Default", PRACTICE_RANGE_BOMB_BARRIER_COLLISION_GROUP, false)
	setGroupsCollidable(BOMB_PROJECTILE_COLLISION_GROUP, PRACTICE_RANGE_BOMB_BARRIER_COLLISION_GROUP, true)
	setGroupsCollidable(BOMB_PROJECTILE_COLLISION_GROUP, "Default", true)
end

local function setProjectileCollisionGroup(instance: Instance)
	if instance:IsA("BasePart") then
		pcall(function()
			instance.CollisionGroup = BOMB_PROJECTILE_COLLISION_GROUP
		end)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			pcall(function()
				descendant.CollisionGroup = BOMB_PROJECTILE_COLLISION_GROUP
			end)
		end
	end
end

local function preparePhysicalProjectile(projectileId: string, owner: any, bombType: string, skinId: string, visuals): (Instance, BasePart)
	local hideBaseVisual = typeof(visuals) == "table" and visuals.hideBaseVisual == true
	local visualScale = if typeof(visuals) == "table" and typeof(visuals.visualScale) == "number"
		then math.max(visuals.visualScale, 0.05)
		else BombConfig.ProjectileVisualScale
	local projectile, rootPart = BombVisualUtil.CreateBombVisual(skinId, "BombProjectile_" .. projectileId, {
		anchored = false,
		canCollide = true,
		canQuery = true,
		massless = false,
		effectState = {
			vfx = not hideBaseVisual,
			fuseSpark = not hideBaseVisual,
			trail = not hideBaseVisual,
		},
		visualScale = visualScale,
	})
	projectile.Name = "BombProjectile_" .. projectileId
	if projectile:IsA("Model") then
		projectile.PrimaryPart = rootPart
	end
	setProjectileCollisionGroup(projectile)
	if hideBaseVisual then
		setBasePartTransparency(projectile, 1)
	end

	projectile:SetAttribute("ProjectileId", projectileId)
	projectile:SetAttribute("OwnerUserId", getOwnerUserId(owner))
	projectile:SetAttribute("BombType", bombType)
	projectile:SetAttribute("BombSkinId", skinId)
	rootPart:SetAttribute("ProjectileId", projectileId)
	rootPart:SetAttribute("OwnerUserId", getOwnerUserId(owner))
	rootPart:SetAttribute("BombType", bombType)
	rootPart:SetAttribute("BombSkinId", skinId)
	return projectile, rootPart
end

local function setPhysicalNetworkOwner(projectile: Instance)
	for _, descendant in ipairs(projectile:GetDescendants()) do
		if descendant:IsA("BasePart") then
			pcall(function()
				descendant:SetNetworkOwner(nil)
			end)
		end
	end
	if projectile:IsA("BasePart") then
		pcall(function()
			projectile:SetNetworkOwner(nil)
		end)
	end
end

local function setPhysicalMotion(projectile: Instance, velocity: Vector3, angularVelocity: Vector3)
	for _, descendant in ipairs(projectile:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = velocity
			descendant.AssemblyAngularVelocity = angularVelocity
		end
	end
	if projectile:IsA("BasePart") then
		projectile.AssemblyLinearVelocity = velocity
		projectile.AssemblyAngularVelocity = angularVelocity
	end
end

setBasePartTransparency = function(instance: Instance, transparency: number)
	transparency = math.clamp(transparency, 0, 1)
	if instance:IsA("BasePart") then
		instance.Transparency = transparency
		instance.CastShadow = transparency < 1
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Transparency = transparency
			descendant.CastShadow = transparency < 1
		end
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

local function getAttachedPosition(state: ProjectileState): Vector3
	local attachment = state.attached
	if not attachment then
		return state.position
	end

	local instance = attachment.instance
	if instance and instance.Parent and attachment.localPosition then
		attachment.position = instance.CFrame:PointToWorldSpace(attachment.localPosition)
	end

	return attachment.position
end

local function getFrozenUntil(result, currentTime: number): number?
	local frozenUntil = tonumber(result.frozenUntil)
	if frozenUntil and frozenUntil > currentTime then
		return frozenUntil
	end

	local durationSeconds = tonumber(result.durationSeconds)
	if durationSeconds and durationSeconds > 0 then
		return currentTime + durationSeconds
	end

	return nil
end

local function applyFreezeResult(state: ProjectileState, result, currentTime: number): boolean
	if typeof(result) ~= "table" then
		return false
	end
	if state.frozenUntil and currentTime < state.frozenUntil then
		return true
	end

	local frozenUntil = getFrozenUntil(result, currentTime)
	if not frozenUntil then
		return false
	end

	local position = if typeof(result.position) == "Vector3"
		then result.position
		elseif state.attached
			then getAttachedPosition(state)
			else getPhysicalPosition(state)
	local velocity = readFiniteVector(result.velocity, getPhysicalVelocity(state))

	state.frozenUntil = frozenUntil
	state.frozenVelocity = velocity
	state.frozenPosition = position
	state.frozenBy = if typeof(result.frozenBy) == "string" then result.frozenBy else nil
	state.position = position
	state.lastPosition = position
	state.velocity = Vector3.zero
	state.settled = true
	state.grounded = false
	state.burrow = nil

	destroyPhysicalProjectile(state)
	fireSnapshot(state, currentTime, true)
	return true
end

local function releaseFrozenProjectile(state: ProjectileState, currentTime: number)
	if not state.frozenUntil or currentTime < state.frozenUntil then
		return
	end

	local restoreVelocity = state.frozenVelocity
	local frozenPosition = state.frozenPosition
	state.frozenUntil = nil
	state.frozenVelocity = nil
	state.frozenPosition = nil
	state.frozenBy = nil

	if frozenPosition then
		state.position = frozenPosition
		state.lastPosition = frozenPosition
	end

	if restoreVelocity and restoreVelocity.Magnitude > 0.05 and not state.attached then
		state.velocity = restoreVelocity
		state.settled = false
		state.grounded = false
	else
		state.velocity = Vector3.zero
	end

	fireSnapshot(state, currentTime, true)
end

local function stepFrozenProjectile(state: ProjectileState, fixedDt: number, currentTime: number): boolean
	local frozenUntil = state.frozenUntil
	if not frozenUntil then
		return false
	end
	if currentTime >= frozenUntil then
		releaseFrozenProjectile(state, currentTime)
		return false
	end

	state.explodeAt += fixedDt
	local frozenPosition = state.frozenPosition or state.position
	state.position = frozenPosition
	state.lastPosition = frozenPosition
	state.velocity = Vector3.zero
	state.settled = true
	state.grounded = false

	destroyPhysicalProjectile(state)
	fireSnapshot(state, currentTime, false)
	return true
end

local function getAttachNormal(result): Vector3
	local normal = if typeof(result) == "table" then result.normal else nil
	if typeof(normal) == "Vector3" and normal.Magnitude > 0.05 then
		return normal.Unit
	end
	return Vector3.yAxis
end

local function attachProjectile(state: ProjectileState, result, currentTime: number): boolean
	if typeof(result) ~= "table" then
		return false
	end

	local position = readFiniteVector(result.position, state.position)
	local instance = if typeof(result.attachInstance) == "Instance" and result.attachInstance:IsA("BasePart")
		then result.attachInstance
		else nil
	local normal = getAttachNormal(result)

	destroyPhysicalProjectile(state)
	state.position = position
	state.lastPosition = position
	state.velocity = Vector3.zero
	state.settled = true
	state.grounded = false
	state.burrow = nil
	state.attached = {
		instance = instance,
		localPosition = if instance then instance.CFrame:PointToObjectSpace(position) else nil,
		position = position,
		normal = normal,
		targetKind = if typeof(result.targetKind) == "string" then result.targetKind else nil,
	}

	local ownerUserId, ownerTeam = getOwnerVisualIdentity(state.owner)
	fireEffect("ProjectileAttach", {
		player = state.owner,
		ownerUserId = ownerUserId,
		ownerTeam = ownerTeam,
		projectileId = state.id,
		customProjectile = true,
		bombSkinId = state.skinId,
		position = position,
		velocity = Vector3.zero,
		remainingFuse = math.max(state.explodeAt - currentTime, 0),
		serverTime = currentTime,
		attached = true,
		attachInstance = instance,
		targetKind = state.attached.targetKind,
		normal = normal,
		visuals = state.visuals,
	})
	fireSnapshot(state, currentTime, true)
	return true
end

local function spawnPhysicalProjectile(state: ProjectileState): Instance?
	if state.physicalProjectile and state.physicalProjectile.Parent then
		return state.physicalProjectile
	end

	local projectile, rootPart = preparePhysicalProjectile(state.id, state.owner, state.bombType, state.skinId, state.visuals)
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
	setPhysicalNetworkOwner(projectile)

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
	params.CollisionGroup = BOMB_PROJECTILE_COLLISION_GROUP
	params.RespectCanCollide = state.collision.respectCanCollide ~= false
	return params
end

local function getAcceleration(physics: ProjectilePhysics.PhysicsConfig, hasImpacted: boolean?): Vector3
	return Vector3.new(0, -ProjectilePhysics.GetGravity(physics, hasImpacted), 0)
end

local function resetProjectileTimeScaleTarget(state: ProjectileState)
	state.targetTimeScale = 1
	state.targetTimeScaleSource = nil
end

local function updateProjectileTimeScale(state: ProjectileState, fixedDt: number): number
	local targetTimeScale = math.clamp(tonumber(state.targetTimeScale) or 1, 0.005, 1)
	local currentTimeScale = math.clamp(tonumber(state.timeScale) or 1, 0.005, 1)
	local rate = if targetTimeScale < currentTimeScale
		then math.max(tonumber(state.timeScaleEnterRate) or 7.5, 0.1)
		else math.max(tonumber(state.timeScaleExitRate) or 5.5, 0.1)
	local alpha = 1 - math.exp(-rate * math.max(fixedDt, 0))
	local nextTimeScale = currentTimeScale + (targetTimeScale - currentTimeScale) * math.clamp(alpha, 0, 1)

	if math.abs(nextTimeScale - targetTimeScale) < 0.001 then
		nextTimeScale = targetTimeScale
	end

	state.timeScale = math.clamp(nextTimeScale, 0.005, 1)
	if targetTimeScale < 0.995 and typeof(state.targetTimeScaleSource) == "string" then
		state.timeScaleSource = state.targetTimeScaleSource
	elseif state.timeScale >= 0.995 then
		state.timeScale = 1
		state.timeScaleSource = nil
	end
	state.timeScaleStrength = if state.timeScaleSource then math.clamp(1 - state.timeScale, 0, 1) else 0

	return fixedDt * state.timeScale
end

fireSnapshot = function(state: ProjectileState, currentTime: number, force: boolean?)
	local snapshotHz = if state.settled or state.attached or state.frozenUntil then BombProjectileConfig.SettledSnapshotHz else BombProjectileConfig.SnapshotHz
	local interval = 1 / math.max(snapshotHz, 1)
	if not force and currentTime < state.nextSnapshotAt then
		return
	end

	if state.attached then
		state.position = getAttachedPosition(state)
	end
	state.nextSnapshotAt = currentTime + interval

	local frozen = state.frozenUntil ~= nil and currentTime < state.frozenUntil
	local burrowing = state.burrow ~= nil
	if not force and state.lastSnapshotPosition then
		local minPositionDelta = math.max(tonumber(BombProjectileConfig.SnapshotMinPositionDelta) or 0.35, 0)
		local minVelocityDelta = math.max(tonumber(BombProjectileConfig.SnapshotMinVelocityDelta) or 2, 0)
		local maxSilence = math.max(tonumber(BombProjectileConfig.SnapshotMaxSilenceSeconds) or 0.25, interval)
		local positionChanged = (state.position - state.lastSnapshotPosition).Magnitude >= minPositionDelta
		local velocityChanged = (state.velocity - (state.lastSnapshotVelocity or Vector3.zero)).Magnitude >= minVelocityDelta
		local stateChanged = state.settled ~= state.lastSnapshotSettled
			or state.grounded ~= state.lastSnapshotGrounded
			or (state.attached ~= nil) ~= state.lastSnapshotAttached
			or frozen ~= state.lastSnapshotFrozen
			or burrowing ~= state.lastSnapshotBurrowing
		local stale = typeof(state.lastSnapshotAt) ~= "number" or currentTime - state.lastSnapshotAt >= maxSilence
		if not (positionChanged or velocityChanged or stateChanged or stale) then
			RuntimeProfiler.Count("Server/BombProjectile/SnapshotsSkippedUnchanged")
			return
		end
	end

	state.lastSnapshotAt = currentTime
	state.lastSnapshotPosition = state.position
	state.lastSnapshotVelocity = state.velocity
	state.lastSnapshotSettled = state.settled
	state.lastSnapshotGrounded = state.grounded
	state.lastSnapshotAttached = state.attached ~= nil
	state.lastSnapshotFrozen = frozen
	state.lastSnapshotBurrowing = burrowing

	local ownerUserId, ownerTeam = getOwnerVisualIdentity(state.owner)
	queueSnapshotPayload({
		player = state.owner,
		ownerUserId = ownerUserId,
		ownerTeam = ownerTeam,
		projectileId = state.id,
		customProjectile = true,
		sourceType = state.sourceType,
		bombSkinId = state.skinId,
		position = state.position,
		velocity = state.velocity,
		acceleration = getAcceleration(state.physics, state.hasImpacted),
		serverTime = currentTime,
		remainingFuse = math.max(state.explodeAt - currentTime, 0),
		settled = state.settled,
		grounded = state.grounded,
		attached = state.attached ~= nil,
		targetKind = if state.attached then state.attached.targetKind else nil,
		radius = state.physics.radius,
		visuals = state.visuals,
		visualScale = state.visuals.visualScale,
		physicalProjectile = state.physicalProjectile,
		frozen = frozen,
		frozenUntil = state.frozenUntil,
		frozenBy = state.frozenBy,
		timeScale = state.timeScale,
		timeScaleSource = state.timeScaleSource,
		infinitySlowed = state.timeScaleSource == "Infinity" and state.timeScale < 0.995,
		infinityStrength = state.timeScaleSource == "Infinity" and state.timeScaleStrength or 0,
		burrowing = burrowing,
	})
	if force then
		flushSnapshotBatch(currentTime, true)
	end
end

local function fireImpact(
	state: ProjectileState,
	hit: RaycastResult,
	hitPosition: Vector3,
	hitNormal: Vector3,
	incomingVelocity: Vector3
): boolean
	local currentTime = now()
	if currentTime - state.lastImpactAt < 0.035 then
		return true
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
		return false
	end
	if impactResult.kind == RESULT_KIND.Block then
		return true
	end
	if impactResult.kind == RESULT_KIND.ExplodeProjectile then
		local explodePosition = if typeof(impactResult.position) == "Vector3" then impactResult.position else hitPosition
		explodeProjectile(state, explodePosition)
		return false
	end
	if impactResult.kind == RESULT_KIND.AttachProjectile and attachProjectile(state, impactResult, currentTime) then
		return false
	end
	if impactResult.kind == RESULT_KIND.RedirectProjectile and redirectProjectile(state, impactResult, currentTime) then
		return false
	end
	if impactResult.kind == RESULT_KIND.BurrowProjectile and startBurrowProjectile(state, impactResult, currentTime) then
		return false
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

	if state.collision.directHitExplodes == true and not state.destroyed then
		state.position = hitPosition
		explodeProjectile(state, hitPosition, {
			directHit = true,
			sourceDetail = "Direct",
		})
		return false
	end

	return true
end

local function fireContactImpact(state: ProjectileState, contact): boolean
	if typeof(contact) ~= "table" or typeof(contact.position) ~= "Vector3" then
		return true
	end

	local currentTime = now()
	if currentTime - state.lastImpactAt < 0.035 then
		return true
	end

	local hitNormal = if typeof(contact.normal) == "Vector3" and contact.normal.Magnitude > 0.05
		then contact.normal.Unit
		else Vector3.yAxis
	local incomingVelocity = state.velocity
	local impactResult = AbilityService:RunHook("OnBeforeProjectileImpact", {
		projectileId = state.id,
		owner = state.owner,
		position = contact.position,
		normal = hitNormal,
		incomingVelocity = incomingVelocity,
		hit = nil,
		hitInstance = contact.hitInstance,
		customProjectile = true,
		playerContact = true,
	})
	local handled = impactResult.kind ~= nil and impactResult.kind ~= RESULT_KIND.Continue
	if not handled and state.collision.playerContactExplodes ~= true then
		return true
	end
	state.lastImpactAt = currentTime

	if impactResult.kind == RESULT_KIND.DestroyProjectile or impactResult.kind == RESULT_KIND.Absorb then
		BombProjectileService:DestroyProjectile(state.id, "Impact")
		return false
	end
	if impactResult.kind == RESULT_KIND.Block then
		return true
	end
	if impactResult.kind == RESULT_KIND.ExplodeProjectile then
		local explodePosition = if typeof(impactResult.position) == "Vector3" then impactResult.position else contact.position
		explodeProjectile(state, explodePosition, {
			directHit = true,
			sourceDetail = "Direct",
		})
		return false
	end
	if impactResult.kind == RESULT_KIND.AttachProjectile and attachProjectile(state, impactResult, currentTime) then
		return false
	end
	if impactResult.kind == RESULT_KIND.RedirectProjectile and redirectProjectile(state, impactResult, currentTime) then
		return false
	end
	if impactResult.kind == RESULT_KIND.BurrowProjectile and startBurrowProjectile(state, impactResult, currentTime) then
		return false
	end

	fireEffect("Impact", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		bombSkinId = state.skinId,
		position = contact.position,
		projectilePosition = state.position,
		impactNormal = hitNormal,
		impactVelocity = incomingVelocity,
		postImpactVelocity = state.velocity,
		acceleration = getAcceleration(state.physics, state.hasImpacted),
		hitInstance = contact.hitInstance,
		settled = state.settled,
		physicalProjectile = state.physicalProjectile,
		playerContact = true,
	})

	if state.collision.playerContactExplodes == true and not state.destroyed then
		state.position = contact.position
		explodeProjectile(state, contact.position, {
			directHit = true,
			sourceDetail = "Direct",
		})
		return false
	end

	return true
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

function redirectProjectile(state: ProjectileState, result, currentTime: number): boolean
	if typeof(result) ~= "table" then
		return false
	end

	local origin = readFiniteVector(result.origin, state.position)
	local aimDirection = readFiniteVector(result.aimDirection, state.velocity)
	if aimDirection.Magnitude <= 0.05 then
		aimDirection = Vector3.zAxis
	end

	if isValidOwner(result.owner) then
		state.owner = result.owner
	end
	local resultSourceType = if typeof(result.sourceType) == "string" and result.sourceType ~= ""
		then result.sourceType
		else nil
	local resultSourceId = if typeof(result.sourceId) == "string" and result.sourceId ~= "" then result.sourceId else nil
	if resultSourceType then
		state.sourceType = resultSourceType
	end
	if resultSourceType or resultSourceId or result.reflected == true then
		state.explosion = table.clone(if typeof(state.explosion) == "table" then state.explosion else {})
		if resultSourceType then
			state.explosion.sourceType = resultSourceType
		end
		if resultSourceId then
			state.explosion.sourceId = resultSourceId
			state.explosion.abilityId = resultSourceId
		end
		if result.reflected == true then
			state.explosion.reflected = true
			state.explosion.reflectorUserId = getOwnerUserId(result.owner)
		end
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
	state.rangeOrigin = origin
	state.velocity = ProjectilePhysics.GetLaunchVelocity(aimDirection, state.physics)
	state.launchedAt = currentTime
	state.settled = false
	state.hasImpacted = false
	state.grounded = false
	state.attached = nil
	state.burrow = nil
	state.groundRollDirection = resolveGroundRollDirection(state.owner, aimDirection)

	local remainingFuse = math.max(state.explodeAt - currentTime, 0)
	local ownerUserId, ownerTeam = getOwnerVisualIdentity(state.owner)
	fireEffect("Throw", {
		player = state.owner,
		ownerUserId = ownerUserId,
		ownerTeam = ownerTeam,
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
		visuals = state.visuals,
		visualScale = state.visuals.visualScale,
		snapshotHz = BombProjectileConfig.SnapshotHz,
	})
	fireSnapshot(state, currentTime, true)
	return true
end

local function countDebrisTargets(debrisPayloads): number
	if typeof(debrisPayloads) ~= "table" then
		return 0
	end
	if typeof(debrisPayloads.targetsHit) == "number" then
		return debrisPayloads.targetsHit
	end
	return #debrisPayloads
end

local function carveBurrowPosition(state: ProjectileState, burrow: ProjectileBurrowState, position: Vector3, currentTime: number)
	local debrisPayloads = DestructionService:DestroySphere(position, burrow.carveRadius, {
		sourceType = "Ability",
		sourceId = burrow.abilityId,
		bombId = state.id,
		ownerUserId = getOwnerUserId(state.owner),
		timestamp = currentTime,
	}, {
		skipDebrisWeld = true,
	})

	if countDebrisTargets(debrisPayloads) > 0 then
		fireEffect("TerrainDebris", {
			payloads = debrisPayloads,
		})
	end
end

local function readBurrowDirection(result, state: ProjectileState): Vector3
	local direction = if typeof(result.direction) == "Vector3"
		then result.direction
		elseif typeof(result.aimDirection) == "Vector3" then result.aimDirection
		else state.velocity
	if direction.Magnitude <= 0.05 then
		direction = Vector3.zAxis
	end
	return direction.Unit
end

function startBurrowProjectile(state: ProjectileState, result, currentTime: number): boolean
	if typeof(result) ~= "table" then
		return false
	end

	local direction = readBurrowDirection(result, state)
	local speed = readNumber(result.speed, 58, 1, 220)
	local maxDistance = readNumber(result.maxDistance, 34, 1, 220)
	local maxDuration = readNumber(result.maxDuration, 0.75, 0.05, 5)
	local carveRadius = readNumber(result.carveRadius, 4.4, 0.5, 24)
	local carveStepDistance = readNumber(result.carveStepDistance, carveRadius * 0.8, 0.5, 32)
	local effectInterval = readNumber(result.effectInterval, 0.075, 0.02, 0.5)
	local startInset = readNumber(result.startInset, math.min(carveRadius * 0.45, 2.5), 0, 12)
	local startPosition = readFiniteVector(result.position, state.position) + direction * startInset
	local abilityId = if typeof(result.abilityId) == "string" and result.abilityId ~= "" then result.abilityId else "DrillBomb"
	local burrowEndsAt = currentTime + maxDuration

	destroyPhysicalProjectile(state)
	state.position = startPosition
	state.lastPosition = startPosition
	state.velocity = direction * speed
	state.explodeAt = math.max(state.explodeAt, burrowEndsAt)
	state.settled = false
	state.hasImpacted = true
	state.grounded = false
	state.attached = nil
	state.burrow = {
		abilityId = abilityId,
		direction = direction,
		startPosition = startPosition,
		startedAt = currentTime,
		endsAt = burrowEndsAt,
		remainingDistance = maxDistance,
		speed = speed,
		carveRadius = carveRadius,
		carveStepDistance = carveStepDistance,
		effectInterval = effectInterval,
		lastCarvePosition = startPosition,
		nextEffectAt = currentTime,
	}

	local burrow = state.burrow
	if burrow then
		carveBurrowPosition(state, burrow, startPosition, currentTime)
	end
	fireEffect("ProjectileBurrowStart", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		bombType = state.bombType,
		bombSkinId = state.skinId,
		position = startPosition,
		direction = direction,
		radius = carveRadius,
		speed = speed,
		remainingFuse = math.max(state.explodeAt - currentTime, 0),
		serverTime = currentTime,
		visuals = state.visuals,
	})
	fireSnapshot(state, currentTime, true)
	return true
end

local function shouldBurrowStopForHit(hit: RaycastResult?): boolean
	if not hit then
		return false
	end
	local instance = hit.Instance
	if not (instance and instance:IsA("BasePart")) then
		return true
	end
	if hasUnsafeTaggedAncestor(instance) then
		return true
	end
	return not hasDestructibleTaggedAncestor(instance)
end

local function stepBurrowProjectile(state: ProjectileState, fixedDt: number, currentTime: number): boolean
	local burrow = state.burrow
	if not burrow then
		return false
	end

	if currentTime >= burrow.endsAt or burrow.remainingDistance <= 0 then
		state.burrow = nil
		fireEffect("ProjectileBurrowEnd", {
			player = state.owner,
			projectileId = state.id,
			customProjectile = true,
			bombSkinId = state.skinId,
			position = state.position,
			direction = burrow.direction,
			serverTime = currentTime,
		})
		explodeProjectile(state, state.position)
		return true
	end

	local travelDistance = math.min(burrow.speed * fixedDt, burrow.remainingDistance)
	local movement = burrow.direction * travelDistance
	local hit = workspace:Raycast(state.position, movement, createRaycastParams(state))
	local nextPosition = state.position + movement
	if shouldBurrowStopForHit(hit) then
		nextPosition = hit.Position - burrow.direction * math.min(math.max(state.physics.radius, 0.1), 1.5)
		burrow.remainingDistance = 0
	end

	state.lastPosition = state.position
	state.position = nextPosition
	state.velocity = burrow.direction * burrow.speed
	burrow.remainingDistance -= travelDistance

	if (state.position - burrow.lastCarvePosition).Magnitude >= burrow.carveStepDistance or burrow.remainingDistance <= 0 then
		burrow.lastCarvePosition = state.position
		carveBurrowPosition(state, burrow, state.position, currentTime)
	end

	if currentTime >= burrow.nextEffectAt or burrow.remainingDistance <= 0 then
		burrow.nextEffectAt = currentTime + burrow.effectInterval
		fireEffect("ProjectileBurrowStep", {
			player = state.owner,
			projectileId = state.id,
			customProjectile = true,
			bombSkinId = state.skinId,
			position = state.position,
			lastPosition = state.lastPosition,
			direction = burrow.direction,
			radius = burrow.carveRadius,
			speed = burrow.speed,
			remainingDistance = burrow.remainingDistance,
			serverTime = currentTime,
		})
	end
	fireSnapshot(state, currentTime, false)
	return true
end

local function handleStepHook(state: ProjectileState, nextPosition: Vector3, currentTime: number, fixedDt: number): boolean
	if type(AbilityService.HasHookCandidates) == "function" and not AbilityService:HasHookCandidates("OnProjectileStep") then
		return true
	end

	local token = RuntimeProfiler.Begin("Server/BombProjectile/AbilityHook/OnProjectileStep")
	local stepResult = AbilityService:RunHook("OnProjectileStep", {
		projectileId = state.id,
		owner = state.owner,
		sourceType = state.sourceType,
		bombType = state.bombType,
		bombSkinId = state.skinId,
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
		attached = state.attached ~= nil,
		deltaTime = fixedDt,
	})
	RuntimeProfiler.End("Server/BombProjectile/AbilityHook/OnProjectileStep", token)

	if stepResult.kind == RESULT_KIND.DestroyProjectile or stepResult.kind == RESULT_KIND.Absorb then
		BombProjectileService:DestroyProjectile(state.id, "Step")
		return false
	end
	if stepResult.kind == RESULT_KIND.ExplodeProjectile then
		if typeof(stepResult.position) == "Vector3" then
			explodeProjectile(state, stepResult.position)
		else
			explodeProjectile(state)
		end
		return false
	end
	if stepResult.kind == RESULT_KIND.AttachProjectile then
		return not attachProjectile(state, stepResult, currentTime)
	end
	if stepResult.kind == RESULT_KIND.DeferProjectile and typeof(stepResult.deferSeconds) == "number" then
		state.explodeAt += math.clamp(stepResult.deferSeconds, 0, BombConfig.FuseSeconds)
		return true
	end
	if stepResult.kind == RESULT_KIND.RedirectProjectile then
		return not redirectProjectile(state, stepResult, currentTime)
	end
	if stepResult.kind == RESULT_KIND.BurrowProjectile then
		return not startBurrowProjectile(state, stepResult, currentTime)
	end
	if stepResult.kind == RESULT_KIND.FreezeProjectile and applyFreezeResult(state, stepResult, currentTime) then
		return false
	end
	if stepResult.kind == RESULT_KIND.ModifyProjectileTimeScale then
		local targetTimeScale = math.clamp(tonumber(stepResult.timeScale) or 1, 0.005, 1)
		state.targetTimeScale = math.min(state.targetTimeScale or 1, targetTimeScale)
		if typeof(stepResult.timeScaleSource) == "string" then
			state.targetTimeScaleSource = stepResult.timeScaleSource
		end
		if typeof(stepResult.timeScaleEnterRate) == "number" then
			state.timeScaleEnterRate = math.max(stepResult.timeScaleEnterRate, 0.1)
		end
		if typeof(stepResult.timeScaleExitRate) == "number" then
			state.timeScaleExitRate = math.max(stepResult.timeScaleExitRate, 0.1)
		end
		if state.physicalProjectile and state.physicalProjectile.Parent and targetTimeScale < 0.995 then
			state.position = getPhysicalPosition(state)
			state.lastPosition = state.position
			state.velocity = getPhysicalVelocity(state)
			if state.velocity.Magnitude > 0.05 then
				state.settled = false
				state.grounded = false
			end
			destroyPhysicalProjectile(state)
		end
	end
	if stepResult.kind == RESULT_KIND.ModifyProjectileVelocity then
		local velocity = readFiniteVector(stepResult.velocity, state.velocity)
		local maxSpeed = math.max(tonumber(stepResult.maxSpeed) or state.physics.maxSpeed, 1)
		state.velocity = ProjectilePhysics.ClampVelocity(velocity, maxSpeed)
		state.settled = false
		state.grounded = false
		if state.physicalProjectile and state.physicalProjectile.Parent then
			setPhysicalMotion(state.physicalProjectile, state.velocity, Vector3.zero)
		end
	end

	return true
end

function explodeProjectile(state: ProjectileState, position: Vector3?, replayContext)
	activeProjectiles[state.id] = nil
	state.destroyed = true
	clearPendingSnapshot(state.id)
	if typeof(position) == "Vector3" then
		state.position = position
	elseif state.attached then
		state.position = getAttachedPosition(state)
	else
		state.position = getPhysicalPosition(state)
	end
	destroyPhysicalProjectile(state)
	local explosionConfig = state.explosion
	if typeof(replayContext) == "table" then
		explosionConfig = table.clone(if typeof(state.explosion) == "table" then state.explosion else {})
		for key, value in pairs(replayContext) do
			explosionConfig[key] = value
		end
	end
	explode(state.owner, state.position, "Projectile", state.id, state.skinId, explosionConfig)
end

local function enforceRangeLimit(state: ProjectileState): boolean
	local maxRange = math.max(tonumber(state.maxRange) or 0, 0)
	if maxRange <= 0 then
		return false
	end

	local offset = state.position - state.rangeOrigin
	if offset.Magnitude < maxRange then
		return false
	end

	state.position = state.rangeOrigin + offset.Unit * maxRange
	explodeProjectile(state, state.position)
	return true
end

local function stepProjectile(state: ProjectileState, fixedDt: number, currentTime: number)
	local token = RuntimeProfiler.Begin("Server/BombProjectile/StepProjectile")
	if state.destroyed then
		RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
		return
	end
	if not isOwnerActive(state.owner) then
		BombProjectileService:DestroyProjectile(state.id, "OwnerRemoved")
		RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
		return
	end
	if stepFrozenProjectile(state, fixedDt, currentTime) then
		RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
		return
	end
	if currentTime >= state.explodeAt then
		explodeProjectile(state)
		RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
		return
	end
	if stepBurrowProjectile(state, fixedDt, currentTime) then
		RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
		return
	end

	resetProjectileTimeScaleTarget(state)

	if state.attached then
		state.position = getAttachedPosition(state)
		state.velocity = Vector3.zero
		if not handleStepHook(state, state.position, currentTime, fixedDt) then
			RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
			return
		end
		updateProjectileTimeScale(state, fixedDt)
		if not state.destroyed then
			fireSnapshot(state, currentTime, false)
		end
		RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
		return
	end

	if state.physicalProjectile then
		dampGroundedPhysicalProjectile(state, fixedDt)
		state.position = getPhysicalPosition(state)
		state.velocity = getPhysicalVelocity(state)
		if enforceRangeLimit(state) then
			RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
			return
		end
		if not handleStepHook(state, state.position + state.velocity * fixedDt, currentTime, fixedDt) then
			RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
			return
		end
		updateProjectileTimeScale(state, fixedDt)
		if state.destroyed or not state.physicalProjectile then
			if not state.destroyed then
				fireSnapshot(state, currentTime, true)
			end
			RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
			return
		end
		fireSnapshot(state, currentTime, false)
		RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
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

	if not handleStepHook(state, predictedPosition, currentTime, fixedDt) then
		RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
		return
	end
	if state.destroyed then
		RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
		return
	end

	local motionDt = updateProjectileTimeScale(state, fixedDt)
	if not state.settled then
		predictedPosition, predictedVelocity = ProjectilePhysics.Integrate(
			state.position,
			state.velocity,
			motionDt,
			state.physics,
			state.hasImpacted
		)
	end

	local playerContact = findSweptPlayerContact(state, predictedPosition, currentTime)
	if playerContact then
		if state.collision.playerContactImpacts == true then
			if not fireContactImpact(state, playerContact) then
				RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
				return
			end
			if state.destroyed or state.attached then
				RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
				return
			end
		elseif typeof(playerContact.position) == "Vector3" then
			state.position = playerContact.position
			explodeProjectile(state)
			RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
			return
		end
	end

	if state.destroyed then
		RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
		return
	end

	state.lastPosition = state.position
	if not state.settled then
		local physicsToken = RuntimeProfiler.Begin("Server/BombProjectile/ProjectilePhysicsStep")
		local result = ProjectilePhysics.Step(state, motionDt, state.physics, createRaycastParams(state))
		RuntimeProfiler.End("Server/BombProjectile/ProjectilePhysicsStep", physicsToken)
		state.position = result.position
		state.velocity = result.velocity
		state.hasImpacted = result.hasImpacted == true
		state.grounded = result.grounded == true
		if enforceRangeLimit(state) then
			RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
			return
		end
		if result.hit and result.hitPosition and result.hitNormal and result.incomingVelocity then
			if state.grounded then
				spawnPhysicalProjectile(state)
			end
			local continueAfterImpact = fireImpact(state, result.hit, result.hitPosition, result.hitNormal, result.incomingVelocity)
			if state.destroyed then
				RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
				return
			end
			if not continueAfterImpact then
				RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
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
	RuntimeProfiler.End("Server/BombProjectile/StepProjectile", token)
end

local function getProjectileStepInterval(state: ProjectileState, fixedDt: number): number
	if state.burrow then
		return fixedDt
	end
	if state.attached or state.settled or state.frozenUntil then
		return 1 / math.max(tonumber(BombProjectileConfig.SettledStepHz) or 10, 1)
	end

	local speed = math.max(state.velocity.Magnitude, 0)
	if state.grounded or state.physicalProjectile then
		local stepHz = if speed >= 30 then BombProjectileConfig.GroundedStepHz else BombProjectileConfig.SlowGroundedStepHz
		return 1 / math.max(tonumber(stepHz) or 20, 1)
	end
	if state.hasImpacted then
		return 1 / math.max(tonumber(BombProjectileConfig.GroundedStepHz) or 30, 1)
	end

	return fixedDt
end

local function stepAll(fixedDt: number)
	local token = RuntimeProfiler.Begin("Server/BombProjectile/StepAll")
	local currentTime = now()
	local activeCount = 0
	local steppedCount = 0
	local skippedCount = 0
	for _, state in pairs(activeProjectiles) do
		activeCount += 1
		local interval = getProjectileStepInterval(state, fixedDt)
		local stepAccumulator = (state.stepAccumulator or 0) + fixedDt
		local forceStep = currentTime >= state.explodeAt
		if not forceStep and stepAccumulator + 0.000001 < interval then
			state.stepAccumulator = stepAccumulator
			skippedCount += 1
			continue
		end

		state.stepAccumulator = 0
		local maxAdaptiveDt = math.max(tonumber(BombProjectileConfig.MaxAdaptiveStepSeconds) or 0.1, fixedDt)
		stepProjectile(state, math.min(stepAccumulator, maxAdaptiveDt), currentTime)
		steppedCount += 1
	end
	flushSnapshotBatch(currentTime)
	RuntimeProfiler.Gauge("Server/BombProjectile/ActiveProjectiles", activeCount)
	RuntimeProfiler.Count("Server/BombProjectile/AdaptiveSteps", steppedCount)
	RuntimeProfiler.Count("Server/BombProjectile/AdaptiveSkips", skippedCount)
	RuntimeProfiler.End("Server/BombProjectile/StepAll", token)
end

function BombProjectileService:IsEnabled(): boolean
	return BombProjectileConfig.Enabled == true
end

function BombProjectileService:SetHandlers(nextHandlers: HandlerTable)
	handlers = nextHandlers or {}
end

function BombProjectileService:FindProjectileAlongRay(origin: Vector3, direction: Vector3, maxRange: number)
	if
		typeof(origin) ~= "Vector3"
		or typeof(direction) ~= "Vector3"
		or direction.Magnitude <= 0.05
		or typeof(maxRange) ~= "number"
		or maxRange <= 0
	then
		return nil
	end

	local unit = direction.Unit
	local best = nil
	local bestDistance = math.huge
	for projectileId, state in pairs(activeProjectiles) do
		if state.destroyed then
			continue
		end

		local position = getPhysicalPosition(state)
		local projectedDistance = (position - origin):Dot(unit)
		if projectedDistance < 0 or projectedDistance > maxRange then
			continue
		end

		local closestPoint = origin + unit * projectedDistance
		local radius = math.max(tonumber(state.physics.radius) or BombConfig.SweepRadius or 1.5, 1.5)
		if (position - closestPoint).Magnitude > radius + 0.75 then
			continue
		end

		if projectedDistance < bestDistance then
			bestDistance = projectedDistance
			best = {
				projectileId = projectileId,
				position = position,
				rootPart = state.physicalRoot,
				instance = state.physicalProjectile,
				distance = projectedDistance,
				radius = radius,
			}
		end
	end

	return best
end

function BombProjectileService:GetProjectilePosition(projectileId: string): Vector3?
	local state = activeProjectiles[projectileId]
	if not state or state.destroyed then
		return nil
	end
	return getPhysicalPosition(state)
end

function BombProjectileService:ApplyExternalVelocity(projectileId: string, velocity: Vector3): boolean
	local state = activeProjectiles[projectileId]
	if not state or state.destroyed or typeof(velocity) ~= "Vector3" then
		return false
	end

	state.position = getPhysicalPosition(state)
	state.lastPosition = state.position
	state.velocity = velocity
	state.settled = false
	state.grounded = false
	state.attached = nil
	state.burrow = nil

	if state.physicalProjectile and state.physicalProjectile.Parent then
		setPhysicalMotion(state.physicalProjectile, velocity, Vector3.zero)
	end

	fireSnapshot(state, now(), true)
	return true
end

function BombProjectileService:Launch(request): boolean
	RuntimeProfiler.Count("Server/BombProjectile/LaunchRequests")
	if not self:IsEnabled() or typeof(request) ~= "table" then
		return false
	end

	local owner = request.owner
	if not isValidOwner(owner) then
		return false
	end
	local projectileId = request.projectileId
	if typeof(projectileId) ~= "string" or projectileId == "" then
		return false
	end

	local bombType = if typeof(request.bombType) == "string" and request.bombType ~= "" then request.bombType else BombProjectileConfig.BombType.Normal
	local sourceType = if typeof(request.sourceType) == "string" and request.sourceType ~= "" then request.sourceType else nil
	local sourceId = if typeof(request.sourceId) == "string" and request.sourceId ~= "" then request.sourceId else nil
	local skinId = BombSkinConfig.NormalizeSkinId(request.skinId)
	if skinId == "" then
		skinId = BombSkinConfig.DefaultSkinId
	end
	local physics, collision, explosionConfig, visuals, fuseConfig = resolveStateConfig(bombType, request.modifier)
	if not sourceId then
		sourceId = if typeof(explosionConfig.abilityId) == "string" and explosionConfig.abilityId ~= ""
			then explosionConfig.abilityId
			else inferAbilityIdFromProjectileId(projectileId)
	end
	if sourceId and not sourceType then
		sourceType = "Ability"
	end
	if sourceId and (typeof(explosionConfig.abilityId) ~= "string" or explosionConfig.abilityId == "") then
		explosionConfig.abilityId = sourceId
	end
	if sourceType and (typeof(explosionConfig.sourceType) ~= "string" or explosionConfig.sourceType == "") then
		explosionConfig.sourceType = sourceType
	end
	if sourceId and (typeof(explosionConfig.sourceId) ~= "string" or explosionConfig.sourceId == "") then
		explosionConfig.sourceId = sourceId
	end
	local origin = readFiniteVector(request.origin, Vector3.zero)
	local aimDirection = readFiniteVector(request.aimDirection, Vector3.zAxis)
	local launchTime = readNumber(request.launchedAt, now(), 0, math.huge)
	local fuseStartedAt = readNumber(request.fuseStartedAt, launchTime, 0, math.huge)
	local requestedFuse = readNumber(request.remainingFuse, readNumber(fuseConfig.seconds, BombConfig.FuseSeconds, 0.05, 60), 0.05, 60)

	local launchResult = AbilityService:RunHook("OnBeforeProjectileLaunch", {
		owner = owner,
		projectileId = projectileId,
		sourceType = sourceType,
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
		sourceType = sourceType,
		bombType = bombType,
		skinId = skinId,
		rangeOrigin = origin,
		maxRange = math.max(tonumber(collision.maxRange) or 0, 0),
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
		attached = nil,
		destroyed = false,
		nextSnapshotAt = launchTime,
		lastImpactAt = 0,
		frozenUntil = nil,
		frozenVelocity = nil,
		frozenPosition = nil,
		frozenBy = nil,
		timeScale = 1,
		targetTimeScale = 1,
		timeScaleSource = nil,
		targetTimeScaleSource = nil,
		timeScaleEnterRate = nil,
		timeScaleExitRate = nil,
		timeScaleStrength = 0,
		burrow = nil,
		stepAccumulator = 0,
	}

	activeProjectiles[projectileId] = state
	RuntimeProfiler.Count("Server/BombProjectile/LaunchAccepted")
	local ownerIdentity = StudioAICombatants.GetOwnerIdentity(owner)
	local ownerUserId = if ownerIdentity and typeof(ownerIdentity.userId) == "number" then ownerIdentity.userId else getOwnerUserId(owner)
	local ownerTeam = if ownerIdentity and typeof(ownerIdentity.teamName) == "string" and ownerIdentity.teamName ~= ""
		then ownerIdentity.teamName
		else nil
	fireEffect("Throw", {
		player = owner,
		ownerUserId = ownerUserId,
		ownerTeam = ownerTeam,
		projectileId = projectileId,
		customProjectile = true,
		sourceType = sourceType,
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
		visuals = visuals,
		visualScale = visuals.visualScale,
		snapshotHz = BombProjectileConfig.SnapshotHz,
	})
	recordReplayEvent("BombThrown", {
		bombId = projectileId,
		ownerUserId = ownerUserId,
		ownerName = if ownerIdentity then ownerIdentity.name else nil,
		ownerDisplayName = if ownerIdentity then ownerIdentity.displayName else nil,
		ownerTeam = ownerTeam,
		ownerIsNPC = if ownerIdentity then ownerIdentity.isNPC == true else nil,
		sourceType = sourceType,
		sourceId = sourceId,
		abilityName = sourceId,
		abilityId = sourceId,
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
	clearPendingSnapshot(projectileId)
	state.position = if state.attached then getAttachedPosition(state) else getPhysicalPosition(state)
	destroyPhysicalProjectile(state)
	AbilityService:RunHook("OnProjectileDestroyed", {
		owner = state.owner,
		projectileId = state.id,
		sourceType = state.sourceType,
		bombType = state.bombType,
		bombSkinId = state.skinId,
		position = state.position,
		reason = reason or "Destroyed",
		customProjectile = true,
	})
	fireEffect("ProjectileDestroy", {
		player = state.owner,
		projectileId = state.id,
		customProjectile = true,
		sourceType = state.sourceType,
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
		local ownerUserId = if isOwnerActive(owner) then getOwnerUserId(owner) else nil
		local ownerIdentity = if ownerUserId then StudioAICombatants.GetOwnerIdentity(owner) else nil
		local radius = if typeof(state.physics.radius) == "number" then state.physics.radius else nil
		local sizeScale = if radius and typeof(defaultRadius) == "number" and defaultRadius > 0 then radius / defaultRadius else nil

		local position = if state.attached then getAttachedPosition(state) elseif state.physicalProjectile then getPhysicalPosition(state) else state.position
		local velocity = if state.physicalProjectile then getPhysicalVelocity(state) else state.velocity

		table.insert(snapshots, {
			bombId = state.id,
			ownerUserId = ownerUserId,
			ownerName = if ownerIdentity then ownerIdentity.name else nil,
			ownerDisplayName = if ownerIdentity then ownerIdentity.displayName else nil,
			ownerIsNPC = if ownerIdentity then ownerIdentity.isNPC == true else nil,
			bombType = state.bombType,
			bombSkinId = state.skinId,
			cframe = CFrame.new(position),
			assemblyLinearVelocity = velocity,
			radius = radius,
			sizeScale = sizeScale,
			fuseStartedAt = state.fuseStartedAt,
			fuseEndsAt = state.explodeAt,
			settled = state.settled,
			attached = state.attached ~= nil,
		})
	end

	return snapshots
end

function BombProjectileService:OnStart()
	configureCollisionGroups()

	if heartbeatConnection then
		heartbeatConnection:Disconnect()
	end

	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		local heartbeatToken = RuntimeProfiler.Begin("Server/BombProjectile/Heartbeat")
		if not self:IsEnabled() then
			RuntimeProfiler.End("Server/BombProjectile/Heartbeat", heartbeatToken)
			return
		end

		local fixedDt = BombProjectileConfig.FixedStepSeconds
		local maxSteps = math.max(BombProjectileConfig.MaxStepsPerHeartbeat, 1)
		accumulator += math.min(deltaTime, fixedDt * maxSteps)

		local steps = 0
		while accumulator >= fixedDt and steps < maxSteps do
			local stepToken = RuntimeProfiler.Begin("Server/BombProjectile/FixedStep")
			accumulator -= fixedDt
			steps += 1
			stepAll(fixedDt)
			RuntimeProfiler.End("Server/BombProjectile/FixedStep", stepToken)
		end
		if steps >= maxSteps then
			RuntimeProfiler.Count("Server/BombProjectile/MaxStepClamp")
			accumulator = 0
		end
		RuntimeProfiler.Gauge("Server/BombProjectile/FixedStepsLastHeartbeat", steps)
		RuntimeProfiler.End("Server/BombProjectile/Heartbeat", heartbeatToken)
	end)
end

function BombProjectileService:OnPlayerRemoving(player: Player)
	self:ClearPlayerProjectiles(player)
end

return BombProjectileService
