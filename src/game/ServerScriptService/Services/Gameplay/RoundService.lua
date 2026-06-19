local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Teams = game:GetService("Teams")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local DestructionService = require(ServerScriptService.Services.DestructionService)
local DataService = require(ServerScriptService.Services.DataService)
local QuestService = require(ServerScriptService.Services.QuestService)
local StudioAICombatants = require(ServerScriptService.Services.StudioAICombatants)
local ReplicaService = require(ServerScriptService.Packages.ReplicaService)

local TEAM_ORDER = { RoundConfig.Teams.Red.name, RoundConfig.Teams.Blue.name }
local REMOTES_FOLDER_NAME = "Remotes"
local SUBMIT_MAP_VOTE_REMOTE_NAME = "SubmitMapVote"
local SET_AFK_REMOTE_NAME = "SetAFK"
local REPORT_PREFERRED_INPUT_REMOTE_NAME = "ReportPreferredInput"
local KILL_FEED_REMOTE_NAME = "KillFeed"
local DESTRUCTION_SCORE_REMOTE_NAME = "DestructionScore"
local ROUND_ID_ATTR = "RoundId"
local ROUND_TEAM_ATTR = "RoundTeam"
local ROUND_ALIVE_ATTR = "RoundAlive"
local ROUND_RESPAWN_ENDS_AT_ATTR = "RoundRespawnEndsAt"
local AFK_ATTR = "AFK"
local AFK_SOURCE_ATTR = "AFKSource"
local AFK_STARTED_AT_ATTR = "AFKStartedAt"
local AFK_MARKER_NAME = "AFK"
local CORE_HEALTH_ATTR = RoundConfig.Cores.HealthAttribute
local CORE_DESTROYED_ATTR = RoundConfig.Cores.DestroyedAttribute
local ASSIST_WINDOW_SECONDS = 10
local DEATH_BODY_RETAIN_SECONDS = 1.8
local RESPAWN_LOAD_VERIFY_DELAY_SECONDS = 0.65
local RESPAWN_LOAD_MAX_ATTEMPTS = 3
local ROUND_CHARACTER_READY_TIMEOUT_SECONDS = 5
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
	thumbnailImage: string?,
}

type VoteChoice = {
	choiceId: string,
	mapId: string,
	displayName: string,
	thumbnailImage: string?,
}

local getConfiguredMap: (string) -> MapConfig?
local getTrackedTeamName: (Player) -> string?

local RoundService = {}

local gameReplica = nil
local submitMapVoteRemote: RemoteEvent? = nil
local setAFKRemote: RemoteEvent? = nil
local reportPreferredInputRemote: RemoteEvent? = nil
local killFeedRemote: RemoteEvent? = nil
local destructionScoreRemote: RemoteEvent? = nil
local running = false
local roundId = 0
local activeRoundStartedAt = 0
local currentState = RoundStates.WaitingForPlayers
local votingOpen = false
local pendingAdminForceStartMapId: string? = nil
local pendingAdminReset = false
local pendingAdminWinnerTeam: string? = nil
local currentChoices: { VoteChoice } = {}
local voteCounts: { [string]: number } = {}
local playerVotes: { [Player]: string } = {}
local roundPlayers: { [Player]: boolean } = {}
local alivePlayers: { [Player]: boolean } = {}
local playerTeams: { [Player]: string } = {}
local characterConnections: { [Player]: { RBXScriptConnection } } = {}
local lobbyCharacterConnections: { [Player]: { RBXScriptConnection } } = {}
local respawnTokens: { [Player]: number } = {}
local characterDestroyTokens: { [Player]: number } = {}
local pendingRoundRespawnTokens: { [Player]: number } = {}
local teamCoreInstances: { [string]: { Instance } } = {}
local coreConnections: { [Instance]: { RBXScriptConnection } } = {}
local scoreboardStats: { [string]: { damage: number, eliminations: number, assists: number, deaths: number, destruction: number } } =
	{}
local scoreboardPlatforms: { [string]: string } = {}
local rewardedRoundIds: { [number]: boolean } = {}
local recentDamageContributors: { [string]: { [string]: { damagedAt: number, teamName: string?, sourceType: string?, sourceId: string? } } } =
	{}
local rng = Random.new()
local RespawnFlow = {}
local RoundFlow = {}
local missingAFKTemplateWarned = false
RespawnFlow.VoidFallPadding = 70
RespawnFlow.RagdollVelocityScale = 0.25
RespawnFlow.RagdollAngularVelocityScale = 0.2
RespawnFlow.RagdollFolderName = "_DeathRagdollConstraints"
RespawnFlow.RagdolledAttribute = "DeathRagdolled"
RespawnFlow.LobbyDeathBoundAttribute = "LobbyDeathBound"
RespawnFlow.RoundDeathBoundAttribute = "RoundDeathBound"

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
		voteVoters = {},
		scoreboardStats = {},
		scoreboardPlatforms = {},
		roundResults = {},
	}
end

local gameStateData = buildInitialState()

local function writeStateValue(path: { any }, value: any)
	local cursor = gameStateData
	for index = 1, #path - 1 do
		local key = path[index]
		local nextValue = cursor[key]
		if typeof(nextValue) ~= "table" then
			nextValue = {}
			cursor[key] = nextValue
		end
		cursor = nextValue
	end

	cursor[path[#path]] = deepCopy(value)
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, REMOTES_FOLDER_NAME)
end

local function ensureRoundRemote(name: string): RemoteEvent
	return RemoteUtil.EnsureRemoteEvent(ensureRemotesFolder(), name)
end

local function ensureVoteRemote(): RemoteEvent
	return ensureRoundRemote(SUBMIT_MAP_VOTE_REMOTE_NAME)
end

local function ensureSetAFKRemote(): RemoteEvent
	return ensureRoundRemote(SET_AFK_REMOTE_NAME)
end

local function ensureReportPreferredInputRemote(): RemoteEvent
	return ensureRoundRemote(REPORT_PREFERRED_INPUT_REMOTE_NAME)
end

local function ensureKillFeedRemote(): RemoteEvent
	return ensureRoundRemote(KILL_FEED_REMOTE_NAME)
end

local function ensureDestructionScoreRemote(): RemoteEvent
	return ensureRoundRemote(DESTRUCTION_SCORE_REMOTE_NAME)
end

local function setReplicaValue(path: { any }, value: any)
	writeStateValue(path, value)
	if gameReplica then
		gameReplica:SetValue(path, value)
	end
end

local function setReplicaValues(path: { any }, values: { [any]: any })
	for key, value in pairs(values) do
		local valuePath = table.clone(path)
		table.insert(valuePath, key)
		writeStateValue(valuePath, value)
	end

	if not gameReplica then
		return
	end
	if type(gameReplica.SetValues) == "function" then
		gameReplica:SetValues(path, values)
		return
	end

	for key, value in pairs(values) do
		local valuePath = table.clone(path)
		table.insert(valuePath, key)
		gameReplica:SetValue(valuePath, value)
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

function RoundFlow.getConfiguredDuration(value: any, fallback: number): number
	if typeof(value) == "number" and value == value then
		return math.max(value, 0)
	end
	return fallback
end

function RoundFlow.getPlayOfTheGameDuration(): number
	return RoundFlow.getConfiguredDuration(RoundConfig.PlayOfTheGameSeconds, 10)
end

function RoundFlow.playRoundEndPOTG(maxWaitSeconds: number): boolean
	local service = getReplayService()
	if not (service and type(service.PlayPOTG) == "function") then
		return false
	end

	local sent = false
	local ok, err = pcall(function()
		sent = service.PlayPOTG(getRoundReplayRecipients(), {
			maxWaitSeconds = maxWaitSeconds,
		})
	end)
	if DEBUG_REPLAY_EVENTS and not ok then
		warn("[RoundService] POTG playback failed:", err)
	end

	return ok and sent == true
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
	local selectedMapId = if typeof(gameStateData.selectedMapId) == "string"
		then gameStateData.selectedMapId
		else ""
	local results = {
		roundId = roundId,
		winnerTeam = winnerTeam,
		selectedMapId = selectedMapId,
		mapDisplayName = getMapDisplayName(selectedMapId),
		durationSeconds = roundNonNegative(os.clock() - activeRoundStartedAt),
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
	DataService:ReportLeaderboardRoundResults(results)
	QuestService:ReportRoundResults(results)
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
	local botKiller = if not killer then StudioAICombatants.GetOwnerIdentity({ studioAIBot = true, UserId = tonumber(eliminatorKey) }) else nil
	if not killer and not botKiller then
		return
	end

	local killerTeam = if killer then getTrackedTeamName(killer) else botKiller.teamName
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
		killerUserId = if killer then killer.UserId else botKiller.userId,
		killerName = if killer then killer.Name else botKiller.name,
		killerDisplayName = if killer then killer.DisplayName else botKiller.displayName,
		killerTeam = killerTeam,
		killerIsNPC = killer == nil,
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
			eliminatorPlayer = getPlayerByKey(eliminatorKey)
			if eliminatorPlayer then
				getScoreboardStatsFor(eliminatorKey).eliminations += 1
			end
			fireKillFeedElimination(eliminatorKey, victim)
		end

		for attackerKey, contributor in pairs(contributors) do
			if
				attackerKey ~= eliminatorKey
				and getPlayerByKey(attackerKey)
				and isRecentEnemyContributor(attackerKey, contributor, victim, currentTime)
			then
				getScoreboardStatsFor(attackerKey).assists += 1
			end
		end
	end

	local botEliminator = if not eliminatorPlayer and eliminatorKey
		then StudioAICombatants.GetOwnerIdentity({ studioAIBot = true, UserId = tonumber(eliminatorKey) })
		else nil
	local playerKilledPayload = {
		timestamp = currentTime,
		roundId = roundId,
		victimUserId = victim.UserId,
		victimName = victim.Name,
		victimDisplayName = victim.DisplayName,
		victimTeam = getTrackedTeamName(victim),
		killerUserId = if eliminatorKey then tonumber(eliminatorKey) else nil,
		killerName = if eliminatorPlayer then eliminatorPlayer.Name elseif botEliminator then botEliminator.name else nil,
		killerDisplayName = if eliminatorPlayer then eliminatorPlayer.DisplayName elseif botEliminator then botEliminator.displayName else nil,
		killerTeam = if eliminatorPlayer then getTrackedTeamName(eliminatorPlayer) elseif botEliminator then botEliminator.teamName else nil,
		killerIsNPC = botEliminator ~= nil,
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
		killerUserId = playerKilledPayload.killerUserId,
		killerName = playerKilledPayload.killerName,
		killerDisplayName = playerKilledPayload.killerDisplayName,
		killerTeam = playerKilledPayload.killerTeam,
		killerIsNPC = playerKilledPayload.killerIsNPC,
		sourceType = playerKilledPayload.sourceType,
		sourceId = playerKilledPayload.sourceId,
	})

	clearRecentDamageFor(victim)
	syncScoreboardStats()
end

local function setState(state: string, status: string?, duration: number?)
	currentState = state
	if state == RoundStates.WaitingForPlayers then
		for _, player in ipairs(Players:GetPlayers()) do
			player:SetAttribute(ROUND_ID_ATTR, nil)
			player:SetAttribute(ROUND_TEAM_ATTR, nil)
			player:SetAttribute(ROUND_ALIVE_ATTR, nil)
			player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, nil)
			player.Neutral = true
			player.Team = nil
		end
		task.defer(function()
			if currentState == RoundStates.WaitingForPlayers and type(RespawnFlow.clearWaitingStateResidue) == "function" then
				RespawnFlow.clearWaitingStateResidue()
			end
		end)
	end
	setReplicaValues({}, {
		state = state,
		status = status or state,
		endsAt = if duration and duration > 0 then workspace:GetServerTimeNow() + duration else 0,
		minPlayers = getRequiredPlayerCount(),
	})
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
		DestructionService:InvalidateTargetCache("MapCleared")
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
	DestructionService:RebuildTargetCache("MapSpawned")
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

local function isPlayerAFK(player: Player): boolean
	return player:GetAttribute(AFK_ATTR) == true
end

local function getAFKTemplate(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local ui = assets and assets:FindFirstChild("UI")
	local template = ui and ui:FindFirstChild(AFK_MARKER_NAME)
	if template then
		return template
	end

	if not missingAFKTemplateWarned then
		missingAFKTemplateWarned = true
		warn("[RoundService] Missing ReplicatedStorage.Assets.UI.AFK template")
	end
	return nil
end

local function removeAFKMarker(player: Player)
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	for _, child in ipairs(rootPart:GetChildren()) do
		if child.Name == AFK_MARKER_NAME then
			child:Destroy()
		end
	end
end

local function syncPlayerAFKMarker(player: Player)
	removeAFKMarker(player)

	if not isPlayerAFK(player) then
		return
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local template = getAFKTemplate()
	if not template then
		return
	end

	local marker = template:Clone()
	marker.Name = AFK_MARKER_NAME
	local billboardGui = marker:FindFirstChild("BillboardGui")
	local frame = billboardGui and billboardGui:FindFirstChild("Frame")
	local timerLabel = frame and frame:FindFirstChild("Timer")
	if timerLabel and timerLabel:IsA("TextLabel") then
		timerLabel.Text = "0:00"
	end
	marker.Parent = rootPart
end

local function bumpRespawnToken(player: Player): number
	local token = (respawnTokens[player] or 0) + 1
	respawnTokens[player] = token
	return token
end

local function cancelScheduledRespawn(player: Player)
	bumpRespawnToken(player)
	pendingRoundRespawnTokens[player] = nil
end

local function bumpCharacterDestroyToken(player: Player): number
	local token = (characterDestroyTokens[player] or 0) + 1
	characterDestroyTokens[player] = token
	return token
end

local function cancelScheduledCharacterDestroy(player: Player)
	bumpCharacterDestroyToken(player)
end

local function destroyPlayerCharacter(player: Player)
	cancelScheduledCharacterDestroy(player)
	local character = player.Character
	if character then
		character:Destroy()
	end
end

local function destroyPlayerCharacterAfter(player: Player, delaySeconds: number)
	local character = player.Character
	if not character then
		return
	end

	local token = bumpCharacterDestroyToken(player)
	task.delay(math.max(delaySeconds, 0), function()
		if characterDestroyTokens[player] ~= token then
			return
		end
		if player.Parent ~= Players then
			return
		end
		if player.Character ~= character then
			return
		end

		character:Destroy()
	end)
end

local function clearPlayerRoundState(player: Player)
	cancelScheduledRespawn(player)
	cancelScheduledCharacterDestroy(player)
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

function RespawnFlow.clearWaitingStateResidue()
	if currentState ~= RoundStates.WaitingForPlayers then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		clearPlayerRoundState(player)
	end
	clearActiveMap()
	clearAllRoundTracking()
	setReplicaValue({ "aliveCounts" }, {
		[RoundConfig.Teams.Red.name] = 0,
		[RoundConfig.Teams.Blue.name] = 0,
	})
	setReplicaValue({ "coreCounts" }, {
		[RoundConfig.Teams.Red.name] = 0,
		[RoundConfig.Teams.Blue.name] = 0,
	})
	setReplicaValue({ "respawnsEnabled" }, {
		[RoundConfig.Teams.Red.name] = false,
		[RoundConfig.Teams.Blue.name] = false,
	})
	setReplicaValue({ "selectedMapId" }, "")
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

local reconcilePlayersWithoutRespawns: (() -> ())?
local eliminatePlayer: ((Player) -> ())?

local function syncCoreState()
	local coreCounts = countAliveCores()
	setReplicaValue({ "coreCounts" }, coreCounts)
	setReplicaValue({ "respawnsEnabled" }, buildRespawnState(coreCounts))
	if currentState == RoundStates.Active and reconcilePlayersWithoutRespawns then
		reconcilePlayersWithoutRespawns()
	end
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

local function hasUsableCharacter(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	return humanoid ~= nil and humanoid.Health > 0 and rootPart ~= nil and rootPart:IsA("BasePart")
end

function RespawnFlow.prepareDeathRagdoll(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid.BreakJointsOnDeath = false
	pcall(function()
		humanoid.RequiresNeck = false
	end)
end

function RespawnFlow.applyDeathRagdoll(character: Model, reason: string)
	if character:GetAttribute(RespawnFlow.RagdolledAttribute) == true then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	RespawnFlow.prepareDeathRagdoll(character)
	character:SetAttribute(RespawnFlow.RagdolledAttribute, true)

	local previousFolder = character:FindFirstChild(RespawnFlow.RagdollFolderName)
	if previousFolder then
		previousFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = RespawnFlow.RagdollFolderName
	folder.Parent = character

	local constraintCount = 0
	for _, descendant in ipairs(character:GetDescendants()) do
		if not descendant:IsA("Motor6D") then
			continue
		end

		local motor = descendant :: Motor6D
		local part0 = motor.Part0
		local part1 = motor.Part1
		if not (part0 and part1) then
			continue
		end

		local attachment0 = Instance.new("Attachment")
		attachment0.Name = motor.Name .. "_DeathRagdollA0"
		attachment0.CFrame = motor.C0
		attachment0.Parent = part0

		local attachment1 = Instance.new("Attachment")
		attachment1.Name = motor.Name .. "_DeathRagdollA1"
		attachment1.CFrame = motor.C1
		attachment1.Parent = part1

		local socket = Instance.new("BallSocketConstraint")
		socket.Name = motor.Name .. "_DeathRagdollSocket"
		socket.Attachment0 = attachment0
		socket.Attachment1 = attachment1
		socket.LimitsEnabled = true
		socket.TwistLimitsEnabled = true
		socket.UpperAngle = 70
		socket.TwistLowerAngle = -45
		socket.TwistUpperAngle = 45
		socket.Parent = folder

		motor.Enabled = false
		constraintCount += 1
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = descendant.Name ~= "HumanoidRootPart"
			descendant.AssemblyLinearVelocity *= RespawnFlow.RagdollVelocityScale
			descendant.AssemblyAngularVelocity *= RespawnFlow.RagdollAngularVelocityScale
		end
	end

	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end)
	RuntimeProfiler.Count("Server/Round/Death/RagdollConstraints", constraintCount)
	RuntimeProfiler.Count("Server/Round/Death/Ragdolled")
	debugDeathFlow("Applied death ragdoll", character.Name, reason, "constraints", constraintCount)
end

function RespawnFlow.getVoidKillY(): number?
	local activeMap = getActiveMap()
	if activeMap then
		local pivot, size = activeMap:GetBoundingBox()
		return pivot.Position.Y - (size.Y * 0.5) - RespawnFlow.VoidFallPadding
	end

	local fallenPartsDestroyHeight = workspace.FallenPartsDestroyHeight
	if typeof(fallenPartsDestroyHeight) == "number" then
		return fallenPartsDestroyHeight + RespawnFlow.VoidFallPadding
	end

	return nil
end

function RespawnFlow.killPlayerForVoidFall(player: Player, voidKillY: number): boolean
	if currentState ~= RoundStates.Active or alivePlayers[player] ~= true or player:GetAttribute(ROUND_ALIVE_ATTR) ~= true then
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not (character and humanoid and rootPart and rootPart:IsA("BasePart") and humanoid.Health > 0) then
		return false
	end
	if rootPart.Position.Y >= voidKillY then
		return false
	end

	debugDeathFlow("Void fall death", player.Name, "y", rootPart.Position.Y, "threshold", voidKillY)
	RuntimeProfiler.Count("Server/Round/Death/VoidFalls")
	character:SetAttribute("DeathReason", "VoidFall")
	RespawnFlow.applyDeathRagdoll(character, "VoidFall")
	humanoid.Health = 0
	return true
end

function RespawnFlow.checkVoidFalls()
	local voidKillY = RespawnFlow.getVoidKillY()
	if not voidKillY then
		return
	end

	for player in pairs(alivePlayers) do
		RespawnFlow.killPlayerForVoidFall(player, voidKillY)
	end
end

function RespawnFlow.waitForUsableCharacter(player: Player, timeoutSeconds: number): boolean
	local deadline = os.clock() + math.max(timeoutSeconds, 0)
	while os.clock() <= deadline do
		if player.Parent ~= Players then
			return false
		end
		if hasUsableCharacter(player) then
			return true
		end
		task.wait(0.05)
	end
	return false
end

function RespawnFlow.safeLoadCharacter(player: Player, context: string): boolean
	if player.Parent ~= Players then
		debugDeathFlow("LoadCharacter skipped; player left", player.Name, context)
		return false
	end

	local ok, err = pcall(function()
		player:LoadCharacter()
	end)
	if not ok then
		warn(("[RoundService] LoadCharacter failed for %s during %s: %s"):format(player.Name, context, tostring(err)))
		return false
	end

	return true
end

function RespawnFlow.moveRoundCharacterToTeamSpawn(player: Player): boolean
	local activeMap = getActiveMap()
	local teamName = playerTeams[player]
	if not (activeMap and teamName) then
		return false
	end

	local spawns = getTeamSpawns(teamName, activeMap)
	if #spawns == 0 then
		warn("[RoundService] Missing TeamSpawn parts for team:", teamName)
		return false
	end

	moveCharacterToSpawn(player, spawns[rng:NextInteger(1, #spawns)])
	return true
end

function RespawnFlow.finalizeRoundRespawnIfReady(player: Player, token: number, context: string): boolean
	if pendingRoundRespawnTokens[player] ~= token then
		return false
	end
	if respawnTokens[player] ~= token then
		debugDeathFlow("Round respawn finalize skipped; stale token", player.Name, token, respawnTokens[player])
		return false
	end
	if not hasUsableCharacter(player) then
		return false
	end
	if currentState ~= RoundStates.Active or not roundPlayers[player] or alivePlayers[player] ~= true then
		debugDeathFlow("Round respawn finalize skipped; state changed", player.Name, context)
		return false
	end
	if not teamHasRespawns(playerTeams[player]) then
		debugDeathFlow("Round respawn finalize skipped; team respawns unavailable", player.Name, tostring(playerTeams[player]))
		return false
	end
	if not RespawnFlow.moveRoundCharacterToTeamSpawn(player) then
		debugDeathFlow("Round respawn finalize skipped; missing spawn", player.Name, tostring(playerTeams[player]))
		return false
	end

	pendingRoundRespawnTokens[player] = nil
	player:SetAttribute(ROUND_ALIVE_ATTR, true)
	player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, 0)
	debugDeathFlow("Round respawn finalized", player.Name, context)
	return true
end

function RespawnFlow.shouldRetryRoundRespawn(player: Player, token: number): boolean
	if respawnTokens[player] ~= token then
		debugDeathFlow("Round respawn verify skipped; stale token", player.Name, token, respawnTokens[player])
		return false
	end
	if player.Parent ~= Players then
		debugDeathFlow("Round respawn verify skipped; player left", player.Name)
		return false
	end
	if currentState ~= RoundStates.Active or not roundPlayers[player] or alivePlayers[player] ~= true then
		debugDeathFlow(
			"Round respawn verify skipped; state changed",
			player.Name,
			"state",
			currentState,
			"roundPlayer",
			roundPlayers[player],
			"alive",
			alivePlayers[player]
		)
		return false
	end
	if not teamHasRespawns(playerTeams[player]) then
		debugDeathFlow("Round respawn verify skipped; team respawns unavailable", player.Name, "team", tostring(playerTeams[player]))
		return false
	end
	if pendingRoundRespawnTokens[player] ~= token and player:GetAttribute(ROUND_ALIVE_ATTR) ~= true then
		debugDeathFlow("Round respawn verify skipped; no pending respawn", player.Name, player:GetAttribute(ROUND_ALIVE_ATTR))
		return false
	end

	return true
end

function RespawnFlow.verifyRoundRespawn(player: Player, token: number, attempt: number)
	task.delay(RESPAWN_LOAD_VERIFY_DELAY_SECONDS, function()
		if not RespawnFlow.shouldRetryRoundRespawn(player, token) then
			return
		end
		if RespawnFlow.finalizeRoundRespawnIfReady(player, token, "VerifyAttempt" .. tostring(attempt)) then
			return
		end
		if hasUsableCharacter(player) then
			if pendingRoundRespawnTokens[player] ~= token then
				debugDeathFlow("Round respawn verified", player.Name, "attempt", attempt)
				return
			end
			debugDeathFlow("Round respawn has character but is still pending finalization", player.Name, "attempt", attempt)
		end
		if attempt >= RESPAWN_LOAD_MAX_ATTEMPTS then
			warn(("[RoundService] Round respawn did not produce a usable character for %s after %d attempts"):format(
				player.Name,
				attempt
			))
			if pendingRoundRespawnTokens[player] == token and alivePlayers[player] == true and eliminatePlayer then
				eliminatePlayer(player)
			end
			return
		end

		local nextAttempt = attempt + 1
		debugDeathFlow("Retrying round respawn LoadCharacter", player.Name, "attempt", nextAttempt)
		RespawnFlow.safeLoadCharacter(player, "RoundRespawnRetry" .. tostring(nextAttempt))
		RespawnFlow.verifyRoundRespawn(player, token, nextAttempt)
	end)
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
		if character:GetAttribute(RespawnFlow.LobbyDeathBoundAttribute) == true then
			return
		end
		character:SetAttribute(RespawnFlow.LobbyDeathBoundAttribute, true)
		RespawnFlow.prepareDeathRagdoll(character)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end

		track(humanoid.Died:Connect(function()
			RespawnFlow.applyDeathRagdoll(character, "NonRoundDeath")
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
			if roundPlayers[player] then
				return
			end

			clearPlayerRoundState(player)
			bindNonRoundHumanoid(character)
			movePlayerToLobby(player)
			syncPlayerAFKMarker(player)
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

local function hasBasePartDescendant(instance: Instance): boolean
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			return true
		end
	end
	return false
end

local function getSpawnAnchorTemplate(teamName: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local spawnAnchors = assets and assets:FindFirstChild("SpawnAnchors")
	local template = spawnAnchors and spawnAnchors:FindFirstChild(teamName)
	return if template and template:IsA("Model") then template else nil
end

local function copyCoreAttributes(source: Instance, target: Instance, teamName: string)
	for attributeName, value in pairs(source:GetAttributes()) do
		target:SetAttribute(attributeName, value)
	end

	target:SetAttribute("Team", teamName)
	if typeof(target:GetAttribute(CORE_HEALTH_ATTR)) ~= "number" then
		target:SetAttribute(CORE_HEALTH_ATTR, RoundConfig.Cores.DefaultHealth)
	end
	if typeof(target:GetAttribute(CORE_DESTROYED_ATTR)) ~= "boolean" then
		target:SetAttribute(CORE_DESTROYED_ATTR, false)
	end
end

local function anchorBaseParts(instance: Instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
end

local function repairEmptyCoreModel(core: Instance, teamName: string): Instance
	if hasBasePartDescendant(core) or not core:IsA("Model") then
		return core
	end

	local template = getSpawnAnchorTemplate(teamName)
	if not template then
		warn("[RoundService] TeamCore model has no BasePart descendants and no SpawnAnchors template exists:", teamName)
		return core
	end

	local parent = core.Parent
	if not parent then
		return core
	end

	local replacement = template:Clone()
	replacement.Name = core.Name
	copyCoreAttributes(core, replacement, teamName)
	anchorBaseParts(replacement)
	replacement.Parent = parent
	replacement:PivotTo(core:GetPivot())
	CollectionService:AddTag(replacement, RoundConfig.Tags.TeamCore)
	CollectionService:RemoveTag(core, RoundConfig.Tags.TeamCore)
	core:Destroy()

	warn("[RoundService] Repaired empty TeamCore model from SpawnAnchors template:", teamName)
	return replacement
end

local function setupTeamCores(map: Model): boolean
	disconnectCoreConnections()
	teamCoreInstances = {}

	for _, teamName in ipairs(TEAM_ORDER) do
		local cores = getTeamCores(teamName, map)
		local repairedCores = {}
		for _, core in ipairs(cores) do
			table.insert(repairedCores, repairEmptyCoreModel(core, teamName))
		end
		teamCoreInstances[teamName] = repairedCores

		if #repairedCores < RoundConfig.Cores.MinPerTeam then
			warn("[RoundService] Missing TeamCore tagged instances for team:", teamName)
			syncCoreState()
			return false
		end

		for _, core in ipairs(repairedCores) do
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

eliminatePlayer = function(player: Player)
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

reconcilePlayersWithoutRespawns = function()
	for player in pairs(roundPlayers) do
		if alivePlayers[player] == true and player:GetAttribute(ROUND_ALIVE_ATTR) == false and not teamHasRespawns(playerTeams[player]) then
			debugDeathFlow("Eliminating pending respawn after core loss", player.Name, "team", tostring(playerTeams[player]))
			eliminatePlayer(player)
		end
	end
end

local function respawnPlayerInRound(player: Player)
	debugDeathFlow("Scheduling round respawn", player.Name, "delay", RoundConfig.RespawnSeconds, "roundId", roundId)
	clearRecentDamageFor(player)
	player:SetAttribute(ROUND_ALIVE_ATTR, false)
	player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, workspace:GetServerTimeNow() + RoundConfig.RespawnSeconds)
	destroyPlayerCharacterAfter(player, DEATH_BODY_RETAIN_SECONDS)

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
		if not teamHasRespawns(playerTeams[player]) then
			debugDeathFlow("Round respawn skipped; team respawns unavailable", player.Name, "team", tostring(playerTeams[player]))
			eliminatePlayer(player)
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
		pendingRoundRespawnTokens[player] = token
		cancelScheduledCharacterDestroy(player)
		RespawnFlow.safeLoadCharacter(player, "RoundRespawn")
		RespawnFlow.verifyRoundRespawn(player, token, 1)
	end)
end

local function handlePlayerDeath(player: Player)
	local token = RuntimeProfiler.Begin("Server/Round/Death/HandlePlayerDeath")
	if not alivePlayers[player] then
		debugDeathFlow("handlePlayerDeath ignored; player not alive", player.Name)
		RuntimeProfiler.End("Server/Round/Death/HandlePlayerDeath", token)
		return
	end
	if player:GetAttribute(ROUND_ALIVE_ATTR) ~= true then
		debugDeathFlow("handlePlayerDeath ignored; player already pending death/respawn", player.Name)
		RuntimeProfiler.End("Server/Round/Death/HandlePlayerDeath", token)
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

	local scoreboardToken = RuntimeProfiler.Begin("Server/Round/Death/CreditScoreboard")
	creditScoreboardDeath(player)
	RuntimeProfiler.End("Server/Round/Death/CreditScoreboard", scoreboardToken)

	local outcomeToken = RuntimeProfiler.Begin("Server/Round/Death/RespawnOrEliminate")
	if teamHasRespawns(playerTeams[player]) then
		respawnPlayerInRound(player)
	else
		eliminatePlayer(player)
	end
	RuntimeProfiler.End("Server/Round/Death/RespawnOrEliminate", outcomeToken)
	RuntimeProfiler.Count("Server/Round/Death/Handled")
	RuntimeProfiler.End("Server/Round/Death/HandlePlayerDeath", token)
end

local function bindCharacter(player: Player)
	disconnectCharacterConnections(player)
	characterConnections[player] = {}

	local function bindHumanoid(character: Model)
		if character:GetAttribute(RespawnFlow.RoundDeathBoundAttribute) == true then
			return
		end
		character:SetAttribute(RespawnFlow.RoundDeathBoundAttribute, true)
		RespawnFlow.prepareDeathRagdoll(character)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end

		table.insert(characterConnections[player], humanoid.Died:Connect(function()
			local deathToken = RuntimeProfiler.Begin("Server/Round/Death/HumanoidDied")
			RuntimeProfiler.Count("Server/Round/Death/HumanoidDiedEvents")
			RespawnFlow.applyDeathRagdoll(character, "RoundDeath")
			if currentState == RoundStates.Active then
				debugDeathFlow("Humanoid.Died", player.Name, "roundId", roundId, "health", humanoid.Health)
				handlePlayerDeath(player)
			end
			RuntimeProfiler.End("Server/Round/Death/HumanoidDied", deathToken)
		end))
	end

	if player.Character then
		bindHumanoid(player.Character)
	end

	table.insert(characterConnections[player], player.CharacterAdded:Connect(function(character)
		task.defer(function()
			if roundPlayers[player] and not alivePlayers[player] then
				movePlayerToLobby(player)
				syncPlayerAFKMarker(player)
				return
			end

			if roundPlayers[player] and alivePlayers[player] then
				if not RespawnFlow.waitForUsableCharacter(player, ROUND_CHARACTER_READY_TIMEOUT_SECONDS) then
					warn("[RoundService] Active round character missing humanoid/root:", player.Name)
					return
				end
				if not roundPlayers[player] or not alivePlayers[player] then
					return
				end
				if player.Character ~= character then
					return
				end
				bindHumanoid(character)
				local pendingToken = pendingRoundRespawnTokens[player]
				if pendingToken then
					RespawnFlow.finalizeRoundRespawnIfReady(player, pendingToken, "CharacterAdded")
				else
					if currentState == RoundStates.Active then
						RespawnFlow.moveRoundCharacterToTeamSpawn(player)
					end
					player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, 0)
				end
				syncPlayerAFKMarker(player)
			else
				clearPlayerRoundState(player)
				movePlayerToLobby(player)
				syncPlayerAFKMarker(player)
			end
		end)
	end))
end

local function makeVoteChoice(mapConfig: MapConfig, occurrence: number): VoteChoice
	return {
		choiceId = if occurrence <= 1 then mapConfig.id else mapConfig.id .. ":" .. tostring(occurrence),
		mapId = mapConfig.id,
		displayName = mapConfig.displayName,
		thumbnailImage = mapConfig.thumbnailImage,
	}
end

local function chooseVoteOptions(): { VoteChoice }
	local available = {}
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		if getMapTemplate(mapConfig.id) then
			table.insert(available, mapConfig)
		end
	end

	local choices = {}
	local sourceMaps = table.clone(available)
	local occurrences = {}
	while #available > 0 and #choices < RoundConfig.VoteChoiceCount do
		local index = rng:NextInteger(1, #available)
		local mapConfig = table.remove(available, index)
		occurrences[mapConfig.id] = (occurrences[mapConfig.id] or 0) + 1
		table.insert(choices, makeVoteChoice(mapConfig, occurrences[mapConfig.id]))
	end

	while #sourceMaps > 0 and #choices < RoundConfig.VoteChoiceCount do
		local mapConfig = sourceMaps[rng:NextInteger(1, #sourceMaps)]
		occurrences[mapConfig.id] = (occurrences[mapConfig.id] or 0) + 1
		table.insert(choices, makeVoteChoice(mapConfig, occurrences[mapConfig.id]))
	end

	return choices
end

local function syncVoteChoices()
	local choices = {}
	local counts = {}
	local voters = {}

	for _, choice in ipairs(currentChoices) do
		table.insert(choices, {
			id = choice.choiceId,
			choiceId = choice.choiceId,
			mapId = choice.mapId,
			displayName = choice.displayName,
			thumbnailImage = choice.thumbnailImage,
		})
		counts[choice.choiceId] = voteCounts[choice.choiceId] or 0
		voters[choice.choiceId] = {}
	end

	for player, choiceId in pairs(playerVotes) do
		if voters[choiceId] and player.Parent == Players then
			table.insert(voters[choiceId], player.UserId)
		end
	end

	setReplicaValue({ "voteChoices" }, choices)
	setReplicaValue({ "voteCounts" }, counts)
	setReplicaValue({ "voteVoters" }, voters)
end

local function getCurrentChoice(choiceId: string): VoteChoice?
	for _, choice in ipairs(currentChoices) do
		if choice.choiceId == choiceId then
			return choice
		end
	end
	return nil
end

local function isCurrentChoice(choiceId: string): boolean
	return getCurrentChoice(choiceId) ~= nil
end

local function clearPlayerVote(player: Player): boolean
	local previousChoiceId = playerVotes[player]
	if not previousChoiceId then
		return false
	end

	playerVotes[player] = nil
	if voteCounts[previousChoiceId] then
		voteCounts[previousChoiceId] = math.max(voteCounts[previousChoiceId] - 1, 0)
	end
	return true
end

local function normalizeAFKSource(value: any): string
	return if value == "Auto" then "Auto" else "Manual"
end

local function fireAFKResult(player: Player, accepted: boolean, reason: string?)
	if setAFKRemote then
		setAFKRemote:FireClient(player, {
			accepted = accepted,
			afk = isPlayerAFK(player),
			source = player:GetAttribute(AFK_SOURCE_ATTR),
			reason = reason,
		})
	end
end

local function setPlayerAFK(player: Player, afk: boolean, source: string): boolean
	if player.Parent ~= Players then
		return false
	end

	if afk and currentState == RoundStates.Active and roundPlayers[player] then
		Notify.Send(player, "You can't go AFK during a round.", {
			color = "Orange",
			duration = 3,
		})
		fireAFKResult(player, false, "ActiveRound")
		return false
	end

	local wasAFK = isPlayerAFK(player)
	player:SetAttribute(AFK_ATTR, afk)
	player:SetAttribute(AFK_SOURCE_ATTR, if afk then normalizeAFKSource(source) else nil)
	player:SetAttribute(AFK_STARTED_AT_ATTR, if afk then workspace:GetServerTimeNow() else nil)

	if afk then
		local voteChanged = clearPlayerVote(player)
		if voteChanged then
			syncVoteChoices()
		end
	end

	if wasAFK ~= afk then
		syncPlayerAFKMarker(player)
	end

	fireAFKResult(player, true, nil)
	return true
end

local function buildForcedVoteChoice(mapConfig: MapConfig): VoteChoice
	return makeVoteChoice(mapConfig, 1)
end

local function chooseWinningMap(): string?
	local tied = {}
	local best = -math.huge

	for _, choice in ipairs(currentChoices) do
		local count = voteCounts[choice.choiceId] or 0
		if count > best then
			best = count
			tied = { choice.choiceId }
		elseif count == best then
			table.insert(tied, choice.choiceId)
		end
	end

	if #tied == 0 then
		return nil
	end

	local winningChoice = getCurrentChoice(tied[rng:NextInteger(1, #tied)])
	if winningChoice then
		return winningChoice.mapId
	end

	return nil
end

local function getEligiblePlayers(): { Player }
	local players = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Parent == Players and not isPlayerAFK(player) then
			table.insert(players, player)
		end
	end
	return players
end

local function getEligiblePlayerCount(): number
	return #getEligiblePlayers()
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
			if not hasUsableCharacter(player) then
				if
					not RespawnFlow.safeLoadCharacter(player, "RoundStart")
					or not RespawnFlow.waitForUsableCharacter(player, ROUND_CHARACTER_READY_TIMEOUT_SECONDS)
				then
					warn("[RoundService] Timed out waiting for round character:", player.Name)
					return false
				end
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
		Data = deepCopy(gameStateData),
		Replication = "All",
	})
end

function RoundFlow.createNewRound()
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

function RoundFlow.waitForSecondsOrInvalid(seconds: number, requireMinPlayers: boolean): boolean
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		if pendingAdminReset or pendingAdminForceStartMapId or pendingAdminWinnerTeam then
			return false
		end
		if requireMinPlayers and getEligiblePlayerCount() < getRequiredPlayerCount() then
			return false
		end
		task.wait(0.2)
	end
	return true
end

function RoundFlow.endRound(winnerTeam: string)
	setWinner(winnerTeam)
	local potgDuration = RoundFlow.getPlayOfTheGameDuration()
	if potgDuration > 0 then
		setState(RoundStates.PlayOfTheGame, "Play of the Game", potgDuration)
		local sentPOTG = RoundFlow.playRoundEndPOTG(potgDuration)
		if sentPOTG then
			setState(RoundStates.PlayOfTheGame, "Play of the Game", potgDuration)
			task.wait(potgDuration)
		end
	end

	local resetStartedAt = os.clock()
	publishRoundResults(winnerTeam)
	setState(RoundStates.RoundEnding, if winnerTeam == "Draw" then "Draw" else winnerTeam .. " wins", RoundConfig.ResetSeconds)
	local remainingResetSeconds = math.max(RoundConfig.ResetSeconds - (os.clock() - resetStartedAt), 0)
	task.wait(remainingResetSeconds)
end

function RoundFlow.runActiveRound()
	setState(RoundStates.Active, "Battle", RoundConfig.RoundSeconds)
	activeRoundStartedAt = os.clock()
	local deadline = os.clock() + RoundConfig.RoundSeconds

	while os.clock() < deadline do
		if pendingAdminReset or pendingAdminForceStartMapId then
			return
		end

		RespawnFlow.checkVoidFalls()

		if pendingAdminWinnerTeam then
			local winnerTeam = pendingAdminWinnerTeam
			pendingAdminWinnerTeam = nil
			RoundFlow.endRound(winnerTeam)
			return
		end

		local aliveCounts = countAlivePlayers()
		local winner = getWinnerFromAliveCounts(aliveCounts)
		if winner then
			if isSoloStudioRoundHeldActive(aliveCounts) then
				task.wait(0.2)
				continue
			end
			RoundFlow.endRound(winner)
			return
		end
		task.wait(0.2)
	end

	RoundFlow.endRound(getTimeoutWinner())
end

function RoundFlow.resetRound()
	setState(RoundStates.Resetting, "Resetting", 0)
	pendingAdminReset = false
	pendingAdminWinnerTeam = nil
	resetPlayersToLobby()
	DestructionService:Cleanup()
	clearActiveMap()
	clearAllRoundTracking()
	for _, player in ipairs(Players:GetPlayers()) do
		clearPlayerRoundState(player)
	end
	resetScoreboardStats()
	setReplicaValue({ "selectedMapId" }, "")
	setReplicaValue({ "roundResults" }, {})
	setVotingOpen(false)
	syncVoteChoices()
	syncAliveCounts()
	syncCoreState()
end

function RoundFlow.cancelToWaiting(reason: string)
	warn("[RoundService] " .. reason)
	RoundFlow.resetRound()
	setState(RoundStates.WaitingForPlayers, "Waiting for players", 0)
end

function RoundService:_runRoundLoop()
	while running do
		if pendingAdminReset and not pendingAdminForceStartMapId then
			RoundFlow.resetRound()
			setState(RoundStates.WaitingForPlayers, "Waiting for players", 0)
			task.wait(0.2)
			continue
		end

		local forcedMapId = pendingAdminForceStartMapId
		local requiredPlayerCount = getRequiredPlayerCount()
		if not forcedMapId and getEligiblePlayerCount() < requiredPlayerCount then
			setState(RoundStates.WaitingForPlayers, "Waiting for players", 0)
			setVotingOpen(false)
			task.wait(1)
			continue
		end
		if forcedMapId and getEligiblePlayerCount() == 0 then
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
			currentChoices = if forcedMap then { buildForcedVoteChoice(forcedMap) } else {}
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

		RoundFlow.createNewRound()
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

		if not forcedMapId and not RoundFlow.waitForSecondsOrInvalid(RoundConfig.IntermissionSeconds, true) then
			RoundFlow.cancelToWaiting("Round cancelled because not enough players remain")
			continue
		end

		setVotingOpen(false)
		selectedMapId = selectedMapId or chooseWinningMap()
		if not selectedMapId or not getConfiguredMap(selectedMapId) then
			RoundFlow.cancelToWaiting("Round cancelled because no voted map could be selected")
			continue
		end

		setReplicaValue({ "selectedMapId" }, selectedMapId)
		setState(RoundStates.AssigningTeams, "Assigning teams", 0)

		local roster = getEligiblePlayers()
		local minimumRosterCount = if forcedMapId then 1 else getRequiredPlayerCount()
		if #roster < minimumRosterCount then
			RoundFlow.cancelToWaiting("Round cancelled because roster is below minimum")
			continue
		end

		roundPlayers = {}
		alivePlayers = {}
		playerTeams = {}
		assignTeams(roster)

		local map = spawnActiveMap(selectedMapId)
		if not map or not setupTeamCores(map) or not teleportTeamsToMap(map) then
			RoundFlow.cancelToWaiting("Round cancelled because map setup is incomplete")
			continue
		end
		setReplayRoundMap(selectedMapId, map)

		local roundStartingSeconds = if typeof(RoundConfig.RoundStartingSeconds) == "number"
			then math.max(RoundConfig.RoundStartingSeconds, 0)
			else 0
		setState(RoundStates.RoundStarting, "Round starting", roundStartingSeconds)
		if roundStartingSeconds > 0 and not RoundFlow.waitForSecondsOrInvalid(roundStartingSeconds, not forcedMapId) then
			RoundFlow.cancelToWaiting("Round cancelled before battle start")
			continue
		end

		RoundFlow.runActiveRound()
		RoundFlow.resetRound()
	end
end

function RoundService:RecordPlayerDamage(attacker: any, target: Player, damage: number, sourceContext)
	if currentState ~= RoundStates.Active then
		return
	end
	if not (target and target.Parent == Players) then
		return
	end
	if not RoundService:IsPlayerActive(target) then
		return
	end
	if typeof(damage) ~= "number" or damage ~= damage or damage <= 0 then
		return
	end

	local attackerIdentity = nil
	if typeof(attacker) == "Instance" and attacker:IsA("Player") and attacker.Parent == Players then
		if attacker == target then
			return
		end
		attackerIdentity = {
			userId = attacker.UserId,
			teamName = getTrackedTeamName(attacker),
			isPlayer = true,
		}
	elseif StudioAICombatants.IsBotOwner(attacker) then
		attackerIdentity = StudioAICombatants.GetOwnerIdentity(attacker)
	end
	if not attackerIdentity or typeof(attackerIdentity.userId) ~= "number" then
		return
	end

	if attackerIdentity.isPlayer then
		local attackerStats = getScoreboardStatsFor(attacker)
		attackerStats.damage += damage
	end

	local targetKey = getPlayerKey(target)
	local attackerKey = tostring(attackerIdentity.userId)
	local contributors = recentDamageContributors[targetKey]
	if not contributors then
		contributors = {}
		recentDamageContributors[targetKey] = contributors
	end

	contributors[attackerKey] = {
		damagedAt = workspace:GetServerTimeNow(),
		teamName = attackerIdentity.teamName,
		sourceType = if typeof(sourceContext) == "table" and typeof(sourceContext.sourceType) == "string"
			then sourceContext.sourceType
			else nil,
		sourceId = if typeof(sourceContext) == "table" and typeof(sourceContext.sourceId) == "string"
			then sourceContext.sourceId
			else nil,
	}

	syncScoreboardStats()
end

function RoundService:RecordMapDestruction(sourceContext, targetsHit: number, position: Vector3?)
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
	local value = roundNonNegative(targetsHit)
	stats.destruction += value
	syncScoreboardStats()

	local remote = destructionScoreRemote or ensureDestructionScoreRemote()
	destructionScoreRemote = remote
	local payload = {
		value = value,
		roundId = roundId,
		timestamp = workspace:GetServerTimeNow(),
	}
	if typeof(position) == "Vector3" then
		payload.position = position
	end
	remote:FireClient(player, payload)
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
	DestructionService:SetScoreRecorder(function(sourceContext, targetsHit, position)
		RoundService:RecordMapDestruction(sourceContext, targetsHit, position)
	end)
	createGameReplica()
	submitMapVoteRemote = ensureVoteRemote()
	submitMapVoteRemote.OnServerEvent:Connect(function(player: Player, choiceId: any)
		if currentState ~= RoundStates.Intermission then
			return
		end
		if not votingOpen then
			return
		end
		if isPlayerAFK(player) then
			return
		end
		if typeof(choiceId) ~= "string" then
			return
		end
		if playerVotes[player] == choiceId then
			return
		end
		if not isCurrentChoice(choiceId) then
			return
		end

		clearPlayerVote(player)
		playerVotes[player] = choiceId
		voteCounts[choiceId] = (voteCounts[choiceId] or 0) + 1
		syncVoteChoices()
	end)
	setAFKRemote = ensureSetAFKRemote()
	setAFKRemote.OnServerEvent:Connect(function(player: Player, payload: any)
		if typeof(payload) ~= "table" then
			return
		end

		local requestedAFK = payload.afk
		if typeof(requestedAFK) ~= "boolean" then
			return
		end

		setPlayerAFK(player, requestedAFK, normalizeAFKSource(payload.source))
	end)
	reportPreferredInputRemote = ensureReportPreferredInputRemote()
	reportPreferredInputRemote.OnServerEvent:Connect(function(player: Player, preferredInput: any)
		RoundService:ReportPreferredInput(player, preferredInput)
	end)
	killFeedRemote = ensureKillFeedRemote()
	destructionScoreRemote = ensureDestructionScoreRemote()

	for _, player in ipairs(Players:GetPlayers()) do
		player:SetAttribute(AFK_ATTR, false)
		player:SetAttribute(AFK_SOURCE_ATTR, nil)
		player:SetAttribute(AFK_STARTED_AT_ATTR, nil)
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
		task.spawn(function()
			RoundService:_runRoundLoop()
		end)
	end
end

function RoundService:OnPlayerAdded(player: Player)
	clearPlayerRoundState(player)
	player:SetAttribute(AFK_ATTR, false)
	player:SetAttribute(AFK_SOURCE_ATTR, nil)
	player:SetAttribute(AFK_STARTED_AT_ATTR, nil)
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
	characterDestroyTokens[player] = nil
	pendingRoundRespawnTokens[player] = nil
	local voteChanged = clearPlayerVote(player)
	if voteChanged then
		syncVoteChoices()
	end
	removeAFKMarker(player)
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
	return deepCopy(gameStateData)
end

function RoundService:IsPlayerActive(player: Player): boolean
	return currentState == RoundStates.Active
		and alivePlayers[player] == true
		and player:GetAttribute(ROUND_ALIVE_ATTR) == true
		and hasUsableCharacter(player)
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

	if currentState == RoundStates.WaitingForPlayers then
		for _, player in ipairs(Players:GetPlayers()) do
			clearPlayerRoundState(player)
		end
	end
	pendingAdminForceStartMapId = selectedMapId
	pendingAdminReset = currentState ~= RoundStates.WaitingForPlayers
	pendingAdminWinnerTeam = nil
	return true, "Queued admin round start for " .. selectedMapId
end

function RoundService:AdminResetRound(): (boolean, string?)
	pendingAdminReset = true
	pendingAdminWinnerTeam = nil
	for _, player in ipairs(Players:GetPlayers()) do
		clearPlayerRoundState(player)
	end
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
		RespawnFlow.safeLoadCharacter(player, "AdminRespawnLobby")
		task.defer(function()
			if player.Parent == Players then
				movePlayerToLobby(player)
			end
		end)
		return true, "Respawned " .. player.Name .. " in lobby"
	end

	alivePlayers[player] = true
	clearRecentDamageFor(player)
	player:SetAttribute(ROUND_ALIVE_ATTR, false)
	player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, workspace:GetServerTimeNow())
	bindCharacter(player)
	syncAliveCounts()
	task.defer(function()
		if player.Parent == Players then
			local token = bumpRespawnToken(player)
			pendingRoundRespawnTokens[player] = token
			cancelScheduledCharacterDestroy(player)
			RespawnFlow.safeLoadCharacter(player, "AdminRespawnRound")
			RespawnFlow.verifyRoundRespawn(player, token, 1)
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
