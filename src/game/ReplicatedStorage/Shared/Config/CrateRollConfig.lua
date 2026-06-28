local CrateRollConfig = {}

CrateRollConfig.RemotesFolderName = "Remotes"
CrateRollConfig.RequestRemoteName = "CrateRollRequest"
CrateRollConfig.ResultRemoteName = "CrateRollResult"
CrateRollConfig.MaxCrateIdLength = 64
CrateRollConfig.MaxRequestsPerSecond = 6
CrateRollConfig.HistoryLimit = 25
CrateRollConfig.PromptTag = "CrateOpenPrompt"
CrateRollConfig.PromptCrateIdAttribute = "CrateId"
CrateRollConfig.PromptFreeRollsEnabled = true
CrateRollConfig.PromptFreeRollSource = "PromptFree"

CrateRollConfig.Actions = table.freeze({
	GetState = "GetState",
	RollCash = "RollCash",
	ClearPromptPurchase = "ClearPromptPurchase",
})

CrateRollConfig.RewardTypes = table.freeze({
	BombSkin = "BombSkin",
	Finisher = "Finisher",
})

CrateRollConfig.Rarities = table.freeze({
	Common = "Common",
	Rare = "Rare",
	Epic = "Epic",
	Legendary = "Legendary",
	Mythic = "Mythic",
})

CrateRollConfig.RarityOrder = table.freeze({
	"Common",
	"Rare",
	"Epic",
	"Legendary",
	"Mythic",
})

local crates = {
	{
		id = "Basic",
		displayName = "Basic Crate",
		description = "A starter crate with common and rare bomb skins.",
		rewardType = CrateRollConfig.RewardTypes.BombSkin,
		cashPrice = 500,
		rarityWeights = {
			Common = 70,
			Rare = 30,
		},
	},
	{
		id = "Rare",
		displayName = "Rare Crate",
		description = "A stronger crate with better rare and epic odds.",
		rewardType = CrateRollConfig.RewardTypes.BombSkin,
		cashPrice = 350,
		rarityWeights = {
			Common = 20,
			Rare = 72,
			Epic = 8,
		},
	},
	{
		id = "Premium",
		displayName = "Premium Crate",
		description = "A premium crate with the best epic and legendary odds.",
		rewardType = CrateRollConfig.RewardTypes.BombSkin,
		productKey = "PremiumCrateRoll",
		rarityWeights = {
			Rare = 65,
			Epic = 25,
			Legendary = 10,
		},
	},
	{
		id = "FinisherBasic",
		displayName = "Normal Finisher Crate",
		description = "A starter crate with common and rare finishers.",
		rewardType = CrateRollConfig.RewardTypes.Finisher,
		cashPrice = 500,
		showcaseFinisherIds = {
			"Explosion",
			"Confetti",
			"Atomic",
			"Evaporation",
			"Flashbang",
			"Frostburst",
			"Light",
		},
		rarityWeights = {
			Common = 70,
			Rare = 30,
		},
	},
	{
		id = "FinisherPremium",
		displayName = "Premium Finisher Crate",
		description = "A premium crate with better finisher odds.",
		rewardType = CrateRollConfig.RewardTypes.Finisher,
		productKey = "PremiumFinisherCrateRoll",
		showcaseFinisherIds = {
			"Lightning",
			"Savage",
			"SoulReaper",
			"Essence",
			"Flashbang",
			"Frostburst",
			"Light",
		},
		rarityWeights = {
			Rare = 65,
			Epic = 25,
			Legendary = 10,
		},
	},
}

local definitions = {}
local crateIds = {}
local aliases = {}
local crateByProductKey = {}

local function getAliasKey(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end

	return string.lower((string.gsub(value, "[^%w]", "")))
end

for index, entry in ipairs(crates) do
	local definition = table.freeze({
		id = entry.id,
		displayName = entry.displayName,
		description = entry.description,
		rewardType = entry.rewardType or CrateRollConfig.RewardTypes.BombSkin,
		cashPrice = entry.cashPrice,
		productKey = entry.productKey,
		rarityWeights = table.freeze(table.clone(entry.rarityWeights or {})),
		showcaseFinisherIds = table.freeze(table.clone(entry.showcaseFinisherIds or {})),
		catalogOrder = index,
	})
	definitions[entry.id] = definition
	table.insert(crateIds, entry.id)
	aliases[getAliasKey(entry.id)] = entry.id
	aliases[getAliasKey(entry.displayName)] = entry.id
	if typeof(entry.productKey) == "string" and entry.productKey ~= "" then
		crateByProductKey[entry.productKey] = definition
	end
end

function CrateRollConfig.NormalizeCrateId(crateId: any): string
	if typeof(crateId) ~= "string" or crateId == "" or #crateId > CrateRollConfig.MaxCrateIdLength then
		return ""
	end

	return aliases[getAliasKey(crateId)] or ""
end

function CrateRollConfig.GetDefinition(crateId: any)
	local normalizedCrateId = CrateRollConfig.NormalizeCrateId(crateId)
	if normalizedCrateId == "" then
		return nil
	end

	return definitions[normalizedCrateId]
end

function CrateRollConfig.GetCrateForProductKey(productKey: any)
	if typeof(productKey) ~= "string" then
		return nil
	end

	return crateByProductKey[productKey]
end

function CrateRollConfig.GetCrateIds(): { string }
	return table.clone(crateIds)
end

function CrateRollConfig.GetCratesPayload()
	local payload = {}
	for _, crateId in ipairs(crateIds) do
		local definition = definitions[crateId]
		table.insert(payload, {
			id = definition.id,
			displayName = definition.displayName,
			description = definition.description,
			rewardType = definition.rewardType,
			cashPrice = definition.cashPrice,
			productKey = definition.productKey,
			rarityWeights = table.clone(definition.rarityWeights),
			showcaseFinisherIds = table.clone(definition.showcaseFinisherIds),
		})
	end
	return payload
end

CrateRollConfig.Definitions = table.freeze(definitions)
CrateRollConfig.CrateIds = table.freeze(crateIds)

return table.freeze(CrateRollConfig)
