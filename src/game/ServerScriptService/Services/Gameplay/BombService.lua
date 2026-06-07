local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local ProjectilePhysics = require(ReplicatedStorage.Shared.Bombs.ProjectilePhysics)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local AbilityService = require(ServerScriptService.Services.AbilityService)
local BombProjectileService = require(ServerScriptService.Services.BombProjectileService)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)
local DestructionService = require(ServerScriptService.Services.DestructionService)
local RoundService = require(ServerScriptService.Services.RoundService)

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
	owner: Player,
	skinId: string,
	path: any,
	launchedAt: number,
	fuseStartedAt: number,
	explodeAt: number,
	position: Vector3,
	lastPosition: Vector3,
	landed: boolean,
	physicalProjectile: Instance?,
	physicalRoot: BasePart?,
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

local function isStudioBombTeamProtectionBypassEnabled(): boolean
	if not RunService:IsStudio() then
		return false
	end

	local studioTesting = RoundConfig.StudioTesting
	return studioTesting ~= nil and studioTesting.AllowBombTeamProtectionBypass == true
end

local function ensureRemotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = REMOTES_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureRemote(name: string): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
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

local function isActivePlayer(player: Player): boolean
	return player.Parent == Players and RoundService:IsPlayerActive(player)
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

local function getTeamName(player: Player): string?
	local teamName = player:GetAttribute(ROUND_TEAM_ATTR)
	return if typeof(teamName) == "string" and teamName ~= "" then teamName else nil
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

local function preparePhysicalProjectile(projectileId: string, owner: Player, skinId: string): (Instance, BasePart)
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
	projectile:SetAttribute("BombSkinId", skinId)
	rootPart:SetAttribute("ProjectileId", projectileId)
	rootPart:SetAttribute("OwnerUserId", owner.UserId)
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

local function createProjectileId(player: Player): string
	nextProjectileId += 1
	return string.format("%d:%d", player.UserId, nextProjectileId)
end

local function getDamageForDistance(distance: number, directDamage: number, nearMax: number, nearMin: number, outerMax: number, outerMin: number): number
	if distance <= BombConfig.InnerRadius then
		return directDamage
	end
	if distance <= BombConfig.NearRadius then
		local alpha = (distance - BombConfig.InnerRadius) / math.max(BombConfig.NearRadius - BombConfig.InnerRadius, 0.001)
		return nearMax + (nearMin - nearMax) * alpha
	end
	if distance <= BombConfig.OuterRadius then
		local alpha = (distance - BombConfig.NearRadius) / math.max(BombConfig.OuterRadius - BombConfig.NearRadius, 0.001)
		return outerMax + (outerMin - outerMax) * alpha
	end

	return 0
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

local function applyKnockback(character: Model?, rootPart: BasePart, origin: Vector3, distance: number, multiplier: number?)
	local away = rootPart.Position - origin
	if away.Magnitude < 0.05 then
		away = Vector3.yAxis
	else
		away = away.Unit
	end

	local radiusAlpha = math.clamp(1 - (distance / BombConfig.OuterRadius), 0, 1)
	local scale = math.max(radiusAlpha, BombConfig.KnockbackMinScale) * (multiplier or 1)
	if scale <= 0 then
		return
	end
	local velocityDelta = Vector3.new(
		away.X * BombConfig.KnockbackHorizontal * scale,
		BombConfig.KnockbackVertical * scale,
		away.Z * BombConfig.KnockbackHorizontal * scale
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

local function applyOwnerKnockback(owner: Player, origin: Vector3)
	local character, humanoid, rootPart = getCharacterParts(owner)
	if not (humanoid and rootPart and humanoid.Health > 0) then
		return
	end

	local distance = (rootPart.Position - origin).Magnitude
	if distance <= BombConfig.OuterRadius then
		local hookResult = AbilityService:RunHook("OnBeforeOwnerBombKnockback", {
			owner = owner,
			character = character,
			humanoid = humanoid,
			rootPart = rootPart,
			origin = origin,
			distance = distance,
		})
		if shouldSuppressBombEffect(hookResult) or hookResult.skipKnockback == true then
			return
		end

		local knockbackMultiplier = if typeof(hookResult.knockbackMultiplier) == "number"
			then math.max(hookResult.knockbackMultiplier, 0)
			else 1
		applyKnockback(character, rootPart, origin, distance, knockbackMultiplier)
	end
end

local function damageEnemyPlayers(owner: Player, origin: Vector3, sourceId: string?)
	local ownerTeam = getTeamName(owner)
	local hitUserIds = {}
	local killedUserIds = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if player == owner then
			continue
		end
		if ownerTeam and getTeamName(player) == ownerTeam then
			continue
		end

		local character, humanoid, rootPart = getCharacterParts(player)
		if not (humanoid and rootPart and humanoid.Health > 0) then
			continue
		end

		local distance = (rootPart.Position - origin).Magnitude
		local damage = getDamageForDistance(
			distance,
			BombConfig.PlayerDirectDamage,
			BombConfig.PlayerNearDamageMax,
			BombConfig.PlayerNearDamageMin,
			BombConfig.PlayerOuterDamageMax,
			BombConfig.PlayerOuterDamageMin
		)
		if damage <= 0 then
			continue
		end

		local hookResult = AbilityService:RunHook("OnBeforePlayerBombDamage", {
			owner = owner,
			target = player,
			character = character,
			humanoid = humanoid,
			rootPart = rootPart,
			origin = origin,
			distance = distance,
			damage = damage,
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
			RoundService:RecordPlayerDamage(owner, player, appliedDamage, {
				sourceType = "Bomb",
				sourceId = sourceId,
			})
			humanoid:TakeDamage(damage)
			local healthAfter = humanoid.Health

			table.insert(hitUserIds, player.UserId)
			if healthBefore > 0 and healthAfter <= 0 then
				table.insert(killedUserIds, player.UserId)
			end
			recordReplayEvent("PlayerDamaged", {
				victimUserId = player.UserId,
				attackerUserId = owner.UserId,
				amount = appliedDamage,
				sourceType = "Bomb",
				sourceId = sourceId,
				victimHealthAfter = healthAfter,
			})
			sendWorldText("PlayerDamaged", owner, player, appliedDamage, rootPart.Position, {
				sourceType = "Bomb",
				sourceId = sourceId,
				victimHealthAfter = healthAfter,
			})
		end
		if hookResult.skipKnockback ~= true then
			applyKnockback(character, rootPart, origin, distance, knockbackMultiplier)
		end
	end

	return hitUserIds, killedUserIds
end

local function damageEnemyAnchors(owner: Player, origin: Vector3, sourceId: string?)
	local ownerTeam = getTeamName(owner)
	local bypassTeamProtection = isStudioBombTeamProtectionBypassEnabled()

	for _, core in ipairs(CollectionService:GetTagged(RoundConfig.Tags.TeamCore)) do
		local trackedCore = RoundService:GetTrackedCore(core)
		if not trackedCore then
			continue
		end
		if not bypassTeamProtection and ownerTeam and trackedCore:GetAttribute("Team") == ownerTeam then
			continue
		end

		local position = getInstancePosition(trackedCore)
		if not position then
			continue
		end

		local damage = getDamageForDistance(
			(position - origin).Magnitude,
			BombConfig.AnchorDirectDamage,
			BombConfig.AnchorNearDamageMax,
			BombConfig.AnchorNearDamageMin,
			BombConfig.AnchorOuterDamageMax,
			BombConfig.AnchorOuterDamageMin
		)
		if damage > 0 then
			local hookResult = AbilityService:RunHook("OnBeforeCoreBombDamage", {
				owner = owner,
				core = trackedCore,
				origin = origin,
				position = position,
				damage = damage,
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
				attackerUserId = owner.UserId,
				sourceType = "Bomb",
				sourceId = sourceId,
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

local function explode(owner: Player, position: Vector3, source: string, projectileId: string?, bombSkinId: string?)
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

	local explosionResult = AbilityService:RunHook("OnBeforeExplosion", {
		owner = owner,
		position = position,
		source = source,
		projectileId = projectileId,
		innerRadius = BombConfig.InnerRadius,
		outerRadius = BombConfig.OuterRadius,
		terrainRadius = BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius,
	})
	if shouldSuppressBombEffect(explosionResult) then
		return
	end
	if typeof(explosionResult.position) == "Vector3" then
		position = explosionResult.position
	end
	if typeof(explosionResult.owner) == "Instance" and explosionResult.owner:IsA("Player") then
		owner = explosionResult.owner
	end
	local impactTimestamp = workspace:GetServerTimeNow()

	local hitUserIds = {}
	local killedUserIds = {}
	local debrisPayloads = {}

	if isActivePlayer(owner) then
		debrisPayloads = DestructionService:DestroySphere(position, BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius, {
			sourceType = "Bomb",
			sourceId = projectileId,
			bombId = projectileId,
			ownerUserId = owner.UserId,
			timestamp = impactTimestamp,
		})
		applyOwnerKnockback(owner, position)
		hitUserIds, killedUserIds = damageEnemyPlayers(owner, position, projectileId)
		damageEnemyAnchors(owner, position, projectileId)
	end

	fireEffect("Explode", {
		player = owner,
		projectileId = projectileId,
		bombSkinId = bombSkinId,
		position = position,
		source = source,
		innerRadius = BombConfig.InnerRadius,
		outerRadius = BombConfig.OuterRadius,
		terrainRadius = BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius,
		hitUserIds = hitUserIds,
	})
	sendWorldText("BombExploded", owner, position, {
		projectileId = projectileId,
		source = source,
		sourceType = "Bomb",
		bombType = BombProjectileConfig.BombType.Normal,
		bombSkinId = bombSkinId,
	})
	if #debrisPayloads > 0 then
		fireEffect("TerrainDebris", {
			payloads = debrisPayloads,
		})
	end

	recordReplayEvent("BombExploded", {
		timestamp = impactTimestamp,
		bombId = projectileId,
		sourceId = projectileId,
		projectileId = projectileId,
		source = source,
		sourceType = "Bomb",
		ownerUserId = owner.UserId,
		bombType = BombProjectileConfig.BombType.Normal,
		bombSkinId = bombSkinId,
		position = position,
		innerRadius = BombConfig.InnerRadius,
		outerRadius = BombConfig.OuterRadius,
		terrainRadius = BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius,
		radius = BombConfig.OuterRadius,
		hitUserIds = hitUserIds,
		killedUserIds = killedUserIds,
	})
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

local function sweepProjectile(owner: Player, fromPosition: Vector3, toPosition: Vector3): RaycastResult?
	local direction = toPosition - fromPosition
	if direction.Magnitude <= 0.001 then
		return nil
	end

	local params = createSweepParams(owner)
	local spherecastOk, spherecastResult = pcall(function()
		return workspace:Spherecast(fromPosition, BombConfig.SweepRadius, direction, params)
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
	local fallbackDirection = rootPart.CFrame.LookVector
	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(targetPayload, fallbackDirection)
	if BombProjectileService:IsEnabled() then
		local projectileId = createProjectileId(player)
		BombProjectileService:Launch({
			owner = player,
			projectileId = projectileId,
			bombType = BombProjectileConfig.BombType.Normal,
			skinId = skinId,
			origin = origin,
			aimDirection = aimDirection,
			fuseStartedAt = startedAt,
			launchedAt = now(),
			remainingFuse = remainingFuse,
		})
		return
	end

	local trajectory = calculateTrajectory(origin, aimDirection)
	local launchResult = AbilityService:RunHook("OnBeforeProjectileLaunch", {
		owner = player,
		origin = origin,
		aimDirection = aimDirection,
		trajectory = trajectory,
		remainingFuse = remainingFuse,
		bombSkinId = skinId,
	})
	if shouldSuppressBombEffect(launchResult) then
		return
	end
	local projectileId = createProjectileId(player)
	local launchTime = now()
	local explodeAt = launchTime + remainingFuse
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
		physicalProjectile = nil,
		physicalRoot = nil,
	}
	activeProjectiles[projectileId] = state

	fireEffect("Throw", {
		player = player,
		projectileId = projectileId,
		bombSkinId = skinId,
		origin = trajectory.origin,
		initialVelocity = trajectory.initialVelocity,
		acceleration = trajectory.acceleration,
		duration = trajectory.duration,
		startedAt = launchTime,
		fuseStartedAt = startedAt,
		remainingFuse = remainingFuse,
	})
	recordReplayEvent("BombThrown", {
		bombId = projectileId,
		ownerUserId = player.UserId,
		bombType = BombProjectileConfig.BombType.Normal,
		bombSkinId = skinId,
		position = trajectory.origin,
		velocity = trajectory.initialVelocity,
		fuseDuration = remainingFuse,
	})

	task.delay(remainingFuse + BombConfig.ProjectileLifetimePadding, function()
		local currentState = activeProjectiles[projectileId]
		if currentState then
			destroyPhysicalProjectile(currentState)
			activeProjectiles[projectileId] = nil
		end
	end)
end

local function redirectProjectile(state: ProjectileState, result, currentTime: number): boolean
	if typeof(result) ~= "table" then
		return false
	end
	if not (BombTrajectory.IsFiniteVector(result.origin) and BombTrajectory.IsFiniteVector(result.aimDirection)) then
		return false
	end

	destroyPhysicalProjectile(state)

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
	})

	return true
end

local function updateProjectileStates(currentTime: number, deltaTime: number)
	for projectileId, state in pairs(activeProjectiles) do
		if not state.owner.Parent then
			destroyPhysicalProjectile(state)
			activeProjectiles[projectileId] = nil
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
			sweepRadius = BombConfig.SweepRadius,
		})
		if stepResult.kind == RESULT_KIND.DestroyProjectile then
			destroyPhysicalProjectile(state)
			activeProjectiles[projectileId] = nil
			continue
		end
		if stepResult.kind == RESULT_KIND.DeferProjectile and typeof(stepResult.deferSeconds) == "number" then
			state.explodeAt += math.clamp(stepResult.deferSeconds, 0, BombConfig.FuseSeconds)
			continue
		end
		if stepResult.kind == RESULT_KIND.RedirectProjectile and redirectProjectile(state, stepResult, currentTime) then
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

			explode(state.owner, state.position, "Projectile", projectileId, state.skinId)
			continue
		end
		if state.landed then
			state.position = nextPosition
			state.lastPosition = state.position
			continue
		end

		local hit = sweepProjectile(state.owner, state.lastPosition, nextPosition)
		if hit then
			fireProjectileImpact(state, hit.Position, hit.Normal, currentVelocity)
		elseif alpha >= 1 then
			local position = BombTrajectory.Evaluate(state.path, 1)
			fireProjectileImpact(state, position, getSurfaceNormal(state.owner, position), BombTrajectory.GetVelocity(state.path, 1))
		else
			state.position = nextPosition
			state.lastPosition = nextPosition
		end
	end
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
		if cookStates[player] then
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
		local currentTime = now()
		updateProjectileStates(currentTime, deltaTime)
		for _, player in ipairs(Players:GetPlayers()) do
			syncPlayerRoundState(player)
			if not isActivePlayer(player) and cookStates[player] then
				stopCooking(player)
			end
			updateRecharge(player, currentTime)
		end
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
