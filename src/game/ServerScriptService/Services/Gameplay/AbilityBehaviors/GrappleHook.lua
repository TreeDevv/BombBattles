local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundService = require(ServerScriptService.Services.RoundService)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerClientMessageContext = AbilityTypes.ServerClientMessageContext

type GrappleSession = {
	sessionId: number,
	kind: string,
	shooter: Player,
	targetPlayer: Player?,
	targetRoot: BasePart?,
	targetProjectileId: string?,
	shooterRoot: BasePart?,
	hookPart: BasePart?,
	hookPosition: Vector3?,
	hookLocalOffset: CFrame?,
	startedAt: number,
	pullStartAt: number,
	maxDuration: number,
	releaseDistance: number,
	maxRange: number,
	lineOfSightBreaksHook: boolean,
	currentPullSpeed: number?,
	lastStepAt: number?,
}

local GrappleHook = {} :: AbilityTypes.ServerBehavior

local RESULT_KIND = AbilityResult.Kind
local DEBUG_GRAPPLE = false
local MAX_ABS_POSITION = 100000
local ORIGIN_SLACK = 45
local REQUEST_SPAM_SECONDS = 0.12
local MAX_RAYCAST_SKIPS = 8

local abilityService: AbilityServiceLike? = nil
local bombProjectileService: any? = nil
local nextSessionId = 0
local heartbeatConnection: RBXScriptConnection? = nil
local activeByShooter: { [Player]: GrappleSession } = {}
local activeByTarget: { [Player]: GrappleSession } = {}
local activeByBombRoot: { [BasePart]: GrappleSession } = {}
local activeByBombProjectile: { [string]: GrappleSession } = {}
local lastRequestAt: { [Player]: number } = {}

local BLOCKED_TAG = "GrappleBlocked"
local ENEMY_TAG = "GrappleEnemy"
local SURFACE_TAG = "HookableSurface"

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
	BLOCKED_TAG,
}

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionBoolean(definition: AbilityDefinition?, key: string, fallback: boolean): boolean
	local value = if definition then definition[key] else nil
	return if typeof(value) == "boolean" then value else fallback
end

local function getBombProjectileService()
	if bombProjectileService then
		return bombProjectileService
	end

	local services = ServerScriptService:FindFirstChild("Services")
	local module = services and services:FindFirstChild("BombProjectileService")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end

	local ok, service = pcall(require, module)
	if ok and typeof(service) == "table" then
		bombProjectileService = service
		return service
	end
	return nil
end

local function isFiniteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end

	return value.X == value.X
		and value.Y == value.Y
		and value.Z == value.Z
		and math.abs(value.X) <= MAX_ABS_POSITION
		and math.abs(value.Y) <= MAX_ABS_POSITION
		and math.abs(value.Z) <= MAX_ABS_POSITION
end

local function setServerStatus(player: Player, status: string, reason: string?, anchorPosition: Vector3?)
	player:SetAttribute("GrappleHook_ServerStatus", status)
	player:SetAttribute("GrappleHook_ServerRejectReason", reason or "")
	player:SetAttribute("GrappleHook_ServerAnchorPosition", anchorPosition)
	player:SetAttribute("GrappleHook_ServerAt", workspace:GetServerTimeNow())
	if DEBUG_GRAPPLE then
		print("[GrappleHook][Server]", player.Name, status, reason or "", anchorPosition)
	end
end

local function getActiveMap(): Instance?
	return workspace:FindFirstChild(RoundConfig.ActiveMapName)
end

local function getPracticeRange(): Instance?
	local lobby = workspace:FindFirstChild("Lobby")
	return lobby and lobby:FindFirstChild("PracticeRange") or nil
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

local function isBombInstance(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		if current:GetAttribute("ProjectileId") ~= nil or current:GetAttribute("BombType") ~= nil then
			return true
		end
		if current.Name == BombConfig.ProjectileFolderName then
			return true
		end
		current = current.Parent
	end
	return false
end

local function getBombRootFromHit(instance: Instance): BasePart?
	local projectileFolder = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	local current: Instance? = instance
	while current and current ~= workspace do
		local projectileId = current:GetAttribute("ProjectileId")
		local bombType = current:GetAttribute("BombType")
		local inProjectileFolder = projectileFolder ~= nil and current:IsDescendantOf(projectileFolder)
		if projectileId ~= nil or bombType ~= nil or current == projectileFolder or inProjectileFolder then
			if current:IsA("BasePart") and current:GetAttribute("ProjectileId") ~= nil then
				return current
			end
			if current:IsA("Model") then
				if current.PrimaryPart and current.PrimaryPart:IsA("BasePart") then
					return current.PrimaryPart
				end
				local matchingProjectileId = if typeof(projectileId) == "string" then projectileId else nil
				for _, descendant in ipairs(current:GetDescendants()) do
					if descendant:IsA("BasePart") then
						if not matchingProjectileId or descendant:GetAttribute("ProjectileId") == matchingProjectileId then
							return descendant
						end
					end
				end
			end
			local ancestorModel = current:FindFirstAncestorOfClass("Model")
			if ancestorModel then
				if ancestorModel.PrimaryPart and ancestorModel.PrimaryPart:IsA("BasePart") then
					return ancestorModel.PrimaryPart
				end
				for _, descendant in ipairs(ancestorModel:GetDescendants()) do
					if descendant:IsA("BasePart") and descendant:GetAttribute("ProjectileId") ~= nil then
						return descendant
					end
				end
			end
			if instance:IsA("BasePart") then
				return instance
			end
		end
		current = current.Parent
	end
	return nil
end

local function getProjectileIdFromBombRoot(rootPart: BasePart?): string?
	local current: Instance? = rootPart
	while current and current ~= workspace do
		local projectileId = current:GetAttribute("ProjectileId")
		if typeof(projectileId) == "string" and projectileId ~= "" then
			return projectileId
		end
		current = current.Parent
	end
	return nil
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

local function getHumanoidFromHit(instance: Instance): Humanoid?
	local model = instance:FindFirstAncestorOfClass("Model")
	return model and model:FindFirstChildOfClass("Humanoid") or nil
end

local function getEnemyPlayer(shooter: Player, instance: Instance): Player?
	local humanoid = getHumanoidFromHit(instance)
	local character = humanoid and humanoid.Parent
	if not (character and character:IsA("Model") and humanoid.Health > 0) then
		return nil
	end

	local player = Players:GetPlayerFromCharacter(character)
	if CombatEligibility.IsPracticeOnly(shooter, RoundService) then
		return nil
	end
	if player and player ~= shooter then
		return player
	end

	if player and player == shooter then
		return nil
	end

	return if hasTaggedAncestor(character, ENEMY_TAG) then player else nil
end

local function isValidSurface(instance: Instance): boolean
	if instance == workspace.Terrain then
		return true
	end
	if hasUnsafeTaggedAncestor(instance) or isBombInstance(instance) then
		return false
	end

	local part = if instance:IsA("BasePart") then instance else nil
	if not part or not part.CanCollide or part.Transparency >= 1 then
		return false
	end

	local activeMap = getActiveMap()
	local practiceRange = getPracticeRange()
	return (activeMap ~= nil and part:IsDescendantOf(activeMap))
		or (practiceRange ~= nil and part:IsDescendantOf(practiceRange))
		or hasTaggedAncestor(part, SURFACE_TAG)
end

local function isSkippableHit(instance: Instance): boolean
	if instance == workspace.Terrain then
		return false
	end
	if getBombRootFromHit(instance) then
		return false
	end
	if hasUnsafeTaggedAncestor(instance) then
		return true
	end
	if getHumanoidFromHit(instance) then
		return false
	end
	local part = if instance:IsA("BasePart") then instance else nil
	return part ~= nil and (not part.CanCollide or part.Transparency >= 1)
end

local function performServerRaycast(shooter: Player, origin: Vector3, direction: Vector3, maxRange: number): RaycastResult?
	local excluded = {}
	if shooter.Character then
		table.insert(excluded, shooter.Character)
	end
	for _, folderName in ipairs({ "GrappleHookVisuals", "AirBurstVisuals", "WallBuilderPreview" }) do
		local folder = workspace:FindFirstChild(folderName)
		if folder then
			table.insert(excluded, folder)
		end
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = false

	local remainingOrigin = origin
	local traveled = 0
	for _ = 1, MAX_RAYCAST_SKIPS do
		params.FilterDescendantsInstances = excluded
		local remainingDistance = maxRange - traveled
		if remainingDistance <= 0 then
			return nil
		end

		local hit = workspace:Raycast(remainingOrigin, direction.Unit * remainingDistance, params)
		if not hit then
			return nil
		end
		if not isSkippableHit(hit.Instance) then
			return hit
		end

		table.insert(excluded, hit.Instance)
		local stepDistance = (hit.Position - remainingOrigin).Magnitude + 0.05
		traveled += stepDistance
		remainingOrigin = hit.Position + direction.Unit * 0.05
	end

	return nil
end

local function getServerOrigin(rootPart: BasePart): Vector3
	return rootPart.Position + Vector3.yAxis * 1.6
end

local function getPullStartTiming(
	definition: AbilityDefinition?,
	origin: Vector3,
	anchorPosition: Vector3,
	now: number
): (number, number, number)
	local speed = math.max(getDefinitionNumber(definition, "projectileSpeed", 375), 1)
	local maxTravelTime = math.max(getDefinitionNumber(definition, "hookTravelMaxSeconds", 0.65), 0.04)
	local travelTime = math.clamp((anchorPosition - origin).Magnitude / speed, 0.04, maxTravelTime)
	local tautSeconds = math.max(getDefinitionNumber(definition, "springTautTweenSeconds", 0.16), 0.01)
	return travelTime, tautSeconds, now + travelTime + tautSeconds
end

local function validateRequest(context: ServerActivateContext): (BasePart?, Vector3?, string, number)
	local payload = context.payload
	if typeof(payload) ~= "table" then
		return nil, nil, "BadPayload", 0
	end

	local direction = payload.direction
	local origin = payload.origin
	local sessionId = if typeof(payload.sequence) == "number" then math.floor(payload.sequence) else 0
	if not isFiniteVector(direction) or direction.Magnitude < 0.9 then
		return nil, nil, "BadDirection", sessionId
	end

	local rootPart = getCharacterRoot(context.player)
	if not rootPart then
		return nil, nil, "NoCharacter", sessionId
	end

	local serverOrigin = getServerOrigin(rootPart)
	if isFiniteVector(origin) and (origin - serverOrigin).Magnitude > ORIGIN_SLACK then
		return nil, nil, "BadOrigin", sessionId
	end

	if activeByShooter[context.player] then
		return nil, nil, "AlreadyGrappling", sessionId
	end

	return rootPart, direction.Unit, "", sessionId
end

local function cancelSession(session: GrappleSession, reason: string)
	if activeByShooter[session.shooter] == session then
		activeByShooter[session.shooter] = nil
	end
	if session.targetPlayer and activeByTarget[session.targetPlayer] == session then
		activeByTarget[session.targetPlayer] = nil
	end
	if session.kind == "Bomb" and session.targetRoot and activeByBombRoot[session.targetRoot] == session then
		activeByBombRoot[session.targetRoot] = nil
	end
	if session.kind == "Bomb" and session.targetProjectileId and activeByBombProjectile[session.targetProjectileId] == session then
		activeByBombProjectile[session.targetProjectileId] = nil
	end

	local targetRoot = session.targetRoot
	if targetRoot and targetRoot.Parent and session.kind ~= "Bomb" then
		targetRoot.AssemblyLinearVelocity = Vector3.zero
		if session.targetPlayer then
			pcall(function()
				targetRoot:SetNetworkOwner(session.targetPlayer)
			end)
		end
	end

	local service = abilityService
	if service then
		service:FireEffect("GrappleHookCancel", {
			player = session.shooter,
			abilityId = "GrappleHook",
			payload = {
				sessionId = session.sessionId,
				reason = reason,
			},
		})
	end
end

local function getHookWorldPosition(session: GrappleSession): Vector3?
	if session.hookPart and session.hookPart.Parent then
		if session.hookLocalOffset then
			return (session.hookPart.CFrame * session.hookLocalOffset).Position
		end
		return session.hookPart.Position
	end
	if session.hookPosition then
		return session.hookPosition
	end
	return nil
end

local function resolveEnemyHitDamage(
	owner: Player,
	target: Player,
	humanoid: Humanoid,
	rootPart: BasePart,
	damage: number
): (number, boolean)
	local service = abilityService
	if not service then
		return damage, false
	end

	local hookResult = service:RunHook("OnBeforePlayerDamage", {
		owner = owner,
		target = target,
		character = target.Character,
		humanoid = humanoid,
		rootPart = rootPart,
		damage = damage,
		sourceType = "Ability",
		sourceId = "GrappleHook",
	})
	if typeof(hookResult) ~= "table" then
		return damage, false
	end
	if hookResult.kind == RESULT_KIND.Block or hookResult.kind == RESULT_KIND.Absorb or hookResult.skipDamage == true then
		return 0, true
	end
	if typeof(hookResult.damage) == "number" then
		return math.max(hookResult.damage, 0), false
	end
	if typeof(hookResult.damageMultiplier) == "number" then
		return math.max(damage * hookResult.damageMultiplier, 0), false
	end

	return damage, false
end

local function hasLineOfSight(session: GrappleSession, fromPart: BasePart, toPosition: Vector3): boolean
	if not session.lineOfSightBreaksHook then
		return true
	end

	local direction = toPosition - fromPart.Position
	if direction.Magnitude <= 0.05 then
		return true
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}
	if session.shooter.Character then
		table.insert(exclude, session.shooter.Character)
	end
	if session.targetPlayer and session.targetPlayer.Character then
		table.insert(exclude, session.targetPlayer.Character)
	end
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = true

	local hit = workspace:Raycast(fromPart.Position, direction, params)
	if not hit then
		return true
	end
	if session.hookPart and (hit.Instance == session.hookPart or hit.Instance:IsDescendantOf(session.hookPart)) then
		return true
	end
	if session.kind == "Bomb" and session.targetRoot and session.targetRoot.Parent then
		local bombContainer = session.targetRoot.Parent
		if hit.Instance == bombContainer or hit.Instance:IsDescendantOf(bombContainer) then
			return true
		end
	end
	return false
end

local function stepWallSession(session: GrappleSession, now: number)
	local rootPart = getCharacterRoot(session.shooter)
	local hookPosition = getHookWorldPosition(session)
	if not (rootPart and hookPosition) then
		cancelSession(session, "MissingRootOrHook")
		return
	end
	if now < session.pullStartAt then
		return
	end
	if now - session.pullStartAt >= session.maxDuration then
		cancelSession(session, "Timeout")
		return
	end

	local offset = hookPosition - rootPart.Position
	local distance = offset.Magnitude
	if distance <= session.releaseDistance then
		cancelSession(session, "Arrived")
		return
	end
	if distance >= session.maxRange * 1.35 then
		cancelSession(session, "TooFar")
		return
	end
	if not hasLineOfSight(session, rootPart, hookPosition) then
		cancelSession(session, "LineBlocked")
	end
end

local function stepEnemySession(session: GrappleSession, now: number)
	local shooterRoot = getCharacterRoot(session.shooter)
	local targetRoot = session.targetRoot
	local targetPlayer = session.targetPlayer
	if not (shooterRoot and targetRoot and targetRoot.Parent and targetPlayer and targetPlayer.Parent == Players) then
		cancelSession(session, "MissingTarget")
		return
	end

	local humanoid = targetPlayer.Character and targetPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		cancelSession(session, "TargetDead")
		return
	end
	if now < session.pullStartAt then
		return
	end
	if now - session.pullStartAt >= session.maxDuration then
		cancelSession(session, "Timeout")
		return
	end

	local offset = shooterRoot.Position - targetRoot.Position
	local distance = offset.Magnitude
	if distance <= session.releaseDistance then
		cancelSession(session, "Arrived")
		return
	end
	if distance >= session.maxRange * 1.35 then
		cancelSession(session, "TooFar")
		return
	end
	if not hasLineOfSight(session, targetRoot, shooterRoot.Position) then
		cancelSession(session, "LineBlocked")
		return
	end

	local definition = AbilityConfig.GetDefinition("GrappleHook")
	local pullSpeed = getDefinitionNumber(definition, "enemyPullSpeed", 95)
	local upwardBias = getDefinitionNumber(definition, "enemyUpwardBias", 14)
	targetRoot.AssemblyLinearVelocity = offset.Unit * pullSpeed + Vector3.yAxis * upwardBias
end

local function stepBombSession(session: GrappleSession, now: number, dt: number)
	local shooterRoot = getCharacterRoot(session.shooter)
	if not shooterRoot then
		cancelSession(session, "MissingBomb")
		return
	end

	local targetRoot = session.targetRoot
	local targetPosition = if targetRoot and targetRoot.Parent then targetRoot.Position else nil
	local projectileService = nil
	if not targetPosition and session.targetProjectileId then
		projectileService = getBombProjectileService()
		if projectileService and type(projectileService.GetProjectilePosition) == "function" then
			targetPosition = projectileService:GetProjectilePosition(session.targetProjectileId)
		end
	end
	if not targetPosition then
		cancelSession(session, "MissingBomb")
		return
	end

	if now < session.pullStartAt then
		return
	end
	if now - session.pullStartAt >= session.maxDuration then
		cancelSession(session, "Timeout")
		return
	end

	local offset = shooterRoot.Position - targetPosition
	local distance = offset.Magnitude
	if distance <= session.releaseDistance then
		cancelSession(session, "Arrived")
		return
	end
	if distance >= session.maxRange * 1.35 then
		cancelSession(session, "TooFar")
		return
	end
	if targetRoot and targetRoot.Parent and not hasLineOfSight(session, targetRoot, shooterRoot.Position) then
		cancelSession(session, "LineBlocked")
		return
	end

	local definition = AbilityConfig.GetDefinition("GrappleHook")
	local maxPullSpeed = getDefinitionNumber(definition, "bombPullSpeed", 115)
	local minPullSpeed = getDefinitionNumber(definition, "bombMinPullSpeed", 42)
	local pullAcceleration = getDefinitionNumber(definition, "bombPullAcceleration", 180)
	local currentPullSpeed = session.currentPullSpeed or minPullSpeed
	currentPullSpeed = math.min(currentPullSpeed + math.max(dt, 0) * pullAcceleration, maxPullSpeed)
	session.currentPullSpeed = currentPullSpeed
	local upwardBias = getDefinitionNumber(definition, "bombUpwardBias", 10)
	local velocity = offset.Unit * currentPullSpeed + Vector3.yAxis * upwardBias
	if targetRoot and targetRoot.Parent then
		targetRoot.AssemblyLinearVelocity = velocity
	end
	if session.targetProjectileId then
		projectileService = projectileService or getBombProjectileService()
		if projectileService and type(projectileService.ApplyExternalVelocity) == "function" then
			projectileService:ApplyExternalVelocity(session.targetProjectileId, velocity)
		end
	end
end

local function ensureHeartbeat()
	if heartbeatConnection then
		return
	end

	heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
		local now = workspace:GetServerTimeNow()
		for _, session in pairs(activeByShooter) do
			if session.kind == "Wall" then
				stepWallSession(session, now)
			end
		end
		for _, session in pairs(activeByTarget) do
			if session.kind == "Enemy" then
				stepEnemySession(session, now)
			end
		end
		local steppedBombSessions = {}
		for _, session in pairs(activeByBombRoot) do
			if session.kind == "Bomb" then
				steppedBombSessions[session] = true
				stepBombSession(session, now, dt)
			end
		end
		for _, session in pairs(activeByBombProjectile) do
			if session.kind == "Bomb" and not steppedBombSessions[session] then
				stepBombSession(session, now, dt)
			end
		end
	end)
end

local function createWallSession(context: ServerActivateContext, rootPart: BasePart, hit: RaycastResult, sessionId: number): AbilityActivationResult
	nextSessionId += 1
	sessionId = if sessionId > 0 then sessionId else nextSessionId

	local definition = context.definition
	local travelTime, tautSeconds, pullStartAt = getPullStartTiming(definition, getServerOrigin(rootPart), hit.Position, context.now)
	local session: GrappleSession = {
		sessionId = sessionId,
		kind = "Wall",
		shooter = context.player,
		shooterRoot = rootPart,
		hookPart = if hit.Instance:IsA("BasePart") then hit.Instance else nil,
		hookPosition = hit.Position,
		hookLocalOffset = if hit.Instance:IsA("BasePart") then hit.Instance.CFrame:ToObjectSpace(CFrame.new(hit.Position)) else nil,
		startedAt = context.now,
		pullStartAt = pullStartAt,
		maxDuration = getDefinitionNumber(definition, "playerMaxPullTime", 1.5),
		releaseDistance = getDefinitionNumber(definition, "playerArrivalDistance", 7),
		maxRange = getDefinitionNumber(definition, "maxRange", 350),
		lineOfSightBreaksHook = getDefinitionBoolean(definition, "lineOfSightBreaksHook", true),
	}
	activeByShooter[context.player] = session
	ensureHeartbeat()

	setServerStatus(context.player, "AcceptedWall", "", hit.Position)

	local state = context.slotState.state
	local activationCount = if typeof(state) == "table" and typeof(state.activationCount) == "number" then state.activationCount else 0
	return {
		state = {
			activationCount = activationCount + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "GrappleHookAttached",
			payload = {
				sessionId = sessionId,
				targetKind = "Wall",
				anchorPosition = hit.Position,
				hitNormal = hit.Normal,
				travelTime = travelTime,
				springTautSeconds = tautSeconds,
				pullStartAt = pullStartAt,
				playerPullSpeed = getDefinitionNumber(definition, "playerPullSpeed", 120),
				playerUpwardBias = getDefinitionNumber(definition, "playerUpwardBias", 22),
				playerArrivalDistance = getDefinitionNumber(definition, "playerArrivalDistance", 7),
				playerMaxPullTime = getDefinitionNumber(definition, "playerMaxPullTime", 1.5),
				maxRange = getDefinitionNumber(definition, "maxRange", 350),
				lineOfSightBreaksHook = getDefinitionBoolean(definition, "lineOfSightBreaksHook", true),
			},
		},
	}
end

local function createEnemySession(context: ServerActivateContext, rootPart: BasePart, enemyPlayer: Player, hit: RaycastResult, sessionId: number): AbilityActivationResult
	local enemyRoot = getCharacterRoot(enemyPlayer)
	if not enemyRoot or activeByTarget[enemyPlayer] then
		setServerStatus(context.player, "Rejected", "EnemyUnavailable", nil)
		return false
	end

	nextSessionId += 1
	sessionId = if sessionId > 0 then sessionId else nextSessionId

	local definition = context.definition
	local travelTime, tautSeconds, pullStartAt = getPullStartTiming(definition, getServerOrigin(rootPart), hit.Position, context.now)
	local session: GrappleSession = {
		sessionId = sessionId,
		kind = "Enemy",
		shooter = context.player,
		targetPlayer = enemyPlayer,
		targetRoot = enemyRoot,
		shooterRoot = rootPart,
		startedAt = context.now,
		pullStartAt = pullStartAt,
		maxDuration = getDefinitionNumber(definition, "enemyMaxPullTime", 1),
		releaseDistance = getDefinitionNumber(definition, "enemyReleaseDistance", 8),
		maxRange = getDefinitionNumber(definition, "maxRange", 350),
		lineOfSightBreaksHook = getDefinitionBoolean(definition, "lineOfSightBreaksHook", true),
	}
	activeByShooter[context.player] = session
	activeByTarget[enemyPlayer] = session
	ensureHeartbeat()

	pcall(function()
		enemyRoot:SetNetworkOwner(nil)
	end)

	local damage = getDefinitionNumber(definition, "damageOnEnemyHit", 20)
	local humanoid = enemyPlayer.Character and enemyPlayer.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and damage > 0 then
		local resolvedDamage, blocked = resolveEnemyHitDamage(context.player, enemyPlayer, humanoid, enemyRoot, damage)
		if not blocked and resolvedDamage > 0 then
			humanoid:TakeDamage(resolvedDamage)
		end
	end
	enemyPlayer:SetAttribute("GrappleHook_StunnedUntil", context.now + getDefinitionNumber(definition, "enemyStunTime", 0.5))

	setServerStatus(context.player, "AcceptedEnemy", "", hit.Position)

	local state = context.slotState.state
	local activationCount = if typeof(state) == "table" and typeof(state.activationCount) == "number" then state.activationCount else 0
	return {
		state = {
			activationCount = activationCount + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "GrappleHookAttached",
			payload = {
				sessionId = sessionId,
				targetKind = "Enemy",
				targetPlayer = enemyPlayer,
				anchorPosition = hit.Position,
				hitNormal = hit.Normal,
				travelTime = travelTime,
				springTautSeconds = tautSeconds,
				pullStartAt = pullStartAt,
				enemyPullSpeed = getDefinitionNumber(definition, "enemyPullSpeed", 95),
				enemyUpwardBias = getDefinitionNumber(definition, "enemyUpwardBias", 14),
				enemyReleaseDistance = getDefinitionNumber(definition, "enemyReleaseDistance", 8),
				enemyMaxPullTime = getDefinitionNumber(definition, "enemyMaxPullTime", 1),
			},
		},
	}
end

local function createBombSession(
	context: ServerActivateContext,
	rootPart: BasePart,
	bombRoot: BasePart?,
	projectileId: string?,
	hitPosition: Vector3,
	hitNormal: Vector3,
	sessionId: number
): AbilityActivationResult
	if bombRoot and activeByBombRoot[bombRoot] then
		setServerStatus(context.player, "Rejected", "BombUnavailable", nil)
		return false
	end
	if projectileId and activeByBombProjectile[projectileId] then
		setServerStatus(context.player, "Rejected", "BombUnavailable", nil)
		return false
	end

	nextSessionId += 1
	sessionId = if sessionId > 0 then sessionId else nextSessionId

	local definition = context.definition
	local travelTime, tautSeconds, pullStartAt = getPullStartTiming(definition, getServerOrigin(rootPart), hitPosition, context.now)
	local session: GrappleSession = {
		sessionId = sessionId,
		kind = "Bomb",
		shooter = context.player,
		targetRoot = bombRoot,
		targetProjectileId = projectileId,
		shooterRoot = rootPart,
		hookPart = bombRoot,
		hookPosition = hitPosition,
		startedAt = context.now,
		pullStartAt = pullStartAt,
		maxDuration = getDefinitionNumber(definition, "bombMaxPullTime", 1),
		releaseDistance = getDefinitionNumber(definition, "bombReleaseDistance", 5),
		maxRange = getDefinitionNumber(definition, "maxRange", 350),
		lineOfSightBreaksHook = getDefinitionBoolean(definition, "lineOfSightBreaksHook", true),
		currentPullSpeed = getDefinitionNumber(definition, "bombMinPullSpeed", 42),
		lastStepAt = context.now,
	}
	activeByShooter[context.player] = session
	if bombRoot then
		activeByBombRoot[bombRoot] = session
	end
	if projectileId then
		activeByBombProjectile[projectileId] = session
	end
	ensureHeartbeat()

	if bombRoot then
		pcall(function()
			bombRoot:SetNetworkOwner(nil)
		end)
	end

	setServerStatus(context.player, "AcceptedBomb", "", hitPosition)

	local state = context.slotState.state
	local activationCount = if typeof(state) == "table" and typeof(state.activationCount) == "number" then state.activationCount else 0
	return {
		state = {
			activationCount = activationCount + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "GrappleHookAttached",
			payload = {
				sessionId = sessionId,
				targetKind = "Bomb",
				targetInstance = bombRoot,
				anchorPosition = hitPosition,
				hitNormal = hitNormal,
				travelTime = travelTime,
				springTautSeconds = tautSeconds,
				pullStartAt = pullStartAt,
				bombPullSpeed = getDefinitionNumber(definition, "bombPullSpeed", 115),
				bombUpwardBias = getDefinitionNumber(definition, "bombUpwardBias", 10),
				bombReleaseDistance = getDefinitionNumber(definition, "bombReleaseDistance", 5),
				bombMaxPullTime = getDefinitionNumber(definition, "bombMaxPullTime", 1),
			},
		},
	}
end

function GrappleHook.CanActivate(context: ServerActivateContext): boolean
	local now = context.now
	local lastAt = lastRequestAt[context.player]
	lastRequestAt[context.player] = now
	if lastAt and now - lastAt < REQUEST_SPAM_SECONDS then
		setServerStatus(context.player, "Rejected", "Spam", nil)
		return false
	end
	return getCharacterRoot(context.player) ~= nil
end

function GrappleHook.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local rootPart, direction, rejectReason, sessionId = validateRequest(context)
	if not rootPart or not direction then
		setServerStatus(context.player, "Rejected", rejectReason, nil)
		return false
	end

	local definition = context.definition
	local maxRange = getDefinitionNumber(definition, "maxRange", 350)
	local serverOrigin = getServerOrigin(rootPart)
	local hit = performServerRaycast(context.player, serverOrigin, direction.Unit, maxRange)
	if hit then
		local bombRoot = getBombRootFromHit(hit.Instance)
		if bombRoot then
			return createBombSession(
				context,
				rootPart,
				bombRoot,
				getProjectileIdFromBombRoot(bombRoot),
				hit.Position,
				hit.Normal,
				sessionId
			)
		end
	end

	local projectileService = getBombProjectileService()
	local projectileHit = if projectileService and type(projectileService.FindProjectileAlongRay) == "function"
		then projectileService:FindProjectileAlongRay(serverOrigin, direction.Unit, maxRange)
		else nil
	if typeof(projectileHit) == "table" and typeof(projectileHit.projectileId) == "string" then
		local hitDistance = if hit then (hit.Position - serverOrigin).Magnitude else math.huge
		local projectileDistance = if typeof(projectileHit.distance) == "number" then projectileHit.distance else hitDistance
		if projectileDistance <= hitDistance then
			local projectilePosition = if typeof(projectileHit.position) == "Vector3"
				then projectileHit.position
				else serverOrigin + direction.Unit * projectileDistance
			local projectileRoot = if typeof(projectileHit.rootPart) == "Instance" and projectileHit.rootPart:IsA("BasePart")
				then projectileHit.rootPart
				else nil
			local normalOffset = serverOrigin - projectilePosition
			return createBombSession(
				context,
				rootPart,
				projectileRoot,
				projectileHit.projectileId,
				projectilePosition,
				if normalOffset.Magnitude > 0.05 then normalOffset.Unit else Vector3.yAxis,
				sessionId
			)
		end
	end

	if not hit then
		setServerStatus(context.player, "Miss", "NoHit", nil)
		return {
			state = context.slotState.state,
			cooldownSeconds = getDefinitionNumber(definition, "missCooldownSeconds", 2),
			effect = {
				name = "GrappleHookMiss",
				payload = {
					sessionId = sessionId,
					origin = serverOrigin,
					direction = direction.Unit,
					maxRange = maxRange,
				},
			},
		}
	end

	local enemyPlayer = getEnemyPlayer(context.player, hit.Instance)
	if enemyPlayer then
		return createEnemySession(context, rootPart, enemyPlayer, hit, sessionId)
	end

	if isValidSurface(hit.Instance) then
		return createWallSession(context, rootPart, hit, sessionId)
	end

	setServerStatus(context.player, "Rejected", "InvalidSurface", hit.Position)
	return {
		state = context.slotState.state,
		cooldownSeconds = getDefinitionNumber(definition, "missCooldownSeconds", 2),
		effect = {
			name = "GrappleHookFail",
			payload = {
				sessionId = sessionId,
				anchorPosition = hit.Position,
				hitNormal = hit.Normal,
			},
		},
	}
end

function GrappleHook.OnPlayerRemoving(player: Player)
	lastRequestAt[player] = nil
	local shooterSession = activeByShooter[player]
	if shooterSession then
		cancelSession(shooterSession, "PlayerRemoving")
	end
	local targetSession = activeByTarget[player]
	if targetSession then
		cancelSession(targetSession, "TargetRemoving")
	end
end

function GrappleHook.OnClientMessage(context: ServerClientMessageContext)
	if context.messageType ~= AbilityConfig.MessageTypes.Cancel then
		return
	end

	local session = activeByShooter[context.player]
	if not session then
		return
	end

	local payload = context.payload
	if typeof(payload) == "table" and typeof(payload.sessionId) == "number" and payload.sessionId ~= session.sessionId then
		return
	end

	cancelSession(session, "ClientCancel")
end

function GrappleHook.OnStart(service: AbilityServiceLike)
	abilityService = service
end

return GrappleHook
