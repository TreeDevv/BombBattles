local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CountryTimezoneOffsets = require(ReplicatedStorage.Shared.Config.CountryTimezoneOffsets)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local CrateRollConfig = require(ReplicatedStorage.Shared.Config.CrateRollConfig)
local DailyRewardConfig = require(ReplicatedStorage.Shared.Config.DailyRewardConfig)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local BombSkinService = require(script.Parent.BombSkinService)
local DataService = require(script.Parent.DataService)
local EmoteService = require(script.Parent.EmoteService)

local DAY_SECONDS = 24 * 60 * 60
local CASH_KEY = Schema.Cash and Schema.Cash.key or "cash"
local DAILY_KEY = Schema.DailyRewards and Schema.DailyRewards.key or "dailyRewards"
local CRATE_TOKENS_KEY = Schema.CrateTokens and Schema.CrateTokens.key or "crateTokens"
local MAX_REQUESTS_PER_SECOND = 6

type RegionRecord = {
	countryCode: string,
	utcOffsetMinutes: number,
}

type RequestWindow = {
	startedAt: number,
	count: number,
}

local DailyRewardService = {}

local requestRemote: RemoteFunction? = nil
local stateRemote: RemoteEvent? = nil
local claimLocks: { [Player]: boolean } = {}
local requestWindows: { [Player]: RequestWindow } = {}
local regionByPlayer: { [Player]: RegionRecord } = {}

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

local function normalizeClaimedDays(value: any): { [string]: boolean }
	local claimed = {}
	if typeof(value) ~= "table" then
		return claimed
	end

	for key, isClaimed in pairs(value) do
		local dayNumber = math.floor(tonumber(key) or 0)
		if dayNumber >= 1 and dayNumber <= DailyRewardConfig.MaxDay and isClaimed == true then
			claimed[tostring(dayNumber)] = true
		end
	end
	return claimed
end

local function normalizeCrateTokens(value: any): { [string]: number }
	local tokens = {
		Basic = 0,
		Premium = 0,
		FinisherBasic = 0,
		FinisherPremium = 0,
	}
	if typeof(value) ~= "table" then
		return tokens
	end

	for crateId in pairs(tokens) do
		tokens[crateId] = roundNonNegative(value[crateId])
	end
	return tokens
end

local function normalizeState(value: any, region: RegionRecord, dayInfo)
	local raw = if typeof(value) == "table" then value else {}
	local claimedDays = normalizeClaimedDays(raw.claimedDays)
	local nextDay = DailyRewardConfig.MaxDay + 1
	for day = 1, DailyRewardConfig.MaxDay do
		if claimedDays[tostring(day)] ~= true then
			nextDay = day
			break
		end
	end

	if nextDay > DailyRewardConfig.MaxDay then
		claimedDays = {}
		nextDay = 1
	end

	return {
		claimedDays = claimedDays,
		nextDay = nextDay,
		lastClaimDayKey = if typeof(raw.lastClaimDayKey) == "string" then raw.lastClaimDayKey else "",
		countryCode = region.countryCode,
		utcOffsetMinutes = region.utcOffsetMinutes,
		resetAtUnix = dayInfo.resetAtUnix,
		completed = false,
	}
end

local function isClaimable(state, dayInfo): boolean
	if state.completed == true then
		return false
	end
	if state.nextDay < 1 or state.nextDay > DailyRewardConfig.MaxDay then
		return false
	end
	return state.lastClaimDayKey ~= dayInfo.dayKey
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, DailyRewardConfig.RemotesFolderName)
end

local function ensureRemotes()
	local remotesFolder = ensureRemotesFolder()
	stateRemote = RemoteUtil.EnsureRemoteEvent(remotesFolder, DailyRewardConfig.StateRemoteName)
	requestRemote = RemoteUtil.EnsureRemoteFunction(remotesFolder, DailyRewardConfig.RequestRemoteName)
end

local function addCash(player: Player, amount: number)
	amount = roundNonNegative(amount)
	if amount <= 0 then
		return
	end

	DataService:Set(player, CASH_KEY, function(currentValue)
		return roundNonNegative(currentValue) + amount
	end)
end

local function addCrateToken(player: Player, crateId: string, amount: number)
	local normalizedCrateId = CrateRollConfig.NormalizeCrateId(crateId)
	amount = roundNonNegative(amount)
	if normalizedCrateId == "" or amount <= 0 then
		return
	end

	DataService:Set(player, CRATE_TOKENS_KEY, function(currentValue)
		local tokens = normalizeCrateTokens(currentValue)
		tokens[normalizedCrateId] = roundNonNegative(tokens[normalizedCrateId]) + amount
		return tokens
	end)
end

local function validateRewards(dayDefinition): (boolean, string?)
	for _, reward in ipairs(dayDefinition.rewards or {}) do
		if reward.type == DailyRewardConfig.RewardTypes.CrateToken then
			if not CrateRollConfig.GetDefinition(reward.crateId) then
				return false, "Unknown crate reward: " .. tostring(reward.crateId)
			end
		elseif reward.type == DailyRewardConfig.RewardTypes.Skin then
			if not BombSkinConfig.GetDefinition(reward.skinId) then
				return false, "Unknown skin reward: " .. tostring(reward.skinId)
			end
		elseif reward.type ~= DailyRewardConfig.RewardTypes.Cash
			and reward.type ~= DailyRewardConfig.RewardTypes.RandomEmote
		then
			return false, "Unknown daily reward type."
		end
	end
	return true, nil
end

local function awardRewards(player: Player, dayDefinition): (boolean, string?)
	local valid, validationError = validateRewards(dayDefinition)
	if not valid then
		return false, validationError
	end

	for _, reward in ipairs(dayDefinition.rewards or {}) do
		if reward.type == DailyRewardConfig.RewardTypes.Skin then
			local ownedSkins = BombSkinService:GetOwnedSkins(player)
			local skinId = BombSkinConfig.NormalizeSkinId(reward.skinId)
			if ownedSkins[skinId] == true and reward.duplicateFallbackCash ~= nil then
				addCash(player, reward.duplicateFallbackCash)
			else
				local ok, result = BombSkinService:GrantSkin(
					player,
					reward.skinId,
					("%s:%d"):format(DailyRewardConfig.RewardSource, dayDefinition.day)
				)
				if not ok then
					return false, tostring(result or "Skin reward failed.")
				end
			end
		elseif reward.type == DailyRewardConfig.RewardTypes.RandomEmote then
			local ok, result = EmoteService:GrantRandomEmote(
				player,
				("%s:%d"):format(DailyRewardConfig.RewardSource, dayDefinition.day)
			)
			if not ok and tostring(result) ~= "All emotes are already owned" then
				return false, tostring(result or "Emote reward failed.")
			end
		end
	end

	for _, reward in ipairs(dayDefinition.rewards or {}) do
		if reward.type == DailyRewardConfig.RewardTypes.Cash then
			addCash(player, reward.amount)
		elseif reward.type == DailyRewardConfig.RewardTypes.CrateToken then
			addCrateToken(player, reward.crateId, reward.amount)
		end
	end

	return true, nil
end

local function getCrateTokens(player: Player)
	return normalizeCrateTokens(DataService:Get(player, CRATE_TOKENS_KEY))
end

local function buildStatePayload(player: Player)
	local region = getRegionRecord(player)
	local dayInfo = getDayInfo(getUnixTime(), region.utcOffsetMinutes)
	local state = normalizeState(DataService:Get(player, DAILY_KEY), region, dayInfo)
	local canClaim = isClaimable(state, dayInfo)

	return {
		dayKey = dayInfo.dayKey,
		resetAtUnix = dayInfo.resetAtUnix,
		countryCode = region.countryCode,
		utcOffsetMinutes = region.utcOffsetMinutes,
		claimedDays = state.claimedDays,
		nextDay = state.nextDay,
		claimableDay = if canClaim then state.nextDay else 0,
		canClaim = canClaim,
		completed = state.completed == true,
		days = DailyRewardConfig.GetDaysPayload(),
		crateTokens = getCrateTokens(player),
	}
end

local function fireState(player: Player)
	local remote = stateRemote
	if remote and player.Parent == Players then
		remote:FireClient(player, buildStatePayload(player))
	end
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

local function response(ok: boolean, code: string, message: string?, state)
	return {
		ok = ok,
		code = code,
		message = message,
		state = state,
	}
end

local function claimNextDay(player: Player)
	if claimLocks[player] then
		return response(false, "Busy", "Please wait.", buildStatePayload(player))
	end
	if isRateLimited(player) then
		return response(false, "RateLimited", "Please wait.", buildStatePayload(player))
	end

	claimLocks[player] = true
	local ok, result = pcall(function()
		local region = getRegionRecord(player)
		local dayInfo = getDayInfo(getUnixTime(), region.utcOffsetMinutes)
		local state = normalizeState(DataService:Get(player, DAILY_KEY), region, dayInfo)
		if state.completed == true then
			return response(false, "Complete", "All daily rewards claimed.", buildStatePayload(player))
		end
		if not isClaimable(state, dayInfo) then
			return response(false, "NotReady", "Come back tomorrow for the next reward.", buildStatePayload(player))
		end

		local dayDefinition = DailyRewardConfig.GetDay(state.nextDay)
		if not dayDefinition then
			return response(false, "UnknownDay", "Daily reward is unavailable.", buildStatePayload(player))
		end

		local awarded, awardError = awardRewards(player, dayDefinition)
		if not awarded then
			warn(("[DailyRewardService] Failed to grant day %d to %s: %s"):format(
				state.nextDay,
				player.Name,
				tostring(awardError)
			))
			return response(false, "GrantFailed", "Daily reward is unavailable right now.", buildStatePayload(player))
		end

		DataService:Set(player, DAILY_KEY, function(currentValue)
			local latestState = normalizeState(currentValue, region, dayInfo)
			latestState.claimedDays[tostring(state.nextDay)] = true
			latestState.lastClaimDayKey = dayInfo.dayKey
			if state.nextDay >= DailyRewardConfig.MaxDay then
				latestState.claimedDays = {}
				latestState.nextDay = 1
				latestState.completed = false
			else
				latestState.nextDay = state.nextDay + 1
				latestState.completed = false
			end
			return latestState
		end)

		Notify.Send(player, "Daily reward claimed: " .. tostring(dayDefinition.displayText), { color = "Green" })
		return response(true, "Claimed", "Daily reward claimed.", buildStatePayload(player))
	end)
	claimLocks[player] = nil

	if not ok then
		warn(("[DailyRewardService] Claim failed for %s: %s"):format(player.Name, tostring(result)))
		return response(false, "Error", "Daily reward is unavailable right now.", buildStatePayload(player))
	end

	fireState(player)
	return result
end

local function handleInvoke(player: Player, request: any)
	if typeof(request) ~= "table" then
		return response(false, "BadRequest", "Bad request.", buildStatePayload(player))
	end

	if request.action == DailyRewardConfig.Actions.GetState then
		return response(true, "State", "OK", buildStatePayload(player))
	elseif request.action == DailyRewardConfig.Actions.Claim then
		return claimNextDay(player)
	end

	return response(false, "UnknownAction", "Unknown daily reward action.", buildStatePayload(player))
end

function DailyRewardService:OnStart()
	ensureRemotes()
	if requestRemote then
		requestRemote.OnServerInvoke = handleInvoke
	end
end

function DailyRewardService:OnPlayerAdded(player: Player)
	task.spawn(function()
		buildStatePayload(player)
		fireState(player)
	end)
end

function DailyRewardService:OnPlayerRemoving(player: Player)
	claimLocks[player] = nil
	requestWindows[player] = nil
	regionByPlayer[player] = nil
end

return DailyRewardService
