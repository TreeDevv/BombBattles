local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)
local CameraShaker = require(ReplicatedStorage.Shared.Camera.CameraShaker)
local InputBindings = require(ReplicatedStorage.Shared.Common.InputBindings)
local PlayerSettings = require(ReplicatedStorage.Shared.Common.PlayerSettings)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local LocalPlayer = Players.LocalPlayer
local RENDER_STEP_NAME = "BombBattlesCameraController"
local SHIFT_LOCK_ACTION_NAME = "BombBattlesShiftLockToggle"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2
local CAMERA_SPECTATING_ATTR = "Camera_Spectating"
local FRAME_FOV_ACTIVE_ATTR = "FrameControllerFOVActive"
local MOUSE_UNLOCK_FRAME_COUNT = 3
local HUD_FOV_BLUR_NAMES = {
	HUDWindowBlur = true,
	TemplateUIBlur = true,
}
local NEVER = -math.huge

type Controls = {
	GetMoveVector: (Controls) -> Vector3,
}

local CameraController = {}

CameraController._characterConnection = nil :: RBXScriptConnection?
CameraController._characterRemovingConnection = nil :: RBXScriptConnection?
CameraController._controls = nil :: Controls?
CameraController._character = nil :: Model?
CameraController._currentFOV = CameraConfig.BaseFOV
CameraController._currentRoll = 0
CameraController._currentShoulderOffset = Vector3.zero
CameraController._currentFallLagYOffset = 0
CameraController._currentAirMotionOffset = Vector3.zero
CameraController._currentAirRoll = 0
CameraController._currentFallAnticipationYOffset = 0
CameraController._currentHeadInfluenceOffset = Vector3.zero
CameraController._headInfluenceBaseLocalOffset = nil :: Vector3?
CameraController._cameraShaker = nil :: any
CameraController._wasGrounded = false
CameraController._hasObservedGroundedState = false
CameraController._airborneStartTime = nil :: number?
CameraController._maxDownwardSpeed = 0
CameraController._skipNextLandingShake = false
CameraController._lastLandingSerial = 0
CameraController._landingSettleStartTime = NEVER
CameraController._landingSettleIntensity = 0
CameraController._landingSettleDuration = CameraConfig.LandingSettleDuration
CameraController._currentLandingSettleYOffset = 0
CameraController._speedEffectFOVIntensity = 0
CameraController._throwFOVStartTime = NEVER
CameraController._takeoffLiftStartTime = NEVER
CameraController._takeoffLiftIntensity = 0
CameraController._airActionPunchStartTime = NEVER
CameraController._airActionPunchDuration = 0
CameraController._airActionPunchFOVBonus = 0
CameraController._airActionPunchOffset = Vector3.zero
CameraController._mouseLocked = false
CameraController._mouseUnlockFrames = 0
CameraController._shiftLocked = CameraConfig.DefaultShiftLocked == true
CameraController._headLockedCamera = nil :: Camera?
CameraController._headLockedSubject = nil :: BasePart?
CameraController._previousCameraSubject = nil :: Instance?
CameraController._settingsConnection = nil :: RBXScriptConnection?

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

local function smoothstep(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * (3 - (2 * alpha))
end

local function smoothVector(current: Vector3, target: Vector3, responsiveness: number, dt: number): Vector3
	return current:Lerp(target, exponentialAlpha(responsiveness, dt))
end

local function inverseLerpClamped(minValue: number, maxValue: number, value: number): number
	local range = maxValue - minValue
	if math.abs(range) <= 0.001 then
		return if value >= maxValue then 1 else 0
	end

	return math.clamp((value - minValue) / range, 0, 1)
end

local function flattenVelocity(velocity: Vector3): Vector3
	return Vector3.new(velocity.X, 0, velocity.Z)
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

local function getHeadInfluenceSubject(character: Model): BasePart?
	local partName = if typeof(CameraConfig.HeadInfluencePartName) == "string"
		then CameraConfig.HeadInfluencePartName
		else CameraConfig.HeadLockedSubjectPartName
	local subject = character:FindFirstChild(partName)
	return if subject and subject:IsA("BasePart") then subject else nil
end

local function isValidCameraSubject(subject: Instance?): boolean
	return subject ~= nil and subject.Parent ~= nil
end

local function isFirstPerson(camera: Camera): boolean
	local distance = (camera.CFrame.Position - camera.Focus.Position).Magnitude
	return distance <= CameraConfig.FirstPersonDistanceThreshold
end

local function getEffectiveShiftLocked(manualShiftLocked: boolean, firstPerson: boolean): boolean
	return manualShiftLocked or firstPerson
end

local function isFrameFOVActive(): boolean
	return LocalPlayer:GetAttribute(FRAME_FOV_ACTIVE_ATTR) == true
end

local function isHudFOVActive(camera: Camera, extraFOVAllowance: number?): boolean
	for _, child in Lighting:GetChildren() do
		if child:IsA("BlurEffect") and HUD_FOV_BLUR_NAMES[child.Name] and child.Size > 0.1 then
			return true
		end
	end

	local maxMovementFOV = CameraConfig.BaseFOV
		+ CameraConfig.SprintFOVBonus
		+ CameraConfig.AirFOVBonus
		+ CameraConfig.AirSpeedFOVBonus
		+ CameraConfig.AirControlFOVBonus
		+ CameraConfig.SlideJumpFOVBonus
		+ CameraConfig.AirCarryFOVBonus
		+ (extraFOVAllowance or 0)
	return camera.FieldOfView > maxMovementFOV + 0.5
end

local function getShakeScale(): number
	return 1
end

local function getMotionScale(): number
	return 1
end

local function getDynamicFOVScale(): number
	return 1
end

local function clampVectorComponents(value: Vector3, limit: Vector3): Vector3
	return Vector3.new(
		math.clamp(value.X, -math.abs(limit.X), math.abs(limit.X)),
		math.clamp(value.Y, -math.abs(limit.Y), math.abs(limit.Y)),
		math.clamp(value.Z, -math.abs(limit.Z), math.abs(limit.Z))
	)
end

function CameraController:_applyMouseLock(locked: boolean)
	if locked then
		self._mouseLocked = true
		self._mouseUnlockFrames = 0
		UserInputService.MouseBehavior = CameraConfig.MouseBehavior
		UserInputService.MouseIconEnabled = CameraConfig.LockMouseIconEnabled
	else
		self._mouseLocked = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

function CameraController:_stepMouseUnlock()
	if
		self._mouseUnlockFrames > 0
		or self._mouseLocked
		or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	then
		self:_applyMouseLock(false)
	end

	if self._mouseUnlockFrames > 0 then
		self._mouseUnlockFrames -= 1
	end
end

function CameraController:_forceMouseUnlock(frameCount: number?)
	self._mouseUnlockFrames = math.max(self._mouseUnlockFrames, frameCount or MOUSE_UNLOCK_FRAME_COUNT)
	self:_stepMouseUnlock()
end

function CameraController:_setShiftLocked(shiftLocked: boolean)
	if self._shiftLocked == shiftLocked then
		return
	end

	self._shiftLocked = shiftLocked

	local character = self._character
	if character then
		local camera = workspace.CurrentCamera
		local firstPerson = if camera then isFirstPerson(camera) else character:GetAttribute("Camera_FirstPerson") == true
		local effectiveShiftLocked = getEffectiveShiftLocked(shiftLocked, firstPerson)
		character:SetAttribute("Camera_ShiftLocked", effectiveShiftLocked)
		if not effectiveShiftLocked then
			self:_forceMouseUnlock()
		end
	elseif not shiftLocked then
		self:_forceMouseUnlock()
	end
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

function CameraController:_updateHeadLockedCameraSubject(camera: Camera, character: Model, effectiveShiftLocked: boolean)
	if
		not CameraConfig.HeadLockedCameraSubjectEnabled
		or not effectiveShiftLocked
		or camera.CameraType == Enum.CameraType.Scriptable
	then
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

function CameraController:_publishCameraState(character: Model, firstPerson: boolean, effectiveShiftLocked: boolean)
	character:SetAttribute("Camera_ShiftLocked", effectiveShiftLocked)
	character:SetAttribute("Camera_FirstPerson", firstPerson)
end

function CameraController:_getHeadInfluenceOffset(
	dt: number,
	camera: Camera,
	character: Model,
	rootPart: BasePart?,
	effectiveShiftLocked: boolean,
	firstPerson: boolean
): Vector3
	if not CameraConfig.HeadInfluenceEnabled or not effectiveShiftLocked or firstPerson or not rootPart then
		self._headInfluenceBaseLocalOffset = nil
		self._currentHeadInfluenceOffset = smoothVector(
			self._currentHeadInfluenceOffset,
			Vector3.zero,
			CameraConfig.HeadInfluenceResponsiveness,
			dt
		)
		return self._currentHeadInfluenceOffset
	end

	local subject = getHeadInfluenceSubject(character)
	if not subject then
		self._headInfluenceBaseLocalOffset = nil
		self._currentHeadInfluenceOffset = smoothVector(
			self._currentHeadInfluenceOffset,
			Vector3.zero,
			CameraConfig.HeadInfluenceResponsiveness,
			dt
		)
		return self._currentHeadInfluenceOffset
	end

	local localHeadOffset = rootPart.CFrame:VectorToObjectSpace(subject.Position - rootPart.Position)
	if not self._headInfluenceBaseLocalOffset then
		self._headInfluenceBaseLocalOffset = localHeadOffset
	end

	local maxLocalOffset = CameraConfig.HeadInfluenceMaxLocalOffset
	if typeof(maxLocalOffset) ~= "Vector3" then
		maxLocalOffset = Vector3.new(0.16, 0.12, 0.16)
	end

	local scale = math.clamp(tonumber(CameraConfig.HeadInfluenceScale) or 1, 0, 1)
	local localDelta = clampVectorComponents(localHeadOffset - self._headInfluenceBaseLocalOffset, maxLocalOffset) * scale
	local worldDelta = rootPart.CFrame:VectorToWorldSpace(localDelta)
	local targetOffset = camera.CFrame:VectorToObjectSpace(worldDelta)

	self._currentHeadInfluenceOffset = smoothVector(
		self._currentHeadInfluenceOffset,
		targetOffset,
		CameraConfig.HeadInfluenceResponsiveness,
		dt
	)
	return self._currentHeadInfluenceOffset
end

function CameraController:_resetCameraState(camera: Camera?)
	self._currentRoll = 0
	self._currentShoulderOffset = Vector3.zero
	self._currentFallLagYOffset = 0
	self._currentAirMotionOffset = Vector3.zero
	self._currentAirRoll = 0
	self._currentFallAnticipationYOffset = 0
	self._currentHeadInfluenceOffset = Vector3.zero
	self._headInfluenceBaseLocalOffset = nil
	self._cameraShaker = nil
	self._wasGrounded = false
	self._hasObservedGroundedState = false
	self._airborneStartTime = nil
	self._maxDownwardSpeed = 0
	self._skipNextLandingShake = false
	self._lastLandingSerial = 0
	self._landingSettleStartTime = NEVER
	self._landingSettleIntensity = 0
	self._landingSettleDuration = CameraConfig.LandingSettleDuration
	self._currentLandingSettleYOffset = 0
	self._speedEffectFOVIntensity = 0
	self._throwFOVStartTime = NEVER
	self._takeoffLiftStartTime = NEVER
	self._takeoffLiftIntensity = 0
	self._airActionPunchStartTime = NEVER
	self._airActionPunchDuration = 0
	self._airActionPunchFOVBonus = 0
	self._airActionPunchOffset = Vector3.zero

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
	local shakeScale = getShakeScale()
	if shakeScale <= 0 then
		return
	end

	self:_getCameraShaker():ShakeOnce(
		(if isHeavyLanding then CameraConfig.LandingHeavyShakeMagnitude else CameraConfig.LandingSmallShakeMagnitude)
			* shakeScale,
		if isHeavyLanding then CameraConfig.LandingHeavyShakeRoughness else CameraConfig.LandingSmallShakeRoughness,
		0,
		if isHeavyLanding then CameraConfig.LandingHeavyShakeFadeOutTime else CameraConfig.LandingSmallShakeFadeOutTime,
		if isHeavyLanding
			then CameraConfig.LandingHeavyShakePositionInfluence * shakeScale
			else CameraConfig.LandingSmallShakePositionInfluence * shakeScale,
		if isHeavyLanding
			then CameraConfig.LandingHeavyShakeRotationInfluence * shakeScale
			else CameraConfig.LandingSmallShakeRotationInfluence * shakeScale
	)
end

function CameraController:_getThrowFOVBonus(now: number): number
	local duration = math.max(CameraConfig.ThrowFOVDuration, 0.001)
	local elapsed = now - self._throwFOVStartTime
	if self._throwFOVStartTime == NEVER or elapsed >= duration then
		self._throwFOVStartTime = NEVER
		return 0
	end

	return CameraConfig.ThrowFOVBonus * (1 - smoothstep(elapsed / duration))
end

function CameraController:_startAirActionPunch(duration: number, fovBonus: number, offset: Vector3)
	self._airActionPunchStartTime = os.clock()
	self._airActionPunchDuration = math.max(duration, 0.001)
	self._airActionPunchFOVBonus = math.max(fovBonus, 0)
	self._airActionPunchOffset = offset
end

function CameraController:_getAirActionPunch(now: number): (Vector3, number)
	if self._airActionPunchStartTime == NEVER then
		return Vector3.zero, 0
	end

	local elapsed = now - self._airActionPunchStartTime
	if elapsed >= self._airActionPunchDuration then
		self._airActionPunchStartTime = NEVER
		self._airActionPunchFOVBonus = 0
		self._airActionPunchOffset = Vector3.zero
		return Vector3.zero, 0
	end

	local alpha = 1 - smoothstep(elapsed / self._airActionPunchDuration)
	return self._airActionPunchOffset * alpha, self._airActionPunchFOVBonus * alpha
end

function CameraController:PlayBombThrowPunch()
	local shakeScale = getShakeScale()
	self._throwFOVStartTime = os.clock()
	if shakeScale > 0 then
		self:_getCameraShaker():ShakeOnce(
			CameraConfig.ThrowShakeMagnitude * shakeScale,
			CameraConfig.ThrowShakeRoughness,
			0,
			CameraConfig.ThrowShakeFadeOutTime,
			CameraConfig.ThrowShakePositionInfluence * shakeScale,
			CameraConfig.ThrowShakeRotationInfluence * shakeScale
		)
	end
end

function CameraController:PlayAirBurstPunch()
	self:_startAirActionPunch(
		CameraConfig.AirBurstPunchDuration,
		CameraConfig.AirBurstPunchFOVBonus,
		CameraConfig.AirBurstPunchOffset
	)
	local shakeScale = getShakeScale()
	if shakeScale > 0 then
		self:_getCameraShaker():ShakeOnce(
			CameraConfig.AirBurstShakeMagnitude * shakeScale,
			CameraConfig.AirBurstShakeRoughness,
			0,
			CameraConfig.AirBurstShakeFadeOutTime,
			CameraConfig.AirBurstShakePositionInfluence * shakeScale,
			CameraConfig.AirBurstShakeRotationInfluence * shakeScale
		)
	end
end

function CameraController:PlayGrapplePullPunch()
	self:_startAirActionPunch(
		CameraConfig.GrapplePunchDuration,
		CameraConfig.GrapplePunchFOVBonus,
		CameraConfig.GrapplePunchOffset
	)
	local shakeScale = getShakeScale()
	if shakeScale > 0 then
		self:_getCameraShaker():ShakeOnce(
			CameraConfig.AirBurstShakeMagnitude * 0.85 * shakeScale,
			CameraConfig.AirBurstShakeRoughness,
			0,
			CameraConfig.AirBurstShakeFadeOutTime,
			Vector3.new(0.02, 0.04, 0.02) * shakeScale,
			Vector3.new(0.22, 0.08, 0.12) * shakeScale
		)
	end
end

function CameraController:PlayAbilityFOVPunch(duration: number, fovBonus: number)
	self:_startAirActionPunch(math.max(duration, 0.001), math.max(fovBonus, 0), Vector3.zero)
end

function CameraController:SetSpeedEffectFOVIntensity(intensity: number)
	self._speedEffectFOVIntensity = math.clamp(tonumber(intensity) or 0, 0, 1)
end

function CameraController:PlayExplosionShake(origin: Vector3, radius: number?)
	if typeof(origin) ~= "Vector3" then
		return
	end

	local maxRadius = math.max(tonumber(radius) or 0, 0)
	if maxRadius <= 0 then
		return
	end

	local character = self:_getCharacter()
	local rootPart = if character then getRootPart(character) else nil
	if not rootPart then
		return
	end

	local distance = (rootPart.Position - origin).Magnitude
	if distance > maxRadius then
		return
	end

	local strength = smoothstep(1 - math.clamp(distance / maxRadius, 0, 1))
	local shakeScale = getShakeScale()
	strength *= shakeScale
	if strength <= 0 then
		return
	end

	self:_getCameraShaker():ShakeOnce(
		CameraConfig.BombExplosionShakeMagnitude * strength,
		CameraConfig.BombExplosionShakeRoughness,
		0,
		CameraConfig.BombExplosionShakeFadeOutTime,
		CameraConfig.BombExplosionShakePositionInfluence * strength,
		CameraConfig.BombExplosionShakeRotationInfluence * strength
	)
end

function CameraController:PlayLocalBombExplosionShake()
	local shakeScale = getShakeScale()
	if shakeScale <= 0 then
		return
	end
	self:_getCameraShaker():ShakeOnce(
		CameraConfig.LocalBombExplosionShakeMagnitude * shakeScale,
		CameraConfig.LocalBombExplosionShakeRoughness,
		0,
		CameraConfig.LocalBombExplosionShakeFadeOutTime,
		CameraConfig.LocalBombExplosionShakePositionInfluence * shakeScale,
		CameraConfig.LocalBombExplosionShakeRotationInfluence * shakeScale
	)
end

function CameraController:PlayOrbitalStrikeShake(origin: Vector3, config: { [string]: any }?)
	if typeof(origin) ~= "Vector3" then
		return
	end

	local maxRadius = math.max(if config and typeof(config.cameraShakeRadius) == "number" then config.cameraShakeRadius else 260, 0)
	if maxRadius <= 0 then
		return
	end

	local character = self:_getCharacter()
	local rootPart = if character then getRootPart(character) else nil
	if not rootPart then
		return
	end

	local distance = (rootPart.Position - origin).Magnitude
	if distance > maxRadius then
		return
	end

	local strength = smoothstep(1 - math.clamp(distance / maxRadius, 0, 1))
	strength *= getShakeScale()
	if strength <= 0 then
		return
	end

	local magnitude = if config and typeof(config.cameraShakeMagnitude) == "number" then config.cameraShakeMagnitude else 6.5
	local roughness = if config and typeof(config.cameraShakeRoughness) == "number" then config.cameraShakeRoughness else 18
	local fadeInTime = if config and typeof(config.cameraShakeFadeInTime) == "number" then config.cameraShakeFadeInTime else 0.03
	local fadeOutTime = if config and typeof(config.cameraShakeFadeOutTime) == "number" then config.cameraShakeFadeOutTime else 0.85
	local positionInfluence = if config and typeof(config.cameraShakePositionInfluence) == "Vector3"
		then config.cameraShakePositionInfluence
		else Vector3.new(0.55, 0.45, 0.55)
	local rotationInfluence = if config and typeof(config.cameraShakeRotationInfluence) == "Vector3"
		then config.cameraShakeRotationInfluence
		else Vector3.new(3.2, 2.1, 2.6)

	self:_getCameraShaker():ShakeOnce(
		magnitude * strength,
		roughness,
		math.max(fadeInTime, 0),
		math.max(fadeOutTime, 0),
		positionInfluence * strength,
		rotationInfluence * strength
	)
end

function CameraController:_updateLandingSettleTrigger(character: Model, now: number)
	local landingSerial = readNumberAttribute(character, "Movement_LandingSerial")
	if landingSerial <= self._lastLandingSerial then
		return
	end

	self._lastLandingSerial = landingSerial
	local impactSpeed = readNumberAttribute(character, "Movement_LandingImpactSpeed")
	local horizontalSpeed = readNumberAttribute(character, "Movement_LandingHorizontalSpeed")
	local verticalRange = math.max(CameraConfig.LandingSettleSpeedForMax - CameraConfig.LandingSettleMinSpeed, 0.001)
	local horizontalRange = math.max(
		CameraConfig.LandingSettleHorizontalSpeedForMax - CameraConfig.LandingSettleHorizontalMinSpeed,
		0.001
	)
	local verticalAlpha = math.clamp((impactSpeed - CameraConfig.LandingSettleMinSpeed) / verticalRange, 0, 1)
	local horizontalAlpha = math.clamp(
		(horizontalSpeed - CameraConfig.LandingSettleHorizontalMinSpeed) / horizontalRange,
		0,
		1
	)
	local landingIntensity = math.clamp(
		(verticalAlpha * CameraConfig.LandingSettleVerticalWeight)
			+ (horizontalAlpha * CameraConfig.LandingSettleHorizontalWeight),
		0,
		1
	)
	if landingIntensity <= 0 then
		return
	end

	local landingMode = character:GetAttribute("Movement_LandingMode")
	self._landingSettleDuration = CameraConfig.LandingSettleDuration
	self._landingSettleIntensity = landingIntensity
	if landingMode == "Runout" then
		self._landingSettleDuration *= CameraConfig.LandingRunoutSettleDurationScale
		self._landingSettleIntensity *= CameraConfig.LandingRunoutSettleIntensityScale
	end
	self._landingSettleStartTime = now
end

function CameraController:_getLandingSettleAlpha(now: number): number
	if self._landingSettleStartTime == NEVER then
		return 0
	end

	local duration = math.max(self._landingSettleDuration, 0.001)
	local elapsed = now - self._landingSettleStartTime
	if elapsed >= duration then
		self._landingSettleStartTime = NEVER
		self._landingSettleIntensity = 0
		return 0
	end

	return (1 - smoothstep(elapsed / duration)) * self._landingSettleIntensity
end

function CameraController:_startTakeoffLift(velocityY: number)
	local liftAlpha = inverseLerpClamped(
		CameraConfig.AirTakeoffMinVelocity,
		CameraConfig.AirTakeoffMinVelocity * 3,
		velocityY
	)
	if liftAlpha <= 0 then
		return
	end

	self._takeoffLiftStartTime = os.clock()
	self._takeoffLiftIntensity = liftAlpha
end

function CameraController:_getTakeoffLift(now: number): number
	if self._takeoffLiftStartTime == NEVER then
		return 0
	end

	local duration = math.max(CameraConfig.AirTakeoffDuration, 0.001)
	local elapsed = now - self._takeoffLiftStartTime
	if elapsed >= duration then
		self._takeoffLiftStartTime = NEVER
		self._takeoffLiftIntensity = 0
		return 0
	end

	local alpha = (1 - smoothstep(elapsed / duration)) * self._takeoffLiftIntensity
	return CameraConfig.AirTakeoffLiftYOffset * alpha
end

function CameraController:_getFallAnticipationAlpha(character: Model, rootPart: BasePart?, isAirborne: boolean, velocityY: number): number
	if
		not isAirborne
		or not rootPart
		or velocityY > CameraConfig.FallAnticipationDownVelocity
		or CameraConfig.FallAnticipationRayDistance <= 0
	then
		return 0
	end

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { character }
	raycastParams.RespectCanCollide = true

	local result = workspace:Raycast(
		rootPart.Position,
		Vector3.yAxis * -CameraConfig.FallAnticipationRayDistance,
		raycastParams
	)
	if not result then
		return 0
	end

	local distanceAlpha = 1
		- inverseLerpClamped(
			CameraConfig.FallAnticipationMinDistance,
			CameraConfig.FallAnticipationRayDistance,
			result.Distance
		)
	local speedAlpha = inverseLerpClamped(
		math.abs(CameraConfig.FallAnticipationDownVelocity),
		math.abs(CameraConfig.FallAnticipationDownVelocity * 2),
		-velocityY
	)

	return smoothstep(math.min(distanceAlpha, speedAlpha))
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
			self:_startTakeoffLift(velocityY)
		end

		self._maxDownwardSpeed = math.min(self._maxDownwardSpeed, velocityY)
		airborneTime = now - self._airborneStartTime
	end

	self._wasGrounded = isGrounded
	return airborneTime
end

function CameraController:_updateFallLag(dt: number, isAirborne: boolean, airborneTime: number, velocityY: number)
	local targetYOffset = 0
	if isAirborne and velocityY <= CameraConfig.FallLagDownVelocityThreshold then
		local fastFallAlpha = inverseLerpClamped(
			CameraConfig.FallLagDownVelocityThreshold,
			CameraConfig.FallLagFastDownVelocity,
			velocityY
		)
		local delayScale = 1 - (fastFallAlpha * (1 - CameraConfig.FallLagFastDelayScale))
		local delay = CameraConfig.FallLagDelay * delayScale
		if airborneTime >= delay then
			local fallLagRange = math.max(CameraConfig.FallLagFullTime - delay, 0.001)
			local fallAlpha = math.clamp((airborneTime - delay) / fallLagRange, 0, 1)
			targetYOffset = (CameraConfig.MaxFallLagYOffset + (CameraConfig.FallLagVelocityBonusYOffset * fastFallAlpha))
				* fallAlpha
		end
	end

	local responsiveness = if targetYOffset == 0
		then CameraConfig.FallLagRecoveryResponsiveness
		else CameraConfig.FallLagResponsiveness
	self._currentFallLagYOffset = smoothNumber(self._currentFallLagYOffset, targetYOffset, responsiveness, dt)
end

function CameraController:_updateAirMotion(
	dt: number,
	camera: Camera,
	isAirborne: boolean,
	slideMomentumActive: boolean,
	linearVelocity: Vector3
)
	local targetOffset = Vector3.zero
	local targetRoll = 0

	if isAirborne then
		local localVelocity = camera.CFrame:VectorToObjectSpace(linearVelocity)
		local lateralAlpha = math.clamp(
			localVelocity.X / math.max(CameraConfig.AirVelocityLeanSpeedForMax, 1),
			-1,
			1
		)
		local forwardAlpha = math.clamp(
			-localVelocity.Z / math.max(CameraConfig.AirDriftSpeedForMax, 1),
			0,
			1
		)
		local riseAlpha = math.clamp(
			linearVelocity.Y / math.max(CameraConfig.AirVerticalRiseSpeedForMax, 1),
			0,
			1
		)
		local fallAlpha = math.clamp(
			-linearVelocity.Y / math.max(CameraConfig.AirVerticalFallSpeedForMax, 1),
			0,
			1
		)

		targetRoll = math.rad(-CameraConfig.MaxAirVelocityRollDegrees * lateralAlpha)
		targetOffset = Vector3.new(
			-CameraConfig.AirDriftMaxOffset.X * lateralAlpha,
			(CameraConfig.AirDriftMaxOffset.Y * riseAlpha * 0.55) - (CameraConfig.AirDriftMaxOffset.Y * fallAlpha),
			CameraConfig.AirDriftMaxOffset.Z * forwardAlpha
		)

		if slideMomentumActive then
			targetOffset += CameraConfig.AirCarryOffset
		end
	end

	self._currentAirMotionOffset = smoothVector(
		self._currentAirMotionOffset,
		targetOffset,
		CameraConfig.AirDriftResponsiveness,
		dt
	)
	self._currentAirRoll = smoothNumber(self._currentAirRoll, targetRoll, CameraConfig.AirLeanResponsiveness, dt)
end

function CameraController:_bindCharacter(character: Model)
	self:_restoreCameraSubject(workspace.CurrentCamera, self._character)
	self._character = character
	character:SetAttribute("Camera_ShiftLocked", self._shiftLocked)
	character:SetAttribute("Camera_FirstPerson", false)
	if not self._shiftLocked then
		self:_forceMouseUnlock()
	end
	self:_resetCameraState(workspace.CurrentCamera)
end

function CameraController:_getCharacter(): Model?
	local character = LocalPlayer.Character
	if character ~= self._character then
		if character then
			self:_bindCharacter(character)
		else
			self._character = nil
			self:_forceMouseUnlock()
		end
	end

	return self._character
end

function CameraController:_step(dt: number)
	local camera = workspace.CurrentCamera
	if LocalPlayer:GetAttribute(CAMERA_SPECTATING_ATTR) == true then
		if camera then
			self._currentFOV = camera.FieldOfView
		end
		self:_forceMouseUnlock()
		self._headLockedCamera = nil
		self._headLockedSubject = nil
		self._previousCameraSubject = nil
		return
	end

	local character = self:_getCharacter()
	if not camera or not character then
		self:_resetCameraState(camera)
		self:_forceMouseUnlock()
		self:_restoreCameraSubject(camera, character)
		return
	end

	local firstPerson = isFirstPerson(camera)
	local effectiveShiftLocked = getEffectiveShiftLocked(self._shiftLocked, firstPerson)
	self:_publishCameraState(character, firstPerson, effectiveShiftLocked)

	if effectiveShiftLocked then
		self:_applyMouseLock(true)
	else
		self:_stepMouseUnlock()
	end
	self:_updateHeadLockedCameraSubject(camera, character, effectiveShiftLocked)

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
	local linearVelocity = if rootPart then rootPart.AssemblyLinearVelocity else Vector3.zero
	local velocityY = linearVelocity.Y
	local slideMomentumActive = slideJumpBurstActive
		or slidePhase == "AirCarry"
		or slidePhase == "GroundRunout"
	local airFramingActive = isAirborne and (slideJumpBurstActive or slidePhase == "AirCarry")

	local now = os.clock()
	self:_updateLandingSettleTrigger(character, now)
	local landingSettleAlpha = self:_getLandingSettleAlpha(now)
	local airborneTime = self:_updateFallState(now, isGrounded, velocityY)
	self:_updateFallLag(dt, isAirborne, airborneTime, velocityY)
	local throwFOVBonus = self:_getThrowFOVBonus(now)
	local airActionOffset, airActionFOVBonus = self:_getAirActionPunch(now)
	local takeoffLiftYOffset = self:_getTakeoffLift(now)
	local fallAnticipationAlpha = self:_getFallAnticipationAlpha(character, rootPart, isAirborne, velocityY)
	if firstPerson then
		fallAnticipationAlpha = 0
	end
	self._currentFallAnticipationYOffset = smoothNumber(
		self._currentFallAnticipationYOffset,
		CameraConfig.FallAnticipationMaxYOffset * fallAnticipationAlpha,
		CameraConfig.FallLagResponsiveness,
		dt
	)
	self:_updateAirMotion(dt, camera, isAirborne, airFramingActive, linearVelocity)

	local targetFOV = CameraConfig.BaseFOV
	if isSprinting then
		targetFOV += CameraConfig.SprintFOVBonus
	elseif effectiveSpeed > 0 and not isAirborne then
		local speedAlpha = math.clamp((effectiveSpeed - 18) / 6, 0, 1)
		targetFOV += CameraConfig.SprintFOVBonus * speedAlpha
	end

	if isAirborne then
		if moveMagnitude > 0.05 then
			targetFOV += CameraConfig.AirFOVBonus
		end

		local horizontalSpeedForCamera = math.max(horizontalSpeed, flattenVelocity(linearVelocity).Magnitude)
		local airSpeedAlpha = inverseLerpClamped(
			CameraConfig.AirSpeedFOVMinSpeed,
			CameraConfig.AirSpeedFOVMaxSpeed,
			horizontalSpeedForCamera
		)
		targetFOV += CameraConfig.AirSpeedFOVBonus * airSpeedAlpha

		local airControlAlpha = inverseLerpClamped(
			CameraConfig.AirControlFOVMinMoveMagnitude,
			1,
			moveMagnitude
		)
		targetFOV += CameraConfig.AirControlFOVBonus * airControlAlpha
	end

	if slideMomentumActive then
		local boostedSpeed = math.max(effectiveSpeed, slideSpeed, horizontalSpeed)
		local speedRange = math.max(CameraConfig.SlideJumpFOVSpeedForMax - 24, 1)
		local slideJumpAlpha = if slideJumpBurstActive
			then 1
			else math.clamp((boostedSpeed - 24) / speedRange, 0, 1)
		targetFOV += CameraConfig.SlideJumpFOVBonus * slideJumpAlpha
		if airFramingActive then
			targetFOV += CameraConfig.AirCarryFOVBonus * slideJumpAlpha
		end
	end
	targetFOV += CameraConfig.SpeedEffectFOVBonus * self._speedEffectFOVIntensity
	targetFOV -= CameraConfig.FallAnticipationMaxFOVDip * fallAnticipationAlpha
	targetFOV -= CameraConfig.LandingSettleMaxFOVDip * landingSettleAlpha
	targetFOV += throwFOVBonus
	targetFOV += airActionFOVBonus
	targetFOV = CameraConfig.BaseFOV + ((targetFOV - CameraConfig.BaseFOV) * getDynamicFOVScale())

	if
		isFrameFOVActive()
		or (CameraConfig.DisableWhenHudFOVActive and isHudFOVActive(camera, throwFOVBonus + airActionFOVBonus))
	then
		self._currentFOV = camera.FieldOfView
	else
		local fovResponsiveness = if airActionFOVBonus > 0
			then math.max(CameraConfig.FOVResponsiveness, CameraConfig.AirActionFOVResponsiveness)
			else CameraConfig.FOVResponsiveness
		self._currentFOV = smoothNumber(self._currentFOV, targetFOV, fovResponsiveness, dt)
		camera.FieldOfView = self._currentFOV
	end

	local targetShoulderOffset = if effectiveShiftLocked and not firstPerson
		then CameraConfig.ShoulderOffset
		else Vector3.zero
	self._currentShoulderOffset = smoothVector(
		self._currentShoulderOffset,
		targetShoulderOffset,
		CameraConfig.ShoulderResponsiveness,
		dt
	)

	local targetRoll = 0
	if effectiveShiftLocked and controls and moveMagnitude > 0.05 then
		local moveVector = controls:GetMoveVector()
		targetRoll = math.rad(-CameraConfig.MaxStrafeRollDegrees * math.clamp(moveVector.X, -1, 1))
	end
	self._currentRoll = smoothNumber(self._currentRoll, targetRoll, CameraConfig.RollResponsiveness, dt)
	self._currentLandingSettleYOffset = CameraConfig.LandingSettleMaxYOffset * landingSettleAlpha

	local motionScale = getMotionScale()
	local cameraMotionOffset = (self._currentAirMotionOffset + airActionOffset + Vector3.new(0, takeoffLiftYOffset, 0))
		* motionScale
	local headInfluenceOffset =
		self:_getHeadInfluenceOffset(dt, camera, character, rootPart, effectiveShiftLocked, firstPerson) * motionScale
	local cameraRoll = (self._currentRoll + self._currentAirRoll) * motionScale
	local fallLagYOffset = self._currentFallLagYOffset * motionScale
	local fallAnticipationYOffset = self._currentFallAnticipationYOffset * motionScale
	local landingSettleYOffset = self._currentLandingSettleYOffset * motionScale
	if firstPerson then
		cameraMotionOffset = Vector3.zero
		headInfluenceOffset = Vector3.zero
		cameraRoll = self._currentRoll * motionScale
	end

	local shakeCFrame = self:_getCameraShaker():Update(dt)

	camera.CFrame = camera.CFrame
		* CFrame.new(self._currentShoulderOffset)
		* CFrame.new(headInfluenceOffset)
		* CFrame.new(cameraMotionOffset)
		* CFrame.new(0, fallLagYOffset, 0)
		* CFrame.new(0, fallAnticipationYOffset, 0)
		* CFrame.new(0, landingSettleYOffset, 0)
		* CFrame.Angles(0, 0, cameraRoll)
		* shakeCFrame
end

function CameraController:_bindShiftLockAction()
	ContextActionService:UnbindAction(SHIFT_LOCK_ACTION_NAME)
	ContextActionService:BindAction(
		SHIFT_LOCK_ACTION_NAME,
		function(...)
			return self:_handleShiftLockAction(...)
		end,
		false,
		table.unpack(InputBindings.GetShiftLockInputs())
	)
end

function CameraController:_handleShiftLockAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		self:_setShiftLocked(not self._shiftLocked)
	end

	return Enum.ContextActionResult.Sink
end

function CameraController:OnStart()
	self._controls = getControls()

	self:_bindShiftLockAction()
	if self._settingsConnection then
		self._settingsConnection:Disconnect()
	end
	self._settingsConnection = PlayerSettings.Changed:Connect(function(id)
		if id == "shiftLockKey" then
			self:_bindShiftLockAction()
		end
	end)

	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function(dt)
		local token = RuntimeProfiler.Begin("Client/CameraController/Render")
		self:_step(dt)
		RuntimeProfiler.End("Client/CameraController/Render", token)
	end)

	if self._characterConnection then
		self._characterConnection:Disconnect()
	end
	if self._characterRemovingConnection then
		self._characterRemovingConnection:Disconnect()
	end

	self._characterConnection = LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)
	self._characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(function()
		self._character = nil
		self:_forceMouseUnlock()
	end)

	if LocalPlayer.Character then
		self:_bindCharacter(LocalPlayer.Character)
	end
end

return CameraController
