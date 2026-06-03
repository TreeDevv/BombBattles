local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)

local LocalPlayer = Players.LocalPlayer
local RENDER_STEP_NAME = "BombBattlesMovementController"
local SPRINT_ACTION_NAME = "BombBattlesSprint"
local CROUCH_ACTION_NAME = "BombBattlesCrouch"
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value + 1
local CONTROLLER_LOOKUP_TIMEOUT = 5
local NEVER = -math.huge
local ADMIN_WALK_SPEED_ATTR = AdminConfig.WalkSpeedAttribute
local KNOCKBACK_UNTIL_ATTR = "Bomb_KnockbackUntil"
local SLIDE_PHASE_NONE = "None"
local SLIDE_PHASE_GROUND = "GroundSlide"
local SLIDE_PHASE_AIR_CARRY = "AirCarry"
local SLIDE_PHASE_GROUND_RUNOUT = "GroundRunout"
local SLIDE_FORWARD_DOT_THRESHOLD = 0.65
local SLIDE_STEER_DOT_THRESHOLD = 0.15
local SLIDE_OPPOSITE_DOT_THRESHOLD = -0.35

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
MovementController._crouchPressConsumedBySlide = false
MovementController._isCrouching = false
MovementController._slidePhase = SLIDE_PHASE_NONE
MovementController._slideDirection = Vector3.zero
MovementController._slideSpeed = 0
MovementController._slideStartTime = NEVER
MovementController._slideBlockedStartTime = NEVER
MovementController._lastSlideEndTime = NEVER
MovementController._slideRequestPending = false
MovementController._lastSlideDirection = Vector3.zero
MovementController._lastSlideSpeed = 0
MovementController._airCarryDirection = Vector3.zero
MovementController._airCarryStartSpeed = 0
MovementController._airCarryStartTime = NEVER
MovementController._airCarryEndTime = NEVER
MovementController._groundRunoutDirection = Vector3.zero
MovementController._groundRunoutSpeed = 0
MovementController._groundRunoutStartTime = NEVER
MovementController._groundRunoutLandingSpeed = 0
MovementController._slideEntryBurstDirection = Vector3.zero
MovementController._slideEntryBurstStartSpeed = 0
MovementController._slideEntryBurstStartTime = NEVER
MovementController._slideEntryBurstEndTime = NEVER
MovementController._slideEntryBurstBlockedStartTime = NEVER
MovementController._slideEntryBurstCharacter = nil :: Model?
MovementController._slideEntryBurstRootPart = nil :: BasePart?
MovementController._slideJumpBurstDirection = Vector3.zero
MovementController._slideJumpBurstStartSpeed = 0
MovementController._slideJumpBurstEndSpeed = 0
MovementController._slideJumpBurstStartTime = NEVER
MovementController._slideJumpBurstEndTime = NEVER
MovementController._slideJumpBurstBlockedStartTime = NEVER
MovementController._slideJumpBurstCharacter = nil :: Model?
MovementController._slideJumpBurstRootPart = nil :: BasePart?
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

local function getMoveVectorWithDeadzone(moveVector: Vector3): Vector3
	local minMoveMagnitude = MovementConfig.MinMoveMagnitude
	local x = if math.abs(moveVector.X) >= minMoveMagnitude then moveVector.X else 0
	local z = if math.abs(moveVector.Z) >= minMoveMagnitude then moveVector.Z else 0

	return Vector3.new(x, 0, z)
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

local function getAdminWalkSpeedOverride(): number?
	local value = LocalPlayer:GetAttribute(ADMIN_WALK_SPEED_ATTR)
	if typeof(value) ~= "number" then
		return nil
	end

	return math.clamp(value, AdminConfig.MinWalkSpeed, AdminConfig.MaxWalkSpeed)
end

local function readCameraShiftLocked(character: Model?): boolean
	return character ~= nil and character:GetAttribute("Camera_ShiftLocked") == true
end

local function isBombKnockbackActive(character: Model?): boolean
	if not character then
		return false
	end

	local knockbackUntil = character:GetAttribute(KNOCKBACK_UNTIL_ATTR)
	return typeof(knockbackUntil) == "number" and knockbackUntil > workspace:GetServerTimeNow()
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

function MovementController:_isGroundSlide(): boolean
	return self._slidePhase == SLIDE_PHASE_GROUND
end

function MovementController:_isAirCarry(): boolean
	return self._slidePhase == SLIDE_PHASE_AIR_CARRY
end

function MovementController:_isGroundRunout(): boolean
	return self._slidePhase == SLIDE_PHASE_GROUND_RUNOUT
end

function MovementController:_getSlideDirection(targetMoveDirection: Vector3): Vector3
	if targetMoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude then
		return targetMoveDirection.Unit
	end

	return Vector3.zero
end

function MovementController:_setGroundControllerTuning(isSliding: boolean)
	local groundController = self._groundController
	if not groundController then
		return
	end

	if isSliding then
		groundController.AccelerationTime = MovementConfig.SlideGroundAccelerationTime
		groundController.DecelerationTime = MovementConfig.SlideGroundDecelerationTime
		groundController.Friction = MovementConfig.SlideGroundFriction
		groundController.FrictionWeight = MovementConfig.SlideGroundFrictionWeight
	else
		groundController.AccelerationTime = MovementConfig.GroundAccelerationTime
		groundController.DecelerationTime = MovementConfig.GroundDecelerationTime
		groundController.Friction = MovementConfig.GroundFriction
		groundController.FrictionWeight = MovementConfig.GroundFrictionWeight
	end
end

function MovementController:_getGroundNormal(): Vector3?
	local groundSensor = self._groundSensor
	if not groundSensor and self._controllerManager then
		groundSensor = getGroundSensor(self._controllerManager)
		self._groundSensor = groundSensor
	end

	if not groundSensor then
		return nil
	end

	local ok, hitNormal = pcall(function()
		return groundSensor.HitNormal
	end)
	if ok and typeof(hitNormal) == "Vector3" and hitNormal.Magnitude >= MovementConfig.MinMoveMagnitude then
		return hitNormal.Unit
	end

	return nil
end

function MovementController:_getSlopeAlignment(slideDirectionOverride: Vector3?): number
	local groundNormal = self:_getGroundNormal()
	local slideDirection = slideDirectionOverride or self._slideDirection
	if not groundNormal or slideDirection.Magnitude < MovementConfig.MinMoveMagnitude then
		return 0
	end

	local gravityDirection = Vector3.new(0, -1, 0)
	local downhill = gravityDirection - (groundNormal * gravityDirection:Dot(groundNormal))
	if downhill.Magnitude < MovementConfig.MinMoveMagnitude then
		return 0
	end

	return downhill:Dot(slideDirection.Unit)
end

function MovementController:_getSlideSpeedCap(slopeAlignment: number?): number
	local alignment = slopeAlignment or self:_getSlopeAlignment()
	if alignment > MovementConfig.SlideSlopeNeutralThreshold then
		return MovementConfig.SlideDownhillMaxSpeed
	end

	return MovementConfig.SlideMaxSpeed
end

function MovementController:_getSlideSpeedDelta(slopeAlignment: number): number
	if slopeAlignment > MovementConfig.SlideSlopeNeutralThreshold then
		return (slopeAlignment * MovementConfig.SlideSlopeDownAcceleration) - MovementConfig.SlideFlatDecay
	end

	if slopeAlignment < -MovementConfig.SlideSlopeNeutralThreshold then
		return -MovementConfig.SlideFlatDecay + (slopeAlignment * MovementConfig.SlideSlopeUpDrain)
	end

	return -MovementConfig.SlideFlatDecay
end

function MovementController:_canStartSlide(now: number, targetMoveDirection: Vector3, isGrounded: boolean, isSprinting: boolean): boolean
	if self._slidePhase ~= SLIDE_PHASE_NONE then
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

function MovementController:_startGroundSlide(now: number, targetMoveDirection: Vector3)
	local slideDirection = self:_getSlideDirection(targetMoveDirection)
	if slideDirection.Magnitude < MovementConfig.MinMoveMagnitude then
		return
	end

	local rootPart = self._rootPart
	local forwardSpeed = 0
	if rootPart and rootPart.Parent then
		forwardSpeed = math.max(flattenVelocity(rootPart.AssemblyLinearVelocity):Dot(slideDirection.Unit), 0)
	end

	local slopeAlignment = self:_getSlopeAlignment(slideDirection)
	local speedCap = self:_getSlideSpeedCap(slopeAlignment)
	local entrySpeed = math.clamp(
		math.max(MovementConfig.SlideStartSpeed, forwardSpeed + MovementConfig.SlideEntrySpeedBonus),
		0,
		speedCap
	)

	self._slidePhase = SLIDE_PHASE_GROUND
	self._isCrouching = false
	self._slideDirection = slideDirection
	self._slideSpeed = entrySpeed
	self._slideStartTime = now
	self._slideBlockedStartTime = NEVER
	self._lastSlideDirection = slideDirection
	self._lastSlideSpeed = self._slideSpeed
	self._crouchPressConsumedBySlide = true
	self:_setGroundControllerTuning(true)
	self:_startSlideEntryBurst(now, slideDirection, entrySpeed)
end

function MovementController:_rememberSlideEnd(now: number)
	if self._slideDirection.Magnitude >= MovementConfig.MinMoveMagnitude then
		self._lastSlideDirection = self._slideDirection
		self._lastSlideSpeed = math.max(self._slideSpeed, 0)
	end
	self._lastSlideEndTime = now
end

function MovementController:_clearSlidePhase()
	self._slidePhase = SLIDE_PHASE_NONE
	self._slideDirection = Vector3.zero
	self._slideSpeed = 0
	self._slideStartTime = NEVER
	self._slideBlockedStartTime = NEVER
	self._airCarryDirection = Vector3.zero
	self._airCarryStartSpeed = 0
	self._airCarryStartTime = NEVER
	self._airCarryEndTime = NEVER
	self._groundRunoutDirection = Vector3.zero
	self._groundRunoutSpeed = 0
	self._groundRunoutStartTime = NEVER
	self._groundRunoutLandingSpeed = 0
	self:_setGroundControllerTuning(false)
	self:_clearSlideEntryBurst()
	self:_clearSlideJumpBurst()
end

function MovementController:_stopGroundSlide(now: number)
	if self:_isGroundSlide() then
		self:_rememberSlideEnd(now)
	end

	self:_clearSlidePhase()
end

function MovementController:_startAirCarry(now: number, direction: Vector3, speed: number)
	if direction.Magnitude < MovementConfig.MinMoveMagnitude or speed < MovementConfig.SlideExitSpeed then
		self:_clearSlidePhase()
		return
	end

	self._slidePhase = SLIDE_PHASE_AIR_CARRY
	self._slideDirection = Vector3.zero
	self._slideSpeed = 0
	self._slideStartTime = NEVER
	self._slideBlockedStartTime = NEVER
	self._airCarryDirection = direction.Unit
	self._airCarryStartSpeed = math.clamp(speed, MovementConfig.AirMoveSpeed, MovementConfig.SlideJumpMaxSpeed)
	self._airCarryStartTime = now
	self._airCarryEndTime = now + MovementConfig.AirCarryDuration
	self:_setGroundControllerTuning(false)
	self:_clearSlideEntryBurst()
end

function MovementController:_getAirCarrySpeed(now: number): number
	if not self:_isAirCarry() then
		return 0
	end

	local duration = MovementConfig.AirCarryDuration
	if duration <= 0 then
		return 0
	end

	local alpha = math.clamp((now - self._airCarryStartTime) / duration, 0, 1)
	local smoothAlpha = alpha * alpha * (3 - (2 * alpha))
	local endSpeed = math.max(MovementConfig.AirMoveSpeed, self._airCarryStartSpeed * MovementConfig.AirCarryEndSpeedScale)
	return self._airCarryStartSpeed + ((endSpeed - self._airCarryStartSpeed) * smoothAlpha)
end

function MovementController:_getSlideJumpSourceSpeed(direction: Vector3, fallbackSpeed: number): number
	local forwardSpeed = math.max(self:_getForwardHorizontalSpeed(direction), 0)
	return math.max(fallbackSpeed, forwardSpeed)
end

function MovementController:_getSlideJumpCarrySpeed(sourceSpeed: number): number
	return math.clamp(
		(sourceSpeed * MovementConfig.SlideJumpVelocityScale) + MovementConfig.SlideJumpVelocityBonus,
		MovementConfig.SlideJumpMinBurstSpeed,
		MovementConfig.SlideJumpMaxSpeed
	)
end

function MovementController:_getSlideJumpBurstEndSpeed(startSpeed: number): number
	return math.max(MovementConfig.SlideJumpMinBurstSpeed, startSpeed * MovementConfig.SlideJumpBurstEndSpeedScale)
end

function MovementController:_getHorizontalSpeed(): number
	local rootPart = self._rootPart
	if not (rootPart and rootPart.Parent) then
		return 0
	end

	return flattenVelocity(rootPart.AssemblyLinearVelocity).Magnitude
end

function MovementController:_getForwardHorizontalSpeed(direction: Vector3): number
	local rootPart = self._rootPart
	if not (rootPart and rootPart.Parent and direction.Magnitude >= MovementConfig.MinMoveMagnitude) then
		return 0
	end

	return flattenVelocity(rootPart.AssemblyLinearVelocity):Dot(direction.Unit)
end

function MovementController:_applyHorizontalVelocityFloor(rootPart: BasePart, direction: Vector3, desiredForwardSpeed: number, maxSpeed: number): number
	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalVelocity = flattenVelocity(velocity)
	local moveDirection = direction.Unit
	local forwardSpeed = horizontalVelocity:Dot(moveDirection)
	local finalForwardSpeed = math.max(forwardSpeed, desiredForwardSpeed)
	local sidewaysVelocity = horizontalVelocity - (moveDirection * forwardSpeed)
	local finalHorizontalVelocity = (moveDirection * finalForwardSpeed) + sidewaysVelocity
	if finalHorizontalVelocity.Magnitude > maxSpeed then
		finalHorizontalVelocity = finalHorizontalVelocity.Unit * maxSpeed
	end

	rootPart.AssemblyLinearVelocity = Vector3.new(finalHorizontalVelocity.X, velocity.Y, finalHorizontalVelocity.Z)
	return finalHorizontalVelocity:Dot(moveDirection)
end

function MovementController:_clearSlideEntryBurst()
	self._slideEntryBurstDirection = Vector3.zero
	self._slideEntryBurstStartSpeed = 0
	self._slideEntryBurstStartTime = NEVER
	self._slideEntryBurstEndTime = NEVER
	self._slideEntryBurstBlockedStartTime = NEVER
	self._slideEntryBurstCharacter = nil
	self._slideEntryBurstRootPart = nil
end

function MovementController:_isSlideEntryBurstActive(now: number?): boolean
	local checkTime = now or os.clock()
	return self._slideEntryBurstEndTime ~= NEVER and checkTime <= self._slideEntryBurstEndTime
end

function MovementController:_getSlideEntryBurstSpeed(now: number): number
	local duration = MovementConfig.SlideEntryBurstDuration
	if duration <= 0 then
		return self._slideEntryBurstStartSpeed * MovementConfig.SlideEntryBurstEndSpeedScale
	end

	local alpha = math.clamp((now - self._slideEntryBurstStartTime) / duration, 0, 1)
	local endSpeed = self._slideEntryBurstStartSpeed * MovementConfig.SlideEntryBurstEndSpeedScale
	return self._slideEntryBurstStartSpeed + ((endSpeed - self._slideEntryBurstStartSpeed) * alpha)
end

function MovementController:_startSlideEntryBurst(now: number, direction: Vector3, startSpeed: number)
	local rootPart = self._rootPart
	if not (rootPart and rootPart.Parent and direction.Magnitude >= MovementConfig.MinMoveMagnitude and startSpeed > 0) then
		self:_clearSlideEntryBurst()
		return
	end

	self._slideEntryBurstDirection = direction.Unit
	self._slideEntryBurstStartSpeed = startSpeed
	self._slideEntryBurstStartTime = now
	self._slideEntryBurstEndTime = now + MovementConfig.SlideEntryBurstDuration
	self._slideEntryBurstBlockedStartTime = NEVER
	self._slideEntryBurstCharacter = self._character
	self._slideEntryBurstRootPart = rootPart
	self:_updateSlideEntryBurst(now)
end

function MovementController:_updateSlideEntryBurst(now: number)
	if not self:_isSlideEntryBurstActive(now) then
		self:_clearSlideEntryBurst()
		return
	end

	local rootPart = self._slideEntryBurstRootPart
	local direction = self._slideEntryBurstDirection
	if not (
		self._slidePhase == SLIDE_PHASE_GROUND
		and self._isGrounded
		and self._slideEntryBurstCharacter == self._character
		and rootPart == self._rootPart
		and rootPart
		and rootPart.Parent
		and direction.Magnitude >= MovementConfig.MinMoveMagnitude
	) then
		self:_clearSlideEntryBurst()
		return
	end

	local burstDirection = direction.Unit
	local forwardSpeed = flattenVelocity(rootPart.AssemblyLinearVelocity):Dot(burstDirection)
	if forwardSpeed < MovementConfig.SlideEntryBurstBlockedSpeedFloor then
		if self._slideEntryBurstBlockedStartTime == NEVER then
			self._slideEntryBurstBlockedStartTime = now
		elseif now - self._slideEntryBurstBlockedStartTime >= MovementConfig.SlideEntryBurstBlockedTime then
			self:_clearSlideEntryBurst()
			return
		end
	else
		self._slideEntryBurstBlockedStartTime = NEVER
	end

	local desiredForwardSpeed = self:_getSlideEntryBurstSpeed(now)
	local speedCap = self:_getSlideSpeedCap()
	local appliedForwardSpeed = self:_applyHorizontalVelocityFloor(rootPart, burstDirection, desiredForwardSpeed, speedCap)
	self._slideSpeed = math.max(self._slideSpeed, math.min(appliedForwardSpeed, speedCap))
end

function MovementController:_clearSlideJumpBurst()
	self._slideJumpBurstDirection = Vector3.zero
	self._slideJumpBurstStartSpeed = 0
	self._slideJumpBurstEndSpeed = 0
	self._slideJumpBurstStartTime = NEVER
	self._slideJumpBurstEndTime = NEVER
	self._slideJumpBurstBlockedStartTime = NEVER
	self._slideJumpBurstCharacter = nil
	self._slideJumpBurstRootPart = nil
end

function MovementController:_isSlideJumpBurstActive(now: number?): boolean
	local checkTime = now or os.clock()
	return self._slideJumpBurstEndTime ~= NEVER and checkTime <= self._slideJumpBurstEndTime
end

function MovementController:_getSlideJumpBurstSpeed(now: number): number
	local duration = MovementConfig.SlideJumpBurstDuration
	if duration <= 0 then
		return self._slideJumpBurstEndSpeed
	end

	local alpha = math.clamp((now - self._slideJumpBurstStartTime) / duration, 0, 1)
	return self._slideJumpBurstStartSpeed
		+ ((self._slideJumpBurstEndSpeed - self._slideJumpBurstStartSpeed) * alpha)
end

function MovementController:_startSlideJumpBurst(now: number, direction: Vector3, startSpeed: number, endSpeed: number)
	local rootPart = self._rootPart
	if not (rootPart and rootPart.Parent and direction.Magnitude >= MovementConfig.MinMoveMagnitude and startSpeed > 0) then
		self:_clearSlideJumpBurst()
		return
	end

	self._slideJumpBurstDirection = direction.Unit
	self._slideJumpBurstStartSpeed = math.clamp(startSpeed, MovementConfig.SlideJumpMinBurstSpeed, MovementConfig.SlideJumpMaxSpeed)
	self._slideJumpBurstEndSpeed = math.clamp(endSpeed, MovementConfig.SlideJumpMinBurstSpeed, self._slideJumpBurstStartSpeed)
	self._slideJumpBurstStartTime = now
	self._slideJumpBurstEndTime = now + MovementConfig.SlideJumpBurstDuration
	self._slideJumpBurstBlockedStartTime = NEVER
	self._slideJumpBurstCharacter = self._character
	self._slideJumpBurstRootPart = rootPart
	self:_updateSlideJumpBurst(now)
end

function MovementController:_updateSlideJumpBurst(now: number)
	if not self:_isSlideJumpBurstActive(now) then
		self:_clearSlideJumpBurst()
		return
	end

	local rootPart = self._slideJumpBurstRootPart
	local direction = self._slideJumpBurstDirection
	if not (
		self._slidePhase == SLIDE_PHASE_AIR_CARRY
		and self._slideJumpBurstCharacter == self._character
		and rootPart == self._rootPart
		and rootPart
		and rootPart.Parent
		and direction.Magnitude >= MovementConfig.MinMoveMagnitude
	) then
		self:_clearSlideJumpBurst()
		return
	end

	if self._isGrounded and now - self._slideJumpBurstStartTime > MovementConfig.SlideJumpBurstGroundForgiveness then
		self:_clearSlideJumpBurst()
		return
	end

	local burstDirection = direction.Unit
	local forwardSpeed = flattenVelocity(rootPart.AssemblyLinearVelocity):Dot(burstDirection)
	if forwardSpeed < MovementConfig.SlideJumpBurstBlockedSpeedFloor then
		if self._slideJumpBurstBlockedStartTime == NEVER then
			self._slideJumpBurstBlockedStartTime = now
		elseif now - self._slideJumpBurstBlockedStartTime >= MovementConfig.SlideJumpBurstBlockedTime then
			self:_clearSlideJumpBurst()
			return
		end
	else
		self._slideJumpBurstBlockedStartTime = NEVER
	end

	local desiredForwardSpeed = self:_getSlideJumpBurstSpeed(now)
	self:_applyHorizontalVelocityFloor(rootPart, burstDirection, desiredForwardSpeed, MovementConfig.SlideJumpMaxSpeed)
end

function MovementController:_steerDirection(currentDirection: Vector3, inputMoveDirection: Vector3, dt: number): Vector3
	if currentDirection.Magnitude < MovementConfig.MinMoveMagnitude then
		return currentDirection
	end

	if inputMoveDirection.Magnitude < MovementConfig.MinMoveMagnitude then
		return currentDirection.Unit
	end

	local inputDirection = inputMoveDirection.Unit
	local alignment = currentDirection.Unit:Dot(inputDirection)
	if alignment < SLIDE_STEER_DOT_THRESHOLD then
		return currentDirection.Unit
	end

	local responsiveness = MovementConfig.SlideSteerResponsiveness * math.clamp(alignment, 0, 1)
	local steered = smoothVector(currentDirection.Unit, inputDirection, responsiveness, dt)
	if steered.Magnitude < MovementConfig.MinMoveMagnitude then
		return currentDirection.Unit
	end

	return steered.Unit
end

function MovementController:_steerRunoutDirection(currentDirection: Vector3, inputMoveDirection: Vector3, dt: number): Vector3
	if currentDirection.Magnitude < MovementConfig.MinMoveMagnitude then
		return currentDirection
	end

	if inputMoveDirection.Magnitude < MovementConfig.MinMoveMagnitude then
		return currentDirection.Unit
	end

	local inputDirection = inputMoveDirection.Unit
	local alignment = currentDirection.Unit:Dot(inputDirection)
	if alignment < MovementConfig.GroundRunoutForwardDotThreshold then
		return currentDirection.Unit
	end

	local steered = smoothVector(currentDirection.Unit, inputDirection, MovementConfig.GroundRunoutSteerResponsiveness, dt)
	if steered.Magnitude < MovementConfig.MinMoveMagnitude then
		return currentDirection.Unit
	end

	return steered.Unit
end

function MovementController:_canPreserveGroundRunout(inputMoveDirection: Vector3, isGrounded: boolean): boolean
	if not (isGrounded and self._sprintHeld and inputMoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude) then
		return false
	end

	local referenceDirection = if self._groundRunoutDirection.Magnitude >= MovementConfig.MinMoveMagnitude
		then self._groundRunoutDirection
		else self._airCarryDirection
	if referenceDirection.Magnitude < MovementConfig.MinMoveMagnitude then
		referenceDirection = self._lastSlideDirection
	end
	if referenceDirection.Magnitude < MovementConfig.MinMoveMagnitude then
		return false
	end

	return referenceDirection.Unit:Dot(inputMoveDirection.Unit) >= MovementConfig.GroundRunoutForwardDotThreshold
end

function MovementController:_startGroundRunout(now: number, direction: Vector3, speed: number)
	if direction.Magnitude < MovementConfig.MinMoveMagnitude or speed <= MovementConfig.GroundRunoutExitSpeed then
		self:_clearSlidePhase()
		return
	end

	self._slidePhase = SLIDE_PHASE_GROUND_RUNOUT
	self._slideDirection = Vector3.zero
	self._slideSpeed = 0
	self._slideStartTime = NEVER
	self._slideBlockedStartTime = NEVER
	self._airCarryDirection = Vector3.zero
	self._airCarryStartSpeed = 0
	self._airCarryStartTime = NEVER
	self._airCarryEndTime = NEVER
	self._groundRunoutDirection = direction.Unit
	self._groundRunoutSpeed = math.clamp(speed, MovementConfig.GroundRunoutExitSpeed, MovementConfig.SlideJumpMaxSpeed)
	self._groundRunoutStartTime = now
	self._groundRunoutLandingSpeed = self._groundRunoutSpeed
	self:_setGroundControllerTuning(false)
end

function MovementController:_stopGroundRunout()
	if self:_isGroundRunout() then
		self._lastSlideDirection = self._groundRunoutDirection
		self._lastSlideSpeed = self._groundRunoutSpeed
	end

	self:_clearSlidePhase()
end

function MovementController:_isSlideBlocked(now: number): boolean
	local rootPart = self._rootPart
	if not (rootPart and rootPart.Parent and self._slideDirection.Magnitude >= MovementConfig.MinMoveMagnitude) then
		return true
	end

	local horizontalVelocity = flattenVelocity(rootPart.AssemblyLinearVelocity)
	local forwardSpeed = horizontalVelocity:Dot(self._slideDirection.Unit)
	local minimumForwardSpeed = MovementConfig.SlideBlockedSpeedFloor
	if self._slideSpeed < minimumForwardSpeed or forwardSpeed >= minimumForwardSpeed then
		self._slideBlockedStartTime = NEVER
		return false
	end

	if self._slideBlockedStartTime == NEVER then
		self._slideBlockedStartTime = now
		return false
	end

	return now - self._slideBlockedStartTime >= MovementConfig.SlideBlockedTime
end

function MovementController:_updateGroundSlide(now: number, dt: number, inputMoveDirection: Vector3, isGrounded: boolean)
	if not self:_isGroundSlide() then
		return
	end

	if not isGrounded then
		local carrySpeed = self._slideSpeed
		local carryDirection = self._slideDirection
		self:_rememberSlideEnd(now)
		if carryDirection.Magnitude >= MovementConfig.MinMoveMagnitude and carrySpeed >= MovementConfig.SlideExitSpeed then
			self:_startAirCarry(now, carryDirection, carrySpeed)
		else
			self:_clearSlidePhase()
		end
		return
	end

	local slideElapsed = now - self._slideStartTime
	local releaseCanEndSlide = not self._crouchHeld and slideElapsed >= MovementConfig.SlideMinDuration
	local maxDurationReached = slideElapsed >= MovementConfig.SlideMaxDuration
	if releaseCanEndSlide or maxDurationReached then
		self:_stopGroundSlide(now)
		return
	end

	if inputMoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude then
		local inputDirection = inputMoveDirection.Unit
		local inputAlignment = self._slideDirection:Dot(inputDirection)
		if inputAlignment <= SLIDE_OPPOSITE_DOT_THRESHOLD then
			self:_stopGroundSlide(now)
			return
		end
		self._slideDirection = self:_steerDirection(self._slideDirection, inputMoveDirection, dt)
	end

	local slopeAlignment = self:_getSlopeAlignment()
	local speedDelta = self:_getSlideSpeedDelta(slopeAlignment) * dt
	self._slideSpeed = math.clamp(self._slideSpeed + speedDelta, 0, self:_getSlideSpeedCap(slopeAlignment))
	self._lastSlideDirection = self._slideDirection
	self._lastSlideSpeed = self._slideSpeed

	if self:_isSlideBlocked(now) or (slideElapsed >= MovementConfig.SlideMinDuration and self._slideSpeed < MovementConfig.SlideExitSpeed) then
		self:_stopGroundSlide(now)
	end
end

function MovementController:_updateAirCarry(now: number, dt: number, inputMoveDirection: Vector3, isGrounded: boolean)
	if not self:_isAirCarry() then
		return
	end

	if isGrounded then
		if self:_isSlideJumpBurstActive(now)
			and now - self._slideJumpBurstStartTime <= MovementConfig.SlideJumpBurstGroundForgiveness
		then
			return
		end

		local landingSpeed = self:_getAirCarrySpeed(now)
		landingSpeed = math.clamp(
			math.max(landingSpeed, self:_getHorizontalSpeed()),
			MovementConfig.GroundRunoutExitSpeed,
			MovementConfig.SlideJumpMaxSpeed
		)
		local landingDirection = self._airCarryDirection
		if self:_canPreserveGroundRunout(inputMoveDirection, isGrounded) then
			self:_startGroundRunout(now, landingDirection, landingSpeed)
		else
			self:_clearSlidePhase()
		end
		return
	end

	if now >= self._airCarryEndTime then
		self:_clearSlidePhase()
		return
	end

	self._airCarryDirection = self:_steerDirection(self._airCarryDirection, inputMoveDirection, dt)
end

function MovementController:_updateGroundRunout(now: number, dt: number, inputMoveDirection: Vector3, isGrounded: boolean)
	if not self:_isGroundRunout() then
		return
	end

	if not self:_canPreserveGroundRunout(inputMoveDirection, isGrounded) then
		self:_clearSlidePhase()
		return
	end

	local inputAlignment = self._groundRunoutDirection:Dot(inputMoveDirection.Unit)
	if inputAlignment <= MovementConfig.GroundRunoutOppositeDotThreshold then
		self:_stopGroundRunout()
		return
	end

	self._groundRunoutDirection = self:_steerRunoutDirection(self._groundRunoutDirection, inputMoveDirection, dt)
	self._groundRunoutSpeed = math.max(
		MovementConfig.GroundRunoutExitSpeed,
		self._groundRunoutSpeed - (MovementConfig.GroundRunoutDrainRate * dt)
	)

	if self._groundRunoutSpeed <= MovementConfig.GroundRunoutExitSpeed then
		self:_stopGroundRunout()
		return
	end

	self._lastSlideDirection = self._groundRunoutDirection
	self._lastSlideSpeed = self._groundRunoutSpeed
end

function MovementController:_consumeSlideJumpCarry(now: number)
	if self:_isGroundSlide() then
		local carryDirection = self._slideDirection
		local sourceSpeed = self:_getSlideJumpSourceSpeed(carryDirection, self._slideSpeed)
		local carrySpeed = self:_getSlideJumpCarrySpeed(sourceSpeed)
		local burstEndSpeed = self:_getSlideJumpBurstEndSpeed(carrySpeed)
		self:_rememberSlideEnd(now)
		self:_startAirCarry(now, carryDirection, carrySpeed)
		return {
			direction = carryDirection,
			speed = carrySpeed,
			burstEndSpeed = burstEndSpeed,
			burst = true,
		}
	end

	if self:_isGroundRunout() then
		self:_stopGroundRunout()
		return nil
	end

	if now - self._lastSlideEndTime <= MovementConfig.SlideJumpGraceTime
		and self._lastSlideDirection.Magnitude >= MovementConfig.MinMoveMagnitude
		and self._lastSlideSpeed >= MovementConfig.SlideExitSpeed
	then
		local sourceSpeed = self:_getSlideJumpSourceSpeed(self._lastSlideDirection, self._lastSlideSpeed)
		local carrySpeed = self:_getSlideJumpCarrySpeed(sourceSpeed)
		local burstEndSpeed = self:_getSlideJumpBurstEndSpeed(carrySpeed)
		self:_startAirCarry(now, self._lastSlideDirection, carrySpeed)
		return {
			direction = self._lastSlideDirection,
			speed = carrySpeed,
			burstEndSpeed = burstEndSpeed,
			burst = true,
		}
	end

	return nil
end

function MovementController:_requestGroundJump(now: number): boolean
	local character = self._character
	local rootPart = self._rootPart
	local humanoid = self._humanoid
	if not (character and rootPart and rootPart.Parent and humanoid) then
		return false
	end

	local slideJumpCarry = self:_consumeSlideJumpCarry(now)

	humanoid.Jump = true
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	if slideJumpCarry and slideJumpCarry.burst then
		self:_startSlideJumpBurst(now, slideJumpCarry.direction, slideJumpCarry.speed, slideJumpCarry.burstEndSpeed)
	end

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
	character:SetAttribute("Movement_SlidePhase", data.slidePhase)
	character:SetAttribute("Movement_SlideSpeed", data.slideSpeed)
	character:SetAttribute("Movement_SlideJumpBurstActive", data.slideJumpBurstActive)
	character:SetAttribute("Movement_HorizontalSpeed", data.horizontalSpeed)
end

function MovementController:_unbindCharacter()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	self:_setGroundControllerTuning(false)
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
	self._crouchPressConsumedBySlide = false
	self._isCrouching = false
	self._slidePhase = SLIDE_PHASE_NONE
	self._slideDirection = Vector3.zero
	self._slideSpeed = 0
	self._slideStartTime = NEVER
	self._slideBlockedStartTime = NEVER
	self._lastSlideEndTime = NEVER
	self._slideRequestPending = false
	self._lastSlideDirection = Vector3.zero
	self._lastSlideSpeed = 0
	self._airCarryDirection = Vector3.zero
	self._airCarryStartSpeed = 0
	self._airCarryStartTime = NEVER
	self._airCarryEndTime = NEVER
	self._groundRunoutDirection = Vector3.zero
	self._groundRunoutSpeed = 0
	self._groundRunoutStartTime = NEVER
	self._groundRunoutLandingSpeed = 0
	self:_clearSlideEntryBurst()
	self:_clearSlideJumpBurst()
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
	if isBombKnockbackActive(self._character) then
		self:_clearSlidePhase()
	end

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

	local inputMoveDirection = getCameraRelativeDirection(getMoveVectorWithDeadzone(controls:GetMoveVector()))
	local hasInputMove = inputMoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude
	local sprintIntent = isGrounded and self._sprintHeld and hasInputMove

	if self._slideRequestPending then
		self._slideRequestPending = false
		if self:_isGroundRunout() then
			self:_stopGroundRunout()
		end
		if self:_canStartSlide(now, inputMoveDirection, isGrounded, sprintIntent) then
			self:_startGroundSlide(now, inputMoveDirection)
		end
	end

	self:_updateGroundSlide(now, dt, inputMoveDirection, isGrounded)
	self:_updateAirCarry(now, dt, inputMoveDirection, isGrounded)
	self:_updateGroundRunout(now, dt, inputMoveDirection, isGrounded)

	local isSliding = self:_isGroundSlide() and isGrounded
	local isAirCarry = self:_isAirCarry()
	local isGroundRunout = self:_isGroundRunout()
	local isCrouching = isGrounded
		and self._crouchHeld
		and not self._crouchPressConsumedBySlide
		and not isSliding
		and not isGroundRunout
	self._isCrouching = isCrouching

	local targetMoveDirection = inputMoveDirection
	local targetSpeed = MovementConfig.AirMoveSpeed
	local slideSpeed = 0

	if isSliding then
		targetMoveDirection = self._slideDirection
		targetSpeed = self._slideSpeed
		slideSpeed = self._slideSpeed
	elseif isAirCarry then
		targetMoveDirection = self._airCarryDirection
		targetSpeed = math.max(MovementConfig.AirMoveSpeed, self:_getAirCarrySpeed(now))
		slideSpeed = targetSpeed
	elseif isGroundRunout then
		targetMoveDirection = self._groundRunoutDirection
		targetSpeed = self._groundRunoutSpeed
		slideSpeed = targetSpeed
	elseif isGrounded and isCrouching then
		targetSpeed = MovementConfig.CrouchMoveSpeed
	elseif isGrounded and sprintIntent then
		targetSpeed = MovementConfig.SprintMoveSpeed
	elseif isGrounded then
		targetSpeed = MovementConfig.WalkMoveSpeed
	end

	local adminWalkSpeed = getAdminWalkSpeedOverride()
	if adminWalkSpeed then
		targetSpeed = adminWalkSpeed
	end

	local hasMoveInput = targetMoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude
	local isSprinting = sprintIntent and not isSliding and not isCrouching

	local responsiveness
	if isSliding then
		responsiveness = MovementConfig.SlideSteerResponsiveness
	elseif isAirCarry then
		responsiveness = MovementConfig.AirMoveResponsiveness
	elseif isGroundRunout then
		responsiveness = MovementConfig.GroundRunoutSteerResponsiveness
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

	if isSliding or isAirCarry or isGroundRunout then
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

	local shiftLocked = readCameraShiftLocked(self._character)
	local targetFacingDirection = if MovementConfig.FaceCameraDirection and shiftLocked
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
		slidePhase = self._slidePhase,
		slideSpeed = slideSpeed,
		slideJumpBurstActive = self:_isSlideJumpBurstActive(now),
		horizontalSpeed = self:_getHorizontalSpeed(),
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
			local slideIntent = self._sprintHeld
			self._slideRequestPending = slideIntent
			self._crouchPressConsumedBySlide = slideIntent
		end
		self._crouchHeld = true
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		self._crouchHeld = false
		self._crouchPressConsumedBySlide = false
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
	character:SetAttribute("Movement_SlidePhase", SLIDE_PHASE_NONE)
	character:SetAttribute("Movement_SlideSpeed", 0)
	character:SetAttribute("Movement_SlideJumpBurstActive", false)
	character:SetAttribute("Movement_HorizontalSpeed", self:_getHorizontalSpeed())

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
		local now = os.clock()
		self:_updateSlideEntryBurst(now)
		self:_updateSlideJumpBurst(now)
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
