local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local Globals = require(ReplicatedStorage.Shared.Config.Lists.Globals)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)

local DataService = require(script.Parent.DataService)
local AbilityService = require(script.Parent.AbilityService)

local REMOTES_FOLDER_NAME = AbilityConfig.RemotesFolderName
local REQUEST_REMOTE_NAME = AbilityConfig.InventoryRequestRemoteName
local ACTIONS = AbilityConfig.InventoryActions

local OWNED_KEY = Schema.OwnedAbilities and Schema.OwnedAbilities.key or "ownedAbilities"
local LOADOUT_KEY = Schema.AbilityLoadout and Schema.AbilityLoadout.key or "abilityLoadout"
local CASH_KEY = Schema.Cash and Schema.Cash.key or "cash"

local MAX_REQUESTS_PER_SECOND = 12
local DEFAULT_ABILITY_BY_SLOT = AbilityConfig.DefaultLoadout

type RequestWindow = {
	startedAt: number,
	count: number,
}

local AbilityInventoryService = {}

local requestRemote: RemoteEvent? = nil
local requestWindows: { [Player]: RequestWindow } = {}
local roundService = nil

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, REMOTES_FOLDER_NAME)
end

local function ensureRequestRemote(): RemoteEvent
	return RemoteUtil.EnsureRemoteEvent(ensureRemotesFolder(), REQUEST_REMOTE_NAME)
end

local function isPlainString(value: any, maxLength: number): boolean
	return typeof(value) == "string" and value ~= "" and #value <= maxLength
end

local function isRateLimited(player: Player): boolean
	local currentTime = os.clock()
	local window = requestWindows[player]
	if not window or currentTime - window.startedAt >= 1 then
		requestWindows[player] = {
			startedAt = currentTime,
			count = 1,
		}
		return false
	end

	window.count += 1
	return window.count > MAX_REQUESTS_PER_SECOND
end

local function getRoundService()
	if not roundService then
		roundService = require(script.Parent.RoundService)
	end

	return roundService
end

local function isInventoryLocked(player: Player): boolean
	local service = getRoundService()
	local state = service:GetState()
	local stateName = typeof(state) == "table" and state.state or nil
	local lockedRoundState = stateName == RoundStates.AssigningTeams
		or stateName == RoundStates.RoundStarting
		or stateName == RoundStates.Active
	return lockedRoundState and service:IsPlayerInCurrentRound(player)
end

local function normalizeOwnedAbilities(value): ({ [string]: boolean }, boolean)
	local owned = {}
	local changed = false

	if typeof(value) ~= "table" then
		return owned, value ~= nil
	end

	for key, child in pairs(value) do
		local abilityId = nil
		if typeof(key) == "string" and child == true then
			abilityId = key
		elseif typeof(child) == "string" then
			abilityId = child
		else
			changed = true
		end

		if abilityId then
			local normalizedAbilityId = AbilityConfig.NormalizeAbilityId(abilityId)
			if AbilityConfig.IsCatalogAbility(normalizedAbilityId) then
				owned[normalizedAbilityId] = true
				if normalizedAbilityId ~= abilityId or child ~= true then
					changed = true
				end
			else
				changed = true
			end
		end
	end

	return owned, changed
end

local function addDefaultOwnedAbilities(ownedAbilities: { [string]: boolean }): boolean
	local changed = false
	for abilityId in pairs(AbilityConfig.StarterAbilities) do
		local definition = AbilityConfig.GetDefinition(abilityId)
		if definition and AbilityConfig.IsCatalogAbility(abilityId) and ownedAbilities[definition.id] ~= true then
			ownedAbilities[definition.id] = true
			changed = true
		end
	end
	return changed
end

local function ownedMatches(left, right): boolean
	if typeof(right) ~= "table" then
		return false
	end

	for abilityId in pairs(left) do
		if right[abilityId] ~= true then
			return false
		end
	end
	for abilityId in pairs(right) do
		if left[abilityId] ~= true then
			return false
		end
	end
	return true
end

local function sanitizeLoadout(value, ownedAbilities): ({ [string]: string }, boolean)
	local loadout = {}
	local changed = typeof(value) ~= "table"

	for _, slot in ipairs(AbilityConfig.SlotOrder) do
		local rawAbilityId = if typeof(value) == "table" and typeof(value[slot]) == "string" then value[slot] else ""
		local abilityId = AbilityConfig.NormalizeAbilityId(rawAbilityId)
		local definition = AbilityConfig.GetDefinition(abilityId)

		if abilityId ~= "" and definition and definition.slot == slot and ownedAbilities[abilityId] == true then
			loadout[slot] = definition.id
		else
			local defaultAbilityId = AbilityConfig.NormalizeAbilityId(DEFAULT_ABILITY_BY_SLOT[slot])
			local defaultDefinition = AbilityConfig.GetDefinition(defaultAbilityId)
			if defaultDefinition and defaultDefinition.slot == slot and ownedAbilities[defaultDefinition.id] == true then
				loadout[slot] = defaultDefinition.id
			else
				loadout[slot] = ""
			end
		end

		if rawAbilityId ~= loadout[slot] then
			changed = true
		end
	end

	return loadout, changed
end

local function loadoutMatches(left, right): boolean
	if typeof(right) ~= "table" then
		return false
	end

	for _, slot in ipairs(AbilityConfig.SlotOrder) do
		if left[slot] ~= right[slot] then
			return false
		end
	end
	return true
end

local function getOwnedAbilities(player: Player): { [string]: boolean }
	local owned = normalizeOwnedAbilities(DataService:Get(player, OWNED_KEY))
	return owned
end

local function respond(player: Player, request, ok: boolean, code: string, message: string?)
	local remote = requestRemote
	if not remote then
		return
	end

	local action = nil
	local abilityId = nil
	local slot = nil
	if typeof(request) == "table" then
		action = request.action
		abilityId = request.abilityId
		slot = request.slot
	end

	remote:FireClient(player, {
		action = action,
		abilityId = abilityId,
		slot = slot,
		ok = ok,
		code = code,
		message = message,
	})
end

local function fail(player: Player, request, code: string, message: string?)
	respond(player, request, false, code, message)
	if message and message ~= "" then
		Notify.Send(player, message, { color = "Red" })
	end
end

local function resolveRequest(request)
	if typeof(request) ~= "table" then
		return nil
	end

	local action = request.action
	if not isPlainString(action, AbilityConfig.MaxInventoryActionLength) then
		return nil
	end
	if action ~= ACTIONS.Buy and action ~= ACTIONS.Equip and action ~= ACTIONS.Unequip then
		return nil
	end

	local abilityId = request.abilityId
	if isPlainString(abilityId, AbilityConfig.MaxAbilityIdLength) then
		abilityId = AbilityConfig.NormalizeAbilityId(abilityId)
	else
		abilityId = ""
	end

	local slot = request.slot
	if typeof(slot) ~= "string" or not AbilityConfig.IsKnownSlot(slot) then
		slot = nil
	end

	local definition = if abilityId ~= "" then AbilityConfig.GetDefinition(abilityId) else nil
	if action ~= ACTIONS.Unequip and not (definition and AbilityConfig.IsCatalogAbility(abilityId)) then
		return nil
	end
	if action == ACTIONS.Unequip and abilityId ~= "" and not (definition and AbilityConfig.IsCatalogAbility(abilityId)) then
		return nil
	end

	if definition and slot and definition.slot ~= slot then
		return nil
	end
	if not slot and definition then
		slot = definition.slot
	end
	if action == ACTIONS.Unequip and not slot then
		return nil
	end

	return {
		action = action,
		abilityId = abilityId,
		slot = slot,
		definition = definition,
	}
end

local function buyAbility(player: Player, request)
	local abilityId = request.abilityId
	local definition = request.definition
	local ownedAbilities = getOwnedAbilities(player)
	if ownedAbilities[abilityId] == true then
		respond(player, request, true, "AlreadyOwned")
		return
	end

	local purchaseKind = definition.purchaseKind or AbilityConfig.PurchaseKinds.Coins
	if purchaseKind == AbilityConfig.PurchaseKinds.Starter then
		fail(player, request, "StarterAbility", "This starter skill is already unlocked.")
		return
	elseif purchaseKind == AbilityConfig.PurchaseKinds.Bundle then
		local bundleLabel = if typeof(definition.bundleLabel) == "string" and definition.bundleLabel ~= ""
			then definition.bundleLabel
			else "Bundle only"
		fail(player, request, "BundleOnly", bundleLabel .. ".")
		return
	elseif purchaseKind ~= AbilityConfig.PurchaseKinds.Coins then
		fail(player, request, "Unavailable", "This skill cannot be bought with coins.")
		return
	end

	local price = math.max(math.floor(tonumber(definition.price) or 0), 0)
	if price <= 0 then
		fail(player, request, "Unavailable", "This skill cannot be bought with coins.")
		return
	end

	local spent = false
	local cash = tonumber(DataService:Get(player, CASH_KEY)) or 0
	if cash < price then
		fail(player, request, "InsufficientCash", "Not enough cash.")
		return
	end

	DataService:Set(player, CASH_KEY, function(currentValue)
		local currentCash = tonumber(currentValue) or 0
		if currentCash < price then
			return currentCash
		end
		spent = true
		return currentCash - price
	end)

	if not spent then
		fail(player, request, "InsufficientCash", "Not enough cash.")
		return
	end

	local ownedAfterSpend = getOwnedAbilities(player)
	if ownedAfterSpend[abilityId] == true then
		DataService:Set(player, CASH_KEY, function(currentValue)
			return (tonumber(currentValue) or 0) + price
		end)
		respond(player, request, true, "AlreadyOwned")
		return
	end

	DataService:Set(player, OWNED_KEY, function(currentValue)
		local currentOwned = normalizeOwnedAbilities(currentValue)
		currentOwned[abilityId] = true
		return currentOwned
	end)

	local priceText = if price > 0 then Globals.formatNumber(price, true, true) else "$0"
	respond(player, request, true, "Bought", "Bought for " .. priceText .. ".")
end

local function equipAbility(player: Player, request)
	local abilityId = request.abilityId
	local definition = request.definition
	local slot = definition.slot
	local ownedAbilities = getOwnedAbilities(player)
	if ownedAbilities[abilityId] ~= true then
		fail(player, request, "NotOwned", "Buy this skill first.")
		return
	end

	DataService:Set(player, LOADOUT_KEY, function(currentValue)
		local loadout = sanitizeLoadout(currentValue, ownedAbilities)
		loadout[slot] = abilityId
		return loadout
	end)
	AbilityService:SetEquippedAbility(player, slot, abilityId)
	respond(player, request, true, "Equipped")
end

local function unequipAbility(player: Player, request)
	local slot = request.slot
	local ownedAbilities = getOwnedAbilities(player)
	local clearedAbilityId = ""

	DataService:Set(player, LOADOUT_KEY, function(currentValue)
		local loadout = sanitizeLoadout(currentValue, ownedAbilities)
		if request.abilityId == "" or loadout[slot] == request.abilityId then
			clearedAbilityId = loadout[slot]
			loadout[slot] = ""
		end
		return loadout
	end)

	if clearedAbilityId ~= "" or request.abilityId == "" then
		AbilityService:SetEquippedAbility(player, slot, "")
	end
	respond(player, request, true, if clearedAbilityId ~= "" then "Unequipped" else "AlreadyUnequipped")
end

local function handleRequest(player: Player, rawRequest)
	if isRateLimited(player) then
		return
	end

	local request = resolveRequest(rawRequest)
	if not request then
		fail(player, rawRequest, "InvalidRequest", "Invalid skill request.")
		return
	end
	if isInventoryLocked(player) then
		fail(player, request, "InventoryLocked", "Inventory is locked during battle.")
		return
	end

	if request.action == ACTIONS.Buy then
		buyAbility(player, request)
	elseif request.action == ACTIONS.Equip then
		equipAbility(player, request)
	elseif request.action == ACTIONS.Unequip then
		unequipAbility(player, request)
	end
end

function AbilityInventoryService:OnStart()
	requestRemote = ensureRequestRemote()
	requestRemote.OnServerEvent:Connect(handleRequest)
end

function AbilityInventoryService:GrantAbility(player: Player, rawAbilityId: any, source: string?): (boolean, any)
	if not (player and player.Parent == Players) then
		return false, "Target player is not in this server"
	end

	local abilityId = if isPlainString(rawAbilityId, AbilityConfig.MaxAbilityIdLength)
		then AbilityConfig.NormalizeAbilityId(rawAbilityId)
		else ""
	local definition = if abilityId ~= "" then AbilityConfig.GetDefinition(abilityId) else nil
	if not (definition and AbilityConfig.IsCatalogAbility(abilityId)) then
		return false, "Unknown ability: " .. tostring(rawAbilityId)
	end

	local ownedBefore = getOwnedAbilities(player)
	local wasOwned = ownedBefore[abilityId] == true
	DataService:Set(player, OWNED_KEY, function(currentValue)
		local ownedAbilities = normalizeOwnedAbilities(currentValue)
		ownedAbilities[abilityId] = true
		return ownedAbilities
	end)

	return true, {
		abilityId = abilityId,
		definition = definition,
		source = source,
		isNew = not wasOwned,
	}
end

function AbilityInventoryService:OnPlayerAdded(player: Player)
	local data = DataService:Get(player)
	if typeof(data) ~= "table" then
		return
	end

	local ownedAbilities, ownedChanged = normalizeOwnedAbilities(data[OWNED_KEY])
	local defaultOwnedChanged = addDefaultOwnedAbilities(ownedAbilities)
	local loadout, loadoutChanged = sanitizeLoadout(data[LOADOUT_KEY], ownedAbilities)

	if ownedChanged or defaultOwnedChanged or not ownedMatches(ownedAbilities, data[OWNED_KEY] or {}) then
		DataService:Set(player, OWNED_KEY, ownedAbilities)
	end
	if loadoutChanged or not loadoutMatches(loadout, data[LOADOUT_KEY] or {}) then
		DataService:Set(player, LOADOUT_KEY, loadout)
	end

	AbilityService:SetLoadout(player, loadout)
end

function AbilityInventoryService:OnPlayerRemoving(player: Player)
	requestWindows[player] = nil
end

return AbilityInventoryService
