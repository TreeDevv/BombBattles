local SpinWheelConfig = {}

SpinWheelConfig.RemotesFolderName = "Remotes"
SpinWheelConfig.RequestSpinRemoteName = "SpinWheelRequestSpin"
SpinWheelConfig.GetStateRemoteName = "SpinWheelGetState"
SpinWheelConfig.StateChangedRemoteName = "SpinWheelStateChanged"
SpinWheelConfig.LegacyRequestSpinRemoteName = "RequestSpin"
SpinWheelConfig.LegacyGetStateRemoteName = "GetState"
SpinWheelConfig.LegacyStateChangedRemoteName = "StateChanged"
SpinWheelConfig.GrantSpinsBindableName = "GrantSpins"
SpinWheelConfig.RewardGrantedBindableName = "RewardGranted"

SpinWheelConfig.ModelPath = table.freeze({
	"Lobby",
	"MonetizationArea",
	"SpinWheel",
})

SpinWheelConfig.FreeSpinCooldownSeconds = 5 * 60
SpinWheelConfig.freeSpinCooldown = SpinWheelConfig.FreeSpinCooldownSeconds
SpinWheelConfig.InstantSpinRewardDurationSeconds = 30 * 60
SpinWheelConfig.MaxRequestsPerSecond = 4
SpinWheelConfig.IdleWheelSpeedDegreesPerSecond = 12
SpinWheelConfig.idleWheelSpeed = SpinWheelConfig.IdleWheelSpeedDegreesPerSecond
SpinWheelConfig.SpinDurationSeconds = 7.4
SpinWheelConfig.OpenMarginStuds = 1.5
SpinWheelConfig.CloseMarginStuds = 5
SpinWheelConfig.cameraEffects = true

SpinWheelConfig.ProductKeys = table.freeze({
	Buy1 = "SpinWheel1",
	Buy3 = "SpinWheel3",
})

SpinWheelConfig.RewardTypes = table.freeze({
	Cash = "cash",
	Spins = "spins",
	CrateToken = "crateToken",
	CrateRoll = "crateRoll",
	BombSkin = "bombSkin",
	Finisher = "finisher",
	Ability = "ability",
	RandomEmote = "randomEmote",
	InstantSpinTimed = "instantSpinTimed",
})

SpinWheelConfig.Rewards = table.freeze({
	table.freeze({
		type = SpinWheelConfig.RewardTypes.Cash,
		amount = 250,
		label = "250 Coins",
		category = "Coins",
		weight = 40,
		imageId = "rbxassetid://121737055548467",
	}),
	table.freeze({
		type = SpinWheelConfig.RewardTypes.Cash,
		amount = 1000,
		label = "1,000 Coins",
		category = "Coins",
		weight = 25,
		imageId = "rbxassetid://97200403072990",
	}),
	table.freeze({
		type = SpinWheelConfig.RewardTypes.CrateToken,
		crateId = "Premium",
		amount = 1,
		label = "Premium Skin Crate",
		category = "Crate",
		weight = 15,
		imageId = "rbxassetid://81833874497008",
	}),
	table.freeze({
		type = SpinWheelConfig.RewardTypes.RandomEmote,
		label = "Random Emote",
		category = "Emote",
		weight = 10,
		imageId = "rbxassetid://106265723563512",
	}),
	table.freeze({
		type = SpinWheelConfig.RewardTypes.InstantSpinTimed,
		durationSeconds = SpinWheelConfig.InstantSpinRewardDurationSeconds,
		label = "Instant Spin for 30m",
		category = "Boost",
		weight = 9,
		imageId = "rbxassetid://131015181438322",
	}),
	table.freeze({
		type = SpinWheelConfig.RewardTypes.Ability,
		itemId = "HeavenFire",
		label = "HeavenFire Ability",
		category = "Ability",
		weight = 1,
		imageId = "rbxassetid://122161462244434",
		jackpot = true,
	}),
})

function SpinWheelConfig.GetTotalWeight(): number
	local total = 0
	for _, reward in ipairs(SpinWheelConfig.Rewards) do
		total += math.max(0, tonumber(reward.weight) or 0)
	end
	return total
end

return table.freeze(SpinWheelConfig)
