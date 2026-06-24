local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)

local OwnerExplosionLaunch = {}

local FORCE_AIRBORNE_UNTIL_ATTR = "AirControl_ForceAirborneUntil"
local LAUNCH_SOURCE_ATTR = "AirControl_LaunchSource"
local LAUNCH_SERIAL_ATTR = "AirControl_LaunchSerial"
local LAUNCHED_AT_ATTR = "AirControl_LaunchedAt"
local KNOCKBACK_UNTIL_ATTR = "Bomb_KnockbackUntil"
local EXPLOSIVE_MIN_AIR_TIME = 0.4
local KNOCKBACK_MOVEMENT_SUPPRESS_SECONDS = math.max(tonumber(BombConfig.KnockbackMovementSuppressSeconds) or 0.25, 0)
local DEFAULT_LAUNCH_GROUP_WINDOW_SECONDS = 3
local launchGroups: { [string]: number } = {}

local function readPositiveNumber(value: any, fallback: number): number
	return if typeof(value) == "number" and value == value and value > 0 then value else fallback
end

local function readNonNegativeNumber(value: any, fallback: number): number
	return if typeof(value) == "number" and value == value and value >= 0 then value else fallback
end

local function readOptionalPositiveNumber(value: any, fallback: number?): number?
	return if typeof(value) == "number" and value == value and value > 0 then value else fallback
end

local function getKnockbackRatio(value: any, baseValue: number): number
	if typeof(value) == "number" and value == value and value >= 0 and baseValue > 0 then
		return value / baseValue
	end
	return 1
end

local function cleanupLaunchGroups(currentTime: number)
	for groupId, expiresAt in pairs(launchGroups) do
		if expiresAt <= currentTime then
			launchGroups[groupId] = nil
		end
	end
end

local function getRepeatLaunchMultiplier(options, currentTime: number): number
	local groupId = options.ownerClientLaunchGroupId
	if typeof(groupId) ~= "string" or groupId == "" then
		return 1
	end

	cleanupLaunchGroups(currentTime)
	if launchGroups[groupId] then
		return readNonNegativeNumber(options.ownerClientRepeatLaunchMultiplier, 0)
	end

	local windowSeconds = readNonNegativeNumber(options.ownerClientLaunchGroupWindowSeconds, DEFAULT_LAUNCH_GROUP_WINDOW_SECONDS)
	launchGroups[groupId] = currentTime + windowSeconds
	return 1
end

local function clampMagnitude(vector: Vector3, maxMagnitude: number?): Vector3
	if not maxMagnitude or maxMagnitude <= 0 then
		return vector
	end

	local magnitude = vector.Magnitude
	if magnitude <= maxMagnitude or magnitude <= 0 then
		return vector
	end

	return vector.Unit * maxMagnitude
end

local function getMaxHorizontalSpeed(options): number?
	return readOptionalPositiveNumber(options.maxKnockbackHorizontalSpeed, BombConfig.KnockbackMaxHorizontalSpeed)
end

local function getMaxVerticalSpeed(options): number?
	return readOptionalPositiveNumber(options.maxKnockbackVerticalSpeed, BombConfig.KnockbackMaxVerticalSpeed)
end

local function getMaxAngularSpeed(options): number?
	return readOptionalPositiveNumber(options.maxKnockbackAngularSpeed, BombConfig.KnockbackMaxAngularSpeed)
end

local function markAirControlLaunch(character: Model?, source: string, minAirTime: number)
	if not character then
		return
	end

	local now = os.clock()
	local currentForceUntil = character:GetAttribute(FORCE_AIRBORNE_UNTIL_ATTR)
	local currentSerial = character:GetAttribute(LAUNCH_SERIAL_ATTR)
	character:SetAttribute(
		FORCE_AIRBORNE_UNTIL_ATTR,
		math.max(if typeof(currentForceUntil) == "number" then currentForceUntil else 0, now + minAirTime)
	)
	character:SetAttribute(LAUNCH_SOURCE_ATTR, source)
	character:SetAttribute(LAUNCH_SERIAL_ATTR, (if typeof(currentSerial) == "number" then currentSerial else 0) + 1)
	character:SetAttribute(LAUNCHED_AT_ATTR, now)
	local knockbackUntil = workspace:GetServerTimeNow() + KNOCKBACK_MOVEMENT_SUPPRESS_SECONDS
	character:SetAttribute(KNOCKBACK_UNTIL_ATTR, knockbackUntil)
	task.delay(KNOCKBACK_MOVEMENT_SUPPRESS_SECONDS + 0.1, function()
		if character.Parent and character:GetAttribute(KNOCKBACK_UNTIL_ATTR) == knockbackUntil then
			character:SetAttribute(KNOCKBACK_UNTIL_ATTR, nil)
		end
	end)
end

local function clampLaunchVelocityDelta(rootPart: BasePart, velocityDelta: Vector3, options): Vector3
	local desiredVelocity = rootPart.AssemblyLinearVelocity + velocityDelta
	local horizontal = clampMagnitude(
		Vector3.new(desiredVelocity.X, 0, desiredVelocity.Z),
		getMaxHorizontalSpeed(options)
	)
	local maxVerticalSpeed = getMaxVerticalSpeed(options)
	local vertical = if maxVerticalSpeed then math.min(desiredVelocity.Y, maxVerticalSpeed) else desiredVelocity.Y
	return Vector3.new(horizontal.X, vertical, horizontal.Z) - rootPart.AssemblyLinearVelocity
end

local function clampLaunchAngularVelocity(rootPart: BasePart, options)
	rootPart.AssemblyAngularVelocity = clampMagnitude(rootPart.AssemblyAngularVelocity, getMaxAngularSpeed(options))
end

function OwnerExplosionLaunch.ApplyForPlayer(player: Player, origin: Vector3, options: any?)
	options = if typeof(options) == "table" then options else {}
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not (character and humanoid and rootPart and rootPart:IsA("BasePart") and humanoid.Health > 0) then
		return
	end

	local distance = (rootPart.Position - origin).Magnitude
	local outerRadius = readPositiveNumber(options.outerRadius, BombConfig.OuterRadius)
	if distance > outerRadius then
		return
	end

	local repeatMultiplier = getRepeatLaunchMultiplier(options, workspace:GetServerTimeNow())
	if repeatMultiplier <= 0 then
		return
	end

	local away = rootPart.Position - origin
	if away.Magnitude < 0.05 then
		away = Vector3.yAxis
	else
		away = away.Unit
	end

	local radiusAlpha = math.clamp(1 - (distance / outerRadius), 0, 1)
	local scale = math.max(radiusAlpha, BombConfig.OwnerClientLaunchMinScale)
	if scale <= 0 then
		return
	end

	local horizontalRatio = getKnockbackRatio(options.knockbackHorizontal, BombConfig.KnockbackHorizontal)
	local verticalRatio = getKnockbackRatio(options.knockbackVertical, BombConfig.KnockbackVertical)
	local horizontal = BombConfig.OwnerClientLaunchHorizontal * horizontalRatio * scale * repeatMultiplier
	local velocityDelta = Vector3.new(
		away.X * horizontal,
		BombConfig.OwnerClientLaunchVertical * verticalRatio * scale * repeatMultiplier,
		away.Z * horizontal
	)
	velocityDelta = clampLaunchVelocityDelta(rootPart, velocityDelta, options)

	if velocityDelta.Magnitude > 0.001 then
		rootPart:ApplyImpulse(velocityDelta * rootPart.AssemblyMass)
		clampLaunchAngularVelocity(rootPart, options)
	end
	markAirControlLaunch(character, "Explosive", EXPLOSIVE_MIN_AIR_TIME)
end

return table.freeze(OwnerExplosionLaunch)
