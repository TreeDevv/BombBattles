local DebugPulse = {}

function DebugPulse.OnActivate(context)
	local currentState = context.slotState.state
	local pulseCount = 0
	if typeof(currentState) == "table" and typeof(currentState.pulseCount) == "number" then
		pulseCount = currentState.pulseCount
	end

	return {
		state = {
			pulseCount = pulseCount + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "DebugPulse",
			payload = {
				pulseCount = pulseCount + 1,
			},
		},
	}
end

return DebugPulse
