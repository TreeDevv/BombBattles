local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CountryTimezoneOffsets = require(ReplicatedStorage.Shared.Config.CountryTimezoneOffsets)
local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local DataService = require(ServerScriptService.Services.DataService)

local DAY_SECONDS = 24 * 60 * 60
local QUESTS_KEY = Schema.Quests and Schema.Quests.key or "quests"
local CASH_KEY = Schema.Cash and Schema.Cash.key or "cash"
local MAX_REQUESTS_PER_SECOND = 8

type RequestWindow = {
	startedAt: number,
	count: number,
}

type RegionRecord = {
	countryCode: string,
	utcOffsetMinutes: number,
}

local QuestService = {}

local requestRemote: RemoteEvent? = nil
local requestWindows: { [Player]: RequestWindow } = {}
local regionByPlayer: { [Player]: RegionRecord } = {}

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, QuestConfig.RemotesFolderName)
end

local function ensureRequestRemote(): RemoteEvent
	return RemoteUtil.EnsureRemoteEvent(ensureRemotesFolder(), QuestConfig.RequestRemoteName)
end

local function getUnixTime(): number
	return math.floor(workspace:GetServerTimeNow())
end

local function roundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue < 0 then
		return 0
	end
	return math.floor(numberValue + 0.5)
end

local function getDayIndex(unixTime: number, utcOffsetMinutes: number): number
	return math.floor((unixTime + utcOffsetMinutes * 60) / DAY_SECONDS)
end

local function getDayKey(dayIndex: number): string
	return os.date("!%Y-%m-%d", dayIndex * DAY_SECONDS)
end

local function getResetAtUnix(dayIndex: number, utcOffsetMinutes: number): number
	return (dayIndex + 1) * DAY_SECONDS - utcOffsetMinutes * 60
end

local function getDayInfo(unixTime: number, utcOffsetMinutes: number)
	local dayIndex = getDayIndex(unixTime, utcOffsetMinutes)
	return {
		dayIndex = dayIndex,
		dayKey = getDayKey(dayIndex),
		resetAtUnix = getResetAtUnix(dayIndex, utcOffsetMinutes),
	}
end

local function copyProgressForActiveQuests(dayKey: string, source)
	local progress = {}
	for _, questId in ipairs(QuestConfig.GetActiveQuestIds(dayKey)) do
		progress[questId] = roundNonNegative(if typeof(source) == "table" then source[questId] else 0)
	end
	return progress
end

local function copyClaimedForActiveQuests(dayKey: string, source)
	local claimed = {}
	for _, questId in ipairs(QuestConfig.GetActiveQuestIds(dayKey)) do
		claimed[questId] = if typeof(source) == "table" then source[questId] == true else false
	end
	return claimed
end

local function buildFreshState(countryCode: string, utcOffsetMinutes: number, unixTime: number)
	local dayInfo = getDayInfo(unixTime, utcOffsetMinutes)
	return {
		dayKey = dayInfo.dayKey,
		countryCode = countryCode,
		utcOffsetMinutes = utcOffsetMinutes,
		resetAtUnix = dayInfo.resetAtUnix,
		progress = copyProgressForActiveQuests(dayInfo.dayKey, nil),
		claimed = copyClaimedForActiveQuests(dayInfo.dayKey, nil),
	}
end

local function normalizeState(currentValue, countryCode: string, utcOffsetMinutes: number, unixTime: number)
	local dayInfo = getDayInfo(unixTime, utcOffsetMinutes)
	if typeof(currentValue) ~= "table" or currentValue.dayKey ~= dayInfo.dayKey then
		return buildFreshState(countryCode, utcOffsetMinutes, unixTime)
	end

	return {
		dayKey = dayInfo.dayKey,
		countryCode = countryCode,
		utcOffsetMinutes = utcOffsetMinutes,
		resetAtUnix = dayInfo.resetAtUnix,
		progress = copyProgressForActiveQuests(dayInfo.dayKey, currentValue.progress),
		claimed = copyClaimedForActiveQuests(dayInfo.dayKey, currentValue.claimed),
	}
end

local function getRegionRecord(player: Player): RegionRecord
	local cached = regionByPlayer[player]
	if cached then
		return cached
	end

	local countryCode = ""
	local ok, result = pcall(function()
		return LocalizationService:GetCountryRegionForPlayerAsync(player)
	end)
	if ok and typeof(result) == "string" then
		countryCode = string.upper(result)
	end

	local record = {
		countryCode = countryCode,
		utcOffsetMinutes = CountryTimezoneOffsets.GetOffsetMinutes(countryCode),
	}
	regionByPlayer[player] = record
	return record
end

local function isRateLimited(player: Player): boolean
	local now = os.clock()
	local window = requestWindows[player]
	if not window or now - window.startedAt >= 1 then
		requestWindows[player] = {
			startedAt = now,
			count = 1,
		}
		return false
	end

	window.count += 1
	return window.count > MAX_REQUESTS_PER_SECOND
end

local function fireResponse(player: Player, payload)
	local remote = requestRemote
	if remote then
		remote:FireClient(player, payload)
	end
end

local function fail(player: Player, request, code: string, message: string?)
	fireResponse(player, {
		action = if typeof(request) == "table" then request.action else nil,
		questId = if typeof(request) == "table" then request.questId else nil,
		ok = false,
		code = code,
		message = message,
	})
end

local function addQuestProgress(state, incrementsByMetric)
	local changed = false
	local progress = state.progress

	for _, questId in ipairs(QuestConfig.GetActiveQuestIds(state.dayKey)) do
		local definition = QuestConfig.GetDefinition(questId)
		local increment = if definition then roundNonNegative(incrementsByMetric[definition.metric]) else 0
		if increment <= 0 then
			continue
		end

		local target = roundNonNegative(definition.target)
		local current = roundNonNegative(progress[questId])
		local nextValue = if target > 0 then math.min(target, current + increment) else current + increment
		if nextValue ~= current then
			progress[questId] = nextValue
			changed = true
		end
	end

	return changed
end

local function resolveClaimRequest(request)
	if typeof(request) ~= "table" or request.action ~= QuestConfig.Actions.Claim then
		return nil
	end

	local questId = QuestConfig.NormalizeQuestId(request.questId)
	if questId == "" or not QuestConfig.GetDefinition(questId) then
		return nil
	end

	return {
		action = request.action,
		questId = questId,
	}
end

function QuestService:_reconcilePlayer(player: Player)
	if not (player and player.Parent == Players) then
		return nil
	end

	DataService:Get(player, QUESTS_KEY)
	if not (player and player.Parent == Players) then
		return nil
	end

	local region = getRegionRecord(player)
	local normalizedState = nil
	DataService:Set(player, QUESTS_KEY, function(currentValue)
		normalizedState = normalizeState(currentValue, region.countryCode, region.utcOffsetMinutes, getUnixTime())
		return normalizedState
	end)

	return normalizedState
end

function QuestService:_handleClaim(player: Player, rawRequest)
	if isRateLimited(player) then
		return
	end

	local request = resolveClaimRequest(rawRequest)
	if not request then
		fail(player, rawRequest, "InvalidRequest", "Invalid quest request.")
		return
	end

	local region = getRegionRecord(player)
	local unixTime = getUnixTime()
	local definition = QuestConfig.GetDefinition(request.questId)
	local shouldAward = false
	local awardCash = 0
	local responseState = nil

	DataService:Set(player, QUESTS_KEY, function(currentValue)
		local state = normalizeState(currentValue, region.countryCode, region.utcOffsetMinutes, unixTime)
		responseState = state

		if not QuestConfig.IsActiveQuest(state.dayKey, request.questId) then
			return state
		end
		if state.claimed[request.questId] == true then
			return state
		end

		local progress = roundNonNegative(state.progress[request.questId])
		local target = roundNonNegative(definition.target)
		if target <= 0 or progress < target then
			return state
		end

		state.claimed[request.questId] = true
		shouldAward = true
		awardCash = roundNonNegative(definition.rewardCash)
		return state
	end)

	if shouldAward and awardCash > 0 then
		DataService:Set(player, CASH_KEY, function(currentValue)
			return roundNonNegative(currentValue) + awardCash
		end)
	end

	fireResponse(player, {
		action = QuestConfig.Actions.Claim,
		questId = request.questId,
		ok = shouldAward,
		code = if shouldAward then "Claimed" else "NotClaimable",
		state = responseState,
	})
end

function QuestService:ReportRoundResults(results)
	if typeof(results) ~= "table" or typeof(results.players) ~= "table" then
		return
	end

	local durationSeconds = roundNonNegative(results.durationSeconds)
	for _, playerResult in ipairs(results.players) do
		if typeof(playerResult) ~= "table" or typeof(playerResult.userId) ~= "number" then
			continue
		end

		local player = Players:GetPlayerByUserId(playerResult.userId)
		if not (player and player.Parent == Players) then
			continue
		end

		local stats = if typeof(playerResult.stats) == "table" then playerResult.stats else {}
		local won = typeof(results.winnerTeam) == "string"
			and results.winnerTeam ~= ""
			and results.winnerTeam ~= "Draw"
			and playerResult.teamName == results.winnerTeam

		local incrementsByMetric = {
			[QuestConfig.Metrics.RoundsPlayed] = 1,
			[QuestConfig.Metrics.Wins] = if won then 1 else 0,
			[QuestConfig.Metrics.Eliminations] = roundNonNegative(stats.eliminations),
			[QuestConfig.Metrics.Damage] = roundNonNegative(stats.damage),
			[QuestConfig.Metrics.Destruction] = roundNonNegative(stats.destruction),
			[QuestConfig.Metrics.TimePlayed] = durationSeconds,
		}

		local region = getRegionRecord(player)
		local unixTime = getUnixTime()
		DataService:Set(player, QUESTS_KEY, function(currentValue)
			local state = normalizeState(currentValue, region.countryCode, region.utcOffsetMinutes, unixTime)
			addQuestProgress(state, incrementsByMetric)
			return state
		end)
	end
end

function QuestService:OnStart()
	requestRemote = ensureRequestRemote()
	requestRemote.OnServerEvent:Connect(function(player, request)
		self:_handleClaim(player, request)
	end)
end

function QuestService:OnPlayerAdded(player: Player)
	task.spawn(function()
		self:_reconcilePlayer(player)
	end)
end

function QuestService:OnPlayerRemoving(player: Player)
	requestWindows[player] = nil
	regionByPlayer[player] = nil
end

return QuestService
