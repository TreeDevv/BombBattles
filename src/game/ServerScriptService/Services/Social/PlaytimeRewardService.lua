local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlaytimeRewardConfig = require(ReplicatedStorage.Shared.Config.PlaytimeRewardConfig)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local CrateRollService = require(script.Parent.CrateRollService)
local DataService = require(script.Parent.DataService)

local CASH_KEY = Schema.Cash and Schema.Cash.key or "cash"

type RuntimeState = {
	joinedAt: number,
	claimedTiers: { [string]: boolean },
}

local PlaytimeRewardService = {}

local requestRemote: RemoteFunction? = nil
local stateRemote: RemoteEvent? = nil
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

local function getRuntime(player: Player): RuntimeState
	local runtime = runtimeByPlayer[player]
	if not runtime then
		runtime = {
			joinedAt = os.clock(),
			claimedTiers = {},
		}
		runtimeByPlayer[player] = runtime
	end
	return runtime
end

local function getSessionSeconds(player: Player): number
	local runtime = getRuntime(player)
	return math.max(0, math.floor(os.clock() - runtime.joinedAt))
end

local function copyClaimedTiers(runtime: RuntimeState): { [string]: boolean }
	local claimed = {}
	for tierId, isClaimed in pairs(runtime.claimedTiers) do
		if isClaimed == true then
			claimed[tierId] = true
		end
	end
	return claimed
end

local function buildStatePayload(player: Player)
	local runtime = getRuntime(player)
	return {
		sessionSeconds = getSessionSeconds(player),
		claimedTiers = copyClaimedTiers(runtime),
		tiers = PlaytimeRewardConfig.Tiers,
		maxTargetSeconds = PlaytimeRewardConfig.GetMaxTargetSeconds(),
	}
end

local function fireState(player: Player)
	local remote = stateRemote
	if remote and player.Parent == Players then
		remote:FireClient(player, buildStatePayload(player))
	end
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, PlaytimeRewardConfig.RemotesFolderName)
end

local function ensureRemotes()
	local remotesFolder = ensureRemotesFolder()
	stateRemote = RemoteUtil.EnsureRemoteEvent(remotesFolder, PlaytimeRewardConfig.StateRemoteName)
	requestRemote = RemoteUtil.EnsureRemoteFunction(remotesFolder, PlaytimeRewardConfig.RequestRemoteName)
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

local function awardTier(player: Player, tier): (boolean, string)
	local reward = tier.reward
	if typeof(reward) ~= "table" then
		return false, "Reward is unavailable."
	end

	if reward.type == PlaytimeRewardConfig.RewardTypes.Cash then
		addCash(player, reward.amount)
		return true, "Claimed"
	elseif reward.type == PlaytimeRewardConfig.RewardTypes.Crate then
		local ok, message = CrateRollService:GrantRewardRoll(
			player,
			reward.crateId,
			("%s:%s"):format(PlaytimeRewardConfig.RewardSource, tier.id)
		)
		if not ok then
			return false, tostring(message or "Crate reward failed.")
		end
		return true, "Claimed"
	end

	return false, "Unknown reward type."
end

local function claimTier(player: Player, tierId: any)
	local tier = PlaytimeRewardConfig.GetTier(tierId)
	if not tier then
		return {
			ok = false,
			code = "UnknownTier",
			message = "Unknown playtime reward.",
			state = buildStatePayload(player),
		}
	end

	if claimLocks[player] then
		return {
			ok = false,
			code = "Busy",
			message = "Please wait.",
			state = buildStatePayload(player),
		}
	end

	claimLocks[player] = true
	local ok, response = pcall(function()
		local runtime = getRuntime(player)
		if runtime.claimedTiers[tier.id] == true then
			return {
				ok = false,
				code = "AlreadyClaimed",
				message = "Reward already claimed.",
				state = buildStatePayload(player),
			}
		end

		if getSessionSeconds(player) < tier.targetSeconds then
			return {
				ok = false,
				code = "NotReady",
				message = "Keep playing to unlock this reward.",
				state = buildStatePayload(player),
			}
		end

		local awarded, awardMessage = awardTier(player, tier)
		if not awarded then
			warn(("[PlaytimeRewardService] Failed to grant %s to %s: %s"):format(
				tier.id,
				player.Name,
				awardMessage
			))
			return {
				ok = false,
				code = "GrantFailed",
				message = "Playtime reward is unavailable right now.",
				state = buildStatePayload(player),
			}
		end

		runtime.claimedTiers[tier.id] = true
		Notify.Send(player, "Playtime reward claimed: " .. tostring(tier.displayName), { color = "Green" })
		return {
			ok = true,
			code = "Claimed",
			message = "Playtime reward claimed.",
			state = buildStatePayload(player),
		}
	end)
	claimLocks[player] = nil

	if not ok then
		warn(("[PlaytimeRewardService] Claim failed for %s: %s"):format(player.Name, tostring(response)))
		return {
			ok = false,
			code = "Error",
			message = "Playtime reward is unavailable right now.",
			state = buildStatePayload(player),
		}
	end

	fireState(player)
	return response
end

local function handleInvoke(player: Player, request: any)
	if typeof(request) ~= "table" then
		return {
			ok = false,
			code = "BadRequest",
			message = "Bad request.",
			state = buildStatePayload(player),
		}
	end

	if request.action == PlaytimeRewardConfig.Actions.GetState then
		return {
			ok = true,
			code = "State",
			state = buildStatePayload(player),
		}
	elseif request.action == PlaytimeRewardConfig.Actions.Claim then
		return claimTier(player, request.tierId)
	end

	return {
		ok = false,
		code = "UnknownAction",
		message = "Unknown playtime reward action.",
		state = buildStatePayload(player),
	}
end

local function startTickLoop()
	if tickLoopStarted then
		return
	end
	tickLoopStarted = true

	task.spawn(function()
		while true do
			for _, player in ipairs(Players:GetPlayers()) do
				if player.Parent == Players then
					fireState(player)
				end
			end
			task.wait(PlaytimeRewardConfig.ProgressTickSeconds)
		end
	end)
end

function PlaytimeRewardService:OnStart()
	ensureRemotes()
	if requestRemote then
		requestRemote.OnServerInvoke = handleInvoke
	end
	startTickLoop()
end

function PlaytimeRewardService:OnPlayerAdded(player: Player)
	runtimeByPlayer[player] = {
		joinedAt = os.clock(),
		claimedTiers = {},
	}
	fireState(player)
end

function PlaytimeRewardService:OnPlayerRemoving(player: Player)
	runtimeByPlayer[player] = nil
	claimLocks[player] = nil
end

return PlaytimeRewardService
