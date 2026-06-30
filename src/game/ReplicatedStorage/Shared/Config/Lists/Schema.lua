local SettingsConfig = require(script.Parent.Parent.SettingsConfig)

return {
	Cash = {
		key = "cash",
		value = 200,
	},

	TimePlayed = {
		key = "timePlayed",
		value = 0,
	},

	LifetimeKills = {
		key = "lifetimeKills",
		value = 0,
	},

	LifetimeWins = {
		key = "lifetimeWins",
		value = 0,
	},

	LifetimeDestruction = {
		key = "lifetimeDestruction",
		value = 0,
	},

	GamesPlayed = {
		key = "gamesPlayed",
		value = 0,
	},

	Losses = {
		key = "losses",
		value = 0,
	},

	CurrentWinStreak = {
		key = "currentWinStreak",
		value = 0,
	},

	BestWinStreak = {
		key = "bestWinStreak",
		value = 0,
	},

	AbilityUsage = {
		key = "abilityUsage",
		value = {},
	},

	AbilityGamesUsed = {
		key = "abilityGamesUsed",
		value = {},
	},

	DailyLeaderboardStats = {
		key = "dailyLeaderboardStats",
		value = {
			periodKey = "",
			kills = 0,
			wins = 0,
			destruction = 0,
		},
	},

	MonthlyLeaderboardStats = {
		key = "monthlyLeaderboardStats",
		value = {
			periodKey = "",
			kills = 0,
			wins = 0,
			destruction = 0,
		},
	},

	OwnedAbilities = {
		key = "ownedAbilities",
		value = {},
	},

	AbilityLoadout = {
		key = "abilityLoadout",
		value = {
			Offensive = "",
			Defensive = "",
		},
	},

	OwnedBombSkins = {
		key = "ownedBombSkins",
		value = {},
	},

	BombSkinCopies = {
		key = "bombSkinCopies",
		value = {},
	},

	EquippedBombSkin = {
		key = "equippedBombSkin",
		value = "Default",
	},

	OwnedFinishers = {
		key = "ownedFinishers",
		value = {},
	},

	FinisherCopies = {
		key = "finisherCopies",
		value = {},
	},

	EquippedFinisher = {
		key = "equippedFinisher",
		value = "",
	},

	OwnedHighlightIntros = {
		key = "ownedHighlightIntros",
		value = {},
	},

	HighlightIntroCopies = {
		key = "highlightIntroCopies",
		value = {},
	},

	EquippedHighlightIntro = {
		key = "equippedHighlightIntro",
		value = "TooFast",
	},

	EmoteOrder = {
		key = "emoteOrder",
		value = {},
	},

	OwnedEmotes = {
		key = "ownedEmotes",
		value = {},
	},

	FavoriteEmotes = {
		key = "favoriteEmotes",
		value = {},
	},

	CrateRollHistory = {
		key = "crateRollHistory",
		value = {
			recent = {},
		},
	},

	CrateTokens = {
		key = "crateTokens",
		value = {
			Basic = 0,
			Premium = 0,
			FinisherBasic = 0,
			FinisherPremium = 0,
		},
	},

	SpinWheel = {
		key = "spinWheel",
		value = {
			spins = 0,
			nextFreeAt = 0,
			instantSpinUntil = 0,
		},
	},

	DailyRewards = {
		key = "dailyRewards",
		value = {
			claimedDays = {},
			nextDay = 1,
			lastClaimDayKey = "",
			countryCode = "",
			utcOffsetMinutes = 0,
			resetAtUnix = 0,
			completed = false,
			consecutive = {
				currentStreak = 0,
				bestStreak = 0,
				lastLoginDayKey = "",
				lastLoginDayIndex = 0,
				unclaimedRewards = {},
			},
		},
	},

	RedeemedCodes = {
		key = "redeemedCodes",
		value = {},
	},

	GroupReward = {
		key = "groupReward",
		value = {
			hasBaseline = false,
			baselineLikes = 0,
			baselineAtUnix = 0,
			rewardClaimed = false,
			claimedAtUnix = 0,
			joinedViaPrompt = false,
		},
	},

	FriendRewards = {
		key = "friendRewards",
		value = {
			totalFriendSeconds = 0,
			claimedTiers = {},
		},
	},

	InviteRewards = {
		key = "inviteRewards",
		value = {
			hasJoined = false,
			referredInviteProcessed = false,
			chickenClaimed = false,
			claimedAtUnix = 0,
			processedReferredUserIds = {},
		},
	},

	Quests = {
		key = "quests",
		value = {
			dayKey = "",
			countryCode = "",
			utcOffsetMinutes = 0,
			resetAtUnix = 0,
			progress = {},
			claimed = {},
		},
	},

	PlayerSettings = {
		key = "playerSettings",
		value = SettingsConfig.NormalizeSettings(nil),
	},

	Diagnostics = {
		key = "diagnostics",
		value = {},
	},
}
