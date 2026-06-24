local POTGCutsceneConfig = require(script.Parent.POTGCutsceneConfig)

local HighlightIntroConfig = {}

HighlightIntroConfig.DefaultHighlightIntroId = POTGCutsceneConfig.DefaultCutsceneId
HighlightIntroConfig.AttributeName = "EquippedHighlightIntro"
HighlightIntroConfig.MaxHighlightIntroIdLength = 64
HighlightIntroConfig.RemotesFolderName = "Remotes"
HighlightIntroConfig.InventoryRequestRemoteName = "HighlightIntroInventoryRequest"
HighlightIntroConfig.MaxInventoryActionLength = 32
HighlightIntroConfig.PlaceholderIconImage = "rbxassetid://131142466377523"

HighlightIntroConfig.InventoryActions = table.freeze({
	Equip = "Equip",
})

HighlightIntroConfig.Rarities = table.freeze({
	Common = "Common",
	Rare = "Rare",
	Epic = "Epic",
	Legendary = "Legendary",
	Mythic = "Mythic",
	Divine = "Divine",
	Secret = "Secret",
})

HighlightIntroConfig.RarityOrder = table.freeze({
	"Common",
	"Rare",
	"Epic",
	"Legendary",
	"Mythic",
	"Divine",
	"Secret",
})

local AUTHORED_ORDER = table.freeze({
	"DefaultHighlightIntro",
	"HollowPurple",
	"TooFast",
})

local displayNames = table.freeze({
	DefaultHighlightIntro = "Default",
	HollowPurple = "Hollow Purple",
	TooFast = "Too Fast",
})

local descriptions = table.freeze({
	DefaultHighlightIntro = "The standard highlight intro.",
	HollowPurple = "A dramatic violet highlight intro.",
	TooFast = "A fast-paced highlight intro.",
})

local catalogOrderByIntroId = {}
for index, introId in ipairs(AUTHORED_ORDER) do
	catalogOrderByIntroId[introId] = index
end
catalogOrderByIntroId = table.freeze(catalogOrderByIntroId)

local function getAliasKey(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end

	return string.lower((string.gsub(value, "[^%w]", "")))
end

local function splitDisplayName(introId: string): string
	local text = string.gsub(introId, "HighlightIntro$", "")
	text = string.gsub(text, "(%l)(%u)", "%1 %2")
	return if text ~= "" then text else introId
end

local function getKnownNames(): { string }
	local names = {}
	local seen = {}

	for _, introId in ipairs(AUTHORED_ORDER) do
		if POTGCutsceneConfig.Cutscenes[introId] and not seen[introId] then
			table.insert(names, introId)
			seen[introId] = true
		end
	end

	local extras = {}
	for introId in pairs(POTGCutsceneConfig.Cutscenes) do
		if not seen[introId] then
			table.insert(extras, introId)
		end
	end
	table.sort(extras)

	for _, introId in ipairs(extras) do
		table.insert(names, introId)
	end

	return names
end

function HighlightIntroConfig.NormalizeHighlightIntroId(highlightIntroId: any): string
	if typeof(highlightIntroId) ~= "string" or highlightIntroId == "" or #highlightIntroId > HighlightIntroConfig.MaxHighlightIntroIdLength then
		return ""
	end

	local targetKey = getAliasKey(highlightIntroId)
	if targetKey == "" then
		return ""
	end

	for _, knownName in ipairs(getKnownNames()) do
		local displayName = displayNames[knownName] or splitDisplayName(knownName)
		if getAliasKey(knownName) == targetKey or getAliasKey(displayName) == targetKey then
			return knownName
		end
	end

	return ""
end

function HighlightIntroConfig.GetDefinition(highlightIntroId: any)
	local normalizedIntroId = HighlightIntroConfig.NormalizeHighlightIntroId(highlightIntroId)
	if normalizedIntroId == "" then
		return nil
	end

	local cutscene = POTGCutsceneConfig.GetCutscene(normalizedIntroId)
	if not cutscene or cutscene.id ~= normalizedIntroId then
		return nil
	end

	return table.freeze({
		id = normalizedIntroId,
		displayName = displayNames[normalizedIntroId] or splitDisplayName(normalizedIntroId),
		description = descriptions[normalizedIntroId] or "A highlight intro for play of the game.",
		cutscene = cutscene,
		cutsceneId = normalizedIntroId,
		rarity = "Common",
		iconImage = HighlightIntroConfig.PlaceholderIconImage,
		catalogOrder = catalogOrderByIntroId[normalizedIntroId] or math.huge,
	})
end

function HighlightIntroConfig.GetIconImage(highlightIntroId: any): string?
	local definition = HighlightIntroConfig.GetDefinition(highlightIntroId)
	return if definition then definition.iconImage else nil
end

function HighlightIntroConfig.IsKnownHighlightIntroId(highlightIntroId: any): boolean
	return HighlightIntroConfig.GetDefinition(highlightIntroId) ~= nil
end

function HighlightIntroConfig.GetCatalogIds(): { string }
	return getKnownNames()
end

return table.freeze(HighlightIntroConfig)
