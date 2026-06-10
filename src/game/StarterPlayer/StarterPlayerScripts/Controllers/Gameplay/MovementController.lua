local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)

local LocalPlayer = Players.LocalPlayer
local RENDER_STEP_NAME = "BombBattlesMovementController"
local SPRINT_ACTION_NAME = "BombBattlesSprint"
local CROUCH_ACTION_NAME = "BombBattlesCrouch"
local AIR_CONTROL_ATTACHMENT_NAME = "BombBattlesAirControlAttachment"
local AIR_CONTROL_FORCE_NAME = "BombBattlesAirControlForce"
local AIR_CONTROL_FORCE_AIRBORNE_UNTIL_ATTR = "AirControl_ForceAirborneUntil"
local AIR_CONTROL_LAUNCH_SOURCE_ATTR = "AirControl_LaunchSource"
local AIR_CONTROL_LAUNCH_SERIAL_ATTR = "AirControl_LaunchSerial"
local AIR_CONTROL_LAUNCHED_AT_ATTR = "AirControl_LaunchedAt"
local GRAVITY_BOOTS_ACTIVE_UNTIL_ATTR = "GravityBoots_ActiveUntil"
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value + 1
local CONTROLLER_LOOKUP_TIMEOUT = 0.75
local CONTROLLER_BIND_RETRY_TIMEOUT = 20
local CONTROLLER_BIND_RETRY_INTERVAL = 0.25
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
local AIR_LAUNCH_SOURCE_DEFAULT = "Default"
local AIR_LAUNCH_SOURCE_NORMAL_JUMP = "NormalJump"
local AIR_LAUNCH_SOURCE_DOUBLE_JUMP = "DoubleJump"
local AIR_LAUNCH_SOURCE_SLIDE_JUMP = "SlideJump"
local AIR_LAUNCH_SOURCE_KNOCKBACK = "Knockback"
local LANDING_MODE_NONE = "None"
local LANDING_MODE_LOW = "Low"
local LANDING_MODE_MEDIUM = "Medium"
local LANDING_MODE_HIGH = "High"
local LANDING_MODE_RUNOUT = "Runout"

type Controls = {
	GetMoveVector: (Controls) -> Vector3,
}

local MovementController = {}

MovementController._character = nil :: Model?
MovementController._characterConnection = nil :: RBXScriptConnection?
MovementController._fallingDownStateConnection = nil :: RBXScriptConnection?
MovementController._fallingDownSyncedStateConnection = nil :: RBXScriptConnection?
MovementController._fallingDownSyncedState = nil :: Instance?
MovementController._jumpRequestConnection = nil :: RBXScriptConnection?
MovementController._heartbeatConnection = nil :: RBXScriptConnection?
MovementController._warnedCharacters = {} :: { [Model]: boolean }
MovementController._bindSerial = 0
MovementController._controls = nil :: Controls?
MovementController._controllerManager = nil :: any
MovementController._groundController = nil :: any
MovementController._airController = nil :: any
MovementController._airControllerBaseMoveMaxForce = nil :: number?
MovementController._cclAirMoveSuppressed = false
MovementController._cclAirMoveMaxForce = 0
MovementController._cclActiveController = ""
MovementController._groundSensor = nil :: any
MovementController._humanoid = nil :: Humanoid?
MovementController._rootPart = nil :: BasePart?
MovementController._smoothedMoveDirection = Vector3.zero
MovementController._smoothedFacingDirection = Vector3.zero
MovementController._smoothedFacingYaw = nil :: number?
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
MovementController._lastSlideRequestTime = NEVER
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
MovementController._groundRunoutInputDotThreshold = 0
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
MovementController._airControlAttachment = nil :: Attachment?
MovementController._airControlForce = nil :: VectorForce?
MovementController._airControlActive = false
MovementController._airControlState = "Grounded"
MovementController._airControlGravityScale = 1
MovementController._airControlForceVector = Vector3.zero
MovementController._airControlSteerForce = Vector3.zero
MovementController._airControlBrakeForce = Vector3.zero
MovementController._airControlFallBrakeForce = Vector3.zero
MovementController._airControlVerticalSpeed = 0
MovementController._airControlHorizontalSpeed = 0
MovementController._airControlLaunchSource = AIR_LAUNCH_SOURCE_DEFAULT
MovementController._airControlLaunchSerial = 0
MovementController._airControlLaunchedAt = NEVER
MovementController._airControlForceAirborneUntil = NEVER
MovementController._lastAirControlLaunchTime = NEVER
MovementController._groundedCandidateStartTime = NEVER
MovementController._observedAirControlLaunchSerial = 0
MovementController._lastObservedKnockbackUntil = NEVER
MovementController._gravityBootsActive = false
MovementController._gravityBootsAirSteeringScale = 1
MovementController._gravityBootsAirBrakeScale = 1
MovementController._gravityBootsAirGravityScaleMultiplier = 1
MovementController._maxAirDownwardSpeed = 0
MovementController._maxAirHorizontalSpeed = 0
MovementController._maxAirHorizontalVelocity = Vector3.zero
MovementController._landingImpactSpeed = 0
MovementController._landingHorizontalSpeed = 0
MovementController._landingHorizontalVelocity = Vector3.zero
MovementController._landingSerial = 0
MovementController._landingMode = LANDING_MODE_NONE
MovementController._landingRecoveryStartTime = NEVER
MovementController._landingRecoveryUntil = NEVER
MovementController._landingRecoveryAlpha = 0
MovementController._landingInputGraceUntil = NEVER
MovementController._landingRunoutEligible = false

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

local function directionToYaw(direction: Vector3): number?
	local flat = flattenDirection(direction)
	if flat.Magnitude <= 0 then
		return nil
	end

	return math.atan2(-flat.X, -flat.Z)
end

local function yawToDirection(yaw: number): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

local function getTiltDegrees(cframe: CFrame): number
	local upDot = math.clamp(cframe.UpVector:Dot(Vector3.yAxis), -1, 1)
	return math.deg(math.acos(upDot))
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

local function readNumberProperty(instance: any, propertyName: string): number?
	if not instance then
		return nil
	end

	local ok, value = pcall(function()
		return instance[propertyName]
	end)
	if not ok or typeof(value) ~= "number" then
		return nil
	end

	return value
end

local function writeNumberProperty(instance: any, propertyName: string, value: number): boolean
	if not instance then
		return false
	end

	local ok = pcall(function()
		instance[propertyName] = value
	end)
	return ok
end

local function readActiveControllerName(controllerManager: any): string
	if not controllerManager then
		return ""
	end

	local ok, activeController = pcall(function()
		return controllerManager.ActiveController
	end)
	if not ok or activeController == nil then
		return ""
	end
	if typeof(activeController) == "Instance" then
		return activeController.ClassName
	end

	return tostring(activeController)
end

local function getBombKnockbackUntil(character: Model?): number
	if not character then
		return NEVER
	end

	local knockbackUntil = character:GetAttribute(KNOCKBACK_UNTIL_ATTR)
	return if typeof(knockbackUntil) == "number" then knockbackUntil else NEVER
end

local function exponentialAlpha(responsiveness: number, dt: number): number
	return 1 - math.exp(-responsiveness * dt)
end

local function smoothstep(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * (3 - (2 * alpha))
end

local function smoothVector(current: Vector3, target: Vector3, responsiveness: number, dt: number): Vector3
	return current:Lerp(target, exponentialAlpha(responsiveness, dt))
end

local function smoothYaw(current: number, target: number, responsiveness: number, dt: number): number
	local delta = math.atan2(math.sin(target - current), math.cos(target - current))
	return current + (delta * exponentialAlpha(responsiveness, dt))
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

local function getFallingDownSyncedState(character: Model): Instance?
	local abilityManagerActor = character:FindFirstChild("AbilityManagerActor")
	local abilities = abilityManagerActor and abilityManagerActor:FindFirstChild("Abilities")
	local fallingDown = abilities and abilities:FindFirstChild("FallingDown")
	return fallingDown and fallingDown:FindFirstChild("SyncedState") or nil
end

local function disableFallingDownSyncedState(instance: Instance): string
	if instance:IsA("ValueBase") then
		local ok = pcall(function()
			(instance :: any).Value = "Disabled"
		end)
		return if ok then "Disabled" else instance.ClassName
	end

	if instance:IsA("Configuration") then
		local enabledOk = pcall(function()
			instance:SetAttribute("Enabled", false)
		end)
		pcall(function()
			instance:SetAttribute("Active", false)
		end)
		return if enabledOk then "Disabled" else instance.ClassName
	end

	return instance.ClassName
end

local function disableFallingDownRuntimeState(character: Model, humanoid: Humanoid?): (boolean, string, Instance?)
	local humanoidDisabled = false
	if humanoid then
		humanoidDisabled = pcall(function()
			humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		end)
	end

	local syncedState = getFallingDownSyncedState(character)
	local syncedValue = "Missing"
	if syncedState then
		syncedValue = disableFallingDownSyncedState(syncedState)
	end

	character:SetAttribute("Movement_FallingDownStateDisabled", humanoidDisabled)
	character:SetAttribute("Movement_FallingDownSyncedState", syncedValue)
	return humanoidDisabled, syncedValue, syncedState
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
		return nil
	end

	local airController = getDescendantOfClass(character, "AirController")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and MovementConfig.DisableHumanoidAutoRotate then
		humanoid.AutoRotate = false
	end
	if humanoid then
		disableFallingDownRuntimeState(character, humanoid)
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

function MovementController:_captureAirControllerDefaults()
	self._airControllerBaseMoveMaxForce = readNumberProperty(self._airController, "MoveMaxForce")
	self:_refreshCCLDebug()
end

function MovementController:_refreshCCLDebug()
	self._cclActiveController = readActiveControllerName(self._controllerManager)
	self._cclAirMoveMaxForce = readNumberProperty(self._airController, "MoveMaxForce") or 0
end

function MovementController:_setCCLAirMoveSuppressed(suppressed: boolean)
	local airController = self._airController
	local baseMoveMaxForce = self._airControllerBaseMoveMaxForce
	if not airController or baseMoveMaxForce == nil then
		self._cclAirMoveSuppressed = false
		self:_refreshCCLDebug()
		return
	end

	local desiredMoveMaxForce = if suppressed then 0 else baseMoveMaxForce
	local wroteMoveMaxForce = writeNumberProperty(airController, "MoveMaxForce", desiredMoveMaxForce)
	self._cclAirMoveSuppressed = suppressed and wroteMoveMaxForce
	self:_refreshCCLDebug()
end

function MovementController:_destroyAirControlForce()
	if self._airControlForce then
		self._airControlForce.Enabled = false
		self._airControlForce.Force = Vector3.zero
		self._airControlForce:Destroy()
	end
	if self._airControlAttachment then
		self._airControlAttachment:Destroy()
	end

	self._airControlAttachment = nil
	self._airControlForce = nil
	self._airControlActive = false
	self._airControlState = "Grounded"
	self._airControlGravityScale = 1
	self._airControlForceVector = Vector3.zero
	self:_setCCLAirMoveSuppressed(false)
end

function MovementController:_ensureAirControlForce(): VectorForce?
	local rootPart = self._rootPart
	if not (rootPart and rootPart.Parent) then
		self:_destroyAirControlForce()
		return nil
	end

	if self._airControlForce
		and self._airControlForce.Parent == rootPart
		and self._airControlAttachment
		and self._airControlAttachment.Parent == rootPart
	then
		return self._airControlForce
	end

	self:_destroyAirControlForce()

	local staleForce = rootPart:FindFirstChild(AIR_CONTROL_FORCE_NAME)
	if staleForce and staleForce:IsA("VectorForce") then
		staleForce.Enabled = false
		staleForce.Force = Vector3.zero
		staleForce:Destroy()
	end
	local staleAttachment = rootPart:FindFirstChild(AIR_CONTROL_ATTACHMENT_NAME)
	if staleAttachment and staleAttachment:IsA("Attachment") then
		staleAttachment:Destroy()
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = AIR_CONTROL_ATTACHMENT_NAME
	attachment.Parent = rootPart

	local vectorForce = Instance.new("VectorForce")
	vectorForce.Name = AIR_CONTROL_FORCE_NAME
	vectorForce.Attachment0 = attachment
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.ApplyAtCenterOfMass = true
	vectorForce.Enabled = false
	vectorForce.Force = Vector3.zero
	vectorForce.Parent = rootPart

	self._airControlAttachment = attachment
	self._airControlForce = vectorForce
	return vectorForce
end

function MovementController:_setAirControlEnabled(enabled: boolean)
	local vectorForce = self._airControlForce
	if vectorForce then
		vectorForce.Enabled = enabled
		if not enabled then
			vectorForce.Force = Vector3.zero
		end
	end

	self._airControlActive = enabled
	self:_setCCLAirMoveSuppressed(enabled)
	if not enabled then
		self._airControlState = "Grounded"
		self._airControlGravityScale = 1
		self._airControlForceVector = Vector3.zero
		self._airControlSteerForce = Vector3.zero
		self._airControlBrakeForce = Vector3.zero
		self._airControlFallBrakeForce = Vector3.zero
		self._airControlVerticalSpeed = 0
		self._airControlHorizontalSpeed = 0
	end
end

function MovementController:_getAirControlLaunchProfile(source: string?)
	local profiles = MovementConfig.AirControl.LaunchProfiles
	local defaultProfile = profiles.Default or {}
	if typeof(source) ~= "string" or source == "" then
		return defaultProfile
	end

	return profiles[source] or defaultProfile
end

function MovementController:_getIntendedGroundMoveSpeed(): number
	local speed = MovementConfig.WalkMoveSpeed
	local humanoid = self._humanoid
	local hasMoveInput = humanoid ~= nil and humanoid.MoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude

	if self._isCrouching then
		speed = MovementConfig.CrouchMoveSpeed
	elseif self._sprintHeld and hasMoveInput then
		speed = MovementConfig.SprintMoveSpeed
	end

	local adminWalkSpeed = getAdminWalkSpeedOverride()
	if adminWalkSpeed then
		speed = adminWalkSpeed
	end

	return speed
end

function MovementController:_getGravityBootsAirControlBuff()
	local character = self._character
	if not character then
		return nil
	end

	local definition = AbilityConfig.GetDefinition("GravityBoots")
	if not definition then
		return nil
	end

	local attribute = definition.activeUntilAttribute
	if typeof(attribute) ~= "string" or attribute == "" then
		attribute = GRAVITY_BOOTS_ACTIVE_UNTIL_ATTR
	end

	local activeUntil = character:GetAttribute(attribute)
	if typeof(activeUntil) ~= "number" or activeUntil <= workspace:GetServerTimeNow() then
		return nil
	end

	return {
		steeringScale = math.max(tonumber(definition.airSteeringScale) or 1, 0),
		brakeScale = math.max(tonumber(definition.airBrakeScale) or 1, 0),
		gravityScaleMultiplier = math.clamp(tonumber(definition.airGravityScaleMultiplier) or 1, 0, 1),
	}
end

function MovementController:_setAirControlLaunchState(
	now: number,
	source: string?,
	minAirTimeOverride: number?,
	publishAttributes: boolean
)
	local launchSource = if typeof(source) == "string" and source ~= "" then source else AIR_LAUNCH_SOURCE_DEFAULT

	local profile = self:_getAirControlLaunchProfile(launchSource)
	local minAirTime = if typeof(minAirTimeOverride) == "number"
		then math.max(minAirTimeOverride, 0)
		else math.max(tonumber(profile.MinAirTime) or 0, 0)
	local forceAirborneUntil = now + minAirTime

	self._lastAirControlLaunchTime = now
	self._airControlLaunchSource = launchSource
	self._airControlLaunchedAt = now
	self._airControlForceAirborneUntil = math.max(self._airControlForceAirborneUntil, forceAirborneUntil)
	self._groundedCandidateStartTime = NEVER

	if publishAttributes then
		local character = self._character
		if character then
			self._airControlLaunchSerial += 1
			self._observedAirControlLaunchSerial = self._airControlLaunchSerial
			character:SetAttribute(AIR_CONTROL_FORCE_AIRBORNE_UNTIL_ATTR, self._airControlForceAirborneUntil)
			character:SetAttribute(AIR_CONTROL_LAUNCH_SOURCE_ATTR, launchSource)
			character:SetAttribute(AIR_CONTROL_LAUNCH_SERIAL_ATTR, self._airControlLaunchSerial)
			character:SetAttribute(AIR_CONTROL_LAUNCHED_AT_ATTR, now)
		end
	end
end

function MovementController:_recordAirControlLaunch(now: number, source: string?, minAirTimeOverride: number?)
	self:_setAirControlLaunchState(now, source, minAirTimeOverride, true)
end

function MovementController:_consumeExternalAirControlLaunch(now: number)
	local character = self._character
	if not character then
		return
	end

	local launchSerial = character:GetAttribute(AIR_CONTROL_LAUNCH_SERIAL_ATTR)
	if typeof(launchSerial) ~= "number" or launchSerial <= self._observedAirControlLaunchSerial then
		return
	end

	self._observedAirControlLaunchSerial = launchSerial
	local launchSource = character:GetAttribute(AIR_CONTROL_LAUNCH_SOURCE_ATTR)
	local launchedAt = character:GetAttribute(AIR_CONTROL_LAUNCHED_AT_ATTR)
	local forceAirborneUntil = character:GetAttribute(AIR_CONTROL_FORCE_AIRBORNE_UNTIL_ATTR)
	local launchTime = if typeof(launchedAt) == "number" then launchedAt else now
	local minAirTime = if typeof(forceAirborneUntil) == "number" then math.max(forceAirborneUntil - launchTime, 0) else nil

	self:_setAirControlLaunchState(launchTime, if typeof(launchSource) == "string" then launchSource else nil, minAirTime, false)
	if typeof(forceAirborneUntil) == "number" then
		self._airControlForceAirborneUntil = math.max(self._airControlForceAirborneUntil, forceAirborneUntil)
	end
end

function MovementController:_getActiveAirControlProfile(now: number)
	local profile = self:_getAirControlLaunchProfile(self._airControlLaunchSource)
	local modifierDuration = tonumber(profile.ModifierDuration) or 0
	local modifierActive = self._airControlLaunchedAt ~= NEVER and now - self._airControlLaunchedAt <= modifierDuration
	return profile, modifierActive
end

function MovementController:_shouldSuppressGroundedForLaunch(now: number): boolean
	local rootPart = self._rootPart
	if not (rootPart and rootPart.Parent) then
		return false
	end

	local airControl = MovementConfig.AirControl
	local velocityY = rootPart.AssemblyLinearVelocity.Y
	if velocityY >= airControl.GroundedUpVelocityThreshold then
		return true
	end

	if now <= self._airControlForceAirborneUntil then
		return true
	end

	return now - self._lastAirControlLaunchTime <= airControl.LaunchGroundSuppressionTime and velocityY > -2
end

function MovementController:_resolveGrounded(now: number, rawGrounded: boolean): boolean
	if not rawGrounded or self:_shouldSuppressGroundedForLaunch(now) then
		self._groundedCandidateStartTime = NEVER
		return false
	end

	if self._isGrounded then
		self._groundedCandidateStartTime = NEVER
		return true
	end

	if self._groundedCandidateStartTime == NEVER then
		self._groundedCandidateStartTime = now
	end

	local profile = self:_getAirControlLaunchProfile(self._airControlLaunchSource)
	local landingConfirmTime = tonumber(profile.LandingConfirmTime) or MovementConfig.AirControl.LandingConfirmTime
	return now - self._groundedCandidateStartTime >= landingConfirmTime
end

function MovementController:_getAirControlMoveDirection(): (Vector3, number)
	local humanoid = self._humanoid
	if not humanoid then
		return Vector3.zero, 0
	end

	local moveDirection = humanoid.MoveDirection
	local flatDirection = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	local magnitude = math.min(flatDirection.Magnitude, 1)
	if magnitude < MovementConfig.MinMoveMagnitude then
		return Vector3.zero, 0
	end

	return flatDirection.Unit, magnitude
end

function MovementController:_calculateAirControlForce(dt: number)
	self._gravityBootsActive = false
	self._gravityBootsAirSteeringScale = 1
	self._gravityBootsAirBrakeScale = 1
	self._gravityBootsAirGravityScaleMultiplier = 1

	local rootPart = self._rootPart
	if not (rootPart and rootPart.Parent) then
		return {
			force = Vector3.zero,
			state = "Grounded",
			gravityScale = 1,
			steerForce = Vector3.zero,
			brakeForce = Vector3.zero,
			fallBrakeForce = Vector3.zero,
			verticalSpeed = 0,
			horizontalSpeed = 0,
		}
	end

	local airControl = MovementConfig.AirControl
	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalVelocity = flattenVelocity(velocity)
	local horizontalSpeed = horizontalVelocity.Magnitude
	local mass = math.max(rootPart.AssemblyMass, 0)
	if mass <= 0 then
		return {
			force = Vector3.zero,
			state = "Airborne",
			gravityScale = 1,
			steerForce = Vector3.zero,
			brakeForce = Vector3.zero,
			fallBrakeForce = Vector3.zero,
			verticalSpeed = velocity.Y,
			horizontalSpeed = horizontalSpeed,
		}
	end

	local gravityBootsBuff = self:_getGravityBootsAirControlBuff()
	if gravityBootsBuff then
		self._gravityBootsActive = true
		self._gravityBootsAirSteeringScale = gravityBootsBuff.steeringScale
		self._gravityBootsAirBrakeScale = gravityBootsBuff.brakeScale
		self._gravityBootsAirGravityScaleMultiplier = gravityBootsBuff.gravityScaleMultiplier
	end

	local verticalSpeed = velocity.Y
	local state
	if math.abs(verticalSpeed) <= airControl.ApexVelocityThreshold then
		state = "Apex"
	elseif verticalSpeed > 0 then
		state = "Rising"
	else
		state = "Falling"
	end

	local baseGravityScale = if verticalSpeed >= 0 then airControl.RisingGravityScale else airControl.FallingGravityScale
	local apexAlpha = 1
		- math.clamp(math.abs(verticalSpeed) / math.max(airControl.GravityBlendVelocityRange, 0.001), 0, 1)
	local gravityScale = baseGravityScale + ((airControl.ApexGravityScale - baseGravityScale) * smoothstep(apexAlpha))
	gravityScale = math.clamp(gravityScale, 0, 1)
	if gravityBootsBuff then
		gravityScale = math.clamp(gravityScale * gravityBootsBuff.gravityScaleMultiplier, 0, 1)
	end
	local force = Vector3.yAxis * mass * workspace.Gravity * (1 - gravityScale)

	local fallBrakeForce = Vector3.zero
	local downwardSpeed = math.max(-verticalSpeed, 0)
	if downwardSpeed > airControl.FallBrakeStartSpeed then
		local brakeAcceleration
		if downwardSpeed <= airControl.MaxFallSpeed then
			local softAlpha = smoothstep(
				(downwardSpeed - airControl.FallBrakeStartSpeed)
					/ math.max(airControl.MaxFallSpeed - airControl.FallBrakeStartSpeed, 0.001)
			)
			brakeAcceleration = airControl.FallBrakeAcceleration * softAlpha
		else
			local hardAlpha = smoothstep(
				(downwardSpeed - airControl.MaxFallSpeed)
					/ math.max(airControl.FallBrakeHardSpeed - airControl.MaxFallSpeed, 0.001)
			)
			brakeAcceleration = airControl.FallBrakeAcceleration
				+ ((airControl.FallBrakeHardAcceleration - airControl.FallBrakeAcceleration) * hardAlpha)
		end

		fallBrakeForce = Vector3.yAxis * mass * brakeAcceleration
		force += fallBrakeForce
	end

	local steerForce = Vector3.zero
	local inputDirection, inputMagnitude = self:_getAirControlMoveDirection()
	if inputMagnitude >= MovementConfig.MinMoveMagnitude then
		local alignment = if horizontalSpeed >= MovementConfig.MinMoveMagnitude
			then horizontalVelocity.Unit:Dot(inputDirection)
			else 0
		local steerAcceleration = if alignment >= 0
			then airControl.SideAirAcceleration
				+ ((airControl.ForwardAirAcceleration - airControl.SideAirAcceleration) * math.clamp(alignment, 0, 1))
			else airControl.SideAirAcceleration
				+ ((airControl.ReverseAirAcceleration - airControl.SideAirAcceleration) * math.clamp(-alignment, 0, 1))

		local speedBudgetAlpha = smoothstep(
			(horizontalSpeed - airControl.LowSpeedFullControl)
				/ math.max(airControl.HighSpeedReducedControl - airControl.LowSpeedFullControl, 0.001)
		)
		local speedBudgetScale = 1 + ((airControl.HighSpeedControlScale - 1) * speedBudgetAlpha)
		local profile, modifierActive = self:_getActiveAirControlProfile(os.clock())
		local sourceSteerScale = 1
		if modifierActive then
			sourceSteerScale = sourceSteerScale * (tonumber(profile.SteeringScale) or 1)
			if math.abs(alignment) < 0.5 then
				sourceSteerScale = sourceSteerScale * (tonumber(profile.SideSteeringScale) or 1)
			end
		end
		if gravityBootsBuff then
			sourceSteerScale *= gravityBootsBuff.steeringScale
		end

		local wishSpeed = self:_getIntendedGroundMoveSpeed() * inputMagnitude
		local currentWishSpeed = horizontalVelocity:Dot(inputDirection)
		local addSpeed = wishSpeed - currentWishSpeed
		if addSpeed > 0 then
			local minDt = 1 / 240
			local acceleration = steerAcceleration * inputMagnitude * speedBudgetScale * sourceSteerScale
			local accelerationSpeed = math.min(acceleration * math.max(dt, minDt), addSpeed)
			steerForce = inputDirection * mass * (accelerationSpeed / math.max(dt, minDt))
		end
		force += steerForce
	end

	local brakeForce = Vector3.zero
	local softAirSpeedCap = airControl.SoftAirSpeedCap
	if horizontalSpeed > softAirSpeedCap and horizontalSpeed >= MovementConfig.MinMoveMagnitude then
		local brakeAlpha = math.clamp(
			(horizontalSpeed - softAirSpeedCap) / math.max(airControl.SoftAirBrakeSpeedRange, 0.001),
			0,
			1
		)
		local profile, modifierActive = self:_getActiveAirControlProfile(os.clock())
		local sourceBrakeScale = if modifierActive then tonumber(profile.OverspeedBrakeScale) or 1 else 1
		if gravityBootsBuff then
			sourceBrakeScale *= gravityBootsBuff.brakeScale
		end
		brakeForce = -horizontalVelocity.Unit
			* mass
			* airControl.SoftAirBrakeAcceleration
			* smoothstep(brakeAlpha)
			* sourceBrakeScale
		force += brakeForce
	end

	return {
		force = force,
		state = state,
		gravityScale = gravityScale,
		steerForce = steerForce,
		brakeForce = brakeForce,
		fallBrakeForce = fallBrakeForce,
		verticalSpeed = verticalSpeed,
		horizontalSpeed = horizontalSpeed,
	}
end

function MovementController:_updateAirControl(now: number, isGrounded: boolean, dt: number)
	local humanoid = self._humanoid
	if isGrounded or not humanoid or humanoid.Health <= 0 then
		self:_setAirControlEnabled(false)
		return
	end

	local vectorForce = self:_ensureAirControlForce()
	if not vectorForce then
		self:_setAirControlEnabled(false)
		return
	end

	local data = self:_calculateAirControlForce(dt)
	vectorForce.Force = data.force
	self._airControlForceVector = data.force
	self._airControlSteerForce = data.steerForce
	self._airControlBrakeForce = data.brakeForce
	self._airControlFallBrakeForce = data.fallBrakeForce
	self._airControlVerticalSpeed = data.verticalSpeed
	self._airControlHorizontalSpeed = data.horizontalSpeed
	self._airControlState = data.state
	self._airControlGravityScale = data.gravityScale
	self:_setAirControlEnabled(true)

	if not self._wasGrounded and not self._isGrounded then
		return
	end
	if now - self._lastAirControlLaunchTime > MovementConfig.AirControl.LaunchGroundSuppressionTime then
		self._lastAirControlLaunchTime = NEVER
	end
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

function MovementController:RecordExternalAirControlLaunch(source: string?, minAirTimeOverride: number?)
	self:_recordAirControlLaunch(os.clock(), source, minAirTimeOverride)
end

function MovementController:PublishExternalJump(kind: string)
	self:_publishJump(kind)
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

function MovementController:_setGroundControllerTuning(isSliding: boolean, landingRecoveryAlpha: number?)
	local groundController = self._groundController
	if not groundController then
		return
	end

	if isSliding then
		groundController.AccelerationTime = MovementConfig.SlideGroundAccelerationTime
		groundController.DecelerationTime = MovementConfig.SlideGroundDecelerationTime
		groundController.Friction = MovementConfig.SlideGroundFriction
		groundController.FrictionWeight = MovementConfig.SlideGroundFrictionWeight
	elseif landingRecoveryAlpha ~= nil then
		local alpha = smoothstep(landingRecoveryAlpha)
		local frictionScale = MovementConfig.LandingRecoveryStartFrictionScale
			+ ((MovementConfig.LandingRecoveryEndFrictionScale - MovementConfig.LandingRecoveryStartFrictionScale) * alpha)
		local decelerationScale = MovementConfig.LandingRecoveryStartDecelerationScale
			+ (
				(MovementConfig.LandingRecoveryEndDecelerationScale - MovementConfig.LandingRecoveryStartDecelerationScale)
				* alpha
			)
		groundController.AccelerationTime = MovementConfig.GroundAccelerationTime
		groundController.DecelerationTime = MovementConfig.GroundDecelerationTime * decelerationScale
		groundController.Friction = MovementConfig.GroundFriction * frictionScale
		groundController.FrictionWeight = MovementConfig.GroundFrictionWeight
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
	self._groundRunoutInputDotThreshold = 0
	self:_setGroundControllerTuning(false)
	self:_clearSlideEntryBurst()
	self:_clearSlideJumpBurst()
	if self._landingMode == LANDING_MODE_RUNOUT then
		self:_clearLandingRecovery()
	end
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

function MovementController:_applyHorizontalImpulseFloor(
	rootPart: BasePart,
	direction: Vector3,
	desiredForwardSpeed: number,
	maxSpeed: number,
	launchSource: string?
): number
	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalVelocity = flattenVelocity(velocity)
	local moveDirection = direction.Unit
	local forwardSpeed = horizontalVelocity:Dot(moveDirection)
	if horizontalVelocity.Magnitude >= maxSpeed then
		return forwardSpeed
	end

	local speedDelta = math.max(desiredForwardSpeed - forwardSpeed, 0)
	if speedDelta <= 0 then
		return forwardSpeed
	end

	rootPart:ApplyImpulse(moveDirection * speedDelta * rootPart.AssemblyMass)
	if launchSource then
		self:_recordAirControlLaunch(os.clock(), launchSource)
	end
	return forwardSpeed + speedDelta
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
	local speedCap = self:_getSlideSpeedCap()
	local appliedForwardSpeed = self:_applyHorizontalImpulseFloor(rootPart, direction.Unit, startSpeed, speedCap)
	self._slideSpeed = math.max(self._slideSpeed, math.min(appliedForwardSpeed, speedCap))
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

	self._slideSpeed = math.max(self._slideSpeed, math.min(forwardSpeed, self:_getSlideSpeedCap()))
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
	self:_applyHorizontalImpulseFloor(rootPart, direction.Unit, self._slideJumpBurstStartSpeed, MovementConfig.SlideJumpMaxSpeed)
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

	self._lastSlideDirection = burstDirection
	self._lastSlideSpeed = math.max(self._lastSlideSpeed, math.min(forwardSpeed, MovementConfig.SlideJumpMaxSpeed))
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
	local inputDotThreshold = self._groundRunoutInputDotThreshold
	if inputDotThreshold == 0 then
		inputDotThreshold = MovementConfig.GroundRunoutForwardDotThreshold
	end
	if alignment < inputDotThreshold then
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

	local inputDotThreshold = self._groundRunoutInputDotThreshold
	if inputDotThreshold == 0 then
		inputDotThreshold = MovementConfig.GroundRunoutForwardDotThreshold
	end
	return referenceDirection.Unit:Dot(inputMoveDirection.Unit) >= inputDotThreshold
end

function MovementController:_startGroundRunout(now: number, direction: Vector3, speed: number, inputDotThreshold: number?)
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
	self._groundRunoutInputDotThreshold = inputDotThreshold or MovementConfig.GroundRunoutForwardDotThreshold
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
	local launchSource = if slideJumpCarry and slideJumpCarry.burst
		then AIR_LAUNCH_SOURCE_SLIDE_JUMP
		else AIR_LAUNCH_SOURCE_NORMAL_JUMP
	self:_recordAirControlLaunch(now, launchSource)
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
	local upwardDelta = math.max(MovementConfig.DoubleJumpUpVelocity - velocity.Y, 0)
	if upwardDelta > 0 then
		rootPart:ApplyImpulse(Vector3.yAxis * upwardDelta * rootPart.AssemblyMass)
	end
	humanoid.Jump = true
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	self:_recordAirControlLaunch(now, AIR_LAUNCH_SOURCE_DOUBLE_JUMP)

	self._airJumpCount += 1
	self._lastAirJumpTime = now
	self._lastJumpReplayTime = now
	self:_consumeJumpRequest()
	self:_publishJump("DoubleJump")
	return true
end

function MovementController:_recordJumpRequest()
	local now = os.clock()
	if self:_resolveGrounded(now, self:_isCurrentlyGrounded()) then
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

function MovementController:_getLandingMode(horizontalSpeed: number, impactSpeed: number): string
	if horizontalSpeed >= MovementConfig.LandingHighHorizontalSpeed then
		return LANDING_MODE_HIGH
	end
	if horizontalSpeed >= MovementConfig.LandingMediumHorizontalSpeed
		or impactSpeed >= MovementConfig.LandingMediumImpactSpeed
	then
		return LANDING_MODE_MEDIUM
	end
	if horizontalSpeed >= MovementConfig.LandingLowHorizontalSpeed or impactSpeed > 0 then
		return LANDING_MODE_LOW
	end

	return LANDING_MODE_NONE
end

function MovementController:_clearLandingRecovery(modeOverride: string?)
	self._landingMode = modeOverride or LANDING_MODE_NONE
	self._landingRecoveryStartTime = NEVER
	self._landingRecoveryUntil = NEVER
	self._landingRecoveryAlpha = 0
	self._landingRunoutEligible = false
	if self._landingMode ~= LANDING_MODE_RUNOUT then
		self._landingInputGraceUntil = NEVER
	end
end

function MovementController:_beginLandingRecovery(now: number, landingMode: string)
	self._landingMode = landingMode
	self._landingRecoveryStartTime = now
	self._landingRecoveryUntil = now + MovementConfig.LandingRecoveryDuration
	self._landingRecoveryAlpha = 0
	self._landingInputGraceUntil = now + MovementConfig.LandingInputGraceTime
	self._landingRunoutEligible = landingMode == LANDING_MODE_HIGH
end

function MovementController:_getLandingRecoveryAlpha(now: number, isGrounded: boolean): number?
	if not isGrounded or self._landingRecoveryStartTime == NEVER or self._landingMode == LANDING_MODE_RUNOUT then
		self._landingRecoveryAlpha = 0
		return nil
	end

	local duration = math.max(MovementConfig.LandingRecoveryDuration, 0.001)
	local alpha = math.clamp((now - self._landingRecoveryStartTime) / duration, 0, 1)
	self._landingRecoveryAlpha = alpha
	if alpha >= 1 then
		self:_clearLandingRecovery()
		return nil
	end

	return alpha
end

function MovementController:_tryStartLandingRunout(now: number, inputMoveDirection: Vector3, isGrounded: boolean)
	if not (
		isGrounded
		and self._landingRunoutEligible
		and self._sprintHeld
		and now <= self._landingInputGraceUntil
		and inputMoveDirection.Magnitude >= MovementConfig.MinMoveMagnitude
		and not self:_isGroundSlide()
		and not self:_isAirCarry()
		and not self:_isGroundRunout()
	) then
		return
	end

	local landingVelocity = self._landingHorizontalVelocity
	if landingVelocity.Magnitude < MovementConfig.MinMoveMagnitude then
		return
	end

	local landingDirection = landingVelocity.Unit
	local inputDirection = inputMoveDirection.Unit
	local alignment = landingDirection:Dot(inputDirection)
	if alignment <= MovementConfig.GroundRunoutOppositeDotThreshold then
		self._landingRunoutEligible = false
		return
	end
	if alignment < MovementConfig.LandingRunoutSideDot then
		return
	end

	local inputDotThreshold = if alignment >= MovementConfig.LandingRunoutForwardDot
		then MovementConfig.GroundRunoutForwardDotThreshold
		else MovementConfig.LandingRunoutSideDot
	self:_startGroundRunout(now, landingDirection, self._landingHorizontalSpeed, inputDotThreshold)
	self:_clearLandingRecovery(LANDING_MODE_RUNOUT)
	self._landingInputGraceUntil = NEVER
	self._slideRequestPending = false
end

function MovementController:_updateLandingState(now: number, isGrounded: boolean)
	local rootPart = self._rootPart
	if not (rootPart and rootPart.Parent) then
		return
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local horizontalVelocity = flattenVelocity(velocity)
	local horizontalSpeed = horizontalVelocity.Magnitude
	if isGrounded then
		if not self._wasGrounded then
			self._landingImpactSpeed = self._maxAirDownwardSpeed
			self._landingHorizontalSpeed = math.max(self._maxAirHorizontalSpeed, horizontalSpeed)
			self._landingHorizontalVelocity = if self._maxAirHorizontalVelocity.Magnitude >= horizontalVelocity.Magnitude
				then self._maxAirHorizontalVelocity
				else horizontalVelocity
			self._landingSerial += 1

			local landingMode = self:_getLandingMode(self._landingHorizontalSpeed, self._landingImpactSpeed)
			if landingMode == LANDING_MODE_NONE then
				self:_clearLandingRecovery()
			else
				self:_beginLandingRecovery(now, landingMode)
			end
		end

		self._maxAirDownwardSpeed = 0
		self._maxAirHorizontalSpeed = 0
		self._maxAirHorizontalVelocity = Vector3.zero
	else
		self._maxAirDownwardSpeed = math.max(self._maxAirDownwardSpeed, math.max(-velocity.Y, 0))
		if horizontalSpeed >= self._maxAirHorizontalSpeed then
			self._maxAirHorizontalSpeed = horizontalSpeed
			self._maxAirHorizontalVelocity = horizontalVelocity
		end
		self:_clearLandingRecovery()
	end
end

function MovementController:_applyAirFacingYaw(isGrounded: boolean): boolean
	if isGrounded then
		return false
	end

	local rootPart = self._rootPart
	local humanoid = self._humanoid
	local facingDirection = self._smoothedFacingDirection
	if not (
		rootPart
		and rootPart.Parent
		and humanoid
		and humanoid.Health > 0
		and facingDirection.Magnitude >= MovementConfig.MinMoveMagnitude
	) then
		return false
	end

	local currentYaw = directionToYaw(rootPart.CFrame.LookVector)
	local targetYaw = directionToYaw(facingDirection)
	if not (currentYaw and targetYaw) then
		return false
	end

	local yawDelta = math.atan2(math.sin(targetYaw - currentYaw), math.cos(targetYaw - currentYaw))
	if math.abs(yawDelta) <= 1e-4 then
		return false
	end

	local linearVelocity = rootPart.AssemblyLinearVelocity
	local angularVelocity = rootPart.AssemblyAngularVelocity
	local position = rootPart.Position
	local rotation = rootPart.CFrame - position
	rootPart.CFrame = (CFrame.fromAxisAngle(Vector3.yAxis, yawDelta) * rotation) + position
	rootPart.AssemblyLinearVelocity = linearVelocity
	rootPart.AssemblyAngularVelocity = angularVelocity
	return true
end

function MovementController:_applyAirUprightStabilization(isGrounded: boolean): (number, Vector3, boolean)
	local rootPart = self._rootPart
	local humanoid = self._humanoid
	if not (rootPart and rootPart.Parent) then
		return 0, Vector3.zero, false
	end

	local tiltDegrees = getTiltDegrees(rootPart.CFrame)
	local angularVelocity = rootPart.AssemblyAngularVelocity
	if not MovementConfig.AirUprightStabilizationEnabled
		or isGrounded
		or not humanoid
		or humanoid.Health <= 0
	then
		return tiltDegrees, angularVelocity, false
	end

	local knockbackUntil = getBombKnockbackUntil(self._character)
	if not MovementConfig.AirUprightApplyWhileKnockback and knockbackUntil > workspace:GetServerTimeNow() then
		return tiltDegrees, angularVelocity, false
	end

	local horizontalFacing = flattenDirection(rootPart.CFrame.LookVector)
	if horizontalFacing.Magnitude < MovementConfig.MinMoveMagnitude then
		horizontalFacing = flattenDirection(self._smoothedFacingDirection)
	end
	if horizontalFacing.Magnitude < MovementConfig.MinMoveMagnitude then
		horizontalFacing = Vector3.new(0, 0, -1)
	end

	local maxTiltDegrees = math.max(tonumber(MovementConfig.AirUprightMaxTiltDegrees) or 0, 0)
	if tiltDegrees > maxTiltDegrees then
		rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + horizontalFacing, Vector3.yAxis)
	end

	local damping = math.clamp(tonumber(MovementConfig.AirUprightAngularVelocityDamping) or 0, 0, 1)
	local dampedAngularVelocity = angularVelocity * damping
	if dampedAngularVelocity ~= angularVelocity then
		rootPart.AssemblyAngularVelocity = dampedAngularVelocity
	end

	return getTiltDegrees(rootPart.CFrame), rootPart.AssemblyAngularVelocity, true
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
	character:SetAttribute("Movement_AirControlActive", data.airControlActive)
	character:SetAttribute("Movement_AirControlState", data.airControlState)
	character:SetAttribute("Movement_AirControlGravityScale", data.airControlGravityScale)
	character:SetAttribute("Movement_AirControlForce", data.airControlForce)
	character:SetAttribute("Movement_AirControlSteerForce", data.airControlSteerForce)
	character:SetAttribute("Movement_AirControlBrakeForce", data.airControlBrakeForce)
	character:SetAttribute("Movement_AirControlFallBrakeForce", data.airControlFallBrakeForce)
	character:SetAttribute("Movement_AirControlVerticalSpeed", data.airControlVerticalSpeed)
	character:SetAttribute("Movement_AirControlHorizontalSpeed", data.airControlHorizontalSpeed)
	character:SetAttribute("Movement_AirControlLaunchSource", data.airControlLaunchSource)
	character:SetAttribute("Movement_AirControlForceAirborneUntil", data.airControlForceAirborneUntil)
	character:SetAttribute("Movement_GravityBootsActive", data.gravityBootsActive)
	character:SetAttribute("Movement_GravityBootsAirSteeringScale", data.gravityBootsAirSteeringScale)
	character:SetAttribute("Movement_GravityBootsAirBrakeScale", data.gravityBootsAirBrakeScale)
	character:SetAttribute("Movement_GravityBootsAirGravityScaleMultiplier", data.gravityBootsAirGravityScaleMultiplier)
	character:SetAttribute("Movement_AirUprightStabilized", data.airUprightStabilized)
	character:SetAttribute("Movement_AirUprightTiltDegrees", data.airUprightTiltDegrees)
	character:SetAttribute("Movement_AirUprightAngularVelocity", data.airUprightAngularVelocity)
	character:SetAttribute("Movement_LandingImpactSpeed", data.landingImpactSpeed)
	character:SetAttribute("Movement_LandingHorizontalSpeed", data.landingHorizontalSpeed)
	character:SetAttribute("Movement_LandingSerial", data.landingSerial)
	character:SetAttribute("Movement_LandingBoostActive", data.landingBoostActive)
	character:SetAttribute("Movement_LandingMode", data.landingMode)
	character:SetAttribute("Movement_LandingRecoveryAlpha", data.landingRecoveryAlpha)
	character:SetAttribute("Movement_LandingInputGraceActive", data.landingInputGraceActive)
	character:SetAttribute("Movement_LandingRunoutEligible", data.landingRunoutEligible)
	self:_refreshCCLDebug()
	character:SetAttribute("Movement_CCLActiveController", self._cclActiveController)
	character:SetAttribute("Movement_CCLAirMoveMaxForce", self._cclAirMoveMaxForce)
	character:SetAttribute("Movement_CCLAirMoveSuppressed", self._cclAirMoveSuppressed)
end

function MovementController:_bindFallingDownStateWatcher(character: Model)
	if self._fallingDownStateConnection then
		self._fallingDownStateConnection:Disconnect()
		self._fallingDownStateConnection = nil
	end
	if self._fallingDownSyncedStateConnection then
		self._fallingDownSyncedStateConnection:Disconnect()
		self._fallingDownSyncedStateConnection = nil
	end
	self._fallingDownSyncedState = nil

	local function refresh()
		local _humanoidDisabled, _syncedValue, syncedState = disableFallingDownRuntimeState(character, self._humanoid)
		if syncedState ~= self._fallingDownSyncedState then
			if self._fallingDownSyncedStateConnection then
				self._fallingDownSyncedStateConnection:Disconnect()
				self._fallingDownSyncedStateConnection = nil
			end
			self._fallingDownSyncedState = syncedState
			if syncedState and syncedState:IsA("Configuration") then
				self._fallingDownSyncedStateConnection = syncedState:GetAttributeChangedSignal("Enabled"):Connect(function()
					if self._character == character and character.Parent and syncedState:GetAttribute("Enabled") ~= false then
						disableFallingDownRuntimeState(character, self._humanoid)
					end
				end)
			end
		end
	end

	refresh()
	self._fallingDownStateConnection = character.DescendantAdded:Connect(function(descendant)
		if
			descendant.Name == "AbilityManagerActor"
			or descendant.Name == "Abilities"
			or descendant.Name == "FallingDown"
			or descendant.Name == "SyncedState"
		then
			task.defer(function()
				if self._character == character and character.Parent then
					refresh()
				end
			end)
		end
	end)
end

function MovementController:_unbindCharacter()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	if self._fallingDownStateConnection then
		self._fallingDownStateConnection:Disconnect()
		self._fallingDownStateConnection = nil
	end
	if self._fallingDownSyncedStateConnection then
		self._fallingDownSyncedStateConnection:Disconnect()
		self._fallingDownSyncedStateConnection = nil
	end
	self._fallingDownSyncedState = nil
	self:_setCCLAirMoveSuppressed(false)
	self:_setGroundControllerTuning(false)
	self:_destroyAirControlForce()
	self._character = nil
	self._controllerManager = nil
	self._groundController = nil
	self._airController = nil
	self._airControllerBaseMoveMaxForce = nil
	self._cclAirMoveSuppressed = false
	self._cclAirMoveMaxForce = 0
	self._cclActiveController = ""
	self._groundSensor = nil
	self._humanoid = nil
	self._rootPart = nil
	self._smoothedMoveDirection = Vector3.zero
	self._smoothedFacingDirection = Vector3.zero
	self._smoothedFacingYaw = nil
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
	self._lastSlideRequestTime = NEVER
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
	self._groundRunoutInputDotThreshold = 0
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
	self._lastAirControlLaunchTime = NEVER
	self._groundedCandidateStartTime = NEVER
	self._observedAirControlLaunchSerial = 0
	self._lastObservedKnockbackUntil = NEVER
	self._gravityBootsActive = false
	self._gravityBootsAirSteeringScale = 1
	self._gravityBootsAirBrakeScale = 1
	self._gravityBootsAirGravityScaleMultiplier = 1
	self._airControlLaunchSource = AIR_LAUNCH_SOURCE_DEFAULT
	self._airControlLaunchSerial = 0
	self._airControlLaunchedAt = NEVER
	self._airControlForceAirborneUntil = NEVER
	self._maxAirDownwardSpeed = 0
	self._maxAirHorizontalSpeed = 0
	self._maxAirHorizontalVelocity = Vector3.zero
	self._landingImpactSpeed = 0
	self._landingHorizontalSpeed = 0
	self._landingHorizontalVelocity = Vector3.zero
	self._landingSerial = 0
	self._landingMode = LANDING_MODE_NONE
	self._landingRecoveryStartTime = NEVER
	self._landingRecoveryUntil = NEVER
	self._landingRecoveryAlpha = 0
	self._landingInputGraceUntil = NEVER
	self._landingRunoutEligible = false
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
	self:_consumeExternalAirControlLaunch(now)

	local knockbackUntil = getBombKnockbackUntil(self._character)
	if knockbackUntil > workspace:GetServerTimeNow() then
		self:_clearSlidePhase()
		if knockbackUntil ~= self._lastObservedKnockbackUntil then
			self._lastObservedKnockbackUntil = knockbackUntil
			self:_recordAirControlLaunch(now, AIR_LAUNCH_SOURCE_KNOCKBACK)
		end
	elseif self._lastObservedKnockbackUntil ~= NEVER then
		self._lastObservedKnockbackUntil = NEVER
	end

	local isGrounded = self:_resolveGrounded(now, self:_isCurrentlyGrounded())
	self._wasGrounded = self._isGrounded
	self._isGrounded = isGrounded
	self:_updateLandingState(now, isGrounded)

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
		if self:_isGroundRunout() then
			self:_stopGroundRunout()
		end
		if self:_canStartSlide(now, inputMoveDirection, isGrounded, sprintIntent) then
			self:_startGroundSlide(now, inputMoveDirection)
			self._slideRequestPending = false
		elseif now - self._lastSlideRequestTime > MovementConfig.LandingInputGraceTime then
			self._slideRequestPending = false
		end
	end

	self:_tryStartLandingRunout(now, inputMoveDirection, isGrounded)

	self:_updateGroundSlide(now, dt, inputMoveDirection, isGrounded)
	self:_updateAirCarry(now, dt, inputMoveDirection, isGrounded)
	self:_updateGroundRunout(now, dt, inputMoveDirection, isGrounded)

	local isSliding = self:_isGroundSlide() and isGrounded
	local isAirCarry = self:_isAirCarry()
	local isGroundRunout = self:_isGroundRunout()
	local landingRecoveryAlpha = self:_getLandingRecoveryAlpha(now, isGrounded)
	local landingRecoveryActive = landingRecoveryAlpha ~= nil
		and not isSliding
		and not isGroundRunout
		and not self._airControlActive
	if not landingRecoveryActive then
		landingRecoveryAlpha = nil
		if isSliding or isGroundRunout then
			self._landingRecoveryAlpha = 0
		end
	end
	self:_setGroundControllerTuning(isSliding, landingRecoveryAlpha)
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

	local cclMoveDirection = if isGrounded then self._smoothedMoveDirection else Vector3.zero
	controllerManager.MovingDirection = cclMoveDirection

	local shiftLocked = readCameraShiftLocked(self._character)
	local targetFacingDirection = if MovementConfig.FaceCameraDirection and shiftLocked
		then getCameraFacingDirection()
		else if hasMoveInput then targetMoveDirection.Unit else Vector3.zero

	local targetFacingYaw = directionToYaw(targetFacingDirection)
	if targetFacingYaw then
		local smoothedFacingYaw = self._smoothedFacingYaw
		if smoothedFacingYaw == nil then
			local currentFacingDirection = flattenDirection(controllerManager.FacingDirection)
			if currentFacingDirection.Magnitude < MovementConfig.MinMoveMagnitude and self._rootPart then
				currentFacingDirection = flattenDirection(self._rootPart.CFrame.LookVector)
			end
			smoothedFacingYaw = directionToYaw(currentFacingDirection) or targetFacingYaw
		end

		smoothedFacingYaw = smoothYaw(smoothedFacingYaw, targetFacingYaw, MovementConfig.FacingResponsiveness, dt)
		local smoothedFacingDirection = yawToDirection(smoothedFacingYaw)
		self._smoothedFacingYaw = smoothedFacingYaw
		self._smoothedFacingDirection = smoothedFacingDirection
		controllerManager.FacingDirection = smoothedFacingDirection
	end

	self:_applyAirFacingYaw(isGrounded)
	self:_updateAirControl(now, isGrounded, dt)
	local airUprightTiltDegrees, airUprightAngularVelocity, airUprightStabilized =
		self:_applyAirUprightStabilization(isGrounded)

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
		airControlActive = self._airControlActive,
		airControlState = self._airControlState,
		airControlGravityScale = self._airControlGravityScale,
		airControlForce = self._airControlForceVector,
		airControlSteerForce = self._airControlSteerForce,
		airControlBrakeForce = self._airControlBrakeForce,
		airControlFallBrakeForce = self._airControlFallBrakeForce,
		airControlVerticalSpeed = self._airControlVerticalSpeed,
		airControlHorizontalSpeed = self._airControlHorizontalSpeed,
		airControlLaunchSource = self._airControlLaunchSource,
		airControlForceAirborneUntil = self._airControlForceAirborneUntil,
		gravityBootsActive = self._gravityBootsActive,
		gravityBootsAirSteeringScale = self._gravityBootsAirSteeringScale,
		gravityBootsAirBrakeScale = self._gravityBootsAirBrakeScale,
		gravityBootsAirGravityScaleMultiplier = self._gravityBootsAirGravityScaleMultiplier,
		airUprightStabilized = airUprightStabilized,
		airUprightTiltDegrees = airUprightTiltDegrees,
		airUprightAngularVelocity = airUprightAngularVelocity,
		landingImpactSpeed = self._landingImpactSpeed,
		landingHorizontalSpeed = self._landingHorizontalSpeed,
		landingSerial = self._landingSerial,
		landingBoostActive = landingRecoveryActive,
		landingMode = self._landingMode,
		landingRecoveryAlpha = self._landingRecoveryAlpha,
		landingInputGraceActive = isGrounded and now <= self._landingInputGraceUntil,
		landingRunoutEligible = self._landingRunoutEligible,
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
			if slideIntent then
				self._lastSlideRequestTime = os.clock()
			end
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

function MovementController:_bindCharacterWithParts(character: Model, parts)
	self._character = character
	self._controllerManager = parts.controllerManager
	self._groundController = parts.groundController
	self._airController = parts.airController
	self._groundSensor = parts.groundSensor
	self._humanoid = parts.humanoid
	self._rootPart = parts.rootPart
	self:_captureAirControllerDefaults()
	self._isGrounded = self:_isCurrentlyGrounded()
	self._wasGrounded = self._isGrounded
	self._lastGroundedTime = if self._isGrounded then os.clock() else NEVER
	self._smoothedMoveDirection = parts.controllerManager.MovingDirection
	self._smoothedFacingDirection = flattenDirection(parts.controllerManager.FacingDirection)
	if self._smoothedFacingDirection.Magnitude < MovementConfig.MinMoveMagnitude and parts.rootPart then
		self._smoothedFacingDirection = flattenDirection(parts.rootPart.CFrame.LookVector)
	end
	self._smoothedFacingYaw = directionToYaw(self._smoothedFacingDirection)
	self._airJumpCount = 0
	self._jumpSerial = 0
	self:_bindFallingDownStateWatcher(character)

	character:SetAttribute("Movement_JumpSerial", self._jumpSerial)
	character:SetAttribute("Movement_LastJumpKind", "")
	character:SetAttribute("Movement_AirJumpCount", self._airJumpCount)
	character:SetAttribute("Movement_Crouching", false)
	character:SetAttribute("Movement_Sliding", false)
	character:SetAttribute("Movement_SlidePhase", SLIDE_PHASE_NONE)
	character:SetAttribute("Movement_SlideSpeed", 0)
	character:SetAttribute("Movement_SlideJumpBurstActive", false)
	character:SetAttribute("Movement_HorizontalSpeed", self:_getHorizontalSpeed())
	character:SetAttribute("Movement_AirControlActive", false)
	character:SetAttribute("Movement_AirControlState", "Grounded")
	character:SetAttribute("Movement_AirControlGravityScale", 1)
	character:SetAttribute("Movement_AirControlForce", Vector3.zero)
	character:SetAttribute("Movement_AirControlSteerForce", Vector3.zero)
	character:SetAttribute("Movement_AirControlBrakeForce", Vector3.zero)
	character:SetAttribute("Movement_AirControlFallBrakeForce", Vector3.zero)
	character:SetAttribute("Movement_AirControlVerticalSpeed", 0)
	character:SetAttribute("Movement_AirControlHorizontalSpeed", 0)
	character:SetAttribute("Movement_AirControlLaunchSource", AIR_LAUNCH_SOURCE_DEFAULT)
	character:SetAttribute("Movement_AirControlForceAirborneUntil", 0)
	character:SetAttribute("Movement_GravityBootsActive", false)
	character:SetAttribute("Movement_GravityBootsAirSteeringScale", 1)
	character:SetAttribute("Movement_GravityBootsAirBrakeScale", 1)
	character:SetAttribute("Movement_GravityBootsAirGravityScaleMultiplier", 1)
	character:SetAttribute("Movement_AirUprightStabilized", false)
	character:SetAttribute("Movement_AirUprightTiltDegrees", 0)
	character:SetAttribute("Movement_AirUprightAngularVelocity", Vector3.zero)
	character:SetAttribute("Movement_LandingImpactSpeed", 0)
	character:SetAttribute("Movement_LandingHorizontalSpeed", 0)
	character:SetAttribute("Movement_LandingSerial", self._landingSerial)
	character:SetAttribute("Movement_LandingBoostActive", false)
	character:SetAttribute("Movement_LandingMode", LANDING_MODE_NONE)
	character:SetAttribute("Movement_LandingRecoveryAlpha", 0)
	character:SetAttribute("Movement_LandingInputGraceActive", false)
	character:SetAttribute("Movement_LandingRunoutEligible", false)
	character:SetAttribute("Movement_CCLActiveController", self._cclActiveController)
	character:SetAttribute("Movement_CCLAirMoveMaxForce", self._cclAirMoveMaxForce)
	character:SetAttribute("Movement_CCLAirMoveSuppressed", false)
	character:SetAttribute(AIR_CONTROL_FORCE_AIRBORNE_UNTIL_ATTR, 0)
	character:SetAttribute(AIR_CONTROL_LAUNCH_SOURCE_ATTR, AIR_LAUNCH_SOURCE_DEFAULT)
	character:SetAttribute(AIR_CONTROL_LAUNCH_SERIAL_ATTR, self._airControlLaunchSerial)
	character:SetAttribute(AIR_CONTROL_LAUNCHED_AT_ATTR, 0)

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function(dt)
		self:_step(dt)
	end)
end

function MovementController:_bindCharacter(character: Model)
	self._bindSerial += 1
	local bindSerial = self._bindSerial
	self:_unbindCharacter()

	character:SetAttribute("Movement_CCLReady", false)
	character:SetAttribute("Movement_CCLMissing", false)
	character:SetAttribute("Movement_CCLStatus", "Waiting")

	task.spawn(function()
		local deadline = os.clock() + CONTROLLER_BIND_RETRY_TIMEOUT
		local parts = nil

		repeat
			if bindSerial ~= self._bindSerial or not character.Parent then
				return
			end

			parts = getMovementParts(character)
			if parts then
				break
			end

			task.wait(CONTROLLER_BIND_RETRY_INTERVAL)
		until os.clock() >= deadline

		if bindSerial ~= self._bindSerial or not character.Parent then
			return
		end

		if not parts then
			character:SetAttribute("Movement_CCLReady", false)
			character:SetAttribute("Movement_CCLMissing", true)
			character:SetAttribute("Movement_CCLStatus", "Missing")

			if not MovementController._warnedCharacters[character] then
				MovementController._warnedCharacters[character] = true
				warn("[MovementController] Missing engine-created CCL ControllerManager or GroundController for character:", character:GetFullName())
			end
			return
		end

		character:SetAttribute("Movement_CCLReady", true)
		character:SetAttribute("Movement_CCLMissing", false)
		character:SetAttribute("Movement_CCLStatus", "Ready")
		self:_bindCharacterWithParts(character, parts)
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
