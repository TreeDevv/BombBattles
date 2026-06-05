local WorldTextConstants = {}

WorldTextConstants.REMOTES_FOLDER_NAME = "Remotes"
WorldTextConstants.REMOTE_NAME = "WorldTextEvent"

WorldTextConstants.DEFAULT_RELEVANCE_RADIUS = 120

WorldTextConstants.Kinds = table.freeze({
	BombThrown = "BombThrown",
	BombExploded = "BombExploded",
	PlayerDamaged = "PlayerDamaged",
	PlayerKilled = "PlayerKilled",
	AbilityUsed = "AbilityUsed",
})

return table.freeze(WorldTextConstants)
