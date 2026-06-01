local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)

local LocalPlayer = Players.LocalPlayer
local RENDER_STEP_NAME = "BombBattlesCharacterAnimationController"
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value + 3
local CHARACTER_LOOKUP_TIMEOUT = 5

type TrackName =
	"Idle"
	| "IdleFlourish"
	| "WalkBack"
	| "WalkForward"
	| "RunForward"
	| "WalkStopForward"
	| "Jump"
	| "DoubleJump"
	| "Fall"
type TrackMap = { [TrackName]: AnimationTrack }

local LOOPED_TRACKS = {
	Idle = true,
	WalkBack = true,
	WalkForward = true,
	RunForward = true,
	Fall = true,
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
CharacterAnimationController._wasUsingForwardLocomotion = false
CharacterAnimationController._forwardLocomotionStartTime = nil :: number?
CharacterAnimationController._nextIdleFlourishTime = nil :: number?

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

local function getAnimator(humanoid: Humanoid): Animator
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
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

local function getIdleFlourishDelay(): number
	return Random.new():NextNumber(AnimationConfig.IdleFlourishMinDelay, AnimationConfig.IdleFlourishMaxDelay)
end

local function ensureLoopPlaying(track: AnimationTrack)
	if not track.IsPlaying then
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

function CharacterAnimationController:_playOneShot(name: TrackName, fadeTime: number?, weight: number?)
	local track = self._tracks[name]
	if not track then
		return
	end

	if track.IsPlaying then
		track:Stop(0)
	end

	track:Play(fadeTime or AnimationConfig.OneShotFadeTime, weight or 1, 1)
	track:AdjustSpeed(getTrackSpeedMultiplier(name))
end

function CharacterAnimationController:_updateJumpOneShots(character: Model)
	local jumpSerial = readNumberAttribute(character, "Movement_JumpSerial")
	if jumpSerial <= self._lastJumpSerial then
		return
	end

	self._lastJumpSerial = jumpSerial
	self:_stopIdleFlourish()

	local jumpKind = readStringAttribute(character, "Movement_LastJumpKind")
	if jumpKind == "DoubleJump" then
		self:_playOneShot("DoubleJump")
	else
		self:_playOneShot("Jump")
	end
end

function CharacterAnimationController:_stopIdleFlourish()
	local track = self._tracks.IdleFlourish
	if track and track.IsPlaying then
		track:Stop(AnimationConfig.IdleFlourishFadeTime)
	end
end

function CharacterAnimationController:_scheduleIdleFlourish(now: number)
	self._nextIdleFlourishTime = now + getIdleFlourishDelay()
end

function CharacterAnimationController:_updateIdle(now: number, isIdle: boolean)
	setTrackWeight(self._tracks.Idle, if isIdle then 1 else 0, AnimationConfig.IdleFadeTime)

	if not isIdle then
		self._nextIdleFlourishTime = nil
		self:_stopIdleFlourish()
		return
	end

	if not self._nextIdleFlourishTime then
		self:_scheduleIdleFlourish(now)
		return
	end

	local flourishTrack = self._tracks.IdleFlourish
	if now >= self._nextIdleFlourishTime and not (flourishTrack and flourishTrack.IsPlaying) then
		self:_playOneShot("IdleFlourish", AnimationConfig.IdleFlourishFadeTime)
		self:_scheduleIdleFlourish(now)
	end
end

function CharacterAnimationController:_updateAirState(now: number, isGrounded: boolean, velocityY: number)
	if isGrounded then
		self._airborneStartTime = nil
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
	local now = os.clock()
	local effectiveSpeed = readNumberAttribute(character, "Movement_EffectiveSpeed")
	local moveMagnitude = readNumberAttribute(character, "Movement_MoveMagnitude")
	local isSprinting = character:GetAttribute("Movement_Sprinting") == true
	local hasMoveInput = isGrounded and moveMagnitude >= AnimationConfig.MinMoveMagnitude
	local localMoveDirection = self:_getLocalMoveDirection()
	local isBackward = localMoveDirection.Z > AnimationConfig.BackwardThreshold
	local usesForwardStop = hasMoveInput and not isBackward and localMoveDirection.Z < AnimationConfig.ForwardStopThreshold

	local walkBackWeight = 0
	local walkForwardWeight = 0
	local runForwardWeight = 0

	if hasMoveInput then
		if isBackward then
			walkBackWeight = 1
		else
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

			walkForwardWeight = 1 - runAlpha
			runForwardWeight = runAlpha
		end
	elseif isGrounded and self._wasUsingForwardLocomotion then
		local forwardMoveTime = if self._forwardLocomotionStartTime then now - self._forwardLocomotionStartTime else 0
		if forwardMoveTime >= AnimationConfig.MinForwardStopMoveTime then
			self:_playOneShot("WalkStopForward", AnimationConfig.StopFadeTime, AnimationConfig.StopWeight)
		end
	end

	setTrackWeight(self._tracks.WalkBack, walkBackWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self._tracks.WalkForward, walkForwardWeight, AnimationConfig.LocomotionFadeTime)
	setTrackWeight(self._tracks.RunForward, runForwardWeight, AnimationConfig.LocomotionFadeTime)

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

	if usesForwardStop then
		if not self._wasUsingForwardLocomotion then
			self._forwardLocomotionStartTime = now
		end
	else
		self._forwardLocomotionStartTime = nil
	end

	self._wasUsingForwardLocomotion = usesForwardStop
	return isGrounded and not hasMoveInput
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
	self:_updateIdle(now, isIdle)
	self:_updateAirState(now, isGrounded, velocityY)
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
	self._wasUsingForwardLocomotion = false
	self._forwardLocomotionStartTime = nil
	self._nextIdleFlourishTime = nil
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
			track:Play(0, 0, 1)
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

	local animator = getAnimator(humanoid)

	self._character = character
	self._rootPart = rootPart
	self._humanoid = humanoid
	self._animator = animator
	self._controllerManager = findDescendantOfClass(character, "ControllerManager")
	self._tracks = self:_loadTracks(animator)
	self._lastJumpSerial = readNumberAttribute(character, "Movement_JumpSerial")
	self._wasGrounded = true
	self._airborneStartTime = nil
	self._wasUsingForwardLocomotion = false
	self._forwardLocomotionStartTime = nil
	self._nextIdleFlourishTime = nil

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function()
		self:_step()
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
