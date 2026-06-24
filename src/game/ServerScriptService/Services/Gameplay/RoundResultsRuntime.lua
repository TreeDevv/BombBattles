local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

local RoundResultsRuntime = {}

local CASH_KEY = "cash"

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

function RoundResultsRuntime.RoundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue < 0 then
		return 0
	end

	return math.floor(numberValue + 0.5)
end

function RoundResultsRuntime.GetMapDisplayName(mapId: string, getConfiguredMap): string
	local mapConfig = if typeof(getConfiguredMap) == "function" then getConfiguredMap(mapId) else nil
	if mapConfig and typeof(mapConfig.displayName) == "string" and mapConfig.displayName ~= "" then
		return mapConfig.displayName
	end

	return mapId
end

local function getRewardAmount(rewards, primaryKey: string, fallbackKey: string?): number
	local value = rewards[primaryKey]
	if value == nil and fallbackKey then
		value = rewards[fallbackKey]
	end
	return RoundResultsRuntime.RoundNonNegative(value)
end

function RoundResultsRuntime.CalculateReward(stats, winnerTeam: string, playerTeam: string?, earnedPOTG: boolean?)
	local rewards = RoundConfig.Rewards or {}
	local damage = RoundResultsRuntime.RoundNonNegative(stats and stats.damage)
	local eliminations = RoundResultsRuntime.RoundNonNegative(stats and stats.eliminations)
	local assists = RoundResultsRuntime.RoundNonNegative(stats and stats.assists)
	local completeMatchCoins = getRewardAmount(rewards, "CompleteMatchCoins", "ParticipationCoins")
	local eliminationCoins = eliminations * getRewardAmount(rewards, "EliminationCoins")
	local assistCoins = assists * getRewardAmount(rewards, "AssistCoins")
	local winCoins = 0
	local potgCoins = if earnedPOTG == true then getRewardAmount(rewards, "POTGCoins") else 0
	local damageCoins = math.floor(damage / 100) * getRewardAmount(rewards, "DamageCoinsPer100")

	if winnerTeam ~= "Draw" and playerTeam == winnerTeam then
		winCoins = getRewardAmount(rewards, "WinCoins")
	end

	local baseCoins = completeMatchCoins + eliminationCoins + assistCoins + winCoins + potgCoins + damageCoins

	local vipBonusMultiplier = tonumber(rewards.VipBonusMultiplier) or 0
	local vipBonusCoins = if vipBonusMultiplier > 0 then math.floor(baseCoins * vipBonusMultiplier + 0.5) else 0

	return {
		completeMatchCoins = completeMatchCoins,
		eliminationCoins = eliminationCoins,
		assistCoins = assistCoins,
		winCoins = winCoins,
		potgCoins = potgCoins,
		damageCoins = damageCoins,
		baseCoins = baseCoins,
		vipBonusCoins = vipBonusCoins,
		totalCoins = baseCoins + vipBonusCoins,
		earnedPOTG = earnedPOTG == true,
	}
end

function RoundResultsRuntime.Build(options)
	local winnerTeam = options.winnerTeam
	local selectedMapId = if typeof(options.selectedMapId) == "string" then options.selectedMapId else ""
	local results = {
		roundId = options.roundId,
		winnerTeam = winnerTeam,
		selectedMapId = selectedMapId,
		mapDisplayName = RoundResultsRuntime.GetMapDisplayName(selectedMapId, options.getConfiguredMap),
		durationSeconds = RoundResultsRuntime.RoundNonNegative(os.clock() - (tonumber(options.activeRoundStartedAt) or os.clock())),
		potgWinnerUserId = if typeof(options.potgWinnerUserId) == "number" then math.floor(options.potgWinnerUserId) else nil,
		players = {},
	}

	for player in pairs(options.roundPlayers or {}) do
		if player.Parent == Players then
			local playerKey = tostring(player.UserId)
			local playerTeam = if typeof(options.getTrackedTeamName) == "function" then options.getTrackedTeamName(player) else nil
			local stats = if typeof(options.getScoreboardStatsFor) == "function" then deepCopy(options.getScoreboardStatsFor(player)) else {}
			local platform = options.scoreboardPlatforms and options.scoreboardPlatforms[playerKey]

			local earnedPOTG = typeof(options.potgWinnerUserId) == "number" and options.potgWinnerUserId == player.UserId
			table.insert(results.players, {
				userId = player.UserId,
				name = player.Name,
				displayName = player.DisplayName,
				teamName = playerTeam or "",
				platform = if typeof(platform) == "string" then platform else "KeyboardAndMouse",
				stats = stats,
				rewards = RoundResultsRuntime.CalculateReward(stats, winnerTeam, playerTeam, earnedPOTG),
			})
		end
	end

	return results
end

function RoundResultsRuntime.Award(results, options)
	local rewardedRoundIds = options.rewardedRoundIds
	if rewardedRoundIds and rewardedRoundIds[results.roundId] then
		return
	end
	if rewardedRoundIds then
		rewardedRoundIds[results.roundId] = true
	end

	local dataService = options.dataService
	if not dataService then
		return
	end

	for _, playerResult in ipairs(results.players) do
		local player = Players:GetPlayerByUserId(playerResult.userId)
		local rewards = playerResult.rewards
		local totalCoins = if typeof(rewards) == "table" then RoundResultsRuntime.RoundNonNegative(rewards.totalCoins) else 0
		if player and totalCoins > 0 then
			dataService:Set(player, options.cashKey or CASH_KEY, function(currentValue)
				return RoundResultsRuntime.RoundNonNegative(currentValue) + totalCoins
			end)
		end
	end
end

function RoundResultsRuntime.Publish(options)
	local results = RoundResultsRuntime.Build(options)
	RoundResultsRuntime.Award(results, options)
	if options.dataService then
		options.dataService:ReportLeaderboardRoundResults(results)
	end
	if options.questService then
		options.questService:ReportRoundResults(results)
	end
	return results
end

return table.freeze(RoundResultsRuntime)
