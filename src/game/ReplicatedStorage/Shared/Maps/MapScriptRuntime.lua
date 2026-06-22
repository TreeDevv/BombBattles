local MapScriptRuntime = {}

type Cleanup = () -> ()

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function getHoistClickPart(motor: HingeConstraint): BasePart?
	local rod = motor.Parent
	local hoist = rod and rod.Parent
	if not (hoist and hoist.Name == "Hoist") then
		return nil
	end

	local trigger = hoist and hoist:FindFirstChild("HoistTrigger")
	if trigger and trigger:IsA("BasePart") then
		return trigger
	end

	return if rod and rod:IsA("BasePart") then rod else nil
end

local function bindCastles(map: Model): Cleanup
	local connections = {}

	for _, descendant in ipairs(map:GetDescendants()) do
		if not descendant:IsA("HingeConstraint") then
			continue
		end

		local clickPart = getHoistClickPart(descendant)
		if not clickPart then
			continue
		end

		local clickDetector = clickPart:FindFirstChildOfClass("ClickDetector")
		if not clickDetector then
			clickDetector = Instance.new("ClickDetector")
			clickDetector.Name = "HoistClickDetector"
			clickDetector.Parent = clickPart
		end

		local motor = descendant
		local direction = -1
		local state = 0

		table.insert(connections, clickDetector.MouseClick:Connect(function()
			if state == -1 then
				direction = 1
			elseif state == 1 then
				direction = -1
			end

			state += direction

			if state == 0 then
				motor.ActuatorType = Enum.ActuatorType.Servo
				motor.TargetAngle = motor.CurrentAngle
			else
				motor.ActuatorType = Enum.ActuatorType.Motor
				motor.AngularVelocity = state * -2
			end
		end))
	end

	return function()
		disconnectAll(connections)
	end
end

local BEHAVIORS: { [string]: (Model) -> Cleanup } = {
	Castles = bindCastles,
}

function MapScriptRuntime.Bind(mapId: string, map: Model): Cleanup
	local behavior = BEHAVIORS[mapId]
	if not behavior then
		return function() end
	end

	local ok, cleanup = pcall(behavior, map)
	if not ok then
		warn(("[MapScriptRuntime] Failed to bind %s: %s"):format(mapId, tostring(cleanup)))
		return function() end
	end

	return if typeof(cleanup) == "function" then cleanup else function() end
end

return table.freeze(MapScriptRuntime)
