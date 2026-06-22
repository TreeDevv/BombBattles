local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)

local OwnerExplosionLaunch = {}

local FORCE_AIRBORNE_UNTIL_ATTR = "AirControl_ForceAirborneUntil"
local LAUNCH_SOURCE_ATTR = "AirControl_LaunchSource"
local LAUNCH_SERIAL_ATTR = "AirControl_LaunchSerial"
local LAUNCHED_AT_ATTR = "AirControl_LaunchedAt"
local EXPLOSIVE_MIN_AIR_TIME = 0.4

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
end

function OwnerExplosionLaunch.ApplyForPlayer(player: Player, origin: Vector3)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not (character and humanoid and rootPart and rootPart:IsA("BasePart") and humanoid.Health > 0) then
		return
	end

	local distance = (rootPart.Position - origin).Magnitude
	if distance > BombConfig.OuterRadius then
		return
	end

	local away = rootPart.Position - origin
	if away.Magnitude < 0.05 then
		away = Vector3.yAxis
	else
		away = away.Unit
	end

	local radiusAlpha = math.clamp(1 - (distance / BombConfig.OuterRadius), 0, 1)
	local scale = math.max(radiusAlpha, BombConfig.OwnerClientLaunchMinScale)
	if scale <= 0 then
		return
	end

	local horizontal = BombConfig.OwnerClientLaunchHorizontal * scale
	local velocityDelta = Vector3.new(
		away.X * horizontal,
		BombConfig.OwnerClientLaunchVertical * scale,
		away.Z * horizontal
	)

	rootPart:ApplyImpulse(velocityDelta * rootPart.AssemblyMass)
	markAirControlLaunch(character, "Explosive", EXPLOSIVE_MIN_AIR_TIME)
end

return table.freeze(OwnerExplosionLaunch)
