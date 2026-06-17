local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Globals = require(ReplicatedStorage.Shared.Config.Lists.Globals)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local REFRESH_TIME = 60 * 60
local MAX_ENTRIES = 100
local REMOTES_FOLDER_NAME = "Remotes"
local GET_LEADERBOARD_REMOTE_NAME = "GetGlobalLeaderboard"
local SCOPE = Globals.SCOPE

local LIFETIME_KILLS_KEY = Schema.LifetimeKills and Schema.LifetimeKills.key or "lifetimeKills"
local LIFETIME_WINS_KEY = Schema.LifetimeWins and Schema.LifetimeWins.key or "lifetimeWins"
local LIFETIME_DESTRUCTION_KEY = Schema.LifetimeDestruction and Schema.LifetimeDestruction.key or "lifetimeDestruction"
local DAILY_STATS_KEY = Schema.DailyLeaderboardStats and Schema.DailyLeaderboardStats.key or "dailyLeaderboardStats"
local MONTHLY_STATS_KEY = Schema.MonthlyLeaderboardStats and Schema.MonthlyLeaderboardStats.key or "monthlyLeaderboardStats"

local BOARD_CONFIGS = {
	kills = {
		statName = "kills",
		lifetimeKey = LIFETIME_KILLS_KEY,
	},
	wins = {
		statName = "wins",
		lifetimeKey = LIFETIME_WINS_KEY,
	},
	destruction = {
		statName = "destruction",
		lifetimeKey = LIFETIME_DESTRUCTION_KEY,
	},
}

local PERIOD_CONFIGS = {
	allTime = {
		order = 1,
		storeSuffix = "all",
	},
	monthly = {
		order = 2,
		bucketKey = MONTHLY_STATS_KEY,
		storeSuffix = "month",
	},
	daily = {
		order = 3,
		bucketKey = DAILY_STATS_KEY,
		storeSuffix = "day",
	},
}

local PERIOD_ORDER = { "allTime", "monthly", "daily" }
local BOARD_ORDER = { "kills", "wins", "destruction" }

local usernameCache: { [number]: string } = {}
local orderedStores: { [string]: any } = {}
local cachedLeaderboards: { [string]: { [string]: any } } = {}
local started = false
local getLeaderboardRemote: RemoteFunction? = nil

local function roundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue < 0 then
		return 0
	end
	return math.floor(numberValue + 0.5)
end

local function getUnixTime(): number
	return math.floor(workspace:GetServerTimeNow())
end

local function getUtcDate(unixTime: number)
	return os.date("!*t", unixTime)
end

local function getDailyPeriodKey(unixTime: number): string
	local date = getUtcDate(unixTime)
	return string.format("%04d-%02d-%02d", date.year, date.month, date.day)
end

local function getMonthlyPeriodKey(unixTime: number): string
	local date = getUtcDate(unixTime)
	return string.format("%04d-%02d", date.year, date.month)
end

local function getNextDailyReset(unixTime: number): number
	local date = getUtcDate(unixTime)
	return DateTime.fromUniversalTime(date.year, date.month, date.day, 0, 0, 0).UnixTimestamp + 86400
end

local function getNextMonthlyReset(unixTime: number): number
	local date = getUtcDate(unixTime)
	local year = date.year
	local month = date.month + 1
	if month > 12 then
		year += 1
		month = 1
	end
	return DateTime.fromUniversalTime(year, month, 1, 0, 0, 0).UnixTimestamp
end

local function getPeriodKey(periodId: string, unixTime: number): string
	if periodId == "daily" then
		return getDailyPeriodKey(unixTime)
	end
	if periodId == "monthly" then
		return getMonthlyPeriodKey(unixTime)
	end
	return "all"
end

local function getPeriodResetsAt(periodId: string, unixTime: number): number?
	if periodId == "daily" then
		return getNextDailyReset(unixTime)
	end
	if periodId == "monthly" then
		return getNextMonthlyReset(unixTime)
	end
	return nil
end

local function copyEntries(entries)
	local copy = {}
	for index, entry in ipairs(entries or {}) do
		copy[index] = {
			rank = entry.rank,
			userId = entry.userId,
			username = entry.username,
			value = entry.value,
		}
	end
	return copy
end

local function getUsernameForUserId(userId: number): string
	if usernameCache[userId] then
		return usernameCache[userId]
	end

	local success, result = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if not success or typeof(result) ~= "string" then
		return tostring(userId)
	end

	usernameCache[userId] = result
	return result
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

local function ensureGetLeaderboardRemote(): RemoteFunction
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(GET_LEADERBOARD_REMOTE_NAME)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = GET_LEADERBOARD_REMOTE_NAME
	remote.Parent = folder
	return remote
end

local function getStoreName(boardId: string, periodId: string, periodKey: string): string
	return string.format("BBLB_%s_%s_%s_%s", boardId, PERIOD_CONFIGS[periodId].storeSuffix, periodKey, SCOPE)
end

local function getOrderedStore(boardId: string, periodId: string, periodKey: string)
	if RunService:IsStudio() then
		return nil
	end

	local storeName = getStoreName(boardId, periodId, periodKey)
	local store = orderedStores[storeName]
	if store then
		return store
	end

	store = DataStoreService:GetOrderedDataStore(storeName)
	orderedStores[storeName] = store
	return store
end

local function normalizePeriodStats(value: any, periodKey: string)
	if typeof(value) ~= "table" or value.periodKey ~= periodKey then
		return {
			periodKey = periodKey,
			kills = 0,
			wins = 0,
			destruction = 0,
		}
	end

	return {
		periodKey = periodKey,
		kills = roundNonNegative(value.kills),
		wins = roundNonNegative(value.wins),
		destruction = roundNonNegative(value.destruction),
	}
end

local function getProfileValueForBoard(dataService, player: Player, boardId: string, periodId: string, unixTime: number): number
	local boardConfig = BOARD_CONFIGS[boardId]
	if not boardConfig then
		return 0
	end

	if periodId == "allTime" then
		return roundNonNegative(dataService:Get(player, boardConfig.lifetimeKey))
	end

	local periodConfig = PERIOD_CONFIGS[periodId]
	if not (periodConfig and periodConfig.bucketKey) then
		return 0
	end

	local periodKey = getPeriodKey(periodId, unixTime)
	local bucket = normalizePeriodStats(dataService:Get(player, periodConfig.bucketKey), periodKey)
	return roundNonNegative(bucket[boardConfig.statName])
end

local function setOrderedStoreValue(store, userId: number, value: number)
	if not store or value <= 0 then
		return
	end

	local success, err = pcall(function()
		store:SetAsync(tostring(userId), value)
	end)
	if not success then
		warn("[Leaderboards] Failed to publish ordered store value:", err)
	end
end

local function publishPlayerStatsForPeriod(dataService, player: Player, periodId: string, unixTime: number)
	local periodKey = getPeriodKey(periodId, unixTime)
	for _, boardId in ipairs(BOARD_ORDER) do
		local value = getProfileValueForBoard(dataService, player, boardId, periodId, unixTime)
		local store = getOrderedStore(boardId, periodId, periodKey)
		setOrderedStoreValue(store, player.UserId, value)
	end
end

local function publishPlayerStats(dataService, player: Player)
	if RunService:IsStudio() or not (player and player.Parent == Players) then
		return
	end

	local unixTime = getUnixTime()
	for _, periodId in ipairs(PERIOD_ORDER) do
		publishPlayerStatsForPeriod(dataService, player, periodId, unixTime)
	end
end

local function publishCurrentPlayerStats(dataService)
	if RunService:IsStudio() then
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		publishPlayerStats(dataService, player)
	end
end

local function getCurrentPlayerEntries(dataService, boardId: string, periodId: string, unixTime: number)
	local entries = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local value = getProfileValueForBoard(dataService, player, boardId, periodId, unixTime)
		if value > 0 then
			table.insert(entries, {
				userId = player.UserId,
				username = player.Name,
				value = value,
			})
		end
	end

	table.sort(entries, function(left, right)
		if left.value ~= right.value then
			return left.value > right.value
		end
		return left.userId < right.userId
	end)

	while #entries > MAX_ENTRIES do
		table.remove(entries)
	end

	for rank, entry in ipairs(entries) do
		entry.rank = rank
	end
	return entries
end

local function getOrderedStoreEntries(boardId: string, periodId: string, periodKey: string)
	local store = getOrderedStore(boardId, periodId, periodKey)
	if not store then
		return {}
	end

	local success, pages = pcall(function()
		return store:GetSortedAsync(false, MAX_ENTRIES)
	end)
	if not success or not pages then
		warn("[Leaderboards] Failed to fetch ordered store:", pages)
		return {}
	end

	local entries = {}
	for rank, item in ipairs(pages:GetCurrentPage()) do
		local userId = tonumber(item.key)
		local value = roundNonNegative(item.value)
		if userId and value > 0 then
			table.insert(entries, {
				rank = rank,
				userId = userId,
				username = getUsernameForUserId(userId),
				value = value,
			})
		end
	end

	return entries
end

local function getCache(boardId: string, periodId: string)
	local boardCache = cachedLeaderboards[boardId]
	return boardCache and boardCache[periodId] or nil
end

local function setCache(boardId: string, periodId: string, payload)
	if not cachedLeaderboards[boardId] then
		cachedLeaderboards[boardId] = {}
	end
	cachedLeaderboards[boardId][periodId] = payload
end

local Leaderboards = {}

function Leaderboards.RecordRoundResults(dataService, results)
	if typeof(results) ~= "table" or typeof(results.players) ~= "table" then
		return
	end

	local unixTime = getUnixTime()
	local dailyPeriodKey = getDailyPeriodKey(unixTime)
	local monthlyPeriodKey = getMonthlyPeriodKey(unixTime)

	for _, playerResult in ipairs(results.players) do
		if typeof(playerResult) ~= "table" or typeof(playerResult.userId) ~= "number" then
			continue
		end

		local player = Players:GetPlayerByUserId(playerResult.userId)
		if not (player and player.Parent == Players) then
			continue
		end

		local stats = if typeof(playerResult.stats) == "table" then playerResult.stats else {}
		local increments = {
			kills = roundNonNegative(stats.eliminations),
			wins = if typeof(results.winnerTeam) == "string"
					and results.winnerTeam ~= ""
					and results.winnerTeam ~= "Draw"
					and playerResult.teamName == results.winnerTeam
				then 1
				else 0,
			destruction = roundNonNegative(stats.destruction),
		}

		if increments.kills <= 0 and increments.wins <= 0 and increments.destruction <= 0 then
			continue
		end

		for _, boardId in ipairs(BOARD_ORDER) do
			local amount = increments[boardId]
			if amount > 0 then
				local key = BOARD_CONFIGS[boardId].lifetimeKey
				dataService:Set(player, key, function(currentValue)
					return roundNonNegative(currentValue) + amount
				end)
			end
		end

		dataService:Set(player, DAILY_STATS_KEY, function(currentValue)
			local bucket = normalizePeriodStats(currentValue, dailyPeriodKey)
			for _, boardId in ipairs(BOARD_ORDER) do
				bucket[boardId] += increments[boardId]
			end
			return bucket
		end)

		dataService:Set(player, MONTHLY_STATS_KEY, function(currentValue)
			local bucket = normalizePeriodStats(currentValue, monthlyPeriodKey)
			for _, boardId in ipairs(BOARD_ORDER) do
				bucket[boardId] += increments[boardId]
			end
			return bucket
		end)

	end
end

function Leaderboards.PublishPlayer(dataService, player: Player)
	publishPlayerStats(dataService, player)
end

function Leaderboards.refresh(dataService)
	local unixTime = getUnixTime()
	local nextRefreshAt = unixTime + REFRESH_TIME

	publishCurrentPlayerStats(dataService)

	for _, boardId in ipairs(BOARD_ORDER) do
		for _, periodId in ipairs(PERIOD_ORDER) do
			local periodKey = getPeriodKey(periodId, unixTime)
			local entries = if RunService:IsStudio()
				then getCurrentPlayerEntries(dataService, boardId, periodId, unixTime)
				else getOrderedStoreEntries(boardId, periodId, periodKey)

			setCache(boardId, periodId, {
				board = boardId,
				period = periodId,
				periodKey = periodKey,
				entries = entries,
				nextRefreshAt = nextRefreshAt,
				periodResetsAt = getPeriodResetsAt(periodId, unixTime),
				refreshedAt = unixTime,
			})
		end
	end
end

function Leaderboards.start(dataService)
	if started then
		return
	end
	started = true

	getLeaderboardRemote = ensureGetLeaderboardRemote()
	getLeaderboardRemote.OnServerInvoke = function(_, request)
		if typeof(request) ~= "table" then
			return {
				ok = false,
				code = "InvalidRequest",
			}
		end

		local boardId = request.board
		local periodId = request.period
		if typeof(boardId) ~= "string" or not BOARD_CONFIGS[boardId] then
			return {
				ok = false,
				code = "InvalidBoard",
			}
		end
		if typeof(periodId) ~= "string" or not PERIOD_CONFIGS[periodId] then
			return {
				ok = false,
				code = "InvalidPeriod",
			}
		end

		local cache = getCache(boardId, periodId)
		if not cache then
			local now = getUnixTime()
			return {
				ok = true,
				board = boardId,
				period = periodId,
				entries = {},
				nextRefreshAt = now + REFRESH_TIME,
				periodResetsAt = getPeriodResetsAt(periodId, now),
			}
		end

		return {
			ok = true,
			board = boardId,
			period = periodId,
			periodKey = cache.periodKey,
			entries = copyEntries(cache.entries),
			nextRefreshAt = cache.nextRefreshAt,
			periodResetsAt = cache.periodResetsAt,
			refreshedAt = cache.refreshedAt,
		}
	end

	Leaderboards.refresh(dataService)
	task.spawn(function()
		while true do
			task.wait(REFRESH_TIME)
			Leaderboards.refresh(dataService)
		end
	end)
end

return Leaderboards
