return {
	Scope = "GameState_1",

	MinPlayers = 2,
	IntermissionSeconds = 30,
	RoundSeconds = 180,
	ResetSeconds = 5,
	VoteChoiceCount = 3,

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
