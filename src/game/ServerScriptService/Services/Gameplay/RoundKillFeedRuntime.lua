local Players = game:GetService("Players")

local RoundKillFeedRuntime = {}

function RoundKillFeedRuntime.GetPlayerByKey(playerKey: string, getPlayerKey): Player?
	for _, player in ipairs(Players:GetPlayers()) do
		if getPlayerKey(player) == playerKey then
			return player
		end
	end

	return nil
end

function RoundKillFeedRuntime.FireElimination(options): Player?
	local killer = RoundKillFeedRuntime.GetPlayerByKey(options.eliminatorKey, options.getPlayerKey)
	local botKiller = if not killer and options.getBotIdentity
		then options.getBotIdentity(options.eliminatorKey)
		else nil
	if not killer and not botKiller then
		return nil
	end

	local killerTeam = if killer then options.getTrackedTeamName(killer) else botKiller.teamName
	local victimTeam = options.getTrackedTeamName(options.victim)
	if not killerTeam or not victimTeam or killerTeam == victimTeam then
		return killer
	end

	local remote = options.getRemote()
	remote:FireAllClients({
		roundId = options.roundId,
		killerUserId = if killer then killer.UserId else botKiller.userId,
		killerName = if killer then killer.Name else botKiller.name,
		killerDisplayName = if killer then killer.DisplayName else botKiller.displayName,
		killerTeam = killerTeam,
		killerIsNPC = killer == nil,
		victimUserId = options.victim.UserId,
		victimName = options.victim.Name,
		victimDisplayName = options.victim.DisplayName,
		victimTeam = victimTeam,
	})

	return killer
end

return table.freeze(RoundKillFeedRuntime)
