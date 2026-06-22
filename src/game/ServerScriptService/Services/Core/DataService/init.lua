local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Globals = require(ReplicatedStorage.Shared.Config.Lists.Globals)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local ProfileService = require(ServerScriptService.Packages.ProfileService)
local ReplicaService = require(ServerScriptService.Packages.ReplicaService)
local Leaderboards = require(script.Leaderboards)

local SCOPE = Globals.SCOPE
local DEBUG = false and RunService:IsStudio()
local USE_MOCK_DATA_IN_STUDIO = false
local PROFILE_CLASS_TOKEN = ReplicaService.NewClassToken(SCOPE)
local TIME_PLAYED_FLUSH_INTERVAL = 30

local CASH_KEY = Schema.Cash and Schema.Cash.key or nil
local TIME_PLAYED_KEY = Schema.TimePlayed and Schema.TimePlayed.key or nil
local GAMES_PLAYED_KEY = Schema.GamesPlayed and Schema.GamesPlayed.key or "gamesPlayed"
local LOSSES_KEY = Schema.Losses and Schema.Losses.key or "losses"
local CURRENT_WIN_STREAK_KEY = Schema.CurrentWinStreak and Schema.CurrentWinStreak.key or "currentWinStreak"
local BEST_WIN_STREAK_KEY = Schema.BestWinStreak and Schema.BestWinStreak.key or "bestWinStreak"
local ABILITY_USAGE_KEY = Schema.AbilityUsage and Schema.AbilityUsage.key or "abilityUsage"

local ATTR_BY_KEY: { [string]: string } = {}
if CASH_KEY then
	ATTR_BY_KEY[CASH_KEY] = "Cash"
end
if TIME_PLAYED_KEY then
	ATTR_BY_KEY[TIME_PLAYED_KEY] = "TimePlayed"
end

local PROFILES: { [Player]: any } = {}
local REPLICAS: { [Player]: any } = {}
local timePlayedSessionStartedAt: { [Player]: number } = {}
local timePlayedLastFlushAt: { [Player]: number } = {}
local timePlayedLoopStarted = false

local GlobalUpdateProcessed = Signal.new()

local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in value do
		copy[key] = deepCopy(child)
	end
	return copy
end

local function roundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue < 0 then
		return 0
	end

	return math.floor(numberValue + 0.5)
end

local function incrementNonNegative(currentValue: any, amount: number?): number
	return roundNonNegative(currentValue) + roundNonNegative(amount or 1)
end

local function getKey(userId: number): string
	return "Player_" .. userId
end

local function isSchemaEntry(value: any): boolean
	return typeof(value) == "table" and value.key ~= nil and value.value ~= nil
end

local function isSchemaContainer(value: any): boolean
	if typeof(value) ~= "table" then
		return false
	end

	local sawAny = false
	for _, child in pairs(value) do
		sawAny = true
		if not isSchemaEntry(child) then
			return false
		end
	end

	return sawAny
end

local function buildStructureFromSchema(schema: any): any
	if not isSchemaContainer(schema) then
		return deepCopy(schema)
	end

	local result = {}
	for _, entry in pairs(schema) do
		local key = entry.key
		local value = entry.value

		if isSchemaEntry(value) then
			result[key] = buildStructureFromSchema({ value })
		elseif isSchemaContainer(value) then
			result[key] = buildStructureFromSchema(value)
		else
			result[key] = deepCopy(value)
		end
	end

	return result
end

local function createLeaderstats(player: Player, profile: any)
	if not CASH_KEY then
		return
	end

	local existing = player:FindFirstChild("leaderstats")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	folder.Parent = player

	local value = Instance.new("StringValue")
	value.Name = "cash"
	value.Value = Globals.formatNumber(tonumber(profile.Data[CASH_KEY]) or 0, true)
	value.Parent = folder
end

local function updateLeaderstatsCash(player: Player, cashValue: number)
	local stats = player:FindFirstChild("leaderstats")
	if not stats then
		return
	end

	local cash = stats:FindFirstChild("cash")
	if cash and cash:IsA("StringValue") then
		cash.Value = Globals.formatNumber(tonumber(cashValue) or 0, true)
	end
end

local function processGlobalUpdates(player: Player, profile: any)
	local globalUpdates = profile.GlobalUpdates

	local function handleLocked(id: number, data: any)
		GlobalUpdateProcessed:Fire(player, profile, data)
		globalUpdates:ClearLockedUpdate(id)
	end

	for _, update in globalUpdates:GetActiveUpdates() do
		globalUpdates:LockActiveUpdate(update[1])
	end

	for _, update in globalUpdates:GetLockedUpdates() do
		handleLocked(update[1], update[2])
	end

	globalUpdates:ListenToNewActiveUpdate(function(id: number)
		globalUpdates:LockActiveUpdate(id)
	end)

	globalUpdates:ListenToNewLockedUpdate(handleLocked)
end

local function createReplica(player: Player, profile: any)
	local replica = ReplicaService.NewReplica({
		ClassToken = PROFILE_CLASS_TOKEN,
		Tags = { Player = player },
		Data = profile.Data,
		Replication = player,
	})

	REPLICAS[player] = replica
end

local function getActiveProfile(player: Player)
	local profile = PROFILES[player]
	if profile and profile:IsActive() then
		return profile
	end
	return nil
end

local function getActiveReplica(player: Player)
	local replica = REPLICAS[player]
	if replica and replica:IsActive() then
		return replica
	end
	return nil
end

local function syncPlayerStateForKey(player: Player, key: string, value: any)
	local attributeName = ATTR_BY_KEY[key]
	if attributeName then
		player:SetAttribute(attributeName, value)
	end

	if CASH_KEY and key == CASH_KEY then
		updateLeaderstatsCash(player, tonumber(value) or 0)
	end
end

local DataService = {}

local function flushTimePlayedForPlayer(player: Player, force: boolean?)
	if not TIME_PLAYED_KEY then
		return
	end

	local lastFlushAt = timePlayedLastFlushAt[player]
	if not lastFlushAt then
		return
	end

	local elapsed = os.clock() - lastFlushAt
	local wholeSeconds = math.max(0, math.floor(elapsed))
	if wholeSeconds <= 0 then
		return
	end
	if not force and wholeSeconds < TIME_PLAYED_FLUSH_INTERVAL then
		return
	end

	timePlayedLastFlushAt[player] = lastFlushAt + wholeSeconds
	DataService:Set(player, TIME_PLAYED_KEY, function(currentValue)
		return math.max(0, tonumber(currentValue) or 0) + wholeSeconds
	end)
end

local function startTimePlayedLoop()
	if timePlayedLoopStarted or not TIME_PLAYED_KEY then
		return
	end

	timePlayedLoopStarted = true
	task.spawn(function()
		while true do
			for _, player in ipairs(Players:GetPlayers()) do
				flushTimePlayedForPlayer(player, false)
			end
			task.wait(TIME_PLAYED_FLUSH_INTERVAL)
		end
	end)
end

local function recordRoundStats(dataService, results)
	if typeof(results) ~= "table" or typeof(results.players) ~= "table" then
		return
	end

	local winnerTeam = if typeof(results.winnerTeam) == "string" then results.winnerTeam else ""
	local hasWinner = winnerTeam ~= "" and winnerTeam ~= "Draw"

	for _, playerResult in ipairs(results.players) do
		if typeof(playerResult) ~= "table" or typeof(playerResult.userId) ~= "number" then
			continue
		end

		local player = Players:GetPlayerByUserId(playerResult.userId)
		if not (player and player.Parent == Players) then
			continue
		end

		dataService:Set(player, GAMES_PLAYED_KEY, incrementNonNegative)

		if not hasWinner then
			continue
		end

		local playerTeam = if typeof(playerResult.teamName) == "string" then playerResult.teamName else ""
		if playerTeam == winnerTeam then
			local nextStreak = roundNonNegative(dataService:Get(player, CURRENT_WIN_STREAK_KEY)) + 1
			dataService:Set(player, CURRENT_WIN_STREAK_KEY, nextStreak)
			dataService:Set(player, BEST_WIN_STREAK_KEY, function(currentValue)
				return math.max(roundNonNegative(currentValue), nextStreak)
			end)
		else
			dataService:Set(player, LOSSES_KEY, incrementNonNegative)
			dataService:Set(player, CURRENT_WIN_STREAK_KEY, 0)
		end
	end
end

local profileStoreName = if DEBUG then "studio" else SCOPE
local profileTemplate = buildStructureFromSchema(Schema)
local profileStore = ProfileService.GetProfileStore(profileStoreName, profileTemplate)
if RunService:IsStudio() and USE_MOCK_DATA_IN_STUDIO then
	profileStore = profileStore.Mock
end

DataService.ProfileStore = profileStore
DataService.GlobalUpdateProcessed = GlobalUpdateProcessed

function DataService:OnStart()
	Leaderboards.start(self)
	startTimePlayedLoop()
end

function DataService:OnPlayerAdded(player: Player)
	local profile = DataService.ProfileStore:LoadProfileAsync(getKey(player.UserId))
	if not profile then
		player:Kick("Sorry! Your data did not load. Please rejoin.")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	profile:ListenToRelease(function()
		PROFILES[player] = nil
		timePlayedSessionStartedAt[player] = nil
		timePlayedLastFlushAt[player] = nil

		local replica = REPLICAS[player]
		if replica then
			replica:Destroy()
			REPLICAS[player] = nil
		end

		if player.Parent == Players then
			player:Kick("Your data has been loaded in a different server.")
		end
	end)

	if DEBUG then
		profile.Data = buildStructureFromSchema(Schema)
	end

	if not player:IsDescendantOf(Players) then
		profile:Release()
		return
	end

	PROFILES[player] = profile
	timePlayedSessionStartedAt[player] = os.clock()
	timePlayedLastFlushAt[player] = os.clock()

	for key, attrName in pairs(ATTR_BY_KEY) do
		player:SetAttribute(attrName, profile.Data[key])
	end

	createReplica(player, profile)
	createLeaderstats(player, profile)
	processGlobalUpdates(player, profile)
end

function DataService:OnPlayerRemoving(player: Player)
	flushTimePlayedForPlayer(player, true)
	Leaderboards.PublishPlayer(self, player)

	local profile = PROFILES[player]
	if profile then
		profile:Release()
	end

	timePlayedSessionStartedAt[player] = nil
	timePlayedLastFlushAt[player] = nil
end

function DataService:Set(player: Player, key: string, mutator: any)
	local replica = getActiveReplica(player)
	if not replica then
		return
	end

	local currentValue = replica.Data[key]
	local newValue = if typeof(mutator) == "function" then mutator(currentValue) else mutator
	replica:SetValue({ key }, newValue)

	syncPlayerStateForKey(player, key, newValue)
end

function DataService:Get(player: Player, key: string?)
	local profile = getActiveProfile(player)
	if profile and profile.Data then
		if key ~= nil then
			return deepCopy(profile.Data[key])
		end
		return deepCopy(profile.Data)
	end

	local timeoutAt = os.clock() + 15
	while os.clock() < timeoutAt do
		if player.Parent ~= Players then
			return nil
		end

		profile = getActiveProfile(player)
		if profile and profile.Data then
			if key ~= nil then
				return deepCopy(profile.Data[key])
			end
			return deepCopy(profile.Data)
		end

		task.wait()
	end

	return nil
end

function DataService:SendGlobalUpdate(sender: Player, targetId: number, updateType: string, payload: any)
	if not sender or not targetId or payload == nil then
		return
	end

	DataService.ProfileStore:GlobalUpdateProfileAsync(getKey(targetId), function(globalUpdates)
		globalUpdates:AddActiveUpdate({
			updateType = updateType,
			senderId = sender.UserId,
			sendTime = os.time(),
			data = payload,
		})
	end)
end

function DataService:ReportLeaderboardRoundResults(results)
	recordRoundStats(self, results)
	Leaderboards.RecordRoundResults(self, results)
end

function DataService:RecordAbilityUsage(player: Player, abilityId: string)
	if not (player and player.Parent == Players) then
		return
	end
	if typeof(abilityId) ~= "string" or abilityId == "" then
		return
	end

	self:Set(player, ABILITY_USAGE_KEY, function(currentValue)
		local usage = if typeof(currentValue) == "table" then deepCopy(currentValue) else {}
		usage[abilityId] = roundNonNegative(usage[abilityId]) + 1
		return usage
	end)
end

function DataService:AdminAddLeaderboardStats(player: Player, increments): (boolean, string?)
	return Leaderboards.AdminAddStats(self, player, increments)
end

local function findLoadedPlayerByUserId(userId: number): Player?
	for player, profile in pairs(PROFILES) do
		if player.UserId == userId and profile and profile:IsActive() then
			return player
		end
	end
	return nil
end

local function waitForProfileRelease(userId: number, timeoutSeconds: number?): (boolean, string?)
	local timeoutAt = os.clock() + (timeoutSeconds or 15)

	while os.clock() < timeoutAt do
		if not findLoadedPlayerByUserId(userId) then
			return true, nil
		end
		task.wait(0.1)
	end

	return false, "Timed out waiting for the player's profile to release"
end

local function wipeProfileByUserId(userId: number): (boolean, string?)
	local resolvedUserId = tonumber(userId)
	if not resolvedUserId then
		return false, "UserId is required"
	end
	resolvedUserId = math.floor(resolvedUserId)

	local loadedPlayer = findLoadedPlayerByUserId(resolvedUserId)
	if loadedPlayer then
		loadedPlayer:Kick("Your data was reset. Please rejoin.")

		local released, releaseError = waitForProfileRelease(resolvedUserId, 15)
		if not released then
			return false, releaseError
		end
	end

	local profileKey = getKey(resolvedUserId)
	local ok, result = pcall(function()
		return DataService.ProfileStore:WipeProfileAsync(profileKey)
	end)
	if not ok then
		return false, tostring(result)
	end
	if result ~= true then
		return false, "WipeProfileAsync returned false"
	end

	Leaderboards.RemovePlayer(resolvedUserId)
	Leaderboards.refresh(DataService, false)
	return true, nil
end

function DataService:OfflineWipe(target: any): (boolean, string?)
	if typeof(target) == "number" then
		local resolvedUserId = math.floor(target)
		if findLoadedPlayerByUserId(resolvedUserId) then
			return false, "Cannot offline wipe a player whose profile is currently loaded in this server"
		end
		return wipeProfileByUserId(resolvedUserId)
	end

	if typeof(target) == "string" then
		local username = string.match(target, "%S+")
		if not username then
			return false, "Username is required"
		end

		local ok, resolvedUserId = pcall(function()
			return Players:GetUserIdFromNameAsync(username)
		end)
		if not ok then
			return false, tostring(resolvedUserId)
		end

		if findLoadedPlayerByUserId(resolvedUserId) then
			return false, "Cannot offline wipe a player whose profile is currently loaded in this server"
		end
		return wipeProfileByUserId(resolvedUserId)
	end

	return false, "Target must be a userId or username"
end

function DataService:WipeByUserId(userId: number): (boolean, string?)
	return wipeProfileByUserId(userId)
end

function DataService:WipeByUsername(username: string): (boolean, string?)
	local ok, resolvedUserId = pcall(function()
		return Players:GetUserIdFromNameAsync(username)
	end)
	if not ok then
		return false, tostring(resolvedUserId)
	end
	return wipeProfileByUserId(resolvedUserId)
end

return DataService
