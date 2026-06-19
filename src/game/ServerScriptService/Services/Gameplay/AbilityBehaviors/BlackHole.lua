local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)
local RoundService = require(ServerScriptService.Services.RoundService)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityHookResult = AbilityTypes.AbilityHookResult
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext

type ProjectileRecord = {
	player: Player,
	slot: string,
	projectileId: string,
	bombSkinId: string,
}

type BlackHoleRecord = {
	id: string,
	player: Player,
	slot: string,
	projectileId: string,
	bombSkinId: string,
	center: Vector3,
	radius: number,
	startedAt: number,
	activeEndsAt: number,
	projectileTimes: { [string]: number },
}

local BlackHole = {} :: AbilityTypes.ServerBehavior

local RESULT_KIND = AbilityResult.Kind
local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5
local ROUND_TEAM_ATTR = "RoundTeam"
local PROJECTILES: { [string]: ProjectileRecord } = {}
local ACTIVE_BLACK_HOLES: { [string]: BlackHoleRecord } = {}
local PULLED_PLAYERS: { [Player]: boolean } = {}
local projectileSerial = 0
local blackHoleSerial = 0
local bombProjectileService = nil
local abilityService: AbilityServiceLike? = nil
local heartbeatConnection: RBXScriptConnection? = nil

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

local function getPlayerParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return character, humanoid, rootPart
	end
	return character, humanoid, nil
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
	return ("BlackHole_%d_%d_%04d"):format(
		player.UserId,
		math.floor(workspace:GetServerTimeNow() * 1000),
		projectileSerial % 10000
	)
end

local function createBlackHoleId(player: Player): string
	blackHoleSerial += 1
	return ("BlackHoleField_%d_%d_%04d"):format(
		player.UserId,
		math.floor(workspace:GetServerTimeNow() * 1000),
		blackHoleSerial % 10000
	)
end

local function getTeamName(player: Player): string?
	local teamName = player:GetAttribute(ROUND_TEAM_ATTR)
	return if typeof(teamName) == "string" and teamName ~= "" then teamName else nil
end

local function isEnemyPlayer(owner: Player, target: Player): boolean
	if target == owner then
		return false
	end
	local ownerTeam = getTeamName(owner)
	local targetTeam = getTeamName(target)
	return not (ownerTeam and targetTeam and ownerTeam == targetTeam)
end

local function readVector(value: any, fallback: Vector3): Vector3
	if typeof(value) == "Vector3" and value.X == value.X and value.Y == value.Y and value.Z == value.Z then
		return value
	end
	return fallback
end

local function getPayloadPosition(payload): Vector3?
	if typeof(payload) ~= "table" then
		return nil
	end
	if typeof(payload.nextPosition) == "Vector3" then
		return payload.nextPosition
	end
	if typeof(payload.position) == "Vector3" then
		return payload.position
	end
	return nil
end

local function cleanupProjectileLater(projectileId: string, record: ProjectileRecord, delaySeconds: number)
	task.delay(delaySeconds, function()
		if PROJECTILES[projectileId] == record then
			PROJECTILES[projectileId] = nil
		end
	end)
end

local function removeBlackHole(fieldId: string): BlackHoleRecord?
	local record = ACTIVE_BLACK_HOLES[fieldId]
	ACTIVE_BLACK_HOLES[fieldId] = nil
	return record
end

local function restorePulledPlayer(player: Player)
	PULLED_PLAYERS[player] = nil
	local _, _, rootPart = getPlayerParts(player)
	if rootPart then
		pcall(function()
			rootPart:SetNetworkOwner(player)
		end)
	end
end

local function stopHeartbeatIfIdle()
	if next(ACTIVE_BLACK_HOLES) ~= nil then
		return
	end
	for player in pairs(PULLED_PLAYERS) do
		restorePulledPlayer(player)
	end
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

local function getDefinition(): AbilityDefinition?
	local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
	return AbilityConfig.GetDefinition("BlackHole")
end

local function pullPlayers(dt: number)
	local definition = getDefinition()
	if not definition then
		return
	end

	local currentTime = workspace:GetServerTimeNow()
	local pulledThisStep: { [Player]: boolean } = {}
	local playerPullSpeed = math.max(getDefinitionNumber(definition, "playerPullSpeed", 68), 1)
	local playerMaxPullSpeed = math.max(getDefinitionNumber(definition, "playerMaxPullSpeed", 92), playerPullSpeed)
	local playerUpwardBias = getDefinitionNumber(definition, "playerUpwardBias", 8)
	local captureRadius = math.max(getDefinitionNumber(definition, "playerCaptureRadius", 4), 0.1)
	local responsiveness = math.max(getDefinitionNumber(definition, "pullResponsiveness", 6.5), 0)

	for fieldId, field in pairs(ACTIVE_BLACK_HOLES) do
		if currentTime >= field.activeEndsAt + 8 then
			removeBlackHole(fieldId)
			continue
		end
		if currentTime >= field.activeEndsAt then
			continue
		end

		for _, target in ipairs(Players:GetPlayers()) do
			if not isEnemyPlayer(field.player, target) or not RoundService:IsPlayerActive(target) then
				continue
			end

			local _, _, rootPart = getPlayerParts(target)
			if not rootPart then
				continue
			end

			local offset = field.center - rootPart.Position
			local distance = offset.Magnitude
			if distance <= 0.05 or distance > field.radius then
				continue
			end

			local pullSpeed = math.clamp(playerPullSpeed + (1 - distance / field.radius) * playerPullSpeed, playerPullSpeed, playerMaxPullSpeed)
			if distance <= captureRadius then
				pullSpeed = math.min(pullSpeed, distance * 12)
			end

			local desired = offset.Unit * pullSpeed + Vector3.yAxis * playerUpwardBias
			local alpha = math.clamp(responsiveness * math.max(dt, 0), 0, 1)
			pulledThisStep[target] = true
			if not PULLED_PLAYERS[target] then
				PULLED_PLAYERS[target] = true
				pcall(function()
					rootPart:SetNetworkOwner(nil)
				end)
			end
			rootPart.AssemblyLinearVelocity = rootPart.AssemblyLinearVelocity:Lerp(desired, alpha)
		end
	end

	for player in pairs(PULLED_PLAYERS) do
		if pulledThisStep[player] then
			continue
		end

		restorePulledPlayer(player)
	end

	stopHeartbeatIfIdle()
end

local function ensureHeartbeat()
	if heartbeatConnection then
		return
	end

	heartbeatConnection = RunService.Heartbeat:Connect(pullPlayers)
end

local function fireStartedEffect(record: BlackHoleRecord, definition: AbilityDefinition)
	local service = abilityService
	if not service then
		return
	end

	local cleanupSeconds = math.max(
		getDefinitionNumber(definition, "pullDurationSeconds", 2.6)
			+ getDefinitionNumber(definition, "visualCleanupSeconds", 4),
		0.1
	)

	service:FireEffect("BlackHoleStarted", {
		player = record.player,
		slot = record.slot,
		abilityId = "BlackHole",
		fieldId = record.id,
		projectileId = record.projectileId,
		position = record.center,
		radius = record.radius,
		activeEndsAt = record.activeEndsAt,
		assetPath = definition.assetPath,
		cleanupSeconds = cleanupSeconds,
	})
end

local function startBlackHole(
	projectileRecord: ProjectileRecord,
	definition: AbilityDefinition,
	position: Vector3,
	currentTime: number
): BlackHoleRecord
	local durationSeconds = math.max(getDefinitionNumber(definition, "pullDurationSeconds", 2.6), 0.1)
	local record: BlackHoleRecord = {
		id = createBlackHoleId(projectileRecord.player),
		player = projectileRecord.player,
		slot = projectileRecord.slot,
		projectileId = projectileRecord.projectileId,
		bombSkinId = projectileRecord.bombSkinId,
		center = position,
		radius = math.max(getDefinitionNumber(definition, "radius", 22), 1),
		startedAt = currentTime,
		activeEndsAt = currentTime + durationSeconds,
		projectileTimes = {},
	}

	ACTIVE_BLACK_HOLES[record.id] = record
	fireStartedEffect(record, definition)
	ensureHeartbeat()
	return record
end

local function getPullVelocity(field: BlackHoleRecord, definition: AbilityDefinition, payload, currentTime: number): Vector3?
	if typeof(payload) ~= "table" or payload.attached == true then
		return nil
	end

	local position = readVector(payload.position, Vector3.zero)
	local nextPosition = readVector(payload.nextPosition, position)
	local velocity = readVector(payload.currentVelocity, nextPosition - position)
	local sweepRadius = math.max(tonumber(payload.sweepRadius) or BombConfig.SweepRadius or 0, 0)
	local offset = field.center - position
	local distance = offset.Magnitude
	if distance > field.radius + sweepRadius then
		return nil
	end

	local projectileId = payload.projectileId
	local lastTime = if typeof(projectileId) == "string" then field.projectileTimes[projectileId] else nil
	local dt = if typeof(payload.deltaTime) == "number" and payload.deltaTime > 0
		then payload.deltaTime
		elseif typeof(lastTime) == "number"
			then currentTime - lastTime
			else 1 / 60
	dt = math.clamp(dt, 1 / 240, 0.12)
	if typeof(projectileId) == "string" then
		field.projectileTimes[projectileId] = currentTime
	end

	if distance <= 0.05 then
		return velocity * math.clamp(getDefinitionNumber(definition, "bombCaptureDamping", 0.56), 0, 1)
	end

	local direction = offset.Unit
	local maxSpeed = math.max(getDefinitionNumber(definition, "bombMaxPullSpeed", 105), 1)
	local responsiveness = math.max(getDefinitionNumber(definition, "pullResponsiveness", 6.5), 0)
	local captureRadius = math.max(getDefinitionNumber(definition, "bombCaptureRadius", 3), 0.1)

	if distance <= captureRadius then
		local damping = math.clamp(getDefinitionNumber(definition, "bombCaptureDamping", 0.56), 0, 1)
		local desired = direction * math.min(maxSpeed * 0.35, distance * 12)
		return velocity:Lerp(desired, math.clamp(responsiveness * dt, 0, 1)) * damping
	end

	local desired = direction * maxSpeed
	local falloff = math.clamp(1 - distance / math.max(field.radius, 0.1), 0, 1)
	local alpha = math.clamp(responsiveness * dt * (0.45 + falloff * 0.55), 0, 0.5)
	return velocity:Lerp(desired, alpha)
end

function BlackHole.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function BlackHole.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getBombProjectileService() ~= nil
end

function BlackHole.OnActivate(context: ServerActivateContext): AbilityActivationResult
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
			explosion = {
				explosionVisualScale = getDefinitionNumber(context.definition, "explosionVisualScale", 1.12),
			},
		},
	})
	if not launched then
		return false
	end

	local record: ProjectileRecord = {
		player = context.player,
		slot = context.slot,
		projectileId = projectileId,
		bombSkinId = skinId,
	}
	PROJECTILES[projectileId] = record
	cleanupProjectileLater(projectileId, record, remainingFuse + BombConfig.ProjectileLifetimePadding + 10)

	local state = context.slotState.state
	local blackHolesThrown = if typeof(state) == "table" and typeof(state.blackHolesThrown) == "number"
		then state.blackHolesThrown
		else 0
	local blackHolesOpened = if typeof(state) == "table" and typeof(state.blackHolesOpened) == "number"
		then state.blackHolesOpened
		else 0

	return {
		state = {
			blackHolesThrown = blackHolesThrown + 1,
			blackHolesOpened = blackHolesOpened,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "BlackHoleThrown",
			payload = {
				projectileId = projectileId,
			},
		},
	}
end

function BlackHole.OnProjectileStep(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	if not (typeof(payload) == "table" and typeof(payload.projectileId) == "string") then
		return AbilityResult.Continue()
	end

	local projectileId = payload.projectileId
	local projectileRecord = PROJECTILES[projectileId]
	if projectileRecord and projectileRecord.player == context.player then
		for _, field in pairs(ACTIVE_BLACK_HOLES) do
			if field.projectileId == projectileId then
				if context.now >= field.activeEndsAt then
					removeBlackHole(field.id)
					PROJECTILES[projectileId] = nil
					stopHeartbeatIfIdle()
					return {
						kind = RESULT_KIND.ExplodeProjectile,
						position = field.center,
					}
				end
				return AbilityResult.Continue()
			end
		end

		local remainingFuse = if typeof(payload.remainingFuse) == "number" then payload.remainingFuse else math.huge
		local leadSeconds = math.max(getDefinitionNumber(context.definition, "pullStartLeadSeconds", 0.08), 0.02)
		if remainingFuse <= leadSeconds then
			local position = getPayloadPosition(payload)
			if not position then
				return AbilityResult.Continue()
			end

			local field = startBlackHole(projectileRecord, context.definition, position, context.now)
			local state = context.slotState.state
			local blackHolesThrown = if typeof(state) == "table" and typeof(state.blackHolesThrown) == "number"
				then state.blackHolesThrown
				else 0
			local blackHolesOpened = if typeof(state) == "table" and typeof(state.blackHolesOpened) == "number"
				then state.blackHolesOpened
				else 0
			if abilityService then
				abilityService:SetSlotValues(context.player, context.slot, {
					state = {
						blackHolesThrown = blackHolesThrown,
						blackHolesOpened = blackHolesOpened + 1,
						lastActivatedAt = if typeof(state) == "table" and typeof(state.lastActivatedAt) == "number"
							then state.lastActivatedAt
							else 0,
					},
				})
			end

			return {
				kind = RESULT_KIND.FreezeProjectile,
				frozenUntil = field.activeEndsAt,
				frozenBy = field.id,
				position = field.center,
				velocity = Vector3.zero,
			}
		end
	end

	for fieldId, field in pairs(ACTIVE_BLACK_HOLES) do
		if context.now >= field.activeEndsAt + 8 then
			removeBlackHole(fieldId)
			continue
		end
		if context.now >= field.activeEndsAt then
			continue
		end
		local velocity = getPullVelocity(field, context.definition, payload, context.now)
		if velocity then
			return {
				kind = RESULT_KIND.ModifyProjectileVelocity,
				velocity = velocity,
				maxSpeed = context.definition.bombMaxPullSpeed,
				maxFlightSeconds = BombConfig.ProjectileMaxFlightSeconds,
			}
		end
	end

	stopHeartbeatIfIdle()
	return AbilityResult.Continue()
end

function BlackHole.OnPlayerRemoving(player: Player)
	PULLED_PLAYERS[player] = nil

	for projectileId, record in pairs(PROJECTILES) do
		if record.player == player then
			PROJECTILES[projectileId] = nil
		end
	end

	for fieldId, record in pairs(ACTIVE_BLACK_HOLES) do
		if record.player == player then
			ACTIVE_BLACK_HOLES[fieldId] = nil
		end
	end

	stopHeartbeatIfIdle()
end

return BlackHole
