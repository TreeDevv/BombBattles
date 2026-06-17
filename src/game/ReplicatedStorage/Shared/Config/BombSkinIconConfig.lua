local BombSkinIconConfig = {}

local icons = {
	Default = "rbxassetid://112184464455965",
	Ghost = "rbxassetid://121317684202145",
	Pizza = "rbxassetid://108013565269646",
	Red = "rbxassetid://72985554991898",
	Cannonball = "rbxassetid://107504780514271",
	UFO = "rbxassetid://100120510742069",
	Slime = "rbxassetid://117851012548592",
	Snowball = "rbxassetid://128960525512793",
	Disco = "rbxassetid://89047457211561",
	RubberDuck = "rbxassetid://92738673119949",
	Meteor = "rbxassetid://84224655165572",
	Pumpkin = "rbxassetid://93118021388732",
	Blue = "rbxassetid://93000687181112",
	TreasureChest = "rbxassetid://139166088005660",
	Chicken = "rbxassetid://104572841319756",
	Beehive = "rbxassetid://94602507566144",
	Paint = "rbxassetid://94752366203347",
	Firework = "rbxassetid://92294335942021",
	WaterBalloon = "rbxassetid://93230000148289",
	TNT = "rbxassetid://138130241539769",
	EventHorizon = "rbxassetid://106484205535599",
	Smoke = "rbxassetid://139198785900668",
	Rusty = "rbxassetid://111202257460621",
	Gold = "rbxassetid://125777910504344",
	Toy = "rbxassetid://119441858039488",
	Nuke = "rbxassetid://125852408372171",
	Shark = "rbxassetid://124959579197911",
	FatGuy = "rbxassetid://107317017502986",
}

local archivedIcons = {
	HollowPurple = "rbxassetid://126087450437587",
}

local iconAliases = {}
local archivedIconAliases = {}

local function getAliasKey(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end

	return string.lower((string.gsub(value, "[^%w]", "")))
end

local function addAlias(aliases: { [string]: string }, alias: string, skinId: string)
	aliases[getAliasKey(alias)] = skinId
end

for skinId in pairs(icons) do
	addAlias(iconAliases, skinId, skinId)
end

addAlias(iconAliases, "Event Horizon", "EventHorizon")
addAlias(iconAliases, "Event_Horizon", "EventHorizon")
addAlias(iconAliases, "Fat Guy", "FatGuy")
addAlias(iconAliases, "Fat_Guy", "FatGuy")
addAlias(iconAliases, "Nuke_2", "Nuke")
addAlias(iconAliases, "Rubber Duck", "RubberDuck")
addAlias(iconAliases, "Rubber_Duck", "RubberDuck")
addAlias(iconAliases, "Treasure Chest", "TreasureChest")
addAlias(iconAliases, "Treasure_Chest", "TreasureChest")
addAlias(iconAliases, "Water Balloon", "WaterBalloon")
addAlias(iconAliases, "Water_Balloon", "WaterBalloon")

for skinId in pairs(archivedIcons) do
	addAlias(archivedIconAliases, skinId, skinId)
end

addAlias(archivedIconAliases, "Hollow Purple", "HollowPurple")
addAlias(archivedIconAliases, "Hollow_Purple", "HollowPurple")

function BombSkinIconConfig.GetIconImage(skinId: any): string?
	if typeof(skinId) ~= "string" then
		return nil
	end

	local normalizedSkinId = iconAliases[getAliasKey(skinId)]
	return if normalizedSkinId then icons[normalizedSkinId] else nil
end

function BombSkinIconConfig.GetArchivedIconImage(skinId: any): string?
	if typeof(skinId) ~= "string" then
		return nil
	end

	local normalizedSkinId = archivedIconAliases[getAliasKey(skinId)]
	return if normalizedSkinId then archivedIcons[normalizedSkinId] else nil
end

function BombSkinIconConfig.GetIcons(): { [string]: string }
	return table.clone(icons)
end

function BombSkinIconConfig.GetArchivedIcons(): { [string]: string }
	return table.clone(archivedIcons)
end

BombSkinIconConfig.Icons = table.freeze(icons)
BombSkinIconConfig.ArchivedIcons = table.freeze(archivedIcons)
BombSkinIconConfig.IconAliases = table.freeze(iconAliases)
BombSkinIconConfig.ArchivedIconAliases = table.freeze(archivedIconAliases)

return table.freeze(BombSkinIconConfig)
