local FriendRewardConfig = {}

FriendRewardConfig.RemotesFolderName = "Remotes"
FriendRewardConfig.OpenRemoteName = "FriendRewardsOpen"
FriendRewardConfig.StateRemoteName = "FriendRewardsState"
FriendRewardConfig.RequestRemoteName = "FriendRewardsRequest"

FriendRewardConfig.FrameName = "FriendRewards"
FriendRewardConfig.ProgressTickSeconds = 1
FriendRewardConfig.ProgressFlushSeconds = 10
FriendRewardConfig.FriendListRetrySeconds = 30
FriendRewardConfig.InvitePromptMessage = "Join me in Bomb Battles!"

FriendRewardConfig.Actions = table.freeze({
	GetState = "GetState",
	UpdateFriends = "UpdateFriends",
	Claim = "Claim",
})

FriendRewardConfig.RewardSource = "FriendReward"
FriendRewardConfig.RewardCrateId = "Basic"
FriendRewardConfig.RewardRollCount = 3

FriendRewardConfig.Tiers = table.freeze({
	table.freeze({
		id = "10m",
		targetSeconds = 10 * 60,
		displayName = "10 mins",
	}),
	table.freeze({
		id = "20m",
		targetSeconds = 20 * 60,
		displayName = "20 mins",
	}),
	table.freeze({
		id = "30m",
		targetSeconds = 30 * 60,
		displayName = "30 mins",
	}),
})

local tiersById = {}
local maxTargetSeconds = 0
for _, tier in ipairs(FriendRewardConfig.Tiers) do
	tiersById[tier.id] = tier
	maxTargetSeconds = math.max(maxTargetSeconds, tier.targetSeconds)
end

function FriendRewardConfig.GetTier(tierId: any)
	if typeof(tierId) ~= "string" then
		return nil
	end

	return tiersById[tierId]
end

function FriendRewardConfig.GetMaxTargetSeconds(): number
	return maxTargetSeconds
end

return table.freeze(FriendRewardConfig)
