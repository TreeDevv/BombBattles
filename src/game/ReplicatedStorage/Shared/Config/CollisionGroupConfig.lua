local CollisionGroupConfig = {}

CollisionGroupConfig.Groups = table.freeze({
	BombProjectile = "BombProjectile",
	PracticeRangeBombBarrier = "PracticeRangeBombBarrier",
})

return table.freeze(CollisionGroupConfig)
