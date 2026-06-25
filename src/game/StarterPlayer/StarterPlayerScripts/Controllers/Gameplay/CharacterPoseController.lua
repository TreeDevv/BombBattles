local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CharacterPoseConfig = require(ReplicatedStorage.Shared.Config.CharacterPoseConfig)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local LocalPlayer = Players.LocalPlayer
local RENDER_STEP_NAME = "BombBattlesCharacterPoseController"
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value + 2
local CHARACTER_LOOKUP_TIMEOUT = 5

type PoseMotorName = "rootJoint" | "neck" | "rightShoulder" | "leftShoulder" | "rightHip" | "leftHip"

type PoseMotorSet = {
	rootJoint: Motor6D,
	neck: Motor6D,
	rightShoulder: Motor6D,
	leftShoulder: Motor6D,
	rightHip: Motor6D,
	leftHip: Motor6D,
}

local CharacterPoseController = {}

CharacterPoseController._character = nil :: Model?
CharacterPoseController._characterConnection = nil :: RBXScriptConnection?
CharacterPoseController._rootPart = nil :: BasePart?
CharacterPoseController._humanoid = nil :: Humanoid?
CharacterPoseController._motors = nil :: PoseMotorSet?
CharacterPoseController._originalC0 = {} :: { [PoseMotorName]: CFrame }
CharacterPoseController._tilts = {} :: { [PoseMotorName]: CFrame }
CharacterPoseController._timeSincePoseUpdate = 0

local function getMotor(parent: Instance?, name: string): Motor6D?
	if not parent then
		return nil
	end

	local child = parent:FindFirstChild(name)
	if child and child:IsA("Motor6D") then
		return child
	end

	return nil
end

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

local function zeroTilts(): { [PoseMotorName]: CFrame }
	return {
		rootJoint = CFrame.new(),
		neck = CFrame.new(),
		rightShoulder = CFrame.new(),
		leftShoulder = CFrame.new(),
		rightHip = CFrame.new(),
		leftHip = CFrame.new(),
	}
end

local function getPoseMotors(rootPart: BasePart, torso: BasePart): PoseMotorSet?
	local rootJoint = getMotor(rootPart, "RootJoint")
	local neck = getMotor(torso, "Neck")
	local rightShoulder = getMotor(torso, "Right Shoulder")
	local leftShoulder = getMotor(torso, "Left Shoulder")
	local rightHip = getMotor(torso, "Right Hip")
	local leftHip = getMotor(torso, "Left Hip")

	if not (rootJoint and neck and rightShoulder and leftShoulder and rightHip and leftHip) then
		return nil
	end

	return {
		rootJoint = rootJoint,
		neck = neck,
		rightShoulder = rightShoulder,
		leftShoulder = leftShoulder,
		rightHip = rightHip,
		leftHip = leftHip,
	}
end

local function applyTilt(
	motors: PoseMotorSet,
	originalC0: { [PoseMotorName]: CFrame },
	tilts: { [PoseMotorName]: CFrame },
	motorName: PoseMotorName,
	target: CFrame
)
	local motor = motors[motorName]
	local original = originalC0[motorName]
	if not (motor and original) then
		return
	end

	tilts[motorName] = tilts[motorName]:Lerp(target, CharacterPoseConfig.DirectionalLerpAlpha)
	motor.C0 = original * tilts[motorName]
end

local function setCommonLimbYaw(
	motors: PoseMotorSet,
	originalC0: { [PoseMotorName]: CFrame },
	tilts: { [PoseMotorName]: CFrame },
	yawRadians: number
)
	local target = CFrame.Angles(0, yawRadians, 0)
	applyTilt(motors, originalC0, tilts, "rightShoulder", target)
	applyTilt(motors, originalC0, tilts, "leftShoulder", target)
	applyTilt(motors, originalC0, tilts, "rightHip", target)
	applyTilt(motors, originalC0, tilts, "leftHip", target)
end

local function resetPose(
	motors: PoseMotorSet,
	originalC0: { [PoseMotorName]: CFrame },
	tilts: { [PoseMotorName]: CFrame }
)
	applyTilt(motors, originalC0, tilts, "rootJoint", CFrame.new())
	applyTilt(motors, originalC0, tilts, "neck", CFrame.new())
	setCommonLimbYaw(motors, originalC0, tilts, 0)
end

function CharacterPoseController:_restoreC0()
	local motors = self._motors
	if not motors then
		return
	end

	for name, original in pairs(self._originalC0) do
		local motor = motors[name]
		if motor then
			motor.C0 = original
		end
	end
end

function CharacterPoseController:_getWorldMoveDirection(): Vector3
	local humanoid = self._humanoid
	if humanoid and humanoid.MoveDirection.Magnitude >= CharacterPoseConfig.MinMoveMagnitude then
		return humanoid.MoveDirection
	end

	local character = self._character
	local rootPart = self._rootPart
	if character and rootPart and rootPart.Parent and character:GetAttribute("Movement_Grounded") == true then
		local horizontalVelocity = Vector3.new(rootPart.AssemblyLinearVelocity.X, 0, rootPart.AssemblyLinearVelocity.Z)
		if horizontalVelocity.Magnitude >= CharacterPoseConfig.MinMoveMagnitude then
			return horizontalVelocity.Unit
		end
	end

	return Vector3.zero
end

function CharacterPoseController:_step(dt: number)
	self._timeSincePoseUpdate += dt
	if self._timeSincePoseUpdate < CharacterPoseConfig.DirectionalTickRate then
		return
	end
	self._timeSincePoseUpdate = 0

	local rootPart = self._rootPart
	local motors = self._motors
	if not (rootPart and rootPart.Parent and motors and CharacterPoseConfig.Enabled) then
		if motors then
			resetPose(motors, self._originalC0, self._tilts)
		end
		return
	end

	local objectMoveDirection = rootPart.CFrame:VectorToObjectSpace(self:_getWorldMoveDirection())
	local moveDirection = Vector3.new(-objectMoveDirection.X, objectMoveDirection.Y, objectMoveDirection.Z)
	if moveDirection.Magnitude < CharacterPoseConfig.MinMoveMagnitude then
		resetPose(motors, self._originalC0, self._tilts)
		return
	end

	local dotThreshold = CharacterPoseConfig.DirectionalDotThreshold
	local rootTarget = CFrame.new()
	local neckTarget = CFrame.new()
	local limbYaw = 0

	if moveDirection:Dot(Vector3.new(1, 0, -1).Unit) > dotThreshold then
		rootTarget = CFrame.Angles(
			math.rad(-moveDirection.Z) * CharacterPoseConfig.RootDiagonalPitchDegrees,
			0,
			math.rad(-moveDirection.X) * CharacterPoseConfig.RootDiagonalRollDegrees
		)
		neckTarget = CFrame.Angles(
			math.rad(moveDirection.Z) * CharacterPoseConfig.DiagonalForwardNeckPitchDegrees,
			0,
			math.rad(moveDirection.X) * CharacterPoseConfig.DiagonalForwardNeckRollDegrees
		)
		limbYaw = math.rad(-moveDirection.X) * CharacterPoseConfig.DiagonalLimbYawDegrees
	elseif moveDirection:Dot(Vector3.new(1, 0, 1).Unit) > dotThreshold then
		rootTarget = CFrame.Angles(
			math.rad(-moveDirection.Z) * CharacterPoseConfig.RootDiagonalPitchDegrees,
			0,
			math.rad(moveDirection.X) * CharacterPoseConfig.RootDiagonalRollDegrees
		)
		neckTarget = CFrame.Angles(
			math.rad(moveDirection.Z) * CharacterPoseConfig.DiagonalBackwardNeckPitchDegrees,
			0,
			math.rad(-moveDirection.X) * CharacterPoseConfig.DiagonalBackwardNeckRollDegrees
		)
		limbYaw = math.rad(moveDirection.X) * CharacterPoseConfig.DiagonalLimbYawDegrees
	elseif moveDirection:Dot(Vector3.new(-1, 0, 1).Unit) > dotThreshold then
		rootTarget = CFrame.Angles(
			math.rad(-moveDirection.Z) * CharacterPoseConfig.RootDiagonalPitchDegrees,
			0,
			math.rad(moveDirection.X) * CharacterPoseConfig.RootDiagonalRollDegrees
		)
		neckTarget = CFrame.Angles(
			math.rad(moveDirection.Z) * CharacterPoseConfig.DiagonalBackwardNeckPitchDegrees,
			0,
			math.rad(-moveDirection.X) * CharacterPoseConfig.DiagonalBackwardNeckRollDegrees
		)
		limbYaw = math.rad(moveDirection.X) * CharacterPoseConfig.DiagonalLimbYawDegrees
	elseif moveDirection:Dot(Vector3.new(-1, 0, -1).Unit) > dotThreshold then
		rootTarget = CFrame.Angles(
			math.rad(-moveDirection.Z) * CharacterPoseConfig.RootDiagonalPitchDegrees,
			0,
			math.rad(-moveDirection.X) * CharacterPoseConfig.RootDiagonalRollDegrees
		)
		neckTarget = CFrame.Angles(
			math.rad(moveDirection.Z) * CharacterPoseConfig.DiagonalForwardNeckPitchDegrees,
			0,
			math.rad(moveDirection.X) * CharacterPoseConfig.DiagonalForwardNeckRollDegrees
		)
		limbYaw = math.rad(-moveDirection.X) * CharacterPoseConfig.DiagonalLimbYawDegrees
	elseif moveDirection:Dot(Vector3.new(0, 0, -1).Unit) > dotThreshold then
		rootTarget = CFrame.Angles(math.rad(-moveDirection.Z) * CharacterPoseConfig.RootForwardBackPitchDegrees, 0, 0)
		neckTarget = CFrame.Angles(math.rad(moveDirection.Z) * CharacterPoseConfig.ForwardBackNeckPitchDegrees, 0, 0)
	elseif moveDirection:Dot(Vector3.new(1, 0, 0).Unit) > dotThreshold then
		rootTarget = CFrame.Angles(0, 0, math.rad(-moveDirection.X) * CharacterPoseConfig.RootSideRollDegrees)
		neckTarget = CFrame.Angles(0, 0, math.rad(moveDirection.X) * CharacterPoseConfig.SideNeckRollDegrees)
		limbYaw = math.rad(-moveDirection.X) * CharacterPoseConfig.SideLimbYawDegrees
	elseif moveDirection:Dot(Vector3.new(0, 0, 1).Unit) > dotThreshold then
		rootTarget = CFrame.Angles(math.rad(-moveDirection.Z) * CharacterPoseConfig.RootForwardBackPitchDegrees, 0, 0)
		neckTarget = CFrame.Angles(math.rad(moveDirection.Z) * CharacterPoseConfig.ForwardBackNeckPitchDegrees, 0, 0)
	elseif moveDirection:Dot(Vector3.new(-1, 0, 0).Unit) > dotThreshold then
		rootTarget = CFrame.Angles(0, 0, math.rad(-moveDirection.X) * CharacterPoseConfig.RootSideRollDegrees)
		neckTarget = CFrame.Angles(0, 0, math.rad(moveDirection.X) * CharacterPoseConfig.SideNeckRollDegrees)
		limbYaw = math.rad(-moveDirection.X) * CharacterPoseConfig.SideLimbYawDegrees
	else
		resetPose(motors, self._originalC0, self._tilts)
		return
	end

	if CharacterPoseConfig.EnableRootJointLean then
		applyTilt(motors, self._originalC0, self._tilts, "rootJoint", rootTarget)
	else
		applyTilt(motors, self._originalC0, self._tilts, "rootJoint", CFrame.new())
	end
	applyTilt(motors, self._originalC0, self._tilts, "neck", neckTarget)
	setCommonLimbYaw(motors, self._originalC0, self._tilts, limbYaw)
end

function CharacterPoseController:_unbindCharacter()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	self:_restoreC0()

	self._character = nil
	self._rootPart = nil
	self._humanoid = nil
	self._motors = nil
	self._originalC0 = {}
	self._tilts = zeroTilts()
	self._timeSincePoseUpdate = 0
end

function CharacterPoseController:_bindCharacter(character: Model)
	self:_unbindCharacter()

	local rootPart = waitForBasePart(character, "HumanoidRootPart", CHARACTER_LOOKUP_TIMEOUT)
	local torso = waitForBasePart(character, "Torso", CHARACTER_LOOKUP_TIMEOUT)
	local humanoid = waitForHumanoid(character, CHARACTER_LOOKUP_TIMEOUT)
	if not (rootPart and torso and humanoid) then
		return
	end

	local motors = getPoseMotors(rootPart, torso)
	if not motors then
		warn("[CharacterPoseController] Missing R6 pose motors for character:", character:GetFullName())
		return
	end

	self._character = character
	self._rootPart = rootPart
	self._humanoid = humanoid
	self._motors = motors
	self._originalC0 = {
		rootJoint = motors.rootJoint.C0,
		neck = motors.neck.C0,
		rightShoulder = motors.rightShoulder.C0,
		leftShoulder = motors.leftShoulder.C0,
		rightHip = motors.rightHip.C0,
		leftHip = motors.leftHip.C0,
	}
	self._tilts = zeroTilts()
	self._timeSincePoseUpdate = 0
	self:_restoreC0()

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function(dt)
		local token = RuntimeProfiler.Begin("Client/CharacterPoseController/Render")
		self:_step(dt)
		RuntimeProfiler.End("Client/CharacterPoseController/Render", token)
	end)
end

function CharacterPoseController:OnStart()
	self._tilts = zeroTilts()

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

return CharacterPoseController
