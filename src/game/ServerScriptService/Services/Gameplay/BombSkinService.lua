local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local DataService = require(script.Parent.DataService)

local OWNED_KEY = Schema.OwnedBombSkins and Schema.OwnedBombSkins.key or "ownedBombSkins"
local COPIES_KEY = Schema.BombSkinCopies and Schema.BombSkinCopies.key or "bombSkinCopies"
local EQUIPPED_KEY = Schema.EquippedBombSkin and Schema.EquippedBombSkin.key or "equippedBombSkin"
local DEFAULT_SKIN_ID = BombSkinConfig.DefaultSkinId
local EQUIPPED_ATTR = BombSkinConfig.AttributeName
local REMOTES_FOLDER_NAME = BombSkinConfig.RemotesFolderName
local REQUEST_REMOTE_NAME = BombSkinConfig.InventoryRequestRemoteName
local ACTIONS = BombSkinConfig.InventoryActions

local MAX_REQUESTS_PER_SECOND = 12

type RequestWindow = {
	startedAt: number,
	count: number,
}

local BombSkinService = {}

local requestRemote: RemoteEvent? = nil
local requestWindows: { [Player]: RequestWindow } = {}

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

local function ensureRequestRemote(): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(REQUEST_REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = REQUEST_REMOTE_NAME
	remote.Parent = folder
	return remote
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

local function normalizeOwnedSkins(value): ({ [string]: boolean }, boolean)
	local owned = {}
	local changed = false

	if typeof(value) ~= "table" then
		changed = value ~= nil
	else
		for key, child in pairs(value) do
			local rawSkinId = nil
			if typeof(key) == "string" and child == true then
				rawSkinId = key
			elseif typeof(child) == "string" then
				rawSkinId = child
			else
				changed = true
			end

			local skinId = BombSkinConfig.NormalizeSkinId(rawSkinId)
			if skinId ~= "" then
				owned[skinId] = true
				if skinId ~= rawSkinId or child ~= true then
					changed = true
				end
			else
				changed = true
			end
		end
	end

	if owned[DEFAULT_SKIN_ID] ~= true then
		owned[DEFAULT_SKIN_ID] = true
		changed = true
	end

	return owned, changed
end

local function normalizeSkinCopies(value, ownedSkins): ({ [string]: number }, boolean)
	local copies = {}
	local changed = false

	if typeof(value) ~= "table" then
		changed = value ~= nil
	else
		for rawSkinId, rawCount in pairs(value) do
			local skinId = BombSkinConfig.NormalizeSkinId(rawSkinId)
			local count = math.floor(tonumber(rawCount) or 0)
			if skinId ~= "" and count > 0 then
				copies[skinId] = (copies[skinId] or 0) + count
				if skinId ~= rawSkinId or count ~= rawCount then
					changed = true
				end
			else
				changed = true
			end
		end
	end

	for skinId in pairs(ownedSkins or {}) do
		if (copies[skinId] or 0) < 1 then
			copies[skinId] = 1
			changed = true
		end
	end

	return copies, changed
end

local function ownedMatches(left, right): boolean
	if typeof(right) ~= "table" then
		return false
	end

	for skinId in pairs(left) do
		if right[skinId] ~= true then
			return false
		end
	end
	for skinId in pairs(right) do
		if left[skinId] ~= true then
			return false
		end
	end
	return true
end

local function copiesMatch(left, right): boolean
	if typeof(right) ~= "table" then
		return false
	end

	for skinId, count in pairs(left) do
		if right[skinId] ~= count then
			return false
		end
	end
	for skinId in pairs(right) do
		if left[skinId] == nil then
			return false
		end
	end
	return true
end

local function resolveEquippedSkin(value, ownedSkins): (string, boolean)
	local skinId = BombSkinConfig.NormalizeSkinId(value)
	if skinId ~= "" and ownedSkins[skinId] == true then
		return skinId, skinId ~= value
	end

	return DEFAULT_SKIN_ID, value ~= DEFAULT_SKIN_ID
end

local function setEquippedAttribute(player: Player, skinId: string)
	player:SetAttribute(EQUIPPED_ATTR, skinId)
end

local function respond(player: Player, request, ok: boolean, code: string, message: string?)
	local remote = requestRemote
	if not remote then
		return
	end

	local action = nil
	local skinId = nil
	if typeof(request) == "table" then
		action = request.action
		skinId = request.skinId
	end

	remote:FireClient(player, {
		action = action,
		skinId = skinId,
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

local function sanitizePlayerData(player: Player): string
	local data = DataService:Get(player)
	if typeof(data) ~= "table" then
		setEquippedAttribute(player, DEFAULT_SKIN_ID)
		return DEFAULT_SKIN_ID
	end

	local ownedSkins, ownedChanged = normalizeOwnedSkins(data[OWNED_KEY])
	local skinCopies, copiesChanged = normalizeSkinCopies(data[COPIES_KEY], ownedSkins)
	local equippedSkin, equippedChanged = resolveEquippedSkin(data[EQUIPPED_KEY], ownedSkins)

	if ownedChanged or not ownedMatches(ownedSkins, data[OWNED_KEY] or {}) then
		DataService:Set(player, OWNED_KEY, ownedSkins)
	end
	if copiesChanged or not copiesMatch(skinCopies, data[COPIES_KEY] or {}) then
		DataService:Set(player, COPIES_KEY, skinCopies)
	end
	if equippedChanged or data[EQUIPPED_KEY] ~= equippedSkin then
		DataService:Set(player, EQUIPPED_KEY, equippedSkin)
	end

	setEquippedAttribute(player, equippedSkin)
	return equippedSkin
end

function BombSkinService:GetEquippedSkinId(player: Player): string
	if not (player and player.Parent == Players) then
		return DEFAULT_SKIN_ID
	end

	local skinId = BombSkinConfig.NormalizeSkinId(player:GetAttribute(EQUIPPED_ATTR))
	if skinId ~= "" then
		return skinId
	end

	return sanitizePlayerData(player)
end

function BombSkinService:GetOwnedSkins(player: Player): { [string]: boolean }
	local data = DataService:Get(player)
	if typeof(data) ~= "table" then
		return {
			[DEFAULT_SKIN_ID] = true,
		}
	end

	local ownedSkins = normalizeOwnedSkins(data[OWNED_KEY])
	return ownedSkins
end

function BombSkinService:GetSkinCopies(player: Player): { [string]: number }
	local ownedSkins = self:GetOwnedSkins(player)
	local data = DataService:Get(player)
	if typeof(data) ~= "table" then
		return {
			[DEFAULT_SKIN_ID] = 1,
		}
	end

	local skinCopies = normalizeSkinCopies(data[COPIES_KEY], ownedSkins)
	return skinCopies
end

function BombSkinService:EquipSkin(player: Player, rawSkinId: any): (boolean, string?, any?)
	if not (player and player.Parent == Players) then
		return false, "Target player is not in this server", nil
	end

	local skinId = BombSkinConfig.NormalizeSkinId(rawSkinId)
	local definition = BombSkinConfig.GetDefinition(skinId)
	if not definition then
		return false, "Unknown bomb skin: " .. tostring(rawSkinId), nil
	end

	local ownedSkins = self:GetOwnedSkins(player)
	if ownedSkins[skinId] ~= true then
		return false, "You do not own this skin.", nil
	end

	DataService:Set(player, EQUIPPED_KEY, skinId)
	setEquippedAttribute(player, skinId)

	return true, nil, {
		skinId = skinId,
		definition = definition,
	}
end

function BombSkinService:GrantSkin(player: Player, rawSkinId: any, source: string?): (boolean, any)
	if not (player and player.Parent == Players) then
		return false, "Target player is not in this server"
	end

	local skinId = BombSkinConfig.NormalizeSkinId(rawSkinId)
	local definition = BombSkinConfig.GetDefinition(skinId)
	if not definition then
		return false, "Unknown bomb skin: " .. tostring(rawSkinId)
	end

	local ownedBefore = self:GetOwnedSkins(player)
	local wasOwned = ownedBefore[skinId] == true
	DataService:Set(player, OWNED_KEY, function(currentValue)
		local ownedSkins = normalizeOwnedSkins(currentValue)
		ownedSkins[skinId] = true
		return ownedSkins
	end)

	local copyCount = 1
	DataService:Set(player, COPIES_KEY, function(currentValue)
		local skinCopies = normalizeSkinCopies(currentValue, ownedBefore)
		local previousCount = skinCopies[skinId] or (if wasOwned then 1 else 0)
		copyCount = previousCount + 1
		skinCopies[skinId] = copyCount
		return skinCopies
	end)

	return true, {
		skinId = skinId,
		definition = definition,
		source = source,
		isNew = not wasOwned,
		copyCount = copyCount,
	}
end

function BombSkinService:AdminGrantAndEquipSkin(player: Player, rawSkinId: any): (boolean, string?)
	local ok, grantResult = self:GrantSkin(player, rawSkinId, "Admin")
	if not ok then
		return false, grantResult
	end

	DataService:Set(player, EQUIPPED_KEY, grantResult.skinId)
	setEquippedAttribute(player, grantResult.skinId)

	return true, "Equipped bomb skin " .. grantResult.definition.displayName .. " for " .. player.Name
end

local function resolveRequest(request)
	if typeof(request) ~= "table" then
		return nil
	end

	local action = request.action
	if not isPlainString(action, BombSkinConfig.MaxInventoryActionLength) then
		return nil
	end
	if action ~= ACTIONS.Equip then
		return nil
	end

	local skinId = request.skinId
	if isPlainString(skinId, BombSkinConfig.MaxSkinIdLength) then
		skinId = BombSkinConfig.NormalizeSkinId(skinId)
	else
		skinId = ""
	end

	local definition = if skinId ~= "" then BombSkinConfig.GetDefinition(skinId) else nil
	if not (definition and BombSkinConfig.IsCatalogSkin(skinId)) then
		return nil
	end

	return {
		action = action,
		skinId = skinId,
		definition = definition,
	}
end

local function handleRequest(player: Player, rawRequest)
	if isRateLimited(player) then
		return
	end

	local request = resolveRequest(rawRequest)
	if not request then
		fail(player, rawRequest, "InvalidRequest", "Invalid skin request.")
		return
	end

	local ok, message = BombSkinService:EquipSkin(player, request.skinId)
	if not ok then
		fail(player, request, "EquipFailed", message or "Skin equip failed.")
		return
	end

	respond(player, request, true, "Equipped")
end

function BombSkinService:OnStart()
	requestRemote = ensureRequestRemote()
	requestRemote.OnServerEvent:Connect(handleRequest)
end

function BombSkinService:OnPlayerAdded(player: Player)
	sanitizePlayerData(player)
end

function BombSkinService:OnPlayerRemoving(player: Player)
	requestWindows[player] = nil
	player:SetAttribute(EQUIPPED_ATTR, nil)
end

return BombSkinService
