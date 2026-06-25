local RoundLateJoinRuntime = {}

local function getRoundPlayerCountsByTeam(options): { [string]: number }
	local counts = {}
	for _, teamName in ipairs(options.teamOrder) do
		counts[teamName] = 0
	end

	for player in pairs(options.roundPlayers) do
		if player.Parent == options.playersService then
			local teamName = options.playerTeams[player]
			if teamName and counts[teamName] ~= nil then
				counts[teamName] += 1
			end
		end
	end

	return counts
end

local function chooseTeam(options): string?
	local counts = getRoundPlayerCountsByTeam(options)
	local lowestCount = math.huge
	local candidates = {}

	for _, teamName in ipairs(options.teamOrder) do
		local count = counts[teamName] or 0
		if count < lowestCount then
			lowestCount = count
			table.clear(candidates)
			table.insert(candidates, teamName)
		elseif count == lowestCount then
			table.insert(candidates, teamName)
		end
	end

	if #candidates == 0 then
		return nil
	end
	return candidates[options.rng:NextInteger(1, #candidates)]
end

local function rollbackPlayer(options)
	local player: Player = options.player
	options.disconnectCharacterConnections(player)
	options.roundPlayers[player] = nil
	options.alivePlayers[player] = nil
	options.playerTeams[player] = nil
	options.clearPlayerRoundState(player)
	if player.Parent == options.playersService then
		options.bindLobbyCharacter(player)
	end
	options.syncAliveCounts()
end

function RoundLateJoinRuntime.TryFillPlayer(options): boolean
	local player: Player = options.player
	if
		player.Parent ~= options.playersService
		or options.currentState ~= options.activeState
		or options.roundPlayers[player] == true
	then
		return false
	end

	local activeMap = options.getActiveMap()
	if not activeMap then
		return false
	end

	local teamName = chooseTeam(options)
	local team = teamName and options.getTeam(teamName) or nil
	local spawns = teamName and options.getTeamSpawns(teamName, activeMap) or {}
	if not (teamName and team and #spawns > 0) then
		warn("[RoundService] Late join skipped; missing team or spawn:", tostring(teamName))
		return false
	end

	options.cancelScheduledRespawn(player)
	options.cancelScheduledCharacterDestroy(player)
	options.disconnectLobbyCharacterConnection(player)

	options.roundPlayers[player] = true
	options.alivePlayers[player] = true
	options.playerTeams[player] = teamName
	player.Neutral = false
	player.Team = team
	player:SetAttribute(options.attrs.roundId, options.roundId)
	player:SetAttribute(options.attrs.roundTeam, teamName)
	player:SetAttribute(options.attrs.roundAlive, true)
	player:SetAttribute(options.attrs.roundRespawnEndsAt, 0)
	if options.attrs.roundSpawnProtectionEndsAt then
		player:SetAttribute(options.attrs.roundSpawnProtectionEndsAt, 0)
	end
	options.bindCharacter(player)

	if not options.hasUsableCharacter(player) then
		if
			not options.safeLoadCharacter(player, "LateJoinRound")
			or not options.waitForUsableCharacter(player, options.characterReadyTimeoutSeconds)
		then
			warn("[RoundService] Late join did not produce a usable character:", player.Name)
			rollbackPlayer(options)
			return false
		end
	end

	if options.currentStateChanged() or player.Parent ~= options.playersService then
		rollbackPlayer(options)
		return false
	end
	if not options.moveRoundCharacterToTeamSpawn(player) then
		rollbackPlayer(options)
		return false
	end

	options.syncAliveCounts()
	options.syncPlayerAFKMarker(player)
	return true
end

return table.freeze(RoundLateJoinRuntime)
