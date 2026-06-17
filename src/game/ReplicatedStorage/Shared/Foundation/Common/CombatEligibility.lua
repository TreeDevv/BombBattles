local CombatEligibility = {}

CombatEligibility.AFKAttribute = "AFK"
CombatEligibility.RoundAliveAttribute = "RoundAlive"
CombatEligibility.PracticeRangeActiveAttribute = "PracticeRangeActive"

function CombatEligibility.IsPlayerAFK(player: Player?): boolean
	return player ~= nil and player:GetAttribute(CombatEligibility.AFKAttribute) == true
end

function CombatEligibility.IsPracticeRangeActive(player: Player?): boolean
	return player ~= nil and player:GetAttribute(CombatEligibility.PracticeRangeActiveAttribute) == true
end

function CombatEligibility.HasAliveCharacter(player: Player?): boolean
	if not player then
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	return humanoid ~= nil and humanoid.Health > 0 and rootPart ~= nil and rootPart:IsA("BasePart")
end

function CombatEligibility.IsRoundActivePlayer(player: Player?, roundService: any): boolean
	return player ~= nil
		and typeof(roundService) == "table"
		and type(roundService.IsPlayerActive) == "function"
		and roundService:IsPlayerActive(player) == true
end

function CombatEligibility.IsCombatActive(player: Player?, roundService: any): boolean
	return CombatEligibility.IsRoundActivePlayer(player, roundService)
		or CombatEligibility.IsPracticeRangeActive(player)
end

function CombatEligibility.IsPracticeOnly(player: Player?, roundService: any): boolean
	return CombatEligibility.IsPracticeRangeActive(player)
		and not CombatEligibility.IsRoundActivePlayer(player, roundService)
end

function CombatEligibility.IsClientCombatActive(player: Player, roundState: any, activeRoundState: any): boolean
	return (roundState == activeRoundState and player:GetAttribute(CombatEligibility.RoundAliveAttribute) == true)
		or CombatEligibility.IsPracticeRangeActive(player)
end

function CombatEligibility.IsClientPracticeOnly(player: Player, roundState: any, activeRoundState: any): boolean
	return CombatEligibility.IsPracticeRangeActive(player)
		and not (roundState == activeRoundState and player:GetAttribute(CombatEligibility.RoundAliveAttribute) == true)
end

return table.freeze(CombatEligibility)
