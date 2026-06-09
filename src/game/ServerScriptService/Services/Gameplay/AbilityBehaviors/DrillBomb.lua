local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local ProjectilePhysics = require(ReplicatedStorage.Shared.Bombs.ProjectilePhysics)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)
local DestructionService = require(ServerScriptService.Services.DestructionService)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext

type DrillRecord = {
	player: Player,
	drilled: boolean,
}

local DrillBomb = {} :: AbilityTypes.ServerBehavior

local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5
local PROJECTILES: { [string]: DrillRecord } = {}
local projectileSerial = 0
local abilityService = nil
local bombProjectileService = nil

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local function getBombProjectileService()
	if bombProjectileService then
		return bombProjectileService
	end

	local serviceModule = ServerScriptService.Services:FindFirstChild("BombProjectileService")
	if serviceModule and serviceModule:IsA("ModuleScript") then
		local ok, service = pcall(require, serviceModule)
		if ok and typeof(service) == "table" then
			bombProjectileService = service
			return bombProjectileService
		end
	end

	return nil
end

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getHorizontalDirection(direction: any): Vector3?
	if typeof(direction) ~= "Vector3" then
		return nil
	end

	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	if horizontal.Magnitude <= MIN_AIM_HORIZONTAL then
		return nil
	end

	return horizontal.Unit
end

local function sanitizeAimDirection(direction: any, fallback: Vector3): Vector3
	local fallbackHorizontal = getHorizontalDirection(fallback) or Vector3.zAxis
	if typeof(direction) ~= "Vector3" then
		return fallbackHorizontal
	end
	if direction.X ~= direction.X or direction.Y ~= direction.Y or direction.Z ~= direction.Z then
		return fallbackHorizontal
	end
	if direction.Magnitude < 0.05 or direction.Magnitude > MAX_AIM_MAGNITUDE then
		return fallbackHorizontal
	end

	local unit = direction.Unit
	local horizontal = getHorizontalDirection(unit)
	if not horizontal then
		horizontal = fallbackHorizontal
		unit = Vector3.new(horizontal.X, unit.Y, horizontal.Z)
	end

	unit = Vector3.new(unit.X, math.clamp(unit.Y, BombConfig.MinAimY, BombConfig.MaxAimY), unit.Z)
	if unit.Magnitude < 0.05 then
		return Vector3.new(fallbackHorizontal.X, 0.15, fallbackHorizontal.Z).Unit
	end

	return unit.Unit
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

local function getThrowOrigin(rootPart: BasePart): Vector3
	return rootPart.CFrame:PointToWorldSpace(BombConfig.ThrowOffset)
end

local function getAimDirectionFromPayload(payload: any, fallbackDirection: Vector3): Vector3
	if typeof(payload) == "table" then
		return sanitizeAimDirection(payload.aimDirection, fallbackDirection)
	end
	return sanitizeAimDirection(fallbackDirection, Vector3.zAxis)
end

local function createProjectileId(player: Player): string
	projectileSerial += 1
	return ("DrillBomb_%d_%d_%04d"):format(player.UserId, math.floor(workspace:GetServerTimeNow() * 1000), projectileSerial % 10000)
end

local function hasUnsafeTaggedAncestor(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		for _, tagName in ipairs(UNSAFE_TAGS) do
			if CollectionService:HasTag(current, tagName) then
				return true
			end
		end
		current = current.Parent
	end
	return false
end

local function hasDestructibleTaggedAncestor(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		if CollectionService:HasTag(current, DestructionConfig.Tag) then
			return true
		end
		current = current.Parent
	end
	return false
end

local function getTrackedProjectile(player: Player, context): DrillRecord?
	if typeof(context) ~= "table" then
		return nil
	end

	local projectileId = context.projectileId
	if typeof(projectileId) ~= "string" or projectileId == "" then
		return nil
	end

	local record = PROJECTILES[projectileId]
	if record and record.player == player then
		return record
	end
	return nil
end

local function isEligibleFloor(definition: AbilityDefinition, hitInstance: any, normal: any): boolean
	if typeof(normal) ~= "Vector3" then
		return false
	end
	if normal.Y < getDefinitionNumber(definition, "drillMinFloorNormalY", 0.68) then
		return false
	end
	if not (typeof(hitInstance) == "Instance" and hitInstance:IsA("BasePart")) then
		return false
	end
	if hasUnsafeTaggedAncestor(hitInstance) then
		return false
	end
	return hasDestructibleTaggedAncestor(hitInstance)
end

local function countDestroyedTargets(debrisPayloads): number
	if typeof(debrisPayloads) ~= "table" then
		return 0
	end
	if typeof(debrisPayloads.targetsHit) == "number" then
		return debrisPayloads.targetsHit
	end
	return #debrisPayloads
end

local function fireDrillEffect(player: Player, projectileId: string, position: Vector3, radius: number, hitInstance: Instance?)
	if not (abilityService and type(abilityService.FireEffect) == "function") then
		return
	end

	abilityService:FireEffect("DrillBombDrilled", {
		player = player,
		abilityId = "DrillBomb",
		projectileId = projectileId,
		position = position,
		radius = radius,
		hitInstance = hitInstance,
	})
end

function DrillBomb.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getBombProjectileService() ~= nil
end

function DrillBomb.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local projectileService = getBombProjectileService()
	local rootPart = getCharacterRoot(context.player)
	if not (projectileService and rootPart) then
		return false
	end

	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(context.payload, rootPart.CFrame.LookVector)
	local projectileId = createProjectileId(context.player)
	local skinId = BombSkinService:GetEquippedSkinId(context.player)
	local launchSpeed = getDefinitionNumber(context.definition, "projectileLaunchSpeed", BombConfig.ProjectileLaunchSpeed)
	local upwardVelocity = getDefinitionNumber(context.definition, "projectileUpwardVelocity", BombConfig.ProjectileUpwardVelocity)
	local gravityScale = getDefinitionNumber(context.definition, "projectileGravityScale", BombConfig.ProjectileGravityScale)
	local remainingFuse = math.max(getDefinitionNumber(context.definition, "projectileMaxFlightSeconds", BombConfig.FuseSeconds), 0.05)

	local launched = projectileService:Launch({
		owner = context.player,
		projectileId = projectileId,
		bombType = BombProjectileConfig.BombType.Drill,
		skinId = skinId,
		origin = origin,
		aimDirection = aimDirection,
		fuseStartedAt = context.now,
		launchedAt = context.now,
		remainingFuse = remainingFuse,
		modifier = {
			physics = {
				launchSpeed = launchSpeed,
				upwardVelocity = upwardVelocity,
				gravity = workspace.Gravity * gravityScale,
				postImpactGravity = workspace.Gravity * gravityScale,
				maxSpeed = math.max(launchSpeed + math.abs(upwardVelocity), launchSpeed, 1),
			},
			collision = {
				directHitExplodes = false,
				playerContactExplodes = false,
			},
		},
	})
	if not launched then
		return false
	end

	PROJECTILES[projectileId] = {
		player = context.player,
		drilled = false,
	}

	local state = context.slotState.state
	local drillsFired = if typeof(state) == "table" and typeof(state.drillsFired) == "number" then state.drillsFired else 0

	return {
		state = {
			drillsFired = drillsFired + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "DrillBombFired",
			payload = {
				projectileId = projectileId,
			},
		},
	}
end

function DrillBomb.OnBeforeProjectileImpact(context: ServerHookContext)
	local payload = context.context
	local record = getTrackedProjectile(context.player, payload)
	if not record then
		return AbilityResult.Continue()
	end

	local projectileId = payload.projectileId
	local position = if typeof(payload.position) == "Vector3" then payload.position else nil
	if not position then
		return AbilityResult.Continue()
	end

	if record.drilled then
		if typeof(payload.normal) == "Vector3" and payload.normal.Y >= getDefinitionNumber(context.definition, "drillMinFloorNormalY", 0.68) then
			PROJECTILES[projectileId] = nil
			return {
				kind = AbilityResult.Kind.ExplodeProjectile,
				position = position,
			}
		end
		return AbilityResult.Continue()
	end

	local hitInstance = payload.hitInstance
	if not isEligibleFloor(context.definition, hitInstance, payload.normal) then
		return AbilityResult.Continue()
	end

	local radius = math.max(getDefinitionNumber(context.definition, "drillRadius", 8), 0.5)
	local debrisPayloads = DestructionService:DestroySphere(position, radius, {
		sourceType = "Ability",
		sourceId = context.abilityId,
		bombId = projectileId,
		ownerUserId = context.player.UserId,
		timestamp = context.now,
	})
	if countDestroyedTargets(debrisPayloads) <= 0 then
		return AbilityResult.Continue()
	end

	record.drilled = true
	fireDrillEffect(context.player, projectileId, position, radius, hitInstance)

	local fallSpeed = math.max(getDefinitionNumber(context.definition, "drillFallSpeed", 78), 1)
	local fallGravityScale = math.max(getDefinitionNumber(context.definition, "drillFallGravityScale", 0.72), 0)
	local exitDepth = math.max(getDefinitionNumber(context.definition, "drillExitDepth", 5), 0)
	return {
		kind = AbilityResult.Kind.RedirectProjectile,
		origin = position - Vector3.yAxis * exitDepth,
		aimDirection = -Vector3.yAxis,
		launchSpeed = fallSpeed,
		upwardVelocity = 0,
		gravity = workspace.Gravity * fallGravityScale,
		postImpactGravity = workspace.Gravity * fallGravityScale,
		maxSpeed = fallSpeed,
		impactResponse = ProjectilePhysics.ImpactResponse.Sandbag,
		restitution = 0,
		friction = 0.9,
		wallFriction = 0.8,
		minRollSpeed = 0,
		minGroundImpactRollSpeed = 0,
	}
end

function DrillBomb.OnProjectileStep(context: ServerHookContext)
	local payload = context.context
	local record = getTrackedProjectile(context.player, payload)
	if not (record and record.drilled) then
		return AbilityResult.Continue()
	end
	if payload.settled ~= true and payload.landed ~= true then
		return AbilityResult.Continue()
	end

	local projectileId = payload.projectileId
	PROJECTILES[projectileId] = nil
	return {
		kind = AbilityResult.Kind.ExplodeProjectile,
		position = if typeof(payload.position) == "Vector3" then payload.position else nil,
	}
end

function DrillBomb.OnStart(service)
	abilityService = service
end

function DrillBomb.OnPlayerRemoving(player: Player)
	for projectileId, record in pairs(PROJECTILES) do
		if record.player == player then
			PROJECTILES[projectileId] = nil
		end
	end
end

return DrillBomb
