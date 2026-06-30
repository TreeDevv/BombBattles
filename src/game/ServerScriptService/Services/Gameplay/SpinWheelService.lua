local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local AbilityInventoryService = require(script.Parent.AbilityInventoryService)
local BombSkinService = require(script.Parent.BombSkinService)
local CrateRollService = require(script.Parent.CrateRollService)
local DataService = require(script.Parent.DataService)
local EmoteService = require(script.Parent.EmoteService)
local FinisherService = require(script.Parent.FinisherService)
local PurchaseReceiptService = require(script.Parent.PurchaseReceiptService)

local SPIN_WHEEL_KEY = Schema.SpinWheel and Schema.SpinWheel.key or "spinWheel"
local CASH_KEY = Schema.Cash and Schema.Cash.key or "cash"

type RequestWindow = {
	startedAt: number,
	count: number,
}

local SpinWheelService = {}

local requestSpinRemote: RemoteFunction? = nil
local getStateRemote: RemoteFunction? = nil
local stateChangedRemote: RemoteEvent? = nil
local legacyRequestSpinRemote: RemoteFunction? = nil
local legacyGetStateRemote: RemoteFunction? = nil
local legacyStateChangedRemote: RemoteEvent? = nil
local grantSpinsBindable: BindableFunction? = nil
local rewardGrantedBindable: BindableEvent? = nil
local requestWindows: { [Player]: RequestWindow } = {}
local lastSpinRequests: { [Player]: number } = {}
local spinLocks: { [Player]: boolean } = {}
local rng = Random.new()

local function roundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue < 0 then
		return 0
	end
	return math.floor(numberValue + 0.5)
end

local function normalizeState(value: any, now: number): ({ spins: number, nextFreeAt: number }, boolean)
	local changed = typeof(value) ~= "table"
	local state = if typeof(value) == "table" then table.clone(value) else {}
	local spins = roundNonNegative(state.spins)
	local nextFreeAt = math.floor(tonumber(state.nextFreeAt) or 0)
	local instantSpinUntil = math.max(0, math.floor(tonumber(state.instantSpinUntil) or 0))

	if nextFreeAt <= 0 then
		nextFreeAt = now + SpinWheelConfig.FreeSpinCooldownSeconds
		changed = true
	end
	if state.spins ~= spins or state.nextFreeAt ~= nextFreeAt or state.instantSpinUntil ~= instantSpinUntil then
		changed = true
	end

	return {
		spins = spins,
		nextFreeAt = nextFreeAt,
		instantSpinUntil = instantSpinUntil,
	}, changed
end

local function hasPermanentInstantSpin(player: Player): boolean
	return PurchaseReceiptService:HasPass(player, "InstantSpin")
end

local function publicState(state, player: Player?)
	local hasTimedInstantSpin = (tonumber(state.instantSpinUntil) or 0) > os.time()
	local hasInstantSpin = hasTimedInstantSpin or (player ~= nil and hasPermanentInstantSpin(player :: Player))
	return {
		Spins = state.spins,
		NextFreeAt = state.nextFreeAt,
		InstantSpinUntil = state.instantSpinUntil,
		HasInstantSpin = hasInstantSpin,
		Now = os.time(),
		rewards = SpinWheelConfig.Rewards,
	}
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, SpinWheelConfig.RemotesFolderName)
end

local function ensureRequestSpinRemote(): RemoteFunction
	return RemoteUtil.EnsureRemoteFunction(ensureRemotesFolder(), SpinWheelConfig.RequestSpinRemoteName)
end

local function ensureGetStateRemote(): RemoteFunction
	return RemoteUtil.EnsureRemoteFunction(ensureRemotesFolder(), SpinWheelConfig.GetStateRemoteName)
end

local function ensureStateChangedRemote(): RemoteEvent
	return RemoteUtil.EnsureRemoteEvent(ensureRemotesFolder(), SpinWheelConfig.StateChangedRemoteName)
end

local function findPath(root: Instance, pathParts: { string }): Instance?
	local current: Instance? = root
	for _, name in ipairs(pathParts) do
		current = current and current:FindFirstChild(name)
		if not current then
			return nil
		end
	end
	return current
end

local function findSpinWheelModel(): Model?
	local model = findPath(workspace, SpinWheelConfig.ModelPath)
	return if model and model:IsA("Model") then model else nil
end

local function ensureFolder(parent: Instance, name: string): Folder?
	local child = parent:FindFirstChild(name)
	if child and child:IsA("Folder") then
		return child
	end
	if child then
		warn(("[SpinWheelService] %s.%s is %s, expected Folder"):format(parent:GetFullName(), name, child.ClassName))
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function ensureRemoteFunction(parent: Instance, name: string): RemoteFunction?
	local child = parent:FindFirstChild(name)
	if child and child:IsA("RemoteFunction") then
		return child
	end
	if child then
		warn(("[SpinWheelService] %s.%s is %s, expected RemoteFunction"):format(parent:GetFullName(), name, child.ClassName))
		return nil
	end
	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function ensureRemoteEvent(parent: Instance, name: string): RemoteEvent?
	local child = parent:FindFirstChild(name)
	if child and child:IsA("RemoteEvent") then
		return child
	end
	if child then
		warn(("[SpinWheelService] %s.%s is %s, expected RemoteEvent"):format(parent:GetFullName(), name, child.ClassName))
		return nil
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function ensureBindableFunction(parent: Instance, name: string): BindableFunction?
	local child = parent:FindFirstChild(name)
	if child and child:IsA("BindableFunction") then
		return child
	end
	if child then
		warn(("[SpinWheelService] %s.%s is %s, expected BindableFunction"):format(parent:GetFullName(), name, child.ClassName))
		return nil
	end
	local bindable = Instance.new("BindableFunction")
	bindable.Name = name
	bindable.Parent = parent
	return bindable
end

local function ensureBindableEvent(parent: Instance, name: string): BindableEvent?
	local child = parent:FindFirstChild(name)
	if child and child:IsA("BindableEvent") then
		return child
	end
	if child then
		warn(("[SpinWheelService] %s.%s is %s, expected BindableEvent"):format(parent:GetFullName(), name, child.ClassName))
		return nil
	end
	local bindable = Instance.new("BindableEvent")
	bindable.Name = name
	bindable.Parent = parent
	return bindable
end

local function ensureModelSurface()
	local model = findSpinWheelModel()
	if not model then
		warn("[SpinWheelService] Missing Workspace.Lobby.MonetizationArea.SpinWheel for legacy remotes")
		return
	end

	local remotes = ensureFolder(model, SpinWheelConfig.RemotesFolderName)
	if remotes then
		legacyRequestSpinRemote = ensureRemoteFunction(remotes, SpinWheelConfig.LegacyRequestSpinRemoteName)
		legacyGetStateRemote = ensureRemoteFunction(remotes, SpinWheelConfig.LegacyGetStateRemoteName)
		legacyStateChangedRemote = ensureRemoteEvent(remotes, SpinWheelConfig.LegacyStateChangedRemoteName)
	end

	grantSpinsBindable = ensureBindableFunction(model, SpinWheelConfig.GrantSpinsBindableName)
	rewardGrantedBindable = ensureBindableEvent(model, SpinWheelConfig.RewardGrantedBindableName)
end

local function getState(player: Player)
	local now = os.time()
	local state = normalizeState(DataService:Get(player, SPIN_WHEEL_KEY), now)
	return state
end

local function setState(player: Player, updater): any
	local resultState = nil
	DataService:Get(player, SPIN_WHEEL_KEY)
	DataService:Set(player, SPIN_WHEEL_KEY, function(currentValue)
		local currentState = normalizeState(currentValue, os.time())
		resultState = updater(currentState)
		return resultState or currentState
	end)
	return resultState
end

local function pushState(player: Player, state)
	local remote = stateChangedRemote or ensureStateChangedRemote()
	remote:FireClient(player, publicState(state, player))
	if legacyStateChangedRemote then
		legacyStateChangedRemote:FireClient(player, publicState(state, player))
	end
end

local function response(ok: boolean, code: string, message: string?, data: any?)
	local payload = {
		ok = ok,
		code = code,
		reason = code,
		message = message,
	}
	if typeof(data) == "table" then
		for key, value in pairs(data) do
			payload[key] = value
		end
	end
	return payload
end

local function isRateLimited(player: Player): boolean
	local now = os.clock()
	local last = lastSpinRequests[player]
	if last and now - last < 1 then
		return true
	end
	lastSpinRequests[player] = now

	local window = requestWindows[player]
	if not window or now - window.startedAt >= 1 then
		requestWindows[player] = {
			startedAt = now,
			count = 1,
		}
		return false
	end

	window.count += 1
	return window.count > SpinWheelConfig.MaxRequestsPerSecond
end

local function pickReward(): (number, any?)
	local total = SpinWheelConfig.GetTotalWeight()
	if total <= 0 then
		return 0, nil
	end

	local pick = rng:NextNumber(0, total)
	for index, reward in ipairs(SpinWheelConfig.Rewards) do
		local weight = math.max(0, tonumber(reward.weight) or 0)
		if pick <= weight then
			return index, reward
		end
		pick -= weight
	end

	return #SpinWheelConfig.Rewards, SpinWheelConfig.Rewards[#SpinWheelConfig.Rewards]
end

local function addCash(player: Player, amount: number)
	DataService:Set(player, CASH_KEY, function(currentValue)
		return roundNonNegative(currentValue) + roundNonNegative(amount)
	end)
end

local function grantTimedInstantSpin(player: Player, durationSeconds: number)
	local duration = math.max(0, math.floor(tonumber(durationSeconds) or 0))
	if duration <= 0 then
		return nil
	end

	return setState(player, function(currentState)
		local now = os.time()
		currentState.instantSpinUntil = math.max(now, tonumber(currentState.instantSpinUntil) or 0) + duration
		return currentState
	end)
end

local function grantReward(player: Player, reward): (boolean, string?, any?)
	local rewardType = reward.type
	if rewardType == SpinWheelConfig.RewardTypes.Cash then
		addCash(player, reward.amount)
		return true, nil, nil
	elseif rewardType == SpinWheelConfig.RewardTypes.Spins then
		return true, nil, nil
	elseif rewardType == SpinWheelConfig.RewardTypes.CrateToken then
		local ok, message = CrateRollService:GrantCrateTokens(
			player,
			tostring(reward.crateId or "Premium"),
			reward.amount or 1,
			"SpinWheel"
		)
		return ok, message, nil
	elseif rewardType == SpinWheelConfig.RewardTypes.CrateRoll then
		local ok, message = CrateRollService:GrantCrateTokens(player, reward.crateId, reward.amount or 1, "SpinWheel")
		return ok, message, nil
	elseif rewardType == SpinWheelConfig.RewardTypes.BombSkin then
		local ok, result = BombSkinService:GrantSkin(player, reward.itemId, "SpinWheel")
		return ok, if ok then nil else tostring(result), nil
	elseif rewardType == SpinWheelConfig.RewardTypes.Finisher then
		local ok, result = FinisherService:GrantFinisher(player, reward.itemId, "SpinWheel")
		return ok, if ok then nil else tostring(result), nil
	elseif rewardType == SpinWheelConfig.RewardTypes.Ability then
		local ok, result = AbilityInventoryService:GrantAbility(player, reward.itemId, "SpinWheel")
		return ok, if ok then nil else tostring(result), nil
	elseif rewardType == SpinWheelConfig.RewardTypes.RandomEmote then
		local ok, result = EmoteService:GrantRandomEmote(player, "SpinWheel")
		if ok then
			local definition = result.definition
			return true, nil, {
				rewardPatch = {
					id = result.emoteId,
					itemId = result.emoteId,
					label = definition and definition.displayName or result.emoteId,
				},
			}
		end
		return true, nil, {
			fallbackSpins = 1,
			rewardPatch = {
				type = SpinWheelConfig.RewardTypes.Spins,
				amount = 1,
				label = "+1 Spin",
				category = "Duplicate",
			},
		}
	elseif rewardType == SpinWheelConfig.RewardTypes.InstantSpinTimed then
		if hasPermanentInstantSpin(player) then
			return true, nil, {
				fallbackSpins = 1,
				rewardPatch = {
					type = SpinWheelConfig.RewardTypes.Spins,
					amount = 1,
					label = "+1 Spin",
					category = "Owned",
				},
			}
		end
		local state = grantTimedInstantSpin(player, reward.durationSeconds)
		if not state then
			return false, "Instant Spin reward is unavailable.", nil
		end
		return true, nil, {
			state = state,
		}
	end

	return false, "Unsupported wheel reward type: " .. tostring(rewardType), nil
end

local function buildRewardPayload(reward, patch)
	local payload = {
		type = reward.type,
		amount = reward.amount,
		id = reward.id or reward.itemId or reward.crateId,
		itemId = reward.itemId,
		crateId = reward.crateId,
		label = reward.label,
		category = reward.category,
		imageId = reward.imageId,
		jackpot = reward.jackpot == true,
	}
	if typeof(patch) == "table" then
		for key, value in pairs(patch) do
			payload[key] = value
		end
	end
	return {
		type = payload.type,
		amount = payload.amount,
		id = payload.id,
		itemId = payload.itemId,
		crateId = payload.crateId,
		label = payload.label,
		category = payload.category,
		imageId = payload.imageId,
		jackpot = payload.jackpot == true,
	}
end

local function fireRewardGranted(player: Player, rewardPayload)
	local bindable = rewardGrantedBindable
	if not (bindable and typeof(rewardPayload) == "table") then
		return
	end
	bindable:Fire(player, {
		type = rewardPayload.type,
		amount = rewardPayload.amount,
		id = rewardPayload.id,
		itemId = rewardPayload.itemId,
		crateId = rewardPayload.crateId,
		label = rewardPayload.label,
		category = rewardPayload.category,
		imageId = rewardPayload.imageId,
		jackpot = rewardPayload.jackpot == true,
	})
end

local function handleRequestSpin(player: Player)
	if isRateLimited(player) then
		return response(false, "RateLimited", "Too many wheel requests.", {
			reason = "too fast",
		})
	end
	if spinLocks[player] then
		return response(false, "SpinInProgress", "A spin is already in progress.", {
			reason = "too fast",
			state = publicState(getState(player), player),
		})
	end

	local resultPayload = nil
	spinLocks[player] = true
	local ok, err = pcall(function()
		local now = os.time()
		local consumed = false
		local consumeMessage = nil
		local stateAfterSpend = setState(player, function(currentState)
			if currentState.spins > 0 then
				currentState.spins -= 1
				consumed = true
			elseif now >= currentState.nextFreeAt then
				currentState.nextFreeAt = now + SpinWheelConfig.FreeSpinCooldownSeconds
				consumed = true
			else
				consumeMessage = "No spins available."
			end
			return currentState
		end)
		if not stateAfterSpend then
			resultPayload = response(false, "DataNotReady", "Player data is not ready.", {
				reason = "loading",
			})
			return
		end

		if not consumed then
			resultPayload = response(false, "NoSpins", consumeMessage or "No spins available.", {
				reason = "no spins",
				state = publicState(stateAfterSpend or getState(player), player),
			})
			return
		end

		local segment, reward = pickReward()
		if not reward then
			resultPayload = response(false, "NoRewards", "No wheel rewards are configured.", {
				state = publicState(stateAfterSpend, player),
			})
			return
		end

		local grantOk, grantMessage, grantResult = grantReward(player, reward)
		if not grantOk then
			warn(("[SpinWheelService] Failed to grant reward to %s: %s"):format(player.Name, tostring(grantMessage)))
			resultPayload = response(false, "GrantFailed", "Wheel reward is unavailable.", {
				state = publicState(stateAfterSpend, player),
			})
			return
		end

		local rewardPatch = if typeof(grantResult) == "table" then grantResult.rewardPatch else nil
		local rewardPayload = buildRewardPayload(reward, rewardPatch)
		local finalState = if typeof(grantResult) == "table" and grantResult.state then grantResult.state else stateAfterSpend
		local extraSpins = if typeof(grantResult) == "table" then roundNonNegative(grantResult.fallbackSpins) else 0
		if reward.type == SpinWheelConfig.RewardTypes.Spins or extraSpins > 0 then
			local spinAmount = if extraSpins > 0 then extraSpins else roundNonNegative(reward.amount)
			finalState = setState(player, function(currentState)
				currentState.spins += spinAmount
				return currentState
			end)
			if not finalState then
				resultPayload = response(false, "DataNotReady", "Player data is not ready.", nil)
				return
			end
		end

		pushState(player, finalState)
		fireRewardGranted(player, rewardPayload)
		Notify.Send(player, "Unlocked " .. tostring(rewardPayload.label or reward.label or "wheel reward") .. "!", { color = "Green" })
		resultPayload = response(true, "Rolled", "Wheel spun.", {
			segment = segment,
			reward = rewardPayload,
			state = publicState(finalState, player),
		})
	end)
	spinLocks[player] = nil

	if not ok then
		warn("[SpinWheelService] Spin request failed: " .. tostring(err))
		return response(false, "SpinFailed", "Wheel spin failed.", {
			state = publicState(getState(player), player),
		})
	end

	return resultPayload
end

function SpinWheelService:GrantSpins(player: Player, amount: number, source: string?): (boolean, string?)
	if not (player and player.Parent == Players) then
		return false, "Target player is not in this server"
	end

	local spinAmount = roundNonNegative(amount)
	if spinAmount <= 0 then
		return false, "Spin amount must be positive"
	end

	local state = setState(player, function(currentState)
		currentState.spins += spinAmount
		return currentState
	end)
	if not state then
		return false, "Player data is not ready"
	end
	pushState(player, state)
	Notify.Send(player, ("Added %d wheel spin%s."):format(spinAmount, if spinAmount == 1 then "" else "s"), {
		color = "Green",
	})
	return true, source
end

function SpinWheelService:GetPublicState(player: Player)
	return publicState(getState(player), player)
end

function SpinWheelService:HasInstantSpin(player: Player): boolean
	return publicState(getState(player), player).HasInstantSpin == true
end

function SpinWheelService:GrantTimedInstantSpin(player: Player, durationSeconds: number, _source: string?): (boolean, string?)
	if not (player and player.Parent == Players) then
		return false, "Target player is not in this server"
	end
	if hasPermanentInstantSpin(player) then
		return self:GrantSpins(player, 1, "InstantSpinOwned")
	end

	local state = grantTimedInstantSpin(player, durationSeconds)
	if not state then
		return false, "Instant Spin reward is unavailable."
	end
	pushState(player, state)
	return true, nil
end

function SpinWheelService:OnStart()
	requestSpinRemote = ensureRequestSpinRemote()
	getStateRemote = ensureGetStateRemote()
	stateChangedRemote = ensureStateChangedRemote()
	ensureModelSurface()

	requestSpinRemote.OnServerInvoke = handleRequestSpin
	getStateRemote.OnServerInvoke = function(player: Player)
		return publicState(getState(player), player)
	end
	if legacyRequestSpinRemote then
		legacyRequestSpinRemote.OnServerInvoke = handleRequestSpin
	end
	if legacyGetStateRemote then
		legacyGetStateRemote.OnServerInvoke = function(player: Player)
			return publicState(getState(player), player)
		end
	end
	if grantSpinsBindable then
		grantSpinsBindable.OnInvoke = function(player: Player, amount: number, source: string?)
			return self:GrantSpins(player, amount, source or "SpinWheelBindable")
		end
	end
end

function SpinWheelService:OnPlayerAdded(player: Player)
	local state = getState(player)
	DataService:Set(player, SPIN_WHEEL_KEY, state)
	pushState(player, state)
end

function SpinWheelService:OnPlayerRemoving(player: Player)
	requestWindows[player] = nil
	lastSpinRequests[player] = nil
	spinLocks[player] = nil
end

return SpinWheelService
