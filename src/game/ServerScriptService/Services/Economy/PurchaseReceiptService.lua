local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataService = require(script.Parent.DataService)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local RobuxPurchases = require(ReplicatedStorage.Shared.Config.Lists.RobuxPurchases)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local PURCHASE_LOG_FIELD = "purchaseLog"
local REMOTES_FOLDER_NAME = "Remotes"
local PLAY_CLIENT_SOUND_REMOTE_NAME = "PlayClientSound"
local STARTER_PACK_KEY = "StarterPack"
local STARTER_PACK_OWNED_ATTR = "StarterPackOwned"

local PurchaseReceipt = {}

PurchaseReceipt.RobuxPurchases = RobuxPurchases
PurchaseReceipt.PurchaseProcessed = Signal.new()
PurchaseReceipt.OwnedPassesReady = Signal.new()

local remotesFolder: Folder? = nil
local playClientSoundRemote: RemoteEvent? = nil
local ownedPassesCache = {}

local function ensureRemotesFolder(): Folder
	if remotesFolder and remotesFolder.Parent == ReplicatedStorage then
		return remotesFolder
	end

	local folder = RemoteUtil.EnsureFolder(ReplicatedStorage, REMOTES_FOLDER_NAME)
	remotesFolder = folder
	return folder
end

local function ensurePlayClientSoundRemote(): RemoteEvent
	local folder = ensureRemotesFolder()

	if playClientSoundRemote and playClientSoundRemote.Parent == folder then
		return playClientSoundRemote
	end

	local remote = RemoteUtil.EnsureRemoteEvent(folder, PLAY_CLIENT_SOUND_REMOTE_NAME)
	playClientSoundRemote = remote
	return remote
end

local function sendClientSound(player: Player, soundName: string)
	if typeof(soundName) ~= "string" or soundName == "" then
		return
	end

	ensurePlayClientSoundRemote():FireClient(player, soundName)
end

local function emptyLog()
	return { products = {}, passes = {} }
end

local function getLog(player)
	return DataService:Get(player, PURCHASE_LOG_FIELD) or emptyLog()
end

local function getProductIdString(idOrKey)
	if typeof(idOrKey) == "number" then
		return tostring(math.floor(idOrKey))
	end
	if typeof(idOrKey) == "string" then
		local config = RobuxPurchases.Products[idOrKey]
		if config and config.id then
			return tostring(config.id)
		end
	end
	return nil
end

local function hasProductPurchase(player, idOrKey)
	local productId = getProductIdString(idOrKey)
	if not productId then
		return false
	end

	local purchaseLog = getLog(player)
	local products = typeof(purchaseLog) == "table" and purchaseLog.products or nil
	return typeof(products) == "table" and products[productId] ~= nil
end

local function syncStarterPackOwnedAttribute(player)
	player:SetAttribute(STARTER_PACK_OWNED_ATTR, hasProductPurchase(player, STARTER_PACK_KEY))
end

local function getPurchaseDisplayName(kind, key, id)
	local catalog = if kind == "product" then RobuxPurchases.Products else RobuxPurchases.Passes
	local config = if typeof(key) == "string" and catalog then catalog[key] else nil
	local rawName = tostring((config and (config.displayName or config.name)) or key or id or "purchase")
	if rawName == "" then
		return "purchase"
	end

	return rawName
		:gsub("_", " ")
		:gsub("(%l)(%u)", "%1 %2")
		:gsub("(%a)(%d)", "%1 %2")
		:gsub("(%d)(%a)", "%1 %2")
		:gsub("%s+", " ")
end

local function sendPurchaseThanks(player, kind, key, id, source)
	if source ~= "prompt" and source ~= "receipt" then
		return
	end

	Notify.Send(player, string.format("Thanks for purchasing %s!", getPurchaseDisplayName(kind, key, id)), { color = "Green" })
end

local function logPurchase(player, idOrKey, purchaseId, opts)
	local idStr, keyStr
	if typeof(idOrKey) == "number" then
		idStr = tostring(idOrKey)
	else
		keyStr = tostring(idOrKey)
	end

	local isNew = false

	DataService:Set(player, PURCHASE_LOG_FIELD, function(purchaseLog)
		purchaseLog = purchaseLog or emptyLog()

		if purchaseId then
			local id = idStr
			if not id and keyStr then
				local config = RobuxPurchases.Products[keyStr]
				id = config and tostring(config.id) or nil
			end
			if not id then
				return purchaseLog
			end

			purchaseLog.products[id] = purchaseLog.products[id] or { key = keyStr }
			if not purchaseLog.products[id][purchaseId] then
				isNew = true
				purchaseLog.products[id][purchaseId] = os.time()
			end
		else
			local id = idStr
			local key = keyStr
			if not id and key then
				local config = RobuxPurchases.Passes[key]
				id = config and tostring(config.id) or nil
			end
			if not id then
				return purchaseLog
			end

			local pass = purchaseLog.passes[id]
			if not pass or not pass.processed then
				isNew = true
			end
			purchaseLog.passes[id] = pass or {
				key = key,
				firstSeen = os.time(),
				via = (opts and opts.via) or "unknown",
				processed = true,
			}
			purchaseLog.passes[id].lastVerified = os.time()
		end

		return purchaseLog
	end)

	return isNew
end

local function callConfigHook(kind, key, hookName, player, context)
	local config = if kind == "product" then RobuxPurchases.Products[key] else RobuxPurchases.Passes[key]
	if config and config[hookName] then
		local ok, err = pcall(config[hookName], player, context)
		if not ok then
			warn(string.format("[PurchaseReceipt] %s:%s for key %s failed: %s", kind, hookName, tostring(key), tostring(err)))
		end
	end
end

local function processProductReceipt(receiptInfo)
	local userId = receiptInfo.PlayerId
	local productId = receiptInfo.ProductId
	local purchaseId = receiptInfo.PurchaseId

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local sentGift = false
	local giftRecipientUserId = player:GetAttribute("Gifting")
	if giftRecipientUserId then
		local targetKey = RobuxPurchases.GiftingMap[productId]
		if targetKey then
			DataService:SendGlobalUpdate(player, giftRecipientUserId, "Gift", targetKey)
			sentGift = true
		end
	end

	local config = RobuxPurchases.ProductsById[productId]
	local key = config and config.key or nil
	if key == STARTER_PACK_KEY and hasProductPurchase(player, productId) then
		syncStarterPackOwnedAttribute(player)
		Notify.Send(player, "You already own the Starter Pack.", { color = "Red" })
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local isNew = logPurchase(player, productId, purchaseId, { via = "receipt" })
	if key == STARTER_PACK_KEY then
		syncStarterPackOwnedAttribute(player)
	end

	if not sentGift and isNew then
		local context = {
			kind = "product",
			key = key,
			id = productId,
			purchaseId = purchaseId,
			source = "receipt",
			isNew = true,
		}
		PurchaseReceipt.PurchaseProcessed:Fire(player, key or tostring(productId), context)
		if key then
			callConfigHook("product", key, "onProcessed", player, context)
		end
		sendClientSound(player, "Kaching")
		sendPurchaseThanks(player, context.kind, key or tostring(productId), productId, context.source)
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function unpackPromptGamePassArgs(a, b, c)
	local player = nil
	local gamePassId = nil
	local wasPurchased = false

	if typeof(a) == "Instance" and a:IsA("Player") then
		player = a
		gamePassId = tonumber(b)
		wasPurchased = c == true
	elseif typeof(a) == "number" and typeof(b) == "number" and typeof(c) == "boolean" then
		player = Players:GetPlayerByUserId(a)
		gamePassId = b
		wasPurchased = c
	else
		gamePassId = tonumber(a)
		wasPurchased = b == true or c == true
		if typeof(b) == "Instance" and b:IsA("Player") then
			player = b
		elseif typeof(c) == "Instance" and c:IsA("Player") then
			player = c
		end
	end

	return player, gamePassId, wasPurchased
end

local function onPromptGamePassFinished(a, b, c)
	local player, gamePassId, wasPurchased = unpackPromptGamePassArgs(a, b, c)
	if not player or not gamePassId or not wasPurchased then
		return
	end

	local config = RobuxPurchases.PassesById[gamePassId]
	if not config then
		warn("[PurchaseReceipt] Unknown pass id:", gamePassId)
		return
	end

	local key = config.key
	ownedPassesCache[player] = ownedPassesCache[player] or {}
	ownedPassesCache[player][key] = true

	local isNew = logPurchase(player, key, nil, { via = "prompt" })
	local context = { kind = "pass", key = key, id = gamePassId, source = "prompt", isNew = isNew == true }
	PurchaseReceipt.PurchaseProcessed:Fire(player, key, context)
	if isNew then
		sendClientSound(player, "Kaching")
		callConfigHook("pass", key, "onProcessed", player, context)
		sendPurchaseThanks(player, context.kind, key, gamePassId, context.source)
	end
end

local function refreshPassOwnership(player)
	local ownedKeys = {}
	local userId = player.UserId

	for key, config in pairs(RobuxPurchases.Passes) do
		local passId = config.id
		if passId then
			local ok, has = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, userId, passId)
			if ok and has then
				ownedKeys[key] = true
				ownedPassesCache[player] = ownedPassesCache[player] or {}
				ownedPassesCache[player][key] = true

				local log = getLog(player)
				local passLog = log.passes[tostring(passId)]
				if not passLog or not passLog.processed then
					local isNew = logPurchase(player, key, nil, { via = "offline" })
					if isNew then
						local context = { kind = "pass", key = key, id = passId, source = "offline", isNew = true }
						PurchaseReceipt.PurchaseProcessed:Fire(player, key, context)
						callConfigHook("pass", key, "onProcessed", player, context)
					end
				end

				local joinContext = { kind = "pass", key = key, id = passId, source = "join", isNew = false }
				callConfigHook("pass", key, "onJoin", player, joinContext)
			end
		end
	end

	PurchaseReceipt.OwnedPassesReady:Fire(player, table.freeze(ownedKeys))
end

function PurchaseReceipt:OnStart()
	ensurePlayClientSoundRemote()
	MarketplaceService.ProcessReceipt = processProductReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPromptGamePassFinished)
end

function PurchaseReceipt:OnPlayerAdded(player: Player)
	syncStarterPackOwnedAttribute(player)
	refreshPassOwnership(player)
end

function PurchaseReceipt:OnPlayerRemoving(player: Player)
	ownedPassesCache[player] = nil
end

function PurchaseReceipt:HasPass(player, passIdOrKey)
	local key = nil
	if typeof(passIdOrKey) == "number" then
		local config = RobuxPurchases.PassesById[passIdOrKey]
		key = config and config.key or nil
	else
		key = passIdOrKey
	end
	if not key then
		return false
	end

	local set = ownedPassesCache[player]
	return set and set[key] == true or false
end

function PurchaseReceipt:GetOwnedPasses(player)
	return ownedPassesCache[player] or {}
end

return PurchaseReceipt
