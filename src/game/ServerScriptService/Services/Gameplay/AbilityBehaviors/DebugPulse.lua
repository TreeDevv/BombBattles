local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type ServerActivateContext = AbilityTypes.ServerActivateContext
type AbilityActivationResult = AbilityTypes.AbilityActivationResult

local DebugPulse = {} :: AbilityTypes.ServerBehavior

function DebugPulse.OnActivate(context: ServerActivateContext): AbilityActivationResult
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
