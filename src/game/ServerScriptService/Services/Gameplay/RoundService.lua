local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Teams = game:GetService("Teams")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local DestructionService = require(ServerScriptService.Services.DestructionService)
local DataService = require(ServerScriptService.Services.DataService)
local ReplicaService = require(ServerScriptService.Packages.ReplicaService)

local TEAM_ORDER = { RoundConfig.Teams.Red.name, RoundConfig.Teams.Blue.name }
local REMOTES_FOLDER_NAME = "Remotes"
local SUBMIT_MAP_VOTE_REMOTE_NAME = "SubmitMapVote"
local REPORT_PREFERRED_INPUT_REMOTE_NAME = "ReportPreferredInput"
local KILL_FEED_REMOTE_NAME = "KillFeed"
local ROUND_ID_ATTR = "RoundId"
local ROUND_TEAM_ATTR = "RoundTeam"
local ROUND_ALIVE_ATTR = "RoundAlive"
local ROUND_RESPAWN_ENDS_AT_ATTR = "RoundRespawnEndsAt"
local CORE_HEALTH_ATTR = RoundConfig.Cores.HealthAttribute
local CORE_DESTROYED_ATTR = RoundConfig.Cores.DestroyedAttribute
local ASSIST_WINDOW_SECONDS = 10
local CASH_KEY = "cash"
local DEBUG_REPLAY_EVENTS = false
local DEBUG_DEATH_FLOW = RunService:IsStudio()

local VALID_PREFERRED_INPUT = {
	KeyboardAndMouse = true,
	Touch = true,
	Gamepad = true,
}

local GAME_STATE_TOKEN = ReplicaService.NewClassToken(RoundConfig.Scope)

type MapConfig = {
	id: string,
	displayName: string,
}

local getConfiguredMap: (string) -> MapConfig?
local getTrackedTeamName: (Player) -> string?

local RoundService = {}

local gameReplica = nil
local submitMapVoteRemote: RemoteEvent? = nil
local reportPreferredInputRemote: RemoteEvent? = nil
local killFeedRemote: RemoteEvent? = nil
local running = false
local roundId = 0
local currentState = RoundStates.WaitingForPlayers
local votingOpen = false
local pendingAdminForceStartMapId: string? = nil
local pendingAdminReset = false
local pendingAdminWinnerTeam: string? = nil
local currentChoices: { MapConfig } = {}
local voteCounts: { [string]: number } = {}
local playerVotes: { [Player]: string } = {}
local roundPlayers: { [Player]: boolean } = {}
local alivePlayers: { [Player]: boolean } = {}
local playerTeams: { [Player]: string } = {}
local characterConnections: { [Player]: { RBXScriptConnection } } = {}
local lobbyCharacterConnections: { [Player]: { RBXScriptConnection } } = {}
local respawnTokens: { [Player]: number } = {}
local teamCoreInstances: { [string]: { Instance } } = {}
local coreConnections: { [Instance]: { RBXScriptConnection } } = {}
local scoreboardStats: { [string]: { damage: number, eliminations: number, assists: number, deaths: number, destruction: number } } =
	{}
local scoreboardPlatforms: { [string]: string } = {}
local rewardedRoundIds: { [number]: boolean } = {}
local recentDamageContributors: { [string]: { [string]: { damagedAt: number, teamName: string?, sourceType: string?, sourceId: string? } } } =
	{}
local rng = Random.new()

local function debugDeathFlow(message: string, ...)
	if DEBUG_DEATH_FLOW then
		warn("[DeathFlow] " .. message, ...)
	end
end

local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		copy[key] = deepCopy(child)
	end
	return copy
end

local function getRequiredPlayerCount(): number
	local studioTesting = RoundConfig.StudioTesting
	if RunService:IsStudio() and studioTesting and typeof(studioTesting.MinPlayers) == "number" then
		return math.max(1, studioTesting.MinPlayers)
	end

	return RoundConfig.MinPlayers
end

local function isSoloStudioRoundHeldActive(counts): boolean
	local studioTesting = RoundConfig.StudioTesting
	if not (RunService:IsStudio() and studioTesting and studioTesting.HoldSoloRoundsActive == true) then
		return false
	end
	if getRequiredPlayerCount() > 1 or #Players:GetPlayers() ~= 1 then
		return false
	end

	local red = counts[RoundConfig.Teams.Red.name] or 0
	local blue = counts[RoundConfig.Teams.Blue.name] or 0
	return red + blue == 1
end

local function buildInitialState()
	return {
		roundId = 0,
		state = RoundStates.WaitingForPlayers,
		endsAt = 0,
		votingOpen = false,
		selectedMapId = "",
		winnerTeam = "",
		status = "Waiting for players",
		minPlayers = getRequiredPlayerCount(),
		aliveCounts = {
			[RoundConfig.Teams.Red.name] = 0,
			[RoundConfig.Teams.Blue.name] = 0,
		},
		coreCounts = {
			[RoundConfig.Teams.Red.name] = 0,
			[RoundConfig.Teams.Blue.name] = 0,
		},
		respawnsEnabled = {
			[RoundConfig.Teams.Red.name] = false,
			[RoundConfig.Teams.Blue.name] = false,
		},
		voteChoices = {},
		voteCounts = {},
		scoreboardStats = {},
		scoreboardPlatforms = {},
		roundResults = {},
	}
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

local function ensureVoteRemote(): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(SUBMIT_MAP_VOTE_REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = SUBMIT_MAP_VOTE_REMOTE_NAME
	remote.Parent = folder
	return remote
end

local function ensureReportPreferredInputRemote(): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(REPORT_PREFERRED_INPUT_REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = REPORT_PREFERRED_INPUT_REMOTE_NAME
	remote.Parent = folder
	return remote
end

local function ensureKillFeedRemote(): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(KILL_FEED_REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = KILL_FEED_REMOTE_NAME
	remote.Parent = folder
	return remote
end

local function setReplicaValue(path: { any }, value: any)
	if gameReplica then
		gameReplica:SetValue(path, value)
	end
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
		warn("[RoundService] ReplayService require failed:", service)
	end
	return nil
end

local function recordReplayEvent(eventType: string, payload)
	local service = getReplayService()
	if not (service and type(service.RecordEvent) == "function") then
		if eventType == "PlayerKilled" then
			debugDeathFlow("Replay event skipped; ReplayService.RecordEvent unavailable", payload)
		end
		return
	end

	if eventType == "PlayerKilled" then
		debugDeathFlow("Recording PlayerKilled replay event", payload)
	end

	local recorded = nil
	local ok, err = pcall(function()
		recorded = service.RecordEvent(eventType, payload)
	end)
	if DEBUG_REPLAY_EVENTS and not ok then
		warn("[RoundService] Replay event failed:", eventType, err)
	elseif eventType == "PlayerKilled" then
		debugDeathFlow("ReplayService.RecordEvent returned", "pcall", ok, "recorded", recorded, "err", err)
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

local function getPlayerRootPosition(player: Player): Vector3?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart.Position else nil
end

local function setReplayPerformanceCritical(isCritical: boolean)
	local service = getReplayService()
	if not (service and type(service.SetPerformanceCritical) == "function") then
		return
	end

	local ok, err = pcall(function()
		service.SetPerformanceCritical(isCritical)
	end)
	if DEBUG_REPLAY_EVENTS and not ok then
		warn("[RoundService] Replay performance state failed:", err)
	end
end

local function resetReplayRoundState()
	local service = getReplayService()
	if not service then
		return
	end

	local ok, err = pcall(function()
		if type(service.ResetRound) == "function" then
			service.ResetRound(roundId)
		elseif type(service.ResetPOTGRound) == "function" then
			service.ResetPOTGRound(roundId)
		end
	end)
	if DEBUG_REPLAY_EVENTS and not ok then
		warn("[RoundService] Replay round reset failed:", err)
	end
end

local function setReplayRoundMap(mapId: string, map: Model)
	local service = getReplayService()
	if not (service and type(service.SetRoundMap) == "function") then
		return
	end

	local ok, err = pcall(function()
		service.SetRoundMap(mapId, map:GetPivot())
	end)
	if DEBUG_REPLAY_EVENTS and not ok then
		warn("[RoundService] Replay map state failed:", err)
	end
end

local function getRoundReplayRecipients(): { Player }
	local recipients = {}
	for player in pairs(roundPlayers) do
		if player.Parent == Players then
			table.insert(recipients, player)
		end
	end
	return recipients
end

local function playRoundEndPOTG(): number
	local service = getReplayService()
	if not (service and type(service.PlayPOTG) == "function") then
		return 0
	end

	local startedAt = os.clock()
	local ok, err = pcall(function()
		service.PlayPOTG(getRoundReplayRecipients(), {
			maxWaitSeconds = RoundConfig.ResetSeconds,
		})
	end)
	if DEBUG_REPLAY_EVENTS and not ok then
		warn("[RoundService] POTG playback failed:", err)
	end

	return os.clock() - startedAt
end

local function getPlayerKey(playerOrUserId: Player | number | string): string
	if typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return tostring(playerOrUserId.UserId)
	end

	return tostring(playerOrUserId)
end

local function getScoreboardStatsFor(playerOrUserId: Player | number | string)
	local key = getPlayerKey(playerOrUserId)
	local stats = scoreboardStats[key]
	if not stats then
		stats = {
			damage = 0,
			eliminations = 0,
			assists = 0,
			deaths = 0,
			destruction = 0,
		}
		scoreboardStats[key] = stats
	end
	stats.damage = tonumber(stats.damage) or 0
	stats.eliminations = tonumber(stats.eliminations) or 0
	stats.assists = tonumber(stats.assists) or 0
	stats.deaths = tonumber(stats.deaths) or 0
	stats.destruction = tonumber(stats.destruction) or 0

	return stats
end

local function syncScoreboardStats()
	setReplicaValue({ "scoreboardStats" }, deepCopy(scoreboardStats))
end

local function syncScoreboardPlatforms()
	setReplicaValue({ "scoreboardPlatforms" }, deepCopy(scoreboardPlatforms))
end

local function resetScoreboardStats()
	scoreboardStats = {}
	recentDamageContributors = {}
	syncScoreboardStats()
end

local function getRewardConfig()
	return RoundConfig.Rewards or {}
end

local function getMapDisplayName(mapId: string): string
	local mapConfig = getConfiguredMap(mapId)
	if mapConfig and typeof(mapConfig.displayName) == "string" and mapConfig.displayName ~= "" then
		return mapConfig.displayName
	end

	return mapId
end

local function roundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue < 0 then
		return 0
	end

	return math.floor(numberValue + 0.5)
end

local function calculateReward(stats, winnerTeam: string, playerTeam: string?)
	local rewards = getRewardConfig()
	local damage = roundNonNegative(stats and stats.damage)
	local eliminations = roundNonNegative(stats and stats.eliminations)
	local destruction = roundNonNegative(stats and stats.destruction)
	local baseCoins = roundNonNegative(rewards.ParticipationCoins)

	if winnerTeam ~= "Draw" and playerTeam == winnerTeam then
		baseCoins += roundNonNegative(rewards.WinCoins)
	end

	baseCoins += eliminations * roundNonNegative(rewards.EliminationCoins)
	baseCoins += math.floor(damage / 100) * roundNonNegative(rewards.DamageCoinsPer100)
	baseCoins += destruction * roundNonNegative(rewards.DestructionCoinsPerTarget)

	local vipBonusMultiplier = tonumber(rewards.VipBonusMultiplier) or 0
	local vipBonusCoins = if vipBonusMultiplier > 0 then math.floor(baseCoins * vipBonusMultiplier + 0.5) else 0

	return {
		baseCoins = baseCoins,
		vipBonusCoins = vipBonusCoins,
		totalCoins = baseCoins + vipBonusCoins,
	}
end

local function buildRoundResults(winnerTeam: string)
	local selectedMapId = if gameReplica and typeof(gameReplica.Data.selectedMapId) == "string"
		then gameReplica.Data.selectedMapId
		else ""
	local results = {
		roundId = roundId,
		winnerTeam = winnerTeam,
		selectedMapId = selectedMapId,
		mapDisplayName = getMapDisplayName(selectedMapId),
		players = {},
	}

	for player in pairs(roundPlayers) do
		if player.Parent == Players then
			local playerKey = getPlayerKey(player)
			local playerTeam = getTrackedTeamName(player)
			local stats = deepCopy(getScoreboardStatsFor(player))
			local platform = scoreboardPlatforms[playerKey]

			table.insert(results.players, {
				userId = player.UserId,
				name = player.Name,
				displayName = player.DisplayName,
				teamName = playerTeam or "",
				platform = if typeof(platform) == "string" then platform else "KeyboardAndMouse",
				stats = stats,
				rewards = calculateReward(stats, winnerTeam, playerTeam),
			})
		end
	end

	return results
end

local function awardRoundResults(results)
	if rewardedRoundIds[results.roundId] then
		return
	end
	rewardedRoundIds[results.roundId] = true

	for _, playerResult in ipairs(results.players) do
		local player = Players:GetPlayerByUserId(playerResult.userId)
		local rewards = playerResult.rewards
		local totalCoins = if typeof(rewards) == "table" then roundNonNegative(rewards.totalCoins) else 0
		if player and totalCoins > 0 then
			DataService:Set(player, CASH_KEY, function(currentValue)
				return roundNonNegative(currentValue) + totalCoins
			end)
		end
	end
end

local function publishRoundResults(winnerTeam: string)
	local results = buildRoundResults(winnerTeam)
	awardRoundResults(results)
	setReplicaValue({ "roundResults" }, deepCopy(results))
end

local function clearRecentDamageFor(player: Player)
	recentDamageContributors[getPlayerKey(player)] = nil
end

local function removePlayerScoreboardState(player: Player)
	local playerKey = getPlayerKey(player)
	scoreboardStats[playerKey] = nil
	scoreboardPlatforms[playerKey] = nil
	recentDamageContributors[playerKey] = nil

	for _, contributors in pairs(recentDamageContributors) do
		contributors[playerKey] = nil
	end

	syncScoreboardStats()
	syncScoreboardPlatforms()
end

getTrackedTeamName = function(player: Player): string?
	local trackedTeam = playerTeams[player]
	if trackedTeam then
		return trackedTeam
	end

	local attributeTeam = player:GetAttribute(ROUND_TEAM_ATTR)
	return if typeof(attributeTeam) == "string" and attributeTeam ~= "" then attributeTeam else nil
end

local function isRecentEnemyContributor(attackerKey: string, contributor, victim: Player, currentTime: number): boolean
	if attackerKey == getPlayerKey(victim) then
		return false
	end
	if typeof(contributor) ~= "table" or typeof(contributor.damagedAt) ~= "number" then
		return false
	end
	if currentTime - contributor.damagedAt > ASSIST_WINDOW_SECONDS then
		return false
	end

	local victimTeam = getTrackedTeamName(victim)
	if not victimTeam then
		return true
	end

	return contributor.teamName ~= victimTeam
end

local function getPlayerByKey(playerKey: string): Player?
	for _, player in ipairs(Players:GetPlayers()) do
		if getPlayerKey(player) == playerKey then
			return player
		end
	end

	return nil
end

local function fireKillFeedElimination(eliminatorKey: string, victim: Player)
	local killer = getPlayerByKey(eliminatorKey)
	if not killer then
		return
	end

	local killerTeam = getTrackedTeamName(killer)
	local victimTeam = getTrackedTeamName(victim)
	if not killerTeam or not victimTeam or killerTeam == victimTeam then
		return
	end

	local remote = killFeedRemote
	if not remote then
		remote = ensureKillFeedRemote()
		killFeedRemote = remote
	end

	remote:FireAllClients({
		roundId = roundId,
		killerUserId = killer.UserId,
		killerName = killer.Name,
		killerDisplayName = killer.DisplayName,
		killerTeam = killerTeam,
		victimUserId = victim.UserId,
		victimName = victim.Name,
		victimDisplayName = victim.DisplayName,
		victimTeam = victimTeam,
	})
end

local function creditScoreboardDeath(victim: Player)
	local victimKey = getPlayerKey(victim)
	getScoreboardStatsFor(victim).deaths += 1

	local currentTime = workspace:GetServerTimeNow()
	local contributors = recentDamageContributors[victimKey]
	local eliminatorKey: string? = nil
	local eliminatorDamagedAt = -math.huge
	local eliminatorContributor = nil
	local eliminatorPlayer: Player? = nil

	if contributors then
		for attackerKey, contributor in pairs(contributors) do
			if isRecentEnemyContributor(attackerKey, contributor, victim, currentTime) and contributor.damagedAt > eliminatorDamagedAt then
				eliminatorKey = attackerKey
				eliminatorDamagedAt = contributor.damagedAt
				eliminatorContributor = contributor
			end
		end

		if eliminatorKey then
			getScoreboardStatsFor(eliminatorKey).eliminations += 1
			eliminatorPlayer = getPlayerByKey(eliminatorKey)
			fireKillFeedElimination(eliminatorKey, victim)
		end

		for attackerKey, contributor in pairs(contributors) do
			if attackerKey ~= eliminatorKey and isRecentEnemyContributor(attackerKey, contributor, victim, currentTime) then
				getScoreboardStatsFor(attackerKey).assists += 1
			end
		end
	end

	local playerKilledPayload = {
		timestamp = currentTime,
		roundId = roundId,
		victimUserId = victim.UserId,
		killerUserId = if eliminatorKey then tonumber(eliminatorKey) else nil,
		sourceType = if eliminatorContributor then eliminatorContributor.sourceType else nil,
		sourceId = if eliminatorContributor then eliminatorContributor.sourceId else nil,
	}
	local deathPosition = getPlayerRootPosition(victim)
	if deathPosition then
		playerKilledPayload.position = deathPosition
	end
	debugDeathFlow("PlayerKilled payload built", playerKilledPayload)
	recordReplayEvent("PlayerKilled", playerKilledPayload)
	sendWorldText("PlayerKilled", eliminatorPlayer, victim, deathPosition, {
		roundId = roundId,
		sourceType = playerKilledPayload.sourceType,
		sourceId = playerKilledPayload.sourceId,
	})

	clearRecentDamageFor(victim)
	syncScoreboardStats()
end

local function setState(state: string, status: string?, duration: number?)
	currentState = state
	setReplicaValue({ "state" }, state)
	setReplicaValue({ "status" }, status or state)
	setReplicaValue({ "endsAt" }, if duration and duration > 0 then workspace:GetServerTimeNow() + duration else 0)
	setReplicaValue({ "minPlayers" }, getRequiredPlayerCount())
	setReplayPerformanceCritical(state == RoundStates.Active)
end

local function setVotingOpen(open: boolean)
	votingOpen = open
	setReplicaValue({ "votingOpen" }, open)
end

local function setWinner(winnerTeam: string)
	setReplicaValue({ "winnerTeam" }, winnerTeam)
end

local function getMapFolder(): Instance?
	local current: Instance = ReplicatedStorage
	for _, name in ipairs(RoundConfig.MapsFolderPath) do
		local nextInstance = current:FindFirstChild(name)
		if not nextInstance then
			return nil
		end
		current = nextInstance
	end
	return current
end

local function getMapTemplate(mapId: string): Model?
	local folder = getMapFolder()
	if not folder then
		warn("[RoundService] Missing ReplicatedStorage." .. table.concat(RoundConfig.MapsFolderPath, "."))
		return nil
	end

	local template = folder:FindFirstChild(mapId)
	if not template then
		warn("[RoundService] Missing map template:", mapId)
		return nil
	end
	if not template:IsA("Model") then
		warn("[RoundService] Map template must be a Model:", template:GetFullName())
		return nil
	end

	return template
end

getConfiguredMap = function(mapId: string): MapConfig?
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		if mapConfig.id == mapId then
			return mapConfig
		end
	end
	return nil
end

local function getFirstConfiguredMapId(): string?
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		if getMapTemplate(mapConfig.id) then
			return mapConfig.id
		end
	end

	return nil
end

local function getTeam(teamName: string): Team?
	local team = Teams:FindFirstChild(teamName)
	if team and team:IsA("Team") then
		return team
	end

	warn("[RoundService] Missing Teams." .. teamName)
	return nil
end

local function ensureTeamsReady(): boolean
	for _, teamName in ipairs(TEAM_ORDER) do
		if not getTeam(teamName) then
			return false
		end
	end
	return true
end

local function getActiveMap(): Model?
	local active = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	if active and active:IsA("Model") then
		return active
	end
	return nil
end

local function clearActiveMap()
	local active = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	if active then
		active:Destroy()
	end
end

local function spawnActiveMap(mapId: string): Model?
	local template = getMapTemplate(mapId)
	if not template then
		return nil
	end

	clearActiveMap()

	local clone = template:Clone()
	clone.Name = RoundConfig.ActiveMapName
	clone.Parent = workspace
	return clone
end

local function getTaggedSpawnParts(tagName: string, map: Instance?): { BasePart }
	local spawns = {}
	for _, instance in ipairs(CollectionService:GetTagged(tagName)) do
		if instance:IsA("BasePart") and (not map or instance:IsDescendantOf(map)) then
			table.insert(spawns, instance)
		end
	end
	return spawns
end

local function getTeamSpawns(teamName: string, map: Instance): { BasePart }
	local spawns = {}
	for _, spawnPart in ipairs(getTaggedSpawnParts(RoundConfig.Tags.TeamSpawn, map)) do
		if spawnPart:GetAttribute("Team") == teamName then
			table.insert(spawns, spawnPart)
		end
	end
	return spawns
end

local function getTeamCores(teamName: string, map: Instance): { Instance }
	local cores = {}
	for _, instance in ipairs(CollectionService:GetTagged(RoundConfig.Tags.TeamCore)) do
		if instance:IsDescendantOf(map) and instance:GetAttribute("Team") == teamName then
			table.insert(cores, instance)
		end
	end
	return cores
end

local function getLobbySpawns(): { BasePart }
	return getTaggedSpawnParts(RoundConfig.Tags.LobbySpawn, nil)
end

local function moveCharacterToSpawn(player: Player, spawnPart: BasePart)
	local character = player.Character
	if not character then
		return
	end

	character:PivotTo(spawnPart.CFrame + Vector3.new(0, 4, 0))
end

local function movePlayerToLobby(player: Player)
	local lobbySpawns = getLobbySpawns()
	if #lobbySpawns == 0 then
		warn("[RoundService] Missing LobbySpawn tagged part")
		return
	end

	moveCharacterToSpawn(player, lobbySpawns[rng:NextInteger(1, #lobbySpawns)])
end

local function bumpRespawnToken(player: Player): number
	local token = (respawnTokens[player] or 0) + 1
	respawnTokens[player] = token
	return token
end

local function cancelScheduledRespawn(player: Player)
	bumpRespawnToken(player)
end

local function destroyPlayerCharacter(player: Player)
	local character = player.Character
	if character then
		character:Destroy()
	end
end

local function clearPlayerRoundState(player: Player)
	cancelScheduledRespawn(player)
	player:SetAttribute(ROUND_ID_ATTR, nil)
	player:SetAttribute(ROUND_TEAM_ATTR, nil)
	player:SetAttribute(ROUND_ALIVE_ATTR, nil)
	player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, nil)
	player.Neutral = true
	player.Team = nil
end

local function disconnectCoreConnections()
	for _, connections in pairs(coreConnections) do
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end

	coreConnections = {}
end

local function clearAllRoundTracking()
	for player in pairs(characterConnections) do
		for _, connection in ipairs(characterConnections[player]) do
			connection:Disconnect()
		end
	end

	characterConnections = {}
	disconnectCoreConnections()
	roundPlayers = {}
	alivePlayers = {}
	playerTeams = {}
	teamCoreInstances = {}
	playerVotes = {}
	voteCounts = {}
	currentChoices = {}
end

local function countAlivePlayers()
	local counts = {
		[RoundConfig.Teams.Red.name] = 0,
		[RoundConfig.Teams.Blue.name] = 0,
	}

	for player in pairs(alivePlayers) do
		local teamName = playerTeams[player]
		if teamName and counts[teamName] ~= nil then
			counts[teamName] += 1
		end
	end

	return counts
end

local function syncAliveCounts()
	setReplicaValue({ "aliveCounts" }, countAlivePlayers())
end

local function isCoreAlive(core: Instance): boolean
	if not core.Parent then
		return false
	end
	if core:GetAttribute(CORE_DESTROYED_ATTR) == true then
		return false
	end

	local health = core:GetAttribute(CORE_HEALTH_ATTR)
	if typeof(health) == "number" and health <= 0 then
		return false
	end

	local humanoid = core:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return false
	end

	return true
end

local function countAliveCores()
	local counts = {
		[RoundConfig.Teams.Red.name] = 0,
		[RoundConfig.Teams.Blue.name] = 0,
	}

	for teamName, cores in pairs(teamCoreInstances) do
		counts[teamName] = counts[teamName] or 0
		for _, core in ipairs(cores) do
			if isCoreAlive(core) then
				counts[teamName] += 1
			end
		end
	end

	return counts
end

local function buildRespawnState(coreCounts: { [string]: number })
	local respawnsEnabled = {}
	for _, teamName in ipairs(TEAM_ORDER) do
		respawnsEnabled[teamName] = (coreCounts[teamName] or 0) > 0
	end
	return respawnsEnabled
end

local function syncCoreState()
	local coreCounts = countAliveCores()
	setReplicaValue({ "coreCounts" }, coreCounts)
	setReplicaValue({ "respawnsEnabled" }, buildRespawnState(coreCounts))
end

local function teamHasRespawns(teamName: string?): boolean
	if not teamName then
		return false
	end

	local cores = teamCoreInstances[teamName]
	if not cores then
		return false
	end

	for _, core in ipairs(cores) do
		if isCoreAlive(core) then
			return true
		end
	end

	return false
end

local function disconnectCharacterConnections(player: Player)
	local connections = characterConnections[player]
	if not connections then
		return
	end

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	characterConnections[player] = nil
end

local function disconnectLobbyCharacterConnection(player: Player)
	local connections = lobbyCharacterConnections[player]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		lobbyCharacterConnections[player] = nil
	end
end

local function bindLobbyCharacter(player: Player)
	disconnectLobbyCharacterConnection(player)
	lobbyCharacterConnections[player] = {}

	local function track(connection: RBXScriptConnection)
		local connections = lobbyCharacterConnections[player]
		if connections then
			table.insert(connections, connection)
		else
			connection:Disconnect()
		end
	end

	local function bindNonRoundHumanoid(character: Model)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end

		track(humanoid.Died:Connect(function()
			if currentState == RoundStates.Active and roundPlayers[player] then
				return
			end

			local token = bumpRespawnToken(player)
			task.delay(RoundConfig.RespawnSeconds, function()
				if respawnTokens[player] ~= token then
					return
				end
				if player.Parent ~= Players then
					return
				end
				if currentState == RoundStates.Active and roundPlayers[player] then
					return
				end

				player:LoadCharacter()
			end)
		end))
	end

	local function onCharacterAdded(character: Model)
		task.defer(function()
			if currentState == RoundStates.Active and roundPlayers[player] and alivePlayers[player] then
				return
			end

			bindNonRoundHumanoid(character)
			movePlayerToLobby(player)
		end)
	end

	track(player.CharacterAdded:Connect(onCharacterAdded))
	if player.Character then
		onCharacterAdded(player.Character)
	end
end

local function bindCore(core: Instance, map: Instance)
	local connections = {}
	coreConnections[core] = connections

	local function onCoreStateChanged()
		if currentState == RoundStates.Active then
			syncCoreState()
		end
	end

	table.insert(connections, core:GetAttributeChangedSignal(CORE_HEALTH_ATTR):Connect(onCoreStateChanged))
	table.insert(connections, core:GetAttributeChangedSignal(CORE_DESTROYED_ATTR):Connect(onCoreStateChanged))
	table.insert(connections, core.AncestryChanged:Connect(function()
		if not core:IsDescendantOf(map) then
			onCoreStateChanged()
		end
	end))

	local humanoid = core:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(connections, humanoid.Died:Connect(onCoreStateChanged))
		table.insert(connections, humanoid.HealthChanged:Connect(onCoreStateChanged))
	end
end

local function setupTeamCores(map: Model): boolean
	disconnectCoreConnections()
	teamCoreInstances = {}

	for _, teamName in ipairs(TEAM_ORDER) do
		local cores = getTeamCores(teamName, map)
		teamCoreInstances[teamName] = cores

		if #cores < RoundConfig.Cores.MinPerTeam then
			warn("[RoundService] Missing TeamCore tagged instances for team:", teamName)
			syncCoreState()
			return false
		end

		for _, core in ipairs(cores) do
			bindCore(core, map)
		end
	end

	syncCoreState()
	return true
end

local function getWinnerFromAliveCounts(counts): string?
	local red = counts[RoundConfig.Teams.Red.name] or 0
	local blue = counts[RoundConfig.Teams.Blue.name] or 0

	if red > 0 and blue <= 0 then
		return RoundConfig.Teams.Red.name
	end
	if blue > 0 and red <= 0 then
		return RoundConfig.Teams.Blue.name
	end
	if red <= 0 and blue <= 0 then
		return "Draw"
	end
	return nil
end

local function getTimeoutWinner(): string
	local counts = countAlivePlayers()
	local red = counts[RoundConfig.Teams.Red.name] or 0
	local blue = counts[RoundConfig.Teams.Blue.name] or 0

	if red > blue then
		return RoundConfig.Teams.Red.name
	end
	if blue > red then
		return RoundConfig.Teams.Blue.name
	end
	return "Draw"
end

local function eliminatePlayer(player: Player)
	if not alivePlayers[player] then
		debugDeathFlow("eliminatePlayer ignored; player not alive", player.Name)
		return
	end

	debugDeathFlow("Eliminating player", player.Name, "team", tostring(playerTeams[player]), "roundId", roundId)
	cancelScheduledRespawn(player)
	alivePlayers[player] = nil
	player:SetAttribute(ROUND_ALIVE_ATTR, false)
	player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, 0)
	syncAliveCounts()
	destroyPlayerCharacter(player)
end

local function respawnPlayerInRound(player: Player)
	debugDeathFlow("Scheduling round respawn", player.Name, "delay", RoundConfig.RespawnSeconds, "roundId", roundId)
	clearRecentDamageFor(player)
	player:SetAttribute(ROUND_ALIVE_ATTR, false)
	player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, workspace:GetServerTimeNow() + RoundConfig.RespawnSeconds)
	destroyPlayerCharacter(player)

	local token = bumpRespawnToken(player)
	task.delay(RoundConfig.RespawnSeconds, function()
		if respawnTokens[player] ~= token then
			debugDeathFlow("Round respawn skipped; stale token", player.Name, token, respawnTokens[player])
			return
		end
		if player.Parent ~= Players then
			debugDeathFlow("Round respawn skipped; player left", player.Name)
			return
		end
		if currentState ~= RoundStates.Active or not roundPlayers[player] or alivePlayers[player] ~= true then
			debugDeathFlow(
				"Round respawn skipped; state changed",
				player.Name,
				"state",
				currentState,
				"roundPlayer",
				roundPlayers[player],
				"alive",
				alivePlayers[player]
			)
			return
		end
		if player:GetAttribute(ROUND_ALIVE_ATTR) ~= false then
			debugDeathFlow(
				"Round respawn skipped; RoundAlive attr changed before respawn",
				player.Name,
				player:GetAttribute(ROUND_ALIVE_ATTR)
			)
			return
		end

		debugDeathFlow("Loading round respawn character", player.Name)
		player:SetAttribute(ROUND_ALIVE_ATTR, true)
		player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, 0)
		player:LoadCharacter()
	end)
end

local function handlePlayerDeath(player: Player)
	if not alivePlayers[player] then
		debugDeathFlow("handlePlayerDeath ignored; player not alive", player.Name)
		return
	end

	debugDeathFlow(
		"Handling player death",
		player.Name,
		"team",
		tostring(playerTeams[player]),
		"hasRespawns",
		teamHasRespawns(playerTeams[player])
	)
	creditScoreboardDeath(player)

	if teamHasRespawns(playerTeams[player]) then
		respawnPlayerInRound(player)
	else
		eliminatePlayer(player)
	end
end

local function bindCharacter(player: Player)
	disconnectCharacterConnections(player)
	characterConnections[player] = {}

	local function bindHumanoid(character: Model)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end

		table.insert(characterConnections[player], humanoid.Died:Connect(function()
			if currentState == RoundStates.Active then
				debugDeathFlow("Humanoid.Died", player.Name, "roundId", roundId, "health", humanoid.Health)
				handlePlayerDeath(player)
			end
		end))
	end

	if player.Character then
		bindHumanoid(player.Character)
	end

	table.insert(characterConnections[player], player.CharacterAdded:Connect(function(character)
		task.defer(function()
			if currentState == RoundStates.Active and roundPlayers[player] and not alivePlayers[player] then
				movePlayerToLobby(player)
				return
			end

			if currentState == RoundStates.Active and roundPlayers[player] then
				bindHumanoid(character)
				player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, 0)
				local activeMap = getActiveMap()
				local teamName = playerTeams[player]
				if activeMap and teamName then
					local spawns = getTeamSpawns(teamName, activeMap)
					if #spawns > 0 then
						moveCharacterToSpawn(player, spawns[rng:NextInteger(1, #spawns)])
					end
				end
			else
				movePlayerToLobby(player)
			end
		end)
	end))
end

local function chooseVoteOptions(): { MapConfig }
	local available = {}
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		if getMapTemplate(mapConfig.id) then
			table.insert(available, mapConfig)
		end
	end

	local choices = {}
	while #available > 0 and #choices < RoundConfig.VoteChoiceCount do
		local index = rng:NextInteger(1, #available)
		table.insert(choices, table.remove(available, index))
	end

	return choices
end

local function syncVoteChoices()
	local choices = {}
	local counts = {}

	for _, mapConfig in ipairs(currentChoices) do
		table.insert(choices, {
			id = mapConfig.id,
			displayName = mapConfig.displayName,
		})
		counts[mapConfig.id] = voteCounts[mapConfig.id] or 0
	end

	setReplicaValue({ "voteChoices" }, choices)
	setReplicaValue({ "voteCounts" }, counts)
end

local function isCurrentChoice(mapId: string): boolean
	for _, mapConfig in ipairs(currentChoices) do
		if mapConfig.id == mapId then
			return true
		end
	end
	return false
end

local function chooseWinningMap(): string?
	local tied = {}
	local best = -math.huge

	for _, mapConfig in ipairs(currentChoices) do
		local count = voteCounts[mapConfig.id] or 0
		if count > best then
			best = count
			tied = { mapConfig.id }
		elseif count == best then
			table.insert(tied, mapConfig.id)
		end
	end

	if #tied == 0 then
		return nil
	end

	return tied[rng:NextInteger(1, #tied)]
end

local function getEligiblePlayers(): { Player }
	local players = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Parent == Players then
			table.insert(players, player)
		end
	end
	return players
end

local function shufflePlayers(players: { Player })
	for index = #players, 2, -1 do
		local swapIndex = rng:NextInteger(1, index)
		players[index], players[swapIndex] = players[swapIndex], players[index]
	end
end

local function assignTeams(players: { Player })
	shufflePlayers(players)

	for index, player in ipairs(players) do
		local teamName = TEAM_ORDER[((index - 1) % #TEAM_ORDER) + 1]
		local team = getTeam(teamName)

		roundPlayers[player] = true
		alivePlayers[player] = true
		playerTeams[player] = teamName
		player.Neutral = false
		player.Team = team
		player:SetAttribute(ROUND_ID_ATTR, roundId)
		player:SetAttribute(ROUND_TEAM_ATTR, teamName)
		player:SetAttribute(ROUND_ALIVE_ATTR, true)
		player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, 0)
		bindCharacter(player)
	end

	syncAliveCounts()
end

local function teleportTeamsToMap(map: Model): boolean
	for _, teamName in ipairs(TEAM_ORDER) do
		local spawns = getTeamSpawns(teamName, map)
		if #spawns == 0 then
			warn("[RoundService] Missing TeamSpawn parts for team:", teamName)
			return false
		end
	end

	for player in pairs(roundPlayers) do
		local teamName = playerTeams[player]
		local spawns = teamName and getTeamSpawns(teamName, map) or {}
		if #spawns > 0 then
			if not player.Character then
				player:LoadCharacter()
			end
			moveCharacterToSpawn(player, spawns[rng:NextInteger(1, #spawns)])
		end
	end

	return true
end

local function resetPlayersToLobby()
	for _, player in ipairs(Players:GetPlayers()) do
		clearPlayerRoundState(player)
		if not player.Character then
			player:LoadCharacter()
		end
		movePlayerToLobby(player)
	end
end

local function createGameReplica()
	if gameReplica then
		return
	end

	gameReplica = ReplicaService.NewReplica({
		ClassToken = GAME_STATE_TOKEN,
		Data = buildInitialState(),
		Replication = "All",
	})
end

local function createNewRound()
	roundId += 1
	resetReplayRoundState()
	resetScoreboardStats()
	setReplicaValue({ "roundId" }, roundId)
	setReplicaValue({ "selectedMapId" }, "")
	setReplicaValue({ "roundResults" }, {})
	setWinner("")
	syncAliveCounts()
	syncCoreState()
end

local function waitForSecondsOrInvalid(seconds: number, requireMinPlayers: boolean): boolean
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		if pendingAdminReset or pendingAdminForceStartMapId or pendingAdminWinnerTeam then
			return false
		end
		if requireMinPlayers and #Players:GetPlayers() < getRequiredPlayerCount() then
			return false
		end
		task.wait(0.2)
	end
	return true
end

local function endRound(winnerTeam: string)
	local resetStartedAt = os.clock()
	setWinner(winnerTeam)
	publishRoundResults(winnerTeam)
	setState(RoundStates.RoundEnding, if winnerTeam == "Draw" then "Draw" else winnerTeam .. " wins", RoundConfig.ResetSeconds)
	playRoundEndPOTG()
	local remainingResetSeconds = math.max(RoundConfig.ResetSeconds - (os.clock() - resetStartedAt), 0)
	task.wait(remainingResetSeconds)
end

local function runActiveRound()
	setState(RoundStates.Active, "Battle", RoundConfig.RoundSeconds)
	local deadline = os.clock() + RoundConfig.RoundSeconds

	while os.clock() < deadline do
		if pendingAdminReset or pendingAdminForceStartMapId then
			return
		end

		if pendingAdminWinnerTeam then
			local winnerTeam = pendingAdminWinnerTeam
			pendingAdminWinnerTeam = nil
			endRound(winnerTeam)
			return
		end

		local aliveCounts = countAlivePlayers()
		local winner = getWinnerFromAliveCounts(aliveCounts)
		if winner then
			if isSoloStudioRoundHeldActive(aliveCounts) then
				task.wait(0.2)
				continue
			end
			endRound(winner)
			return
		end
		task.wait(0.2)
	end

	endRound(getTimeoutWinner())
end

local function resetRound()
	setState(RoundStates.Resetting, "Resetting", 0)
	pendingAdminReset = false
	pendingAdminWinnerTeam = nil
	resetPlayersToLobby()
	DestructionService:Cleanup()
	clearActiveMap()
	clearAllRoundTracking()
	resetScoreboardStats()
	setReplicaValue({ "selectedMapId" }, "")
	setReplicaValue({ "roundResults" }, {})
	setVotingOpen(false)
	syncVoteChoices()
	syncAliveCounts()
	syncCoreState()
end

local function cancelToWaiting(reason: string)
	warn("[RoundService] " .. reason)
	resetRound()
	setState(RoundStates.WaitingForPlayers, "Waiting for players", 0)
end

local function runRoundLoop()
	while running do
		if pendingAdminReset and not pendingAdminForceStartMapId then
			resetRound()
			setState(RoundStates.WaitingForPlayers, "Waiting for players", 0)
			task.wait(0.2)
			continue
		end

		local forcedMapId = pendingAdminForceStartMapId
		local requiredPlayerCount = getRequiredPlayerCount()
		if not forcedMapId and #Players:GetPlayers() < requiredPlayerCount then
			setState(RoundStates.WaitingForPlayers, "Waiting for players", 0)
			setVotingOpen(false)
			task.wait(1)
			continue
		end
		if forcedMapId and #Players:GetPlayers() == 0 then
			setState(RoundStates.WaitingForPlayers, "Waiting for admin tester", 0)
			setVotingOpen(false)
			task.wait(1)
			continue
		end

		if not ensureTeamsReady() then
			setState(RoundStates.WaitingForPlayers, "Waiting for setup", 0)
			task.wait(3)
			continue
		end

		if forcedMapId then
			local forcedMap = getConfiguredMap(forcedMapId)
			currentChoices = if forcedMap then { forcedMap } else {}
		else
			currentChoices = chooseVoteOptions()
		end
		if #currentChoices == 0 then
			if forcedMapId then
				pendingAdminForceStartMapId = nil
			end
			setState(RoundStates.WaitingForPlayers, "Waiting for maps", 0)
			task.wait(3)
			continue
		end

		createNewRound()
		playerVotes = {}
		voteCounts = {}
		syncVoteChoices()
		setVotingOpen(not forcedMapId)

		local selectedMapId: string?
		if forcedMapId then
			selectedMapId = forcedMapId
			pendingAdminForceStartMapId = nil
			pendingAdminReset = false
			setState(RoundStates.Intermission, "Admin start", 0)
		else
			setState(RoundStates.Intermission, "Intermission", RoundConfig.IntermissionSeconds)
		end

		if not forcedMapId and not waitForSecondsOrInvalid(RoundConfig.IntermissionSeconds, true) then
			cancelToWaiting("Round cancelled because not enough players remain")
			continue
		end

		setVotingOpen(false)
		selectedMapId = selectedMapId or chooseWinningMap()
		if not selectedMapId or not getConfiguredMap(selectedMapId) then
			cancelToWaiting("Round cancelled because no voted map could be selected")
			continue
		end

		setReplicaValue({ "selectedMapId" }, selectedMapId)
		setState(RoundStates.AssigningTeams, "Assigning teams", 0)

		local roster = getEligiblePlayers()
		local minimumRosterCount = if forcedMapId then 1 else getRequiredPlayerCount()
		if #roster < minimumRosterCount then
			cancelToWaiting("Round cancelled because roster is below minimum")
			continue
		end

		roundPlayers = {}
		alivePlayers = {}
		playerTeams = {}
		assignTeams(roster)

		setState(RoundStates.RoundStarting, "Round starting", 0)
		local map = spawnActiveMap(selectedMapId)
		if not map or not setupTeamCores(map) or not teleportTeamsToMap(map) then
			cancelToWaiting("Round cancelled because map setup is incomplete")
			continue
		end
		setReplayRoundMap(selectedMapId, map)

		runActiveRound()
		resetRound()
	end
end

local function onSubmitMapVote(player: Player, mapId: any)
	if currentState ~= RoundStates.Intermission then
		return
	end
	if not votingOpen then
		return
	end
	if typeof(mapId) ~= "string" then
		return
	end
	if playerVotes[player] ~= nil then
		return
	end
	if not isCurrentChoice(mapId) then
		return
	end

	playerVotes[player] = mapId
	voteCounts[mapId] = (voteCounts[mapId] or 0) + 1
	syncVoteChoices()
end

local function onReportPreferredInput(player: Player, preferredInput: any)
	RoundService:ReportPreferredInput(player, preferredInput)
end

function RoundService:RecordPlayerDamage(attacker: Player, target: Player, damage: number, sourceContext)
	if currentState ~= RoundStates.Active then
		return
	end
	if not (attacker and attacker.Parent == Players and target and target.Parent == Players) then
		return
	end
	if attacker == target or typeof(damage) ~= "number" or damage ~= damage or damage <= 0 then
		return
	end

	local attackerStats = getScoreboardStatsFor(attacker)
	attackerStats.damage += damage

	local targetKey = getPlayerKey(target)
	local attackerKey = getPlayerKey(attacker)
	local contributors = recentDamageContributors[targetKey]
	if not contributors then
		contributors = {}
		recentDamageContributors[targetKey] = contributors
	end

	contributors[attackerKey] = {
		damagedAt = workspace:GetServerTimeNow(),
		teamName = getTrackedTeamName(attacker),
		sourceType = if typeof(sourceContext) == "table" and typeof(sourceContext.sourceType) == "string"
			then sourceContext.sourceType
			else nil,
		sourceId = if typeof(sourceContext) == "table" and typeof(sourceContext.sourceId) == "string"
			then sourceContext.sourceId
			else nil,
	}

	syncScoreboardStats()
end

function RoundService:RecordMapDestruction(sourceContext, targetsHit: number)
	if currentState ~= RoundStates.Active then
		return
	end
	if typeof(sourceContext) ~= "table" or typeof(sourceContext.ownerUserId) ~= "number" then
		return
	end
	if typeof(targetsHit) ~= "number" or targetsHit <= 0 then
		return
	end

	local player = Players:GetPlayerByUserId(sourceContext.ownerUserId)
	if not (player and player.Parent == Players and roundPlayers[player]) then
		return
	end

	local stats = getScoreboardStatsFor(player)
	stats.destruction += roundNonNegative(targetsHit)
	syncScoreboardStats()
end

function RoundService:ReportPreferredInput(player: Player, preferredInput: any)
	if not (player and player.Parent == Players) then
		return
	end
	if typeof(preferredInput) ~= "string" or not VALID_PREFERRED_INPUT[preferredInput] then
		return
	end

	local playerKey = getPlayerKey(player)
	if scoreboardPlatforms[playerKey] == preferredInput then
		return
	end

	scoreboardPlatforms[playerKey] = preferredInput
	syncScoreboardPlatforms()
end

function RoundService:OnStart()
	Players.CharacterAutoLoads = false
	DestructionService:SetScoreRecorder(function(sourceContext, targetsHit)
		RoundService:RecordMapDestruction(sourceContext, targetsHit)
	end)
	createGameReplica()
	submitMapVoteRemote = ensureVoteRemote()
	submitMapVoteRemote.OnServerEvent:Connect(onSubmitMapVote)
	reportPreferredInputRemote = ensureReportPreferredInputRemote()
	reportPreferredInputRemote.OnServerEvent:Connect(onReportPreferredInput)
	killFeedRemote = ensureKillFeedRemote()

	for _, player in ipairs(Players:GetPlayers()) do
		bindLobbyCharacter(player)
		if not player.Character then
			player:LoadCharacter()
		end
		task.defer(function()
			if player.Parent == Players then
				movePlayerToLobby(player)
			end
		end)
	end

	if not running then
		running = true
		task.spawn(runRoundLoop)
	end
end

function RoundService:OnPlayerAdded(player: Player)
	clearPlayerRoundState(player)
	bindLobbyCharacter(player)
	task.defer(function()
		if player.Parent ~= Players then
			return
		end
		if not player.Character then
			player:LoadCharacter()
		end
		movePlayerToLobby(player)
	end)
end

function RoundService:OnPlayerRemoving(player: Player)
	respawnTokens[player] = nil
	playerVotes[player] = nil
	removePlayerScoreboardState(player)
	disconnectCharacterConnections(player)
	disconnectLobbyCharacterConnection(player)

	if currentState == RoundStates.Active and alivePlayers[player] then
		alivePlayers[player] = nil
		syncAliveCounts()
	end

	roundPlayers[player] = nil
	alivePlayers[player] = nil
	playerTeams[player] = nil
end

function RoundService:GetState()
	if not gameReplica then
		return buildInitialState()
	end
	return deepCopy(gameReplica.Data)
end

function RoundService:IsPlayerActive(player: Player): boolean
	return currentState == RoundStates.Active and alivePlayers[player] == true
end

function RoundService:GetCoreCounts()
	return countAliveCores()
end

function RoundService:MarkCoreDestroyed(core: Instance): boolean
	local trackedCore = self:GetTrackedCore(core)
	if not trackedCore then
		return false
	end

	trackedCore:SetAttribute(CORE_HEALTH_ATTR, 0)
	trackedCore:SetAttribute(CORE_DESTROYED_ATTR, true)
	syncCoreState()
	return true
end

function RoundService:DamageCore(core: Instance, damage: number, sourceContext): boolean
	if currentState ~= RoundStates.Active then
		return false
	end
	if typeof(damage) ~= "number" or damage <= 0 then
		return false
	end

	local trackedCore = self:GetTrackedCore(core)
	if not trackedCore or not isCoreAlive(trackedCore) then
		return false
	end

	local teamName = trackedCore:GetAttribute("Team")
	local payload = {
		teamName = if typeof(teamName) == "string" then teamName else nil,
		baseId = trackedCore.Name,
		amount = damage,
		attackerUserId = if typeof(sourceContext) == "table" then sourceContext.attackerUserId else nil,
		sourceType = if typeof(sourceContext) == "table" then sourceContext.sourceType else nil,
		sourceId = if typeof(sourceContext) == "table" then sourceContext.sourceId else nil,
	}

	local humanoid = trackedCore:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:TakeDamage(damage)
		recordReplayEvent("BaseDamaged", payload)
		syncCoreState()
		return true
	end

	local health = trackedCore:GetAttribute(CORE_HEALTH_ATTR)
	if typeof(health) ~= "number" then
		health = RoundConfig.Cores.DefaultHealth
	end

	payload.amount = math.min(damage, math.max(health, 0))
	health -= damage
	trackedCore:SetAttribute(CORE_HEALTH_ATTR, math.max(health, 0))
	if health <= 0 then
		trackedCore:SetAttribute(CORE_DESTROYED_ATTR, true)
	end

	recordReplayEvent("BaseDamaged", payload)
	syncCoreState()
	return true
end

function RoundService:GetTrackedCore(instance: Instance): Instance?
	local current: Instance? = instance
	while current do
		if CollectionService:HasTag(current, RoundConfig.Tags.TeamCore) then
			for _, cores in pairs(teamCoreInstances) do
				if table.find(cores, current) then
					return current
				end
			end
		end

		current = current.Parent
	end

	return nil
end

function RoundService:AdminForceStart(mapId: string?): (boolean, string?)
	local selectedMapId = mapId
	if typeof(selectedMapId) ~= "string" or selectedMapId == "" then
		selectedMapId = getFirstConfiguredMapId()
	end
	if not selectedMapId then
		return false, "No configured map is available"
	end
	if not getConfiguredMap(selectedMapId) then
		return false, "Unknown map: " .. selectedMapId
	end
	if not getMapTemplate(selectedMapId) then
		return false, "Map template is missing: " .. selectedMapId
	end

	pendingAdminForceStartMapId = selectedMapId
	pendingAdminReset = currentState ~= RoundStates.WaitingForPlayers
	pendingAdminWinnerTeam = nil
	return true, "Queued admin round start for " .. selectedMapId
end

function RoundService:AdminResetRound(): (boolean, string?)
	pendingAdminReset = true
	pendingAdminWinnerTeam = nil
	return true, "Queued round reset"
end

function RoundService:AdminEndRound(winnerTeam: string): (boolean, string?)
	if currentState ~= RoundStates.Active then
		return false, "A round must be active to force a winner"
	end
	if winnerTeam ~= RoundConfig.Teams.Red.name and winnerTeam ~= RoundConfig.Teams.Blue.name and winnerTeam ~= "Draw" then
		return false, "Invalid winner"
	end

	pendingAdminWinnerTeam = winnerTeam
	return true, "Queued " .. winnerTeam .. " win"
end

function RoundService:AdminDamageTeamCore(teamName: string, damage: number): (boolean, string?)
	if typeof(teamName) ~= "string" or not teamCoreInstances[teamName] then
		return false, "Unknown team"
	end
	if typeof(damage) ~= "number" or damage <= 0 then
		return false, "Damage must be positive"
	end

	for _, core in ipairs(teamCoreInstances[teamName]) do
		if isCoreAlive(core) then
			if self:DamageCore(core, damage) then
				return true, "Damaged " .. teamName .. " core"
			end
		end
	end

	return false, "No live " .. teamName .. " core is available"
end

function RoundService:AdminDestroyTeamCore(teamName: string): (boolean, string?)
	if typeof(teamName) ~= "string" or not teamCoreInstances[teamName] then
		return false, "Unknown team"
	end

	for _, core in ipairs(teamCoreInstances[teamName]) do
		if isCoreAlive(core) then
			if self:MarkCoreDestroyed(core) then
				return true, "Destroyed " .. teamName .. " core"
			end
		end
	end

	return false, "No live " .. teamName .. " core is available"
end

function RoundService:AdminTestKillFeed(): (boolean, string?)
	local remote = killFeedRemote
	if not remote then
		remote = ensureKillFeedRemote()
		killFeedRemote = remote
	end

	remote:FireAllClients({
		roundId = roundId,
		killerUserId = 0,
		killerName = "BlueTester",
		killerDisplayName = "Blue Tester",
		killerTeam = RoundConfig.Teams.Blue.name,
		victimUserId = 0,
		victimName = "RedTester",
		victimDisplayName = "Red Tester",
		victimTeam = RoundConfig.Teams.Red.name,
	})

	task.delay(0.15, function()
		if remote.Parent then
			remote:FireAllClients({
				roundId = roundId,
				killerUserId = 0,
				killerName = "RedTester",
				killerDisplayName = "Red Tester",
				killerTeam = RoundConfig.Teams.Red.name,
				victimUserId = 0,
				victimName = "BlueTester",
				victimDisplayName = "Blue Tester",
				victimTeam = RoundConfig.Teams.Blue.name,
			})
		end
	end)

	return true, "Sent kill feed test"
end

function RoundService:AdminRespawnPlayer(player: Player): (boolean, string?)
	if not player or player.Parent ~= Players then
		return false, "Target player is not in this server"
	end

	cancelScheduledRespawn(player)
	if currentState ~= RoundStates.Active or not roundPlayers[player] then
		player:LoadCharacter()
		task.defer(function()
			if player.Parent == Players then
				movePlayerToLobby(player)
			end
		end)
		return true, "Respawned " .. player.Name .. " in lobby"
	end

	alivePlayers[player] = true
	clearRecentDamageFor(player)
	player:SetAttribute(ROUND_ALIVE_ATTR, true)
	player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, 0)
	bindCharacter(player)
	syncAliveCounts()
	task.defer(function()
		if player.Parent == Players then
			player:LoadCharacter()
		end
	end)
	return true, "Respawned " .. player.Name .. " in round"
end

function RoundService:AdminRespawnAll(): (boolean, string?)
	for _, player in ipairs(Players:GetPlayers()) do
		self:AdminRespawnPlayer(player)
	end

	return true, "Respawned all players"
end

function RoundService:AdminTeleportPlayer(player: Player, destination: string, sourcePlayer: Player?): (boolean, string?)
	if not player or player.Parent ~= Players then
		return false, "Target player is not in this server"
	end
	if not player.Character then
		player:LoadCharacter()
	end

	if destination == "Lobby" then
		movePlayerToLobby(player)
		return true, "Teleported " .. player.Name .. " to lobby"
	end

	if destination == "Admin" then
		local sourceCharacter = sourcePlayer and sourcePlayer.Character
		local sourceRoot = sourceCharacter and sourceCharacter:FindFirstChild("HumanoidRootPart")
		if sourceRoot and sourceRoot:IsA("BasePart") and player.Character then
			player.Character:PivotTo(sourceRoot.CFrame + sourceRoot.CFrame.LookVector * 4)
			return true, "Teleported " .. player.Name .. " to admin"
		end
		return false, "Admin character is not available"
	end

	if destination == "MapSpawn" then
		local activeMap = getActiveMap()
		if not activeMap then
			return false, "No active map is available"
		end

		local teamName = playerTeams[player]
		local spawns = if teamName then getTeamSpawns(teamName, activeMap) else getTaggedSpawnParts(RoundConfig.Tags.TeamSpawn, activeMap)
		if #spawns == 0 then
			return false, "No map spawn is available"
		end
		moveCharacterToSpawn(player, spawns[rng:NextInteger(1, #spawns)])
		return true, "Teleported " .. player.Name .. " to map"
	end

	return false, "Unknown teleport destination"
end

return RoundService
