local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local GroupRewardConfig = require(ReplicatedStorage.Shared.Config.GroupRewardConfig)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local CrateRollService = require(script.Parent.CrateRollService)
local DataService = require(script.Parent.DataService)
local FriendRewardService = require(script.Parent.FriendRewardService)
local LikeService = require(ServerScriptService.Services.LikeService)

local STATE_KEY = Schema.GroupReward and Schema.GroupReward.key or "groupReward"
local CASH_KEY = Schema.Cash and Schema.Cash.key or "cash"

type RewardState = {
	hasBaseline: boolean,
	baselineLikes: number,
	baselineAtUnix: number,
	rewardClaimed: boolean,
	claimedAtUnix: number,
	joinedViaPrompt: boolean,
}

type PromptRequest = {
	requestId: string,
	groupId: number,
	startedAt: number,
}

local GroupRewardService = {}

local promptRemote: RemoteEvent? = nil
local promptResultRemote: RemoteEvent? = nil
local stateRemote: RemoteEvent? = nil
local stateRequestRemote: RemoteFunction? = nil
local zone = nil
local zonePart: BasePart? = nil
local ZonePlus = nil
local warnedMissingZone = false
local warnedZonePlusFailed = false
local warnedMissingGroupId = false
local promptRequests: { [Player]: PromptRequest } = {}
local interactionLocks: { [Player]: boolean } = {}
local lastInteractionAt: { [Player]: number } = {}

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

local function normalizeState(value: any): RewardState
	local state = if typeof(value) == "table" then value else {}
	return {
		hasBaseline = state.hasBaseline == true,
		baselineLikes = roundNonNegative(state.baselineLikes),
		baselineAtUnix = roundNonNegative(state.baselineAtUnix),
		rewardClaimed = state.rewardClaimed == true,
		claimedAtUnix = roundNonNegative(state.claimedAtUnix),
		joinedViaPrompt = state.joinedViaPrompt == true,
	}
end

local function getState(player: Player): RewardState
	return normalizeState(DataService:Get(player, STATE_KEY))
end

local function updateState(player: Player, mutator: (RewardState) -> ())
	DataService:Set(player, STATE_KEY, function(currentValue)
		local state = normalizeState(currentValue)
		mutator(state)
		return state
	end)
end

local function addCash(player: Player, amount: number)
	amount = roundNonNegative(amount)
	if amount <= 0 then
		return
	end

	DataService:Set(player, CASH_KEY, function(currentValue)
		return roundNonNegative(currentValue) + amount
	end)
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
	for _, pathParts in ipairs(GroupRewardConfig.ZonePaths) do
		local instance = findByPath(Workspace, pathParts)
		if instance and instance:IsA("BasePart") then
			return instance
		end
	end
	return nil
end

local function getGroupId(): number
	local configuredGroupId = tonumber(GroupRewardConfig.GroupId) or 0
	if configuredGroupId > 0 then
		return math.floor(configuredGroupId)
	end

	if game.CreatorType == Enum.CreatorType.Group then
		return math.max(0, math.floor(tonumber(game.CreatorId) or 0))
	end

	if not warnedMissingGroupId then
		warn("[GroupRewardService] Missing group id; set GroupRewardConfig.GroupId or run the game under a group-owned experience.")
		warnedMissingGroupId = true
	end
	return 0
end

local function fetchLikes(): (number?, string?)
	local likes, err = LikeService.FetchLikes()
	if likes == nil then
		return nil, err
	end
	return roundNonNegative(likes), nil
end

local function isPlayerInGroup(player: Player, groupId: number): (boolean, string?)
	local okAsync, asyncResult = pcall(function()
		return player:IsInGroupAsync(groupId)
	end)
	if okAsync and typeof(asyncResult) == "boolean" then
		return asyncResult, nil
	end

	local ok, result = pcall(function()
		return player:IsInGroup(groupId)
	end)
	if ok and typeof(result) == "boolean" then
		return result, nil
	end

	return false, tostring(if okAsync then result else asyncResult)
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
			warn("[GroupRewardService] ZonePlus failed to load: " .. tostring(result))
			warnedZonePlusFailed = true
		end
		return nil
	end

	ZonePlus = result
	return ZonePlus
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, GroupRewardConfig.RemotesFolderName)
end

local function ensureRemotes()
	local remotesFolder = ensureRemotesFolder()
	promptRemote = RemoteUtil.EnsureRemoteEvent(remotesFolder, GroupRewardConfig.PromptRemoteName)
	promptResultRemote = RemoteUtil.EnsureRemoteEvent(remotesFolder, GroupRewardConfig.PromptResultRemoteName)
	stateRemote = RemoteUtil.EnsureRemoteEvent(remotesFolder, GroupRewardConfig.StateRemoteName)
	stateRequestRemote = RemoteUtil.EnsureRemoteFunction(remotesFolder, GroupRewardConfig.StateRequestRemoteName)
end

local function buildStatePayload(player: Player)
	local state = getState(player)
	return {
		hasBaseline = state.hasBaseline == true,
		rewardClaimed = state.rewardClaimed == true,
		joinedViaPrompt = state.joinedViaPrompt == true,
	}
end

local function fireState(player: Player)
	if not stateRemote then
		ensureRemotes()
	end

	local remote = stateRemote
	if remote and player.Parent == Players then
		remote:FireClient(player, buildStatePayload(player))
	end
end

local function shouldRateLimit(player: Player): boolean
	local now = os.clock()
	local cooldown = math.max(0.25, tonumber(GroupRewardConfig.InteractionCooldownSeconds) or 3)
	local last = lastInteractionAt[player]
	if last and now - last < cooldown then
		return true
	end

	lastInteractionAt[player] = now
	return false
end

local function startJoinPrompt(player: Player, groupId: number)
	local remote = promptRemote
	if not remote or player.Parent ~= Players then
		return
	end

	local timeout = math.max(5, tonumber(GroupRewardConfig.PromptTimeoutSeconds) or 45)
	local existing = promptRequests[player]
	if existing and os.clock() - existing.startedAt < timeout then
		return
	end

	local requestId = HttpService:GenerateGUID(false)
	promptRequests[player] = {
		requestId = requestId,
		groupId = groupId,
		startedAt = os.clock(),
	}

	remote:FireClient(player, {
		requestId = requestId,
		groupId = groupId,
	})
end

local function rememberBaseline(player: Player, likes: number)
	updateState(player, function(state)
		if state.hasBaseline then
			return
		end
		state.hasBaseline = true
		state.baselineLikes = roundNonNegative(likes)
		state.baselineAtUnix = nowUnix()
	end)
	fireState(player)
end

local function rememberPromptJoin(player: Player)
	updateState(player, function(state)
		state.joinedViaPrompt = true
	end)
	fireState(player)
end

local function grantReward(player: Player): boolean
	local ok, message = CrateRollService:GrantRewardRoll(
		player,
		GroupRewardConfig.RewardCrateId,
		GroupRewardConfig.RewardSource
	)
	if not ok then
		warn(("[GroupRewardService] Failed to grant crate reward to %s: %s"):format(player.Name, tostring(message)))
		Notify.Send(player, "Group reward is unavailable right now. Try again soon.", { color = "Red" })
		return false
	end

	addCash(player, GroupRewardConfig.RewardCash)
	updateState(player, function(state)
		state.rewardClaimed = true
		state.claimedAtUnix = nowUnix()
	end)
	fireState(player)
	Notify.Send(player, GroupRewardConfig.RewardClaimedText, { color = "Green" })
	FriendRewardService.OpenForPlayer(player)
	return true
end

local function evaluateReward(player: Player, currentLikes: number, groupId: number, knownGroupMember: boolean?)
	if player.Parent ~= Players then
		return
	end

	local state = getState(player)
	if not state.hasBaseline then
		local inGroup = knownGroupMember
		if inGroup == nil then
			local membership, membershipErr = isPlayerInGroup(player, groupId)
			if membershipErr then
				warn(("[GroupRewardService] Failed group check for %s: %s"):format(player.Name, membershipErr))
			end
			inGroup = membership
		end

		Notify.Send(player, GroupRewardConfig.ReminderText, { color = "Yellow" })
		if not inGroup then
			startJoinPrompt(player, groupId)
			return
		end

		rememberBaseline(player, currentLikes)
		return
	end

	if state.rewardClaimed then
		fireState(player)
		FriendRewardService.OpenForPlayer(player)
		return
	end

	if currentLikes <= state.baselineLikes then
		Notify.Send(player, GroupRewardConfig.ReminderText, { color = "Yellow" })
		if knownGroupMember == false then
			startJoinPrompt(player, groupId)
		end
		return
	end

	local inGroup = knownGroupMember
	if inGroup == nil then
		local membership, membershipErr = isPlayerInGroup(player, groupId)
		if membershipErr then
			warn(("[GroupRewardService] Failed group check for %s: %s"):format(player.Name, membershipErr))
		end
		inGroup = membership
	end

	if not inGroup then
		Notify.Send(player, GroupRewardConfig.ReminderText, { color = "Yellow" })
		startJoinPrompt(player, groupId)
		return
	end

	grantReward(player)
end

local function handleInteraction(player: Player)
	if not (player and player:IsA("Player") and player.Parent == Players) then
		return
	end
	if interactionLocks[player] or shouldRateLimit(player) then
		return
	end

	local state = getState(player)
	if state.rewardClaimed then
		fireState(player)
		FriendRewardService.OpenForPlayer(player)
		return
	end

	local groupId = getGroupId()
	if groupId <= 0 then
		Notify.Send(player, "Group rewards are not configured yet.", { color = "Red" })
		return
	end

	interactionLocks[player] = true
	local ok, err = pcall(function()
		local inGroup, membershipErr = isPlayerInGroup(player, groupId)
		if membershipErr then
			warn(("[GroupRewardService] Failed group check for %s: %s"):format(player.Name, membershipErr))
		end

		if not state.hasBaseline and not inGroup then
			Notify.Send(player, GroupRewardConfig.ReminderText, { color = "Yellow" })
			startJoinPrompt(player, groupId)
			return
		end

		local likes, likeErr = fetchLikes()
		if likes == nil then
			warn(("[GroupRewardService] Failed to fetch likes for %s: %s"):format(player.Name, tostring(likeErr)))
			Notify.Send(player, GroupRewardConfig.ReminderText, { color = "Yellow" })
			if not inGroup then
				startJoinPrompt(player, groupId)
			end
			return
		end

		evaluateReward(player, likes, groupId, inGroup)
	end)
	interactionLocks[player] = nil

	if not ok then
		warn(("[GroupRewardService] Interaction failed for %s: %s"):format(player.Name, tostring(err)))
	end
end

local function handlePromptResult(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local requestId = payload.requestId
	if typeof(requestId) ~= "string" or requestId == "" then
		return
	end

	local pending = promptRequests[player]
	if not pending or pending.requestId ~= requestId then
		return
	end
	promptRequests[player] = nil

	if payload.status == "Joined" or payload.status == "AlreadyMember" then
		rememberPromptJoin(player)
	end

	local inGroup, membershipErr = isPlayerInGroup(player, pending.groupId)
	if membershipErr then
		warn(("[GroupRewardService] Failed post-prompt group check for %s: %s"):format(player.Name, membershipErr))
	end

	if not inGroup then
		Notify.Send(player, GroupRewardConfig.ReminderText, { color = "Yellow" })
		return
	end

	local likes, likeErr = fetchLikes()
	if likes == nil then
		warn(("[GroupRewardService] Failed to fetch post-prompt likes for %s: %s"):format(player.Name, tostring(likeErr)))
		Notify.Send(player, GroupRewardConfig.ReminderText, { color = "Yellow" })
		return
	end

	evaluateReward(player, likes, pending.groupId, true)
end

local function startZone(part: BasePart)
	zonePart = part
	local zonePlus = getZonePlus()
	if not zonePlus then
		return
	end

	local ok, result = pcall(function()
		return zonePlus.new(part)
	end)
	if not ok then
		if not warnedZonePlusFailed then
			warn("[GroupRewardService] ZonePlus failed to start: " .. tostring(result))
			warnedZonePlusFailed = true
		end
		return
	end

	zone = result
	zone.playerEntered:Connect(function(player: Player)
		task.spawn(handleInteraction, player)
	end)

	task.defer(function()
		if not zone then
			return
		end
		for _, player in ipairs(zone:getPlayers()) do
			task.spawn(handleInteraction, player)
		end
	end)
end

function GroupRewardService:OnStart()
	ensureRemotes()

	if promptResultRemote then
		promptResultRemote.OnServerEvent:Connect(handlePromptResult)
	end
	if stateRequestRemote then
		stateRequestRemote.OnServerInvoke = buildStatePayload
	end

	local part = getZonePart()
	if not part then
		if not warnedMissingZone then
			local paths = {}
			for _, pathParts in ipairs(GroupRewardConfig.ZonePaths) do
				table.insert(paths, "Workspace." .. pathToString(pathParts))
			end
			warn("[GroupRewardService] Missing group reward zone at " .. table.concat(paths, " or "))
			warnedMissingZone = true
		end
		return
	end

	startZone(part)
end

function GroupRewardService:OnPlayerAdded(player: Player)
	fireState(player)
end

function GroupRewardService:OnPlayerRemoving(player: Player)
	promptRequests[player] = nil
	interactionLocks[player] = nil
	lastInteractionAt[player] = nil
end

return GroupRewardService
