local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local LocalPlayer = Players.LocalPlayer
local RENDER_STEP_NAME = "BombBattlesCharacterAnimationController"
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value + 3
local CHARACTER_LOOKUP_TIMEOUT = 5
local NEVER = -math.huge
local RISKY_TRACKS = { "Land", "Slide", "Jump", "DoubleJump" }

type TrackName =
	"Idle"
	| "WalkBack"
	| "WalkForward"
	| "RunForward"
	| "WalkLeft"
	| "WalkRight"
	| "Jump"
	| "DoubleJump"
	| "Fall"
	| "Land"
	| "CrouchIdle"
	| "CrouchWalk"
	| "Slide"
type TrackMap = { [TrackName]: AnimationTrack }

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

local CharacterAnimationController = {}

CharacterAnimationController._character = nil :: Model?
CharacterAnimationController._characterConnection = nil :: RBXScriptConnection?
CharacterAnimationController._animateConnection = nil :: RBXScriptConnection?
CharacterAnimationController._rootPart = nil :: BasePart?
CharacterAnimationController._humanoid = nil :: Humanoid?
CharacterAnimationController._animator = nil :: Animator?
CharacterAnimationController._controllerManager = nil :: any
CharacterAnimationController._tracks = {} :: TrackMap
CharacterAnimationController._animations = {} :: { Animation }
CharacterAnimationController._lastJumpSerial = 0
CharacterAnimationController._wasGrounded = true
CharacterAnimationController._airborneStartTime = nil :: number?
CharacterAnimationController._wasSliding = false
CharacterAnimationController._rootGuardUntil = NEVER
CharacterAnimationController._lastDebugLogTimes = {} :: { [string]: number }

local function waitForBasePart(parent: Instance, name: string, timeoutSeconds: number): BasePart?
	local child = parent:WaitForChild(name, timeoutSeconds)
	if child and child:IsA("BasePart") then
		return child
	end

	return nil
end

local function waitForHumanoid(parent: Instance, timeoutSeconds: number): Humanoid?
	local deadline = os.clock() + timeoutSeconds

	repeat
		local humanoid = parent:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return humanoid
		end

		task.wait()
	until os.clock() >= deadline or not parent.Parent

	return nil
end

local function findDescendantOfClass(parent: Instance, className: string): Instance?
	for _, descendant in parent:GetDescendants() do
		if descendant.ClassName == className then
			return descendant
		end
	end

	return nil
end

local function readNumberAttribute(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

local function readStringAttribute(instance: Instance, name: string): string
	local value = instance:GetAttribute(name)
	return if typeof(value) == "string" then value else ""
end

local function readOptionalBoolAttribute(instance: Instance, name: string): boolean?
	local value = instance:GetAttribute(name)
	return if typeof(value) == "boolean" then value else nil
end

local function readCameraShiftLocked(character: Model): boolean
	return character:GetAttribute("Camera_ShiftLocked") == true
end

local function isServerAnimator(animator: Animator): boolean
	local attributeName = AnimationConfig.ServerAnimatorAttributeName
	return typeof(attributeName) ~= "string" or attributeName == "" or animator:GetAttribute(attributeName) == true
end

local function findServerAnimator(humanoid: Humanoid): Animator?
	for _, child in ipairs(humanoid:GetChildren()) do
		if child:IsA("Animator") and isServerAnimator(child) then
			return child
		end
	end

	return nil
end

local function waitForServerAnimator(humanoid: Humanoid, timeoutSeconds: number): Animator?
	local deadline = os.clock() + timeoutSeconds

	repeat
		local animator = findServerAnimator(humanoid)
		if animator then
			return animator
		end

		task.wait()
	until os.clock() >= deadline or not humanoid.Parent

	return nil
end

local function disableDefaultAnimate(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant.Name == "Animate" and descendant:IsA("BaseScript") then
			descendant.Disabled = true
		end
	end
end

local function disableIfDefaultAnimate(instance: Instance)
	if instance.Name == "Animate" and instance:IsA("BaseScript") then
		instance.Disabled = true
	end
end

local function readControllerMoveDirection(controllerManager: any): Vector3
	if not controllerManager then
		return Vector3.zero
	end

	local ok, movingDirection = pcall(function()
		return controllerManager.MovingDirection
	end)

	if ok and typeof(movingDirection) == "Vector3" then
		return movingDirection
	end

	return Vector3.zero
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

local function getTrackSpeedMultiplier(trackName: TrackName): number
	local config = AnimationConfig.Animations[trackName]
	if config and typeof(config.SpeedMultiplier) == "number" then
		return config.SpeedMultiplier
	end

	return 1
end

local function getTrackWeight(trackName: TrackName): number
	local config = AnimationConfig.Animations[trackName]
	if config and typeof(config.Weight) == "number" then
		return math.clamp(config.Weight, 0, 1)
	end

	return 1
end

local function getReplicationMinimumTrackWeight(): number
	local weight = AnimationConfig.ReplicationMinimumTrackWeight
	if typeof(weight) ~= "number" then
		return 0
	end

	return math.clamp(weight, 0, 1)
end

local function getLoopedTrackReplicationWeight(weight: number): number
	local clampedWeight = math.clamp(weight, 0, 1)
	local minimumWeight = getReplicationMinimumTrackWeight()
	if minimumWeight <= 0 then
		return clampedWeight
	end

	return math.max(clampedWeight, minimumWeight)
end

local function isRiskyTrackEnabled(trackName: string): boolean
	local toggles = AnimationConfig.DebugRiskyTrackEnabled
	return not (typeof(toggles) == "table" and toggles[trackName] == false)
end

local function readTrackNumber(track: AnimationTrack, propertyName: string): number?
	local ok, value = pcall(function()
		return track[propertyName]
	end)

	return if ok and typeof(value) == "number" then value else nil
end

local function getRootAngles(rootPart: BasePart?): (number, number, number)
	if not rootPart then
		return 0, 0, 0
	end

	local pitch, yaw, roll = rootPart.CFrame:ToOrientation()
	return math.deg(pitch), math.deg(roll), math.deg(yaw)
end

local function formatNumber(value: number?): string
	if typeof(value) ~= "number" then
		return "?"
	end

	return string.format("%.2f", value)
end

local function getTrackSummary(track: AnimationTrack?): string
	if not track then
		return "track=nil"
	end

	local weight = readTrackNumber(track, "WeightCurrent")
	local targetWeight = readTrackNumber(track, "WeightTarget")
	local speed = readTrackNumber(track, "Speed")
	return string.format(
		"playing=%s weight=%s target=%s speed=%s priority=%s",
		tostring(track.IsPlaying),
		formatNumber(weight),
		formatNumber(targetWeight),
		formatNumber(speed),
		track.Priority.Name
	)
end

local function getHumanoidStateName(humanoid: Humanoid?): string
	if not humanoid then
		return "?"
	end

	local ok, state = pcall(function()
		return humanoid:GetState()
	end)

	return if ok then state.Name else "?"
end

local function getActiveRiskyTrackSummary(tracks: TrackMap): string
	local summaries = {}
	for _, name in ipairs(RISKY_TRACKS) do
		local track = tracks[name]
		if track and track.IsPlaying then
			table.insert(summaries, name .. "{" .. getTrackSummary(track) .. "}")
		end
	end

	return if #summaries > 0 then table.concat(summaries, "; ") else "none"
end

local function ensureLoopPlaying(track: AnimationTrack)
	if not track.IsPlaying then
		track:Play(0, getLoopedTrackReplicationWeight(0), 1)
	end
end

local function setTrackWeight(track: AnimationTrack?, weight: number, fadeTime: number)
	if not track then
		return
	end

	ensureLoopPlaying(track)
	track:AdjustWeight(getLoopedTrackReplicationWeight(weight), fadeTime)
end

function CharacterAnimationController:_stopAllTracks()
	for _, track in pairs(self._tracks) do
		track:Stop(0)
	end

	for _, animation in ipairs(self._animations) do
		animation:Destroy()
	end
end

function CharacterAnimationController:_getWorldMoveDirection(): Vector3
	local controllerDirection = readControllerMoveDirection(self._controllerManager)
	if controllerDirection.Magnitude >= AnimationConfig.MinMoveMagnitude then
		return controllerDirection
	end

	local humanoid = self._humanoid
	if humanoid and humanoid.MoveDirection.Magnitude >= AnimationConfig.MinMoveMagnitude then
		return humanoid.MoveDirection
	end

	return Vector3.zero
end

function CharacterAnimationController:_getLocalMoveDirection(): Vector3
	local rootPart = self._rootPart
	if not rootPart then
		return Vector3.zero
	end

	return rootPart.CFrame:VectorToObjectSpace(self:_getWorldMoveDirection())
end

function CharacterAnimationController:_setDebugAttributes(eventName: string, trackName: string?, pitch: number, roll: number)
	local character = self._character
	if not character then
		return
	end

	character:SetAttribute("Animation_DebugLastEvent", eventName)
	character:SetAttribute("Animation_DebugLastRootPitch", pitch)
	character:SetAttribute("Animation_DebugLastRootRoll", roll)
	character:SetAttribute("Animation_DebugLastTrack", trackName or "")
end

function CharacterAnimationController:_logDebug(eventName: string, trackName: string?, force: boolean?)
	if not AnimationConfig.DebugTransitionsEnabled then
		return
	end

	local now = os.clock()
	local key = eventName .. ":" .. (trackName or "")
	local cooldown = AnimationConfig.DebugLogCooldownSeconds or 0
	if not force and now - (self._lastDebugLogTimes[key] or NEVER) < cooldown then
		return
	end
	self._lastDebugLogTimes[key] = now

	local character = self._character
	local rootPart = self._rootPart
	local pitch, roll, yaw = getRootAngles(rootPart)
	local velocityY = if rootPart then rootPart.AssemblyLinearVelocity.Y else 0
	local angularVelocity = if rootPart then rootPart.AssemblyAngularVelocity.Magnitude else 0
	self:_setDebugAttributes(eventName, trackName, pitch, roll)

	warn(string.format(
		"[AnimationDebug] event=%s track=%s grounded=%s sliding=%s crouching=%s sprinting=%s pitch=%.1f roll=%.1f yaw=%.1f velY=%.1f angVel=%.2f humanoid=%s active=%s focus={%s}",
		eventName,
		trackName or "",
		tostring(character and character:GetAttribute("Movement_Grounded") == true),
		tostring(character and character:GetAttribute("Movement_Sliding") == true),
		tostring(character and character:GetAttribute("Movement_Crouching") == true),
		tostring(character and character:GetAttribute("Movement_Sprinting") == true),
		pitch,
		roll,
		yaw,
		velocityY,
		angularVelocity,
		getHumanoidStateName(self._humanoid),
		getActiveRiskyTrackSummary(self._tracks),
		getTrackSummary(if trackName then self._tracks[trackName] else nil)
	))
end

function CharacterAnimationController:_markRiskyTransition(eventName: string, trackName: TrackName?)
	if trackName then
		self._rootGuardUntil = math.max(self._rootGuardUntil, os.clock() + AnimationConfig.RootUprightGuardWindowSeconds)
	end

	self:_logDebug(eventName, trackName, true)
end

function CharacterAnimationController:_updateRootGuard(now: number)
	if not AnimationConfig.RootUprightGuardEnabled or not AnimationConfig.DebugTransitionsEnabled or now > self._rootGuardUntil then
		return
	end

	local rootPart = self._rootPart
	if not rootPart then
		return
	end

	local pitch, roll, yaw = getRootAngles(rootPart)
	local threshold = AnimationConfig.DebugRootTiltThresholdDegrees or 12
	if math.max(math.abs(pitch), math.abs(roll)) < threshold then
		return
	end

	self:_setDebugAttributes("root-guard-corrected", nil, pitch, roll)
	warn(string.format(
		"[AnimationDebug] event=root-guard-corrected pitch=%.1f roll=%.1f yaw=%.1f threshold=%.1f active=%s",
		pitch,
		roll,
		yaw,
		threshold,
		getActiveRiskyTrackSummary(self._tracks)
	))
	rootPart.CFrame = CFrame.new(rootPart.Position) * CFrame.Angles(0, math.rad(yaw), 0)
	rootPart.AssemblyAngularVelocity = Vector3.zero
end

function CharacterAnimationController:_playOneShot(name: TrackName, fadeTime: number?, weight: number?)
	local track = self._tracks[name]
	if not track then
		return
	end

	if not isRiskyTrackEnabled(name) then
		self:_markRiskyTransition("skip-disabled", name)
		return
	end

	self:_markRiskyTransition("play-before", name)

	if track.IsPlaying then
		track:Stop(0)
	end

	track:Play(fadeTime or AnimationConfig.OneShotFadeTime, weight or getTrackWeight(name), 1)
	track:AdjustSpeed(getTrackSpeedMultiplier(name))
	self:_markRiskyTransition("play-after", name)
end

function CharacterAnimationController:_updateJumpOneShots(character: Model)
	local jumpSerial = readNumberAttribute(character, "Movement_JumpSerial")
	if jumpSerial <= self._lastJumpSerial then
		return
	end

	self._lastJumpSerial = jumpSerial

	local jumpKind = readStringAttribute(character, "Movement_LastJumpKind")
	if jumpKind == "DoubleJump" then
		self:_playOneShot("DoubleJump")
	else
		self:_playOneShot("Jump")
	end
end

function CharacterAnimationController:_updateIdle(isIdle: boolean)
	setTrackWeight(self._tracks.Idle, if isIdle then 1 else 0, AnimationConfig.IdleFadeTime)
end

function CharacterAnimationController:_updateAirState(now: number, isGrounded: boolean, velocityY: number)
	if isGrounded then
		self._airborneStartTime = nil
		if not self._wasGrounded then
			self:_playOneShot("Land", AnimationConfig.LandingFadeTime)
		end
		setTrackWeight(self._tracks.Fall, 0, AnimationConfig.LandingFadeTime)
		return
	end

	if self._wasGrounded or not self._airborneStartTime then
		self._airborneStartTime = now
	end

	local airborneTime = now - self._airborneStartTime
	local shouldFall = velocityY <= AnimationConfig.FallVelocityThreshold and airborneTime >= AnimationConfig.FallDelay
	setTrackWeight(self._tracks.Fall, if shouldFall then 1 else 0, AnimationConfig.AirFadeTime)
end

function CharacterAnimationController:_updateGroundLocomotion(character: Model, isGrounded: boolean)
	local effectiveSpeed = readNumberAttribute(character, "Movement_EffectiveSpeed")
	local moveMagnitude = readNumberAttribute(character, "Movement_MoveMagnitude")
	local isSprinting = character:GetAttribute("Movement_Sprinting") == true
	local isCrouching = character:GetAttribute("Movement_Crouching") == true
	local isSliding = character:GetAttribute("Movement_Sliding") == true
	local shiftLocked = readCameraShiftLocked(character)
	local hasMoveInput = isGrounded and moveMagnitude >= AnimationConfig.MinMoveMagnitude
	local localMoveDirection = self:_getLocalMoveDirection()

	local walkBackWeight = 0
	local walkForwardWeight = 0
	local runForwardWeight = 0
	local walkLeftWeight = 0
	local walkRightWeight = 0
	local crouchIdleWeight = 0
	local crouchWalkWeight = 0

	if isGrounded and isSliding then
		crouchWalkWeight = AnimationConfig.SlideBaseCrouchWalkWeight
		if not self._wasSliding then
			self:_playOneShot("Slide", AnimationConfig.SlideFadeTime)
		end
	elseif self._wasSliding then
		local slideTrack = self._tracks.Slide
		if slideTrack and slideTrack.IsPlaying then
			slideTrack:Stop(AnimationConfig.SlideFadeTime)
		end
	elseif isGrounded and isCrouching then
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
			local hasForwardBack = forwardAmount >= AnimationConfig.MinMoveMagnitude
				or backAmount >= AnimationConfig.MinMoveMagnitude

			if hasForwardBack then
				local totalForwardBackAmount = forwardAmount + backAmount
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
			local runAlpha = 0
			if isSprinting then
				runAlpha = 1
			elseif AnimationConfig.RunBlendRange > 0 then
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

	setTrackWeight(self._tracks.WalkBack, walkBackWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self._tracks.WalkForward, walkForwardWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self._tracks.RunForward, runForwardWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self._tracks.WalkLeft, walkLeftWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self._tracks.WalkRight, walkRightWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self._tracks.CrouchIdle, crouchIdleWeight, AnimationConfig.CrouchFadeTime)
	setTrackWeight(self._tracks.CrouchWalk, crouchWalkWeight, AnimationConfig.CrouchFadeTime)

	if self._tracks.WalkBack then
		self._tracks.WalkBack:AdjustSpeed(
			getPlaybackSpeed(effectiveSpeed, AnimationConfig.WalkSpeedReference, getTrackSpeedMultiplier("WalkBack"))
		)
	end
	if self._tracks.WalkForward then
		self._tracks.WalkForward:AdjustSpeed(
			getPlaybackSpeed(effectiveSpeed, AnimationConfig.WalkSpeedReference, getTrackSpeedMultiplier("WalkForward"))
		)
	end
	if self._tracks.RunForward then
		self._tracks.RunForward:AdjustSpeed(
			getPlaybackSpeed(effectiveSpeed, AnimationConfig.RunSpeedReference, getTrackSpeedMultiplier("RunForward"))
		)
	end
	if self._tracks.WalkLeft then
		self._tracks.WalkLeft:AdjustSpeed(
			getPlaybackSpeed(effectiveSpeed, AnimationConfig.WalkSpeedReference, getTrackSpeedMultiplier("WalkLeft"))
		)
	end
	if self._tracks.WalkRight then
		self._tracks.WalkRight:AdjustSpeed(
			getPlaybackSpeed(effectiveSpeed, AnimationConfig.WalkSpeedReference, getTrackSpeedMultiplier("WalkRight"))
		)
	end
	if self._tracks.CrouchWalk then
		self._tracks.CrouchWalk:AdjustSpeed(
			getPlaybackSpeed(effectiveSpeed, AnimationConfig.CrouchSpeedReference, getTrackSpeedMultiplier("CrouchWalk"))
		)
	end

	self._wasSliding = isGrounded and isSliding
	return isGrounded and not hasMoveInput and not isCrouching and not isSliding
end

function CharacterAnimationController:_step()
	local character = self._character
	local rootPart = self._rootPart
	if not (AnimationConfig.Enabled and character and rootPart and rootPart.Parent) then
		return
	end

	local groundedAttribute = readOptionalBoolAttribute(character, "Movement_Grounded")
	local isGrounded = if groundedAttribute == nil then true else groundedAttribute
	local velocityY = rootPart.AssemblyLinearVelocity.Y
	local now = os.clock()

	self:_updateJumpOneShots(character)
	local isIdle = self:_updateGroundLocomotion(character, isGrounded)
	self:_updateIdle(isIdle)
	self:_updateAirState(now, isGrounded, velocityY)
	self:_updateRootGuard(now)
	self._wasGrounded = isGrounded
end

function CharacterAnimationController:_unbindCharacter()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	self:_stopAllTracks()
	if self._animateConnection then
		self._animateConnection:Disconnect()
	end

	self._character = nil
	self._animateConnection = nil
	self._rootPart = nil
	self._humanoid = nil
	self._animator = nil
	self._controllerManager = nil
	self._tracks = {} :: TrackMap
	self._animations = {}
	self._lastJumpSerial = 0
	self._wasGrounded = true
	self._airborneStartTime = nil
	self._wasSliding = false
	self._rootGuardUntil = NEVER
	self._lastDebugLogTimes = {}
end

function CharacterAnimationController:_loadTracks(animator: Animator): TrackMap
	local tracks = {} :: TrackMap

	for name, config in pairs(AnimationConfig.Animations) do
		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = config.AnimationId
		animation.Parent = script
		table.insert(self._animations, animation)

		local track = animator:LoadAnimation(animation)
		track.Looped = config.Looped == true
		track.Priority = config.Priority
		tracks[name] = track

		if LOOPED_TRACKS[name] then
			track:Play(0, getLoopedTrackReplicationWeight(0), 1)
		end
	end

	return tracks
end

function CharacterAnimationController:_bindCharacter(character: Model)
	self:_unbindCharacter()

	local rootPart = waitForBasePart(character, "HumanoidRootPart", CHARACTER_LOOKUP_TIMEOUT)
	local humanoid = waitForHumanoid(character, CHARACTER_LOOKUP_TIMEOUT)
	if not (rootPart and humanoid) then
		return
	end

	disableDefaultAnimate(character)
	self._animateConnection = character.DescendantAdded:Connect(disableIfDefaultAnimate)

	local animator = waitForServerAnimator(humanoid, CHARACTER_LOOKUP_TIMEOUT)
	if not animator then
		warn("[CharacterAnimationController] Missing server-created Animator for character:", character:GetFullName())
		return
	end

	self._character = character
	self._rootPart = rootPart
	self._humanoid = humanoid
	self._animator = animator
	self._controllerManager = findDescendantOfClass(character, "ControllerManager")
	self._tracks = self:_loadTracks(animator)
	self._lastJumpSerial = readNumberAttribute(character, "Movement_JumpSerial")
	self._wasGrounded = true
	self._airborneStartTime = nil
	self._wasSliding = false
	self._rootGuardUntil = NEVER
	self._lastDebugLogTimes = {}

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function()
		local token = RuntimeProfiler.Begin("Client/CharacterAnimationController/Render")
		self:_step()
		RuntimeProfiler.End("Client/CharacterAnimationController/Render", token)
	end)
end

function CharacterAnimationController:OnStart()
	if LocalPlayer.Character then
		task.spawn(function()
			self:_bindCharacter(LocalPlayer.Character)
		end)
	end

	if self._characterConnection then
		self._characterConnection:Disconnect()
	end

	self._characterConnection = LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)
end

return CharacterAnimationController
