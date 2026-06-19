return {
	Scope = "GameState_1",
	GameModeDisplayName = "TEAM DEATHMATCH",

	MinPlayers = 2,
	IntermissionSeconds = 30,
	RoundStartingSeconds = 3,
	RoundSeconds = 180,
	PlayOfTheGameSeconds = 10,
	RespawnSeconds = 7,
	ResetSeconds = 5,
	VoteChoiceCount = 4,
	StudioTesting = {
		MinPlayers = 1,
		HoldSoloRoundsActive = true,
		AIBots = {
			Enabled = true,
			TargetTeamSize = 6,
			MaxBotsTotal = 12,
			PatrolRadius = 42,
			PatrolRepathSeconds = 3.5,
			ThrowMinSeconds = 1.8,
			ThrowMaxSeconds = 3.4,
			ThrowOriginHeight = 3.2,
			AimSpreadStuds = 3,
			AimResampleAttempts = 6,
			MinExpectedPlayerDamage = 20,
			RespawnSeconds = 4,
			WalkSpeed = 18,
			JumpPower = 45,
		},
	},

	Teams = {
		Red = {
			name = "Red",
			color = BrickColor.new("Really red"),
		},
		Blue = {
			name = "Blue",
			color = BrickColor.new("Really blue"),
		},
	},

	Tags = {
		TeamSpawn = "TeamSpawn",
		LobbySpawn = "LobbySpawn",
		TeamCore = "TeamCore",
	},

	Cores = {
		MinPerTeam = 1,
		HealthAttribute = "Health",
		DestroyedAttribute = "Destroyed",
		DefaultHealth = 100,
	},

	Rewards = {
		ParticipationCoins = 25,
		WinCoins = 25,
		EliminationCoins = 10,
		DamageCoinsPer100 = 3,
		DestructionCoinsPerTarget = 2,
		VipBonusMultiplier = 0,
	},

	MapsFolderPath = { "Assets", "Maps" },
	ActiveMapName = "Map",

	Maps = {
		{
			id = "Ships",
			displayName = "Ships",
			thumbnailImage = "",
		},
	},
}
