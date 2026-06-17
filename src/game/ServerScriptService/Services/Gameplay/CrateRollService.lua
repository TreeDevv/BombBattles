local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local CrateRollConfig = require(ReplicatedStorage.Shared.Config.CrateRollConfig)
local RobuxPurchases = require(ReplicatedStorage.Shared.Config.Lists.RobuxPurchases)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local BombSkinService = require(script.Parent.BombSkinService)
local DataService = require(script.Parent.DataService)
local PurchaseReceiptService = require(script.Parent.PurchaseReceiptService)

local REMOTES_FOLDER_NAME = CrateRollConfig.RemotesFolderName
local REQUEST_REMOTE_NAME = CrateRollConfig.RequestRemoteName
local RESULT_REMOTE_NAME = CrateRollConfig.ResultRemoteName
local PROMPT_TAG = CrateRollConfig.PromptTag
local PROMPT_CRATE_ID_ATTRIBUTE = CrateRollConfig.PromptCrateIdAttribute
local PROMPT_FREE_ROLL_SOURCE = CrateRollConfig.PromptFreeRollSource
local CASH_KEY = Schema.Cash and Schema.Cash.key or "cash"
local HISTORY_KEY = Schema.CrateRollHistory and Schema.CrateRollHistory.key or "crateRollHistory"

type RequestWindow = {
	startedAt: number,
	count: number,
}

local CrateRollService = {}

local requestRemote: RemoteFunction? = nil
local resultRemote: RemoteEvent? = nil
local requestWindows: { [Player]: RequestWindow } = {}
local rollLocks: { [Player]: boolean } = {}
local promptConnections: { [ProximityPrompt]: RBXScriptConnection } = {}
local rng = Random.new()
local rollSerial = 0

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
	local existing = folder:FindFirstChild(REQUEST_REMOTE_NAME)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = REQUEST_REMOTE_NAME
	remote.Parent = folder
	return remote
end

local function ensureResultRemote(): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(RESULT_REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = RESULT_REMOTE_NAME
	remote.Parent = folder
	return remote
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
	return math.max(0, tonumber(DataService:Get(player, CASH_KEY)) or 0)
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

local function buildStatePayload(player: Player)
	return {
		crates = CrateRollConfig.GetCratesPayload(),
		cash = getCash(player),
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
	for _, skinId in ipairs(BombSkinConfig.GetCatalogIds()) do
		local definition = BombSkinConfig.GetDefinition(skinId)
		local rarity = definition and definition.rarity
		if rarity and (tonumber(crateDefinition.rarityWeights[rarity]) or 0) > 0 then
			candidatesByRarity[rarity] = candidatesByRarity[rarity] or {}
			table.insert(candidatesByRarity[rarity], skinId)
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

local function pickSkinId(crateDefinition): string?
	local candidatesByRarity = getCandidatesByRarity(crateDefinition)
	local rarity = pickWeightedRarity(crateDefinition, candidatesByRarity)
	local candidates = rarity and candidatesByRarity[rarity] or nil
	if not candidates or #candidates <= 0 then
		return nil
	end

	return candidates[rng:NextInteger(1, #candidates)]
end

local function nextRollId(player: Player, crateId: string): string
	rollSerial += 1
	return ("%d:%d:%s:%06d"):format(player.UserId, os.time(), crateId, rollSerial)
end

local function buildRewardPayload(crateDefinition, grantResult, source: string, rollId: string)
	local definition = grantResult.definition
	local reward = {
		skinId = grantResult.skinId,
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
		skinId = reward.skinId,
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
			skinId = rollPayload.skinId,
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
	local skinId = pickSkinId(crateDefinition)
	if not skinId then
		return false, "No rollable skins are configured for " .. crateDefinition.displayName
	end

	local ok, grantResult = BombSkinService:GrantSkin(player, skinId, source)
	if not ok then
		return false, grantResult
	end

	local rollPayload = buildRewardPayload(crateDefinition, grantResult, source, nextRollId(player, crateDefinition.id))
	recordRollHistory(player, rollPayload)
	return true, rollPayload
end

local function rollCash(player: Player, crateDefinition)
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

	if price > 0 then
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
		return rollPromptFree(player, crateDefinition)
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
	local rewardName = if typeof(reward) == "table" then tostring(reward.displayName or reward.skinId) else "reward"
	return resultPayload.ok == true, resultPayload.message or resultPayload.code, resultPayload.ok == true and rewardName or nil
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
end

return CrateRollService
