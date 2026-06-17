local BombSkinIconConfig = require(script.Parent.BombSkinIconConfig)

local BombSkinConfig = {}

BombSkinConfig.DefaultSkinId = "Default"
BombSkinConfig.AttributeName = "EquippedBombSkin"
BombSkinConfig.MaxSkinIdLength = 64
BombSkinConfig.RemotesFolderName = "Remotes"
BombSkinConfig.InventoryRequestRemoteName = "BombSkinInventoryRequest"
BombSkinConfig.MaxInventoryActionLength = 32

BombSkinConfig.InventoryActions = table.freeze({
	Equip = "Equip",
})

BombSkinConfig.Rarities = table.freeze({
	Common = "Common",
	Rare = "Rare",
	Epic = "Epic",
	Legendary = "Legendary",
	Mythic = "Mythic",
	Divine = "Divine",
	Secret = "Secret",
})

BombSkinConfig.RarityOrder = table.freeze({
	"Common",
	"Rare",
	"Epic",
	"Legendary",
	"Mythic",
	"Divine",
	"Secret",
})

local catalog = {
	{
		id = "Default",
		displayName = "Default",
		assetFolder = "Default",
		rarity = "Common",
		description = "The standard bomb shell issued to every battler.",
	},
	{
		id = "Red",
		displayName = "Red",
		assetFolder = "Red",
		rarity = "Common",
		description = "A bold red shell for clean, classic pressure.",
	},
	{
		id = "Blue",
		displayName = "Blue",
		assetFolder = "Blue",
		rarity = "Common",
		description = "A crisp blue shell for a cooler take on the classic bomb.",
	},
	{
		id = "Gold",
		displayName = "Gold",
		assetFolder = "Gold",
		rarity = "Common",
		description = "A polished gold shell for players who want every throw to shine.",
	},
	{
		id = "Rusty",
		displayName = "Rusty",
		assetFolder = "Rusty",
		rarity = "Common",
		description = "A worn metal shell that still gets the job done.",
	},
	{
		id = "Toy",
		displayName = "Toy",
		assetFolder = "Toy",
		rarity = "Common",
		description = "A playful toy shell hiding very real danger.",
	},
	{
		id = "TNT",
		displayName = "TNT",
		assetFolder = "TNT",
		rarity = "Common",
		description = "A classic explosive bundle with unmistakable warning energy.",
	},
	{
		id = "Cannonball",
		displayName = "Cannonball",
		assetFolder = "Cannonball",
		rarity = "Common",
		description = "A heavy iron look built for direct hits.",
	},
	{
		id = "WaterBalloon",
		displayName = "Water Balloon",
		assetFolder = "Water Balloon",
		rarity = "Rare",
		description = "A splashy shell that looks soft until the fuse runs out.",
	},
	{
		id = "Paint",
		displayName = "Paint",
		assetFolder = "Paint",
		rarity = "Rare",
		description = "A paint-splashed shell for messy, colorful fights.",
	},
	{
		id = "Smoke",
		displayName = "Smoke",
		assetFolder = "Smoke",
		rarity = "Rare",
		description = "A hazy shell wrapped in drifting battlefield style.",
	},
	{
		id = "Firework",
		displayName = "Firework",
		assetFolder = "Firework",
		rarity = "Rare",
		description = "A celebratory shell that promises a bright finish.",
	},
	{
		id = "Beehive",
		displayName = "Beehive",
		assetFolder = "Beehive",
		rarity = "Rare",
		description = "A buzzing hive shell that warns everyone to keep distance.",
	},
	{
		id = "Chicken",
		displayName = "Chicken",
		assetFolder = "Chicken",
		rarity = "Rare",
		description = "A chaotic farmyard shell with no sense of self-preservation.",
	},
	{
		id = "Pizza",
		displayName = "Pizza",
		assetFolder = "Pizza",
		rarity = "Rare",
		description = "A hot slice of chaos served with extra blast radius attitude.",
	},
	{
		id = "Snowball",
		displayName = "Snowball",
		assetFolder = "Snowball",
		rarity = "Epic",
		description = "A frosty shell that brings winter energy to every throw.",
	},
	{
		id = "Slime",
		displayName = "Slime",
		assetFolder = "Slime",
		rarity = "Epic",
		description = "A gooey shell that looks like it should splash before it explodes.",
	},
	{
		id = "Disco",
		displayName = "Disco",
		assetFolder = "Disco",
		rarity = "Epic",
		description = "A flashy bomb shell that turns the arena into a dance floor.",
	},
	{
		id = "RubberDuck",
		displayName = "Rubber Duck",
		assetFolder = "Rubber Duck",
		rarity = "Epic",
		description = "A playful duck shell that makes danger look harmless.",
	},
	{
		id = "Pumpkin",
		displayName = "Pumpkin",
		assetFolder = "Pumpkin",
		rarity = "Epic",
		description = "A carved seasonal shell with a wicked grin.",
	},
	{
		id = "Meteor",
		displayName = "Meteor",
		assetFolder = "Meteor",
		rarity = "Legendary",
		description = "A scorched space-rock shell made for dramatic impacts.",
	},
	{
		id = "Ghost",
		displayName = "Ghost",
		assetFolder = "Ghost",
		rarity = "Legendary",
		description = "A spectral shell that gives each throw a haunted look.",
	},
	{
		id = "Shark",
		displayName = "Shark",
		assetFolder = "Shark",
		rarity = "Legendary",
		description = "A sharp predator shell that turns throws into feeding time.",
	},
	{
		id = "TreasureChest",
		displayName = "Treasure Chest",
		assetFolder = "Treasure Chest",
		rarity = "Legendary",
		description = "A loot-stuffed shell that makes every throw feel valuable.",
	},
	{
		id = "UFO",
		displayName = "UFO",
		assetFolder = "UFO",
		rarity = "Mythic",
		description = "An alien-styled bomb shell with an otherworldly silhouette.",
	},
	{
		id = "FatGuy",
		displayName = "Fat Guy",
		assetFolder = "Fat Guy",
		rarity = "Divine",
		description = "A bulky shell with a heavy presence in the arena.",
	},
	{
		id = "HollowPurple",
		displayName = "Hollow Purple",
		assetFolder = "Hollow Purple",
		rarity = "Divine",
		catalogOrder = 25.5,
	},
	{
		id = "EventHorizon",
		displayName = "Event Horizon",
		assetFolder = "Event Horizon",
		rarity = "Secret",
		catalogOrder = 26,
		description = "A cosmic shell that makes every detonation feel inevitable.",
	},
	{
		id = "Nuke",
		displayName = "Nuke",
		assetFolder = "Nuke",
		rarity = "Secret",
		catalogOrder = 27,
		description = "A legendary shell built to make the whole lobby notice.",
	},
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
	local catalogOrder = entry.catalogOrder
	if catalogOrder == nil then
		if entry.id == BombSkinConfig.DefaultSkinId then
			catalogOrder = 0
		else
			catalogOrder = index - 1
		end
	end

	local definition = table.freeze({
		id = entry.id,
		displayName = entry.displayName,
		assetFolder = entry.assetFolder,
		rarity = entry.rarity,
		description = entry.description,
		iconImage = BombSkinIconConfig.GetIconImage(entry.id),
		catalogOrder = catalogOrder,
	})
	definitions[entry.id] = definition
	table.insert(catalogIds, entry.id)
	aliases[getAliasKey(entry.id)] = entry.id
	aliases[getAliasKey(entry.displayName)] = entry.id
	aliases[getAliasKey(entry.assetFolder)] = entry.id
end

aliases[getAliasKey("Nuke_2")] = "Nuke"

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

function BombSkinConfig.GetIconImage(skinId: any): string?
	local definition = BombSkinConfig.GetDefinition(skinId)
	return if definition then definition.iconImage else nil
end

function BombSkinConfig.GetArchivedIconImage(skinId: any): string?
	if typeof(skinId) ~= "string" then
		return nil
	end

	return BombSkinIconConfig.GetArchivedIconImage(skinId)
end

function BombSkinConfig.IsCatalogSkin(skinId: any): boolean
	return BombSkinConfig.GetDefinition(skinId) ~= nil
end

function BombSkinConfig.GetCatalogIds(): { string }
	return table.clone(catalogIds)
end

BombSkinConfig.Definitions = table.freeze(definitions)
BombSkinConfig.Catalog = table.freeze(catalogIds)
BombSkinConfig.IconConfig = BombSkinIconConfig

return table.freeze(BombSkinConfig)
