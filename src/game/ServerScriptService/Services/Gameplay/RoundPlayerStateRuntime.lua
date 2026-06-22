local RoundPlayerStateRuntime = {}

function RoundPlayerStateRuntime.ClearRoundState(player: Player, attrs)
	player:SetAttribute(attrs.roundId, nil)
	player:SetAttribute(attrs.roundTeam, nil)
	player:SetAttribute(attrs.roundAlive, nil)
	player:SetAttribute(attrs.roundRespawnEndsAt, nil)
	player.Neutral = true
	player.Team = nil
end

function RoundPlayerStateRuntime.ClearRoundStateForPlayers(players: { Player }, attrs)
	for _, player in ipairs(players) do
		RoundPlayerStateRuntime.ClearRoundState(player, attrs)
	end
end

return table.freeze(RoundPlayerStateRuntime)
