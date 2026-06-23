local GroupRewardConfig = {}

GroupRewardConfig.RemotesFolderName = "Remotes"
GroupRewardConfig.PromptRemoteName = "GroupRewardPrompt"
GroupRewardConfig.PromptResultRemoteName = "GroupRewardPromptResult"
GroupRewardConfig.StateRemoteName = "GroupRewardState"
GroupRewardConfig.StateRequestRemoteName = "GroupRewardStateRequest"

GroupRewardConfig.GroupId = 0
GroupRewardConfig.InteractionCooldownSeconds = 3
GroupRewardConfig.PromptTimeoutSeconds = 45

GroupRewardConfig.ZonePaths = table.freeze({
	table.freeze({ "Lobby", "GroupRewards", "ZonePart" }),
	table.freeze({ "Lobby", "GroupRewards", "TouchPart" }),
})

GroupRewardConfig.Visuals = table.freeze({
	RootPath = table.freeze({ "Lobby", "GroupRewards" }),
	GroupChestName = "GroupRewards",
	FriendChestName = "FriendRewards",
	VisibleTransparency = 0,
	HiddenTransparency = 1,
	TweenSeconds = 0.18,
})

GroupRewardConfig.ReminderText = "Like and Join the group for FREE rewards"
GroupRewardConfig.RewardCrateId = "Basic"
GroupRewardConfig.RewardCash = 500
GroupRewardConfig.RewardSource = "GroupReward"
GroupRewardConfig.RewardClaimedText = "Group reward claimed: Basic crate + 500 coins!"
GroupRewardConfig.AlreadyClaimedText = "You already claimed your group reward."

return table.freeze(GroupRewardConfig)
