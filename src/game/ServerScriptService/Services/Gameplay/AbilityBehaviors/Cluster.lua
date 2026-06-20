local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)
local ProjectilePhysics = require(ReplicatedStorage.Shared.Bombs.ProjectilePhysics)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityHookResult = AbilityTypes.AbilityHookResult
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext

type ClusterRecord = {
	player: Player,
	skinId: string,
	groupId: string,
}

type MiniRecord = {
	player: Player,
	groupId: string,
	expiresAt: number,
}

type KnockbackGroupRecord = {
	player: Player,
	expiresAt: number,
	targets: { [string]: boolean },
}

local Cluster = {} :: AbilityTypes.ServerBehavior
Cluster.AlwaysRunHooks = table.freeze({
	OnBeforeExplosion = true,
	OnBeforeOwnerBombKnockback = true,
	OnBeforePlayerBombDamage = true,
})

local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5
local PRIMARY_PROJECTILES: { [string]: ClusterRecord } = {}
local MINI_PROJECTILES: { [string]: MiniRecord } = {}
local KNOCKBACK_GROUPS: { [string]: KnockbackGroupRecord } = {}
local projectileSerial = 0
local bombProjectileService = nil

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

local function createProjectileId(prefix: string, player: Player, index: number?): string
	projectileSerial += 1
	return ("%s_%d_%d_%02d_%04d"):format(
		prefix,
		player.UserId,
		math.floor(workspace:GetServerTimeNow() * 1000),
		index or 0,
		projectileSerial % 10000
	)
end

local function buildScaledExplosionConfig(scale: number)
	scale = math.max(scale, 0)
	return {
		innerRadius = BombConfig.InnerRadius * scale,
		nearRadius = BombConfig.NearRadius * scale,
		outerRadius = BombConfig.OuterRadius * scale,
		terrainRadius = (BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius) * scale,
		playerDirectDamage = BombConfig.PlayerDirectDamage * scale,
		playerNearDamageMax = BombConfig.PlayerNearDamageMax * scale,
		playerNearDamageMin = BombConfig.PlayerNearDamageMin * scale,
		playerOuterDamageMax = BombConfig.PlayerOuterDamageMax * scale,
		playerOuterDamageMin = BombConfig.PlayerOuterDamageMin * scale,
		anchorDirectDamage = BombConfig.AnchorDirectDamage * scale,
		anchorNearDamageMax = BombConfig.AnchorNearDamageMax * scale,
		anchorNearDamageMin = BombConfig.AnchorNearDamageMin * scale,
		anchorOuterDamageMax = BombConfig.AnchorOuterDamageMax * scale,
		anchorOuterDamageMin = BombConfig.AnchorOuterDamageMin * scale,
		knockbackHorizontal = BombConfig.KnockbackHorizontal * scale,
		knockbackVertical = BombConfig.KnockbackVertical * scale,
		knockbackMinScale = BombConfig.KnockbackMinScale,
		explosionVisualScale = math.max(scale, 0.05),
	}
end

local function getTrackedPrimary(player: Player, payload): ClusterRecord?
	if typeof(payload) ~= "table" then
		return nil
	end

	local projectileId = payload.projectileId
	if typeof(projectileId) ~= "string" or projectileId == "" then
		return nil
	end

	local record = PRIMARY_PROJECTILES[projectileId]
	if record and record.player == player then
		return record
	end
	return nil
end

local function cleanupProjectileLater(projectileId: string, record: ClusterRecord, delaySeconds: number)
	task.delay(delaySeconds, function()
		if PRIMARY_PROJECTILES[projectileId] == record then
			PRIMARY_PROJECTILES[projectileId] = nil
		end
	end)
end

local function cleanupMiniLater(projectileId: string, record: MiniRecord, delaySeconds: number)
	task.delay(delaySeconds, function()
		if MINI_PROJECTILES[projectileId] == record then
			MINI_PROJECTILES[projectileId] = nil
		end
	end)
end

local function cleanupKnockbackGroupLater(groupId: string, record: KnockbackGroupRecord, delaySeconds: number)
	task.delay(delaySeconds, function()
		if KNOCKBACK_GROUPS[groupId] == record then
			KNOCKBACK_GROUPS[groupId] = nil
		end
	end)
end

local function getProjectileIdFromPayload(payload): string?
	if typeof(payload) ~= "table" then
		return nil
	end

	local projectileId = payload.sourceId or payload.projectileId
	return if typeof(projectileId) == "string" and projectileId ~= "" then projectileId else nil
end

local function getTrackedMini(player: Player, payload): MiniRecord?
	local projectileId = getProjectileIdFromPayload(payload)
	if not projectileId then
		return nil
	end

	local record = MINI_PROJECTILES[projectileId]
	if record and record.player == player then
		if record.expiresAt <= workspace:GetServerTimeNow() then
			MINI_PROJECTILES[projectileId] = nil
			return nil
		end
		return record
	end
	return nil
end

local function getTargetKey(target: any): string?
	if typeof(target) == "Instance" and target:IsA("Player") then
		return "Player:" .. tostring(target.UserId)
	end
	return nil
end

local function getRepeatKnockbackResult(context: ServerHookContext, payload, target: any): AbilityHookResult
	local miniRecord = getTrackedMini(context.player, payload)
	if not miniRecord then
		return AbilityResult.Continue()
	end

	local targetKey = getTargetKey(target)
	if not targetKey then
		return AbilityResult.Continue()
	end

	local group = KNOCKBACK_GROUPS[miniRecord.groupId]
	if not group or group.expiresAt <= context.now then
		group = {
			player = context.player,
			expiresAt = math.max(miniRecord.expiresAt, context.now),
			targets = {},
		}
		KNOCKBACK_GROUPS[miniRecord.groupId] = group
	end

	if not group.targets[targetKey] then
		group.targets[targetKey] = true
		return AbilityResult.Continue()
	end

	local multiplier = math.max(getDefinitionNumber(context.definition, "miniRepeatKnockbackMultiplier", 0), 0)
	if multiplier <= 0 then
		return {
			kind = AbilityResult.Kind.ModifyDamage,
			skipKnockback = true,
		}
	end

	return {
		kind = AbilityResult.Kind.ModifyDamage,
		knockbackMultiplier = multiplier,
	}
end

local function getRingDirections(count: number): { Vector3 }
	count = math.max(math.floor(count), 1)
	local directions = {}
	for index = 1, count do
		local angle = (index - 1) / count * math.pi * 2
		table.insert(directions, Vector3.new(math.cos(angle), 0, math.sin(angle)))
	end
	return directions
end

local function spawnMiniBombs(context: ServerHookContext, record: ClusterRecord, position: Vector3)
	local projectileService = getBombProjectileService()
	if not projectileService then
		return {}
	end

	local definition = context.definition
	local count = math.max(math.floor(getDefinitionNumber(definition, "miniBombCount", 9)), 1)
	local powerScale = getDefinitionNumber(definition, "miniPowerScale", 0.35)
	local fuseSeconds = math.max(getDefinitionNumber(definition, "miniFuseSeconds", 1.1), 0.05)
	local launchSpeed = getDefinitionNumber(definition, "miniLaunchSpeed", 42)
	local upwardVelocity = getDefinitionNumber(definition, "miniUpwardVelocity", 30)
	local gravityScale = getDefinitionNumber(definition, "miniGravityScale", 0.85)
	local radiusScale = math.max(getDefinitionNumber(definition, "miniRadiusScale", 0.45), 0.05)
	local visualScale = math.max(getDefinitionNumber(definition, "miniVisualScale", BombConfig.ProjectileVisualScale * 0.45), 0.05)
	local spawnYOffset = getDefinitionNumber(definition, "miniSpawnYOffset", 1.25)
	local repeatWindowSeconds = math.max(getDefinitionNumber(definition, "miniRepeatKnockbackWindowSeconds", 3), 0)
	local origin = position + Vector3.yAxis * spawnYOffset
	local launchedIds = {}
	local cleanupDelay = fuseSeconds + BombConfig.ProjectileLifetimePadding + repeatWindowSeconds + 1
	local groupRecord: KnockbackGroupRecord = {
		player = record.player,
		expiresAt = context.now + cleanupDelay,
		targets = {},
	}
	KNOCKBACK_GROUPS[record.groupId] = groupRecord
	cleanupKnockbackGroupLater(record.groupId, groupRecord, cleanupDelay)

	for index, direction in ipairs(getRingDirections(count)) do
		local projectileId = createProjectileId("ClusterMini", record.player, index)
		local launched = projectileService:Launch({
			owner = record.player,
			projectileId = projectileId,
			bombType = BombProjectileConfig.BombType.Bouncy,
			skinId = record.skinId,
			origin = origin,
			aimDirection = direction,
			fuseStartedAt = context.now,
			launchedAt = context.now,
			remainingFuse = fuseSeconds,
			modifier = {
				physics = {
					radius = BombConfig.SweepRadius * radiusScale,
					launchSpeed = launchSpeed,
					upwardVelocity = upwardVelocity,
					gravity = workspace.Gravity * gravityScale,
					postImpactGravity = workspace.Gravity * gravityScale,
					maxSpeed = math.max(launchSpeed + math.abs(upwardVelocity), launchSpeed, 1),
					impactResponse = ProjectilePhysics.ImpactResponse.Bounce,
					restitution = getDefinitionNumber(definition, "miniRestitution", 0.34),
					friction = getDefinitionNumber(definition, "miniFriction", 0.28),
					wallFriction = getDefinitionNumber(definition, "miniWallFriction", 0.16),
					groundedFrictionPerSecond = getDefinitionNumber(definition, "miniGroundedFrictionPerSecond", 2),
					minRollSpeed = getDefinitionNumber(definition, "miniMinRollSpeed", 1.5),
					minGroundImpactRollSpeed = getDefinitionNumber(definition, "miniMinGroundImpactRollSpeed", 8),
				},
				collision = {
					directHitExplodes = false,
					playerContactExplodes = false,
					playerContactImpacts = false,
				},
				explosion = buildScaledExplosionConfig(powerScale),
				visuals = {
					visualScale = visualScale,
				},
			},
		})
		if launched then
			local miniRecord: MiniRecord = {
				player = record.player,
				groupId = record.groupId,
				expiresAt = context.now + cleanupDelay,
			}
			MINI_PROJECTILES[projectileId] = miniRecord
			cleanupMiniLater(projectileId, miniRecord, cleanupDelay)
			table.insert(launchedIds, projectileId)
		end
	end

	return launchedIds
end

function Cluster.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getBombProjectileService() ~= nil
end

function Cluster.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local projectileService = getBombProjectileService()
	local rootPart = getCharacterRoot(context.player)
	if not (projectileService and rootPart) then
		return false
	end

	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(context.payload, rootPart.CFrame.LookVector)
	local projectileId = createProjectileId("Cluster", context.player)
	local skinId = BombSkinService:GetEquippedSkinId(context.player)
	local launchSpeed = getDefinitionNumber(context.definition, "projectileLaunchSpeed", BombConfig.ProjectileLaunchSpeed)
	local upwardVelocity = getDefinitionNumber(context.definition, "projectileUpwardVelocity", BombConfig.ProjectileUpwardVelocity)
	local gravityScale = getDefinitionNumber(context.definition, "projectileGravityScale", BombConfig.ProjectileGravityScale)
	local remainingFuse = math.max(getDefinitionNumber(context.definition, "projectileMaxFlightSeconds", BombConfig.FuseSeconds), 0.05)

	local launched = projectileService:Launch({
		owner = context.player,
		projectileId = projectileId,
		bombType = BombProjectileConfig.BombType.Normal,
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
				playerContactImpacts = false,
			},
		},
	})
	if not launched then
		return false
	end

	local record = {
		player = context.player,
		skinId = skinId,
		groupId = projectileId,
	}
	PRIMARY_PROJECTILES[projectileId] = record
	cleanupProjectileLater(projectileId, record, remainingFuse + BombConfig.ProjectileLifetimePadding + 4)

	local state = context.slotState.state
	local clusterBombsThrown = if typeof(state) == "table" and typeof(state.clusterBombsThrown) == "number"
		then state.clusterBombsThrown
		else 0

	return {
		state = {
			clusterBombsThrown = clusterBombsThrown + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "ClusterBombFired",
			payload = {
				projectileId = projectileId,
			},
		},
	}
end

function Cluster.OnBeforeExplosion(context: ServerHookContext)
	local payload = context.context
	local record = getTrackedPrimary(context.player, payload)
	if not record then
		return AbilityResult.Continue()
	end

	local projectileId = payload.projectileId
	PRIMARY_PROJECTILES[projectileId] = nil

	if typeof(payload.position) == "Vector3" then
		spawnMiniBombs(context, record, payload.position)
	end

	return AbilityResult.Continue()
end

function Cluster.OnBeforePlayerBombDamage(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	local target = if typeof(payload) == "table" then payload.target else nil
	return getRepeatKnockbackResult(context, payload, target)
end

function Cluster.OnBeforeOwnerBombKnockback(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	local owner = if typeof(payload) == "table" then payload.owner else nil
	return getRepeatKnockbackResult(context, payload, owner)
end

function Cluster.OnPlayerRemoving(player: Player)
	for projectileId, record in pairs(PRIMARY_PROJECTILES) do
		if record.player == player then
			PRIMARY_PROJECTILES[projectileId] = nil
		end
	end
	for projectileId, record in pairs(MINI_PROJECTILES) do
		if record.player == player then
			MINI_PROJECTILES[projectileId] = nil
		end
	end
	for groupId, record in pairs(KNOCKBACK_GROUPS) do
		if record.player == player then
			KNOCKBACK_GROUPS[groupId] = nil
		end
	end
end

return Cluster
