local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)

local ReplayAnimationDriver = {}
ReplayAnimationDriver.__index = ReplayAnimationDriver

local LOOPED_TRACKS = {
	Idle = true,
	WalkBack = true,
	WalkForward = true,
	RunForward = true,
	WalkLeft = true,
	WalkRight = true,
	Fall = true,
	CrouchIdle = true,
	CrouchWalk = true,
}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function getNumber(value: any, fallback: number): number
	return if isFiniteNumber(value) then value else fallback
end

local function getBoolean(value: any, fallback: boolean): boolean
	return if typeof(value) == "boolean" then value else fallback
end

local function getAnimator(model: Model): Animator?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.AutoRotate = false
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.NameDisplayDistance = 0

		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			return animator
		end

		animator = Instance.new("Animator")
		animator.Parent = humanoid
		return animator
	end

	local animationController = model:FindFirstChildOfClass("AnimationController")
	if not animationController then
		animationController = Instance.new("AnimationController")
		animationController.Parent = model
	end

	local animator = animationController:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	animator = Instance.new("Animator")
	animator.Parent = animationController
	return animator
end

local function loadTrack(animator: Animator, animationId: any, name: string, config)
	if typeof(animationId) ~= "string" or animationId == "" then
		return nil, nil
	end

	local animation = Instance.new("Animation")
	animation.Name = "Replay" .. name
	animation.AnimationId = animationId

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not (ok and track) then
		animation:Destroy()
		return nil, nil
	end

	track.Looped = config and config.Looped == true
	if config and config.Priority then
		track.Priority = config.Priority
	end

	return track, animation
end

local function ensureLoopPlaying(track: AnimationTrack?)
	if track and not track.IsPlaying then
		track:Play(0, 0, 1)
	end
end

local function setTrackWeight(track: AnimationTrack?, weight: number, fadeTime: number)
	if not track then
		return
	end

	ensureLoopPlaying(track)
	track:AdjustWeight(math.clamp(weight, 0, 1), fadeTime)
end

local function adjustSpeed(track: AnimationTrack?, speed: number)
	if track then
		track:AdjustSpeed(speed)
	end
end

local function getTrackSpeedMultiplier(trackName: string): number
	local config = AnimationConfig.Animations[trackName]
	if config and isFiniteNumber(config.SpeedMultiplier) then
		return config.SpeedMultiplier
	end
	return 1
end

local function getTrackWeight(trackName: string): number
	local config = AnimationConfig.Animations[trackName]
	if config and isFiniteNumber(config.Weight) then
		return math.clamp(config.Weight, 0, 1)
	end
	return 1
end

local function getPlaybackSpeed(effectiveSpeed: number, referenceSpeed: number, speedMultiplier: number?): number
	local multiplier = speedMultiplier or 1
	if referenceSpeed <= 0 or effectiveSpeed <= 0 then
		return multiplier
	end

	return math.clamp(
		(effectiveSpeed / referenceSpeed) * multiplier,
		AnimationConfig.MinPlaybackSpeed,
		AnimationConfig.MaxPlaybackSpeed
	)
end

function ReplayAnimationDriver.new(model: Model)
	if not (AnimationConfig.Enabled and model and model:IsA("Model")) then
		return nil
	end

	local animator = getAnimator(model)
	if not animator then
		return nil
	end

	local self = setmetatable({
		model = model,
		animator = animator,
		tracks = {},
		bombTracks = {},
		animations = {},
		lastGrounded = nil,
		lastSliding = false,
		lastJumpSerial = nil,
		bombHolding = false,
		bombReleasePending = false,
		bombHoldConnection = nil,
		bombHoldSerial = 0,
	}, ReplayAnimationDriver)

	for name, config in pairs(AnimationConfig.Animations) do
		local track, animation = loadTrack(animator, config.AnimationId, name, config)
		if track then
			self.tracks[name] = track
			table.insert(self.animations, animation)
			if LOOPED_TRACKS[name] then
				track:Play(0, 0, 1)
			end
		end
	end

	for name, config in pairs(AnimationConfig.BombAnimations or {}) do
		local track, animation = loadTrack(animator, config.AnimationId, "Bomb" .. name, config)
		if track then
			self.bombTracks[name] = track
			table.insert(self.animations, animation)
		end
	end

	return self
end

function ReplayAnimationDriver:_playOneShot(name: string, fadeTime: number?, weight: number?)
	local track = self.tracks[name]
	if not track then
		return
	end

	if track.IsPlaying then
		track:Stop(0)
	end

	track:Play(fadeTime or AnimationConfig.OneShotFadeTime, weight or getTrackWeight(name), 1)
	track:AdjustSpeed(getTrackSpeedMultiplier(name))
end

function ReplayAnimationDriver:_disconnectBombHold()
	if self.bombHoldConnection then
		self.bombHoldConnection:Disconnect()
		self.bombHoldConnection = nil
	end
end

function ReplayAnimationDriver:StartBombHold()
	local track = self.bombTracks.Throw
	if not track or self.bombHolding then
		return
	end

	self:_disconnectBombHold()
	self.bombHolding = true
	self.bombReleasePending = false
	self.bombHoldSerial += 1
	local serial = self.bombHoldSerial

	if track.IsPlaying then
		track:Stop(0)
	end

	track:Play(AnimationConfig.BombAnimationFadeInTime, 1, 1)
	track:AdjustSpeed(1)

	self.bombHoldConnection = track.KeyframeReached:Connect(function(keyframeName: string)
		if keyframeName == AnimationConfig.BombHoldKeyframeName and self.bombHolding and serial == self.bombHoldSerial then
			track:AdjustSpeed(0)
		end
	end)

	task.delay(0.3, function()
		if self.bombHolding and serial == self.bombHoldSerial and track.IsPlaying then
			track:AdjustSpeed(0)
		end
	end)
end

function ReplayAnimationDriver:PlayBombRelease()
	local track = self.bombTracks.Throw
	if not track then
		self.bombHolding = false
		self.bombReleasePending = false
		return
	end

	self:_disconnectBombHold()
	self.bombHolding = false
	self.bombReleasePending = true
	self.bombHoldSerial += 1

	if not track.IsPlaying then
		track:Play(AnimationConfig.BombAnimationFadeInTime, 1, 1)
	end
	track:AdjustSpeed(1)

	local serial = self.bombHoldSerial
	task.delay(AnimationConfig.BombReleaseFallbackSeconds, function()
		if self.bombHoldSerial == serial then
			self.bombReleasePending = false
		end
	end)
end

function ReplayAnimationDriver:_updateBomb(state)
	local bombCooking = state.bombCooking == true
	if bombCooking then
		if not self.bombHolding and not self.bombReleasePending then
			self:StartBombHold()
		end
	elseif self.bombHolding then
		self:PlayBombRelease()
	end
end

function ReplayAnimationDriver:Step(snapshot, cframe: CFrame?)
	local state = if typeof(snapshot) == "table" and typeof(snapshot.animationState) == "table"
		then snapshot.animationState
		else {}

	local linearVelocity = if typeof(state.linearVelocity) == "Vector3" then state.linearVelocity else Vector3.zero
	local horizontalVelocity = Vector3.new(linearVelocity.X, 0, linearVelocity.Z)
	local horizontalSpeed = horizontalVelocity.Magnitude
	local effectiveSpeed = getNumber(state.effectiveSpeed, horizontalSpeed)
	local moveMagnitude = math.clamp(getNumber(state.moveMagnitude, if horizontalSpeed > 0.5 then 1 else 0), 0, 1)
	local grounded = getBoolean(state.grounded, true)
	local sprinting = getBoolean(state.sprinting, effectiveSpeed >= AnimationConfig.RunSpeedThreshold)
	local crouching = getBoolean(state.crouching, false)
	local sliding = getBoolean(state.sliding, false)
	local shiftLocked = getBoolean(state.shiftLocked, false)

	local localMoveDirection = Vector3.new(0, 0, -1)
	if cframe and horizontalSpeed > 0.05 then
		localMoveDirection = cframe:VectorToObjectSpace(horizontalVelocity.Unit)
	end

	local walkBackWeight = 0
	local walkForwardWeight = 0
	local runForwardWeight = 0
	local walkLeftWeight = 0
	local walkRightWeight = 0
	local crouchIdleWeight = 0
	local crouchWalkWeight = 0
	local hasMoveInput = grounded and moveMagnitude >= AnimationConfig.MinMoveMagnitude

	if grounded and sliding then
		crouchWalkWeight = AnimationConfig.SlideBaseCrouchWalkWeight
		if not self.lastSliding then
			self:_playOneShot("Slide", AnimationConfig.SlideFadeTime)
		end
	elseif grounded and crouching then
		if hasMoveInput then
			crouchWalkWeight = 1
		else
			crouchIdleWeight = 1
		end
	elseif hasMoveInput then
		if not shiftLocked then
			walkForwardWeight = 1
		else
			local forwardAmount = math.max(-localMoveDirection.Z, 0)
			local backAmount = math.max(localMoveDirection.Z, 0)
			if forwardAmount + backAmount >= AnimationConfig.MinMoveMagnitude then
				local totalForwardBackAmount = math.max(forwardAmount + backAmount, 1)
				walkBackWeight = backAmount / totalForwardBackAmount
				walkForwardWeight = forwardAmount / totalForwardBackAmount
			else
				local leftAmount = math.max(-localMoveDirection.X, 0)
				local rightAmount = math.max(localMoveDirection.X, 0)
				local totalStrafeAmount = math.max(leftAmount + rightAmount, 1)
				walkLeftWeight = leftAmount / totalStrafeAmount
				walkRightWeight = rightAmount / totalStrafeAmount
			end
		end

		if walkForwardWeight > 0 then
			local runAlpha = if sprinting then 1 else 0
			if not sprinting and AnimationConfig.RunBlendRange > 0 then
				runAlpha = math.clamp(
					(effectiveSpeed - AnimationConfig.RunSpeedThreshold) / AnimationConfig.RunBlendRange,
					0,
					1
				)
			end

			runForwardWeight = walkForwardWeight * runAlpha
			walkForwardWeight *= 1 - runAlpha
		end
	end

	setTrackWeight(self.tracks.Idle, if grounded and not hasMoveInput and not crouching and not sliding then 1 else 0, AnimationConfig.IdleFadeTime)
	setTrackWeight(self.tracks.WalkBack, walkBackWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self.tracks.WalkForward, walkForwardWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self.tracks.RunForward, runForwardWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self.tracks.WalkLeft, walkLeftWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self.tracks.WalkRight, walkRightWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self.tracks.CrouchIdle, crouchIdleWeight, AnimationConfig.CrouchFadeTime)
	setTrackWeight(self.tracks.CrouchWalk, crouchWalkWeight, AnimationConfig.CrouchFadeTime)

	adjustSpeed(self.tracks.WalkBack, getPlaybackSpeed(effectiveSpeed, AnimationConfig.WalkSpeedReference, getTrackSpeedMultiplier("WalkBack")))
	adjustSpeed(self.tracks.WalkForward, getPlaybackSpeed(effectiveSpeed, AnimationConfig.WalkSpeedReference, getTrackSpeedMultiplier("WalkForward")))
	adjustSpeed(self.tracks.RunForward, getPlaybackSpeed(effectiveSpeed, AnimationConfig.RunSpeedReference, getTrackSpeedMultiplier("RunForward")))
	adjustSpeed(self.tracks.WalkLeft, getPlaybackSpeed(effectiveSpeed, AnimationConfig.WalkSpeedReference, getTrackSpeedMultiplier("WalkLeft")))
	adjustSpeed(self.tracks.WalkRight, getPlaybackSpeed(effectiveSpeed, AnimationConfig.WalkSpeedReference, getTrackSpeedMultiplier("WalkRight")))
	adjustSpeed(self.tracks.CrouchWalk, getPlaybackSpeed(effectiveSpeed, AnimationConfig.CrouchSpeedReference, getTrackSpeedMultiplier("CrouchWalk")))

	local jumpSerial = if isFiniteNumber(state.jumpSerial) then math.floor(state.jumpSerial) else nil
	if jumpSerial then
		if self.lastJumpSerial == nil then
			self.lastJumpSerial = jumpSerial
		elseif jumpSerial > self.lastJumpSerial then
			self.lastJumpSerial = jumpSerial
			self:_playOneShot(if state.lastJumpKind == "DoubleJump" then "DoubleJump" else "Jump")
		end
	elseif self.lastGrounded == true and not grounded and linearVelocity.Y > 2 then
		self:_playOneShot("Jump")
	end

	if self.lastGrounded == false and grounded then
		self:_playOneShot("Land", AnimationConfig.LandingFadeTime, getTrackWeight("Land"))
	end

	local shouldFall = not grounded and linearVelocity.Y <= AnimationConfig.FallVelocityThreshold
	setTrackWeight(self.tracks.Fall, if shouldFall then 1 else 0, if grounded then AnimationConfig.LandingFadeTime else AnimationConfig.AirFadeTime)

	self.lastGrounded = grounded
	self.lastSliding = grounded and sliding
	self:_updateBomb(state)
end

function ReplayAnimationDriver:Reset()
	self:_disconnectBombHold()
	self.lastGrounded = nil
	self.lastSliding = false
	self.lastJumpSerial = nil
	self.bombHolding = false
	self.bombReleasePending = false
	self.bombHoldSerial += 1

	for _, track in pairs(self.tracks) do
		pcall(function()
			track:Stop(0)
		end)
	end
	for _, track in pairs(self.bombTracks) do
		pcall(function()
			track:Stop(0)
		end)
	end
end

function ReplayAnimationDriver:Destroy()
	self:_disconnectBombHold()

	for _, track in pairs(self.tracks) do
		pcall(function()
			track:Stop(0)
		end)
	end
	for _, track in pairs(self.bombTracks) do
		pcall(function()
			track:Stop(0)
		end)
	end
	for _, animation in ipairs(self.animations) do
		pcall(function()
			animation:Destroy()
		end)
	end

	table.clear(self.tracks)
	table.clear(self.bombTracks)
	table.clear(self.animations)
end

return ReplayAnimationDriver
