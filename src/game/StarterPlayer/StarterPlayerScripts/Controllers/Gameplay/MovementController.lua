local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)

local LocalPlayer = Players.LocalPlayer
local RENDER_STEP_NAME = "BombBattlesMovementController"
local SPRINT_ACTION_NAME = "BombBattlesSprint"
local CROUCH_ACTION_NAME = "BombBattlesCrouch"
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value + 1
local CONTROLLER_LOOKUP_TIMEOUT = 5
local NEVER = -math.huge
local SLIDE_FORWARD_DOT_THRESHOLD = 0.65

type Controls = {
	GetMoveVector: (Controls) -> Vector3,
}

local MovementController = {}

MovementController._character = nil :: Model?
MovementController._characterConnection = nil :: RBXScriptConnection?
MovementController._jumpRequestConnection = nil :: RBXScriptConnection?
MovementController._heartbeatConnection = nil :: RBXScriptConnection?
MovementController._warnedCharacters = {} :: { [Model]: boolean }
MovementController._controls = nil :: Controls?
MovementController._controllerManager = nil :: any
MovementController._groundController = nil :: any
MovementController._airController = nil :: any
MovementController._groundSensor = nil :: any
MovementController._humanoid = nil :: Humanoid?
MovementController._rootPart = nil :: BasePart?
MovementController._smoothedMoveDirection = Vector3.zero
MovementController._smoothedFacingDirection = Vector3.zero
MovementController._sprintHeld = false
MovementController._crouchHeld = false
MovementController._isCrouching = false
MovementController._isSliding = false
MovementController._slideDirection = Vector3.zero
MovementController._slideEndTime = NEVER
MovementController._lastSlideEndTime = NEVER
MovementController._slideRequestPending = false
MovementController._slideJumpCarryHorizontalVelocity = Vector3.zero
MovementController._slideJumpCarryStartTime = NEVER
MovementController._slideJumpCarryEndTime = NEVER
MovementController._slideJumpCarryCharacter = nil :: Model?
MovementController._slideJumpCarryRootPart = nil :: BasePart?
MovementController._lastSlideHorizontalVelocity = Vector3.zero
MovementController._isGrounded = false
MovementController._wasGrounded = false
MovementController._lastGroundedTime = NEVER
MovementController._lastLandedTime = NEVER
MovementController._lastJumpRequestTime = NEVER
MovementController._lastJumpReplayTime = NEVER
MovementController._lastAirJumpTime = NEVER
MovementController._airJumpCount = 0
MovementController._jumpSerial = 0

local function getControls(): Controls?
	local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
	if not playerScripts then
		return nil
	end

	local playerModule = playerScripts:FindFirstChild("PlayerModule")
	if not playerModule or not playerModule:IsA("ModuleScript") then
		return nil
	end

	local ok, module = pcall(require, playerModule)
	if not ok or typeof(module) ~= "table" or type(module.GetControls) ~= "function" then
		return nil
	end

	return module:GetControls()
end

local function flattenDirection(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local magnitude = flat.Magnitude
	if magnitude <= 0 then
		return Vector3.zero
	end
	return flat / magnitude
end

local function flattenVelocity(velocity: Vector3): Vector3
	return Vector3.new(velocity.X, 0, velocity.Z)
end

local function getCameraRelativeDirection(moveVector: Vector3): Vector3
	local moveMagnitude = math.min(moveVector.Magnitude, 1)
	if moveMagnitude < MovementConfig.MinMoveMagnitude then
		return Vector3.zero
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return Vector3.zero
	end

	local forward = flattenDirection(camera.CFrame.LookVector)
	local right = flattenDirection(camera.CFrame.RightVector)
	local worldDirection = (right * moveVector.X) + (forward * -moveVector.Z)
	local worldMagnitude = worldDirection.Magnitude

	if worldMagnitude < MovementConfig.MinMoveMagnitude then
		return Vector3.zero
	end

	return worldDirection.Unit * moveMagnitude
end

local function getCameraFacingDirection(): Vector3
	local camera = workspace.CurrentCamera
	if not camera then
		return Vector3.zero
	end

	return flattenDirection(camera.CFrame.LookVector)
end

local function exponentialAlpha(responsiveness: number, dt: number): number
	return 1 - math.exp(-responsiveness * dt)
end

local function smoothVector(current: Vector3, target: Vector3, responsiveness: number, dt: number): Vector3
	return current:Lerp(target, exponentialAlpha(responsiveness, dt))
end

local function getDescendantOfClass(parent: Instance, className: string): Instance?
	for _, descendant in parent:GetDescendants() do
		if descendant.ClassName == className then
			return descendant
		end
	end
	return nil
end

local function waitForDescendantOfClass(parent: Instance, className: string, timeoutSeconds: number): Instance?
	local deadline = os.clock() + timeoutSeconds

	repeat
		local found = getDescendantOfClass(parent, className)
		if found then
			return found
		end

		task.wait()
	until os.clock() >= deadline or not parent.Parent

	return nil
end

local function getGroundSensor(controllerManager: any): any
	local sensor = controllerManager.GroundSensor
	if sensor then
		return sensor
	end

	local rootPart = controllerManager.RootPart
	if rootPart then
		for _, descendant in rootPart:GetDescendants() do
			if descendant.ClassName == "ControllerPartSensor" and descendant.SensorMode == Enum.SensorMode.Floor then
				return descendant
			end
		end
	end

	return nil
end

local function getMovementParts(character: Model)
	local controllerManager = waitForDescendantOfClass(
		character,
		"ControllerManager",
		CONTROLLER_LOOKUP_TIMEOUT
	)
	local groundController = waitForDescendantOfClass(
		character,
		"GroundController",
		CONTROLLER_LOOKUP_TIMEOUT
	)

	if not controllerManager or not groundController then
		if not MovementController._warnedCharacters[character] then
			MovementController._warnedCharacters[character] = true
			warn("[MovementController] Missing CCL ControllerManager or GroundController for character:", character:GetFullName())
		end
		return nil
	end

	local airController = getDescendantOfClass(character, "AirController")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and MovementConfig.DisableHumanoidAutoRotate then
		humanoid.AutoRotate = false
	end
	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	end

	controllerManager.BaseMoveSpeed = MovementConfig.WalkMoveSpeed
	controllerManager.BaseTurnSpeed = MovementConfig.BaseTurnSpeed

	groundController.AccelerationTime = MovementConfig.GroundAccelerationTime
	groundController.DecelerationTime = MovementConfig.GroundDecelerationTime
	groundController.Friction = MovementConfig.GroundFriction
	groundController.FrictionWeight = MovementConfig.GroundFrictionWeight

	if airController then
		airController.MoveSpeedFactor = 1
		local hasMaintainLinearMomentum = pcall(function()
			return airController.MaintainLinearMomentum
		end)
		if hasMaintainLinearMomentum then
			airController.MaintainLinearMomentum = true
		end
	end

	return {
		controllerManager = controllerManager,
		groundController = groundController,
		airController = airController,
		groundSensor = getGroundSensor(controllerManager),
		humanoid = humanoid,
		rootPart = if rootPart and rootPart:IsA("BasePart") then rootPart else nil,
	}
end

function MovementController:_isCurrentlyGrounded(): boolean
	local groundSensor = self._groundSensor
	if not groundSensor and self._controllerManager then
		groundSensor = getGroundSensor(self._controllerManager)
		self._groundSensor = groundSensor
	end

	if groundSensor then
		return groundSensor.SensedPart ~= nil
	end

	local humanoid = self._humanoid
	return humanoid ~= nil and humanoid.FloorMaterial ~= Enum.Material.Air
end

function MovementController:_publishJump(kind: string)
	local character = self._character
	if not character then
		return
	end

	self._jumpSerial += 1
	character:SetAttribute("Movement_JumpSerial", self._jumpSerial)
	character:SetAttribute("Movement_LastJumpKind", kind)
	character:SetAttribute("Movement_AirJumpCount", self._airJumpCount)
end

function MovementController:_getSlideDirection(targetMoveDirection: Vector3): Vector3
	if targetMoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude then
		return targetMoveDirection.Unit
	end

	return Vector3.zero
end

function MovementController:_canStartSlide(now: number, targetMoveDirection: Vector3, isGrounded: boolean, isSprinting: boolean): boolean
	if self._isSliding then
		return false
	end

	if not (isGrounded and isSprinting and targetMoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude) then
		return false
	end

	if now - self._lastSlideEndTime < MovementConfig.SlideCooldown then
		return false
	end

	local rootPart = self._rootPart
	if not rootPart then
		return false
	end

	local localMoveDirection = rootPart.CFrame:VectorToObjectSpace(targetMoveDirection.Unit)
	return -localMoveDirection.Z >= SLIDE_FORWARD_DOT_THRESHOLD
end

function MovementController:_applySlideVelocity(speed: number): Vector3?
	local rootPart = self._rootPart
	local slideDirection = self._slideDirection
	if not (rootPart and rootPart.Parent and slideDirection.Magnitude >= MovementConfig.MinMoveMagnitude) then
		return nil
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalVelocity = flattenVelocity(velocity)
	local forwardSpeed = horizontalVelocity:Dot(slideDirection)
	if forwardSpeed >= speed then
		return horizontalVelocity
	end

	local newVelocity = velocity + slideDirection * (speed - forwardSpeed)
	rootPart.AssemblyLinearVelocity = newVelocity
	return flattenVelocity(newVelocity)
end

function MovementController:_getSlideJumpSpeedTarget(): number
	return math.max(MovementConfig.SlideJumpMinHorizontalSpeed, MovementConfig.SlideSpeed)
end

function MovementController:_rememberSlideMomentum(horizontalVelocity: Vector3?)
	local slideDirection = self._slideDirection
	if slideDirection.Magnitude < MovementConfig.MinMoveMagnitude then
		return
	end

	local rememberedVelocity = horizontalVelocity or Vector3.zero
	local speedTarget = self:_getSlideJumpSpeedTarget()
	local forwardSpeed = rememberedVelocity:Dot(slideDirection)
	if forwardSpeed < speedTarget then
		rememberedVelocity += slideDirection * (speedTarget - forwardSpeed)
	end

	self._lastSlideHorizontalVelocity = rememberedVelocity
end

function MovementController:_startSlide(now: number, targetMoveDirection: Vector3)
	self._isSliding = true
	self._isCrouching = false
	self._slideDirection = self:_getSlideDirection(targetMoveDirection)
	self._slideEndTime = now + MovementConfig.SlideDuration
	self:_rememberSlideMomentum(self:_applySlideVelocity(MovementConfig.SlideSpeed))
end

function MovementController:_stopSlide(now: number?)
	if self._isSliding then
		self:_rememberSlideMomentum(if self._rootPart then flattenVelocity(self._rootPart.AssemblyLinearVelocity) else nil)
		self._lastSlideEndTime = now or os.clock()
	end

	self._isSliding = false
	self._slideDirection = Vector3.zero
	self._slideEndTime = NEVER
end

function MovementController:_preserveSlideJumpMomentum()
	local now = os.clock()
	if not self._isSliding and now - self._lastSlideEndTime > MovementConfig.SlideJumpGraceTime then
		return nil
	end

	local horizontalVelocity
	if self._isSliding then
		horizontalVelocity = self:_applySlideVelocity(self:_getSlideJumpSpeedTarget())
		self:_stopSlide(now)
	else
		horizontalVelocity = self._lastSlideHorizontalVelocity
	end

	if not horizontalVelocity or horizontalVelocity.Magnitude < MovementConfig.MinMoveMagnitude then
		return nil
	end

	return horizontalVelocity
end

function MovementController:_clearSlideJumpCarry()
	self._slideJumpCarryHorizontalVelocity = Vector3.zero
	self._slideJumpCarryStartTime = NEVER
	self._slideJumpCarryEndTime = NEVER
	self._slideJumpCarryCharacter = nil
	self._slideJumpCarryRootPart = nil
end

function MovementController:_startSlideJumpCarry(now: number, horizontalVelocity: Vector3)
	if horizontalVelocity.Magnitude < MovementConfig.MinMoveMagnitude then
		self:_clearSlideJumpCarry()
		return
	end

	self._slideJumpCarryHorizontalVelocity = horizontalVelocity * MovementConfig.SlideJumpMomentumMultiplier
	self._slideJumpCarryStartTime = now
	self._slideJumpCarryEndTime = now + MovementConfig.SlideJumpCarryDuration
	self._slideJumpCarryCharacter = self._character
	self._slideJumpCarryRootPart = self._rootPart
end

function MovementController:_getSlideJumpCarryScale(now: number): number
	local duration = MovementConfig.SlideJumpCarryDuration
	if duration <= 0 then
		return 0
	end

	local alpha = math.clamp((now - self._slideJumpCarryStartTime) / duration, 0, 1)
	local smoothAlpha = alpha * alpha * (3 - (2 * alpha))
	local endScale = math.clamp(MovementConfig.SlideJumpCarryEndSpeedScale, 0, 1)
	return 1 + ((endScale - 1) * smoothAlpha)
end

function MovementController:_enforceSlideJumpCarry(now: number)
	if self._slideJumpCarryEndTime == NEVER then
		return
	end

	if now > self._slideJumpCarryEndTime then
		self:_clearSlideJumpCarry()
		return
	end

	local character = self._slideJumpCarryCharacter
	local rootPart = self._slideJumpCarryRootPart
	if not (character == self._character and rootPart == self._rootPart and rootPart and rootPart.Parent) then
		self:_clearSlideJumpCarry()
		return
	end

	local carryVelocity = self._slideJumpCarryHorizontalVelocity
	local carrySpeed = carryVelocity.Magnitude * self:_getSlideJumpCarryScale(now)
	if carrySpeed < MovementConfig.MinMoveMagnitude then
		self:_clearSlideJumpCarry()
		return
	end

	local carryDirection = carryVelocity.Unit
	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalVelocity = flattenVelocity(velocity)
	local forwardSpeed = horizontalVelocity:Dot(carryDirection)
	if forwardSpeed >= carrySpeed then
		return
	end

	rootPart.AssemblyLinearVelocity = velocity + carryDirection * (carrySpeed - forwardSpeed)
end

function MovementController:_getSlideJumpCarryVelocity(now: number): Vector3?
	if self._slideJumpCarryEndTime == NEVER or now > self._slideJumpCarryEndTime then
		return nil
	end

	if self._slideJumpCarryHorizontalVelocity.Magnitude < MovementConfig.MinMoveMagnitude then
		return nil
	end

	return self._slideJumpCarryHorizontalVelocity * self:_getSlideJumpCarryScale(now)
end

function MovementController:_requestGroundJump(now: number): boolean
	local character = self._character
	local rootPart = self._rootPart
	local humanoid = self._humanoid
	if not (character and rootPart and rootPart.Parent and humanoid) then
		return false
	end

	local slideJumpVelocity = self:_preserveSlideJumpMomentum()
	if slideJumpVelocity then
		self:_startSlideJumpCarry(now, slideJumpVelocity)
	end

	humanoid.Jump = true
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	self:_enforceSlideJumpCarry(now)

	self._lastJumpReplayTime = now
	self:_consumeJumpRequest()
	self:_publishJump("Jump")
	return true
end

function MovementController:_tryAirJump(now: number): boolean
	if not MovementConfig.DoubleJumpEnabled then
		return false
	end

	if self._airJumpCount >= MovementConfig.MaxAirJumps then
		return false
	end

	if now - self._lastAirJumpTime < MovementConfig.DoubleJumpCooldown then
		return false
	end

	local rootPart = self._rootPart
	local humanoid = self._humanoid
	if not (rootPart and rootPart.Parent and humanoid) then
		return false
	end

	local velocity = rootPart.AssemblyLinearVelocity
	rootPart.AssemblyLinearVelocity = Vector3.new(
		velocity.X,
		math.max(velocity.Y, MovementConfig.DoubleJumpUpVelocity),
		velocity.Z
	)
	humanoid.Jump = true
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)

	self._airJumpCount += 1
	self._lastAirJumpTime = now
	self._lastJumpReplayTime = now
	self:_consumeJumpRequest()
	self:_publishJump("DoubleJump")
	return true
end

function MovementController:_recordJumpRequest()
	local now = os.clock()
	if self:_isCurrentlyGrounded() then
		self:_requestGroundJump(now)
		return
	end

	if now - self._lastGroundedTime <= MovementConfig.CoyoteTime then
		self._lastJumpRequestTime = now
		return
	end

	if self:_tryAirJump(now) then
		return
	end

	self._lastJumpRequestTime = now
end

function MovementController:_consumeJumpRequest()
	self._lastJumpRequestTime = NEVER
end

function MovementController:_tryReplayJump(now: number, isGrounded: boolean, inCoyoteTime: boolean)
	if now - self._lastJumpReplayTime <= math.max(MovementConfig.CoyoteTime, MovementConfig.JumpBufferTime) then
		return
	end

	local jumpBuffered = now - self._lastJumpRequestTime <= MovementConfig.JumpBufferTime
	if not jumpBuffered then
		return
	end

	if isGrounded or inCoyoteTime then
		self:_requestGroundJump(now)
	end
end

function MovementController:_setDebugAttributes(data)
	local character = self._character
	if not character then
		return
	end

	character:SetAttribute("Movement_Grounded", data.isGrounded)
	character:SetAttribute("Movement_Sprinting", data.isSprinting)
	character:SetAttribute("Movement_Crouching", data.isCrouching)
	character:SetAttribute("Movement_Sliding", data.isSliding)
	character:SetAttribute("Movement_EffectiveSpeed", data.effectiveSpeed)
	character:SetAttribute("Movement_MoveMagnitude", data.moveMagnitude)
	character:SetAttribute("Movement_InCoyoteTime", data.inCoyoteTime)
	character:SetAttribute("Movement_JumpBuffered", data.jumpBuffered)
	character:SetAttribute("Movement_LandingSettling", data.landingSettling)
	character:SetAttribute("Movement_AirJumpCount", self._airJumpCount)
end

function MovementController:_unbindCharacter()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	self._character = nil
	self._controllerManager = nil
	self._groundController = nil
	self._airController = nil
	self._groundSensor = nil
	self._humanoid = nil
	self._rootPart = nil
	self._smoothedMoveDirection = Vector3.zero
	self._smoothedFacingDirection = Vector3.zero
	self._sprintHeld = false
	self._crouchHeld = false
	self._isCrouching = false
	self._isSliding = false
	self._slideDirection = Vector3.zero
	self._slideEndTime = NEVER
	self._lastSlideEndTime = NEVER
	self._slideRequestPending = false
	self:_clearSlideJumpCarry()
	self._lastSlideHorizontalVelocity = Vector3.zero
	self._isGrounded = false
	self._wasGrounded = false
	self._lastGroundedTime = NEVER
	self._lastLandedTime = NEVER
	self._lastJumpRequestTime = NEVER
	self._lastJumpReplayTime = NEVER
	self._lastAirJumpTime = NEVER
	self._airJumpCount = 0
	self._jumpSerial = 0
end

function MovementController:_step(dt: number)
	local controllerManager = self._controllerManager
	if not controllerManager or not controllerManager.Parent then
		return
	end

	local controls = self._controls or getControls()
	self._controls = controls

	if not controls then
		return
	end

	local now = os.clock()
	local isGrounded = self:_isCurrentlyGrounded()
	self._wasGrounded = self._isGrounded
	self._isGrounded = isGrounded

	if isGrounded then
		self._lastGroundedTime = now
		if not self._wasGrounded then
			self._lastLandedTime = now
			self._airJumpCount = 0
		end
	end

	local inCoyoteTime = not isGrounded and now - self._lastGroundedTime <= MovementConfig.CoyoteTime
	local jumpBuffered = now - self._lastJumpRequestTime <= MovementConfig.JumpBufferTime
	local landingSettling = isGrounded and now - self._lastLandedTime <= MovementConfig.LandingSettleTime

	self:_tryReplayJump(now, isGrounded, inCoyoteTime)

	local inputMoveDirection = getCameraRelativeDirection(controls:GetMoveVector())
	local hasInputMove = inputMoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude
	local sprintIntent = isGrounded and self._sprintHeld and hasInputMove

	if self._isSliding and (not isGrounded or now >= self._slideEndTime) then
		self:_stopSlide(now)
	end

	if self._slideRequestPending then
		self._slideRequestPending = false
		if self:_canStartSlide(now, inputMoveDirection, isGrounded, sprintIntent) then
			self:_startSlide(now, inputMoveDirection)
		end
	end

	local isSliding = self._isSliding
	local isCrouching = isGrounded and self._crouchHeld and not isSliding
	self._isCrouching = isCrouching

	local targetMoveDirection = if isSliding then self._slideDirection else inputMoveDirection
	local hasMoveInput = targetMoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude
	local isSprinting = sprintIntent and not isSliding and not isCrouching
	local targetSpeed = MovementConfig.AirMoveSpeed
	if isSliding then
		targetSpeed = MovementConfig.SlideSpeed
	elseif isGrounded and isCrouching then
		targetSpeed = MovementConfig.CrouchMoveSpeed
	elseif isGrounded and isSprinting then
		targetSpeed = MovementConfig.SprintMoveSpeed
	elseif isGrounded then
		targetSpeed = MovementConfig.WalkMoveSpeed
	end

	local slideJumpCarryVelocity = self:_getSlideJumpCarryVelocity(now)
	if slideJumpCarryVelocity and not isGrounded then
		targetMoveDirection = slideJumpCarryVelocity.Unit
		hasMoveInput = true
		targetSpeed = math.max(targetSpeed, slideJumpCarryVelocity.Magnitude)
	end

	local responsiveness
	if isSliding then
		responsiveness = MovementConfig.StopResponsiveness
	elseif isGrounded then
		if landingSettling and not hasMoveInput then
			responsiveness = MovementConfig.LandingStopResponsiveness
		else
			responsiveness = if targetMoveDirection.Magnitude > self._smoothedMoveDirection.Magnitude
				then MovementConfig.MoveResponsiveness
				else MovementConfig.StopResponsiveness
		end
	else
		responsiveness = if hasMoveInput
			then MovementConfig.AirMoveResponsiveness
			else MovementConfig.AirStopResponsiveness
	end

	controllerManager.BaseMoveSpeed = targetSpeed
	controllerManager.BaseTurnSpeed = MovementConfig.BaseTurnSpeed

	if isSliding then
		self._smoothedMoveDirection = targetMoveDirection
	elseif isGrounded and not hasMoveInput and MovementConfig.SnapGroundStop then
		self._smoothedMoveDirection = Vector3.zero
	else
		self._smoothedMoveDirection = smoothVector(self._smoothedMoveDirection, targetMoveDirection, responsiveness, dt)
	end

	if self._smoothedMoveDirection.Magnitude < MovementConfig.MinMoveMagnitude then
		self._smoothedMoveDirection = Vector3.zero
	end

	controllerManager.MovingDirection = self._smoothedMoveDirection

	local targetFacingDirection = if MovementConfig.FaceCameraDirection
		then getCameraFacingDirection()
		else if hasMoveInput then targetMoveDirection.Unit else Vector3.zero

	if targetFacingDirection.Magnitude >= MovementConfig.MinMoveMagnitude then
		if self._smoothedFacingDirection.Magnitude < MovementConfig.MinMoveMagnitude then
			self._smoothedFacingDirection = targetFacingDirection
		else
			self._smoothedFacingDirection = smoothVector(
				self._smoothedFacingDirection,
				targetFacingDirection,
				MovementConfig.FacingResponsiveness,
				dt
			)
		end

		if self._smoothedFacingDirection.Magnitude >= MovementConfig.MinMoveMagnitude then
			controllerManager.FacingDirection = self._smoothedFacingDirection.Unit
		end
	end

	self:_setDebugAttributes({
		isGrounded = isGrounded,
		isSprinting = isSprinting,
		isCrouching = isCrouching,
		isSliding = isSliding,
		effectiveSpeed = targetSpeed,
		moveMagnitude = targetMoveDirection.Magnitude,
		inCoyoteTime = inCoyoteTime,
		jumpBuffered = jumpBuffered,
		landingSettling = landingSettling,
	})
end

function MovementController:_handleSprintAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		self._sprintHeld = true
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		self._sprintHeld = false
	end

	return Enum.ContextActionResult.Pass
end

function MovementController:_handleCrouchAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		if not self._crouchHeld then
			self._slideRequestPending = self._sprintHeld
		end
		self._crouchHeld = true
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		self._crouchHeld = false
		self._slideRequestPending = false
	end

	return Enum.ContextActionResult.Pass
end

function MovementController:_bindCharacter(character: Model)
	self:_unbindCharacter()

	local parts = getMovementParts(character)
	if not parts then
		return
	end

	self._character = character
	self._controllerManager = parts.controllerManager
	self._groundController = parts.groundController
	self._airController = parts.airController
	self._groundSensor = parts.groundSensor
	self._humanoid = parts.humanoid
	self._rootPart = parts.rootPart
	self._isGrounded = self:_isCurrentlyGrounded()
	self._wasGrounded = self._isGrounded
	self._lastGroundedTime = if self._isGrounded then os.clock() else NEVER
	self._smoothedMoveDirection = parts.controllerManager.MovingDirection
	self._smoothedFacingDirection = parts.controllerManager.FacingDirection
	self._airJumpCount = 0
	self._jumpSerial = 0

	character:SetAttribute("Movement_JumpSerial", self._jumpSerial)
	character:SetAttribute("Movement_LastJumpKind", "")
	character:SetAttribute("Movement_AirJumpCount", self._airJumpCount)
	character:SetAttribute("Movement_Crouching", false)
	character:SetAttribute("Movement_Sliding", false)

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function(dt)
		self:_step(dt)
	end)
end

function MovementController:OnStart()
	self._controls = getControls()

	ContextActionService:UnbindAction(SPRINT_ACTION_NAME)
	ContextActionService:BindAction(
		SPRINT_ACTION_NAME,
		function(...)
			return self:_handleSprintAction(...)
		end,
		false,
		Enum.KeyCode.LeftShift,
		Enum.KeyCode.ButtonL3
	)

	ContextActionService:UnbindAction(CROUCH_ACTION_NAME)
	ContextActionService:BindAction(
		CROUCH_ACTION_NAME,
		function(...)
			return self:_handleCrouchAction(...)
		end,
		false,
		Enum.KeyCode.C
	)

	if self._jumpRequestConnection then
		self._jumpRequestConnection:Disconnect()
	end
	self._jumpRequestConnection = UserInputService.JumpRequest:Connect(function()
		self:_recordJumpRequest()
	end)

	if self._heartbeatConnection then
		self._heartbeatConnection:Disconnect()
	end
	self._heartbeatConnection = RunService.Heartbeat:Connect(function()
		self:_enforceSlideJumpCarry(os.clock())
	end)

	if LocalPlayer.Character then
		self:_bindCharacter(LocalPlayer.Character)
	end

	if self._characterConnection then
		self._characterConnection:Disconnect()
	end

	self._characterConnection = LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)
end

return MovementController
