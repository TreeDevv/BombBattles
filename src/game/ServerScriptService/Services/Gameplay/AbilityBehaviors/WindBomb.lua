local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityBehaviorServices = require(ServerScriptService.Services.AbilityBehaviorServices)

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombThrowOrigin = require(ReplicatedStorage.Shared.Common.BombThrowOrigin)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityHookResult = AbilityTypes.AbilityHookResult
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext

type WindRecord = {
	player: Player,
}

local WindBomb = {} :: AbilityTypes.ServerBehavior

local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5
local PROJECTILES: { [string]: WindRecord } = {}
local projectileSerial = 0
local abilityService: AbilityServiceLike? = nil

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
	return ("WindBomb_%d_%d_%04d"):format(
		player.UserId,
		math.floor(workspace:GetServerTimeNow() * 1000),
		projectileSerial % 10000
	)
end

local function buildExplosionConfig(damageMultiplier: number, knockbackMultiplier: number)
	return {
		playerDirectDamage = BombConfig.PlayerDirectDamage * damageMultiplier,
		playerNearDamageMax = BombConfig.PlayerNearDamageMax * damageMultiplier,
		playerNearDamageMin = BombConfig.PlayerNearDamageMin * damageMultiplier,
		playerOuterDamageMax = BombConfig.PlayerOuterDamageMax * damageMultiplier,
		playerOuterDamageMin = BombConfig.PlayerOuterDamageMin * damageMultiplier,
		anchorDirectDamage = BombConfig.AnchorDirectDamage * damageMultiplier,
		anchorNearDamageMax = BombConfig.AnchorNearDamageMax * damageMultiplier,
		anchorNearDamageMin = BombConfig.AnchorNearDamageMin * damageMultiplier,
		anchorOuterDamageMax = BombConfig.AnchorOuterDamageMax * damageMultiplier,
		anchorOuterDamageMin = BombConfig.AnchorOuterDamageMin * damageMultiplier,
		knockbackHorizontal = BombConfig.KnockbackHorizontal * knockbackMultiplier,
		knockbackVertical = BombConfig.KnockbackVertical * knockbackMultiplier,
		knockbackMinScale = BombConfig.KnockbackMinScale,
	}
end

local function getTrackedProjectile(player: Player, context): WindRecord?
	if typeof(context) ~= "table" then
		return nil
	end

	local projectileId = context.projectileId or context.sourceId
	if typeof(projectileId) ~= "string" or projectileId == "" then
		return nil
	end

	local record = PROJECTILES[projectileId]
	if record and record.player == player then
		return record
	end
	return nil
end

local function cleanupProjectileLater(projectileId: string, record: WindRecord, delaySeconds: number)
	task.delay(delaySeconds, function()
		if PROJECTILES[projectileId] == record then
			PROJECTILES[projectileId] = nil
		end
	end)
end

function WindBomb.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function WindBomb.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getBombProjectileService() ~= nil
end

function WindBomb.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local projectileService = getBombProjectileService()
	local rootPart = getCharacterRoot(context.player)
	if not (projectileService and rootPart) then
		return false
	end

	local damageMultiplier = math.max(getDefinitionNumber(context.definition, "damageMultiplier", 0.5), 0)
	local knockbackMultiplier = math.max(getDefinitionNumber(context.definition, "knockbackMultiplier", 2), 0)
	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(context.payload, rootPart.CFrame.LookVector)
	local projectileId = AbilityBehaviorServices.GetClientProjectileId(context) or createProjectileId(context.player)
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
			explosion = buildExplosionConfig(damageMultiplier, knockbackMultiplier),
			visuals = {
				abilityVisualOverlay = true,
				abilityVisualAssetPath = context.definition.assetPath,
				abilityVisualName = "WindBombVFX",
				abilityVisualDisabledAttachmentName = "Impact",
				highlightColor = if typeof(context.definition.highlightColor) == "Color3"
					then context.definition.highlightColor
					else Color3.fromRGB(96, 221, 255),
			},
		},
	})
	if not launched then
		return false
	end

	local record = {
		player = context.player,
	}
	PROJECTILES[projectileId] = record
	cleanupProjectileLater(projectileId, record, remainingFuse + BombConfig.ProjectileLifetimePadding + 8)

	local state = context.slotState.state
	local windBombsThrown = if typeof(state) == "table" and typeof(state.windBombsThrown) == "number"
		then state.windBombsThrown
		else 0

	return {
		state = {
			windBombsThrown = windBombsThrown + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "WindBombFired",
			payload = {
				projectileId = projectileId,
				damageMultiplier = damageMultiplier,
				knockbackMultiplier = knockbackMultiplier,
			},
		},
	}
end

function WindBomb.OnBeforeExplosion(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	local record = getTrackedProjectile(context.player, payload)
	if not record then
		return AbilityResult.Continue()
	end

	local projectileId = if typeof(payload) == "table" then payload.projectileId else nil
	if typeof(projectileId) ~= "string" or projectileId == "" then
		return AbilityResult.Continue()
	end

	PROJECTILES[projectileId] = nil

	if abilityService and typeof(payload.position) == "Vector3" then
		abilityService:FireEffect("WindBombImpact", {
			player = record.player,
			slot = context.slot,
			abilityId = "WindBomb",
			projectileId = projectileId,
			position = payload.position,
			assetPath = context.definition.assetPath,
		})
	end

	return AbilityResult.Continue()
end

function WindBomb.OnPlayerRemoving(player: Player)
	for projectileId, record in pairs(PROJECTILES) do
		if record.player == player then
			PROJECTILES[projectileId] = nil
		end
	end
end

return WindBomb
