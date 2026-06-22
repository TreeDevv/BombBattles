local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local BombDamage = require(ReplicatedStorage.Shared.Bombs.BombDamage)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local ProjectilePhysics = require(ReplicatedStorage.Shared.Bombs.ProjectilePhysics)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local AbilityService = require(ServerScriptService.Services.AbilityService)
local BombProjectileService = require(ServerScriptService.Services.BombProjectileService)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)
local DestructionService = require(ServerScriptService.Services.DestructionService)
local EmoteService = require(ServerScriptService.Services.EmoteService)
local RoundService = require(ServerScriptService.Services.RoundService)
local StudioAICombatants = require(ServerScriptService.Services.StudioAICombatants)

local REMOTES_FOLDER_NAME = "Remotes"
local BEGIN_REMOTE_NAME = "BeginBombCook"
local RELEASE_REMOTE_NAME = "ReleaseBombCook"
local EFFECT_REMOTE_NAME = "BombEffect"
local ROUND_ID_ATTR = "RoundId"
local ROUND_TEAM_ATTR = "RoundTeam"
local KNOCKBACK_UNTIL_ATTR = "Bomb_KnockbackUntil"
local KNOCKBACK_MOVEMENT_SUPPRESS_SECONDS = 0.25
local ATTR = BombConfig.Attributes
local RESULT_KIND = AbilityResult.Kind
local DEBUG_REPLAY_EVENTS = false
local MIN_AIM_HORIZONTAL = 0.08
local NORMAL_PROJECTILE_PHYSICS = ProjectilePhysics.ResolvePhysicsConfig(
	BombProjectileConfig.Defaults,
	BombProjectileConfig.GetBombTypeConfig(BombProjectileConfig.BombType.Normal).physics
)

type CookState = {
	holdStartedAt: number,
	cookStartedAt: number?,
	skinId: string,
}

type ProjectileState = {
	id: string,
	owner: any,
	skinId: string,
	path: any,
	launchedAt: number,
	fuseStartedAt: number,
	explodeAt: number,
	position: Vector3,
	lastPosition: Vector3,
	landed: boolean,
	sweepRadius: number,
	visualScale: number,
	visuals: { [string]: any }?,
	explosionOverride: { [string]: any }?,
	physicalProjectile: Instance?,
	physicalRoot: BasePart?,
	nextSnapshotAt: number,
	frozenUntil: number?,
	frozenVelocity: Vector3?,
	frozenPosition: Vector3?,
	frozenBy: string?,
}

local BombService = {}

local beginRemote: RemoteEvent? = nil
local releaseRemote: RemoteEvent? = nil
local effectRemote: RemoteEvent? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local cookStates: { [Player]: CookState } = {}
local activeProjectiles: { [string]: ProjectileState } = {}
local seenRoundIds: { [Player]: number } = {}
local characterConnections: { [Player]: RBXScriptConnection } = {}
local nextProjectileId = 0

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
		warn("[BombService] ReplayService require failed:", service)
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
		warn("[BombService] Replay event failed:", eventType, err)
	end
end

local worldTextService = nil

local function getWorldTextService()
	if worldTextService then
		return worldTextService
	end

	local services = ServerScriptService:FindFirstChild("Services")
	local worldTextModule = services and services:FindFirstChild("WorldTextService")
	if not (worldTextModule and worldTextModule:IsA("ModuleScript")) then
		return nil
	end

	local ok, service = pcall(require, worldTextModule)
	if ok and typeof(service) == "table" then
		worldTextService = service
		return worldTextService
	end

	return nil
end

local function sendWorldText(methodName: string, ...)
	local service = getWorldTextService()
	if not service then
		return
	end

	local method = service[methodName]
	if type(method) ~= "function" then
		return
	end

	pcall(function(...)
		method(...)
	end, ...)
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, REMOTES_FOLDER_NAME)
end

local function ensureRemote(name: string): RemoteEvent
	return RemoteUtil.EnsureRemoteEvent(ensureRemotesFolder(), name)
end

local function fireEffect(effectName: string, payload)
	if effectName == "Throw" and typeof(payload) == "table" then
		local position = if typeof(payload.position) == "Vector3"
			then payload.position
			elseif typeof(payload.origin) == "Vector3"
			then payload.origin
			else nil
		local player = payload.player
		if position and typeof(player) == "Instance" and player:IsA("Player") then
			sendWorldText("BombThrown", player, position, {
				projectileId = payload.projectileId,
				bombType = payload.bombType,
				sourceType = "Bomb",
			})
		end
	end

	if effectRemote then
		effectRemote:FireAllClients(effectName, payload)
	end
end

local function setBombAttributes(player: Player, count: number, rechargeEndsAt: number?)
	player:SetAttribute(ATTR.Max, BombConfig.MaxBombs)
	player:SetAttribute(ATTR.Count, math.clamp(math.floor(count), 0, BombConfig.MaxBombs))
	player:SetAttribute(ATTR.RechargeEndsAt, rechargeEndsAt or 0)
end

local function setCookingAttributes(player: Player, cooking: boolean, startedAt: number?)
	player:SetAttribute(ATTR.Cooking, cooking)
	player:SetAttribute(ATTR.CookStartedAt, startedAt or 0)
end

local function clearCookState(player: Player)
	local hadCookState = cookStates[player] ~= nil
	cookStates[player] = nil
	if hadCookState then
		fireEffect("HoldEnd", {
			player = player,
		})
	end
end

local function resetPlayerBombs(player: Player)
	clearCookState(player)
	setBombAttributes(player, BombConfig.MaxBombs, 0)
	setCookingAttributes(player, false, 0)
end

local function getBombCount(player: Player): number
	local count = player:GetAttribute(ATTR.Count)
	return if typeof(count) == "number" then math.clamp(math.floor(count), 0, BombConfig.MaxBombs) else BombConfig.MaxBombs
end

local function isPlayerOwner(owner: any): boolean
	return typeof(owner) == "Instance" and owner:IsA("Player")
end

local function getOwnerUserId(owner: any): number
	if typeof(owner) == "table" and typeof(owner.UserId) == "number" then
		return owner.UserId
	end
	return owner.UserId
end

local function isStudioAIBotOwner(owner: any): boolean
	return StudioAICombatants.IsBotOwner(owner)
end

local function isActivePlayer(player: Player): boolean
	return player.Parent == Players and CombatEligibility.IsCombatActive(player, RoundService)
end

local function isActiveBombOwner(owner: any): boolean
	if isPlayerOwner(owner) then
		return isActivePlayer(owner)
	end
	if not isStudioAIBotOwner(owner) then
		return false
	end

	local state = RoundService:GetState()
	if not state or state.state ~= RoundStates.Active then
		return false
	end

	local character = owner.Character
	if typeof(character) ~= "Instance" or not character:IsA("Model") or not character.Parent then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function getCharacterParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return character, humanoid, rootPart
	end

	return character, humanoid, nil
end

local function getTeamName(owner: any): string?
	if typeof(owner) == "table" and typeof(owner.teamName) == "string" and owner.teamName ~= "" then
		return owner.teamName
	end

	if isPlayerOwner(owner) then
		local teamName = owner:GetAttribute(ROUND_TEAM_ATTR)
		return if typeof(teamName) == "string" and teamName ~= "" then teamName else nil
	end

	return nil
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
		else getTeamName(owner)
	return ownerUserId, ownerTeam
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
	if direction.Magnitude < 0.05 or direction.Magnitude > 1.5 then
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

local function getThrowOrigin(rootPart: BasePart): Vector3
	return rootPart.CFrame:PointToWorldSpace(BombConfig.ThrowOffset)
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

local function preparePhysicalProjectile(projectileId: string, owner: any, skinId: string): (Instance, BasePart)
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
	projectile:SetAttribute("OwnerUserId", getOwnerUserId(owner))
	projectile:SetAttribute("BombSkinId", skinId)
	rootPart:SetAttribute("ProjectileId", projectileId)
	rootPart:SetAttribute("OwnerUserId", getOwnerUserId(owner))
	rootPart:SetAttribute("BombSkinId", skinId)
	return projectile, rootPart
end

local function getAimDirectionFromPayload(payload: any, fallbackDirection: Vector3): Vector3
	if typeof(payload) == "table" then
		local aimDirection = payload.aimDirection
		if BombTrajectory.IsFiniteVector(aimDirection) then
			return sanitizeAimDirection(aimDirection, fallbackDirection)
		end
	elseif BombTrajectory.IsFiniteVector(payload) then
		return sanitizeAimDirection(payload, fallbackDirection)
	end

	return sanitizeAimDirection(fallbackDirection, Vector3.zAxis)
end

local function calculateTrajectory(origin: Vector3, aimDirection: Vector3)
	return BombTrajectory.CreatePath(
		origin,
		aimDirection,
		BombConfig.ProjectileLaunchSpeed,
		BombConfig.ProjectileUpwardVelocity,
		workspace.Gravity * BombConfig.ProjectileGravityScale,
		BombConfig.ProjectileMaxFlightSeconds
	)
end

local function calculateRedirectTrajectory(origin: Vector3, aimDirection: Vector3, result)
	return BombTrajectory.CreatePath(
		origin,
		aimDirection,
		math.max(tonumber(result.launchSpeed) or BombConfig.ProjectileLaunchSpeed, 1),
		math.max(tonumber(result.upwardVelocity) or BombConfig.ProjectileUpwardVelocity, 0),
		workspace.Gravity * BombConfig.ProjectileGravityScale,
		math.max(tonumber(result.maxFlightSeconds) or BombConfig.ProjectileMaxFlightSeconds, 0.12)
	)
end

local function createProjectileId(owner: any): string
	nextProjectileId += 1
	return string.format("%d:%d", getOwnerUserId(owner), nextProjectileId)
end

local function getClientProjectileId(owner: any, targetPayload: any): string?
	if typeof(targetPayload) ~= "table" then
		return nil
	end

	local projectileId = targetPayload.clientProjectileId
	if typeof(projectileId) ~= "string" or #projectileId > 64 then
		return nil
	end

	local expectedPrefix = "Client_" .. tostring(getOwnerUserId(owner)) .. "_"
	if string.sub(projectileId, 1, #expectedPrefix) ~= expectedPrefix then
		return nil
	end
	if not string.match(projectileId, "^Client_%d+_%d+$") then
		return nil
	end

	return projectileId
end

local function getInstancePosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end

	local part = instance:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.Position else nil
end

local function markCharacterKnockback(character: Model?)
	if not character then
		return
	end

	local knockbackUntil = now() + KNOCKBACK_MOVEMENT_SUPPRESS_SECONDS
	character:SetAttribute(KNOCKBACK_UNTIL_ATTR, knockbackUntil)
	task.delay(KNOCKBACK_MOVEMENT_SUPPRESS_SECONDS + 0.1, function()
		if character.Parent and character:GetAttribute(KNOCKBACK_UNTIL_ATTR) == knockbackUntil then
			character:SetAttribute(KNOCKBACK_UNTIL_ATTR, nil)
		end
	end)
end

local function readPositiveNumber(value: any, fallback: number): number
	return if typeof(value) == "number" and value == value and value > 0 then value else fallback
end

local function readNonNegativeNumber(value: any, fallback: number): number
	return if typeof(value) == "number" and value == value and value >= 0 then value else fallback
end

local function applyKnockback(character: Model?, rootPart: BasePart, origin: Vector3, distance: number, multiplier: number?, explosionConfig)
	local away = rootPart.Position - origin
	if away.Magnitude < 0.05 then
		away = Vector3.yAxis
	else
		away = away.Unit
	end

	explosionConfig = explosionConfig or {}
	local outerRadius = readPositiveNumber(explosionConfig.outerRadius, BombConfig.OuterRadius)
	local knockbackMinScale = readNonNegativeNumber(explosionConfig.knockbackMinScale, BombConfig.KnockbackMinScale)
	local knockbackHorizontal = readNonNegativeNumber(explosionConfig.knockbackHorizontal, BombConfig.KnockbackHorizontal)
	local knockbackVertical = readNonNegativeNumber(explosionConfig.knockbackVertical, BombConfig.KnockbackVertical)
	local radiusAlpha = math.clamp(1 - (distance / outerRadius), 0, 1)
	local scale = math.max(radiusAlpha, knockbackMinScale) * (multiplier or 1)
	if scale <= 0 then
		return
	end
	local velocityDelta = Vector3.new(
		away.X * knockbackHorizontal * scale,
		knockbackVertical * scale,
		away.Z * knockbackHorizontal * scale
	)

	rootPart:ApplyImpulse(velocityDelta * rootPart.AssemblyMass)
	markCharacterKnockback(character)
end

local function shouldSuppressBombEffect(result): boolean
	if typeof(result) ~= "table" then
		return false
	end

	return result.kind == RESULT_KIND.Block or result.kind == RESULT_KIND.Absorb
end

local function resolveExplosionConfig(override)
	override = if typeof(override) == "table" then override else {}
	return {
		abilityId = if typeof(override.abilityId) == "string" then override.abilityId else nil,
		suppressDefaultExplosionVfx = override.suppressDefaultExplosionVfx == true,
		explosionVfxAssetPath = if typeof(override.explosionVfxAssetPath) == "table" then override.explosionVfxAssetPath else nil,
		innerRadius = readPositiveNumber(override.innerRadius, BombConfig.InnerRadius),
		nearRadius = readPositiveNumber(override.nearRadius, BombConfig.NearRadius),
		outerRadius = readPositiveNumber(override.outerRadius, BombConfig.OuterRadius),
		terrainRadius = readPositiveNumber(override.terrainRadius, BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius),
		forceTerrainSubtract = override.forceTerrainSubtract == true,
		playerDirectDamage = readNonNegativeNumber(override.playerDirectDamage, BombConfig.PlayerDirectDamage),
		playerNearDamageMax = readNonNegativeNumber(override.playerNearDamageMax, BombConfig.PlayerNearDamageMax),
		playerNearDamageMin = readNonNegativeNumber(override.playerNearDamageMin, BombConfig.PlayerNearDamageMin),
		playerOuterDamageMax = readNonNegativeNumber(override.playerOuterDamageMax, BombConfig.PlayerOuterDamageMax),
		playerOuterDamageMin = readNonNegativeNumber(override.playerOuterDamageMin, BombConfig.PlayerOuterDamageMin),
		anchorDirectDamage = readNonNegativeNumber(override.anchorDirectDamage, BombConfig.AnchorDirectDamage),
		anchorNearDamageMax = readNonNegativeNumber(override.anchorNearDamageMax, BombConfig.AnchorNearDamageMax),
		anchorNearDamageMin = readNonNegativeNumber(override.anchorNearDamageMin, BombConfig.AnchorNearDamageMin),
		anchorOuterDamageMax = readNonNegativeNumber(override.anchorOuterDamageMax, BombConfig.AnchorOuterDamageMax),
		anchorOuterDamageMin = readNonNegativeNumber(override.anchorOuterDamageMin, BombConfig.AnchorOuterDamageMin),
		knockbackHorizontal = readNonNegativeNumber(override.knockbackHorizontal, BombConfig.KnockbackHorizontal),
		knockbackVertical = readNonNegativeNumber(override.knockbackVertical, BombConfig.KnockbackVertical),
		knockbackMinScale = readNonNegativeNumber(override.knockbackMinScale, BombConfig.KnockbackMinScale),
		explosionVisualScale = readPositiveNumber(override.explosionVisualScale, 1),
		chargeScale = readPositiveNumber(override.chargeScale, 1),
	}
end

local function applyExplosionResult(config, result)
	if typeof(result) ~= "table" then
		return config
	end

	if typeof(result.abilityId) == "string" then
		config.abilityId = result.abilityId
	end
	if typeof(result.suppressDefaultExplosionVfx) == "boolean" then
		config.suppressDefaultExplosionVfx = result.suppressDefaultExplosionVfx
	end
	if typeof(result.explosionVfxAssetPath) == "table" then
		config.explosionVfxAssetPath = result.explosionVfxAssetPath
	end
	config.innerRadius = readPositiveNumber(result.innerRadius, config.innerRadius)
	config.nearRadius = readPositiveNumber(result.nearRadius, config.nearRadius)
	config.outerRadius = readPositiveNumber(result.outerRadius, config.outerRadius)
	config.terrainRadius = readPositiveNumber(result.terrainRadius, config.terrainRadius)
	if typeof(result.forceTerrainSubtract) == "boolean" then
		config.forceTerrainSubtract = result.forceTerrainSubtract
	end
	config.playerDirectDamage = readNonNegativeNumber(result.playerDirectDamage, config.playerDirectDamage)
	config.playerNearDamageMax = readNonNegativeNumber(result.playerNearDamageMax, config.playerNearDamageMax)
	config.playerNearDamageMin = readNonNegativeNumber(result.playerNearDamageMin, config.playerNearDamageMin)
	config.playerOuterDamageMax = readNonNegativeNumber(result.playerOuterDamageMax, config.playerOuterDamageMax)
	config.playerOuterDamageMin = readNonNegativeNumber(result.playerOuterDamageMin, config.playerOuterDamageMin)
	config.anchorDirectDamage = readNonNegativeNumber(result.anchorDirectDamage, config.anchorDirectDamage)
	config.anchorNearDamageMax = readNonNegativeNumber(result.anchorNearDamageMax, config.anchorNearDamageMax)
	config.anchorNearDamageMin = readNonNegativeNumber(result.anchorNearDamageMin, config.anchorNearDamageMin)
	config.anchorOuterDamageMax = readNonNegativeNumber(result.anchorOuterDamageMax, config.anchorOuterDamageMax)
	config.anchorOuterDamageMin = readNonNegativeNumber(result.anchorOuterDamageMin, config.anchorOuterDamageMin)
	config.knockbackHorizontal = readNonNegativeNumber(result.knockbackHorizontal, config.knockbackHorizontal)
	config.knockbackVertical = readNonNegativeNumber(result.knockbackVertical, config.knockbackVertical)
	config.knockbackMinScale = readNonNegativeNumber(result.knockbackMinScale, config.knockbackMinScale)
	config.explosionVisualScale = readPositiveNumber(result.explosionVisualScale, config.explosionVisualScale)
	config.chargeScale = readPositiveNumber(result.chargeScale, config.chargeScale)
	return config
end

local function applyOwnerKnockback(owner: Player, origin: Vector3, explosionConfig, sourceId: string?)
	local character, humanoid, rootPart = getCharacterParts(owner)
	if not (humanoid and rootPart and humanoid.Health > 0) then
		return
	end

	local distance = (rootPart.Position - origin).Magnitude
	if distance <= explosionConfig.outerRadius then
		local hookResult = AbilityService:RunHook("OnBeforeOwnerBombKnockback", {
			owner = owner,
			sourceId = sourceId,
			projectileId = sourceId,
			character = character,
			humanoid = humanoid,
			rootPart = rootPart,
			origin = origin,
			distance = distance,
			explosion = explosionConfig,
		})
		if shouldSuppressBombEffect(hookResult) or hookResult.skipKnockback == true then
			return
		end

		local knockbackMultiplier = if typeof(hookResult.knockbackMultiplier) == "number"
			then math.max(hookResult.knockbackMultiplier, 0)
			else 1
		applyKnockback(character, rootPart, origin, distance, knockbackMultiplier, explosionConfig)
	end
end

local function damageEnemyPlayers(owner: any, origin: Vector3, sourceId: string?, damageMultiplier: number?, explosionConfig)
	local token = RuntimeProfiler.Begin("Server/BombService/DamageEnemyPlayers")
	local ownerTeam = getTeamName(owner)
	local ownerUserId = getOwnerUserId(owner)
	local hitUserIds = {}
	local killedUserIds = {}
	local baseDamageMultiplier = readNonNegativeNumber(damageMultiplier, 1)

	local playersToken = RuntimeProfiler.Begin("Server/BombService/DamageEnemyPlayers/Players")
	for _, player in ipairs(Players:GetPlayers()) do
		if isPlayerOwner(owner) and player == owner then
			continue
		end
		if ownerTeam and getTeamName(player) == ownerTeam then
			continue
		end
		if not RoundService:IsPlayerActive(player) then
			continue
		end

		local character, humanoid, rootPart = getCharacterParts(player)
		if not (humanoid and rootPart and humanoid.Health > 0) then
			continue
		end

		local distance = (rootPart.Position - origin).Magnitude
		local damage = BombDamage.GetPlayerDamageForDistance(distance, explosionConfig)
		damage = damage * baseDamageMultiplier
		if damage <= 0 then
			continue
		end

		local hookResult = AbilityService:RunHook("OnBeforePlayerBombDamage", {
			owner = owner,
			target = player,
			sourceId = sourceId,
			projectileId = sourceId,
			character = character,
			humanoid = humanoid,
			rootPart = rootPart,
			origin = origin,
			distance = distance,
			damage = damage,
			explosion = explosionConfig,
		})
		if shouldSuppressBombEffect(hookResult) then
			continue
		end
		if typeof(hookResult.damage) == "number" then
			damage = math.max(hookResult.damage, 0)
		elseif typeof(hookResult.damageMultiplier) == "number" then
			damage = math.max(damage * hookResult.damageMultiplier, 0)
		end

		local knockbackMultiplier = if typeof(hookResult.knockbackMultiplier) == "number"
			then math.max(hookResult.knockbackMultiplier, 0)
			else 1

		if hookResult.skipDamage ~= true and damage > 0 then
			local healthBefore = humanoid.Health
			local appliedDamage = math.min(damage, healthBefore)
			if isPlayerOwner(owner) or isStudioAIBotOwner(owner) then
				RoundService:RecordPlayerDamage(owner, player, appliedDamage, {
					sourceType = explosionConfig.replaySourceType or "Bomb",
					sourceId = explosionConfig.replaySourceId or sourceId,
					bombId = sourceId,
					bombType = explosionConfig.replayBombType,
					abilityName = explosionConfig.replayAbilityName,
					abilityId = explosionConfig.abilityId,
					directHit = explosionConfig.directHit == true,
					sourceDetail = explosionConfig.sourceDetail,
				})
			end
			local takeDamageToken = RuntimeProfiler.Begin("Server/BombService/DamageEnemyPlayers/TakeDamage")
			humanoid:TakeDamage(damage)
			RuntimeProfiler.End("Server/BombService/DamageEnemyPlayers/TakeDamage", takeDamageToken)
			local healthAfter = humanoid.Health

			table.insert(hitUserIds, player.UserId)
			if healthBefore > 0 and healthAfter <= 0 then
				table.insert(killedUserIds, player.UserId)
				RuntimeProfiler.Count("Server/BombService/DeathsFromPlayerDamage")
			end
			local replayToken = RuntimeProfiler.Begin("Server/BombService/DamageEnemyPlayers/RecordDamageReplay")
			recordReplayEvent("PlayerDamaged", {
				victimUserId = player.UserId,
				attackerUserId = ownerUserId,
				amount = appliedDamage,
				sourceType = explosionConfig.replaySourceType or "Bomb",
				sourceId = explosionConfig.replaySourceId or sourceId,
				bombId = sourceId,
				bombType = explosionConfig.replayBombType,
				abilityName = explosionConfig.replayAbilityName,
				abilityId = explosionConfig.abilityId,
				directHit = explosionConfig.directHit == true,
				sourceDetail = explosionConfig.sourceDetail,
				victimHealthAfter = healthAfter,
			})
			RuntimeProfiler.End("Server/BombService/DamageEnemyPlayers/RecordDamageReplay", replayToken)
			sendWorldText("PlayerDamaged", owner, player, appliedDamage, rootPart.Position, {
				sourceType = explosionConfig.replaySourceType or "Bomb",
				sourceId = explosionConfig.replaySourceId or sourceId,
				bombId = sourceId,
				bombType = explosionConfig.replayBombType,
				abilityName = explosionConfig.replayAbilityName,
				victimHealthAfter = healthAfter,
			})
		end
		if hookResult.skipKnockback ~= true then
			applyKnockback(character, rootPart, origin, distance, knockbackMultiplier, explosionConfig)
		end
	end
	RuntimeProfiler.End("Server/BombService/DamageEnemyPlayers/Players", playersToken)

	local botsToken = RuntimeProfiler.Begin("Server/BombService/DamageEnemyPlayers/Bots")
	for _, bot in ipairs(StudioAICombatants.GetAliveBots({
		enemyOfTeam = ownerTeam,
		excludeUserId = ownerUserId,
	})) do
		local character = bot.model
		local humanoid = bot.humanoid
		local rootPart = bot.rootPart
		if not (character and humanoid and rootPart and humanoid.Health > 0) then
			continue
		end

		local distance = (rootPart.Position - origin).Magnitude
		local damage = BombDamage.GetPlayerDamageForDistance(distance, explosionConfig)
		damage = damage * baseDamageMultiplier
		if damage <= 0 then
			continue
		end

		local botDamageToken = RuntimeProfiler.Begin("Server/BombService/DamageEnemyPlayers/BotApplyDamage")
		local appliedDamage, killed = StudioAICombatants.ApplyDamage(owner, bot, damage, {
			sourceType = "Bomb",
			sourceId = sourceId,
		})
		RuntimeProfiler.End("Server/BombService/DamageEnemyPlayers/BotApplyDamage", botDamageToken)
		if appliedDamage > 0 then
			table.insert(hitUserIds, bot.userId)
			if killed then
				table.insert(killedUserIds, bot.userId)
				RuntimeProfiler.Count("Server/BombService/DeathsFromBotDamage")
			end
		end
		applyKnockback(character, rootPart, origin, distance, 1, explosionConfig)
	end
	RuntimeProfiler.End("Server/BombService/DamageEnemyPlayers/Bots", botsToken)

	RuntimeProfiler.Count("Server/BombService/DamageEnemyPlayersHits", #hitUserIds)
	RuntimeProfiler.Count("Server/BombService/DamageEnemyPlayersKills", #killedUserIds)
	RuntimeProfiler.End("Server/BombService/DamageEnemyPlayers", token)
	return hitUserIds, killedUserIds
end

local function damageEnemyAnchors(owner: any, origin: Vector3, sourceId: string?, damageMultiplier: number?, explosionConfig)
	local ownerTeam = getTeamName(owner)
	local ownerUserId = getOwnerUserId(owner)
	local baseDamageMultiplier = readNonNegativeNumber(damageMultiplier, 1)

	for _, core in ipairs(CollectionService:GetTagged(RoundConfig.Tags.TeamCore)) do
		local trackedCore = RoundService:GetTrackedCore(core)
		if not trackedCore then
			continue
		end
		if ownerTeam and trackedCore:GetAttribute("Team") == ownerTeam then
			continue
		end

		local position = getInstancePosition(trackedCore)
		if not position then
			continue
		end

		local damage = BombDamage.GetAnchorDamageForDistance((position - origin).Magnitude, explosionConfig)
		damage = damage * baseDamageMultiplier
		if damage > 0 then
			local hookResult = AbilityService:RunHook("OnBeforeCoreBombDamage", {
				owner = owner,
				core = trackedCore,
				origin = origin,
				position = position,
				damage = damage,
				explosion = explosionConfig,
			})
			if shouldSuppressBombEffect(hookResult) then
				continue
			end
			if typeof(hookResult.damage) == "number" then
				damage = math.max(hookResult.damage, 0)
			elseif typeof(hookResult.damageMultiplier) == "number" then
				damage = math.max(damage * hookResult.damageMultiplier, 0)
			end
			if hookResult.skipDamage == true or damage <= 0 then
				continue
			end

			RoundService:DamageCore(trackedCore, damage, {
				attackerUserId = ownerUserId,
				sourceType = explosionConfig.replaySourceType or "Bomb",
				sourceId = explosionConfig.replaySourceId or sourceId,
			})
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

local function getProjectilePhysicsPosition(state: ProjectileState): Vector3
	local rootPart = state.physicalRoot
	if rootPart and rootPart.Parent then
		return rootPart.Position
	end

	return state.position
end

local function getProjectilePhysicsVelocity(state: ProjectileState): Vector3
	local rootPart = state.physicalRoot
	if rootPart and rootPart.Parent then
		return rootPart.AssemblyLinearVelocity
	end

	return Vector3.zero
end

local function explode(owner: any, position: Vector3, source: string, projectileId: string?, bombSkinId: string?, explosionOverride)
	local explodeToken = RuntimeProfiler.Begin("Server/BombService/Explode")
	if projectileId then
		local state = activeProjectiles[projectileId]
		if state then
			bombSkinId = state.skinId
			position = getProjectilePhysicsPosition(state)
			destroyPhysicalProjectile(state)
		end
		activeProjectiles[projectileId] = nil
	end
	bombSkinId = BombSkinConfig.NormalizeSkinId(bombSkinId)
	if bombSkinId == "" then
		bombSkinId = BombSkinConfig.DefaultSkinId
	end

	local explosionConfig = resolveExplosionConfig(explosionOverride)
	local playerDamageMultiplier = 1
	local coreDamageMultiplier = 1

	local explosionResult = AbilityService:RunHook("OnBeforeExplosion", {
		owner = owner,
		position = position,
		source = source,
		projectileId = projectileId,
		innerRadius = explosionConfig.innerRadius,
		nearRadius = explosionConfig.nearRadius,
		outerRadius = explosionConfig.outerRadius,
		terrainRadius = explosionConfig.terrainRadius,
		playerDamageMultiplier = playerDamageMultiplier,
		coreDamageMultiplier = coreDamageMultiplier,
		explosionVisualScale = explosionConfig.explosionVisualScale,
		chargeScale = explosionConfig.chargeScale,
		explosion = explosionConfig,
	})
	if shouldSuppressBombEffect(explosionResult) then
		RuntimeProfiler.End("Server/BombService/Explode", explodeToken)
		return
	end
	if typeof(explosionResult.position) == "Vector3" then
		position = explosionResult.position
	end
	if isPlayerOwner(explosionResult.owner) or isStudioAIBotOwner(explosionResult.owner) then
		owner = explosionResult.owner
	end
	if typeof(explosionResult.explosion) == "table" then
		for key, value in pairs(explosionResult.explosion) do
			explosionConfig[key] = value
		end
		explosionConfig = applyExplosionResult(explosionConfig, explosionResult.explosion)
	end
	explosionConfig = applyExplosionResult(explosionConfig, explosionResult)
	playerDamageMultiplier = readNonNegativeNumber(explosionResult.playerDamageMultiplier, playerDamageMultiplier)
	coreDamageMultiplier = readNonNegativeNumber(explosionResult.coreDamageMultiplier, coreDamageMultiplier)
	local replayAbilityId = if typeof(explosionConfig.abilityId) == "string" and explosionConfig.abilityId ~= ""
		then explosionConfig.abilityId
		else nil
	local replaySourceType = if typeof(explosionConfig.sourceType) == "string" and explosionConfig.sourceType ~= ""
		then explosionConfig.sourceType
		elseif replayAbilityId or source == "Ability"
		then "Ability"
		else "Bomb"
	local replaySourceId = if typeof(explosionConfig.sourceId) == "string" and explosionConfig.sourceId ~= ""
		then explosionConfig.sourceId
		elseif replayAbilityId
		then replayAbilityId
		else projectileId
	local replayBombType = if typeof(explosionConfig.bombType) == "string" and explosionConfig.bombType ~= ""
		then explosionConfig.bombType
		elseif replayAbilityId
		then replayAbilityId
		else BombProjectileConfig.BombType.Normal
	explosionConfig.replaySourceType = replaySourceType
	explosionConfig.replaySourceId = replaySourceId
	explosionConfig.replayBombType = replayBombType
	explosionConfig.replayAbilityName = replayAbilityId
	local impactTimestamp = workspace:GetServerTimeNow()

	local hitUserIds = {}
	local killedUserIds = {}
	local debrisPayloads = {}

	if isActiveBombOwner(owner) then
		local ownerUserId = getOwnerUserId(owner)
		local destructionToken = RuntimeProfiler.Begin("Server/BombService/ExplosionDestruction")
		debrisPayloads = DestructionService:DestroySphere(position, explosionConfig.terrainRadius, {
			sourceType = replaySourceType,
			sourceId = replaySourceId,
			bombId = projectileId,
			ownerUserId = ownerUserId,
			timestamp = impactTimestamp,
		}, {
			forceSubtract = explosionConfig.forceTerrainSubtract == true,
		})
		RuntimeProfiler.End("Server/BombService/ExplosionDestruction", destructionToken)
		if isPlayerOwner(owner) then
			applyOwnerKnockback(owner, position, explosionConfig, projectileId)
		end
		if not (isPlayerOwner(owner) and CombatEligibility.IsPracticeOnly(owner, RoundService)) then
			local playerDamageToken = RuntimeProfiler.Begin("Server/BombService/DamagePlayers")
			hitUserIds, killedUserIds =
				damageEnemyPlayers(owner, position, projectileId, playerDamageMultiplier, explosionConfig)
			RuntimeProfiler.End("Server/BombService/DamagePlayers", playerDamageToken)
			local anchorDamageToken = RuntimeProfiler.Begin("Server/BombService/DamageAnchors")
			damageEnemyAnchors(owner, position, projectileId, coreDamageMultiplier, explosionConfig)
			RuntimeProfiler.End("Server/BombService/DamageAnchors", anchorDamageToken)
		end
	end

	fireEffect("Explode", {
		player = owner,
		abilityId = explosionConfig.abilityId,
		projectileId = projectileId,
		bombSkinId = bombSkinId,
		position = position,
		source = source,
		suppressDefaultExplosionVfx = explosionConfig.suppressDefaultExplosionVfx,
		explosionVfxAssetPath = explosionConfig.explosionVfxAssetPath,
		innerRadius = explosionConfig.innerRadius,
		nearRadius = explosionConfig.nearRadius,
		outerRadius = explosionConfig.outerRadius,
		terrainRadius = explosionConfig.terrainRadius,
		explosionVisualScale = explosionConfig.explosionVisualScale,
		chargeScale = explosionConfig.chargeScale,
		hitUserIds = hitUserIds,
	})
	sendWorldText("BombExploded", owner, position, {
		projectileId = projectileId,
		source = source,
		sourceType = replaySourceType,
		sourceId = replaySourceId,
		bombType = replayBombType,
		abilityName = replayAbilityId,
		bombSkinId = bombSkinId,
		chargeScale = explosionConfig.chargeScale,
	})
	if #debrisPayloads > 0 then
		fireEffect("TerrainDebris", {
			payloads = debrisPayloads,
		})
	end

	local ownerIdentity = StudioAICombatants.GetOwnerIdentity(owner)
	recordReplayEvent("BombExploded", {
		timestamp = impactTimestamp,
		bombId = projectileId,
		sourceId = replaySourceId,
		projectileId = projectileId,
		source = source,
		sourceType = replaySourceType,
		ownerUserId = getOwnerUserId(owner),
		ownerName = if ownerIdentity then ownerIdentity.name else nil,
		ownerDisplayName = if ownerIdentity then ownerIdentity.displayName else nil,
		ownerTeam = if ownerIdentity then ownerIdentity.teamName else nil,
		ownerIsNPC = if ownerIdentity then ownerIdentity.isNPC == true else nil,
		bombType = replayBombType,
		abilityName = replayAbilityId,
		abilityId = replayAbilityId,
		directHit = explosionConfig.directHit == true,
		sourceDetail = explosionConfig.sourceDetail,
		bombSkinId = bombSkinId,
		position = position,
		innerRadius = explosionConfig.innerRadius,
		nearRadius = explosionConfig.nearRadius,
		outerRadius = explosionConfig.outerRadius,
		terrainRadius = explosionConfig.terrainRadius,
		explosionVisualScale = explosionConfig.explosionVisualScale,
		chargeScale = explosionConfig.chargeScale,
		playerDamageMultiplier = playerDamageMultiplier,
		coreDamageMultiplier = coreDamageMultiplier,
		radius = explosionConfig.outerRadius,
		hitUserIds = hitUserIds,
		killedUserIds = killedUserIds,
	})
	RuntimeProfiler.Count("Server/BombService/Explosions")
	RuntimeProfiler.Count("Server/BombService/ExplosionHits", #hitUserIds)
	RuntimeProfiler.Count("Server/BombService/ExplosionKills", #killedUserIds)
	RuntimeProfiler.Count("Server/BombService/TerrainDebrisPayloads", #debrisPayloads)
	RuntimeProfiler.End("Server/BombService/Explode", explodeToken)
end

local function stopCooking(player: Player)
	clearCookState(player)
	setCookingAttributes(player, false, 0)
end

local consumeBomb

local function explodeInHand(player: Player, source: string)
	local state = cookStates[player]
	local skinId = state and state.skinId or BombSkinService:GetEquippedSkinId(player)
	if not consumeBomb(player) then
		stopCooking(player)
		return
	end

	local _, _, rootPart = getCharacterParts(player)
	local position = if rootPart then rootPart.Position else Vector3.zero
	stopCooking(player)
	explode(player, position, source, nil, skinId)
end

local function scheduleInHandExplosion(player: Player, state: CookState, cookStartedAt: number)
	task.delay(BombConfig.FuseSeconds, function()
		local currentState = cookStates[player]
		if currentState == state and currentState.cookStartedAt == cookStartedAt then
			explodeInHand(player, "InHand")
		end
	end)
end

function consumeBomb(player: Player): boolean
	local count = getBombCount(player)
	if count <= 0 then
		return false
	end

	count -= 1
	local rechargeEndsAt = player:GetAttribute(ATTR.RechargeEndsAt)
	if typeof(rechargeEndsAt) ~= "number" or rechargeEndsAt <= 0 then
		rechargeEndsAt = now() + BombConfig.RechargeSeconds
	end

	setBombAttributes(player, count, if count < BombConfig.MaxBombs then rechargeEndsAt else 0)
	return true
end

local function startActiveCook(player: Player, state: CookState)
	if cookStates[player] ~= state or state.cookStartedAt then
		return
	end
	if not isActivePlayer(player) then
		stopCooking(player)
		return
	end

	local cookStartedAt = now()
	state.cookStartedAt = cookStartedAt
	setCookingAttributes(player, true, cookStartedAt)

	fireEffect("Cook", {
		player = player,
		startedAt = cookStartedAt,
		fuseSeconds = BombConfig.FuseSeconds,
		bombSkinId = state.skinId,
	})

	scheduleInHandExplosion(player, state, cookStartedAt)
end

local function createSweepParams(owner: Player): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = owner.Character
	params.FilterDescendantsInstances = if character then { character } else {}
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return params
end

local function createPhysicalGroundParams(state: ProjectileState): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded = {}
	local character = state.owner.Character
	if character then
		table.insert(excluded, character)
	end
	if state.physicalProjectile then
		table.insert(excluded, state.physicalProjectile)
	end
	params.FilterDescendantsInstances = excluded
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return params
end

local function getSurfaceNormal(owner: Player, position: Vector3): Vector3
	local params = createSweepParams(owner)
	local rayOrigin = position + Vector3.yAxis * BombConfig.PostImpactNormalProbeUp
	local rayDirection = Vector3.new(0, -(BombConfig.PostImpactNormalProbeUp + BombConfig.PostImpactNormalProbeDown), 0)
	local hit = workspace:Raycast(rayOrigin, rayDirection, params)
	if hit and BombTrajectory.IsFiniteVector(hit.Normal) and hit.Normal.Magnitude > 0.05 then
		return hit.Normal.Unit
	end

	return Vector3.yAxis
end

local function sweepProjectile(owner: Player, fromPosition: Vector3, toPosition: Vector3, radius: number?): RaycastResult?
	local direction = toPosition - fromPosition
	if direction.Magnitude <= 0.001 then
		return nil
	end

	local params = createSweepParams(owner)
	local sweepRadius = math.max(tonumber(radius) or BombConfig.SweepRadius, 0.05)
	local spherecastOk, spherecastResult = pcall(function()
		return workspace:Spherecast(fromPosition, sweepRadius, direction, params)
	end)
	if spherecastOk then
		return spherecastResult
	end

	return workspace:Raycast(fromPosition, direction, params)
end

local function clampVectorMagnitude(vector: Vector3, maxMagnitude: number): Vector3
	if vector.Magnitude <= maxMagnitude then
		return vector
	end

	return vector.Unit * maxMagnitude
end

local function getPostImpactVelocity(incomingVelocity: Vector3, normal: Vector3): Vector3
	return clampVectorMagnitude(
		ProjectilePhysics.GetImpactVelocity(incomingVelocity, normal, NORMAL_PROJECTILE_PHYSICS),
		BombConfig.PostImpactMaxSpeed
	)
end

local function setProjectileAssemblyMotion(projectile: Instance, velocity: Vector3, angularVelocity: Vector3)
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
	local radius = math.max(NORMAL_PROJECTILE_PHYSICS.radius, rootPart.Size.X * 0.5, rootPart.Size.Z * 0.5, 0.1)
	local probeDistance = radius + math.max(NORMAL_PROJECTILE_PHYSICS.surfaceOffset, 0) + 0.35
	local hit = workspace:Raycast(rootPart.Position, Vector3.yAxis * -probeDistance, createPhysicalGroundParams(state))
	return hit ~= nil and hit.Normal.Y >= NORMAL_PROJECTILE_PHYSICS.floorNormalY
end

local function dampGroundedPhysicalProjectile(state: ProjectileState, dt: number)
	local projectile = state.physicalProjectile
	local rootPart = state.physicalRoot
	if not (projectile and projectile.Parent and rootPart and rootPart.Parent) then
		return
	end
	if not isPhysicalProjectileGrounded(state, rootPart) then
		return
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local dampedHorizontal = dampVector(
		horizontalVelocity,
		NORMAL_PROJECTILE_PHYSICS.groundedFrictionPerSecond,
		dt,
		NORMAL_PROJECTILE_PHYSICS.minRollSpeed
	)

	local verticalSpeed = velocity.Y
	if math.abs(verticalSpeed) <= NORMAL_PROJECTILE_PHYSICS.minRollSpeed then
		verticalSpeed = 0
	end

	local radius = math.max(NORMAL_PROJECTILE_PHYSICS.radius, 0.1)
	local dampedAngular = dampVector(
		rootPart.AssemblyAngularVelocity,
		NORMAL_PROJECTILE_PHYSICS.groundedFrictionPerSecond * 1.35,
		dt,
		NORMAL_PROJECTILE_PHYSICS.minRollSpeed / radius
	)
	local dampedVelocity = Vector3.new(dampedHorizontal.X, verticalSpeed, dampedHorizontal.Z)
	setProjectileAssemblyMotion(projectile, dampedVelocity, dampedAngular)
end

local function spawnPhysicalProjectile(state: ProjectileState, position: Vector3, normal: Vector3, incomingVelocity: Vector3): Instance?
	local projectile, rootPart = preparePhysicalProjectile(state.id, state.owner, state.skinId)
	projectile:SetAttribute("BombType", BombProjectileConfig.BombType.Normal)
	projectile:SetAttribute("BombSkinId", state.skinId)
	projectile:SetAttribute("FuseStartedAt", state.fuseStartedAt)
	projectile:SetAttribute("FuseEndsAt", state.explodeAt)
	local unitNormal = if normal.Magnitude > 0.05 then normal.Unit else Vector3.yAxis
	local spawnPosition = position + unitNormal * BombConfig.PostImpactSpawnNormalOffset
	local spawnCFrame = CFrame.new(spawnPosition)

	if projectile:IsA("Model") then
		projectile:PivotTo(spawnCFrame)
	else
		projectile.CFrame = spawnCFrame
	end

	projectile.Parent = getProjectileFolder()

	local velocity = getPostImpactVelocity(incomingVelocity, unitNormal)
	local spinAxis = incomingVelocity:Cross(unitNormal)
	if spinAxis.Magnitude <= 0.05 then
		spinAxis = Vector3.new(0.35, 1, 0.2)
	end
	local angularVelocity = if NORMAL_PROJECTILE_PHYSICS.impactResponse == ProjectilePhysics.ImpactResponse.Sandbag
		then Vector3.zero
		else spinAxis.Unit * BombConfig.PostImpactAngularSpeed
	setProjectileAssemblyMotion(projectile, velocity, angularVelocity)

	state.physicalProjectile = projectile
	state.physicalRoot = rootPart
	state.position = rootPart.Position
	state.lastPosition = rootPart.Position
	return projectile
end

local function fireProjectileImpact(state: ProjectileState, position: Vector3, normal: Vector3, incomingVelocity: Vector3)
	if state.landed then
		return
	end

	local impactResult = AbilityService:RunHook("OnBeforeProjectileImpact", {
		projectileId = state.id,
		owner = state.owner,
		position = position,
		normal = normal,
		incomingVelocity = incomingVelocity,
	})
	if impactResult.kind == RESULT_KIND.DestroyProjectile then
		destroyPhysicalProjectile(state)
		activeProjectiles[state.id] = nil
		return
	end
	if shouldSuppressBombEffect(impactResult) then
		state.position = position
		state.lastPosition = position
		return
	end
	if typeof(impactResult.position) == "Vector3" then
		position = impactResult.position
	end
	if typeof(impactResult.normal) == "Vector3" then
		normal = impactResult.normal
	end

	state.landed = true
	state.position = position
	state.lastPosition = position
	local physicalProjectile = spawnPhysicalProjectile(state, position, normal, incomingVelocity)
	fireEffect("Impact", {
		player = state.owner,
		projectileId = state.id,
		bombSkinId = state.skinId,
		position = position,
		impactNormal = normal,
		impactVelocity = incomingVelocity,
		physicalProjectile = physicalProjectile,
	})
end

local function throwBomb(player: Player, rootPart: BasePart, targetPayload: any, startedAt: number, remainingFuse: number, skinId: string)
	local token = RuntimeProfiler.Begin("Server/BombService/ThrowBomb")
	local fallbackDirection = rootPart.CFrame.LookVector
	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(targetPayload, fallbackDirection)
	if BombProjectileService:IsEnabled() then
		local projectileId = getClientProjectileId(player, targetPayload) or createProjectileId(player)
		BombProjectileService:Launch({
			owner = player,
			projectileId = projectileId,
			sourceType = "Bomb",
			bombType = BombProjectileConfig.BombType.Normal,
			skinId = skinId,
			origin = origin,
			aimDirection = aimDirection,
			fuseStartedAt = startedAt,
			launchedAt = now(),
			remainingFuse = remainingFuse,
		})
		RuntimeProfiler.Count("Server/BombService/ProjectileServiceLaunch")
		RuntimeProfiler.End("Server/BombService/ThrowBomb", token)
		return
	end

	local trajectory = calculateTrajectory(origin, aimDirection)
	local launchResult = AbilityService:RunHook("OnBeforeProjectileLaunch", {
		owner = player,
		sourceType = "Bomb",
		origin = origin,
		aimDirection = aimDirection,
		trajectory = trajectory,
		remainingFuse = remainingFuse,
		bombSkinId = skinId,
	})
	if shouldSuppressBombEffect(launchResult) then
		RuntimeProfiler.End("Server/BombService/ThrowBomb", token)
		return
	end
	if typeof(launchResult.origin) == "Vector3" then
		origin = launchResult.origin
	end
	if typeof(launchResult.aimDirection) == "Vector3" then
		aimDirection = launchResult.aimDirection
	end
	if typeof(launchResult.remainingFuse) == "number" then
		remainingFuse = readPositiveNumber(launchResult.remainingFuse, remainingFuse)
	end
	if typeof(launchResult.origin) == "Vector3" or typeof(launchResult.aimDirection) == "Vector3" then
		trajectory = calculateTrajectory(origin, aimDirection)
	end
	local projectileId = getClientProjectileId(player, targetPayload) or createProjectileId(player)
	local launchTime = now()
	local explodeAt = launchTime + remainingFuse
	local visuals = if typeof(launchResult.visuals) == "table" then launchResult.visuals else nil
	local physics = if typeof(launchResult.physics) == "table" then launchResult.physics else nil
	local explosionOverride = if typeof(launchResult.explosion) == "table" then launchResult.explosion else nil
	local visualScale = if visuals and typeof(visuals.visualScale) == "number"
		then math.max(visuals.visualScale, 0.05)
		else BombConfig.ProjectileVisualScale
	local sweepRadius = if physics and typeof(physics.radius) == "number"
		then math.max(physics.radius, 0.05)
		else BombConfig.SweepRadius
	local state: ProjectileState = {
		id = projectileId,
		owner = player,
		skinId = skinId,
		path = trajectory,
		launchedAt = launchTime,
		fuseStartedAt = startedAt,
		explodeAt = explodeAt,
		position = origin,
		lastPosition = origin,
		landed = false,
		sweepRadius = sweepRadius,
		visualScale = visualScale,
		visuals = visuals,
		explosionOverride = explosionOverride,
		physicalProjectile = nil,
		physicalRoot = nil,
		nextSnapshotAt = launchTime,
		frozenUntil = nil,
		frozenVelocity = nil,
		frozenPosition = nil,
		frozenBy = nil,
	}
	activeProjectiles[projectileId] = state
	RuntimeProfiler.Count("Server/BombService/LegacyProjectileLaunch")

	local ownerUserId, ownerTeam = getOwnerVisualIdentity(player)
	fireEffect("Throw", {
		player = player,
		ownerUserId = ownerUserId,
		ownerTeam = ownerTeam,
		projectileId = projectileId,
		bombSkinId = skinId,
		origin = trajectory.origin,
		initialVelocity = trajectory.initialVelocity,
		acceleration = trajectory.acceleration,
		duration = trajectory.duration,
		startedAt = launchTime,
		fuseStartedAt = startedAt,
		remainingFuse = remainingFuse,
		visuals = visuals,
		visualScale = visualScale,
	})
	recordReplayEvent("BombThrown", {
		bombId = projectileId,
		ownerUserId = ownerUserId,
		ownerTeam = ownerTeam,
		bombType = BombProjectileConfig.BombType.Normal,
		bombSkinId = skinId,
		position = trajectory.origin,
		velocity = trajectory.initialVelocity,
		fuseDuration = remainingFuse,
	})

	local function scheduleCleanup(delaySeconds: number)
		task.delay(math.max(delaySeconds, 0), function()
			local currentState = activeProjectiles[projectileId]
			if not currentState then
				return
			end

			local cleanupDelay = currentState.explodeAt + BombConfig.ProjectileLifetimePadding - now()
			if cleanupDelay > 0 then
				scheduleCleanup(cleanupDelay)
				return
			end

			destroyPhysicalProjectile(currentState)
			activeProjectiles[projectileId] = nil
		end)
	end
	scheduleCleanup(remainingFuse + BombConfig.ProjectileLifetimePadding)
	RuntimeProfiler.End("Server/BombService/ThrowBomb", token)
end

local function redirectProjectile(state: ProjectileState, result, currentTime: number): boolean
	if typeof(result) ~= "table" then
		return false
	end
	if not (BombTrajectory.IsFiniteVector(result.origin) and BombTrajectory.IsFiniteVector(result.aimDirection)) then
		return false
	end

	destroyPhysicalProjectile(state)
	if isPlayerOwner(result.owner) or isStudioAIBotOwner(result.owner) then
		state.owner = result.owner
	end

	local trajectory = calculateRedirectTrajectory(result.origin, result.aimDirection, result)
	state.path = trajectory
	state.launchedAt = currentTime
	state.position = trajectory.origin
	state.lastPosition = trajectory.origin
	state.landed = false

	local remainingFuse = math.max(state.explodeAt - currentTime, 0)
	fireEffect("Throw", {
		player = state.owner,
		projectileId = state.id,
		bombSkinId = state.skinId,
		origin = trajectory.origin,
		initialVelocity = trajectory.initialVelocity,
		acceleration = trajectory.acceleration,
		duration = trajectory.duration,
		startedAt = currentTime,
		fuseStartedAt = state.fuseStartedAt,
		remainingFuse = remainingFuse,
		visuals = state.visuals,
		visualScale = state.visualScale,
	})

	return true
end

local function applyProjectileVelocity(
	state: ProjectileState,
	result,
	currentTime: number,
	currentVelocity: Vector3,
	nextPosition: Vector3
): boolean
	if typeof(result) ~= "table" then
		return false
	end

	local velocity = if BombTrajectory.IsFiniteVector(result.velocity) then result.velocity else currentVelocity
	local maxSpeed = math.max(tonumber(result.maxSpeed) or 220, 1)
	if velocity.Magnitude > maxSpeed then
		velocity = velocity.Unit * maxSpeed
	end

	if state.landed then
		local rootPart = state.physicalRoot
		if rootPart and rootPart.Parent then
			rootPart.AssemblyLinearVelocity = velocity
			state.position = rootPart.Position
			state.lastPosition = state.position
			return true
		end
	end

	local remainingFuse = math.max(state.explodeAt - currentTime, 0)
	state.lastPosition = state.position
	state.position = nextPosition
	state.path = {
		origin = state.position,
		initialVelocity = velocity,
		acceleration = Vector3.new(0, -workspace.Gravity * BombConfig.ProjectileGravityScale, 0),
		duration = math.max(tonumber(result.maxFlightSeconds) or BombConfig.ProjectileMaxFlightSeconds, remainingFuse, 0.12),
	}
	state.launchedAt = currentTime
	state.lastPosition = state.position
	state.landed = false
	return true
end

local function fireProjectileSnapshot(state: ProjectileState, currentTime: number, force: boolean?, velocity: Vector3?)
	local interval = 1 / math.max(BombProjectileConfig.SnapshotHz, 1)
	if not force and currentTime < state.nextSnapshotAt then
		return
	end

	state.nextSnapshotAt = currentTime + interval
	local position = state.position
	local currentVelocity = velocity
	if state.landed then
		position = getProjectilePhysicsPosition(state)
		currentVelocity = currentVelocity or getProjectilePhysicsVelocity(state)
	end

	local ownerUserId, ownerTeam = getOwnerVisualIdentity(state.owner)
	fireEffect("ProjectileSnapshot", {
		player = state.owner,
		ownerUserId = ownerUserId,
		ownerTeam = ownerTeam,
		projectileId = state.id,
		customProjectile = true,
		bombSkinId = state.skinId,
		position = position,
		velocity = currentVelocity or Vector3.zero,
		acceleration = Vector3.new(0, -workspace.Gravity * BombConfig.ProjectileGravityScale, 0),
		serverTime = currentTime,
		remainingFuse = math.max(state.explodeAt - currentTime, 0),
		settled = state.landed,
		grounded = state.landed,
		radius = state.sweepRadius,
		visuals = state.visuals,
		visualScale = state.visualScale,
		frozen = state.frozenUntil ~= nil and currentTime < state.frozenUntil,
		frozenUntil = state.frozenUntil,
		frozenBy = state.frozenBy,
	})
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

local function applyFreezeResult(
	state: ProjectileState,
	result,
	currentTime: number,
	currentVelocity: Vector3,
	position: Vector3
): boolean
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

	local frozenPosition = if typeof(result.position) == "Vector3" then result.position else position
	local frozenVelocity = if BombTrajectory.IsFiniteVector(result.velocity) then result.velocity else currentVelocity
	state.frozenUntil = frozenUntil
	state.frozenVelocity = frozenVelocity
	state.frozenPosition = frozenPosition
	state.frozenBy = if typeof(result.frozenBy) == "string" then result.frozenBy else nil
	state.position = frozenPosition
	state.lastPosition = frozenPosition
	state.landed = true

	destroyPhysicalProjectile(state)
	fireProjectileSnapshot(state, currentTime, true, Vector3.zero)
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

	if restoreVelocity and restoreVelocity.Magnitude > 0.05 then
		local remainingFuse = math.max(state.explodeAt - currentTime, 0)
		state.path = {
			origin = state.position,
			initialVelocity = restoreVelocity,
			acceleration = Vector3.new(0, -workspace.Gravity * BombConfig.ProjectileGravityScale, 0),
			duration = math.max(BombConfig.ProjectileMaxFlightSeconds, remainingFuse, 0.12),
		}
		state.launchedAt = currentTime
		state.landed = false
	else
		state.landed = true
	end

	fireProjectileSnapshot(state, currentTime, true, restoreVelocity or Vector3.zero)
end

local function stepFrozenProjectile(state: ProjectileState, deltaTime: number, currentTime: number): boolean
	local frozenUntil = state.frozenUntil
	if not frozenUntil then
		return false
	end
	if currentTime >= frozenUntil then
		releaseFrozenProjectile(state, currentTime)
		return false
	end

	state.explodeAt += math.max(deltaTime, 0)
	local frozenPosition = state.frozenPosition or state.position
	state.position = frozenPosition
	state.lastPosition = frozenPosition
	state.landed = true

	destroyPhysicalProjectile(state)
	fireProjectileSnapshot(state, currentTime, false, Vector3.zero)
	return true
end

local function updateProjectileStates(currentTime: number, deltaTime: number)
	local token = RuntimeProfiler.Begin("Server/BombService/UpdateProjectileStates")
	local activeCount = 0
	for projectileId, state in pairs(activeProjectiles) do
		activeCount += 1
		if not isActiveBombOwner(state.owner) then
			destroyPhysicalProjectile(state)
			activeProjectiles[projectileId] = nil
			continue
		end
		if stepFrozenProjectile(state, deltaTime, currentTime) then
			continue
		end
		local expired = currentTime >= state.explodeAt
		local alpha = 0
		local nextPosition = state.position
		local currentVelocity = Vector3.zero
		if state.landed then
			dampGroundedPhysicalProjectile(state, deltaTime)
			nextPosition = getProjectilePhysicsPosition(state)
			currentVelocity = getProjectilePhysicsVelocity(state)
		else
			alpha = math.clamp((currentTime - state.launchedAt) / state.path.duration, 0, 1)
			if expired then
				local fuseAlpha = math.clamp((state.explodeAt - state.launchedAt) / state.path.duration, 0, 1)
				nextPosition = BombTrajectory.Evaluate(state.path, fuseAlpha)
				currentVelocity = BombTrajectory.GetVelocity(state.path, fuseAlpha)
			else
				nextPosition = BombTrajectory.Evaluate(state.path, alpha)
				currentVelocity = BombTrajectory.GetVelocity(state.path, alpha)
			end
		end

		local stepResult = AbilityService:RunHook("OnProjectileStep", {
			projectileId = projectileId,
			owner = state.owner,
			position = state.position,
			lastPosition = state.lastPosition,
			nextPosition = nextPosition,
			currentVelocity = currentVelocity,
			landed = state.landed,
			currentTime = currentTime,
			explodeAt = state.explodeAt,
			remainingFuse = math.max(state.explodeAt - currentTime, 0),
			sweepRadius = state.sweepRadius,
			deltaTime = deltaTime,
			attached = false,
		})
		if stepResult.kind == RESULT_KIND.DestroyProjectile or stepResult.kind == RESULT_KIND.Absorb then
			destroyPhysicalProjectile(state)
			activeProjectiles[projectileId] = nil
			continue
		end
		if stepResult.kind == RESULT_KIND.ModifyProjectileTimeScale then
			local timeScale = math.clamp(tonumber(stepResult.timeScale) or 1, 0, 1)
			if timeScale < 1 then
				state.explodeAt += deltaTime * (1 - timeScale)
				if state.landed then
					if state.physicalRoot then
						state.physicalRoot.AssemblyLinearVelocity *= timeScale
					end
				else
					nextPosition = state.position:Lerp(nextPosition, timeScale)
					currentVelocity *= timeScale
				end
				expired = currentTime >= state.explodeAt
			end
		end
		if stepResult.kind == RESULT_KIND.DeferProjectile and typeof(stepResult.deferSeconds) == "number" then
			state.explodeAt += math.clamp(stepResult.deferSeconds, 0, BombConfig.FuseSeconds)
			continue
		end
		if stepResult.kind == RESULT_KIND.RedirectProjectile and redirectProjectile(state, stepResult, currentTime) then
			continue
		end
		if stepResult.kind == RESULT_KIND.FreezeProjectile
			and applyFreezeResult(state, stepResult, currentTime, currentVelocity, nextPosition)
		then
			continue
		end
		if stepResult.kind == RESULT_KIND.ModifyProjectileVelocity
			and applyProjectileVelocity(state, stepResult, currentTime, currentVelocity, nextPosition)
		then
			continue
		end

		if expired then
			if state.landed then
				state.position = getProjectilePhysicsPosition(state)
				state.lastPosition = state.position
			else
				state.position = nextPosition
				state.lastPosition = state.position
			end

			explode(state.owner, state.position, "Projectile", projectileId, state.skinId, state.explosionOverride)
			continue
		end
		if state.landed then
			state.position = nextPosition
			state.lastPosition = state.position
			fireProjectileSnapshot(state, currentTime, false, currentVelocity)
			continue
		end

		local hit = sweepProjectile(state.owner, state.lastPosition, nextPosition, state.sweepRadius)
		if hit then
			fireProjectileImpact(state, hit.Position, hit.Normal, currentVelocity)
		elseif alpha >= 1 then
			local position = BombTrajectory.Evaluate(state.path, 1)
			fireProjectileImpact(state, position, getSurfaceNormal(state.owner, position), BombTrajectory.GetVelocity(state.path, 1))
		else
			state.position = nextPosition
			state.lastPosition = nextPosition
			fireProjectileSnapshot(state, currentTime, false, currentVelocity)
		end
	end
	RuntimeProfiler.Gauge("Server/BombService/LegacyActiveProjectiles", activeCount)
	RuntimeProfiler.End("Server/BombService/UpdateProjectileStates", token)
end

local function beginCook(player: Player)
	if not isActivePlayer(player) then
		return
	end
	if cookStates[player] then
		return
	end
	if getBombCount(player) <= 0 then
		return
	end

	EmoteService:CancelActive(player, "Bomb")

	local skinId = BombSkinService:GetEquippedSkinId(player)
	local state = {
		holdStartedAt = now(),
		skinId = skinId,
	}
	cookStates[player] = state
	setCookingAttributes(player, false, 0)
	fireEffect("Hold", {
		player = player,
		startedAt = state.holdStartedAt,
		bombSkinId = skinId,
	})

	task.delay(BombConfig.CookDelaySeconds, function()
		startActiveCook(player, state)
	end)
end

local function releaseCook(player: Player, targetPayload: any)
	local state = cookStates[player]
	if not state then
		return
	end

	EmoteService:CancelActive(player, "Bomb")

	if not isActivePlayer(player) then
		stopCooking(player)
		return
	end

	local _, _, rootPart = getCharacterParts(player)
	if not rootPart then
		stopCooking(player)
		return
	end

	local currentTime = now()
	local cookStartedAt = state.cookStartedAt
	local throwStartedAt = currentTime
	local remainingFuse = BombConfig.FuseSeconds

	if cookStartedAt then
		local elapsed = currentTime - cookStartedAt
		if elapsed >= BombConfig.FuseSeconds then
			explodeInHand(player, "InHand")
			return
		end

		throwStartedAt = cookStartedAt
		remainingFuse = math.max(BombConfig.FuseSeconds - elapsed, 0)
	end

	if remainingFuse <= 0 then
		explodeInHand(player, "InHand")
		return
	end
	if not consumeBomb(player) then
		stopCooking(player)
		return
	end

	stopCooking(player)
	throwBomb(player, rootPart, targetPayload, throwStartedAt, remainingFuse, state.skinId)
end

local function updateRecharge(player: Player, currentTime: number)
	local count = getBombCount(player)
	if count >= BombConfig.MaxBombs then
		setBombAttributes(player, BombConfig.MaxBombs, 0)
		return
	end

	local rechargeEndsAt = player:GetAttribute(ATTR.RechargeEndsAt)
	if typeof(rechargeEndsAt) ~= "number" or rechargeEndsAt <= 0 then
		setBombAttributes(player, count, currentTime + BombConfig.RechargeSeconds)
		return
	end
	if currentTime < rechargeEndsAt then
		return
	end

	count += 1
	setBombAttributes(
		player,
		count,
		if count < BombConfig.MaxBombs then currentTime + BombConfig.RechargeSeconds else 0
	)
end

local function syncPlayerRoundState(player: Player)
	local roundId = player:GetAttribute(ROUND_ID_ATTR)
	if typeof(roundId) ~= "number" then
		if seenRoundIds[player] ~= nil then
			seenRoundIds[player] = nil
			resetPlayerBombs(player)
		end
		if cookStates[player] and not CombatEligibility.IsPracticeRangeActive(player) then
			stopCooking(player)
		end
		return
	end

	if seenRoundIds[player] ~= roundId then
		seenRoundIds[player] = roundId
		resetPlayerBombs(player)
	end
end

local function disconnectCharacter(player: Player)
	local connection = characterConnections[player]
	if connection then
		connection:Disconnect()
		characterConnections[player] = nil
	end
end

local function clearPlayerProjectiles(player: Player)
	BombProjectileService:ClearPlayerProjectiles(player)
	for projectileId, state in pairs(activeProjectiles) do
		if state.owner == player then
			destroyPhysicalProjectile(state)
			activeProjectiles[projectileId] = nil
		end
	end
end

function BombService:OnStart()
	beginRemote = ensureRemote(BEGIN_REMOTE_NAME)
	releaseRemote = ensureRemote(RELEASE_REMOTE_NAME)
	effectRemote = ensureRemote(EFFECT_REMOTE_NAME)

	BombProjectileService:SetHandlers({
		fireEffect = fireEffect,
		explode = explode,
	})

	beginRemote.OnServerEvent:Connect(beginCook)
	releaseRemote.OnServerEvent:Connect(releaseCook)

	if heartbeatConnection then
		heartbeatConnection:Disconnect()
	end
	heartbeatConnection = game:GetService("RunService").Heartbeat:Connect(function(deltaTime)
		local heartbeatToken = RuntimeProfiler.Begin("Server/BombService/Heartbeat")
		local currentTime = now()
		updateProjectileStates(currentTime, deltaTime)
		local playerCount = 0
		for _, player in ipairs(Players:GetPlayers()) do
			playerCount += 1
			local syncToken = RuntimeProfiler.Begin("Server/BombService/SyncPlayerRoundState")
			syncPlayerRoundState(player)
			RuntimeProfiler.End("Server/BombService/SyncPlayerRoundState", syncToken)
			if not isActivePlayer(player) and cookStates[player] then
				stopCooking(player)
			end
			local rechargeToken = RuntimeProfiler.Begin("Server/BombService/UpdateRecharge")
			updateRecharge(player, currentTime)
			RuntimeProfiler.End("Server/BombService/UpdateRecharge", rechargeToken)
		end
		RuntimeProfiler.Gauge("Server/BombService/PlayersUpdated", playerCount)
		RuntimeProfiler.End("Server/BombService/Heartbeat", heartbeatToken)
	end)
end

function BombService:OnPlayerAdded(player: Player)
	resetPlayerBombs(player)
	disconnectCharacter(player)
	characterConnections[player] = player.CharacterAdded:Connect(function()
		if cookStates[player] then
			stopCooking(player)
		end
	end)
end

function BombService:OnPlayerRemoving(player: Player)
	stopCooking(player)
	seenRoundIds[player] = nil
	clearPlayerProjectiles(player)
	disconnectCharacter(player)
end

function BombService:RefillBombsForPractice(player: Player): boolean
	if not player or player.Parent ~= Players then
		return false
	end

	setBombAttributes(player, BombConfig.MaxBombs, 0)
	return true
end

function BombService:ExplodeAbility(owner: Player, position: Vector3, sourceId: string, bombSkinId: string?, explosionOverride): boolean
	if not (owner and owner.Parent == Players and BombTrajectory.IsFiniteVector(position)) then
		return false
	end
	if typeof(sourceId) ~= "string" or sourceId == "" then
		return false
	end

	explosionOverride = if typeof(explosionOverride) == "table" then explosionOverride else {}
	explosionOverride.abilityId = if typeof(explosionOverride.abilityId) == "string"
		then explosionOverride.abilityId
		else sourceId
	explode(owner, position, "Ability", sourceId, bombSkinId, explosionOverride)
	return true
end

function BombService:LaunchStudioAIBomb(request): boolean
	if not RunService:IsStudio() or typeof(request) ~= "table" then
		return false
	end

	local owner = request.owner
	if not isStudioAIBotOwner(owner) or not isActiveBombOwner(owner) then
		return false
	end

	local origin = request.origin
	local aimDirection = request.aimDirection
	if not BombTrajectory.IsFiniteVector(origin) or not BombTrajectory.IsFiniteVector(aimDirection) then
		return false
	end

	local skinId = BombSkinConfig.NormalizeSkinId(request.skinId)
	if skinId == "" then
		skinId = BombSkinConfig.DefaultSkinId
	end

	local currentTime = now()
	local remainingFuse = readPositiveNumber(request.remainingFuse, BombConfig.FuseSeconds)
	local projectileId = createProjectileId(owner)
	if BombProjectileService:IsEnabled() then
		return BombProjectileService:Launch({
			owner = owner,
			projectileId = projectileId,
			bombType = BombProjectileConfig.BombType.Normal,
			skinId = skinId,
			origin = origin,
			aimDirection = sanitizeAimDirection(aimDirection, Vector3.zAxis),
			fuseStartedAt = currentTime,
			launchedAt = currentTime,
			remainingFuse = remainingFuse,
		})
	end

	local trajectory = calculateTrajectory(origin, sanitizeAimDirection(aimDirection, Vector3.zAxis))
	activeProjectiles[projectileId] = {
		id = projectileId,
		owner = owner,
		skinId = skinId,
		path = trajectory,
		launchedAt = currentTime,
		fuseStartedAt = currentTime,
		explodeAt = currentTime + remainingFuse,
		position = origin,
		lastPosition = origin,
		landed = false,
		sweepRadius = BombConfig.SweepRadius,
		visualScale = BombConfig.ProjectileVisualScale,
		visuals = nil,
		explosionOverride = nil,
		physicalProjectile = nil,
		physicalRoot = nil,
		nextSnapshotAt = currentTime,
		frozenUntil = nil,
		frozenVelocity = nil,
		frozenPosition = nil,
		frozenBy = nil,
	}
	fireEffect("Throw", {
		player = owner,
		projectileId = projectileId,
		bombSkinId = skinId,
		origin = trajectory.origin,
		initialVelocity = trajectory.initialVelocity,
		acceleration = trajectory.acceleration,
		duration = trajectory.duration,
		startedAt = currentTime,
		fuseStartedAt = currentTime,
		remainingFuse = remainingFuse,
	})
	local ownerIdentity = StudioAICombatants.GetOwnerIdentity(owner)
	recordReplayEvent("BombThrown", {
		bombId = projectileId,
		ownerUserId = getOwnerUserId(owner),
		ownerName = if ownerIdentity then ownerIdentity.name else nil,
		ownerDisplayName = if ownerIdentity then ownerIdentity.displayName else nil,
		ownerTeam = if ownerIdentity then ownerIdentity.teamName else nil,
		ownerIsNPC = if ownerIdentity then ownerIdentity.isNPC == true else nil,
		bombType = BombProjectileConfig.BombType.Normal,
		bombSkinId = skinId,
		position = trajectory.origin,
		velocity = trajectory.initialVelocity,
		fuseDuration = remainingFuse,
	})
	return true
end

function BombService:AdminRefillBombs(player: Player): (boolean, string?)
	if not player or player.Parent ~= Players then
		return false, "Target player is not in this server"
	end

	stopCooking(player)
	setBombAttributes(player, BombConfig.MaxBombs, 0)
	setCookingAttributes(player, false, 0)
	return true, "Refilled bombs for " .. player.Name
end

function BombService:AdminClearPlayerBombState(player: Player): (boolean, string?)
	if not player or player.Parent ~= Players then
		return false, "Target player is not in this server"
	end

	stopCooking(player)
	clearPlayerProjectiles(player)
	setCookingAttributes(player, false, 0)
	return true, "Cleared bomb state for " .. player.Name
end

return BombService
