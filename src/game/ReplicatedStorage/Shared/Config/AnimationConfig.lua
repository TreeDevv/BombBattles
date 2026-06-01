local function assetId(id: string): string
	return "rbxassetid://" .. id
end

return table.freeze({
	Enabled = true,

	BombAnimations = {
		Charge = {
			AnimationId = assetId("82827773383624"),
			Looped = false,
			Priority = Enum.AnimationPriority.Action,
		},
		Hold = {
			AnimationId = assetId("105822161782761"),
			Looped = true,
			Priority = Enum.AnimationPriority.Action,
		},
		Release = {
			AnimationId = assetId("76193431030955"),
			Looped = false,
			Priority = Enum.AnimationPriority.Action,
		},
	},
	BombThrowMarkerName = "Throw",
	BombReleaseFallbackSeconds = 0.45,
	BombAnimationFadeTime = 0.06,

	Animations = {
		Idle = {
			AnimationId = assetId("73608429239863"),
			Looped = true,
			Priority = Enum.AnimationPriority.Idle,
			SpeedMultiplier = 1,
		},
		IdleFlourish = {
			AnimationId = assetId("135150821008547"),
			Looped = false,
			Priority = Enum.AnimationPriority.Action,
			SpeedMultiplier = 1,
		},
		WalkBack = {
			AnimationId = assetId("126697754920293"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		WalkForward = {
			AnimationId = assetId("122191856900103"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		RunForward = {
			AnimationId = assetId("122226350928552"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1.5,
		},
		WalkStopForward = {
			AnimationId = assetId("94971797693984"),
			Looped = false,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
		Jump = {
			AnimationId = assetId("93060497012221"),
			Looped = false,
			Priority = Enum.AnimationPriority.Action,
			SpeedMultiplier = 1,
		},
		DoubleJump = {
			AnimationId = assetId("130534270338425"),
			Looped = false,
			Priority = Enum.AnimationPriority.Action,
			SpeedMultiplier = 1,
		},
		Fall = {
			AnimationId = assetId("132969408252045"),
			Looped = true,
			Priority = Enum.AnimationPriority.Movement,
			SpeedMultiplier = 1,
		},
	},

	LocomotionFadeTime = 0.05,
	AirFadeTime = 0.06,
	LandingFadeTime = 0.02,
	OneShotFadeTime = 0.05,
	StopFadeTime = 0.06,
	StopWeight = 0.9,
	MinForwardStopMoveTime = 0.12,
	IdleFadeTime = 0.08,
	IdleFlourishFadeTime = 0.08,
	IdleFlourishMinDelay = 3,
	IdleFlourishMaxDelay = 5,

	MinMoveMagnitude = 0.04,
	BackwardThreshold = 0.2,
	ForwardStopThreshold = -0.2,
	RunSpeedThreshold = 21,
	RunBlendRange = 3,

	WalkSpeedReference = 18,
	RunSpeedReference = 24,
	MinPlaybackSpeed = 0.75,
	MaxPlaybackSpeed = 1.8,

	FallVelocityThreshold = -6,
	FallDelay = 0.08,
})
