local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Teams = game:GetService("Teams")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local ConnectionGroupMap = require(ReplicatedStorage.Shared.Common.ConnectionGroupMap)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local DestructionService = require(ServerScriptService.Services.DestructionService)
local DataService = require(ServerScriptService.Services.DataService)
local QuestService = require(ServerScriptService.Services.QuestService)
local RoundAdminRuntime = require(ServerScriptService.Services.RoundAdminRuntime)
local RoundAFKRuntime = require(ServerScriptService.Services.RoundAFKRuntime)
local RoundCharacterRuntime = require(ServerScriptService.Services.RoundCharacterRuntime)
local RoundCoreRuntime = require(ServerScriptService.Services.RoundCoreRuntime)
local RoundDamageRuntime = require(ServerScriptService.Services.RoundDamageRuntime)
local RoundDeathRuntime = require(ServerScriptService.Services.RoundDeathRuntime)
local RoundKillFeedRuntime = require(ServerScriptService.Services.RoundKillFeedRuntime)
local RoundLightingRuntime = require(ServerScriptService.Services.RoundLightingRuntime)
local RoundMapRuntime = require(ServerScriptService.Services.RoundMapRuntime)
local RoundPlayerStateRuntime = require(ServerScriptService.Services.RoundPlayerStateRuntime)
local RoundRagdollRuntime = require(ServerScriptService.Services.RoundRagdollRuntime)
local RoundReplayRuntime = require(ServerScriptService.Services.RoundReplayRuntime)
local RoundResultsRuntime = require(ServerScriptService.Services.RoundResultsRuntime)
local RoundRespawnRuntime = require(ServerScriptService.Services.RoundRespawnRuntime)
local RoundRespawnTokens = require(ServerScriptService.Services.RoundRespawnTokens)
local RoundScoreboardState = require(ServerScriptService.Services.RoundScoreboardState)
local RoundSpawnRuntime = require(ServerScriptService.Services.RoundSpawnRuntime)
local RoundVotingRuntime = require(ServerScriptService.Services.RoundVotingRuntime)
local RoundVoidFallRuntime = require(ServerScriptService.Services.RoundVoidFallRuntime)
local RoundWorldTextRuntime = require(ServerScriptService.Services.RoundWorldTextRuntime)
local StudioAICombatants = require(ServerScriptService.Services.StudioAICombatants)
local ReplicaService = require(ServerScriptService.Packages.ReplicaService)

local TEAM_ORDER = { RoundConfig.Teams.Red.name, RoundConfig.Teams.Blue.name }
local VALID_ROUND_TEAMS = {
	[RoundConfig.Teams.Red.name] = true,
	[RoundConfig.Teams.Blue.name] = true,
}
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
local CORE_HEALTH_ATTR = RoundConfig.Cores.HealthAttribute
local CORE_DESTROYED_ATTR = RoundConfig.Cores.DestroyedAttribute
local ROUND_ATTRS = {
	roundId = ROUND_ID_ATTR,
	roundTeam = ROUND_TEAM_ATTR,
	roundAlive = ROUND_ALIVE_ATTR,
	roundRespawnEndsAt = ROUND_RESPAWN_ENDS_AT_ATTR,
}
local ASSIST_WINDOW_SECONDS = 10
local DEATH_BODY_RETAIN_SECONDS = 1.8
local RESPAWN_LOAD_VERIFY_DELAY_SECONDS = 0.65
local RESPAWN_LOAD_MAX_ATTEMPTS = 3
local ROUND_CHARACTER_READY_TIMEOUT_SECONDS = 5
local CHARACTER_READINESS_WATCHDOG_TIMEOUT_SECONDS = ROUND_CHARACTER_READY_TIMEOUT_SECONDS
local CHARACTER_READINESS_WATCHDOG_CHECK_INTERVAL_SECONDS = 0.1
local CHARACTER_READINESS_WATCHDOG_RETRY_WINDOW_SECONDS = 20
local CHARACTER_READINESS_WATCHDOG_MAX_RECOVERIES = 2
local LOBBY_VOID_FALL_CHECK_INTERVAL_SECONDS = 0.25
local LOBBY_VOID_FALL_SPAWN_PADDING_STUDS = 80
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

local function isValidRoundTeam(teamName: any): boolean
	return typeof(teamName) == "string" and VALID_ROUND_TEAMS[teamName] == true
end

local function buildInitialTeamKillCounts(): { [string]: number }
	return {
		[RoundConfig.Teams.Red.name] = 0,
		[RoundConfig.Teams.Blue.name] = 0,
	}
end

local function getCreditedTeamKill(payload): string?
	if typeof(payload) ~= "table" then
		return nil
	end

	local killerTeam = payload.killerTeam
	local victimTeam = payload.victimTeam
	if not isValidRoundTeam(killerTeam) or not isValidRoundTeam(victimTeam) then
		return nil
	end
	if killerTeam == victimTeam then
		return nil
	end

	return killerTeam
end

local function getTeamKillWinner(counts: { [string]: number }): string
	local redTeam = RoundConfig.Teams.Red.name
	local blueTeam = RoundConfig.Teams.Blue.name
	local redKills = tonumber(counts[redTeam]) or 0
	local blueKills = tonumber(counts[blueTeam]) or 0

	if redKills > blueKills then
		return redTeam
	end
	if blueKills > redKills then
		return blueTeam
	end
	return "Draw"
end

local getConfiguredMap: (string) -> MapConfig?
local getTrackedTeamName: (Player) -> string?
local getMapTemplate = RoundMapRuntime.GetMapSource
local getFirstConfiguredMapId = RoundMapRuntime.GetFirstConfiguredMapId
local getActiveMap = RoundMapRuntime.GetActiveMap
local clearActiveMap = RoundMapRuntime.ClearActiveMap
local clearPreparedMapClones = RoundMapRuntime.ClearPreparedMapClones
local prepareVoteMapClones = RoundMapRuntime.PrepareVoteMapClones
local spawnActiveMap = RoundMapRuntime.SpawnActiveMap
local getTaggedSpawnParts = RoundSpawnRuntime.GetTaggedSpawnParts
local getTeamSpawns = RoundSpawnRuntime.GetTeamSpawns
local getTeamCores = RoundSpawnRuntime.GetTeamCores
local moveCharacterToSpawn = RoundSpawnRuntime.MoveCharacterToSpawn

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
local teamKillCounts: { [string]: number } = buildInitialTeamKillCounts()
local characterConnections = ConnectionGroupMap.new()
local lobbyCharacterConnections = ConnectionGroupMap.new()
local characterReadinessWatchdogConnections = ConnectionGroupMap.new()
local respawnTokens = RoundRespawnTokens.new()
local teamCoreInstances: { [string]: { Instance } } = {}
local coreConnections = ConnectionGroupMap.new()
local scoreboardState = RoundScoreboardState.new()
local rewardedRoundIds: { [number]: boolean } = {}
local rng = Random.new()
local RespawnFlow = {}
local RoundFlow = {}
local lobbyVoidFallConnection: RBXScriptConnection? = nil
local lobbyVoidFallAccumulator = 0
local lobbyVoidResettingPlayers: { [Player]: boolean } = {}
local characterReadinessWatchdogSerials: { [Player]: number } = {}
local characterReadinessWatchdogRecoveries: { [Player]: { startedAt: number, count: number } } = {}
RespawnFlow.VoidFallPadding = 70
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
		teamKillCounts = buildInitialTeamKillCounts(),
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

local function ensureRoundRemote(name: string): RemoteEvent
	return RemoteUtil.EnsureRemoteEventInFolder(ReplicatedStorage, REMOTES_FOLDER_NAME, name)
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

local function getDestructionScoreRemote(): RemoteEvent
	local remote = destructionScoreRemote
	if not remote then
		remote = ensureDestructionScoreRemote()
		destructionScoreRemote = remote
	end
	return remote
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

local function recordReplayEvent(eventType: string, payload)
	RoundReplayRuntime.RecordEvent(eventType, payload, {
		debugEnabled = DEBUG_REPLAY_EVENTS,
		debugDeathFlow = debugDeathFlow,
	})
end

local function sendWorldText(methodName: string, ...)
	RoundWorldTextRuntime.Send(methodName, ...)
end

local function getPlayerRootPosition(player: Player): Vector3?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart.Position else nil
end

local function setReplayPerformanceCritical(isCritical: boolean)
	RoundReplayRuntime.SetPerformanceCritical(isCritical, DEBUG_REPLAY_EVENTS)
end

local function resetReplayRoundState()
	RoundReplayRuntime.ResetRound(roundId, DEBUG_REPLAY_EVENTS)
end

local function setReplayRoundMap(mapId: string, map: Model)
	RoundReplayRuntime.SetRoundMap(mapId, map, DEBUG_REPLAY_EVENTS)
end

function RoundFlow.getConfiguredDuration(value: any, fallback: number): number
	return RoundReplayRuntime.GetConfiguredDuration(value, fallback)
end

function RoundFlow.getPlayOfTheGameDuration(): number
	return RoundFlow.getConfiguredDuration(RoundConfig.PlayOfTheGameSeconds, 10)
end

function RoundFlow.playRoundEndPOTG(maxWaitSeconds: number): boolean
	return RoundReplayRuntime.PlayPOTG(roundPlayers, maxWaitSeconds, DEBUG_REPLAY_EVENTS)
end

local function getPlayerKey(playerOrUserId: Player | number | string): string
	return RoundScoreboardState.GetPlayerKey(playerOrUserId)
end

local function getScoreboardStatsFor(playerOrUserId: Player | number | string)
	return scoreboardState:GetStatsFor(playerOrUserId)
end

local function syncScoreboardStats()
	setReplicaValue({ "scoreboardStats" }, deepCopy(scoreboardState.stats))
end

local function syncScoreboardPlatforms()
	setReplicaValue({ "scoreboardPlatforms" }, deepCopy(scoreboardState.platforms))
end

local function syncTeamKillCounts()
	setReplicaValue({ "teamKillCounts" }, deepCopy(teamKillCounts))
end

local function resetTeamKillCounts()
	teamKillCounts = buildInitialTeamKillCounts()
	syncTeamKillCounts()
end

local function creditTeamKill(payload)
	local teamName = getCreditedTeamKill(payload)
	if not teamName then
		return
	end

	teamKillCounts[teamName] = (teamKillCounts[teamName] or 0) + 1
	syncTeamKillCounts()
end

local function resetScoreboardStats()
	scoreboardState:Reset()
	syncScoreboardStats()
end

local function roundNonNegative(value: any): number
	return RoundResultsRuntime.RoundNonNegative(value)
end

local function publishRoundResults(winnerTeam: string)
	local selectedMapId = if typeof(gameStateData.selectedMapId) == "string" then gameStateData.selectedMapId else ""
	local results = RoundResultsRuntime.Publish({
		winnerTeam = winnerTeam,
		roundId = roundId,
		selectedMapId = selectedMapId,
		activeRoundStartedAt = activeRoundStartedAt,
		roundPlayers = roundPlayers,
		scoreboardPlatforms = scoreboardState.platforms,
		rewardedRoundIds = rewardedRoundIds,
		dataService = DataService,
		questService = QuestService,
		getConfiguredMap = getConfiguredMap,
		getTrackedTeamName = getTrackedTeamName,
		getScoreboardStatsFor = getScoreboardStatsFor,
	})
	setReplicaValue({ "roundResults" }, deepCopy(results))
end

local function clearRecentDamageFor(player: Player)
	scoreboardState:ClearRecentDamageFor(player)
end

local function removePlayerScoreboardState(player: Player)
	scoreboardState:RemovePlayer(player)
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

local function getPlayerByKey(playerKey: string): Player?
	return RoundKillFeedRuntime.GetPlayerByKey(playerKey, getPlayerKey)
end

local function fireKillFeedElimination(eliminatorKey: string, victim: Player)
	return RoundKillFeedRuntime.FireElimination({
		roundId = roundId,
		eliminatorKey = eliminatorKey,
		victim = victim,
		getPlayerKey = getPlayerKey,
		getTrackedTeamName = getTrackedTeamName,
		getBotIdentity = function(playerKey: string)
			return StudioAICombatants.GetOwnerIdentity({ studioAIBot = true, UserId = tonumber(playerKey) })
		end,
		getRemote = function()
			local remote = killFeedRemote
			if not remote then
				remote = ensureKillFeedRemote()
				killFeedRemote = remote
			end
			return remote
		end,
	})
end

local function creditScoreboardDeath(victim: Player)
	RoundDeathRuntime.CreditScoreboardDeath({
		victim = victim,
		roundId = roundId,
		assistWindowSeconds = ASSIST_WINDOW_SECONDS,
		scoreboardState = scoreboardState,
		getPlayerKey = getPlayerKey,
		getScoreboardStatsFor = getScoreboardStatsFor,
		getTrackedTeamName = getTrackedTeamName,
		getPlayerByKey = getPlayerByKey,
		getPlayerRootPosition = getPlayerRootPosition,
		fireKillFeedElimination = fireKillFeedElimination,
		recordReplayEvent = recordReplayEvent,
		sendWorldText = sendWorldText,
		debugDeathFlow = debugDeathFlow,
		clearRecentDamageFor = clearRecentDamageFor,
		creditTeamKill = creditTeamKill,
		syncScoreboardStats = syncScoreboardStats,
	})
end

local function setState(state: string, status: string?, duration: number?)
	currentState = state
	if state == RoundStates.WaitingForPlayers then
		RoundPlayerStateRuntime.ClearRoundStateForPlayers(Players:GetPlayers(), ROUND_ATTRS)
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

local function getRoundSecondsRemaining(): number?
	local endsAt = gameStateData.endsAt
	if typeof(endsAt) ~= "number" or endsAt <= 0 then
		return nil
	end
	return math.max(endsAt - workspace:GetServerTimeNow(), 0)
end

local function setVotingOpen(open: boolean)
	votingOpen = open
	setReplicaValue({ "votingOpen" }, open)
end

local function setWinner(winnerTeam: string)
	setReplicaValue({ "winnerTeam" }, winnerTeam)
end

getConfiguredMap = function(mapId: string): MapConfig?
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		if mapConfig.id == mapId then
			return mapConfig
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

local function movePlayerToLobby(player: Player)
	RoundSpawnRuntime.MovePlayerToLobby(player, rng)
end

function RoundService.IsPlayerAFK(player: Player): boolean
	return RoundAFKRuntime.IsPlayerAFK(player)
end

function RoundService.GetAFKTemplate(): Instance?
	return RoundAFKRuntime.GetTemplate()
end

function RoundService.RemoveAFKMarker(player: Player)
	RoundAFKRuntime.RemoveMarker(player)
end

function RoundService.SyncPlayerAFKMarker(player: Player)
	RoundAFKRuntime.SyncMarker(player)
end

local function bumpRespawnToken(player: Player): number
	return respawnTokens:BumpRespawn(player)
end

local function cancelScheduledRespawn(player: Player)
	respawnTokens:CancelRespawn(player)
end

local function cancelScheduledCharacterDestroy(player: Player)
	respawnTokens:CancelCharacterDestroy(player)
end

local function destroyPlayerCharacter(player: Player)
	respawnTokens:DestroyPlayerCharacter(player)
end

local function destroyPlayerCharacterAfter(player: Player, delaySeconds: number)
	respawnTokens:DestroyPlayerCharacterAfter(player, delaySeconds)
end

local function clearPlayerRoundState(player: Player)
	cancelScheduledRespawn(player)
	cancelScheduledCharacterDestroy(player)
	RoundPlayerStateRuntime.ClearRoundState(player, ROUND_ATTRS)
end

local function disconnectCoreConnections()
	coreConnections:DisconnectAll()
end

local function clearAllRoundTracking()
	characterConnections:DisconnectAll()
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
	resetTeamKillCounts()
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
	return RoundCoreRuntime.IsCoreAlive(core)
end

local function countAliveCores()
	return RoundCoreRuntime.CountAliveCores(teamCoreInstances)
end

local function buildRespawnState(_coreCounts: { [string]: number })
	return {
		[RoundConfig.Teams.Red.name] = true,
		[RoundConfig.Teams.Blue.name] = true,
	}
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
	return isValidRoundTeam(teamName)
end

local function hasUsableCharacter(player: Player): boolean
	return RoundCharacterRuntime.HasUsableCharacter(player)
end

local function getMissingCharacterReadiness(character: Model): ({ string }, boolean)
	local missing = {}
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		table.insert(missing, "Humanoid")
	elseif humanoid.Health <= 0 then
		return { "HumanoidDead" }, true
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (rootPart and rootPart:IsA("BasePart")) then
		table.insert(missing, "HumanoidRootPart")
	end

	local abilityManagerActor = character:FindFirstChild("AbilityManagerActor")
	if not abilityManagerActor then
		table.insert(missing, "AbilityManagerActor")
	elseif not abilityManagerActor:FindFirstChild("Abilities") then
		table.insert(missing, "AbilityManagerActor.Abilities")
	end

	if not character:FindFirstChildOfClass("ControllerManager") then
		table.insert(missing, "ControllerManager")
	end

	return missing, false
end

local function isCharacterReadyForGameplay(character: Model): boolean
	local missing, terminal = getMissingCharacterReadiness(character)
	return not terminal and #missing == 0
end

function RespawnFlow.prepareDeathRagdoll(character: Model)
	RoundRagdollRuntime.Prepare(character)
end

function RespawnFlow.applyDeathRagdoll(character: Model, reason: string)
	RoundRagdollRuntime.Apply(character, reason, debugDeathFlow)
end

function RespawnFlow.getVoidKillY(): number?
	return RoundVoidFallRuntime.GetKillY(getActiveMap(), RespawnFlow.VoidFallPadding)
end

function RespawnFlow.killPlayerForVoidFall(player: Player, voidKillY: number): boolean
	return RoundVoidFallRuntime.KillPlayerForVoidFall({
		player = player,
		voidKillY = voidKillY,
		isEligible = function(candidate: Player): boolean
			return currentState == RoundStates.Active
				and alivePlayers[candidate] == true
				and candidate:GetAttribute(ROUND_ALIVE_ATTR) == true
		end,
		debugDeathFlow = debugDeathFlow,
		applyDeathRagdoll = function(character: Model, reason: string)
			RespawnFlow.applyDeathRagdoll(character, reason)
		end,
	})
end

function RespawnFlow.checkVoidFalls()
	RoundVoidFallRuntime.CheckVoidFalls({
		alivePlayers = alivePlayers,
		getVoidKillY = function()
			return RespawnFlow.getVoidKillY()
		end,
		isEligible = function(player: Player): boolean
			return currentState == RoundStates.Active
				and alivePlayers[player] == true
				and player:GetAttribute(ROUND_ALIVE_ATTR) == true
		end,
		debugDeathFlow = debugDeathFlow,
		applyDeathRagdoll = function(character: Model, reason: string)
			RespawnFlow.applyDeathRagdoll(character, reason)
		end,
	})
end

function RespawnFlow.checkLobbyVoidFalls()
	local voidKillY = nil
	local lobbySpawns = RoundSpawnRuntime.GetLobbySpawns()
	for _, spawnPart in ipairs(lobbySpawns) do
		local spawnKillY = spawnPart.Position.Y - LOBBY_VOID_FALL_SPAWN_PADDING_STUDS
		voidKillY = if voidKillY then math.min(voidKillY, spawnKillY) else spawnKillY
	end
	voidKillY = voidKillY or RoundVoidFallRuntime.GetKillY(nil, RespawnFlow.VoidFallPadding)
	if not voidKillY then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		if roundPlayers[player] ~= true and lobbyVoidResettingPlayers[player] ~= true then
			local character = player.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			local hasRoot = rootPart and rootPart:IsA("BasePart")
			local shouldReset = character == nil or hasRoot ~= true or (hasRoot and rootPart.Position.Y < voidKillY)
			if shouldReset then
				lobbyVoidResettingPlayers[player] = true
				task.spawn(function()
					local token = bumpRespawnToken(player)
					debugDeathFlow("Lobby void reset", player.Name, "threshold", voidKillY)
					if character then
						character:SetAttribute("DeathReason", "LobbyVoidFall")
					end
					RespawnFlow.respawnPlayerToLobby(player, "LobbyVoidFall", true, token)
					lobbyVoidResettingPlayers[player] = nil
				end)
			end
		end
	end
end

function RespawnFlow.startLobbyVoidFallMonitor()
	if lobbyVoidFallConnection then
		return
	end

	lobbyVoidFallConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
		lobbyVoidFallAccumulator += deltaTime
		if lobbyVoidFallAccumulator < LOBBY_VOID_FALL_CHECK_INTERVAL_SECONDS then
			return
		end

		lobbyVoidFallAccumulator = 0
		RespawnFlow.checkLobbyVoidFalls()
	end)
end

function RespawnFlow.waitForUsableCharacter(player: Player, timeoutSeconds: number): boolean
	return RoundCharacterRuntime.WaitForUsableCharacter(player, timeoutSeconds)
end

function RespawnFlow.safeLoadCharacter(player: Player, context: string): boolean
	return RoundCharacterRuntime.SafeLoadCharacter(player, context, debugDeathFlow)
end

function RespawnFlow.respawnPlayerToLobby(
	player: Player,
	context: string,
	shouldLoadCharacter: boolean?,
	expectedRespawnToken: number?,
	allowRoundTracked: boolean?
): boolean
	if player.Parent ~= Players or (roundPlayers[player] == true and allowRoundTracked ~= true) then
		return false
	end
	if expectedRespawnToken ~= nil and respawnTokens:GetRespawn(player) ~= expectedRespawnToken then
		return false
	end

	local hasCharacter = player.Character ~= nil
	local needsCharacterLoad = shouldLoadCharacter == true or not hasCharacter
	if needsCharacterLoad then
		if not RespawnFlow.safeLoadCharacter(player, context) then
			return false
		end
		RespawnFlow.waitForUsableCharacter(player, ROUND_CHARACTER_READY_TIMEOUT_SECONDS)
	elseif not hasUsableCharacter(player) then
		RespawnFlow.waitForUsableCharacter(player, ROUND_CHARACTER_READY_TIMEOUT_SECONDS)
	end

	if expectedRespawnToken ~= nil and respawnTokens:GetRespawn(player) ~= expectedRespawnToken then
		return false
	end
	if player.Parent ~= Players or (roundPlayers[player] == true and allowRoundTracked ~= true) then
		return false
	end
	if not hasUsableCharacter(player) then
		warn(("[RoundService] Lobby respawn did not produce a usable character for %s during %s"):format(
			player.Name,
			context
		))
		return false
	end

	clearPlayerRoundState(player)
	movePlayerToLobby(player)
	RoundService.SyncPlayerAFKMarker(player)
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

	RoundSpawnRuntime.MoveCharacterToTeamSpawn(player, spawns[rng:NextInteger(1, #spawns)], activeMap)
	return true
end

function RespawnFlow.finalizeRoundRespawnIfReady(player: Player, token: number, context: string): boolean
	return RoundRespawnRuntime.FinalizeRoundRespawnIfReady({
		player = player,
		token = token,
		context = context,
		roundAliveAttribute = ROUND_ALIVE_ATTR,
		roundRespawnEndsAtAttribute = ROUND_RESPAWN_ENDS_AT_ATTR,
		debugDeathFlow = debugDeathFlow,
		getPendingRoundRespawn = function(candidate: Player): number?
			return respawnTokens:GetPendingRoundRespawn(candidate)
		end,
		getRespawnToken = function(candidate: Player): number?
			return respawnTokens:GetRespawn(candidate)
		end,
		hasUsableCharacter = hasUsableCharacter,
		isRespawnStillValid = function(candidate: Player): boolean
			return currentState == RoundStates.Active and roundPlayers[candidate] == true and alivePlayers[candidate] == true
		end,
		getTeamName = function(candidate: Player): string?
			return playerTeams[candidate]
		end,
		teamHasRespawns = teamHasRespawns,
		moveRoundCharacterToTeamSpawn = function(candidate: Player): boolean
			return RespawnFlow.moveRoundCharacterToTeamSpawn(candidate)
		end,
		clearPendingRoundRespawn = function(candidate: Player)
			respawnTokens:ClearPendingRoundRespawn(candidate)
		end,
	})
end

function RespawnFlow.shouldRetryRoundRespawn(player: Player, token: number): boolean
	return RoundRespawnRuntime.ShouldRetryRoundRespawn({
		player = player,
		token = token,
		roundAliveAttribute = ROUND_ALIVE_ATTR,
		debugDeathFlow = debugDeathFlow,
		getPendingRoundRespawn = function(candidate: Player): number?
			return respawnTokens:GetPendingRoundRespawn(candidate)
		end,
		getRespawnToken = function(candidate: Player): number?
			return respawnTokens:GetRespawn(candidate)
		end,
		getCurrentState = function(): string
			return currentState
		end,
		isRespawnStillValid = function(candidate: Player): boolean
			return currentState == RoundStates.Active and roundPlayers[candidate] == true and alivePlayers[candidate] == true
		end,
		isRoundPlayer = function(candidate: Player): boolean
			return roundPlayers[candidate] == true
		end,
		isAlive = function(candidate: Player): boolean
			return alivePlayers[candidate] == true
		end,
		getTeamName = function(candidate: Player): string?
			return playerTeams[candidate]
		end,
		teamHasRespawns = teamHasRespawns,
	})
end

function RespawnFlow.verifyRoundRespawn(player: Player, token: number, attempt: number)
	RoundRespawnRuntime.VerifyRoundRespawn({
		player = player,
		token = token,
		attempt = attempt,
		verifyDelaySeconds = RESPAWN_LOAD_VERIFY_DELAY_SECONDS,
		maxAttempts = RESPAWN_LOAD_MAX_ATTEMPTS,
		roundAliveAttribute = ROUND_ALIVE_ATTR,
		roundRespawnEndsAtAttribute = ROUND_RESPAWN_ENDS_AT_ATTR,
		debugDeathFlow = debugDeathFlow,
		getPendingRoundRespawn = function(candidate: Player): number?
			return respawnTokens:GetPendingRoundRespawn(candidate)
		end,
		getRespawnToken = function(candidate: Player): number?
			return respawnTokens:GetRespawn(candidate)
		end,
		getCurrentState = function(): string
			return currentState
		end,
		hasUsableCharacter = hasUsableCharacter,
		isRespawnStillValid = function(candidate: Player): boolean
			return currentState == RoundStates.Active and roundPlayers[candidate] == true and alivePlayers[candidate] == true
		end,
		isRoundPlayer = function(candidate: Player): boolean
			return roundPlayers[candidate] == true
		end,
		isAlive = function(candidate: Player): boolean
			return alivePlayers[candidate] == true
		end,
		getTeamName = function(candidate: Player): string?
			return playerTeams[candidate]
		end,
		teamHasRespawns = teamHasRespawns,
		moveRoundCharacterToTeamSpawn = function(candidate: Player): boolean
			return RespawnFlow.moveRoundCharacterToTeamSpawn(candidate)
		end,
		clearPendingRoundRespawn = function(candidate: Player)
			respawnTokens:ClearPendingRoundRespawn(candidate)
		end,
		safeLoadCharacter = function(candidate: Player, context: string): boolean
			return RespawnFlow.safeLoadCharacter(candidate, context)
		end,
		eliminatePlayer = eliminatePlayer,
	})
end

local function canRecoverCharacterReadiness(player: Player): boolean
	local nowSeconds = os.clock()
	local record = characterReadinessWatchdogRecoveries[player]
	if not record or nowSeconds - record.startedAt > CHARACTER_READINESS_WATCHDOG_RETRY_WINDOW_SECONDS then
		characterReadinessWatchdogRecoveries[player] = {
			startedAt = nowSeconds,
			count = 1,
		}
		return true
	end

	if record.count >= CHARACTER_READINESS_WATCHDOG_MAX_RECOVERIES then
		return false
	end

	record.count += 1
	return true
end

function RespawnFlow.recoverBrokenCharacter(player: Player, character: Model, reason: string, missing: { string }): boolean
	if player.Parent ~= Players or player.Character ~= character or not character.Parent then
		return false
	end
	if not canRecoverCharacterReadiness(player) then
		warn(("[RoundService] Character readiness watchdog retry cap reached for %s; missing=%s reason=%s"):format(
			player.Name,
			table.concat(missing, ","),
			reason
		))
		return false
	end

	warn(("[RoundService] Character readiness watchdog respawning %s; missing=%s reason=%s"):format(
		player.Name,
		table.concat(missing, ","),
		reason
	))

	if roundPlayers[player] == true and alivePlayers[player] == true then
		cancelScheduledRespawn(player)
		cancelScheduledCharacterDestroy(player)
		clearRecentDamageFor(player)
		player:SetAttribute(ROUND_ALIVE_ATTR, false)
		player:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, workspace:GetServerTimeNow())
		syncAliveCounts()

		local token = bumpRespawnToken(player)
		respawnTokens:SetPendingRoundRespawn(player, token)
		if not RespawnFlow.safeLoadCharacter(player, "CharacterReadinessWatchdogRound") then
			return false
		end
		RespawnFlow.verifyRoundRespawn(player, token, 1)
		return true
	end

	if roundPlayers[player] == true then
		debugDeathFlow(
			"Character readiness watchdog skipped round-tracked non-alive player",
			player.Name,
			currentState,
			tostring(alivePlayers[player])
		)
		return false
	end

	local token = bumpRespawnToken(player)
	return RespawnFlow.respawnPlayerToLobby(player, "CharacterReadinessWatchdogLobby", true, token)
end

local function watchCharacterReadiness(player: Player, character: Model)
	characterReadinessWatchdogSerials[player] = (characterReadinessWatchdogSerials[player] or 0) + 1
	local serial = characterReadinessWatchdogSerials[player]

	task.spawn(function()
		local deadline = os.clock() + CHARACTER_READINESS_WATCHDOG_TIMEOUT_SECONDS
		local lastMissing = {}

		while os.clock() <= deadline do
			if player.Parent ~= Players or player.Character ~= character or not character.Parent then
				return
			end
			if characterReadinessWatchdogSerials[player] ~= serial then
				return
			end

			local missing, terminal = getMissingCharacterReadiness(character)
			if terminal then
				return
			end
			if #missing == 0 then
				return
			end
			lastMissing = missing
			task.wait(CHARACTER_READINESS_WATCHDOG_CHECK_INTERVAL_SECONDS)
		end

		if player.Parent ~= Players or player.Character ~= character or not character.Parent then
			return
		end
		if characterReadinessWatchdogSerials[player] ~= serial then
			return
		end
		if isCharacterReadyForGameplay(character) then
			return
		end

		local missing, terminal = getMissingCharacterReadiness(character)
		if terminal then
			return
		end
		if #missing == 0 then
			missing = lastMissing
		end
		RespawnFlow.recoverBrokenCharacter(player, character, "ReadinessTimeout", missing)
	end)
end

local function bindCharacterReadinessWatchdog(player: Player)
	characterReadinessWatchdogConnections:Reset(player)
	characterReadinessWatchdogSerials[player] = (characterReadinessWatchdogSerials[player] or 0) + 1

	characterReadinessWatchdogConnections:Add(player, player.CharacterAdded:Connect(function(character)
		watchCharacterReadiness(player, character)
	end))

	if player.Character then
		watchCharacterReadiness(player, player.Character)
	end
end

local function disconnectCharacterConnections(player: Player)
	characterConnections:Disconnect(player)
end

local function disconnectLobbyCharacterConnection(player: Player)
	lobbyCharacterConnections:Disconnect(player)
end

local function disconnectCharacterReadinessWatchdog(player: Player)
	characterReadinessWatchdogConnections:Disconnect(player)
	characterReadinessWatchdogSerials[player] = (characterReadinessWatchdogSerials[player] or 0) + 1
	characterReadinessWatchdogRecoveries[player] = nil
end

local function bindLobbyCharacter(player: Player)
	RoundCharacterRuntime.BindLobbyCharacter({
		player = player,
		connections = lobbyCharacterConnections,
		lobbyDeathBoundAttribute = RespawnFlow.LobbyDeathBoundAttribute,
		respawnSeconds = RoundConfig.RespawnSeconds,
		prepareDeathRagdoll = function(character: Model)
			RespawnFlow.prepareDeathRagdoll(character)
		end,
		applyDeathRagdoll = function(character: Model, reason: string)
			RespawnFlow.applyDeathRagdoll(character, reason)
		end,
		isRoundPlayer = function(candidate: Player): boolean
			return roundPlayers[candidate] == true
		end,
		bumpRespawnToken = bumpRespawnToken,
		getRespawnToken = function(candidate: Player): number?
			return respawnTokens:GetRespawn(candidate)
		end,
		safeLoadCharacter = function(candidate: Player, context: string): boolean
			return RespawnFlow.safeLoadCharacter(candidate, context)
		end,
		waitForUsableCharacter = function(candidate: Player, timeoutSeconds: number): boolean
			return RespawnFlow.waitForUsableCharacter(candidate, timeoutSeconds)
		end,
		respawnPlayerToLobby = function(
			candidate: Player,
			context: string,
			shouldLoadCharacter: boolean?,
			expectedRespawnToken: number?,
			allowRoundTracked: boolean?
		): boolean
			return RespawnFlow.respawnPlayerToLobby(
				candidate,
				context,
				shouldLoadCharacter,
				expectedRespawnToken,
				allowRoundTracked
			)
		end,
		verifyDelaySeconds = RESPAWN_LOAD_VERIFY_DELAY_SECONDS,
		maxLoadAttempts = RESPAWN_LOAD_MAX_ATTEMPTS,
		readyTimeoutSeconds = ROUND_CHARACTER_READY_TIMEOUT_SECONDS,
		clearPlayerRoundState = clearPlayerRoundState,
		movePlayerToLobby = movePlayerToLobby,
		syncAFKMarker = function(candidate: Player)
			RoundService.SyncPlayerAFKMarker(candidate)
		end,
	})
end

local function bindCore(core: Instance, map: Instance)
	coreConnections:Reset(core)

	local function onCoreStateChanged()
		if currentState == RoundStates.Active then
			syncCoreState()
		end
	end

	coreConnections:Add(core, core:GetAttributeChangedSignal(CORE_HEALTH_ATTR):Connect(onCoreStateChanged))
	coreConnections:Add(core, core:GetAttributeChangedSignal(CORE_DESTROYED_ATTR):Connect(onCoreStateChanged))
	coreConnections:Add(core, core.AncestryChanged:Connect(function()
		if not core:IsDescendantOf(map) then
			onCoreStateChanged()
		end
	end))

	local humanoid = core:FindFirstChildOfClass("Humanoid")
	if humanoid then
		coreConnections:Add(core, humanoid.Died:Connect(onCoreStateChanged))
		coreConnections:Add(core, humanoid.HealthChanged:Connect(onCoreStateChanged))
	end
end

local function setupTeamCores(map: Model): boolean
	disconnectCoreConnections()
	teamCoreInstances = {}

	for _, teamName in ipairs(TEAM_ORDER) do
		local cores = getTeamCores(teamName, map)
		local repairedCores = {}
		for _, core in ipairs(cores) do
			local repairedCore = RoundCoreRuntime.RepairEmptyCoreModel(core, teamName)
			table.insert(repairedCores, RoundCoreRuntime.PrepareCoreForRound(repairedCore, teamName))
		end
		teamCoreInstances[teamName] = repairedCores

		for _, core in ipairs(repairedCores) do
			bindCore(core, map)
		end
	end

	syncCoreState()
	return true
end

local function getTimeoutWinner(): string
	return getTeamKillWinner(teamKillCounts)
end

eliminatePlayer = function(player: Player)
	RoundRespawnRuntime.EliminatePlayer({
		player = player,
		alivePlayers = alivePlayers,
		playerTeams = playerTeams,
		roundId = roundId,
		roundAliveAttribute = ROUND_ALIVE_ATTR,
		roundRespawnEndsAtAttribute = ROUND_RESPAWN_ENDS_AT_ATTR,
		debugDeathFlow = debugDeathFlow,
		cancelScheduledRespawn = cancelScheduledRespawn,
		syncAliveCounts = syncAliveCounts,
		destroyPlayerCharacter = destroyPlayerCharacter,
	})
end

reconcilePlayersWithoutRespawns = function()
	RoundRespawnRuntime.ReconcilePlayersWithoutRespawns({
		roundPlayers = roundPlayers,
		alivePlayers = alivePlayers,
		playerTeams = playerTeams,
		roundAliveAttribute = ROUND_ALIVE_ATTR,
		teamHasRespawns = teamHasRespawns,
		debugDeathFlow = debugDeathFlow,
		eliminatePlayer = eliminatePlayer,
	})
end

local function respawnPlayerInRound(player: Player)
	RoundRespawnRuntime.ScheduleRoundRespawn({
		player = player,
		roundId = roundId,
		respawnSeconds = RoundConfig.RespawnSeconds,
		deathBodyRetainSeconds = DEATH_BODY_RETAIN_SECONDS,
		roundAliveAttribute = ROUND_ALIVE_ATTR,
		roundRespawnEndsAtAttribute = ROUND_RESPAWN_ENDS_AT_ATTR,
		debugDeathFlow = debugDeathFlow,
		clearRecentDamageFor = clearRecentDamageFor,
		destroyPlayerCharacterAfter = destroyPlayerCharacterAfter,
		bumpRespawnToken = bumpRespawnToken,
		getRespawnToken = function(candidate: Player): number?
			return respawnTokens:GetRespawn(candidate)
		end,
		getCurrentState = function(): string
			return currentState
		end,
		isRespawnStillValid = function(candidate: Player): boolean
			return currentState == RoundStates.Active and roundPlayers[candidate] == true and alivePlayers[candidate] == true
		end,
		isRoundPlayer = function(candidate: Player): boolean
			return roundPlayers[candidate] == true
		end,
		isAlive = function(candidate: Player): boolean
			return alivePlayers[candidate] == true
		end,
		getTeamName = function(candidate: Player): string?
			return playerTeams[candidate]
		end,
		teamHasRespawns = teamHasRespawns,
		eliminatePlayer = eliminatePlayer,
		setPendingRoundRespawn = function(candidate: Player, token: number)
			respawnTokens:SetPendingRoundRespawn(candidate, token)
		end,
		cancelScheduledCharacterDestroy = cancelScheduledCharacterDestroy,
		safeLoadCharacter = function(candidate: Player, context: string): boolean
			return RespawnFlow.safeLoadCharacter(candidate, context)
		end,
		verifyRoundRespawn = function(candidate: Player, token: number, attempt: number)
			RespawnFlow.verifyRoundRespawn(candidate, token, attempt)
		end,
	})
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
	RoundCharacterRuntime.BindRoundCharacter({
		player = player,
		connections = characterConnections,
		roundDeathBoundAttribute = RespawnFlow.RoundDeathBoundAttribute,
		readyTimeoutSeconds = ROUND_CHARACTER_READY_TIMEOUT_SECONDS,
		prepareDeathRagdoll = function(character: Model)
			RespawnFlow.prepareDeathRagdoll(character)
		end,
		applyDeathRagdoll = function(character: Model, reason: string)
			RespawnFlow.applyDeathRagdoll(character, reason)
		end,
		isRoundActive = function(): boolean
			return currentState == RoundStates.Active
		end,
		getRoundId = function(): number
			return roundId
		end,
		debugDeathFlow = debugDeathFlow,
		handlePlayerDeath = handlePlayerDeath,
		isRoundPlayer = function(candidate: Player): boolean
			return roundPlayers[candidate] == true
		end,
		isAlive = function(candidate: Player): boolean
			return alivePlayers[candidate] == true
		end,
		movePlayerToLobby = movePlayerToLobby,
		syncAFKMarker = function(candidate: Player)
			RoundService.SyncPlayerAFKMarker(candidate)
		end,
		getPendingRoundRespawn = function(candidate: Player): number?
			return respawnTokens:GetPendingRoundRespawn(candidate)
		end,
		finalizeRoundRespawnIfReady = function(candidate: Player, token: number, context: string): boolean
			return RespawnFlow.finalizeRoundRespawnIfReady(candidate, token, context)
		end,
		moveRoundCharacterToTeamSpawn = function(candidate: Player): boolean
			return RespawnFlow.moveRoundCharacterToTeamSpawn(candidate)
		end,
		clearRespawnEndsAt = function(candidate: Player)
			candidate:SetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR, 0)
		end,
		clearPlayerRoundState = clearPlayerRoundState,
	})
end

local function chooseVoteOptions(): { VoteChoice }
	return RoundVotingRuntime.ChooseOptions(function(mapId: string): boolean
		return getMapTemplate(mapId) ~= nil
	end, rng)
end

function RoundFlow.syncVoteChoices()
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

local function isCurrentChoice(choiceId: string): boolean
	return RoundVotingRuntime.HasChoice(currentChoices, choiceId)
end

function RoundFlow.clearPlayerVote(player: Player): boolean
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

function RoundFlow.normalizeAFKSource(value: any): string
	return RoundAFKRuntime.NormalizeSource(value)
end

function RoundFlow.fireAFKResult(player: Player, accepted: boolean, reason: string?)
	if setAFKRemote then
		setAFKRemote:FireClient(player, {
			accepted = accepted,
			afk = RoundService.IsPlayerAFK(player),
			source = RoundAFKRuntime.GetSource(player),
			reason = reason,
		})
	end
end

function RoundFlow.setPlayerAFK(player: Player, afk: boolean, source: string): boolean
	if player.Parent ~= Players then
		return false
	end

	if afk and currentState == RoundStates.Active and roundPlayers[player] then
		Notify.Send(player, "You can't go AFK during a round.", {
			color = "Orange",
			duration = 3,
		})
		RoundFlow.fireAFKResult(player, false, "ActiveRound")
		return false
	end

	local wasAFK = RoundService.IsPlayerAFK(player)
	RoundAFKRuntime.SetPlayerAFK(player, afk, source)

	if afk then
		local voteChanged = RoundFlow.clearPlayerVote(player)
		if voteChanged then
			RoundFlow.syncVoteChoices()
		end
	end

	if wasAFK ~= afk then
		RoundService.SyncPlayerAFKMarker(player)
	end

	RoundFlow.fireAFKResult(player, true, nil)
	return true
end

local function buildForcedVoteChoice(mapConfig: MapConfig): VoteChoice
	return RoundVotingRuntime.MakeChoice(mapConfig, 1)
end

function RoundFlow.chooseWinningMap(): string?
	return RoundVotingRuntime.ChooseWinningMap(currentChoices, voteCounts, rng)
end

function RoundService.GetEligiblePlayers(): { Player }
	local players = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Parent == Players and not RoundService.IsPlayerAFK(player) then
			table.insert(players, player)
		end
	end
	return players
end

function RoundService.GetEligiblePlayerCount(): number
	return #RoundService.GetEligiblePlayers()
end

function RoundService.ShufflePlayers(players: { Player })
	for index = #players, 2, -1 do
		local swapIndex = rng:NextInteger(1, index)
		players[index], players[swapIndex] = players[swapIndex], players[index]
	end
end

function RoundService.AssignTeams(players: { Player })
	RoundService.ShufflePlayers(players)

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

function RoundService.TeleportTeamsToMap(map: Model): boolean
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
			RoundSpawnRuntime.MoveCharacterToTeamSpawn(player, spawns[rng:NextInteger(1, #spawns)], map)
		end
	end

	return true
end

function RoundService.ResetPlayersToLobby()
	for _, player in ipairs(Players:GetPlayers()) do
		RespawnFlow.respawnPlayerToLobby(player, "RoundResetLobby", false, nil, true)
	end
end

function RoundFlow.createGameReplica()
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
	resetTeamKillCounts()
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
		if requireMinPlayers and RoundService.GetEligiblePlayerCount() < getRequiredPlayerCount() then
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

		task.wait(0.2)
	end

	RoundFlow.endRound(getTimeoutWinner())
end

function RoundFlow.resetRound()
	setState(RoundStates.Resetting, "Resetting", 0)
	pendingAdminReset = false
	pendingAdminWinnerTeam = nil
	RoundService.ResetPlayersToLobby()
	DestructionService:BeginBulkUpdate("RoundReset")
	DestructionService:Cleanup()
	clearActiveMap()
	DestructionService:EndBulkUpdate("RoundReset")
	RoundLightingRuntime.RestoreDefaultLighting()
	clearPreparedMapClones(nil)
	clearAllRoundTracking()
	for _, player in ipairs(Players:GetPlayers()) do
		clearPlayerRoundState(player)
	end
	resetScoreboardStats()
	resetTeamKillCounts()
	setReplicaValue({ "selectedMapId" }, "")
	setReplicaValue({ "roundResults" }, {})
	setVotingOpen(false)
	RoundFlow.syncVoteChoices()
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
		if not forcedMapId and RoundService.GetEligiblePlayerCount() < requiredPlayerCount then
			setState(RoundStates.WaitingForPlayers, "Waiting for players", 0)
			setVotingOpen(false)
			task.wait(1)
			continue
		end
		if forcedMapId and RoundService.GetEligiblePlayerCount() == 0 then
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
		RoundFlow.syncVoteChoices()
		setVotingOpen(not forcedMapId)
		prepareVoteMapClones(currentChoices)

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
		selectedMapId = selectedMapId or RoundFlow.chooseWinningMap()
		if not selectedMapId or not getConfiguredMap(selectedMapId) then
			RoundFlow.cancelToWaiting("Round cancelled because no voted map could be selected")
			continue
		end

		setReplicaValue({ "selectedMapId" }, selectedMapId)
		setState(RoundStates.AssigningTeams, "Assigning teams", 0)

		local roster = RoundService.GetEligiblePlayers()
		local minimumRosterCount = if forcedMapId then 1 else getRequiredPlayerCount()
		if #roster < minimumRosterCount then
			RoundFlow.cancelToWaiting("Round cancelled because roster is below minimum")
			continue
		end

		roundPlayers = {}
		alivePlayers = {}
		playerTeams = {}
		RoundService.AssignTeams(roster)

		RoundMapRuntime.WaitForPreparedMapClone(selectedMapId, RoundMapRuntime.MapPrepSelectedWaitSeconds)

		DestructionService:BeginBulkUpdate("RoundMapSetup")
		local map = spawnActiveMap(selectedMapId)
		local mapReady = map and setupTeamCores(map)
		DestructionService:EndBulkUpdate("RoundMapSetup")
		if map then
			RoundLightingRuntime.ApplyMapLighting(map)
		end
		if not mapReady or not map or not RoundService.TeleportTeamsToMap(map) then
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
	RoundDamageRuntime.RecordPlayerDamage({
		isRoundActive = currentState == RoundStates.Active,
		attacker = attacker,
		target = target,
		damage = damage,
		sourceContext = sourceContext,
		scoreboardState = scoreboardState,
		getTrackedTeamName = getTrackedTeamName,
		getScoreboardStatsFor = getScoreboardStatsFor,
		isPlayerActive = function(player: Player): boolean
			return RoundService:IsPlayerActive(player)
		end,
		syncScoreboardStats = syncScoreboardStats,
	})
end

function RoundService:RecordMapDestruction(sourceContext, targetsHit: number, position: Vector3?)
	RoundDamageRuntime.RecordMapDestruction({
		isRoundActive = currentState == RoundStates.Active,
		sourceContext = sourceContext,
		targetsHit = targetsHit,
		position = position,
		roundId = roundId,
		roundPlayers = roundPlayers,
		getScoreboardStatsFor = getScoreboardStatsFor,
		roundNonNegative = roundNonNegative,
		syncScoreboardStats = syncScoreboardStats,
		getDestructionScoreRemote = getDestructionScoreRemote,
	})
end

function RoundService:ReportPreferredInput(player: Player, preferredInput: any)
	if not (player and player.Parent == Players) then
		return
	end
	if typeof(preferredInput) ~= "string" or not VALID_PREFERRED_INPUT[preferredInput] then
		return
	end

	if not scoreboardState:SetPreferredInput(player, preferredInput) then
		return
	end

	syncScoreboardPlatforms()
end

function RoundService:OnStart()
	Players.CharacterAutoLoads = false
	RoundLightingRuntime.Initialize()
	StudioAICombatants.SetTeamKillRecorder(creditTeamKill)
	RespawnFlow.startLobbyVoidFallMonitor()
	DestructionService:SetScoreRecorder(function(sourceContext, targetsHit, position)
		RoundService:RecordMapDestruction(sourceContext, targetsHit, position)
	end)
	RoundFlow.createGameReplica()
	submitMapVoteRemote = ensureVoteRemote()
	submitMapVoteRemote.OnServerEvent:Connect(function(player: Player, choiceId: any)
		if currentState ~= RoundStates.Intermission then
			return
		end
		if not votingOpen then
			return
		end
		if RoundService.IsPlayerAFK(player) then
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

		RoundFlow.clearPlayerVote(player)
		playerVotes[player] = choiceId
		voteCounts[choiceId] = (voteCounts[choiceId] or 0) + 1
		RoundFlow.syncVoteChoices()
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

		RoundFlow.setPlayerAFK(player, requestedAFK, RoundFlow.normalizeAFKSource(payload.source))
	end)
	reportPreferredInputRemote = ensureReportPreferredInputRemote()
	reportPreferredInputRemote.OnServerEvent:Connect(function(player: Player, preferredInput: any)
		RoundService:ReportPreferredInput(player, preferredInput)
	end)
	killFeedRemote = ensureKillFeedRemote()
	destructionScoreRemote = ensureDestructionScoreRemote()

	for _, player in ipairs(Players:GetPlayers()) do
		RoundAFKRuntime.ResetPlayer(player)
		bindCharacterReadinessWatchdog(player)
		bindLobbyCharacter(player)
		task.defer(function()
			if player.Parent == Players then
				RespawnFlow.respawnPlayerToLobby(player, "ServerStartLobby", false, nil)
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
	RoundAFKRuntime.ResetPlayer(player)
	bindCharacterReadinessWatchdog(player)
	bindLobbyCharacter(player)
	task.defer(function()
		if player.Parent ~= Players then
			return
		end
		RespawnFlow.respawnPlayerToLobby(player, "PlayerAddedLobby", false, nil)
	end)
end

function RoundService:OnPlayerRemoving(player: Player)
	lobbyVoidResettingPlayers[player] = nil
	respawnTokens:ClearPlayer(player)
	local voteChanged = RoundFlow.clearPlayerVote(player)
	if voteChanged then
		RoundFlow.syncVoteChoices()
	end
	RoundService.RemoveAFKMarker(player)
	removePlayerScoreboardState(player)
	disconnectCharacterConnections(player)
	disconnectLobbyCharacterConnection(player)
	disconnectCharacterReadinessWatchdog(player)

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
	if not RoundCoreRuntime.MarkCoreDestroyed(trackedCore) then
		return false
	end

	syncCoreState()
	return true
end

function RoundService:DamageCore(core: Instance, damage: number, sourceContext): boolean
	return RoundCoreRuntime.DamageCore({
		isRoundActive = currentState == RoundStates.Active,
		core = self:GetTrackedCore(core),
		damage = damage,
		sourceContext = sourceContext,
		getRoundSecondsRemaining = getRoundSecondsRemaining,
		recordReplayEvent = recordReplayEvent,
		syncCoreState = syncCoreState,
	})
end

function RoundService:GetTrackedCore(instance: Instance): Instance?
	return RoundCoreRuntime.FindTrackedCore(instance, teamCoreInstances)
end

function RoundService:AdminForceStart(mapId: string?): (boolean, string?)
	return RoundAdminRuntime.ForceStart({
		mapId = mapId,
		currentState = currentState,
		getFirstConfiguredMapId = getFirstConfiguredMapId,
		getConfiguredMap = getConfiguredMap,
		getMapTemplate = getMapTemplate,
		clearAllPlayerRoundState = function()
			for _, player in ipairs(Players:GetPlayers()) do
				clearPlayerRoundState(player)
			end
		end,
		setPendingForceStart = function(selectedMapId: string, resetCurrentRound: boolean)
			pendingAdminForceStartMapId = selectedMapId
			pendingAdminReset = resetCurrentRound
			pendingAdminWinnerTeam = nil
		end,
	})
end

function RoundService:AdminResetRound(): (boolean, string?)
	return RoundAdminRuntime.ResetRound({
		setPendingReset = function()
			pendingAdminReset = true
			pendingAdminWinnerTeam = nil
		end,
		clearAllPlayerRoundState = function()
			for _, player in ipairs(Players:GetPlayers()) do
				clearPlayerRoundState(player)
			end
		end,
	})
end

function RoundService:AdminEndRound(winnerTeam: string): (boolean, string?)
	return RoundAdminRuntime.EndRound({
		currentState = currentState,
		winnerTeam = winnerTeam,
		setPendingWinner = function(selectedWinnerTeam: string)
			pendingAdminWinnerTeam = selectedWinnerTeam
		end,
	})
end

function RoundService:AdminDamageTeamCore(teamName: string, damage: number): (boolean, string?)
	return RoundAdminRuntime.DamageTeamCore({
		teamName = teamName,
		damage = damage,
		teamCoreInstances = teamCoreInstances,
		isCoreAlive = isCoreAlive,
		damageCore = function(core: Instance, amount: number): boolean
			return self:DamageCore(core, amount)
		end,
	})
end

function RoundService:AdminDestroyTeamCore(teamName: string): (boolean, string?)
	return RoundAdminRuntime.DestroyTeamCore({
		teamName = teamName,
		teamCoreInstances = teamCoreInstances,
		isCoreAlive = isCoreAlive,
		markCoreDestroyed = function(core: Instance): boolean
			return self:MarkCoreDestroyed(core)
		end,
	})
end

function RoundService:AdminTestKillFeed(): (boolean, string?)
	return RoundAdminRuntime.TestKillFeed({
		roundId = roundId,
		getKillFeedRemote = function(): RemoteEvent
			local remote = killFeedRemote
			if not remote then
				remote = ensureKillFeedRemote()
				killFeedRemote = remote
			end
			return remote
		end,
	})
end

function RoundService:AdminRespawnPlayer(player: Player): (boolean, string?)
	return RoundAdminRuntime.RespawnPlayer({
		player = player,
		roundAliveAttribute = ROUND_ALIVE_ATTR,
		roundRespawnEndsAtAttribute = ROUND_RESPAWN_ENDS_AT_ATTR,
		cancelScheduledRespawn = cancelScheduledRespawn,
		isActiveRoundPlayer = function(candidate: Player): boolean
			return currentState == RoundStates.Active and roundPlayers[candidate] == true
		end,
		safeLoadCharacter = function(candidate: Player, context: string): boolean
			return RespawnFlow.safeLoadCharacter(candidate, context)
		end,
		respawnPlayerToLobby = function(
			candidate: Player,
			context: string,
			shouldLoadCharacter: boolean?,
			expectedRespawnToken: number?,
			allowRoundTracked: boolean?
		): boolean
			return RespawnFlow.respawnPlayerToLobby(
				candidate,
				context,
				shouldLoadCharacter,
				expectedRespawnToken,
				allowRoundTracked
			)
		end,
		movePlayerToLobby = movePlayerToLobby,
		setAlive = function(candidate: Player, alive: boolean)
			alivePlayers[candidate] = alive
		end,
		clearRecentDamageFor = clearRecentDamageFor,
		bindCharacter = bindCharacter,
		syncAliveCounts = syncAliveCounts,
		bumpRespawnToken = bumpRespawnToken,
		setPendingRoundRespawn = function(candidate: Player, token: number)
			respawnTokens:SetPendingRoundRespawn(candidate, token)
		end,
		cancelScheduledCharacterDestroy = cancelScheduledCharacterDestroy,
		verifyRoundRespawn = function(candidate: Player, token: number, attempt: number)
			RespawnFlow.verifyRoundRespawn(candidate, token, attempt)
		end,
	})
end

function RoundService:AdminRespawnAll(): (boolean, string?)
	return RoundAdminRuntime.RespawnAll({
		respawnPlayer = function(player: Player)
			self:AdminRespawnPlayer(player)
		end,
	})
end

function RoundService:AdminTeleportPlayer(player: Player, destination: string, sourcePlayer: Player?): (boolean, string?)
	return RoundAdminRuntime.TeleportPlayer({
		player = player,
		destination = destination,
		sourcePlayer = sourcePlayer,
		safeLoadCharacter = function(candidate: Player, context: string): boolean
			return RespawnFlow.safeLoadCharacter(candidate, context)
		end,
		respawnPlayerToLobby = function(
			candidate: Player,
			context: string,
			shouldLoadCharacter: boolean?,
			expectedRespawnToken: number?,
			allowRoundTracked: boolean?
		): boolean
			return RespawnFlow.respawnPlayerToLobby(
				candidate,
				context,
				shouldLoadCharacter,
				expectedRespawnToken,
				allowRoundTracked
			)
		end,
		movePlayerToLobby = movePlayerToLobby,
		getActiveMap = getActiveMap,
		getPlayerTeam = function(candidate: Player): string?
			return playerTeams[candidate]
		end,
		getTeamSpawns = getTeamSpawns,
		getTaggedSpawnParts = getTaggedSpawnParts,
		moveCharacterToSpawn = moveCharacterToSpawn,
		nextSpawnIndex = function(spawnCount: number): number
			return rng:NextInteger(1, spawnCount)
		end,
	})
end

return RoundService
