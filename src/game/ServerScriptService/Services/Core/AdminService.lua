local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local BombService = require(ServerScriptService.Services.BombService)
local DataService = require(ServerScriptService.Services.DataService)
local RoundService = require(ServerScriptService.Services.RoundService)

local REMOTES_FOLDER_NAME = "Remotes"

type AdminResult = {
	ok: boolean,
	message: string,
	data: any?,
}

local AdminService = {}

local requestRemote: RemoteFunction? = nil
local lastRequestAtByUserId: { [number]: number } = {}

local function ensureRemotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = REMOTES_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureRequestRemote(): RemoteFunction
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(AdminConfig.RequestRemoteName)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = AdminConfig.RequestRemoteName
	remote.Parent = folder
	return remote
end

local function isAllowedUserId(userId: number): boolean
	for _, allowedUserId in ipairs(AdminConfig.AllowedUserIds) do
		if allowedUserId == userId then
			return true
		end
	end

	return false
end

local function isAuthorized(player: Player): boolean
	if AdminConfig.EnabledInStudio and RunService:IsStudio() then
		return true
	end

	return isAllowedUserId(player.UserId)
end

local function result(ok: boolean, message: string, data: any?): AdminResult
	return {
		ok = ok,
		message = message,
		data = data,
	}
end

local function getPlayersPayload()
	local payload = {}
	for _, player in ipairs(Players:GetPlayers()) do
		table.insert(payload, {
			name = player.Name,
			displayName = player.DisplayName,
			userId = player.UserId,
		})
	end
	table.sort(payload, function(left, right)
		return left.name < right.name
	end)
	return payload
end

local function getMapsPayload()
	local payload = {}
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		table.insert(payload, {
			id = mapConfig.id,
			displayName = mapConfig.displayName,
		})
	end
	return payload
end

local function getStatePayload()
	return {
		players = getPlayersPayload(),
		maps = getMapsPayload(),
		round = RoundService:GetState(),
		teams = {
			RoundConfig.Teams.Red.name,
			RoundConfig.Teams.Blue.name,
		},
	}
end

local function getTargetPlayer(payload): Player?
	if typeof(payload) ~= "table" then
		return nil
	end
	local targetUserId = payload.targetUserId
	if typeof(targetUserId) ~= "number" then
		return nil
	end

	return Players:GetPlayerByUserId(math.floor(targetUserId))
end

local function setHumanoidHealth(player: Player, health: number): (boolean, string?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false, "Target humanoid is not available"
	end

	humanoid.Health = math.clamp(health, 0, humanoid.MaxHealth)
	return true, "Updated health for " .. player.Name
end

local function setMovementValue(player: Player, walkSpeed: number?, jumpPower: number?): (boolean, string?)
	if walkSpeed then
		walkSpeed = math.clamp(walkSpeed, AdminConfig.MinWalkSpeed, AdminConfig.MaxWalkSpeed)
		player:SetAttribute(AdminConfig.WalkSpeedAttribute, walkSpeed)
	end
	if jumpPower then
		jumpPower = math.clamp(jumpPower, AdminConfig.MinJumpPower, AdminConfig.MaxJumpPower)
		player:SetAttribute(AdminConfig.JumpPowerAttribute, jumpPower)
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		if walkSpeed then
			humanoid.WalkSpeed = walkSpeed
		end
		if jumpPower then
			humanoid.UseJumpPower = true
			humanoid.JumpPower = jumpPower
		end
	end

	return true, "Updated movement for " .. player.Name
end

local function dispatchCommand(adminPlayer: Player, command: string, payload): AdminResult
	if command == "round.forceStart" then
		local mapId = if typeof(payload) == "table" then payload.mapId else nil
		local ok, message = RoundService:AdminForceStart(mapId)
		return result(ok, message or "", getStatePayload())
	elseif command == "round.reset" then
		local ok, message = RoundService:AdminResetRound()
		return result(ok, message or "", getStatePayload())
	elseif command == "round.end" then
		local winnerTeam = if typeof(payload) == "table" then payload.winnerTeam else nil
		if typeof(winnerTeam) ~= "string" then
			return result(false, "Winner is required", nil)
		end
		local ok, message = RoundService:AdminEndRound(winnerTeam)
		return result(ok, message or "", getStatePayload())
	elseif command == "round.damageCore" then
		local teamName = if typeof(payload) == "table" then payload.teamName else nil
		local damage = if typeof(payload) == "table" then payload.damage else nil
		if typeof(teamName) ~= "string" then
			return result(false, "Team is required", nil)
		end
		if typeof(damage) ~= "number" then
			damage = 25
		end
		damage = math.clamp(damage, 1, AdminConfig.MaxCoreDamage)
		local ok, message = RoundService:AdminDamageTeamCore(teamName, damage)
		return result(ok, message or "", getStatePayload())
	elseif command == "round.destroyCore" then
		local teamName = if typeof(payload) == "table" then payload.teamName else nil
		if typeof(teamName) ~= "string" then
			return result(false, "Team is required", nil)
		end
		local ok, message = RoundService:AdminDestroyTeamCore(teamName)
		return result(ok, message or "", getStatePayload())
	elseif command == "round.respawnAll" then
		local ok, message = RoundService:AdminRespawnAll()
		return result(ok, message or "", getStatePayload())
	end

	local targetPlayer = getTargetPlayer(payload)
	if not targetPlayer then
		return result(false, "Target player is required", nil)
	end

	if command == "round.respawnPlayer" then
		local ok, message = RoundService:AdminRespawnPlayer(targetPlayer)
		return result(ok, message or "", getStatePayload())
	elseif command == "player.teleportToAdmin" then
		local ok, message = RoundService:AdminTeleportPlayer(targetPlayer, "Admin", adminPlayer)
		return result(ok, message or "", getStatePayload())
	elseif command == "player.teleportToLobby" then
		local ok, message = RoundService:AdminTeleportPlayer(targetPlayer, "Lobby", adminPlayer)
		return result(ok, message or "", getStatePayload())
	elseif command == "player.teleportToMapSpawn" then
		local ok, message = RoundService:AdminTeleportPlayer(targetPlayer, "MapSpawn", adminPlayer)
		return result(ok, message or "", getStatePayload())
	elseif command == "player.heal" then
		local character = targetPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return result(false, "Target humanoid is not available", nil)
		end
		local ok, message = setHumanoidHealth(targetPlayer, humanoid.MaxHealth)
		return result(ok, message or "", getStatePayload())
	elseif command == "player.kill" then
		local ok, message = setHumanoidHealth(targetPlayer, 0)
		return result(ok, message or "", getStatePayload())
	elseif command == "player.setWalkSpeed" then
		local value = if typeof(payload) == "table" then payload.value else nil
		if typeof(value) ~= "number" then
			return result(false, "Walk speed value is required", nil)
		end
		local ok, message = setMovementValue(targetPlayer, value, nil)
		return result(ok, message or "", getStatePayload())
	elseif command == "player.setJumpPower" then
		local value = if typeof(payload) == "table" then payload.value else nil
		if typeof(value) ~= "number" then
			return result(false, "Jump power value is required", nil)
		end
		local ok, message = setMovementValue(targetPlayer, nil, value)
		return result(ok, message or "", getStatePayload())
	elseif command == "player.refillBombs" then
		local ok, message = BombService:AdminRefillBombs(targetPlayer)
		return result(ok, message or "", getStatePayload())
	elseif command == "player.clearBombState" then
		local ok, message = BombService:AdminClearPlayerBombState(targetPlayer)
		return result(ok, message or "", getStatePayload())
	elseif command == "data.wipe" then
		local confirmation = if typeof(payload) == "table" then payload.confirmation else nil
		if confirmation ~= AdminConfig.DataWipeConfirmation then
			return result(false, "Data wipe requires exact confirmation", nil)
		end
		local ok, message = DataService:WipeByUserId(targetPlayer.UserId)
		return result(ok, if ok then "Wiped data for " .. targetPlayer.Name else message or "Data wipe failed", getStatePayload())
	end

	return result(false, "Unknown command", nil)
end

local function isRateLimited(player: Player): boolean
	local cooldown = AdminConfig.RequestCooldownSeconds
	if typeof(cooldown) ~= "number" or cooldown <= 0 then
		return false
	end

	local now = os.clock()
	local lastRequestAt = lastRequestAtByUserId[player.UserId]
	lastRequestAtByUserId[player.UserId] = now
	return lastRequestAt ~= nil and now - lastRequestAt < cooldown
end

local function onInvoke(player: Player, request): AdminResult
	if not isAuthorized(player) then
		warn("[AdminService] Rejected unauthorized request from", player.Name, player.UserId)
		return result(false, "Not authorized", nil)
	end
	if typeof(request) ~= "table" then
		return result(false, "Request must be a table", nil)
	end

	local action = request.action
	if action == "Bootstrap" or action == "GetState" then
		return result(true, "OK", getStatePayload())
	end

	if action ~= "Command" then
		return result(false, "Unknown admin action", nil)
	end
	if isRateLimited(player) then
		return result(false, "Too many admin requests", nil)
	end

	local command = request.command
	if typeof(command) ~= "string" then
		return result(false, "Command is required", nil)
	end

	local commandResult = dispatchCommand(player, command, request.payload)
	if commandResult.ok then
		print("[AdminService]", player.Name, player.UserId, command, commandResult.message)
	else
		warn("[AdminService]", player.Name, player.UserId, command, commandResult.message)
	end
	return commandResult
end

function AdminService:OnStart()
	requestRemote = ensureRequestRemote()
	requestRemote.OnServerInvoke = onInvoke
end

function AdminService:OnPlayerRemoving(player: Player)
	lastRequestAtByUserId[player.UserId] = nil
end

return AdminService
