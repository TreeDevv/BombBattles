local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)

local PracticeRangeTargeting = {}

local LOBBY_NAME = "Lobby"
local PRACTICE_RANGE_NAME = "PracticeRange"

function PracticeRangeTargeting.GetPracticeRange(): Model?
	local lobby = workspace:FindFirstChild(LOBBY_NAME)
	local range = lobby and lobby:FindFirstChild(PRACTICE_RANGE_NAME)
	return if range and range:IsA("Model") then range else nil
end

function PracticeRangeTargeting.GetServerTargetRoot(player: Player, roundRoot: Instance?): Instance?
	if CombatEligibility.IsPracticeRangeActive(player) then
		return PracticeRangeTargeting.GetPracticeRange() or roundRoot
	end

	return roundRoot
end

function PracticeRangeTargeting.GetClientTargetRoot(
	player: Player,
	roundState: any,
	activeRoundState: any,
	roundRoot: Instance?
): Instance?
	if CombatEligibility.IsClientPracticeOnly(player, roundState, activeRoundState) then
		return PracticeRangeTargeting.GetPracticeRange() or roundRoot
	end

	return roundRoot
end

function PracticeRangeTargeting.IsInTargetRoot(instance: Instance, targetRoot: Instance?): boolean
	return targetRoot == nil or instance:IsDescendantOf(targetRoot)
end

function PracticeRangeTargeting.GetObjectParentForServer(player: Player, roundRoot: Instance?): Instance
	return PracticeRangeTargeting.GetServerTargetRoot(player, roundRoot) or workspace
end

return table.freeze(PracticeRangeTargeting)
