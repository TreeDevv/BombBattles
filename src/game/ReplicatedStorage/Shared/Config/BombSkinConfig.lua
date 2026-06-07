local BombSkinConfig = {}

BombSkinConfig.DefaultSkinId = "Default"
BombSkinConfig.AttributeName = "EquippedBombSkin"
BombSkinConfig.MaxSkinIdLength = 64

local catalog = {
	{ id = "Default", displayName = "Default", assetFolder = "Default" },
	{ id = "Ghost", displayName = "Ghost", assetFolder = "Ghost" },
	{ id = "Pizza", displayName = "Pizza", assetFolder = "Pizza" },
	{ id = "Red", displayName = "Red", assetFolder = "Red" },
	{ id = "Cannonball", displayName = "Cannonball", assetFolder = "Cannonball" },
	{ id = "UFO", displayName = "UFO", assetFolder = "UFO" },
	{ id = "Slime", displayName = "Slime", assetFolder = "Slime" },
	{ id = "Snowball", displayName = "Snowball", assetFolder = "Snowball" },
	{ id = "Disco", displayName = "Disco", assetFolder = "Disco" },
	{ id = "RubberDuck", displayName = "Rubber Duck", assetFolder = "Rubber Duck" },
	{ id = "Meteor", displayName = "Meteor", assetFolder = "Meteor" },
	{ id = "Pumpkin", displayName = "Pumpkin", assetFolder = "Pumpkin" },
	{ id = "Blue", displayName = "Blue", assetFolder = "Blue" },
	{ id = "TreasureChest", displayName = "Treasure Chest", assetFolder = "Treasure Chest" },
	{ id = "Chicken", displayName = "Chicken", assetFolder = "Chicken" },
	{ id = "Beehive", displayName = "Beehive", assetFolder = "Beehive" },
	{ id = "Paint", displayName = "Paint", assetFolder = "Paint" },
	{ id = "Firework", displayName = "Firework", assetFolder = "Firework" },
	{ id = "WaterBalloon", displayName = "Water Balloon", assetFolder = "Water Balloon" },
	{ id = "TNT", displayName = "TNT", assetFolder = "TNT" },
	{ id = "EventHorizon", displayName = "Event Horizon", assetFolder = "Event Horizon" },
	{ id = "Smoke", displayName = "Smoke", assetFolder = "Smoke" },
	{ id = "Rusty", displayName = "Rusty", assetFolder = "Rusty" },
	{ id = "Gold", displayName = "Gold", assetFolder = "Gold" },
	{ id = "Toy", displayName = "Toy", assetFolder = "Toy" },
	{ id = "Nuke", displayName = "Nuke", assetFolder = "Nuke" },
	{ id = "Shark", displayName = "Shark", assetFolder = "Shark" },
}

local definitions = {}
local catalogIds = {}
local aliases = {}

local function getAliasKey(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end

	return string.lower((string.gsub(value, "[^%w]", "")))
end

for index, entry in ipairs(catalog) do
	local definition = table.freeze({
		id = entry.id,
		displayName = entry.displayName,
		assetFolder = entry.assetFolder,
		catalogOrder = index,
	})
	definitions[entry.id] = definition
	table.insert(catalogIds, entry.id)
	aliases[getAliasKey(entry.id)] = entry.id
	aliases[getAliasKey(entry.displayName)] = entry.id
	aliases[getAliasKey(entry.assetFolder)] = entry.id
end

function BombSkinConfig.NormalizeSkinId(skinId: any): string
	if typeof(skinId) ~= "string" or skinId == "" or #skinId > BombSkinConfig.MaxSkinIdLength then
		return ""
	end

	return aliases[getAliasKey(skinId)] or ""
end

function BombSkinConfig.GetDefinition(skinId: any)
	local normalizedSkinId = BombSkinConfig.NormalizeSkinId(skinId)
	if normalizedSkinId == "" then
		return nil
	end

	return definitions[normalizedSkinId]
end

function BombSkinConfig.IsCatalogSkin(skinId: any): boolean
	return BombSkinConfig.GetDefinition(skinId) ~= nil
end

function BombSkinConfig.GetCatalogIds(): { string }
	return table.clone(catalogIds)
end

BombSkinConfig.Definitions = table.freeze(definitions)
BombSkinConfig.Catalog = table.freeze(catalogIds)

return table.freeze(BombSkinConfig)
