local PlaytimeRewardConfig = {}

PlaytimeRewardConfig.RemotesFolderName = "Remotes"
PlaytimeRewardConfig.RequestRemoteName = "PlaytimeRewardRequest"
PlaytimeRewardConfig.StateRemoteName = "PlaytimeRewardState"
PlaytimeRewardConfig.FrameName = "PlaytimeRewards"

PlaytimeRewardConfig.ProgressTickSeconds = 1
PlaytimeRewardConfig.RewardSource = "PlaytimeReward"

PlaytimeRewardConfig.Actions = table.freeze({
	GetState = "GetState",
	Claim = "Claim",
})

PlaytimeRewardConfig.RewardTypes = table.freeze({
	Cash = "Cash",
	Crate = "Crate",
})

PlaytimeRewardConfig.Tiers = table.freeze({
	table.freeze({
		id = "5m",
		targetSeconds = 5 * 60,
		displayName = "1 Normal Crate",
		reward = table.freeze({
			type = PlaytimeRewardConfig.RewardTypes.Crate,
			crateId = "Basic",
		}),
	}),
	table.freeze({
		id = "10m",
		targetSeconds = 10 * 60,
		displayName = "150 Coins",
		reward = table.freeze({
			type = PlaytimeRewardConfig.RewardTypes.Cash,
			amount = 150,
		}),
	}),
	table.freeze({
		id = "15m",
		targetSeconds = 15 * 60,
		displayName = "250 Coins",
		reward = table.freeze({
			type = PlaytimeRewardConfig.RewardTypes.Cash,
			amount = 250,
		}),
	}),
	table.freeze({
		id = "20m",
		targetSeconds = 20 * 60,
		displayName = "1 Normal Crate",
		reward = table.freeze({
			type = PlaytimeRewardConfig.RewardTypes.Crate,
			crateId = "Basic",
		}),
	}),
	table.freeze({
		id = "25m",
		targetSeconds = 25 * 60,
		displayName = "350 Coins",
		reward = table.freeze({
			type = PlaytimeRewardConfig.RewardTypes.Cash,
			amount = 350,
		}),
	}),
	table.freeze({
		id = "30m",
		targetSeconds = 30 * 60,
		displayName = "1 Premium Crate",
		reward = table.freeze({
			type = PlaytimeRewardConfig.RewardTypes.Crate,
			crateId = "Premium",
		}),
	}),
})

local tiersById = {}
local maxTargetSeconds = 0
for _, tier in ipairs(PlaytimeRewardConfig.Tiers) do
	tiersById[tier.id] = tier
	maxTargetSeconds = math.max(maxTargetSeconds, tier.targetSeconds)
end

function PlaytimeRewardConfig.GetTier(tierId: any)
	if typeof(tierId) ~= "string" then
		return nil
	end
	return tiersById[tierId]
end

function PlaytimeRewardConfig.GetMaxTargetSeconds(): number
	return maxTargetSeconds
end

return table.freeze(PlaytimeRewardConfig)
