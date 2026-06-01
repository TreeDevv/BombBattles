return table.freeze({
	BaseFOV = 70,
	SprintFOVBonus = 6,
	AirFOVBonus = 2,
	FOVResponsiveness = 10,

	ShoulderOffset = Vector3.new(2.25, 0.45, 0),
	ShoulderResponsiveness = 14,
	MouseBehavior = Enum.MouseBehavior.LockCenter,
	LockMouseIconEnabled = false,

	MaxStrafeRollDegrees = 1.25,
	RollResponsiveness = 12,

	LandingSmallMinAirTime = 0.18,
	LandingHeavyMinAirTime = 0.75,
	LandingSmallShakeMagnitude = 1.2,
	LandingSmallShakeRoughness = 10,
	LandingSmallShakeFadeOutTime = 0.28,
	LandingSmallShakePositionInfluence = Vector3.new(0, 0.14, 0),
	LandingSmallShakeRotationInfluence = Vector3.new(0.8, 0, 0.25),
	LandingHeavyShakeMagnitude = 2.0,
	LandingHeavyShakeRoughness = 12,
	LandingHeavyShakeFadeOutTime = 0.36,
	LandingHeavyShakePositionInfluence = Vector3.new(0, 0.2, 0),
	LandingHeavyShakeRotationInfluence = Vector3.new(1.25, 0, 0.35),

	FallLagDelay = 0.35,
	FallLagFullTime = 1.1,
	MaxFallLagYOffset = 0.35,
	FallLagDownVelocityThreshold = -8,
	FallLagResponsiveness = 5,
	FallLagRecoveryResponsiveness = 16,

	DisableWhenHudFOVActive = true,
})
