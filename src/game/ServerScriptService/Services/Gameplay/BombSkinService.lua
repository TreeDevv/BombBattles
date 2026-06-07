local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local DataService = require(script.Parent.DataService)

local OWNED_KEY = Schema.OwnedBombSkins and Schema.OwnedBombSkins.key or "ownedBombSkins"
local EQUIPPED_KEY = Schema.EquippedBombSkin and Schema.EquippedBombSkin.key or "equippedBombSkin"
local DEFAULT_SKIN_ID = BombSkinConfig.DefaultSkinId
local EQUIPPED_ATTR = BombSkinConfig.AttributeName

local BombSkinService = {}

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

local function sanitizePlayerData(player: Player): string
	local data = DataService:Get(player)
	if typeof(data) ~= "table" then
		setEquippedAttribute(player, DEFAULT_SKIN_ID)
		return DEFAULT_SKIN_ID
	end

	local ownedSkins, ownedChanged = normalizeOwnedSkins(data[OWNED_KEY])
	local equippedSkin, equippedChanged = resolveEquippedSkin(data[EQUIPPED_KEY], ownedSkins)

	if ownedChanged or not ownedMatches(ownedSkins, data[OWNED_KEY] or {}) then
		DataService:Set(player, OWNED_KEY, ownedSkins)
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

function BombSkinService:AdminGrantAndEquipSkin(player: Player, rawSkinId: any): (boolean, string?)
	if not (player and player.Parent == Players) then
		return false, "Target player is not in this server"
	end

	local skinId = BombSkinConfig.NormalizeSkinId(rawSkinId)
	local definition = BombSkinConfig.GetDefinition(skinId)
	if not definition then
		return false, "Unknown bomb skin: " .. tostring(rawSkinId)
	end

	DataService:Set(player, OWNED_KEY, function(currentValue)
		local ownedSkins = normalizeOwnedSkins(currentValue)
		ownedSkins[skinId] = true
		return ownedSkins
	end)
	DataService:Set(player, EQUIPPED_KEY, skinId)
	setEquippedAttribute(player, skinId)

	return true, "Equipped bomb skin " .. definition.displayName .. " for " .. player.Name
end

function BombSkinService:OnPlayerAdded(player: Player)
	sanitizePlayerData(player)
end

function BombSkinService:OnPlayerRemoving(player: Player)
	player:SetAttribute(EQUIPPED_ATTR, nil)
end

return BombSkinService
