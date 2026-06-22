local InviteRewardConfig = {}

InviteRewardConfig.RemotesFolderName = "Remotes"
InviteRewardConfig.OpenRemoteName = "InviteRewardOpen"
InviteRewardConfig.StateRemoteName = "InviteRewardState"
InviteRewardConfig.RequestRemoteName = "InviteRewardRequest"

InviteRewardConfig.FrameName = "InviteMenu"
InviteRewardConfig.InvitePromptMessage = "Join me in Bomb Battles!"
InviteRewardConfig.LaunchDataSource = "InviteMenu"
InviteRewardConfig.RewardSkinId = "Chicken"
InviteRewardConfig.RewardSource = "InviteReward"
InviteRewardConfig.GlobalUpdateType = "InviteRewardChicken"

InviteRewardConfig.InteractionCooldownSeconds = 3
InviteRewardConfig.MaxLaunchDataLength = 200

InviteRewardConfig.ZonePaths = table.freeze({
	table.freeze({ "Lobby", "Pedestal", "ZonePart" }),
})

InviteRewardConfig.Actions = table.freeze({
	GetState = "GetState",
})

InviteRewardConfig.RewardGrantedText = "Invite reward unlocked: Chicken bomb!"
InviteRewardConfig.RewardAlreadyOwnedText = "Invite reward completed: Chicken bomb already unlocked."

return table.freeze(InviteRewardConfig)
