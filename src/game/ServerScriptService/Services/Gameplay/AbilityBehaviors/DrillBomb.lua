local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityBehaviorServices = require(ServerScriptService.Services.AbilityBehaviorServices)

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombThrowOrigin = require(ReplicatedStorage.Shared.Common.BombThrowOrigin)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext

type DrillRecord = {
	player: Player,
	burrowing: boolean,
}

local DrillBomb = {} :: AbilityTypes.ServerBehavior

local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5
local PROJECTILES: { [string]: DrillRecord } = {}
local projectileSerial = 0

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local function getBombProjectileService()
	return AbilityBehaviorServices.GetBombProjectileService()
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
	return BombThrowOrigin.GetOrigin(rootPart)
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

local function isEligibleDrillSurface(_definition: AbilityDefinition, hitInstance: any): boolean
	if not (typeof(hitInstance) == "Instance" and hitInstance:IsA("BasePart")) then
		return false
	end
	if hasUnsafeTaggedAncestor(hitInstance) then
		return false
	end
	return hasDestructibleTaggedAncestor(hitInstance)
end

local function getIncomingDirection(payload): Vector3?
	if typeof(payload) ~= "table" then
		return nil
	end
	local velocity = payload.incomingVelocity
	if typeof(velocity) == "Vector3" and velocity.Magnitude > 0.05 then
		return velocity.Unit
	end
	velocity = payload.currentVelocity
	if typeof(velocity) == "Vector3" and velocity.Magnitude > 0.05 then
		return velocity.Unit
	end
	return nil
end

local function cleanupProjectileLater(projectileId: string, record: DrillRecord, delaySeconds: number)
	task.delay(delaySeconds, function()
		if PROJECTILES[projectileId] == record then
			PROJECTILES[projectileId] = nil
		end
	end)
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
	local cleanupDelay = math.max(
		remainingFuse + BombConfig.ProjectileLifetimePadding + 4,
		getDefinitionNumber(context.definition, "durationSeconds", remainingFuse) + 1
	)

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
			visuals = {
				spinRadiansPerSecond = getDefinitionNumber(context.definition, "drillTravelSpinRadiansPerSecond", 18),
				burrowSpinRadiansPerSecond = getDefinitionNumber(context.definition, "drillBurrowSpinRadiansPerSecond", 34),
				trailColor = context.definition.previewColor,
				highlightColor = context.definition.drillColor or context.definition.previewColor,
				highlightFillTransparency = 0.72,
				highlightOutlineTransparency = 0.08,
				drill = true,
			},
		},
	})
	if not launched then
		return false
	end

	local record = {
		player = context.player,
		burrowing = false,
	}
	PROJECTILES[projectileId] = record
	cleanupProjectileLater(projectileId, record, cleanupDelay)

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

	if record.burrowing then
		return AbilityResult.Continue()
	end

	local hitInstance = payload.hitInstance
	if not isEligibleDrillSurface(context.definition, hitInstance) then
		return AbilityResult.Continue()
	end

	local direction = getIncomingDirection(payload)
	if not direction then
		return AbilityResult.Continue()
	end

	record.burrowing = true
	return {
		kind = AbilityResult.Kind.BurrowProjectile,
		abilityId = context.abilityId,
		position = position,
		direction = direction,
		speed = getDefinitionNumber(context.definition, "drillBurrowSpeed", 62),
		maxDistance = getDefinitionNumber(context.definition, "drillBurrowDistance", 42),
		maxDuration = getDefinitionNumber(context.definition, "drillBurrowDuration", 0.8),
		carveRadius = getDefinitionNumber(context.definition, "drillCarveRadius", 4.5),
		carveStepDistance = getDefinitionNumber(context.definition, "drillCarveStepDistance", 3.25),
		effectInterval = getDefinitionNumber(context.definition, "drillBurrowEffectInterval", 0.065),
		startInset = getDefinitionNumber(context.definition, "drillStartInset", 2.2),
	}
end

function DrillBomb.OnBeforeExplosion(context: ServerHookContext)
	local payload = context.context
	if not getTrackedProjectile(context.player, payload) then
		return AbilityResult.Continue()
	end
	local projectileId = payload.projectileId
	PROJECTILES[projectileId] = nil

	return {
		kind = AbilityResult.Kind.ModifyDamage,
		explosionVisualScale = getDefinitionNumber(context.definition, "drillExplosionVisualScale", 1.12),
	}
end

function DrillBomb.OnStart(_service)
end

function DrillBomb.OnPlayerRemoving(player: Player)
	for projectileId, record in pairs(PROJECTILES) do
		if record.player == player then
			PROJECTILES[projectileId] = nil
		end
	end
end

return DrillBomb
