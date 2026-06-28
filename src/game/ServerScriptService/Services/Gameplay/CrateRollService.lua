local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local CrateRollConfig = require(ReplicatedStorage.Shared.Config.CrateRollConfig)
local DebugEconomyConfig = require(ReplicatedStorage.Shared.Config.DebugEconomyConfig)
local RobuxPurchases = require(ReplicatedStorage.Shared.Config.Lists.RobuxPurchases)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)

local BombSkinService = require(script.Parent.BombSkinService)
local DataService = require(script.Parent.DataService)
local FinisherConfig = require(ReplicatedStorage.Shared.Config.FinisherConfig)
local FinisherService = require(script.Parent.FinisherService)
local PurchaseReceiptService = require(script.Parent.PurchaseReceiptService)

local REMOTES_FOLDER_NAME = CrateRollConfig.RemotesFolderName
local REQUEST_REMOTE_NAME = CrateRollConfig.RequestRemoteName
local RESULT_REMOTE_NAME = CrateRollConfig.ResultRemoteName
local PROMPT_TAG = CrateRollConfig.PromptTag
local PROMPT_CRATE_ID_ATTRIBUTE = CrateRollConfig.PromptCrateIdAttribute
local PROMPT_FREE_ROLL_SOURCE = CrateRollConfig.PromptFreeRollSource
local CASH_KEY = Schema.Cash and Schema.Cash.key or "cash"
local HISTORY_KEY = Schema.CrateRollHistory and Schema.CrateRollHistory.key or "crateRollHistory"
local CRATE_TOKENS_KEY = Schema.CrateTokens and Schema.CrateTokens.key or "crateTokens"
local PENDING_PROMPT_PURCHASE_TTL_SECONDS = 120

type RequestWindow = {
	startedAt: number,
	count: number,
}

type PendingPromptPurchase = {
	productKey: string,
	crateId: string,
	requestedAt: number,
}

local CrateRollService = {}

local requestRemote: RemoteFunction? = nil
local resultRemote: RemoteEvent? = nil
local requestWindows: { [Player]: RequestWindow } = {}
local rollLocks: { [Player]: boolean } = {}
local promptConnections: { [ProximityPrompt]: RBXScriptConnection } = {}
local pendingPromptPurchases: { [Player]: PendingPromptPurchase } = {}
local rng = Random.new()
local rollSerial = 0

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, REMOTES_FOLDER_NAME)
end

local function ensureRequestRemote(): RemoteFunction
	return RemoteUtil.EnsureRemoteFunction(ensureRemotesFolder(), REQUEST_REMOTE_NAME)
end

local function ensureResultRemote(): RemoteEvent
	return RemoteUtil.EnsureRemoteEvent(ensureRemotesFolder(), RESULT_REMOTE_NAME)
end

local function response(ok: boolean, code: string, message: string?, data: any?)
	local payload = {
		ok = ok,
		code = code,
		message = message,
	}
	if typeof(data) == "table" then
		for key, value in pairs(data) do
			payload[key] = value
		end
	end
	return payload
end

local function getCash(player: Player): number
	return DebugEconomyConfig.GetEffectiveCash(player, DataService:Get(player, CASH_KEY))
end

local function roundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue < 0 then
		return 0
	end
	return math.floor(numberValue + 0.5)
end

local function normalizeCrateTokens(value: any): { [string]: number }
	local tokens = {
		Basic = 0,
		Premium = 0,
		FinisherBasic = 0,
		FinisherPremium = 0,
	}
	if typeof(value) ~= "table" then
		return tokens
	end

	for crateId in pairs(tokens) do
		tokens[crateId] = roundNonNegative(value[crateId])
	end
	return tokens
end

local function getCrateTokens(player: Player): { [string]: number }
	return normalizeCrateTokens(DataService:Get(player, CRATE_TOKENS_KEY))
end

local function getCrateTokenCount(player: Player, crateId: string): number
	local normalizedCrateId = CrateRollConfig.NormalizeCrateId(crateId)
	if normalizedCrateId == "" then
		return 0
	end
	return roundNonNegative(getCrateTokens(player)[normalizedCrateId])
end

local function consumeCrateToken(player: Player, crateId: string): boolean
	local normalizedCrateId = CrateRollConfig.NormalizeCrateId(crateId)
	if normalizedCrateId == "" then
		return false
	end

	local consumed = false
	DataService:Set(player, CRATE_TOKENS_KEY, function(currentValue)
		local tokens = normalizeCrateTokens(currentValue)
		local currentCount = roundNonNegative(tokens[normalizedCrateId])
		if currentCount <= 0 then
			return tokens
		end

		tokens[normalizedCrateId] = currentCount - 1
		consumed = true
		return tokens
	end)
	return consumed
end

local function getProductConfig(productKey: string?)
	if typeof(productKey) ~= "string" or productKey == "" then
		return nil
	end

	return RobuxPurchases.Products[productKey]
end

local function isProductEnabled(productKey: string?): boolean
	local productConfig = getProductConfig(productKey)
	local productId = productConfig and tonumber(productConfig.id) or nil
	return productId ~= nil and productId > 0
end

local function getPromptProductForCrate(crateDefinition): (string?, any?, string?)
	local productKey = crateDefinition.productKey
	local productConfig = getProductConfig(productKey)
	if not productConfig then
		return nil, nil, "This crate is unavailable."
	end

	local productId = math.floor(tonumber(productConfig.id) or 0)
	if productId <= 0 then
		return productKey, nil, "This crate is not available yet."
	end

	return productKey, productConfig, nil
end

local function buildProductPurchasePayload(crateDefinition, productKey: string, productConfig)
	return {
		crateId = crateDefinition.id,
		crateDisplayName = crateDefinition.displayName,
		productKey = productKey,
		productId = math.floor(tonumber(productConfig.id) or 0),
		displayName = tostring(productConfig.displayName or crateDefinition.displayName),
		price = math.floor(tonumber(productConfig.price) or 0),
	}
end

local function setPendingPromptPurchase(player: Player, productKey: string, crateId: string)
	pendingPromptPurchases[player] = {
		productKey = productKey,
		crateId = crateId,
		requestedAt = os.clock(),
	}
end

local function clearPendingPromptPurchase(player: Player, productKey: string?)
	local pending = pendingPromptPurchases[player]
	if not pending then
		return
	end
	if typeof(productKey) == "string" and productKey ~= "" and pending.productKey ~= productKey then
		return
	end
	pendingPromptPurchases[player] = nil
end

local function hasPendingPromptPurchase(player: Player, productKey: string, crateId: string): boolean
	local pending = pendingPromptPurchases[player]
	if not pending then
		return false
	end

	if os.clock() - pending.requestedAt > PENDING_PROMPT_PURCHASE_TTL_SECONDS then
		pendingPromptPurchases[player] = nil
		return false
	end

	return pending.productKey == productKey and pending.crateId == crateId
end

local function buildStatePayload(player: Player)
	return {
		crates = CrateRollConfig.GetCratesPayload(),
		cash = getCash(player),
		infiniteCash = DebugEconomyConfig.HasInfiniteCash(player),
		crateTokens = getCrateTokens(player),
		ownedBombSkins = BombSkinService:GetOwnedSkins(player),
		bombSkinCopies = BombSkinService:GetSkinCopies(player),
	}
end

local function isRateLimited(player: Player): boolean
	local now = os.clock()
	local window = requestWindows[player]
	if not window or now - window.startedAt >= 1 then
		requestWindows[player] = {
			startedAt = now,
			count = 1,
		}
		return false
	end

	window.count += 1
	return window.count > CrateRollConfig.MaxRequestsPerSecond
end

local function getCandidatesByRarity(crateDefinition)
	local candidatesByRarity = {}
	local rewardType = crateDefinition.rewardType or CrateRollConfig.RewardTypes.BombSkin
	local config = if rewardType == CrateRollConfig.RewardTypes.Finisher then FinisherConfig else BombSkinConfig

	for _, itemId in ipairs(config.GetCatalogIds()) do
		local definition = config.GetDefinition(itemId)
		local rarity = definition and definition.rarity
		if rarity and (tonumber(crateDefinition.rarityWeights[rarity]) or 0) > 0 then
			candidatesByRarity[rarity] = candidatesByRarity[rarity] or {}
			table.insert(candidatesByRarity[rarity], itemId)
		end
	end
	return candidatesByRarity
end

local function pickWeightedRarity(crateDefinition, candidatesByRarity): string?
	local totalWeight = 0
	local weightedRarities = {}
	for _, rarity in ipairs(CrateRollConfig.RarityOrder) do
		local candidates = candidatesByRarity[rarity]
		local weight = tonumber(crateDefinition.rarityWeights[rarity]) or 0
		if candidates and #candidates > 0 and weight > 0 then
			totalWeight += weight
			table.insert(weightedRarities, {
				rarity = rarity,
				weight = weight,
			})
		end
	end

	if totalWeight <= 0 then
		return nil
	end

	local roll = rng:NextNumber(0, totalWeight)
	local cursor = 0
	for _, entry in ipairs(weightedRarities) do
		cursor += entry.weight
		if roll <= cursor then
			return entry.rarity
		end
	end

	return weightedRarities[#weightedRarities].rarity
end

local function pickRewardId(crateDefinition): string?
	local candidatesByRarity = getCandidatesByRarity(crateDefinition)
	local rarity = pickWeightedRarity(crateDefinition, candidatesByRarity)
	local candidates = rarity and candidatesByRarity[rarity] or nil
	if not candidates or #candidates <= 0 then
		return nil
	end

	return candidates[rng:NextInteger(1, #candidates)]
end

local function grantCrateReward(player: Player, crateDefinition, rewardId: string, source: string): (boolean, any)
	local rewardType = crateDefinition.rewardType or CrateRollConfig.RewardTypes.BombSkin
	if rewardType == CrateRollConfig.RewardTypes.Finisher then
		return FinisherService:GrantFinisher(player, rewardId, source)
	end

	return BombSkinService:GrantSkin(player, rewardId, source)
end

local function nextRollId(player: Player, crateId: string): string
	rollSerial += 1
	return ("%d:%d:%s:%06d"):format(player.UserId, os.time(), crateId, rollSerial)
end

local function buildRewardPayload(crateDefinition, grantResult, source: string, rollId: string)
	local definition = grantResult.definition
	local rewardType = crateDefinition.rewardType or CrateRollConfig.RewardTypes.BombSkin
	local itemId = grantResult.skinId or grantResult.finisherId
	local reward = {
		rewardType = rewardType,
		itemId = itemId,
		skinId = grantResult.skinId,
		finisherId = grantResult.finisherId,
		displayName = definition.displayName,
		rarity = definition.rarity,
		iconImage = definition.iconImage,
		isNew = grantResult.isNew,
		copyCount = grantResult.copyCount,
	}

	return {
		rollId = rollId,
		crateId = crateDefinition.id,
		crateDisplayName = crateDefinition.displayName,
		source = source,
		rewardType = reward.rewardType,
		itemId = reward.itemId,
		skinId = reward.skinId,
		finisherId = reward.finisherId,
		displayName = reward.displayName,
		rarity = reward.rarity,
		iconImage = reward.iconImage,
		isNew = reward.isNew,
		copyCount = reward.copyCount,
		reward = reward,
	}
end

local function recordRollHistory(player: Player, rollPayload)
	DataService:Set(player, HISTORY_KEY, function(currentValue)
		local history = if typeof(currentValue) == "table" then currentValue else {}
		local recent = if typeof(history.recent) == "table" then history.recent else {}

		table.insert(recent, 1, {
			rollId = rollPayload.rollId,
			crateId = rollPayload.crateId,
			source = rollPayload.source,
			rewardType = rollPayload.rewardType,
			itemId = rollPayload.itemId,
			skinId = rollPayload.skinId,
			finisherId = rollPayload.finisherId,
			rarity = rollPayload.rarity,
			isNew = rollPayload.isNew,
			copyCount = rollPayload.copyCount,
			rolledAt = os.time(),
		})

		while #recent > CrateRollConfig.HistoryLimit do
			table.remove(recent)
		end

		history.recent = recent
		return history
	end)
end

local function grantRoll(player: Player, crateDefinition, source: string): (boolean, any)
	local rewardId = pickRewardId(crateDefinition)
	if not rewardId then
		local rewardName = if crateDefinition.rewardType == CrateRollConfig.RewardTypes.Finisher then "finishers" else "skins"
		return false, "No rollable " .. rewardName .. " are configured for " .. crateDefinition.displayName
	end

	local ok, grantResult = grantCrateReward(player, crateDefinition, rewardId, source)
	if not ok then
		return false, grantResult
	end

	local rollPayload = buildRewardPayload(crateDefinition, grantResult, source, nextRollId(player, crateDefinition.id))
	recordRollHistory(player, rollPayload)
	return true, rollPayload
end

local function rollToken(player: Player, crateDefinition, source: string)
	local ok, rollPayload = grantRoll(player, crateDefinition, source)
	if not ok then
		return response(false, "RollFailed", tostring(rollPayload), buildStatePayload(player))
	end

	if not consumeCrateToken(player, crateDefinition.id) then
		return response(false, "TokenUnavailable", "Crate token is unavailable.", buildStatePayload(player))
	end

	return response(true, "Rolled", "Opened " .. crateDefinition.displayName .. ".", {
		roll = rollPayload,
		reward = rollPayload.reward,
		state = buildStatePayload(player),
	})
end

local function rollCash(player: Player, crateDefinition)
	if getCrateTokenCount(player, crateDefinition.id) > 0 then
		return rollToken(player, crateDefinition, "CrateToken")
	end

	local price = tonumber(crateDefinition.cashPrice)
	if not price or price < 0 then
		return response(false, "CashUnavailable", "This crate cannot be opened with cash.", buildStatePayload(player))
	end

	price = math.floor(price)
	local cash = getCash(player)
	if cash < price then
		return response(false, "InsufficientCash", "Not enough cash.", buildStatePayload(player))
	end

	local ok, rollPayload = grantRoll(player, crateDefinition, "Cash")
	if not ok then
		return response(false, "RollFailed", tostring(rollPayload), buildStatePayload(player))
	end

	if price > 0 and not DebugEconomyConfig.ShouldBypassCashSpend(player) then
		DataService:Set(player, CASH_KEY, function(currentValue)
			return math.max(0, (tonumber(currentValue) or 0) - price)
		end)
	end

	return response(true, "Rolled", "Opened " .. crateDefinition.displayName .. ".", {
		roll = rollPayload,
		reward = rollPayload.reward,
		state = buildStatePayload(player),
	})
end

local function rollPrompt(player: Player, crateDefinition)
	if getCrateTokenCount(player, crateDefinition.id) > 0 then
		return rollToken(player, crateDefinition, "CrateToken")
	end

	if tonumber(crateDefinition.cashPrice) ~= nil then
		return rollCash(player, crateDefinition)
	end

	local productKey, productConfig, unavailableMessage = getPromptProductForCrate(crateDefinition)
	if not productKey or not productConfig then
		return response(
			false,
			"PurchaseUnavailable",
			unavailableMessage or "This crate is not available yet.",
			buildStatePayload(player)
		)
	end

	setPendingPromptPurchase(player, productKey, crateDefinition.id)
	return response(false, "PurchaseRequired", "This crate requires a purchase.", {
		productPurchase = buildProductPurchasePayload(crateDefinition, productKey, productConfig),
		state = buildStatePayload(player),
	})
end

local function rollPromptFree(player: Player, crateDefinition)
	if CrateRollConfig.PromptFreeRollsEnabled ~= true then
		return response(false, "PromptRollsDisabled", "Crate prompts are not available.", buildStatePayload(player))
	end

	local ok, rollPayload = grantRoll(player, crateDefinition, PROMPT_FREE_ROLL_SOURCE)
	if not ok then
		return response(false, "RollFailed", tostring(rollPayload), buildStatePayload(player))
	end

	return response(true, "Rolled", "Opened " .. crateDefinition.displayName .. ".", {
		roll = rollPayload,
		reward = rollPayload.reward,
		state = buildStatePayload(player),
	})
end

local function withRollLock(player: Player, callback)
	if rollLocks[player] then
		return response(false, "RollInProgress", "A crate roll is already in progress.", buildStatePayload(player))
	end

	rollLocks[player] = true
	local ok, resultPayload = pcall(callback)
	rollLocks[player] = nil

	if not ok then
		warn("[CrateRollService] Roll failed:", resultPayload)
		return response(false, "RollFailed", "Crate roll failed.", buildStatePayload(player))
	end

	return resultPayload
end

local function resolveRequest(rawRequest)
	if typeof(rawRequest) ~= "table" then
		return nil
	end

	local action = rawRequest.action
	if typeof(action) ~= "string" then
		return nil
	end

	return {
		action = action,
		crateId = rawRequest.crateId,
		productKey = rawRequest.productKey,
	}
end

local function handleInvoke(player: Player, rawRequest)
	if isRateLimited(player) then
		return response(false, "RateLimited", "Too many crate requests.", nil)
	end

	local request = resolveRequest(rawRequest)
	if not request then
		return response(false, "InvalidRequest", "Invalid crate request.", nil)
	end

	if request.action == CrateRollConfig.Actions.GetState then
		return response(true, "OK", "OK", {
			state = buildStatePayload(player),
		})
	elseif request.action == CrateRollConfig.Actions.RollCash then
		local crateDefinition = CrateRollConfig.GetDefinition(request.crateId)
		if not crateDefinition then
			return response(false, "UnknownCrate", "Unknown crate.", buildStatePayload(player))
		end

		return withRollLock(player, function()
			return rollCash(player, crateDefinition)
		end)
	elseif request.action == CrateRollConfig.Actions.ClearPromptPurchase then
		clearPendingPromptPurchase(player, request.productKey)
		return response(true, "OK", "OK", nil)
	end

	return response(false, "UnknownAction", "Unknown crate action.", nil)
end

local function fireRollResult(player: Player, resultPayload)
	if resultRemote then
		resultRemote:FireClient(player, resultPayload)
	end
end

local function handlePromptTriggered(prompt: ProximityPrompt, player: Player)
	if not (player and player:IsA("Player")) then
		return
	end

	if isRateLimited(player) then
		fireRollResult(player, response(false, "RateLimited", "Too many crate requests.", nil))
		return
	end

	local crateId = prompt:GetAttribute(PROMPT_CRATE_ID_ATTRIBUTE)
	local crateDefinition = CrateRollConfig.GetDefinition(crateId)
	if not crateDefinition then
		warn(("[CrateRollService] Tagged crate prompt %s has invalid %s: %s"):format(
			prompt:GetFullName(),
			PROMPT_CRATE_ID_ATTRIBUTE,
			tostring(crateId)
		))
		fireRollResult(player, response(false, "UnknownCrate", "Unknown crate.", buildStatePayload(player)))
		return
	end

	local resultPayload = withRollLock(player, function()
		return rollPrompt(player, crateDefinition)
	end)

	fireRollResult(player, resultPayload)
end

local function unbindCratePrompt(instance: Instance)
	if not instance:IsA("ProximityPrompt") then
		return
	end

	local connection = promptConnections[instance]
	if connection then
		connection:Disconnect()
		promptConnections[instance] = nil
	end
end

local function bindCratePrompt(instance: Instance)
	if not instance:IsA("ProximityPrompt") then
		return
	end
	if promptConnections[instance] then
		return
	end

	promptConnections[instance] = instance.Triggered:Connect(function(player)
		handlePromptTriggered(instance, player)
	end)
end

local function bindExistingCratePrompts()
	for _, instance in ipairs(CollectionService:GetTagged(PROMPT_TAG)) do
		bindCratePrompt(instance)
	end
end

local function handlePurchaseProcessed(player: Player, productKey: string, context)
	local productConfig = getProductConfig(productKey)
	if productConfig and tonumber(productConfig.crateTokens) ~= nil then
		local crateDefinition = CrateRollConfig.GetDefinition(productConfig.crateId)
		if not crateDefinition or not hasPendingPromptPurchase(player, productKey, crateDefinition.id) then
			return
		end

		clearPendingPromptPurchase(player, productKey)
		local resultPayload = withRollLock(player, function()
			return rollToken(player, crateDefinition, "Robux")
		end)

		if typeof(resultPayload) == "table" then
			resultPayload.productContext = context
		end
		fireRollResult(player, resultPayload)
		return
	end

	local crateDefinition = CrateRollConfig.GetCrateForProductKey(productKey)
	if not crateDefinition then
		return
	end
	if not isProductEnabled(productKey) then
		warn("[CrateRollService] Ignoring disabled crate product:", productKey)
		return
	end

	local resultPayload = withRollLock(player, function()
		local ok, rollPayload = grantRoll(player, crateDefinition, "Robux")
		if not ok then
			return response(false, "RollFailed", tostring(rollPayload), buildStatePayload(player))
		end

		return response(true, "Rolled", "Opened " .. crateDefinition.displayName .. ".", {
			roll = rollPayload,
			reward = rollPayload.reward,
			productContext = context,
			state = buildStatePayload(player),
		})
	end)

	fireRollResult(player, resultPayload)
	if resultPayload.ok == true and resultPayload.reward then
		local displayName = tostring(resultPayload.reward.displayName or "skin")
		Notify.Send(player, "Unlocked " .. displayName .. "!", { color = "Green" })
	end
end

function CrateRollService:AdminRoll(player: Player, rawCrateId: any): (boolean, string?, any?)
	local crateDefinition = CrateRollConfig.GetDefinition(rawCrateId)
	if not crateDefinition then
		return false, "Unknown crate: " .. tostring(rawCrateId), nil
	end

	local resultPayload = withRollLock(player, function()
		local ok, rollPayload = grantRoll(player, crateDefinition, "Admin")
		if not ok then
			return response(false, "RollFailed", tostring(rollPayload), buildStatePayload(player))
		end

		return response(true, "Rolled", "Opened " .. crateDefinition.displayName .. ".", {
			roll = rollPayload,
			reward = rollPayload.reward,
			state = buildStatePayload(player),
		})
	end)

	if resultPayload.ok == true then
		fireRollResult(player, resultPayload)
	end

	local reward = resultPayload.reward
	local rewardName = if typeof(reward) == "table" then tostring(reward.displayName or reward.itemId or reward.skinId or reward.finisherId) else "reward"
	return resultPayload.ok == true, resultPayload.message or resultPayload.code, resultPayload.ok == true and rewardName or nil
end

function CrateRollService:GrantRewardRoll(player: Player, rawCrateId: any, source: string?): (boolean, string?, any?)
	if not (player and player:IsA("Player")) then
		return false, "Player is required", nil
	end

	local crateDefinition = CrateRollConfig.GetDefinition(rawCrateId)
	if not crateDefinition then
		return false, "Unknown crate: " .. tostring(rawCrateId), nil
	end

	local resultPayload = withRollLock(player, function()
		local ok, rollPayload = grantRoll(player, crateDefinition, tostring(source or "Reward"))
		if not ok then
			return response(false, "RollFailed", tostring(rollPayload), buildStatePayload(player))
		end

		return response(true, "Rolled", "Opened " .. crateDefinition.displayName .. ".", {
			roll = rollPayload,
			reward = rollPayload.reward,
			state = buildStatePayload(player),
		})
	end)

	if resultPayload.ok == true then
		fireRollResult(player, resultPayload)
	end

	local reward = resultPayload.reward
	local rewardName = if typeof(reward) == "table" then tostring(reward.displayName or reward.itemId or reward.skinId or reward.finisherId) else nil
	return resultPayload.ok == true, resultPayload.message or resultPayload.code, rewardName
end

function CrateRollService:OnStart()
	requestRemote = ensureRequestRemote()
	resultRemote = ensureResultRemote()
	requestRemote.OnServerInvoke = handleInvoke
	PurchaseReceiptService.PurchaseProcessed:Connect(handlePurchaseProcessed)
	CollectionService:GetInstanceAddedSignal(PROMPT_TAG):Connect(bindCratePrompt)
	CollectionService:GetInstanceRemovedSignal(PROMPT_TAG):Connect(unbindCratePrompt)
	bindExistingCratePrompts()
end

function CrateRollService:OnPlayerRemoving(player: Player)
	requestWindows[player] = nil
	rollLocks[player] = nil
	pendingPromptPurchases[player] = nil
end

return CrateRollService
