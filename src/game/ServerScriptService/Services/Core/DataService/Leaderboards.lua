local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Globals = require(ReplicatedStorage.Shared.Config.Lists.Globals)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)

local REFRESH_TIME = 60 * 60
local MAX_ENTRIES = 100
local MAX_ADMIN_STAT_INCREMENT = 1000000
local REMOTE_REQUEST_WINDOW_SECONDS = 10
local REMOTE_MAX_REQUESTS_PER_WINDOW = 30
local REMOTES_FOLDER_NAME = "Remotes"
local GET_LEADERBOARD_REMOTE_NAME = "GetGlobalLeaderboard"
local LEADERBOARD_UPDATED_REMOTE_NAME = "GlobalLeaderboardUpdated"
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
local remoteRequestWindows: { [Player]: { startedAt: number, count: number } } = {}
local started = false
local getLeaderboardRemote: RemoteFunction? = nil
local leaderboardUpdatedRemote: RemoteEvent? = nil

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

local function addUnique(list, seen, value: string)
	if seen[value] then
		return
	end

	seen[value] = true
	table.insert(list, value)
end

local function copyArray(values)
	local copy = {}
	for index, value in ipairs(values or {}) do
		copy[index] = value
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
	return RemoteUtil.EnsureFolder(ReplicatedStorage, REMOTES_FOLDER_NAME)
end

local function ensureGetLeaderboardRemote(): RemoteFunction
	return RemoteUtil.EnsureRemoteFunction(ensureRemotesFolder(), GET_LEADERBOARD_REMOTE_NAME)
end

local function ensureLeaderboardUpdatedRemote(): RemoteEvent
	return RemoteUtil.EnsureRemoteEvent(ensureRemotesFolder(), LEADERBOARD_UPDATED_REMOTE_NAME)
end

local function getStoreName(boardId: string, periodId: string, periodKey: string): string
	return string.format("BBLB_%s_%s_%s_%s", boardId, PERIOD_CONFIGS[periodId].storeSuffix, periodKey, SCOPE)
end

local function getOrderedStore(boardId: string, periodId: string, periodKey: string)
	local storeName = getStoreName(boardId, periodId, periodKey)
	local store = orderedStores[storeName]
	if store then
		return store
	end

	local success, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(storeName)
	end)
	if not success or not result then
		warn("[Leaderboards] Failed to get ordered store:", storeName, result)
		return nil
	end

	store = result
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

local function removeOrderedStoreValue(store, userId: number)
	if not store then
		return
	end

	local success, err = pcall(function()
		store:RemoveAsync(tostring(userId))
	end)
	if not success then
		warn("[Leaderboards] Failed to remove ordered store value:", err)
	end
end

local function publishPlayerStatsForPeriod(dataService, player: Player, periodId: string, unixTime: number, boardIds)
	local periodKey = getPeriodKey(periodId, unixTime)
	for _, boardId in ipairs(boardIds or BOARD_ORDER) do
		local value = getProfileValueForBoard(dataService, player, boardId, periodId, unixTime)
		local store = getOrderedStore(boardId, periodId, periodKey)
		setOrderedStoreValue(store, player.UserId, value)
	end
end

local function publishPlayerStats(dataService, player: Player, boardIds, periodIds, unixTime: number?)
	if not (player and player.Parent == Players) then
		return
	end

	local publishTime = unixTime or getUnixTime()
	for _, periodId in ipairs(periodIds or PERIOD_ORDER) do
		publishPlayerStatsForPeriod(dataService, player, periodId, publishTime, boardIds)
	end
end

local function publishCurrentPlayerStats(dataService, boardIds, periodIds, unixTime: number?)
	for _, player in ipairs(Players:GetPlayers()) do
		publishPlayerStats(dataService, player, boardIds, periodIds, unixTime)
	end
end

local function removePlayerFromCurrentStores(userId: number)
	local unixTime = getUnixTime()

	for _, periodId in ipairs(PERIOD_ORDER) do
		local periodKey = getPeriodKey(periodId, unixTime)
		for _, boardId in ipairs(BOARD_ORDER) do
			local store = getOrderedStore(boardId, periodId, periodKey)
			removeOrderedStoreValue(store, userId)
		end
	end
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

local function applyLeaderboardIncrements(dataService, player: Player, increments, unixTime: number)
	local dailyPeriodKey = getDailyPeriodKey(unixTime)
	local monthlyPeriodKey = getMonthlyPeriodKey(unixTime)

	for _, boardId in ipairs(BOARD_ORDER) do
		local amount = roundNonNegative(increments[boardId])
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
			bucket[boardId] += roundNonNegative(increments[boardId])
		end
		return bucket
	end)

	dataService:Set(player, MONTHLY_STATS_KEY, function(currentValue)
		local bucket = normalizePeriodStats(currentValue, monthlyPeriodKey)
		for _, boardId in ipairs(BOARD_ORDER) do
			bucket[boardId] += roundNonNegative(increments[boardId])
		end
		return bucket
	end)
end

local function parseAdminStatIncrement(statName: string, value: any): (number?, string?)
	if value == nil then
		return 0, nil
	end
	if typeof(value) ~= "number" then
		return nil, statName .. " increment must be a number"
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return nil, statName .. " increment must be finite"
	end
	if value < 0 then
		return nil, statName .. " increment cannot be negative"
	end
	if value ~= math.floor(value) then
		return nil, statName .. " increment must be a whole number"
	end
	if value > MAX_ADMIN_STAT_INCREMENT then
		return nil, statName .. " increment is too large"
	end

	return value, nil
end

local function normalizeAdminStatIncrements(rawIncrements: any): (any?, string?)
	if typeof(rawIncrements) ~= "table" then
		return nil, "Leaderboard stat increments are required"
	end

	local increments = {}
	local total = 0
	for _, boardId in ipairs(BOARD_ORDER) do
		local amount, message = parseAdminStatIncrement(boardId, rawIncrements[boardId])
		if not amount then
			return nil, message
		end

		increments[boardId] = amount
		total += amount
	end

	if total <= 0 then
		return nil, "Leaderboard stat amount must be greater than 0"
	end

	return increments, nil
end

local function formatAdminIncrementMessage(player: Player, increments): string
	local parts = {}
	for _, boardId in ipairs(BOARD_ORDER) do
		local amount = roundNonNegative(increments[boardId])
		if amount > 0 then
			table.insert(parts, ("+%d %s"):format(amount, boardId))
		end
	end

	return ("Added %s to %s's leaderboard data"):format(table.concat(parts, ", "), player.Name)
end

local function isRateLimited(player: Player): boolean
	local now = os.clock()
	local window = remoteRequestWindows[player]
	if not window or now - window.startedAt >= REMOTE_REQUEST_WINDOW_SECONDS then
		remoteRequestWindows[player] = {
			startedAt = now,
			count = 1,
		}
		return false
	end

	if window.count >= REMOTE_MAX_REQUESTS_PER_WINDOW then
		return true
	end

	window.count += 1
	return false
end

local function notifyLeaderboardUpdated(boardIds, periodIds, refreshTime: number)
	local remote = leaderboardUpdatedRemote
	if not remote then
		return
	end

	remote:FireAllClients({
		boards = copyArray(boardIds or BOARD_ORDER),
		periods = copyArray(periodIds or PERIOD_ORDER),
		refreshedAt = refreshTime,
	})
end

local Leaderboards = {}

function Leaderboards.RecordRoundResults(dataService, results)
	if typeof(results) ~= "table" or typeof(results.players) ~= "table" then
		return
	end

	local unixTime = getUnixTime()
	local changedPlayers = {}
	local changedUserIds = {}
	local touchedBoards = {}
	local touchedBoardIds = {}

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

		applyLeaderboardIncrements(dataService, player, increments, unixTime)

		if not changedUserIds[player.UserId] then
			changedUserIds[player.UserId] = true
			table.insert(changedPlayers, player)
		end

		for _, boardId in ipairs(BOARD_ORDER) do
			if roundNonNegative(increments[boardId]) > 0 then
				addUnique(touchedBoards, touchedBoardIds, boardId)
			end
		end
	end

	if #changedPlayers <= 0 or #touchedBoards <= 0 then
		return
	end

	for _, player in ipairs(changedPlayers) do
		publishPlayerStats(dataService, player, touchedBoards, PERIOD_ORDER, unixTime)
	end

	Leaderboards.refresh(dataService, false, touchedBoards, PERIOD_ORDER, unixTime)
end

function Leaderboards.AdminAddStats(dataService, player: Player, rawIncrements): (boolean, string?)
	if not (player and player.Parent == Players) then
		return false, "Target player is unavailable"
	end
	if typeof(dataService:Get(player)) ~= "table" then
		return false, "Target player data is not loaded"
	end

	local increments, message = normalizeAdminStatIncrements(rawIncrements)
	if not increments then
		return false, message
	end

	applyLeaderboardIncrements(dataService, player, increments, getUnixTime())
	publishPlayerStats(dataService, player)
	Leaderboards.refresh(dataService, false)

	return true, formatAdminIncrementMessage(player, increments)
end

function Leaderboards.PublishPlayer(dataService, player: Player)
	publishPlayerStats(dataService, player)
end

function Leaderboards.RemovePlayer(userId: number)
	removePlayerFromCurrentStores(userId)
end

function Leaderboards.refresh(dataService, publishPlayers: boolean?, boardIds, periodIds, unixTime: number?)
	local refreshTime = unixTime or getUnixTime()
	local nextRefreshAt = refreshTime + REFRESH_TIME

	if publishPlayers ~= false then
		publishCurrentPlayerStats(dataService, boardIds, periodIds, refreshTime)
	end

	for _, boardId in ipairs(boardIds or BOARD_ORDER) do
		for _, periodId in ipairs(periodIds or PERIOD_ORDER) do
			local periodKey = getPeriodKey(periodId, refreshTime)
			local entries = getOrderedStoreEntries(boardId, periodId, periodKey)

			setCache(boardId, periodId, {
				board = boardId,
				period = periodId,
				periodKey = periodKey,
				entries = entries,
				nextRefreshAt = nextRefreshAt,
				periodResetsAt = getPeriodResetsAt(periodId, refreshTime),
				refreshedAt = refreshTime,
			})
		end
	end

	notifyLeaderboardUpdated(boardIds, periodIds, refreshTime)
end

function Leaderboards.start(dataService)
	if started then
		return
	end
	started = true

	getLeaderboardRemote = ensureGetLeaderboardRemote()
	leaderboardUpdatedRemote = ensureLeaderboardUpdatedRemote()
	getLeaderboardRemote.OnServerInvoke = function(player, request)
		if isRateLimited(player) then
			return {
				ok = false,
				code = "RateLimited",
			}
		end

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
		local now = getUnixTime()
		local periodKey = getPeriodKey(periodId, now)
		if cache and cache.periodKey ~= periodKey then
			Leaderboards.refresh(dataService, false, { boardId }, { periodId }, now)
			cache = getCache(boardId, periodId)
		end
		if not cache then
			return {
				ok = true,
				board = boardId,
				period = periodId,
				entries = {},
				nextRefreshAt = now + REFRESH_TIME,
				periodKey = periodKey,
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

	Players.PlayerRemoving:Connect(function(player)
		remoteRequestWindows[player] = nil
	end)

	Leaderboards.refresh(dataService)
	task.spawn(function()
		while true do
			task.wait(REFRESH_TIME)
			Leaderboards.refresh(dataService)
		end
	end)
end

return Leaderboards
