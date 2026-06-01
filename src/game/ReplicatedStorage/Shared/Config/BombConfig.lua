return table.freeze({
	MaxBombs = 5,
	RechargeSeconds = 2,
	FuseSeconds = 2.5,

	ThrowSpeed = 92,
	ThrowUpBoost = 20,
	ThrowOffset = Vector3.new(0, 2.2, -2.6),
	InheritedVelocityScale = 0.35,
	MinAimY = -0.55,
	MaxAimY = 0.85,

	RuntimeBombName = "BasicBomb",
	RuntimeBombSize = Vector3.new(1.4, 1.4, 1.4),
	ProjectileFolderName = "BombProjectiles",
	ProjectileLifetimePadding = 0.4,

	InnerRadius = 4,
	NearRadius = 10,
	OuterRadius = 18,

	PlayerDirectDamage = 50,
	PlayerNearDamageMax = 35,
	PlayerNearDamageMin = 25,
	PlayerOuterDamageMax = 20,
	PlayerOuterDamageMin = 10,

	AnchorDirectDamage = 20,
	AnchorNearDamageMax = 12,
	AnchorNearDamageMin = 8,
	AnchorOuterDamageMax = 6,
	AnchorOuterDamageMin = 3,

	KnockbackHorizontal = 56,
	KnockbackVertical = 34,
	KnockbackMinScale = 0.35,

	PreviewPoints = 18,
	PreviewStepSeconds = 0.08,
	PreviewPointSize = 0.18,
	PreviewMaxSeconds = 1.4,
	PreviewColor = Color3.fromRGB(255, 197, 67),
	PreviewDangerColor = Color3.fromRGB(255, 88, 64),
	ExplosionEffectSeconds = 0.28,

	Attributes = table.freeze({
		Count = "BombCount",
		Max = "BombMax",
		RechargeEndsAt = "BombRechargeEndsAt",
		Cooking = "BombCooking",
		CookStartedAt = "BombCookStartedAt",
	}),
})
