local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)

local LocalPlayer = Players.LocalPlayer

local ReplayLocalRecorder = {}

local MAX_ANIMATION_LINEAR_SPEED = 220
local MAX_REPLAY_POSE_JOINTS = 32
local MIN_REPLAY_CAMERA_FOV = 20
local MAX_REPLAY_CAMERA_FOV = 120
local CAMERA_SPECTATING_ATTR = "Camera_Spectating"

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteCFrame(value: any): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end

	local components = { value:GetComponents() }
	for _, component in ipairs(components) do
		if not isFiniteNumber(component) then
			return false
		end
	end
	return true
end

local function getBoolAttribute(instance: Instance?, name: string): boolean?
	local value = instance and instance:GetAttribute(name)
	return if typeof(value) == "boolean" then value else nil
end

local function getNumberAttribute(instance: Instance?, name: string): number?
	local value = instance and instance:GetAttribute(name)
	return if isFiniteNumber(value) then value else nil
end

local function getStringAttribute(instance: Instance?, name: string): string?
	local value = instance and instance:GetAttribute(name)
	return if typeof(value) == "string" and value ~= "" then value else nil
end

local function clampVectorMagnitude(value: any, maxMagnitude: number): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	if value.X ~= value.X or value.Y ~= value.Y or value.Z ~= value.Z then
		return nil
	end

	local magnitude = value.Magnitude
	if magnitude <= maxMagnitude then
		return value
	end
	if magnitude <= 0 then
		return Vector3.zero
	end
	return value.Unit * maxMagnitude
end

local function getMotorJointKey(motor: Motor6D): string
	local part0Name = if motor.Part0 then motor.Part0.Name else ""
	local part1Name = if motor.Part1 then motor.Part1.Name else ""
	return part0Name .. ">" .. motor.Name .. ">" .. part1Name
end

local function collectLocalPoseJoints(character: Model): { any }
	local joints = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if #joints >= MAX_REPLAY_POSE_JOINTS then
			break
		end
		if not descendant:IsA("Motor6D") then
			continue
		end
		if not isFiniteCFrame(descendant.Transform) then
			continue
		end
		table.insert(joints, {
			name = descendant.Name,
			part0 = if descendant.Part0 then descendant.Part0.Name else nil,
			part1 = if descendant.Part1 then descendant.Part1.Name else nil,
			key = getMotorJointKey(descendant),
			transform = descendant.Transform,
		})
	end
	return joints
end

local function getLocalCameraSnapshot(sampleTime: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	if LocalPlayer:GetAttribute(CAMERA_SPECTATING_ATTR) == true or camera.CameraType == Enum.CameraType.Scriptable then
		return nil
	end

	local cframe = camera.CFrame
	local focus = camera.Focus
	if not (isFiniteCFrame(cframe) and isFiniteCFrame(focus)) then
		return nil
	end

	return {
		sampleTime = sampleTime,
		cframe = cframe,
		focus = focus,
		fieldOfView = math.clamp(camera.FieldOfView, MIN_REPLAY_CAMERA_FOV, MAX_REPLAY_CAMERA_FOV),
	}
end

local function getLocalHeldBombSnapshot()
	local attrs = BombConfig.Attributes
	local bombCooking = LocalPlayer:GetAttribute(attrs.Cooking) == true
	if not bombCooking then
		return nil
	end

	local fuseStartedAt = getNumberAttribute(LocalPlayer, attrs.CookStartedAt)
	local fuseEndsAt = if fuseStartedAt then fuseStartedAt + BombConfig.FuseSeconds else nil
	local bombSkinId = BombSkinConfig.NormalizeSkinId(LocalPlayer:GetAttribute(BombSkinConfig.AttributeName))
	if bombSkinId == "" then
		bombSkinId = BombSkinConfig.DefaultSkinId
	end

	return {
		bombType = BombConfig.RuntimeBombName,
		bombSkinId = bombSkinId,
		fuseStartedAt = fuseStartedAt,
		fuseEndsAt = fuseEndsAt,
		visualScale = BombConfig.HeldVisualScale,
		sizeScale = BombConfig.HeldVisualScale,
	}
end

local function getLocalHumanoidState(character: Model?, humanoid: Humanoid?, rootPart: BasePart?)
	local sampleTime = workspace:GetServerTimeNow()
	local linearVelocity = if rootPart then rootPart.AssemblyLinearVelocity else Vector3.zero
	local horizontalVelocity = Vector3.new(linearVelocity.X, 0, linearVelocity.Z)
	local effectiveSpeed = getNumberAttribute(character, "Movement_EffectiveSpeed") or horizontalVelocity.Magnitude
	local moveMagnitude = getNumberAttribute(character, "Movement_MoveMagnitude")
	if not moveMagnitude then
		moveMagnitude = if effectiveSpeed > 0.5 then math.clamp(effectiveSpeed / 24, 0, 1) else 0
	end

	local grounded = getBoolAttribute(character, "Movement_Grounded")
	if grounded == nil and humanoid then
		grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	end

	local attrs = BombConfig.Attributes
	local rootCFrame = if rootPart and isFiniteCFrame(rootPart.CFrame) then rootPart.CFrame else nil
	local state = {
		sampleTime = sampleTime,
		rootCFrame = rootCFrame,
		grounded = if grounded == nil then true else grounded,
		sprinting = getBoolAttribute(character, "Movement_Sprinting") or effectiveSpeed >= 21,
		crouching = getBoolAttribute(character, "Movement_Crouching") or false,
		sliding = getBoolAttribute(character, "Movement_Sliding") or false,
		effectiveSpeed = effectiveSpeed,
		moveMagnitude = moveMagnitude,
		jumpSerial = getNumberAttribute(character, "Movement_JumpSerial"),
		lastJumpKind = getStringAttribute(character, "Movement_LastJumpKind"),
		shiftLocked = getBoolAttribute(character, "Camera_ShiftLocked") or false,
		linearVelocity = clampVectorMagnitude(linearVelocity, MAX_ANIMATION_LINEAR_SPEED) or Vector3.zero,
		bombCooking = LocalPlayer:GetAttribute(attrs.Cooking) == true,
		bombCookStartedAt = getNumberAttribute(LocalPlayer, attrs.CookStartedAt),
	}

	local heldBomb = getLocalHeldBombSnapshot()
	if heldBomb then
		state.heldBomb = heldBomb
	end

	if character then
		local joints = collectLocalPoseJoints(character)
		if #joints > 0 then
			state.pose = {
				sampleTime = sampleTime,
				joints = joints,
			}
		end
	end

	local cameraSnapshot = getLocalCameraSnapshot(sampleTime)
	if cameraSnapshot then
		state.camera = cameraSnapshot
	end

	return state
end

function ReplayLocalRecorder.BuildAnimationStatePayload()
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and rootPart and rootPart:IsA("BasePart")) then
		return nil
	end

	return getLocalHumanoidState(character, humanoid, rootPart)
end

return ReplayLocalRecorder
