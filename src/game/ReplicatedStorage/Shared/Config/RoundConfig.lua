return {
	Scope = "GameState_1",

	MinPlayers = 2,
	IntermissionSeconds = 30,
	RoundSeconds = 180,
	RespawnSeconds = 5,
	ResetSeconds = 5,
	VoteChoiceCount = 3,
	StudioTesting = {
		MinPlayers = 1,
		HoldSoloRoundsActive = true,
		AllowBombTeamProtectionBypass = true,
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

	MapsFolderPath = { "Assets", "Maps" },
	ActiveMapName = "Map",

	Maps = {
		{
			id = "Ships",
			displayName = "Ships",
		},
	},
}
