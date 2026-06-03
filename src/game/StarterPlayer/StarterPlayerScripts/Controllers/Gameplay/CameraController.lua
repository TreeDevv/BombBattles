local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CameraShaker = require(ReplicatedStorage.Shared.Camera.CameraShaker)

local LocalPlayer = Players.LocalPlayer
local RENDER_STEP_NAME = "BombBattlesCameraController"
local SHIFT_LOCK_ACTION_NAME = "BombBattlesShiftLockToggle"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local HUD_FOV_BLUR_NAMES = {
	HUDWindowBlur = true,
	TemplateUIBlur = true,
}

type Controls = {
	GetMoveVector: (Controls) -> Vector3,
}

local CameraController = {}

CameraController._characterConnection = nil :: RBXScriptConnection?
CameraController._controls = nil :: Controls?
CameraController._character = nil :: Model?
CameraController._currentFOV = CameraConfig.BaseFOV
CameraController._currentRoll = 0
CameraController._currentShoulderOffset = Vector3.zero
CameraController._currentFallLagYOffset = 0
CameraController._cameraShaker = nil :: any
CameraController._wasGrounded = false
CameraController._hasObservedGroundedState = false
CameraController._airborneStartTime = nil :: number?
CameraController._maxDownwardSpeed = 0
CameraController._skipNextLandingShake = false
CameraController._mouseLocked = false
CameraController._previousMouseBehavior = nil :: Enum.MouseBehavior?
CameraController._previousMouseIconEnabled = nil :: boolean?
CameraController._shiftLocked = CameraConfig.DefaultShiftLocked == true
CameraController._headLockedCamera = nil :: Camera?
CameraController._headLockedSubject = nil :: BasePart?
CameraController._previousCameraSubject = nil :: Instance?

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

local function exponentialAlpha(responsiveness: number, dt: number): number
	return 1 - math.exp(-responsiveness * dt)
end

local function smoothNumber(current: number, target: number, responsiveness: number, dt: number): number
	return current + (target - current) * exponentialAlpha(responsiveness, dt)
end

local function smoothVector(current: Vector3, target: Vector3, responsiveness: number, dt: number): Vector3
	return current:Lerp(target, exponentialAlpha(responsiveness, dt))
end

local function readBoolAttribute(instance: Instance, name: string): boolean
	return instance:GetAttribute(name) == true
end

local function readOptionalBoolAttribute(instance: Instance, name: string): boolean?
	local value = instance:GetAttribute(name)
	return if typeof(value) == "boolean" then value else nil
end

local function readNumberAttribute(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

local function getRootPart(character: Model): BasePart?
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

local function getHumanoid(character: Model): Humanoid?
	return character:FindFirstChildOfClass("Humanoid")
end

local function getHeadLockedSubject(character: Model): BasePart?
	local subject = character:FindFirstChild(CameraConfig.HeadLockedSubjectPartName)
	return if subject and subject:IsA("BasePart") then subject else nil
end

local function isValidCameraSubject(subject: Instance?): boolean
	return subject ~= nil and subject.Parent ~= nil
end

local function isFirstPerson(camera: Camera): boolean
	local distance = (camera.CFrame.Position - camera.Focus.Position).Magnitude
	return distance <= CameraConfig.FirstPersonDistanceThreshold
end

local function isHudFOVActive(camera: Camera): boolean
	for _, child in Lighting:GetChildren() do
		if child:IsA("BlurEffect") and HUD_FOV_BLUR_NAMES[child.Name] and child.Size > 0.1 then
			return true
		end
	end

	local maxMovementFOV = CameraConfig.BaseFOV
		+ CameraConfig.SprintFOVBonus
		+ CameraConfig.AirFOVBonus
		+ CameraConfig.SlideJumpFOVBonus
	return camera.FieldOfView > maxMovementFOV + 0.5
end

function CameraController:_lockMouse()
	if not self._mouseLocked then
		self._previousMouseBehavior = UserInputService.MouseBehavior
		self._previousMouseIconEnabled = UserInputService.MouseIconEnabled
		self._mouseLocked = true
	end

	UserInputService.MouseBehavior = CameraConfig.MouseBehavior
	UserInputService.MouseIconEnabled = CameraConfig.LockMouseIconEnabled
end

function CameraController:_setShiftLocked(shiftLocked: boolean)
	if self._shiftLocked == shiftLocked then
		return
	end

	self._shiftLocked = shiftLocked
	if not shiftLocked then
		self:_restoreMouse()
	end

	local character = self._character
	if character then
		character:SetAttribute("Camera_ShiftLocked", shiftLocked)
	end
end

function CameraController:_restoreMouse()
	if not self._mouseLocked then
		return
	end

	if self._previousMouseBehavior then
		UserInputService.MouseBehavior = self._previousMouseBehavior
	end

	if self._previousMouseIconEnabled ~= nil then
		UserInputService.MouseIconEnabled = self._previousMouseIconEnabled
	end

	self._mouseLocked = false
	self._previousMouseBehavior = nil
	self._previousMouseIconEnabled = nil
end

function CameraController:_restoreCameraSubject(camera: Camera?, character: Model?)
	if not self._headLockedCamera and not self._headLockedSubject and not self._previousCameraSubject then
		return
	end

	local targetCamera = camera or self._headLockedCamera
	if targetCamera then
		local subject = if isValidCameraSubject(self._previousCameraSubject) then self._previousCameraSubject else nil
		if not subject and character then
			subject = getHumanoid(character)
		end

		if subject then
			targetCamera.CameraSubject = subject
		end
	end

	self._headLockedCamera = nil
	self._headLockedSubject = nil
	self._previousCameraSubject = nil
end

function CameraController:_updateHeadLockedCameraSubject(camera: Camera, character: Model)
	if not CameraConfig.HeadLockedCameraSubjectEnabled or not self._shiftLocked or camera.CameraType == Enum.CameraType.Scriptable then
		self:_restoreCameraSubject(camera, character)
		return
	end

	local humanoid = getHumanoid(character)
	local subject = getHeadLockedSubject(character)
	if not humanoid or humanoid.Health <= 0 or not subject then
		self:_restoreCameraSubject(camera, character)
		return
	end

	if self._headLockedCamera ~= camera or self._headLockedSubject ~= subject then
		self:_restoreCameraSubject(self._headLockedCamera, character)
		self._headLockedCamera = camera
		self._headLockedSubject = subject
		self._previousCameraSubject = if camera.CameraSubject ~= subject then camera.CameraSubject else nil
	end

	if camera.CameraSubject ~= subject then
		camera.CameraSubject = subject
	end
end

function CameraController:_publishCameraState(character: Model, firstPerson: boolean)
	character:SetAttribute("Camera_ShiftLocked", self._shiftLocked)
	character:SetAttribute("Camera_FirstPerson", firstPerson)
end

function CameraController:_resetCameraState(camera: Camera?)
	self._currentRoll = 0
	self._currentShoulderOffset = Vector3.zero
	self._currentFallLagYOffset = 0
	self._cameraShaker = nil
	self._wasGrounded = false
	self._hasObservedGroundedState = false
	self._airborneStartTime = nil
	self._maxDownwardSpeed = 0
	self._skipNextLandingShake = false

	if camera then
		self._currentFOV = camera.FieldOfView
	else
		self._currentFOV = CameraConfig.BaseFOV
	end
end

function CameraController:_getCameraShaker()
	if self._cameraShaker then
		return self._cameraShaker
	end

	self._cameraShaker = CameraShaker.new(RENDER_PRIORITY, function() end)
	return self._cameraShaker
end

function CameraController:_playLandingBump(airborneTime: number)
	local isHeavyLanding = airborneTime >= CameraConfig.LandingHeavyMinAirTime

	self:_getCameraShaker():ShakeOnce(
		if isHeavyLanding then CameraConfig.LandingHeavyShakeMagnitude else CameraConfig.LandingSmallShakeMagnitude,
		if isHeavyLanding then CameraConfig.LandingHeavyShakeRoughness else CameraConfig.LandingSmallShakeRoughness,
		0,
		if isHeavyLanding then CameraConfig.LandingHeavyShakeFadeOutTime else CameraConfig.LandingSmallShakeFadeOutTime,
		if isHeavyLanding
			then CameraConfig.LandingHeavyShakePositionInfluence
			else CameraConfig.LandingSmallShakePositionInfluence,
		if isHeavyLanding
			then CameraConfig.LandingHeavyShakeRotationInfluence
			else CameraConfig.LandingSmallShakeRotationInfluence
	)
end

function CameraController:_updateFallState(now: number, isGrounded: boolean, velocityY: number): number
	if not self._hasObservedGroundedState then
		self._hasObservedGroundedState = true
		self._wasGrounded = isGrounded
		if not isGrounded then
			self._airborneStartTime = now
			self._maxDownwardSpeed = math.min(0, velocityY)
			self._skipNextLandingShake = true
		end
		return 0
	end

	local airborneTime = 0
	if isGrounded then
		if not self._wasGrounded and self._airborneStartTime then
			airborneTime = now - self._airborneStartTime
			if self._skipNextLandingShake then
				self._skipNextLandingShake = false
			elseif airborneTime >= CameraConfig.LandingSmallMinAirTime then
				self:_playLandingBump(airborneTime)
			end
		end

		self._airborneStartTime = nil
		self._maxDownwardSpeed = 0
	else
		if self._wasGrounded or not self._airborneStartTime then
			self._airborneStartTime = now
			self._maxDownwardSpeed = 0
		end

		self._maxDownwardSpeed = math.min(self._maxDownwardSpeed, velocityY)
		airborneTime = now - self._airborneStartTime
	end

	self._wasGrounded = isGrounded
	return airborneTime
end

function CameraController:_updateFallLag(dt: number, isAirborne: boolean, airborneTime: number, velocityY: number)
	local targetYOffset = 0
	if
		isAirborne
		and velocityY <= CameraConfig.FallLagDownVelocityThreshold
		and airborneTime >= CameraConfig.FallLagDelay
	then
		local fallLagRange = math.max(CameraConfig.FallLagFullTime - CameraConfig.FallLagDelay, 0.001)
		local fallAlpha = math.clamp((airborneTime - CameraConfig.FallLagDelay) / fallLagRange, 0, 1)
		targetYOffset = CameraConfig.MaxFallLagYOffset * fallAlpha
	end

	local responsiveness = if targetYOffset == 0
		then CameraConfig.FallLagRecoveryResponsiveness
		else CameraConfig.FallLagResponsiveness
	self._currentFallLagYOffset = smoothNumber(self._currentFallLagYOffset, targetYOffset, responsiveness, dt)
end

function CameraController:_bindCharacter(character: Model)
	self:_restoreCameraSubject(workspace.CurrentCamera, self._character)
	self._character = character
	character:SetAttribute("Camera_ShiftLocked", self._shiftLocked)
	character:SetAttribute("Camera_FirstPerson", false)
	self:_resetCameraState(workspace.CurrentCamera)
end

function CameraController:_getCharacter(): Model?
	local character = LocalPlayer.Character
	if character ~= self._character then
		if character then
			self:_bindCharacter(character)
		else
			self._character = nil
		end
	end

	return self._character
end

function CameraController:_step(dt: number)
	local camera = workspace.CurrentCamera
	local character = self:_getCharacter()
	if not camera or not character then
		self:_resetCameraState(camera)
		self:_restoreMouse()
		self:_restoreCameraSubject(camera, character)
		return
	end

	local firstPerson = isFirstPerson(camera)
	self:_publishCameraState(character, firstPerson)

	if self._shiftLocked then
		self:_lockMouse()
	else
		self:_restoreMouse()
	end
	self:_updateHeadLockedCameraSubject(camera, character)

	local controls = self._controls or getControls()
	self._controls = controls

	local isGrounded = readBoolAttribute(character, "Movement_Grounded")
	local movementGrounded = readOptionalBoolAttribute(character, "Movement_Grounded")
	if movementGrounded == nil then
		isGrounded = true
	else
		isGrounded = movementGrounded
	end
	local isSprinting = readBoolAttribute(character, "Movement_Sprinting")
	local effectiveSpeed = readNumberAttribute(character, "Movement_EffectiveSpeed")
	local moveMagnitude = readNumberAttribute(character, "Movement_MoveMagnitude")
	local slidePhase = character:GetAttribute("Movement_SlidePhase")
	local slideSpeed = readNumberAttribute(character, "Movement_SlideSpeed")
	local horizontalSpeed = readNumberAttribute(character, "Movement_HorizontalSpeed")
	local slideJumpBurstActive = readBoolAttribute(character, "Movement_SlideJumpBurstActive")
	local isAirborne = not isGrounded
	local rootPart = getRootPart(character)
	local velocityY = if rootPart then rootPart.AssemblyLinearVelocity.Y else 0

	local airborneTime = self:_updateFallState(os.clock(), isGrounded, velocityY)
	self:_updateFallLag(dt, isAirborne, airborneTime, velocityY)

	local targetFOV = CameraConfig.BaseFOV
	if isSprinting then
		targetFOV += CameraConfig.SprintFOVBonus
	elseif isAirborne and moveMagnitude > 0.05 then
		targetFOV += CameraConfig.AirFOVBonus
	elseif effectiveSpeed > 0 then
		local speedAlpha = math.clamp((effectiveSpeed - 18) / 6, 0, 1)
		targetFOV += CameraConfig.SprintFOVBonus * speedAlpha
	end

	local slideMomentumActive = slideJumpBurstActive
		or slidePhase == "AirCarry"
		or slidePhase == "GroundRunout"
	if slideMomentumActive then
		local boostedSpeed = math.max(effectiveSpeed, slideSpeed, horizontalSpeed)
		local speedRange = math.max(CameraConfig.SlideJumpFOVSpeedForMax - 24, 1)
		local slideJumpAlpha = if slideJumpBurstActive
			then 1
			else math.clamp((boostedSpeed - 24) / speedRange, 0, 1)
		targetFOV += CameraConfig.SlideJumpFOVBonus * slideJumpAlpha
	end

	if CameraConfig.DisableWhenHudFOVActive and isHudFOVActive(camera) then
		self._currentFOV = camera.FieldOfView
	else
		self._currentFOV = smoothNumber(self._currentFOV, targetFOV, CameraConfig.FOVResponsiveness, dt)
		camera.FieldOfView = self._currentFOV
	end

	local targetShoulderOffset = if self._shiftLocked and not firstPerson
		then CameraConfig.ShoulderOffset
		else Vector3.zero
	self._currentShoulderOffset = smoothVector(
		self._currentShoulderOffset,
		targetShoulderOffset,
		CameraConfig.ShoulderResponsiveness,
		dt
	)

	local targetRoll = 0
	if self._shiftLocked and controls and moveMagnitude > 0.05 then
		local moveVector = controls:GetMoveVector()
		targetRoll = math.rad(-CameraConfig.MaxStrafeRollDegrees * math.clamp(moveVector.X, -1, 1))
	end
	self._currentRoll = smoothNumber(self._currentRoll, targetRoll, CameraConfig.RollResponsiveness, dt)

	local shakeCFrame = self:_getCameraShaker():Update(dt)

	camera.CFrame = camera.CFrame
		* CFrame.new(self._currentShoulderOffset)
		* CFrame.new(0, self._currentFallLagYOffset, 0)
		* CFrame.Angles(0, 0, self._currentRoll)
		* shakeCFrame
end

function CameraController:_handleShiftLockAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		self:_setShiftLocked(not self._shiftLocked)
	end

	return Enum.ContextActionResult.Sink
end

function CameraController:OnStart()
	self._controls = getControls()

	ContextActionService:UnbindAction(SHIFT_LOCK_ACTION_NAME)
	ContextActionService:BindAction(
		SHIFT_LOCK_ACTION_NAME,
		function(...)
			return self:_handleShiftLockAction(...)
		end,
		false,
		CameraConfig.ShiftLockToggleKey
	)

	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function(dt)
		self:_step(dt)
	end)

	if self._characterConnection then
		self._characterConnection:Disconnect()
	end

	self._characterConnection = LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)

	if LocalPlayer.Character then
		self:_bindCharacter(LocalPlayer.Character)
	end
end

return CameraController
