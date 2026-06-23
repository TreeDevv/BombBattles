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
local PREPARE_GIFT_PURCHASE_REMOTE_NAME = "PrepareGiftPurchase"
local GIFT_PURCHASE_RESULT_REMOTE_NAME = "GiftPurchaseResult"
local GIFT_UPDATE_TYPE = "Gift"
local PENDING_GIFT_TTL_SECONDS = 30 * 60
local STARTER_PACK_KEY = "StarterPack"
local STARTER_PACK_OWNED_ATTR = "StarterPackOwned"

local SUPPORTED_GIFT_TARGETS = {
	FatPack = true,
}

local GIFT_OWNERSHIP_REQUIREMENTS = {
	FatPack = {
		abilityId = "FatBomb",
		bombSkinId = "FatGuy",
	},
}

local PurchaseReceipt = {}

PurchaseReceipt.RobuxPurchases = RobuxPurchases
PurchaseReceipt.PurchaseProcessed = Signal.new()
PurchaseReceipt.OwnedPassesReady = Signal.new()

local remotesFolder: Folder? = nil
local playClientSoundRemote: RemoteEvent? = nil
local prepareGiftPurchaseRemote: RemoteFunction? = nil
local giftPurchaseResultRemote: RemoteEvent? = nil
local giftGlobalUpdateConnection: RBXScriptConnection? = nil
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

local function ensurePrepareGiftPurchaseRemote(): RemoteFunction
	local folder = ensureRemotesFolder()

	if prepareGiftPurchaseRemote and prepareGiftPurchaseRemote.Parent == folder then
		return prepareGiftPurchaseRemote
	end

	local remote = RemoteUtil.EnsureRemoteFunction(folder, PREPARE_GIFT_PURCHASE_REMOTE_NAME)
	prepareGiftPurchaseRemote = remote
	return remote
end

local function ensureGiftPurchaseResultRemote(): RemoteEvent
	local folder = ensureRemotesFolder()

	if giftPurchaseResultRemote and giftPurchaseResultRemote.Parent == folder then
		return giftPurchaseResultRemote
	end

	local remote = RemoteUtil.EnsureRemoteEvent(folder, GIFT_PURCHASE_RESULT_REMOTE_NAME)
	giftPurchaseResultRemote = remote
	return remote
end

local function sendClientSound(player: Player, soundName: string)
	if typeof(soundName) ~= "string" or soundName == "" then
		return
	end

	ensurePlayClientSoundRemote():FireClient(player, soundName)
end

local function emptyLog()
	return { products = {}, passes = {}, pendingGifts = {}, giftsReceived = {} }
end

local function ensureLogTables(purchaseLog)
	purchaseLog = if typeof(purchaseLog) == "table" then purchaseLog else emptyLog()
	purchaseLog.products = if typeof(purchaseLog.products) == "table" then purchaseLog.products else {}
	purchaseLog.passes = if typeof(purchaseLog.passes) == "table" then purchaseLog.passes else {}
	purchaseLog.pendingGifts = if typeof(purchaseLog.pendingGifts) == "table" then purchaseLog.pendingGifts else {}
	purchaseLog.giftsReceived = if typeof(purchaseLog.giftsReceived) == "table" then purchaseLog.giftsReceived else {}
	return purchaseLog
end

local function getLog(player)
	return ensureLogTables(DataService:Get(player, PURCHASE_LOG_FIELD))
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

local function hasProductReceipt(player, productId, purchaseId)
	if purchaseId == nil then
		return false
	end

	local productLog = getLog(player).products[tostring(productId)]
	return typeof(productLog) == "table" and productLog[purchaseId] ~= nil
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
		purchaseLog = ensureLogTables(purchaseLog)

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
			return false, err
		end
	end
	return true, nil
end

local function fireGiftResult(player: Player, payload)
	ensureGiftPurchaseResultRemote():FireClient(player, payload)
end

local function getGiftProductKeyForTarget(targetKey: string): string?
	local key = RobuxPurchases.GiftProductsByTargetKey and RobuxPurchases.GiftProductsByTargetKey[targetKey]
	if typeof(key) == "string" and key ~= "" then
		return key
	end

	for productKey, config in pairs(RobuxPurchases.Products) do
		if config.giftTargetKey == targetKey then
			return productKey
		end
	end

	return nil
end

local function getGiftTargetForProduct(productId: number): (string?, string?, any?)
	local config = RobuxPurchases.ProductsById[productId]
	if config and typeof(config.giftTargetKey) == "string" and config.giftTargetKey ~= "" then
		return config.giftTargetKey, config.key, config
	end

	local targetKey = RobuxPurchases.GiftingMap[productId]
	if typeof(targetKey) ~= "string" or targetKey == "" then
		return nil, nil, config
	end

	local giftProductKey = getGiftProductKeyForTarget(targetKey)
	return targetKey, giftProductKey, config
end

local function normalizeGiftUserId(value): number
	local userId = math.floor(tonumber(value) or 0)
	return if userId > 0 then userId else 0
end

local function getProfileKey(userId: number): string
	return "Player_" .. tostring(userId)
end

local function profileDataOwnsTarget(data, targetKey: string): boolean
	if typeof(data) ~= "table" then
		return false
	end

	local requirements = GIFT_OWNERSHIP_REQUIREMENTS[targetKey]
	if typeof(requirements) ~= "table" then
		return false
	end

	local abilityId = requirements.abilityId
	if typeof(abilityId) == "string" and abilityId ~= "" then
		local ownedAbilities = data.ownedAbilities
		if typeof(ownedAbilities) ~= "table" or ownedAbilities[abilityId] ~= true then
			return false
		end
	end

	local bombSkinId = requirements.bombSkinId
	if typeof(bombSkinId) == "string" and bombSkinId ~= "" then
		local ownedBombSkins = data.ownedBombSkins
		if typeof(ownedBombSkins) ~= "table" or ownedBombSkins[bombSkinId] ~= true then
			return false
		end
	end

	return true
end

local function viewOfflineProfileData(userId: number): (any?, string?)
	local ok, profileOrError = pcall(function()
		return DataService.ProfileStore:ViewProfileAsync(getProfileKey(userId))
	end)
	if not ok then
		return nil, "Recipient profile could not be checked."
	end
	if not profileOrError or typeof(profileOrError.Data) ~= "table" then
		return nil, "Recipient profile is unavailable."
	end

	local data = profileOrError.Data
	if typeof(profileOrError.Release) == "function" then
		pcall(function()
			profileOrError:Release()
		end)
	end

	return data, nil
end

local function recipientOwnsTarget(recipientUserId: number, targetKey: string): (boolean?, string?)
	local recipient = Players:GetPlayerByUserId(recipientUserId)
	if recipient then
		local data = DataService:Get(recipient)
		if typeof(data) ~= "table" then
			return nil, "Recipient data is still loading."
		end
		return profileDataOwnsTarget(data, targetKey), nil
	end

	local data, err = viewOfflineProfileData(recipientUserId)
	if not data then
		return nil, err
	end

	return profileDataOwnsTarget(data, targetKey), nil
end

local function iterFriendPages(pages)
	return coroutine.wrap(function()
		while true do
			for _, item in ipairs(pages:GetCurrentPage()) do
				coroutine.yield(item)
			end
			if pages.IsFinished then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
	end)
end

local function isAllowedGiftRecipient(sender: Player, recipientUserId: number): (boolean, string?)
	if Players:GetPlayerByUserId(recipientUserId) then
		return true, nil
	end

	local ok, pagesOrError = pcall(function()
		return Players:GetFriendsAsync(sender.UserId)
	end)
	if not ok then
		return false, "Could not verify that recipient is your friend."
	end

	for item in iterFriendPages(pagesOrError) do
		if normalizeGiftUserId(item.Id) == recipientUserId then
			return true, nil
		end
	end

	return false, "Recipient must be in this server or on your friends list."
end

local function resolveUsername(userId: number): string
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return player.Name
	end

	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and typeof(name) == "string" and name ~= "" then
		return name
	end

	return "User" .. tostring(userId)
end

local function makeGiftFailure(code: string, message: string)
	return {
		ok = false,
		code = code,
		message = message,
	}
end

local function setPendingGift(player: Player, pendingGift)
	DataService:Set(player, PURCHASE_LOG_FIELD, function(purchaseLog)
		purchaseLog = ensureLogTables(purchaseLog)
		purchaseLog.pendingGifts[tostring(pendingGift.giftProductId)] = pendingGift
		return purchaseLog
	end)
end

local function clearPendingGift(player: Player, giftProductId: number)
	DataService:Set(player, PURCHASE_LOG_FIELD, function(purchaseLog)
		purchaseLog = ensureLogTables(purchaseLog)
		purchaseLog.pendingGifts[tostring(giftProductId)] = nil
		return purchaseLog
	end)
end

local function getPendingGift(player: Player, giftProductId: number)
	local pending = getLog(player).pendingGifts[tostring(giftProductId)]
	return if typeof(pending) == "table" then pending else nil
end

local function markGiftReceived(player: Player, purchaseId: any, payload)
	if purchaseId == nil then
		return
	end

	DataService:Set(player, PURCHASE_LOG_FIELD, function(purchaseLog)
		purchaseLog = ensureLogTables(purchaseLog)
		purchaseLog.giftsReceived[tostring(purchaseId)] = {
			targetProductKey = payload.targetProductKey,
			giftProductKey = payload.giftProductKey,
			senderUserId = payload.senderUserId,
			senderUsername = payload.senderUsername,
			receivedAt = os.time(),
		}
		return purchaseLog
	end)
end

local function hasReceivedGift(player: Player, purchaseId: any): boolean
	if purchaseId == nil then
		return false
	end
	return getLog(player).giftsReceived[tostring(purchaseId)] ~= nil
end

local function grantProductToPlayer(player: Player, targetKey: string, context): (boolean, string?)
	local config = RobuxPurchases.Products[targetKey]
	if not config then
		return false, "Unknown gift target."
	end

	local ok, err = callConfigHook("product", targetKey, "onProcessed", player, context)
	if not ok then
		return false, tostring(err or "Gift grant failed.")
	end

	PurchaseReceipt.PurchaseProcessed:Fire(player, targetKey, context)
	sendClientSound(player, "Kaching")
	return true, nil
end

local function prepareGiftPurchase(player: Player, request)
	if typeof(request) ~= "table" then
		return makeGiftFailure("InvalidRequest", "Gift request is invalid.")
	end

	local recipientUserId = normalizeGiftUserId(request.recipientUserId)
	local targetKey = if typeof(request.targetProductKey) == "string" then request.targetProductKey else ""
	local giftProductKey = if typeof(request.giftProductKey) == "string" then request.giftProductKey else ""

	if recipientUserId <= 0 then
		return makeGiftFailure("InvalidRecipient", "Choose someone to gift first.")
	end
	if recipientUserId == player.UserId then
		return makeGiftFailure("SelfGift", "You can't gift yourself.")
	end
	if not SUPPORTED_GIFT_TARGETS[targetKey] then
		return makeGiftFailure("UnsupportedGift", "This item cannot be gifted yet.")
	end

	local targetConfig = RobuxPurchases.Products[targetKey]
	local giftConfig = RobuxPurchases.Products[giftProductKey]
	if not targetConfig or not giftConfig or giftConfig.giftTargetKey ~= targetKey then
		return makeGiftFailure("InvalidProduct", "Gift product is not configured correctly.")
	end

	local giftProductId = math.floor(tonumber(giftConfig.id) or 0)
	if giftProductId <= 0 then
		return makeGiftFailure("ProductUnavailable", "Gift product is unavailable.")
	end

	local allowed, allowedMessage = isAllowedGiftRecipient(player, recipientUserId)
	if not allowed then
		return makeGiftFailure("RecipientNotAllowed", allowedMessage or "Recipient is not eligible.")
	end

	local owns, ownsMessage = recipientOwnsTarget(recipientUserId, targetKey)
	if owns == true then
		return makeGiftFailure("AlreadyOwned", "That player already owns this bundle.")
	elseif owns == nil then
		return makeGiftFailure("OwnershipUnavailable", ownsMessage or "Recipient ownership could not be checked.")
	end

	local recipientUsername = resolveUsername(recipientUserId)
	local pendingGift = {
		giftProductId = giftProductId,
		giftProductKey = giftProductKey,
		targetProductKey = targetKey,
		targetProductId = targetConfig.id,
		recipientUserId = recipientUserId,
		recipientUsername = recipientUsername,
		preparedAt = os.time(),
	}
	setPendingGift(player, pendingGift)

	return {
		ok = true,
		productId = giftProductId,
		giftProductKey = giftProductKey,
		targetProductKey = targetKey,
		recipientUserId = recipientUserId,
		recipientUsername = recipientUsername,
	}
end

local function processReceivedGift(player: Player, payload)
	if typeof(payload) ~= "table" then
		return
	end

	local purchaseId = payload.purchaseId
	if hasReceivedGift(player, purchaseId) then
		return
	end

	local targetKey = payload.targetProductKey
	if typeof(targetKey) ~= "string" or not RobuxPurchases.Products[targetKey] then
		warn("[PurchaseReceipt] Received invalid gift target:", tostring(targetKey))
		return
	end

	local context = {
		kind = "product",
		key = targetKey,
		id = payload.targetProductId,
		purchaseId = purchaseId,
		source = "gift",
		isNew = true,
		senderUserId = payload.senderUserId,
		senderUsername = payload.senderUsername,
		giftProductKey = payload.giftProductKey,
	}

	local ok, err = grantProductToPlayer(player, targetKey, context)
	if not ok then
		warn(("[PurchaseReceipt] Failed to grant gift %s to %s: %s"):format(
			tostring(purchaseId),
			player.Name,
			tostring(err)
		))
		return
	end

	markGiftReceived(player, purchaseId, payload)
	local senderName = if typeof(payload.senderUsername) == "string" and payload.senderUsername ~= ""
		then payload.senderUsername
		else "a friend"
	Notify.Send(player, string.format("You received %s from @%s!", getPurchaseDisplayName("product", targetKey, nil), senderName), {
		color = "Green",
	})
end

local function handleGlobalUpdate(player: Player, _profile, updateData)
	if typeof(updateData) ~= "table" or updateData.updateType ~= GIFT_UPDATE_TYPE then
		return
	end

	processReceivedGift(player, updateData.data)
end

local function ensureGlobalGiftListener()
	if giftGlobalUpdateConnection then
		return
	end

	giftGlobalUpdateConnection = DataService.GlobalUpdateProcessed:Connect(handleGlobalUpdate)
end

ensureGlobalGiftListener()

local function processGiftReceipt(player: Player, productId: number, purchaseId: string, targetKey: string, giftProductKey: string)
	if hasProductReceipt(player, productId, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local pendingGift = getPendingGift(player, productId)
	if not pendingGift then
		warn(("[PurchaseReceipt] Gift receipt %s for %s has no pending gift; retrying."):format(
			tostring(purchaseId),
			player.Name
		))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if pendingGift.giftProductKey ~= giftProductKey or pendingGift.targetProductKey ~= targetKey then
		warn(("[PurchaseReceipt] Gift receipt %s did not match pending gift for %s; retrying."):format(
			tostring(purchaseId),
			player.Name
		))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local preparedAt = tonumber(pendingGift.preparedAt) or 0
	if preparedAt > 0 and os.time() - preparedAt > PENDING_GIFT_TTL_SECONDS then
		Notify.Send(player, "Gift purchase expired before it could be processed. Please contact support.", { color = "Red" })
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local recipientUserId = normalizeGiftUserId(pendingGift.recipientUserId)
	if recipientUserId <= 0 or recipientUserId == player.UserId then
		warn(("[PurchaseReceipt] Gift receipt %s has invalid recipient; retrying."):format(tostring(purchaseId)))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local targetConfig = RobuxPurchases.Products[targetKey]
	local recipient = Players:GetPlayerByUserId(recipientUserId)
	local payload = {
		purchaseId = purchaseId,
		giftProductId = productId,
		giftProductKey = giftProductKey,
		targetProductKey = targetKey,
		targetProductId = targetConfig and targetConfig.id or nil,
		senderUserId = player.UserId,
		senderUsername = player.Name,
		recipientUserId = recipientUserId,
		recipientUsername = pendingGift.recipientUsername,
		sentAt = os.time(),
	}

	if recipient then
		local context = {
			kind = "product",
			key = targetKey,
			id = payload.targetProductId,
			purchaseId = purchaseId,
			source = "gift",
			isNew = true,
			senderUserId = player.UserId,
			senderUsername = player.Name,
			giftProductKey = giftProductKey,
		}
		local ok, err = grantProductToPlayer(recipient, targetKey, context)
		if not ok then
			warn(("[PurchaseReceipt] Gift receipt %s online grant failed: %s"):format(tostring(purchaseId), tostring(err)))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		markGiftReceived(recipient, purchaseId, payload)
		Notify.Send(recipient, string.format("You received %s from @%s!", getPurchaseDisplayName("product", targetKey, nil), player.Name), {
			color = "Green",
		})
	else
		local ok, err = pcall(function()
			DataService:SendGlobalUpdate(player, recipientUserId, GIFT_UPDATE_TYPE, payload)
		end)
		if not ok then
			warn(("[PurchaseReceipt] Gift receipt %s global update failed: %s"):format(tostring(purchaseId), tostring(err)))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	logPurchase(player, productId, purchaseId, { via = "gift" })
	clearPendingGift(player, productId)

	local recipientName = tostring(pendingGift.recipientUsername or ("User" .. recipientUserId))
	Notify.Send(player, string.format("Gift sent to @%s!", recipientName), { color = "Green" })
	fireGiftResult(player, {
		ok = true,
		purchaseId = purchaseId,
		productId = productId,
		targetProductKey = targetKey,
		recipientUserId = recipientUserId,
		recipientUsername = recipientName,
		message = string.format("Gift sent to @%s!", recipientName),
	})

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function processProductReceipt(receiptInfo)
	local userId = receiptInfo.PlayerId
	local productId = receiptInfo.ProductId
	local purchaseId = receiptInfo.PurchaseId

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local giftTargetKey, giftProductKey = getGiftTargetForProduct(productId)
	if giftTargetKey and giftProductKey then
		return processGiftReceipt(player, productId, purchaseId, giftTargetKey, giftProductKey)
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

	if isNew then
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
	ensureGiftPurchaseResultRemote()
	ensurePrepareGiftPurchaseRemote().OnServerInvoke = prepareGiftPurchase
	ensureGlobalGiftListener()
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
