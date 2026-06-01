local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Teams = game:GetService("Teams")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local ReplicaService = require(ServerScriptService.Packages.ReplicaService)

local TEAM_ORDER = { RoundConfig.Teams.Red.name, RoundConfig.Teams.Blue.name }
local REMOTES_FOLDER_NAME = "Remotes"
local SUBMIT_MAP_VOTE_REMOTE_NAME = "SubmitMapVote"
local ROUND_ID_ATTR = "RoundId"
local ROUND_TEAM_ATTR = "RoundTeam"
local ROUND_ALIVE_ATTR = "RoundAlive"
local CORE_HEALTH_ATTR = RoundConfig.Cores.HealthAttribute
local CORE_DESTROYED_ATTR = RoundConfig.Cores.DestroyedAttribute

local GAME_STATE_TOKEN = ReplicaService.NewClassToken(RoundConfig.Scope)

type MapConfig = {
	id: string,
	displayName: string,
}

local RoundService = {}

local gameReplica = nil
local submitMapVoteRemote: RemoteEvent? = nil
local running = false
local roundId = 0
local currentState = RoundStates.WaitingForPlayers
local votingOpen = false
local currentChoices: { MapConfig } = {}
local voteCounts: { [string]: number } = {}
local playerVotes: { [Player]: string } = {}
local roundPlayers: { [Player]: boolean } = {}
local alivePlayers: { [Player]: boolean } = {}
local playerTeams: { [Player]: string } = {}
local characterConnections: { [Player]: { RBXScriptConnection } } = {}
local lobbyCharacterConnections: { [Player]: RBXScriptConnection } = {}
local teamCoreInstances: { [string]: { Instance } } = {}
local coreConnections: { [Instance]: { RBXScriptConnection } } = {}
local rng = Random.new()

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

local function setReplicaValue(path: { any }, value: any)
	if gameReplica then
		gameReplica:SetValue(path, value)
	end
end

local function setState(state: string, status: string?, duration: number?)
	currentState = state
	setReplicaValue({ "state" }, state)
	setReplicaValue({ "status" }, status or state)
	setReplicaValue({ "endsAt" }, if duration and duration > 0 then workspace:GetServerTimeNow() + duration else 0)
	setReplicaValue({ "minPlayers" }, getRequiredPlayerCount())
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

local function getConfiguredMap(mapId: string): MapConfig?
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

local function clearPlayerRoundState(player: Player)
	player:SetAttribute(ROUND_ID_ATTR, nil)
	player:SetAttribute(ROUND_TEAM_ATTR, nil)
	player:SetAttribute(ROUND_ALIVE_ATTR, nil)
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
	local connection = lobbyCharacterConnections[player]
	if connection then
		connection:Disconnect()
		lobbyCharacterConnections[player] = nil
	end
end

local function bindLobbyCharacter(player: Player)
	disconnectLobbyCharacterConnection(player)

	lobbyCharacterConnections[player] = player.CharacterAdded:Connect(function()
		task.defer(function()
			if currentState == RoundStates.Active and roundPlayers[player] and alivePlayers[player] then
				return
			end

			movePlayerToLobby(player)
		end)
	end)
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
		return
	end

	alivePlayers[player] = nil
	player:SetAttribute(ROUND_ALIVE_ATTR, false)
	syncAliveCounts()

	task.defer(function()
		if player.Parent == Players then
			player:LoadCharacter()
		end
	end)
end

local function respawnPlayerInRound(player: Player)
	player:SetAttribute(ROUND_ALIVE_ATTR, true)

	task.defer(function()
		if player.Parent == Players and currentState == RoundStates.Active and alivePlayers[player] then
			player:LoadCharacter()
		end
	end)
end

local function handlePlayerDeath(player: Player)
	if not alivePlayers[player] then
		return
	end

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
	setReplicaValue({ "roundId" }, roundId)
	setReplicaValue({ "selectedMapId" }, "")
	setWinner("")
	syncAliveCounts()
	syncCoreState()
end

local function waitForSecondsOrInvalid(seconds: number, requireMinPlayers: boolean): boolean
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		if requireMinPlayers and #Players:GetPlayers() < getRequiredPlayerCount() then
			return false
		end
		task.wait(0.2)
	end
	return true
end

local function endRound(winnerTeam: string)
	setWinner(winnerTeam)
	setState(RoundStates.RoundEnding, if winnerTeam == "Draw" then "Draw" else winnerTeam .. " wins", RoundConfig.ResetSeconds)
	task.wait(RoundConfig.ResetSeconds)
end

local function runActiveRound()
	setState(RoundStates.Active, "Battle", RoundConfig.RoundSeconds)
	local deadline = os.clock() + RoundConfig.RoundSeconds

	while os.clock() < deadline do
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
	resetPlayersToLobby()
	clearActiveMap()
	clearAllRoundTracking()
	setReplicaValue({ "selectedMapId" }, "")
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
		local requiredPlayerCount = getRequiredPlayerCount()
		if #Players:GetPlayers() < requiredPlayerCount then
			setState(RoundStates.WaitingForPlayers, "Waiting for players", 0)
			setVotingOpen(false)
			task.wait(1)
			continue
		end

		if not ensureTeamsReady() then
			setState(RoundStates.WaitingForPlayers, "Waiting for setup", 0)
			task.wait(3)
			continue
		end

		currentChoices = chooseVoteOptions()
		if #currentChoices == 0 then
			setState(RoundStates.WaitingForPlayers, "Waiting for maps", 0)
			task.wait(3)
			continue
		end

		createNewRound()
		playerVotes = {}
		voteCounts = {}
		syncVoteChoices()
		setVotingOpen(true)
		setState(RoundStates.Intermission, "Intermission", RoundConfig.IntermissionSeconds)

		if not waitForSecondsOrInvalid(RoundConfig.IntermissionSeconds, true) then
			cancelToWaiting("Round cancelled because not enough players remain")
			continue
		end

		setVotingOpen(false)
		local selectedMapId = chooseWinningMap()
		if not selectedMapId or not getConfiguredMap(selectedMapId) then
			cancelToWaiting("Round cancelled because no voted map could be selected")
			continue
		end

		setReplicaValue({ "selectedMapId" }, selectedMapId)
		setState(RoundStates.AssigningTeams, "Assigning teams", 0)

		local roster = getEligiblePlayers()
		if #roster < getRequiredPlayerCount() then
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

function RoundService:OnStart()
	createGameReplica()
	submitMapVoteRemote = ensureVoteRemote()
	submitMapVoteRemote.OnServerEvent:Connect(onSubmitMapVote)

	for _, player in ipairs(Players:GetPlayers()) do
		bindLobbyCharacter(player)
		movePlayerToLobby(player)
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
		movePlayerToLobby(player)
	end)
end

function RoundService:OnPlayerRemoving(player: Player)
	playerVotes[player] = nil
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

function RoundService:DamageCore(core: Instance, damage: number): boolean
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

	local humanoid = trackedCore:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:TakeDamage(damage)
		syncCoreState()
		return true
	end

	local health = trackedCore:GetAttribute(CORE_HEALTH_ATTR)
	if typeof(health) ~= "number" then
		health = RoundConfig.Cores.DefaultHealth
	end

	health -= damage
	trackedCore:SetAttribute(CORE_HEALTH_ATTR, math.max(health, 0))
	if health <= 0 then
		trackedCore:SetAttribute(CORE_DESTROYED_ATTR, true)
	end

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

return RoundService
