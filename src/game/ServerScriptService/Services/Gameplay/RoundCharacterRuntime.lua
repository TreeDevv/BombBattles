local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local RoundCharacterRuntime = {}

function RoundCharacterRuntime.HasUsableCharacter(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	return humanoid ~= nil and humanoid.Health > 0 and rootPart ~= nil and rootPart:IsA("BasePart")
end

function RoundCharacterRuntime.WaitForUsableCharacter(player: Player, timeoutSeconds: number): boolean
	local deadline = os.clock() + math.max(timeoutSeconds, 0)
	while os.clock() <= deadline do
		if player.Parent ~= Players then
			return false
		end
		if RoundCharacterRuntime.HasUsableCharacter(player) then
			return true
		end
		task.wait(0.05)
	end
	return false
end

function RoundCharacterRuntime.SafeLoadCharacter(player: Player, context: string, debugLog: ((string, ...any) -> ())?): boolean
	if player.Parent ~= Players then
		if debugLog then
			debugLog("LoadCharacter skipped; player left", player.Name, context)
		end
		return false
	end

	local ok, err = pcall(function()
		player:LoadCharacter()
	end)
	if not ok then
		warn(("[RoundCharacterRuntime] LoadCharacter failed for %s during %s: %s"):format(player.Name, context, tostring(err)))
		return false
	end

	return true
end

function RoundCharacterRuntime.BindLobbyCharacter(options)
	local player: Player = options.player
	options.connections:Reset(player)
	local maxLoadAttempts = math.max(tonumber(options.maxLoadAttempts) or 1, 1)
	local verifyDelaySeconds = math.max(tonumber(options.verifyDelaySeconds) or 0.5, 0)

	local function shouldContinueLobbyRespawn(token: number): boolean
		return options.getRespawnToken(player) == token and player.Parent == Players and not options.isRoundPlayer(player)
	end

	local function finalizeLobbyRespawn(token: number): boolean
		if not shouldContinueLobbyRespawn(token) then
			return true
		end

		return options.respawnPlayerToLobby(player, "LobbyRespawnFinalize", false, token)
	end

	local function verifyLobbyRespawn(token: number, attempt: number)
		task.delay(verifyDelaySeconds, function()
			if not shouldContinueLobbyRespawn(token) then
				return
			end
			if finalizeLobbyRespawn(token) then
				return
			end
			if attempt >= maxLoadAttempts then
				warn(("[RoundCharacterRuntime] Lobby respawn did not produce a usable character for %s after %d attempts"):format(
					player.Name,
					attempt
				))
				return
			end

			local nextAttempt = attempt + 1
			if options.respawnPlayerToLobby(player, "LobbyRespawnRetry" .. tostring(nextAttempt), true, token) then
				return
			end
			verifyLobbyRespawn(token, nextAttempt)
		end)
	end

	local function bindNonRoundHumanoid(character: Model)
		if character:GetAttribute(options.lobbyDeathBoundAttribute) == true then
			return
		end
		character:SetAttribute(options.lobbyDeathBoundAttribute, true)
		options.prepareDeathRagdoll(character)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end

		options.connections:Add(player, humanoid.Died:Connect(function()
			options.applyDeathRagdoll(character, "NonRoundDeath")
			if options.isRoundPlayer(player) then
				return
			end

			local token = options.bumpRespawnToken(player)
			task.delay(options.respawnSeconds, function()
				if options.getRespawnToken(player) ~= token then
					return
				end
				if player.Parent ~= Players then
					return
				end
				if options.isRoundPlayer(player) then
					return
				end

				if not options.respawnPlayerToLobby(player, "LobbyRespawn", true, token) then
					verifyLobbyRespawn(token, 1)
				end
			end)
		end))
	end

	local function onCharacterAdded(character: Model)
		task.defer(function()
			if options.isRoundPlayer(player) then
				return
			end

			if not options.respawnPlayerToLobby(player, "LobbyCharacterAdded", false, nil) then
				return
			end
			local currentCharacter = player.Character
			if currentCharacter then
				bindNonRoundHumanoid(currentCharacter)
			end
		end)
	end

	options.connections:Add(player, player.CharacterAdded:Connect(onCharacterAdded))
	if player.Character then
		onCharacterAdded(player.Character)
	end
end

function RoundCharacterRuntime.BindRoundCharacter(options)
	local player: Player = options.player
	options.connections:Reset(player)

	local function bindHumanoid(character: Model)
		if character:GetAttribute(options.roundDeathBoundAttribute) == true then
			return
		end
		character:SetAttribute(options.roundDeathBoundAttribute, true)
		options.prepareDeathRagdoll(character)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end

		local deathHandled = false
		local function handleBoundHumanoidDeath(profilerName: string, countName: string, reason: string, debugLabel: string)
			if deathHandled then
				return
			end

			deathHandled = true
			local deathToken = RuntimeProfiler.Begin(profilerName)
			RuntimeProfiler.Count(countName)
			options.applyDeathRagdoll(character, reason)
			if options.isRoundActive() then
				options.debugDeathFlow(debugLabel, player.Name, "roundId", options.getRoundId(), "health", humanoid.Health)
				options.handlePlayerDeath(player)
			end
			RuntimeProfiler.End(profilerName, deathToken)
		end

		options.connections:Add(player, humanoid.Died:Connect(function()
			handleBoundHumanoidDeath(
				"Server/Round/Death/HumanoidDied",
				"Server/Round/Death/HumanoidDiedEvents",
				"RoundDeath",
				"Humanoid.Died"
			)
		end))

		options.connections:Add(player, humanoid.HealthChanged:Connect(function(nextHealth: number)
			if nextHealth > 0 then
				return
			end

			task.defer(function()
				if deathHandled then
					return
				end
				if player.Character ~= character or not humanoid.Parent then
					return
				end
				if humanoid.Health > 0 or not options.isRoundActive() then
					return
				end

				handleBoundHumanoidDeath(
					"Server/Round/Death/HumanoidHealthZeroFallback",
					"Server/Round/Death/HumanoidHealthZeroFallbackEvents",
					"RoundHealthZeroFallback",
					"Humanoid.HealthChangedZero"
				)
			end)
		end))
	end

	if player.Character then
		bindHumanoid(player.Character)
	end

	options.connections:Add(player, player.CharacterAdded:Connect(function(character)
		task.defer(function()
			if options.isRoundPlayer(player) and not options.isAlive(player) then
				options.movePlayerToLobby(player)
				options.syncAFKMarker(player)
				return
			end

			if options.isRoundPlayer(player) and options.isAlive(player) then
				if not RoundCharacterRuntime.WaitForUsableCharacter(player, options.readyTimeoutSeconds) then
					warn("[RoundCharacterRuntime] Active round character missing humanoid/root:", player.Name)
					return
				end
				if not options.isRoundPlayer(player) or not options.isAlive(player) then
					return
				end
				if player.Character ~= character then
					return
				end
				bindHumanoid(character)
				local pendingToken = options.getPendingRoundRespawn(player)
				if pendingToken then
					options.finalizeRoundRespawnIfReady(player, pendingToken, "CharacterAdded")
				elseif options.isRoundActive() then
					options.moveRoundCharacterToTeamSpawn(player)
					options.clearRespawnEndsAt(player)
				else
					options.clearRespawnEndsAt(player)
				end
				options.syncAFKMarker(player)
			else
				options.clearPlayerRoundState(player)
				options.movePlayerToLobby(player)
				options.syncAFKMarker(player)
			end
		end)
	end))
end

return table.freeze(RoundCharacterRuntime)
