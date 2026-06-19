local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local RoundService = require(ServerScriptService.Services.RoundService)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityHookResult = AbilityTypes.AbilityHookResult
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext

type FlareRecord = {
	player: Player,
	projectileId: string,
	bombSkinId: string,
	definition: AbilityDefinition,
	sequenceId: number,
	landed: boolean,
	impactStarted: boolean,
}

local FatBomb = {} :: AbilityTypes.ServerBehavior

local EFFECT_FLARE_LANDED = "FatBombFlareLanded"
local EFFECT_IMPACT = "FatBombImpact"
local PROJECTILE_PREFIX = "FatBomb_"
local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5

local abilityService: AbilityServiceLike? = nil
local bombProjectileService = nil
local bombService = nil
local projectileSerial = 0
local sequenceSerial = 0
local activeFlares: { [string]: FlareRecord } = {}

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

local function getBombService()
	if bombService then
		return bombService
	end

	local serviceModule = ServerScriptService.Services:FindFirstChild("BombService")
	if serviceModule and serviceModule:IsA("ModuleScript") then
		local ok, service = pcall(require, serviceModule)
		if ok and typeof(service) == "table" then
			bombService = service
			return bombService
		end
	end

	return nil
end

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

local function getDefinitionPath(definition: AbilityDefinition?, key: string)
	local value = if definition then definition[key] else nil
	return if typeof(value) == "table" then value else nil
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
	return ("%s%d_%d_%04d"):format(
		PROJECTILE_PREFIX,
		player.UserId,
		math.floor(workspace:GetServerTimeNow() * 1000),
		projectileSerial % 10000
	)
end

local function isOwnerActive(player: Player): boolean
	return player.Parent == Players
		and CombatEligibility.IsCombatActive(player, RoundService)
		and CombatEligibility.HasAliveCharacter(player)
end

local function destroyProjectile(projectileId: string)
	local projectileService = getBombProjectileService()
	if projectileService and type(projectileService.DestroyProjectile) == "function" then
		projectileService:DestroyProjectile(projectileId, "FatBombImpact")
	end
end

local function fireAll(effectName: string, payload: any?)
	if abilityService and type(abilityService.FireEffect) == "function" then
		abilityService:FireEffect(effectName, payload)
	end
end

local function buildExplosionOverride(definition: AbilityDefinition)
	local coreDamageMultiplier = math.max(getDefinitionNumber(definition, "coreDamageMultiplier", 1), 0)
	return {
		abilityId = "FatBomb",
		suppressDefaultExplosionVfx = true,
		innerRadius = getDefinitionNumber(definition, "innerRadius", 9),
		nearRadius = getDefinitionNumber(definition, "nearRadius", 18),
		outerRadius = getDefinitionNumber(definition, "outerRadius", 28),
		terrainRadius = getDefinitionNumber(definition, "terrainRadius", 20),
		forceTerrainSubtract = definition.forceTerrainSubtract == true,
		playerDirectDamage = getDefinitionNumber(definition, "playerDirectDamage", 135),
		playerNearDamageMax = getDefinitionNumber(definition, "playerNearDamageMax", 110),
		playerNearDamageMin = getDefinitionNumber(definition, "playerNearDamageMin", 78),
		playerOuterDamageMax = getDefinitionNumber(definition, "playerOuterDamageMax", 64),
		playerOuterDamageMin = getDefinitionNumber(definition, "playerOuterDamageMin", 34),
		anchorDirectDamage = BombConfig.AnchorDirectDamage * coreDamageMultiplier,
		anchorNearDamageMax = BombConfig.AnchorNearDamageMax * coreDamageMultiplier,
		anchorNearDamageMin = BombConfig.AnchorNearDamageMin * coreDamageMultiplier,
		anchorOuterDamageMax = BombConfig.AnchorOuterDamageMax * coreDamageMultiplier,
		anchorOuterDamageMin = BombConfig.AnchorOuterDamageMin * coreDamageMultiplier,
		knockbackHorizontal = getDefinitionNumber(definition, "knockbackHorizontal", BombConfig.KnockbackHorizontal),
		knockbackVertical = getDefinitionNumber(definition, "knockbackVertical", BombConfig.KnockbackVertical),
		knockbackMinScale = getDefinitionNumber(definition, "knockbackMinScale", BombConfig.KnockbackMinScale),
		explosionVisualScale = getDefinitionNumber(definition, "explosionVisualScale", 1.55),
	}
end

local function buildSequencePayload(record: FlareRecord, position: Vector3, normal: Vector3, landedAt: number)
	local definition = record.definition
	local impactDelay = math.max(getDefinitionNumber(definition, "impactDelaySeconds", 1), 0.15)
	return {
		player = record.player,
		abilityId = "FatBomb",
		projectileId = record.projectileId,
		sequenceId = record.sequenceId,
		position = position,
		normal = normal,
		radius = getDefinitionNumber(definition, "damageRadius", 28),
		landedAt = landedAt,
		impactAt = landedAt + impactDelay,
		impactDelaySeconds = impactDelay,
		revealDelaySeconds = getDefinitionNumber(definition, "revealDelaySeconds", 0.2),
		finalWarningSeconds = getDefinitionNumber(definition, "finalWarningSeconds", 0.35),
		exitSeconds = getDefinitionNumber(definition, "exitSeconds", 0.3),
		flareColor = getDefinitionColor(definition, "flareColor", Color3.fromRGB(255, 86, 28)),
		cameraShakeRadius = getDefinitionNumber(definition, "cameraShakeRadius", 210),
		cameraShakeMagnitude = getDefinitionNumber(definition, "cameraShakeMagnitude", 4.8),
		cameraShakeRoughness = getDefinitionNumber(definition, "cameraShakeRoughness", 16),
		cameraShakeFadeInTime = getDefinitionNumber(definition, "cameraShakeFadeInTime", 0.02),
		cameraShakeFadeOutTime = getDefinitionNumber(definition, "cameraShakeFadeOutTime", 0.55),
		cameraShakePositionInfluence = definition.cameraShakePositionInfluence,
		cameraShakeRotationInfluence = definition.cameraShakeRotationInfluence,
	}
end

local function scheduleImpact(record: FlareRecord, position: Vector3, normal: Vector3, landedAt: number)
	local impactDelay = math.max(getDefinitionNumber(record.definition, "impactDelaySeconds", 1), 0.15)
	task.delay(impactDelay, function()
		if activeFlares[record.projectileId] ~= record or record.impactStarted then
			return
		end
		activeFlares[record.projectileId] = nil
		record.impactStarted = true
		destroyProjectile(record.projectileId)

		if not isOwnerActive(record.player) then
			return
		end

		fireAll(EFFECT_IMPACT, {
			player = record.player,
			abilityId = "FatBomb",
			projectileId = record.projectileId,
			sequenceId = record.sequenceId,
			position = position,
			normal = normal,
			radius = getDefinitionNumber(record.definition, "damageRadius", 28),
		})

		local service = getBombService()
		if service and type(service.ExplodeAbility) == "function" then
			service:ExplodeAbility(record.player, position, "FatBomb", record.bombSkinId, buildExplosionOverride(record.definition))
		end
	end)
end

local function activateFlare(record: FlareRecord, position: Vector3, normal: Vector3, landedAt: number)
	if record.landed then
		return
	end

	record.landed = true
	fireAll(EFFECT_FLARE_LANDED, buildSequencePayload(record, position, normal, landedAt))
	scheduleImpact(record, position, normal, landedAt)
end

function FatBomb.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function FatBomb.CanActivate(context: ServerActivateContext): boolean
	return isOwnerActive(context.player)
		and getCharacterRoot(context.player) ~= nil
		and getBombProjectileService() ~= nil
		and getBombService() ~= nil
end

function FatBomb.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local projectileService = getBombProjectileService()
	local rootPart = getCharacterRoot(context.player)
	if not (projectileService and rootPart) then
		return false
	end

	sequenceSerial += 1
	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(context.payload, rootPart.CFrame.LookVector)
	local projectileId = createProjectileId(context.player)
	local skinId = BombSkinService:GetEquippedSkinId(context.player)
	local launchSpeed = getDefinitionNumber(context.definition, "projectileLaunchSpeed", BombConfig.ProjectileLaunchSpeed)
	local upwardVelocity = getDefinitionNumber(context.definition, "projectileUpwardVelocity", BombConfig.ProjectileUpwardVelocity)
	local gravityScale = getDefinitionNumber(context.definition, "projectileGravityScale", BombConfig.ProjectileGravityScale)
	local projectileFuse = math.max(getDefinitionNumber(context.definition, "projectileFuseSeconds", 7), 1)
	local visualScale = math.max(getDefinitionNumber(context.definition, "projectileVisualScale", 0.48), 0.1)

	local launched = projectileService:Launch({
		owner = context.player,
		projectileId = projectileId,
		bombType = BombProjectileConfig.BombType.Normal,
		skinId = skinId,
		origin = origin,
		aimDirection = aimDirection,
		fuseStartedAt = context.now,
		launchedAt = context.now,
		remainingFuse = projectileFuse,
		modifier = {
			physics = {
				radius = math.max((BombConfig.SweepRadius or 1.5) * 0.55, 0.45),
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
				visualScale = visualScale,
				highlightColor = getDefinitionColor(context.definition, "highlightColor", Color3.fromRGB(255, 92, 36)),
				abilityVisualOverlay = true,
				abilityVisualAssetPath = getDefinitionPath(context.definition, "flareVisualAssetPath"),
				abilityVisualName = "FatBombFlareVFX",
				hideBaseVisual = true,
			},
			explosion = {
				abilityId = "FatBomb",
				suppressDefaultExplosionVfx = true,
			},
		},
	})
	if not launched then
		return false
	end

	activeFlares[projectileId] = {
		player = context.player,
		projectileId = projectileId,
		bombSkinId = BombSkinConfig.NormalizeSkinId(skinId),
		definition = context.definition,
		sequenceId = sequenceSerial,
		landed = false,
		impactStarted = false,
	}

	local state = context.slotState.state
	local flaresThrown = if typeof(state) == "table" and typeof(state.flaresThrown) == "number" then state.flaresThrown else 0
	return {
		state = {
			flaresThrown = flaresThrown + 1,
			lastActivatedAt = context.now,
		},
	}
end

function FatBomb.OnBeforeProjectileImpact(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return AbilityResult.Continue()
	end

	local record = activeFlares[payload.projectileId]
	if not record or record.player ~= payload.owner or record.landed then
		return AbilityResult.Continue()
	end

	local position = if typeof(payload.position) == "Vector3" then payload.position else nil
	if not position then
		return AbilityResult.Continue()
	end

	local normal = if typeof(payload.normal) == "Vector3" and payload.normal.Magnitude > 0.05
		then payload.normal.Unit
		else Vector3.yAxis
	activateFlare(record, position + normal * 0.08, normal, context.now)

	return {
		kind = AbilityResult.Kind.AttachProjectile,
		position = position + normal * 0.08,
		normal = normal,
		attachInstance = if typeof(payload.hitInstance) == "Instance" and payload.hitInstance:IsA("BasePart")
			then payload.hitInstance
			else nil,
		targetKind = "FatBombFlare",
	}
end

function FatBomb.OnPlayerRemoving(player: Player)
	for projectileId, record in pairs(activeFlares) do
		if record.player == player then
			activeFlares[projectileId] = nil
			destroyProjectile(projectileId)
		end
	end
end

return FatBomb
