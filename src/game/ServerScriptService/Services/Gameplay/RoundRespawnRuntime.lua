local Players = game:GetService("Players")

local RoundRespawnRuntime = {}

function RoundRespawnRuntime.EliminatePlayer(options): boolean
	local player: Player = options.player
	if not options.alivePlayers[player] then
		options.debugDeathFlow("eliminatePlayer ignored; player not alive", player.Name)
		return false
	end

	options.debugDeathFlow("Eliminating player", player.Name, "team", tostring(options.playerTeams[player]), "roundId", options.roundId)
	options.cancelScheduledRespawn(player)
	options.alivePlayers[player] = nil
	player:SetAttribute(options.roundAliveAttribute, false)
	player:SetAttribute(options.roundRespawnEndsAtAttribute, 0)
	options.syncAliveCounts()
	options.destroyPlayerCharacter(player)
	return true
end

function RoundRespawnRuntime.ReconcilePlayersWithoutRespawns(options)
	for player in pairs(options.roundPlayers) do
		if
			options.alivePlayers[player] == true
			and player:GetAttribute(options.roundAliveAttribute) == false
			and not options.teamHasRespawns(options.playerTeams[player])
		then
			options.debugDeathFlow(
				"Eliminating pending respawn after core loss",
				player.Name,
				"team",
				tostring(options.playerTeams[player])
			)
			options.eliminatePlayer(player)
		end
	end
end

function RoundRespawnRuntime.ScheduleRoundRespawn(options)
	local player: Player = options.player
	options.debugDeathFlow("Scheduling round respawn", player.Name, "delay", options.respawnSeconds, "roundId", options.roundId)
	options.clearRecentDamageFor(player)
	player:SetAttribute(options.roundAliveAttribute, false)
	player:SetAttribute(options.roundRespawnEndsAtAttribute, workspace:GetServerTimeNow() + options.respawnSeconds)
	options.destroyPlayerCharacterAfter(player, options.deathBodyRetainSeconds)

	local token = options.bumpRespawnToken(player)
	task.delay(options.respawnSeconds, function()
		if options.getRespawnToken(player) ~= token then
			options.debugDeathFlow("Round respawn skipped; stale token", player.Name, token, options.getRespawnToken(player))
			return
		end
		if player.Parent ~= Players then
			options.debugDeathFlow("Round respawn skipped; player left", player.Name)
			return
		end
		if not options.isRespawnStillValid(player) then
			options.debugDeathFlow(
				"Round respawn skipped; state changed",
				player.Name,
				"state",
				options.getCurrentState(),
				"roundPlayer",
				options.isRoundPlayer(player),
				"alive",
				options.isAlive(player)
			)
			return
		end
		if not options.teamHasRespawns(options.getTeamName(player)) then
			options.debugDeathFlow("Round respawn skipped; team respawns unavailable", player.Name, "team", tostring(options.getTeamName(player)))
			options.eliminatePlayer(player)
			return
		end
		if player:GetAttribute(options.roundAliveAttribute) ~= false then
			options.debugDeathFlow(
				"Round respawn skipped; RoundAlive attr changed before respawn",
				player.Name,
				player:GetAttribute(options.roundAliveAttribute)
			)
			return
		end

		options.debugDeathFlow("Loading round respawn character", player.Name)
		options.setPendingRoundRespawn(player, token)
		options.cancelScheduledCharacterDestroy(player)
		options.safeLoadCharacter(player, "RoundRespawn")
		options.verifyRoundRespawn(player, token, 1)
	end)
end

function RoundRespawnRuntime.FinalizeRoundRespawnIfReady(options): boolean
	local player: Player = options.player
	local token: number = options.token
	if options.getPendingRoundRespawn(player) ~= token then
		return false
	end
	if options.getRespawnToken(player) ~= token then
		options.debugDeathFlow("Round respawn finalize skipped; stale token", player.Name, token, options.getRespawnToken(player))
		return false
	end
	if not options.hasUsableCharacter(player) then
		return false
	end
	if not options.isRespawnStillValid(player) then
		options.debugDeathFlow("Round respawn finalize skipped; state changed", player.Name, options.context)
		return false
	end
	if not options.teamHasRespawns(options.getTeamName(player)) then
		options.debugDeathFlow("Round respawn finalize skipped; team respawns unavailable", player.Name, tostring(options.getTeamName(player)))
		return false
	end
	if not options.moveRoundCharacterToTeamSpawn(player) then
		options.debugDeathFlow("Round respawn finalize skipped; missing spawn", player.Name, tostring(options.getTeamName(player)))
		return false
	end

	options.clearPendingRoundRespawn(player)
	player:SetAttribute(options.roundAliveAttribute, true)
	player:SetAttribute(options.roundRespawnEndsAtAttribute, 0)
	options.debugDeathFlow("Round respawn finalized", player.Name, options.context)
	return true
end

function RoundRespawnRuntime.ShouldRetryRoundRespawn(options): boolean
	local player: Player = options.player
	local token: number = options.token
	if options.getRespawnToken(player) ~= token then
		options.debugDeathFlow("Round respawn verify skipped; stale token", player.Name, token, options.getRespawnToken(player))
		return false
	end
	if player.Parent ~= Players then
		options.debugDeathFlow("Round respawn verify skipped; player left", player.Name)
		return false
	end
	if not options.isRespawnStillValid(player) then
		options.debugDeathFlow(
			"Round respawn verify skipped; state changed",
			player.Name,
			"state",
			options.getCurrentState(),
			"roundPlayer",
			options.isRoundPlayer(player),
			"alive",
			options.isAlive(player)
		)
		return false
	end
	if not options.teamHasRespawns(options.getTeamName(player)) then
		options.debugDeathFlow("Round respawn verify skipped; team respawns unavailable", player.Name, "team", tostring(options.getTeamName(player)))
		return false
	end
	if options.getPendingRoundRespawn(player) ~= token and player:GetAttribute(options.roundAliveAttribute) ~= true then
		options.debugDeathFlow("Round respawn verify skipped; no pending respawn", player.Name, player:GetAttribute(options.roundAliveAttribute))
		return false
	end

	return true
end

function RoundRespawnRuntime.VerifyRoundRespawn(options)
	local player: Player = options.player
	local token: number = options.token
	local attempt: number = options.attempt
	task.delay(options.verifyDelaySeconds, function()
		if not RoundRespawnRuntime.ShouldRetryRoundRespawn(options) then
			return
		end

		local finalizeOptions = table.clone(options)
		finalizeOptions.context = "VerifyAttempt" .. tostring(attempt)
		if RoundRespawnRuntime.FinalizeRoundRespawnIfReady(finalizeOptions) then
			return
		end
		if options.hasUsableCharacter(player) then
			if options.getPendingRoundRespawn(player) ~= token then
				options.debugDeathFlow("Round respawn verified", player.Name, "attempt", attempt)
				return
			end
			options.debugDeathFlow("Round respawn has character but is still pending finalization", player.Name, "attempt", attempt)
		end
		if attempt >= options.maxAttempts then
			warn(("[RoundService] Round respawn did not produce a usable character for %s after %d attempts"):format(
				player.Name,
				attempt
			))
			if options.getPendingRoundRespawn(player) == token and options.isAlive(player) and options.eliminatePlayer then
				options.eliminatePlayer(player)
			end
			return
		end

		local nextAttempt = attempt + 1
		options.debugDeathFlow("Retrying round respawn LoadCharacter", player.Name, "attempt", nextAttempt)
		options.safeLoadCharacter(player, "RoundRespawnRetry" .. tostring(nextAttempt))

		local retryOptions = table.clone(options)
		retryOptions.attempt = nextAttempt
		RoundRespawnRuntime.VerifyRoundRespawn(retryOptions)
	end)
end

return table.freeze(RoundRespawnRuntime)
