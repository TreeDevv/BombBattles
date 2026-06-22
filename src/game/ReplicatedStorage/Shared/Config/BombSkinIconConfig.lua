local BombSkinIconConfig = {}

local icons = {
	Default = "rbxassetid://112184464455965",
	Red = "rbxassetid://71293779484632",
	Blue = "rbxassetid://136349207297773",
	Rusty = "rbxassetid://111490800094903",
	Toy = "rbxassetid://106602275657078",
	TNT = "rbxassetid://86937336244768",
	Cannonball = "rbxassetid://87660896999009",
	WaterBalloon = "rbxassetid://105082749460502",
	Paint = "rbxassetid://137238989130297",
	Smoke = "rbxassetid://106321296285028",
	Firework = "rbxassetid://95505454938665",
	Beehive = "rbxassetid://104188729786725",
	Chicken = "rbxassetid://114474665085007",
	Pizza = "rbxassetid://83670286703206",
	Snowball = "rbxassetid://112758032741859",
	Slime = "rbxassetid://83108723563228",
	RubberDuck = "rbxassetid://106483697466531",
	Disco = "rbxassetid://124938911233454",
	Pumpkin = "rbxassetid://118317426473189",
	Meteor = "rbxassetid://88753226580637",
	Ghost = "rbxassetid://113197926864579",
	Shark = "rbxassetid://97890152431889",
	TreasureChest = "rbxassetid://73171907878677",
	UFO = "rbxassetid://100989491332496",
	Nuke = "rbxassetid://100190229096228",
	FatGuy = "rbxassetid://116354763358266",
	HollowPurple = "rbxassetid://111981190835677",
	Gold = "rbxassetid://115895528667213",
	EventHorizon = "rbxassetid://102755267228381",
}

local archivedIcons = {}

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
addAlias(iconAliases, "Hollow Purple", "HollowPurple")
addAlias(iconAliases, "Hollow_Purple", "HollowPurple")
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
