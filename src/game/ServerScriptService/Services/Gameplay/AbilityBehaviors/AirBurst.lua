local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type ServerActivateContext = AbilityTypes.ServerActivateContext

local AirBurst = {} :: AbilityTypes.ServerBehavior

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

function AirBurst.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil
end

function AirBurst.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local state = context.slotState.state
	local activationCount = if typeof(state) == "table" and typeof(state.activationCount) == "number"
		then state.activationCount
		else 0

	return {
		state = {
			activationCount = activationCount + 1,
			lastActivatedAt = context.now,
		},
	}
end

return AirBurst
