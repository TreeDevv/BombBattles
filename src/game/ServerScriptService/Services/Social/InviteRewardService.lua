local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local InviteRewardConfig = require(ReplicatedStorage.Shared.Config.InviteRewardConfig)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local BombSkinService = require(script.Parent.BombSkinService)
local DataService = require(script.Parent.DataService)

local STATE_KEY = Schema.InviteRewards and Schema.InviteRewards.key or "inviteRewards"
local TIME_PLAYED_KEY = Schema.TimePlayed and Schema.TimePlayed.key or "timePlayed"

type InviteRewardState = {
	hasJoined: boolean,
	referredInviteProcessed: boolean,
	chickenClaimed: boolean,
	claimedAtUnix: number,
	processedReferredUserIds: { [string]: boolean },
}

local InviteRewardService = {}

local requestRemote: RemoteFunction? = nil
local stateRemote: RemoteEvent? = nil
local openRemote: RemoteEvent? = nil
local zone = nil
local ZonePlus = nil
local lastInteractionAt: { [Player]: number } = {}
local grantLocksByUserId: { [number]: boolean } = {}
local zonePartAddedConnection: RBXScriptConnection? = nil
local warnedMissingZone = false
local warnedZonePlusFailed = false

local function nowUnix(): number
	return math.floor(Workspace:GetServerTimeNow())
end

local function roundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue == math.huge or numberValue == -math.huge then
		return 0
	end
	return math.max(0, math.floor(numberValue + 0.5))
end

local function normalizeProcessed(value: any): { [string]: boolean }
	local processed = {}
	if typeof(value) ~= "table" then
		return processed
	end

	for key, child in pairs(value) do
		local userId = nil
		if typeof(key) == "string" and child == true then
			userId = key
		elseif typeof(child) == "number" or typeof(child) == "string" then
			userId = tostring(roundNonNegative(child))
		end
		if userId and userId ~= "0" then
			processed[userId] = true
		end
	end

	return processed
end

local function normalizeState(value: any): InviteRewardState
	local state = if typeof(value) == "table" then value else {}
	return {
		hasJoined = state.hasJoined == true,
		referredInviteProcessed = state.referredInviteProcessed == true,
		chickenClaimed = state.chickenClaimed == true,
		claimedAtUnix = roundNonNegative(state.claimedAtUnix),
		processedReferredUserIds = normalizeProcessed(state.processedReferredUserIds),
	}
end

local function getState(player: Player): InviteRewardState
	return normalizeState(DataService:Get(player, STATE_KEY))
end

local function updateState(player: Player, mutator: (InviteRewardState) -> ())
	DataService:Set(player, STATE_KEY, function(currentValue)
		local state = normalizeState(currentValue)
		mutator(state)
		return state
	end)
end

local function buildPublicState(player: Player)
	local state = getState(player)
	return {
		chickenClaimed = state.chickenClaimed,
		claimedAtUnix = state.claimedAtUnix,
		rewardSkinId = InviteRewardConfig.RewardSkinId,
	}
end

local function fireState(player: Player)
	local remote = stateRemote
	if remote and player.Parent == Players then
		remote:FireClient(player, buildPublicState(player))
	end
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, InviteRewardConfig.RemotesFolderName)
end

local function ensureRemotes()
	local folder = ensureRemotesFolder()
	openRemote = RemoteUtil.EnsureRemoteEvent(folder, InviteRewardConfig.OpenRemoteName)
	stateRemote = RemoteUtil.EnsureRemoteEvent(folder, InviteRewardConfig.StateRemoteName)
	requestRemote = RemoteUtil.EnsureRemoteFunction(folder, InviteRewardConfig.RequestRemoteName)
end

local function handleRequest(player: Player, request: any)
	if typeof(request) ~= "table" then
		return {
			ok = false,
			code = "BadRequest",
			state = buildPublicState(player),
		}
	end

	if request.action == InviteRewardConfig.Actions.GetState then
		return {
			ok = true,
			code = "State",
			state = buildPublicState(player),
		}
	end

	return {
		ok = false,
		code = "UnknownAction",
		state = buildPublicState(player),
	}
end

local function shouldRateLimitInteraction(player: Player): boolean
	local now = os.clock()
	local cooldown = math.max(0.25, tonumber(InviteRewardConfig.InteractionCooldownSeconds) or 3)
	local last = lastInteractionAt[player]
	if last and now - last < cooldown then
		return true
	end
	lastInteractionAt[player] = now
	return false
end

local function openForPlayer(player: Player)
	if shouldRateLimitInteraction(player) then
		return
	end

	fireState(player)
	local remote = openRemote
	if remote and player.Parent == Players then
		remote:FireClient(player)
	end
end

local function findByPath(root: Instance, pathParts: { string }): Instance?
	local current: Instance? = root
	for _, childName in ipairs(pathParts) do
		current = current and current:FindFirstChild(childName) or nil
		if not current then
			return nil
		end
	end
	return current
end

local function pathToString(pathParts: { string }): string
	return table.concat(pathParts, ".")
end

local function getZonePart(): BasePart?
	for _, pathParts in ipairs(InviteRewardConfig.ZonePaths) do
		local instance = findByPath(Workspace, pathParts)
		if instance and instance:IsA("BasePart") then
			return instance
		end
	end
	return nil
end

local function getZonePlus()
	if ZonePlus then
		return ZonePlus
	end

	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local module = packages and packages:FindFirstChild("ZonePlus")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end

	local ok, result = pcall(require, module)
	if not ok then
		if not warnedZonePlusFailed then
			warn("[InviteRewardService] ZonePlus failed to load: " .. tostring(result))
			warnedZonePlusFailed = true
		end
		return nil
	end

	ZonePlus = result
	return ZonePlus
end

local function startZone(part: BasePart)
	if zone then
		return
	end

	local zonePlus = getZonePlus()
	if not zonePlus then
		return
	end

	local ok, result = pcall(function()
		return zonePlus.new(part)
	end)
	if not ok then
		if not warnedZonePlusFailed then
			warn("[InviteRewardService] ZonePlus failed to start: " .. tostring(result))
			warnedZonePlusFailed = true
		end
		return
	end

	zone = result
	zone.playerEntered:Connect(function(player: Player)
		task.spawn(openForPlayer, player)
	end)

	task.defer(function()
		if not zone then
			return
		end
		for _, player in ipairs(zone:getPlayers()) do
			task.spawn(openForPlayer, player)
		end
	end)
end

local function startZoneWhenAvailable()
	local part = getZonePart()
	if part then
		startZone(part)
		return true
	end

	return false
end

local function watchForZonePart()
	if zonePartAddedConnection then
		return
	end

	zonePartAddedConnection = Workspace.DescendantAdded:Connect(function(descendant)
		if zone or not descendant:IsA("BasePart") then
			return
		end

		task.defer(startZoneWhenAvailable)
	end)
end

local function decodeLaunchData(rawLaunchData: any): any?
	if typeof(rawLaunchData) ~= "string" or rawLaunchData == "" then
		return nil
	end

	local ok, result = pcall(function()
		return HttpService:JSONDecode(rawLaunchData)
	end)
	return if ok and typeof(result) == "table" then result else nil
end

local function getJoinData(player: Player): any
	local ok, result = pcall(function()
		return player:GetJoinData()
	end)
	return if ok and typeof(result) == "table" then result else {}
end

local function markJoined(player: Player)
	updateState(player, function(state)
		state.hasJoined = true
	end)
end

local function markReferredProcessed(player: Player)
	updateState(player, function(state)
		state.referredInviteProcessed = true
	end)
end

local function markClaimedState(player: Player, referredUserId: number)
	updateState(player, function(state)
		state.chickenClaimed = true
		if state.claimedAtUnix <= 0 then
			state.claimedAtUnix = nowUnix()
		end
		if referredUserId > 0 then
			state.processedReferredUserIds[tostring(referredUserId)] = true
		end
	end)
end

local function markProcessedWithoutClaim(player: Player, referredUserId: number)
	updateState(player, function(state)
		if referredUserId > 0 then
			state.processedReferredUserIds[tostring(referredUserId)] = true
		end
	end)
end

local function grantChickenToInviter(inviter: Player, referredUserId: number, source: string): boolean
	if grantLocksByUserId[inviter.UserId] then
		return false
	end

	grantLocksByUserId[inviter.UserId] = true
	local granted = false
	local ok, err = pcall(function()
		local state = getState(inviter)
		local referredKey = tostring(roundNonNegative(referredUserId))
		if state.processedReferredUserIds[referredKey] == true then
			return
		end

		if state.chickenClaimed then
			markProcessedWithoutClaim(inviter, referredUserId)
			return
		end

		local ownedSkins = BombSkinService:GetOwnedSkins(inviter)
		if ownedSkins[InviteRewardConfig.RewardSkinId] == true then
			markClaimedState(inviter, referredUserId)
			Notify.Send(inviter, InviteRewardConfig.RewardAlreadyOwnedText, { color = "Green" })
			granted = true
			return
		end

		local grantOk, grantResult = BombSkinService:GrantSkin(inviter, InviteRewardConfig.RewardSkinId, source)
		if not grantOk then
			warn(("[InviteRewardService] Failed to grant Chicken to %s: %s"):format(inviter.Name, tostring(grantResult)))
			return
		end

		markClaimedState(inviter, referredUserId)
		Notify.Send(inviter, InviteRewardConfig.RewardGrantedText, { color = "Green" })
		granted = true
	end)
	grantLocksByUserId[inviter.UserId] = nil

	if not ok then
		warn(("[InviteRewardService] Grant failed for %s: %s"):format(inviter.Name, tostring(err)))
	end

	fireState(inviter)
	return granted
end

local function handleGlobalUpdate(player: Player, _profile: any, data: any)
	if typeof(data) ~= "table" or data.updateType ~= InviteRewardConfig.GlobalUpdateType then
		return
	end

	local payload = data.data
	if typeof(payload) ~= "table" then
		return
	end

	local referredUserId = roundNonNegative(payload.referredUserId)
	if referredUserId <= 0 then
		return
	end

	grantChickenToInviter(player, referredUserId, InviteRewardConfig.RewardSource .. ":GlobalUpdate")
end

local function processJoinReferral(player: Player)
	local state = getState(player)
	local savedTimePlayed = roundNonNegative(DataService:Get(player, TIME_PLAYED_KEY))
	local firstProfileJoin = state.hasJoined ~= true and savedTimePlayed <= 0
	if not firstProfileJoin then
		markJoined(player)
		return
	end

	local joinData = getJoinData(player)
	local inviterUserId = roundNonNegative(joinData.ReferredByPlayerId)
	if inviterUserId <= 0 or inviterUserId == player.UserId then
		markJoined(player)
		return
	end

	if state.referredInviteProcessed then
		markJoined(player)
		return
	end

	local launchData = decodeLaunchData(joinData.LaunchData)
	local source = InviteRewardConfig.RewardSource
	if typeof(launchData) == "table" and launchData.source == InviteRewardConfig.LaunchDataSource then
		source = InviteRewardConfig.RewardSource .. ":InviteMenu"
	end

	markReferredProcessed(player)
	markJoined(player)

	local inviter = Players:GetPlayerByUserId(inviterUserId)
	if inviter then
		grantChickenToInviter(inviter, player.UserId, source)
		return
	end

	DataService:SendGlobalUpdate(player, inviterUserId, InviteRewardConfig.GlobalUpdateType, {
		referredUserId = player.UserId,
		referredUsername = player.Name,
		source = source,
	})
end

function InviteRewardService:OnStart()
	ensureRemotes()
	if requestRemote then
		requestRemote.OnServerInvoke = handleRequest
	end

	DataService.GlobalUpdateProcessed:Connect(handleGlobalUpdate)

	if not startZoneWhenAvailable() then
		watchForZonePart()
		if not warnedMissingZone then
			local paths = {}
			for _, pathParts in ipairs(InviteRewardConfig.ZonePaths) do
				table.insert(paths, "Workspace." .. pathToString(pathParts))
			end
			warn("[InviteRewardService] Waiting for invite reward zone at " .. table.concat(paths, " or "))
			warnedMissingZone = true
		end
	end
end

function InviteRewardService:OnPlayerAdded(player: Player)
	task.spawn(function()
		processJoinReferral(player)
		fireState(player)
	end)
end

function InviteRewardService:OnPlayerRemoving(player: Player)
	lastInteractionAt[player] = nil
	grantLocksByUserId[player.UserId] = nil
end

return InviteRewardService
