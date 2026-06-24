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
		CompleteMatchCoins = 40,
		WinCoins = 50,
		EliminationCoins = 10,
		AssistCoins = 5,
		POTGCoins = 25,
		DamageCoinsPer100 = 3,
		VipBonusMultiplier = 0,
	},

	MapsFolderPath = { "Assets", "Maps" },
	ActiveMapName = "Map",
	ActiveMapWorldOffset = Vector3.new(12000, 0, 0),

	Maps = {
		{
			id = "Castles",
			displayName = "Castles",
			thumbnailImage = "rbxassetid://139253894629234",
		},
		{
			id = "Islands",
			displayName = "Islands",
			thumbnailImage = "rbxassetid://91990041425162",
		},
		{
			id = "Sakura",
			displayName = "Sakura",
			thumbnailImage = "rbxassetid://138201366272213",
		},
		{
			id = "Ships",
			displayName = "Ships",
			thumbnailImage = "rbxassetid://132616495811930",
		},
		{
			id = "SkyIslands",
			displayName = "Sky Islands",
			thumbnailImage = "rbxassetid://138066547116968",
		},
		{
			id = "SpaceShips",
			displayName = "Space Ships",
			thumbnailImage = "rbxassetid://109099081715690",
		},
	},
}
