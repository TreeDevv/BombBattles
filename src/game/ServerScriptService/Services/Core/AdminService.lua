local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local BombProjectileService = require(ServerScriptService.Services.BombProjectileService)
local BombService = require(ServerScriptService.Services.BombService)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)
local DataService = require(ServerScriptService.Services.DataService)
local ReplayService = require(ServerScriptService.Services.ReplayService)
local RoundService = require(ServerScriptService.Services.RoundService)

local REMOTES_FOLDER_NAME = "Remotes"
local EXPLOSION_DEMO_FORWARD_DISTANCE = 45
local EXPLOSION_DEMO_HEIGHT = 45
local EXPLOSION_DEMO_SPACING = 8
local EXPLOSION_DEMO_STAGGER_SECONDS = 0.18
local EXPLOSION_DEMO_FUSE_SECONDS = 1.35

type AdminResult = {
	ok: boolean,
	message: string,
	data: any?,
}

local AdminService = {}

local requestRemote: RemoteFunction? = nil
local potgCutsceneRemote: RemoteEvent? = nil
local lastRequestAtByUserId: { [number]: number } = {}
local explosionDemoSerial = 0

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

local function ensurePOTGCutsceneRemote(): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(AdminConfig.POTGCutsceneRemoteName)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = AdminConfig.POTGCutsceneRemoteName
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

local function isDebugAllowedUserId(userId: number): boolean
	for _, allowedUserId in ipairs(AdminConfig.ReplayDebugAllowedUserIds or {}) do
		if allowedUserId == userId then
			return true
		end
	end

	return isAllowedUserId(userId)
end

local function isGameCreator(player: Player): boolean
	return game.CreatorType == Enum.CreatorType.User and game.CreatorId == player.UserId
end

local function isAuthorized(player: Player): boolean
	if AdminConfig.EnabledInStudio and RunService:IsStudio() then
		return true
	end

	return isAllowedUserId(player.UserId)
end

local function isReplayDebugAuthorized(player: Player): (boolean, string?)
	if AdminConfig.ReplayDebugEnabled ~= true then
		return false, "Replay debug tools are disabled"
	end
	if RunService:IsStudio() then
		return true, nil
	end
	if isGameCreator(player) or isDebugAllowedUserId(player.UserId) then
		return true, nil
	end

	return false, "Replay debug tools are restricted"
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
		replayDebug = {
			enabled = AdminConfig.ReplayDebugEnabled == true,
		},
	}
end

local function dispatchReplayDebugCommand(adminPlayer: Player, command: string): AdminResult
	if command == "replay.testSelfKillReplay" then
		if not RunService:IsStudio() then
			return result(false, "Self kill replay test is Studio-only", getStatePayload())
		end

		local ok, debugMessage = ReplayService.DebugSendRecentKillReplay(adminPlayer, 7)
		return result(ok, debugMessage or "Studio self kill replay failed", getStatePayload())
	end

	local authorized, message = isReplayDebugAuthorized(adminPlayer)
	if not authorized then
		return result(false, message or "Replay debug is unavailable", getStatePayload())
	end

	if command == "replay.printCounts" then
		local ok, debugMessage = ReplayService.DebugPrintBufferCounts(adminPlayer)
		return result(ok, debugMessage or "Replay buffer debug failed", getStatePayload())
	elseif command == "replay.printPOTG" then
		local ok, debugMessage = ReplayService.DebugPrintPOTGCandidates(adminPlayer)
		return result(ok, debugMessage or "POTG debug failed", getStatePayload())
	elseif command == "replay.testKillReplay" then
		local ok, debugMessage = ReplayService.DebugSendRecentKillReplay(adminPlayer, 7)
		return result(ok, debugMessage or "Debug kill replay failed", getStatePayload())
	elseif command == "replay.testPOTG" then
		local ok, debugMessage = ReplayService.DebugPlayBestPOTG(adminPlayer)
		return result(ok, debugMessage or "Debug POTG replay failed", getStatePayload())
	end

	return result(false, "Unknown replay debug command", getStatePayload())
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

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

local function getHorizontalUnit(direction: Vector3, fallback: Vector3): Vector3
	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	if horizontal.Magnitude > 0.05 then
		return horizontal.Unit
	end
	return fallback
end

local function runExplosionDemo(adminPlayer: Player): (boolean, string?)
	if not BombProjectileService:IsEnabled() then
		return false, "Bomb projectile service is disabled"
	end

	local rootPart = getCharacterRoot(adminPlayer)
	if not rootPart then
		return false, "Admin character root is not available"
	end

	local skinIds = BombSkinConfig.GetCatalogIds()
	if #skinIds == 0 then
		return false, "No bomb skins are configured"
	end

	local rootCFrame = rootPart.CFrame
	local forward = getHorizontalUnit(rootCFrame.LookVector, Vector3.zAxis)
	local right = getHorizontalUnit(rootCFrame.RightVector, Vector3.xAxis)
	local center = rootPart.Position
		+ forward * EXPLOSION_DEMO_FORWARD_DISTANCE
		+ Vector3.yAxis * EXPLOSION_DEMO_HEIGHT
	local firstOffset = -((#skinIds - 1) * EXPLOSION_DEMO_SPACING * 0.5)

	explosionDemoSerial += 1
	local serial = explosionDemoSerial
	for index, skinId in ipairs(skinIds) do
		local lineOffset = firstOffset + ((index - 1) * EXPLOSION_DEMO_SPACING)
		local origin = center + right * lineOffset
		task.delay((index - 1) * EXPLOSION_DEMO_STAGGER_SECONDS, function()
			if not adminPlayer.Parent then
				return
			end

			BombProjectileService:Launch({
				owner = adminPlayer,
				projectileId = ("AdminExplosionDemo_%d_%d_%02d_%s"):format(adminPlayer.UserId, serial, index, skinId),
				bombType = BombProjectileConfig.BombType.Normal,
				skinId = skinId,
				origin = origin,
				aimDirection = Vector3.new(0, -1, 0),
				remainingFuse = EXPLOSION_DEMO_FUSE_SECONDS,
				modifier = {
					physics = {
						launchSpeed = 0,
						upwardVelocity = 0,
					},
				},
			})
		end)
	end

	return true, ("Started explosion demo for %d bomb skins"):format(#skinIds)
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
	elseif command == "round.testKillFeed" then
		local ok, message = RoundService:AdminTestKillFeed()
		return result(ok, message or "", getStatePayload())
	elseif string.sub(command, 1, 7) == "replay." then
		return dispatchReplayDebugCommand(adminPlayer, command)
	elseif command == "cutscene.playPOTG" then
		local remote = potgCutsceneRemote or ensurePOTGCutsceneRemote()
		potgCutsceneRemote = remote
		remote:FireClient(adminPlayer, {
			requestedAt = workspace:GetServerTimeNow(),
		})
		return result(true, "Playing POTG cutscene", getStatePayload())
	elseif command == "bomb.demoAllExplosions" then
		local ok, message = runExplosionDemo(adminPlayer)
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
	elseif command == "player.setBombSkin" then
		local skinId = if typeof(payload) == "table" then payload.skinId else nil
		local ok, message = BombSkinService:AdminGrantAndEquipSkin(targetPlayer, skinId)
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
	potgCutsceneRemote = ensurePOTGCutsceneRemote()
	requestRemote.OnServerInvoke = onInvoke
end

function AdminService:OnPlayerRemoving(player: Player)
	lastRequestAtByUserId[player.UserId] = nil
end

return AdminService
