local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local RoundRagdollRuntime = {}

local RAGDOLL_VELOCITY_SCALE = 0.25
local RAGDOLL_ANGULAR_VELOCITY_SCALE = 0.2
local RAGDOLL_FOLDER_NAME = "_DeathRagdollConstraints"
local RAGDOLLED_ATTRIBUTE = "DeathRagdolled"

function RoundRagdollRuntime.Prepare(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	humanoid.BreakJointsOnDeath = false
	pcall(function()
		humanoid.RequiresNeck = false
	end)
end

function RoundRagdollRuntime.Apply(character: Model, reason: string, debugLog: ((string, ...any) -> ())?)
	if character:GetAttribute(RAGDOLLED_ATTRIBUTE) == true then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	RoundRagdollRuntime.Prepare(character)
	character:SetAttribute(RAGDOLLED_ATTRIBUTE, true)

	local previousFolder = character:FindFirstChild(RAGDOLL_FOLDER_NAME)
	if previousFolder then
		previousFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = RAGDOLL_FOLDER_NAME
	folder.Parent = character

	local constraintCount = 0
	for _, descendant in ipairs(character:GetDescendants()) do
		if not descendant:IsA("Motor6D") then
			continue
		end

		local motor = descendant :: Motor6D
		local part0 = motor.Part0
		local part1 = motor.Part1
		if not (part0 and part1) then
			continue
		end

		local attachment0 = Instance.new("Attachment")
		attachment0.Name = motor.Name .. "_DeathRagdollA0"
		attachment0.CFrame = motor.C0
		attachment0.Parent = part0

		local attachment1 = Instance.new("Attachment")
		attachment1.Name = motor.Name .. "_DeathRagdollA1"
		attachment1.CFrame = motor.C1
		attachment1.Parent = part1

		local socket = Instance.new("BallSocketConstraint")
		socket.Name = motor.Name .. "_DeathRagdollSocket"
		socket.Attachment0 = attachment0
		socket.Attachment1 = attachment1
		socket.LimitsEnabled = true
		socket.TwistLimitsEnabled = true
		socket.UpperAngle = 70
		socket.TwistLowerAngle = -45
		socket.TwistUpperAngle = 45
		socket.Parent = folder

		motor.Enabled = false
		constraintCount += 1
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = descendant.Name ~= "HumanoidRootPart"
			descendant.AssemblyLinearVelocity *= RAGDOLL_VELOCITY_SCALE
			descendant.AssemblyAngularVelocity *= RAGDOLL_ANGULAR_VELOCITY_SCALE
		end
	end

	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end)
	RuntimeProfiler.Count("Server/Round/Death/RagdollConstraints", constraintCount)
	RuntimeProfiler.Count("Server/Round/Death/Ragdolled")
	if debugLog then
		debugLog("Applied death ragdoll", character.Name, reason, "constraints", constraintCount)
	end
end

return table.freeze(RoundRagdollRuntime)
