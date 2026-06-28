local DebugEconomyConfig = {}

DebugEconomyConfig.InfiniteCashEnabled = true
DebugEconomyConfig.InfiniteCashAppliesToAllPlayers = true
DebugEconomyConfig.EffectiveCashValue = 999999999999
DebugEconomyConfig.DisplayCashText = "INF"

function DebugEconomyConfig.HasInfiniteCash(_player: Player?): boolean
	return DebugEconomyConfig.InfiniteCashEnabled == true
		and DebugEconomyConfig.InfiniteCashAppliesToAllPlayers == true
end

function DebugEconomyConfig.GetEffectiveCash(player: Player?, storedCash: any): number
	if DebugEconomyConfig.HasInfiniteCash(player) then
		return DebugEconomyConfig.EffectiveCashValue
	end

	return math.max(0, tonumber(storedCash) or 0)
end

function DebugEconomyConfig.ShouldBypassCashSpend(player: Player?): boolean
	return DebugEconomyConfig.HasInfiniteCash(player)
end

return table.freeze(DebugEconomyConfig)
