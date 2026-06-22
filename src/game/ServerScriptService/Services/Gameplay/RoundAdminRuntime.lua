local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)

local RoundAdminRuntime = {}

function RoundAdminRuntime.ForceStart(options): (boolean, string?)
	local selectedMapId = options.mapId
	if typeof(selectedMapId) ~= "string" or selectedMapId == "" then
		selectedMapId = options.getFirstConfiguredMapId()
	end
	if not selectedMapId then
		return false, "No configured map is available"
	end
	if not options.getConfiguredMap(selectedMapId) then
		return false, "Unknown map: " .. selectedMapId
	end
	if not options.getMapTemplate(selectedMapId) then
		return false, "Map template is missing: " .. selectedMapId
	end

	if options.currentState == RoundStates.WaitingForPlayers then
		options.clearAllPlayerRoundState()
	end
	options.setPendingForceStart(selectedMapId, options.currentState ~= RoundStates.WaitingForPlayers)
	return true, "Queued admin round start for " .. selectedMapId
end

function RoundAdminRuntime.ResetRound(options): (boolean, string?)
	options.setPendingReset()
	options.clearAllPlayerRoundState()
	return true, "Queued round reset"
end

function RoundAdminRuntime.EndRound(options): (boolean, string?)
	local winnerTeam = options.winnerTeam
	if options.currentState ~= RoundStates.Active then
		return false, "A round must be active to force a winner"
	end
	if winnerTeam ~= RoundConfig.Teams.Red.name and winnerTeam ~= RoundConfig.Teams.Blue.name and winnerTeam ~= "Draw" then
		return false, "Invalid winner"
	end

	options.setPendingWinner(winnerTeam)
	return true, "Queued " .. winnerTeam .. " win"
end

function RoundAdminRuntime.DamageTeamCore(options): (boolean, string?)
	local teamName = options.teamName
	if typeof(teamName) ~= "string" or not options.teamCoreInstances[teamName] then
		return false, "Unknown team"
	end
	if typeof(options.damage) ~= "number" or options.damage <= 0 then
		return false, "Damage must be positive"
	end

	for _, core in ipairs(options.teamCoreInstances[teamName]) do
		if options.isCoreAlive(core) and options.damageCore(core, options.damage) then
			return true, "Damaged " .. teamName .. " core"
		end
	end

	return false, "No live " .. teamName .. " core is available"
end

function RoundAdminRuntime.DestroyTeamCore(options): (boolean, string?)
	local teamName = options.teamName
	if typeof(teamName) ~= "string" or not options.teamCoreInstances[teamName] then
		return false, "Unknown team"
	end

	for _, core in ipairs(options.teamCoreInstances[teamName]) do
		if options.isCoreAlive(core) and options.markCoreDestroyed(core) then
			return true, "Destroyed " .. teamName .. " core"
		end
	end

	return false, "No live " .. teamName .. " core is available"
end

function RoundAdminRuntime.TestKillFeed(options): (boolean, string?)
	local remote = options.getKillFeedRemote()
	local roundId = options.roundId

	remote:FireAllClients({
		roundId = roundId,
		killerUserId = 0,
		killerName = "BlueTester",
		killerDisplayName = "Blue Tester",
		killerTeam = RoundConfig.Teams.Blue.name,
		victimUserId = 0,
		victimName = "RedTester",
		victimDisplayName = "Red Tester",
		victimTeam = RoundConfig.Teams.Red.name,
	})

	task.delay(0.15, function()
		if remote.Parent then
			remote:FireAllClients({
				roundId = roundId,
				killerUserId = 0,
				killerName = "RedTester",
				killerDisplayName = "Red Tester",
				killerTeam = RoundConfig.Teams.Red.name,
				victimUserId = 0,
				victimName = "BlueTester",
				victimDisplayName = "Blue Tester",
				victimTeam = RoundConfig.Teams.Blue.name,
			})
		end
	end)

	return true, "Sent kill feed test"
end

function RoundAdminRuntime.RespawnPlayer(options): (boolean, string?)
	local player: Player = options.player
	if not player or player.Parent ~= Players then
		return false, "Target player is not in this server"
	end

	options.cancelScheduledRespawn(player)
	if not options.isActiveRoundPlayer(player) then
		if options.respawnPlayerToLobby(player, "AdminRespawnLobby", true, nil, true) then
			return true, "Respawned " .. player.Name .. " in lobby"
		end
		return false, "Could not respawn " .. player.Name .. " in lobby"
	end

	options.setAlive(player, true)
	options.clearRecentDamageFor(player)
	player:SetAttribute(options.roundAliveAttribute, false)
	player:SetAttribute(options.roundRespawnEndsAtAttribute, workspace:GetServerTimeNow())
	options.bindCharacter(player)
	options.syncAliveCounts()
	task.defer(function()
		if player.Parent == Players then
			local token = options.bumpRespawnToken(player)
			options.setPendingRoundRespawn(player, token)
			options.cancelScheduledCharacterDestroy(player)
			options.safeLoadCharacter(player, "AdminRespawnRound")
			options.verifyRoundRespawn(player, token, 1)
		end
	end)
	return true, "Respawned " .. player.Name .. " in round"
end

function RoundAdminRuntime.RespawnAll(options): (boolean, string?)
	for _, player in ipairs(Players:GetPlayers()) do
		options.respawnPlayer(player)
	end

	return true, "Respawned all players"
end

function RoundAdminRuntime.TeleportPlayer(options): (boolean, string?)
	local player: Player = options.player
	if not player or player.Parent ~= Players then
		return false, "Target player is not in this server"
	end

	if options.destination == "Lobby" then
		if options.respawnPlayerToLobby(player, "AdminTeleportLobby", false, nil, true) then
			return true, "Teleported " .. player.Name .. " to lobby"
		end
		return false, "Could not teleport " .. player.Name .. " to lobby"
	end

	if not player.Character and options.safeLoadCharacter then
		options.safeLoadCharacter(player, "AdminTeleport" .. options.destination)
	end

	if options.destination == "Admin" then
		local sourceCharacter = options.sourcePlayer and options.sourcePlayer.Character
		local sourceRoot = sourceCharacter and sourceCharacter:FindFirstChild("HumanoidRootPart")
		if sourceRoot and sourceRoot:IsA("BasePart") and player.Character then
			player.Character:PivotTo(sourceRoot.CFrame + sourceRoot.CFrame.LookVector * 4)
			return true, "Teleported " .. player.Name .. " to admin"
		end
		return false, "Admin character is not available"
	end

	if options.destination == "MapSpawn" then
		local activeMap = options.getActiveMap()
		if not activeMap then
			return false, "No active map is available"
		end

		local teamName = options.getPlayerTeam(player)
		local spawns = if teamName
			then options.getTeamSpawns(teamName, activeMap)
			else options.getTaggedSpawnParts(RoundConfig.Tags.TeamSpawn, activeMap)
		if #spawns == 0 then
			return false, "No map spawn is available"
		end
		options.moveCharacterToSpawn(player, spawns[options.nextSpawnIndex(#spawns)])
		return true, "Teleported " .. player.Name .. " to map"
	end

	return false, "Unknown teleport destination"
end

return table.freeze(RoundAdminRuntime)
