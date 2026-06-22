local GroupRewardConfig = {}

GroupRewardConfig.RemotesFolderName = "Remotes"
GroupRewardConfig.PromptRemoteName = "GroupRewardPrompt"
GroupRewardConfig.PromptResultRemoteName = "GroupRewardPromptResult"

GroupRewardConfig.GroupId = 0
GroupRewardConfig.InteractionCooldownSeconds = 3
GroupRewardConfig.PromptTimeoutSeconds = 45

GroupRewardConfig.ZonePaths = table.freeze({
	table.freeze({ "Lobby", "GroupRewards", "ZonePart" }),
	table.freeze({ "Lobby", "GroupRewards", "TouchPart" }),
})

GroupRewardConfig.ReminderText = "Like and Join the group for FREE rewards"
GroupRewardConfig.RewardCrateId = "Basic"
GroupRewardConfig.RewardCash = 500
GroupRewardConfig.RewardSource = "GroupReward"
GroupRewardConfig.RewardClaimedText = "Group reward claimed: Basic crate + 500 coins!"
GroupRewardConfig.AlreadyClaimedText = "You already claimed your group reward."

return table.freeze(GroupRewardConfig)
