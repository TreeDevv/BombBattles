local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTES_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "CombatMotion"
local KNOCKBACK_UNTIL_ATTR = "Bomb_KnockbackUntil"

local LocalPlayer = Players.LocalPlayer

local CombatMotionController = {}

local connection: RBXScriptConnection? = nil
local lastMotionId = 0

local function isFiniteVector(value: any): boolean
	return typeof(value) == "Vector3"
		and value.X == value.X
		and value.Y == value.Y
		and value.Z == value.Z
		and value.Magnitude < math.huge
end

local function getCharacterParts(): (Model?, Humanoid?, BasePart?)
	local character = LocalPlayer.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return character, humanoid, rootPart
	end
	return character, humanoid, nil
end

local function clampMagnitude(vector: Vector3, maxMagnitude: number?): Vector3
	if typeof(maxMagnitude) ~= "number" or maxMagnitude <= 0 then
		return vector
	end
	local magnitude = vector.Magnitude
	if magnitude <= maxMagnitude then
		return vector
	end
	return vector.Unit * maxMagnitude
end

local function clampVelocity(rootPart: BasePart, maxHorizontalSpeed: number?, maxVerticalSpeed: number?)
	local velocity = rootPart.AssemblyLinearVelocity
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
	horizontal = clampMagnitude(horizontal, maxHorizontalSpeed)

	local vertical = velocity.Y
	if typeof(maxVerticalSpeed) == "number" and maxVerticalSpeed > 0 then
		vertical = math.clamp(vertical, -maxVerticalSpeed, maxVerticalSpeed)
	end

	rootPart.AssemblyLinearVelocity = Vector3.new(horizontal.X, vertical, horizontal.Z)
end

local function markMovementSuppress(character: Model?, suppressUntil: any)
	if not character or typeof(suppressUntil) ~= "number" or suppressUntil <= 0 then
		return
	end

	local current = character:GetAttribute(KNOCKBACK_UNTIL_ATTR)
	if typeof(current) ~= "number" or suppressUntil > current then
		character:SetAttribute(KNOCKBACK_UNTIL_ATTR, suppressUntil)
	end
end

local function applyMotion(payload)
	if typeof(payload) ~= "table" or typeof(payload.id) ~= "number" then
		return
	end
	if payload.id <= lastMotionId then
		return
	end
	lastMotionId = payload.id

	local character, _, rootPart = getCharacterParts()
	if not rootPart then
		return
	end

	markMovementSuppress(character, payload.movementSuppressUntil)

	if payload.kind == "Impulse" and isFiniteVector(payload.velocityDelta) then
		local mass = math.max(rootPart.AssemblyMass, 0)
		if mass > 0 then
			rootPart:ApplyImpulse(payload.velocityDelta * mass)
			clampVelocity(rootPart, payload.maxHorizontalSpeed, payload.maxVerticalSpeed)
		end
	elseif payload.kind == "SetVelocity" and isFiniteVector(payload.velocity) then
		rootPart.AssemblyLinearVelocity = payload.velocity
	end

	if typeof(payload.maxAngularSpeed) == "number" and payload.maxAngularSpeed > 0 then
		rootPart.AssemblyAngularVelocity = clampMagnitude(rootPart.AssemblyAngularVelocity, payload.maxAngularSpeed)
	end
end

local function getRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(REMOTE_NAME, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

function CombatMotionController:OnStart()
	local remote = getRemote()
	if not remote then
		return
	end

	if connection then
		connection:Disconnect()
	end

	connection = remote.OnClientEvent:Connect(applyMotion)
end

return CombatMotionController
