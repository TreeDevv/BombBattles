local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)

local REMOTES_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "CombatMotion"
local KNOCKBACK_UNTIL_ATTR = "Bomb_KnockbackUntil"

local CombatMotionService = {}

local remote: RemoteEvent? = nil
local motionSerial = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function ensureRemote(): RemoteEvent
	if remote then
		return remote
	end

	local folder = RemoteUtil.EnsureFolder(ReplicatedStorage, REMOTES_FOLDER_NAME)
	remote = RemoteUtil.EnsureRemoteEvent(folder, REMOTE_NAME)
	return remote :: RemoteEvent
end

local function isFiniteVector(value: any): boolean
	return typeof(value) == "Vector3"
		and value.X == value.X
		and value.Y == value.Y
		and value.Z == value.Z
		and value.Magnitude < math.huge
end

local function nextMotionId(): number
	motionSerial += 1
	return motionSerial
end

local function markMovementSuppress(character: Model?, suppressUntil: number?)
	if not character or typeof(suppressUntil) ~= "number" or suppressUntil <= 0 then
		return
	end

	local current = character:GetAttribute(KNOCKBACK_UNTIL_ATTR)
	if typeof(current) ~= "number" or suppressUntil > current then
		character:SetAttribute(KNOCKBACK_UNTIL_ATTR, suppressUntil)
	end
end

local function sendMotion(player: Player, payload)
	payload.id = nextMotionId()
	payload.serverTime = now()
	ensureRemote():FireClient(player, payload)
end

function CombatMotionService.SendImpulse(player: Player, character: Model?, velocityDelta: Vector3, options): boolean
	if not (player and player:IsA("Player")) or not isFiniteVector(velocityDelta) then
		return false
	end

	options = options or {}
	local suppressUntil = if typeof(options.movementSuppressUntil) == "number"
		then options.movementSuppressUntil
		else nil
	if not suppressUntil and typeof(options.movementSuppressSeconds) == "number" and options.movementSuppressSeconds > 0 then
		suppressUntil = now() + options.movementSuppressSeconds
	end

	markMovementSuppress(character, suppressUntil)
	sendMotion(player, {
		kind = "Impulse",
		sourceType = options.sourceType,
		sourceId = options.sourceId,
		velocityDelta = velocityDelta,
		movementSuppressUntil = suppressUntil,
		maxAngularSpeed = options.maxAngularSpeed,
		maxHorizontalSpeed = options.maxHorizontalSpeed,
		maxVerticalSpeed = options.maxVerticalSpeed,
	})
	return true
end

function CombatMotionService.SendSetVelocity(player: Player, character: Model?, velocity: Vector3, options): boolean
	if not (player and player:IsA("Player")) or not isFiniteVector(velocity) then
		return false
	end

	options = options or {}
	local suppressUntil = if typeof(options.movementSuppressUntil) == "number"
		then options.movementSuppressUntil
		else nil
	if not suppressUntil and typeof(options.movementSuppressSeconds) == "number" and options.movementSuppressSeconds > 0 then
		suppressUntil = now() + options.movementSuppressSeconds
	end

	markMovementSuppress(character, suppressUntil)
	sendMotion(player, {
		kind = "SetVelocity",
		sourceType = options.sourceType,
		sourceId = options.sourceId,
		velocity = velocity,
		movementSuppressUntil = suppressUntil,
		maxAngularSpeed = options.maxAngularSpeed,
	})
	return true
end

function CombatMotionService.OnStart()
	ensureRemote()
end

return CombatMotionService
