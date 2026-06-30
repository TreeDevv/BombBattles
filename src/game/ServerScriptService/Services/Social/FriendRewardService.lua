local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FriendRewardConfig = require(ReplicatedStorage.Shared.Config.FriendRewardConfig)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local CrateRollService = require(script.Parent.CrateRollService)
local DataService = require(script.Parent.DataService)

local STATE_KEY = Schema.FriendRewards and Schema.FriendRewards.key or "friendRewards"

type FriendInfo = {
	userId: number,
	username: string,
	displayName: string,
	isOnline: boolean,
}

type FriendRewardState = {
	totalFriendSeconds: number,
	claimedTiers: { [string]: boolean },
}

type RuntimeState = {
	friends: { FriendInfo },
	friendIds: { [number]: boolean },
	friendsLoaded: boolean,
	nextFriendLoadAt: number,
	unflushedSeconds: number,
	remainderSeconds: number,
	lastTickAt: number,
	lastFlushAt: number,
	lastEligibleCount: number,
}

local FriendRewardService = {}

local requestRemote: RemoteFunction? = nil
local stateRemote: RemoteEvent? = nil
local openRemote: RemoteEvent? = nil
local runtimeByPlayer: { [Player]: RuntimeState } = {}
local claimLocks: { [Player]: boolean } = {}
local tickLoopStarted = false

local function roundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue == math.huge or numberValue == -math.huge then
		return 0
	end
	return math.max(0, math.floor(numberValue + 0.5))
end

local function normalizeState(value: any): FriendRewardState
	local state = if typeof(value) == "table" then value else {}
	local claimedTiers = {}
	if typeof(state.claimedTiers) == "table" then
		for tierId, claimed in pairs(state.claimedTiers) do
			if typeof(tierId) == "string" and claimed == true then
				claimedTiers[tierId] = true
			end
		end
	end

	return {
		totalFriendSeconds = roundNonNegative(state.totalFriendSeconds),
		claimedTiers = claimedTiers,
	}
end

local function getState(player: Player): FriendRewardState
	return normalizeState(DataService:Get(player, STATE_KEY))
end

local function updateState(player: Player, mutator: (FriendRewardState) -> ())
	DataService:Set(player, STATE_KEY, function(currentValue)
		local state = normalizeState(currentValue)
		mutator(state)
		return state
	end)
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, FriendRewardConfig.RemotesFolderName)
end

local function ensureRemotes()
	local remotesFolder = ensureRemotesFolder()
	openRemote = RemoteUtil.EnsureRemoteEvent(remotesFolder, FriendRewardConfig.OpenRemoteName)
	stateRemote = RemoteUtil.EnsureRemoteEvent(remotesFolder, FriendRewardConfig.StateRemoteName)
	requestRemote = RemoteUtil.EnsureRemoteFunction(remotesFolder, FriendRewardConfig.RequestRemoteName)
end

local function createRuntimeState(): RuntimeState
	local now = os.clock()
	return {
		friends = {},
		friendIds = {},
		friendsLoaded = false,
		nextFriendLoadAt = 0,
		unflushedSeconds = 0,
		remainderSeconds = 0,
		lastTickAt = now,
		lastFlushAt = now,
		lastEligibleCount = 0,
	}
end

local function getRuntime(player: Player): RuntimeState
	local runtime = runtimeByPlayer[player]
	if not runtime then
		runtime = createRuntimeState()
		runtimeByPlayer[player] = runtime
	end
	return runtime
end

local function applyFriendsPayload(player: Player, rawFriends: any)
	local runtime = getRuntime(player)
	local friends = {}
	local friendIds = {}
	if typeof(rawFriends) == "table" then
		for _, rawFriend in ipairs(rawFriends) do
			if typeof(rawFriend) == "table" then
				local userId = roundNonNegative(rawFriend.userId)
				if userId > 0 and not friendIds[userId] and userId ~= player.UserId then
					friendIds[userId] = true
					local username = if typeof(rawFriend.username) == "string" and rawFriend.username ~= ""
						then rawFriend.username
						else "User" .. userId
					local displayName = if typeof(rawFriend.displayName) == "string" and rawFriend.displayName ~= ""
						then rawFriend.displayName
						else username
					table.insert(friends, {
						userId = userId,
						username = username,
						displayName = displayName,
						isOnline = rawFriend.isOnline == true,
					})
				end
			end
		end
	end

	table.sort(friends, function(left, right)
		return string.lower(left.username) < string.lower(right.username)
	end)

	runtime.friends = friends
	runtime.friendIds = friendIds
	runtime.friendsLoaded = true
end

local function isEligibleFriend(owner: Player, candidate: Player): boolean
	if owner == candidate then
		return false
	end

	local runtime = runtimeByPlayer[owner]
	return runtime ~= nil and runtime.friendIds[candidate.UserId] == true
end

local function countEligibleFriends(player: Player): number
	local count = 0
	for _, candidate in ipairs(Players:GetPlayers()) do
		if isEligibleFriend(player, candidate) then
			count += 1
		end
	end
	return count
end

local function buildFriendsPayload(player: Player, runtime: RuntimeState)
	local friends = {}
	for _, friend in ipairs(runtime.friends) do
		table.insert(friends, {
			userId = friend.userId,
			username = friend.username,
			displayName = friend.displayName,
			eligible = runtime.friendIds[friend.userId] == true and Players:GetPlayerByUserId(friend.userId) ~= nil,
			isOnline = friend.isOnline == true,
		})
	end
	return friends
end

local function getTotalSeconds(player: Player, runtime: RuntimeState): number
	local state = getState(player)
	return state.totalFriendSeconds + math.floor(runtime.unflushedSeconds)
end

local function buildStatePayload(player: Player, includeFriends: boolean?)
	local runtime = getRuntime(player)
	local state = getState(player)
	local totalSeconds = state.totalFriendSeconds + math.floor(runtime.unflushedSeconds)
	local eligibleCount = countEligibleFriends(player)
	runtime.lastEligibleCount = eligibleCount

	local payload = {
		totalFriendSeconds = totalSeconds,
		eligibleFriendCount = eligibleCount,
		friendsLoaded = runtime.friendsLoaded,
		claimedTiers = state.claimedTiers,
		tiers = FriendRewardConfig.Tiers,
		maxTargetSeconds = FriendRewardConfig.GetMaxTargetSeconds(),
	}
	if includeFriends == true then
		payload.friends = buildFriendsPayload(player, runtime)
	end
	return payload
end

local function fireState(player: Player, includeFriends: boolean?)
	local remote = stateRemote
	if remote and player.Parent == Players then
		remote:FireClient(player, buildStatePayload(player, includeFriends))
	end
end

local function flushProgress(player: Player, force: boolean?)
	local runtime = runtimeByPlayer[player]
	if not runtime then
		return
	end

	local wholeSeconds = math.floor(runtime.unflushedSeconds)
	local now = os.clock()
	if wholeSeconds <= 0 then
		if force then
			runtime.lastFlushAt = now
		end
		return
	end

	if not force and now - runtime.lastFlushAt < FriendRewardConfig.ProgressFlushSeconds then
		return
	end

	runtime.unflushedSeconds -= wholeSeconds
	runtime.lastFlushAt = now
	updateState(player, function(state)
		state.totalFriendSeconds += wholeSeconds
	end)
end

local function awardTier(player: Player, tierId: string): (boolean, string)
	local ok, message = CrateRollService:GrantCrateTokens(
		player,
		FriendRewardConfig.RewardCrateId,
		FriendRewardConfig.RewardRollCount,
		("%s:%s"):format(FriendRewardConfig.RewardSource, tierId)
	)
	if not ok then
		return false, tostring(message or "Reward failed")
	end
	return true, "Claimed"
end

local function claimTier(player: Player, tierId: any)
	local tier = FriendRewardConfig.GetTier(tierId)
	if not tier then
		return {
			ok = false,
			code = "UnknownTier",
			message = "Unknown reward tier.",
			state = buildStatePayload(player, true),
		}
	end

	if claimLocks[player] then
		return {
			ok = false,
			code = "Busy",
			message = "Please wait.",
			state = buildStatePayload(player, true),
		}
	end

	claimLocks[player] = true
	local ok, response = pcall(function()
		flushProgress(player, true)
		local state = getState(player)
		if state.claimedTiers[tier.id] == true then
			return {
				ok = false,
				code = "AlreadyClaimed",
				message = "Reward already claimed.",
				state = buildStatePayload(player, true),
			}
		end

		local runtime = getRuntime(player)
		if getTotalSeconds(player, runtime) < tier.targetSeconds then
			return {
				ok = false,
				code = "NotReady",
				message = "Keep playing with friends to unlock this reward.",
				state = buildStatePayload(player, true),
			}
		end

		local awarded, awardMessage = awardTier(player, tier.id)
		if not awarded then
			warn(("[FriendRewardService] Failed to grant %s to %s: %s"):format(tier.id, player.Name, awardMessage))
			return {
				ok = false,
				code = "GrantFailed",
				message = "Friend reward is unavailable right now.",
				state = buildStatePayload(player, true),
			}
		end

		updateState(player, function(currentState)
			currentState.claimedTiers[tier.id] = true
		end)

		Notify.Send(player, "Friend reward claimed: 3 Basic crates!", { color = "Green" })
		return {
			ok = true,
			code = "Claimed",
			message = "Friend reward claimed.",
			state = buildStatePayload(player, true),
		}
	end)
	claimLocks[player] = nil

	if not ok then
		warn(("[FriendRewardService] Claim failed for %s: %s"):format(player.Name, tostring(response)))
		return {
			ok = false,
			code = "Error",
			message = "Friend reward is unavailable right now.",
			state = buildStatePayload(player, true),
		}
	end

	fireState(player, true)
	return response
end

local function handleInvoke(player: Player, request: any)
	if typeof(request) ~= "table" then
		return {
			ok = false,
			code = "BadRequest",
			message = "Bad request.",
			state = buildStatePayload(player, true),
		}
	end

	if request.action == FriendRewardConfig.Actions.GetState then
		return {
			ok = true,
			code = "State",
			state = buildStatePayload(player, true),
		}
	elseif request.action == FriendRewardConfig.Actions.UpdateFriends then
		applyFriendsPayload(player, request.friends)
		return {
			ok = true,
			code = "FriendsUpdated",
			state = buildStatePayload(player, true),
		}
	elseif request.action == FriendRewardConfig.Actions.Claim then
		return claimTier(player, request.tierId)
	end

	return {
		ok = false,
		code = "UnknownAction",
		message = "Unknown action.",
		state = buildStatePayload(player, true),
	}
end

local function tickPlayer(player: Player, now: number)
	local runtime = getRuntime(player)

	local elapsed = math.max(0, now - runtime.lastTickAt)
	runtime.lastTickAt = now

	local previousEligibleCount = runtime.lastEligibleCount
	local eligibleCount = countEligibleFriends(player)
	runtime.lastEligibleCount = eligibleCount
	if eligibleCount > 0 and elapsed > 0 then
		runtime.remainderSeconds += elapsed * eligibleCount
		local wholeSeconds = math.floor(runtime.remainderSeconds)
		if wholeSeconds > 0 then
			runtime.remainderSeconds -= wholeSeconds
			runtime.unflushedSeconds += wholeSeconds
		end
	end

	flushProgress(player, false)
	fireState(player, eligibleCount ~= previousEligibleCount)
end

local function startTickLoop()
	if tickLoopStarted then
		return
	end
	tickLoopStarted = true

	task.spawn(function()
		while true do
			local now = os.clock()
			for _, player in ipairs(Players:GetPlayers()) do
				if player.Parent == Players then
					tickPlayer(player, now)
				end
			end
			task.wait(FriendRewardConfig.ProgressTickSeconds)
		end
	end)
end

function FriendRewardService.OpenForPlayer(player: Player)
	if not openRemote then
		ensureRemotes()
	end

	local remote = openRemote
	if remote and player.Parent == Players then
		fireState(player, true)
		remote:FireClient(player)
	end
end

function FriendRewardService:OnStart()
	ensureRemotes()
	if requestRemote then
		requestRemote.OnServerInvoke = handleInvoke
	end
	startTickLoop()
end

function FriendRewardService:OnPlayerAdded(player: Player)
	local runtime = getRuntime(player)
	runtime.lastTickAt = os.clock()
	fireState(player, true)
end

function FriendRewardService:OnPlayerRemoving(player: Player)
	flushProgress(player, true)
	runtimeByPlayer[player] = nil
	claimLocks[player] = nil
end

return FriendRewardService
