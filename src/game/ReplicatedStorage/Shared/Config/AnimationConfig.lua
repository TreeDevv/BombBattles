local function assetId(id: string): string
	return "rbxassetid://" .. id
end

return table.freeze({
	Enabled = true,
	DebugTransitionsEnabled = true,
	DebugRootTiltThresholdDegrees = 12,
	DebugLogCooldownSeconds = 0.15,
	RootUprightGuardEnabled = false,
	RootUprightGuardWindowSeconds = 0.35,
	DebugRiskyTrackEnabled = {
		Land = true,
		Slide = true,
		Jump = true,
		DoubleJump = true,
		Throw = true,
	},

	BombAnimations = {
		Throw = {
			AnimationId = assetId("115997415565360"),
			Looped = false,
			Priority = Enum.AnimationPriority.Movement,
			Weight = 0.65,
		},
	},
	BombHoldKeyframeName = "Hold",
	BombThrowMarkerName = "Throw",
	BombReleaseFallbackSeconds = 0.45,
	BombAnimationFadeTime = 0.06,

	Animations = {
		Idle = {
			AnimationId = assetId("113541114672918"),
			Looped = true,
			Priority = Enum.AnimationPriority.Idle,
			SpeedMultiplier = 1,
		},
		WalkBack = {
			AnimationId = assetId("126697754920293"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		WalkForward = {
			AnimationId = assetId("121231707745691"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		RunForward = {
			AnimationId = assetId("119471521802007"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		WalkLeft = {
			AnimationId = assetId("76093944492388"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		WalkRight = {
			AnimationId = assetId("125886726687274"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		Jump = {
			AnimationId = assetId("137023970046935"),
			Looped = false,
			Priority = Enum.AnimationPriority.Action,
			SpeedMultiplier = 1,
		},
		DoubleJump = {
			AnimationId = assetId("72137905343835"),
			Looped = false,
			Priority = Enum.AnimationPriority.Action,
			SpeedMultiplier = 1,
		},
		Fall = {
			AnimationId = assetId("93502229849069"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		Land = {
			AnimationId = assetId("97343882521319"),
			Looped = false,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
			Weight = 0.55,
		},
		CrouchIdle = {
			AnimationId = assetId("140078846779926"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		CrouchWalk = {
			AnimationId = assetId("125375083818610"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		Slide = {
			AnimationId = assetId("128718352020244"),
			Looped = false,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
			Weight = 0.75,
		},
	},

	LocomotionFadeTime = 0.05,
	AirFadeTime = 0.06,
	LandingFadeTime = 0.02,
	OneShotFadeTime = 0.05,
	IdleFadeTime = 0.08,
	CrouchFadeTime = 0.08,
	SlideFadeTime = 0.04,
	SlideBaseCrouchWalkWeight = 0.35,

	MinMoveMagnitude = 0.04,
	BackwardThreshold = 0.2,
	RunSpeedThreshold = 21,
	RunBlendRange = 3,

	WalkSpeedReference = 18,
	RunSpeedReference = 24,
	CrouchSpeedReference = 10,
	MinPlaybackSpeed = 0.75,
	MaxPlaybackSpeed = 1.8,

	FallVelocityThreshold = -6,
	FallDelay = 0.08,
})
