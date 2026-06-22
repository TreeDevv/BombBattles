local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FinisherConfig = {}

FinisherConfig.DefaultFinisherId = ""
FinisherConfig.AttributeName = "EquippedFinisher"
FinisherConfig.MaxFinisherIdLength = 64
FinisherConfig.RemotesFolderName = "Remotes"
FinisherConfig.PlayedRemoteName = "FinisherPlayed"

local AUTHORED_ORDER = table.freeze({
	"Atomic",
	"Confetti",
	"Evaporation",
	"Explosion",
	"Flashbang",
	"Frostburst",
	"Light",
	"Lightning",
	"Savage",
	"SoulReaper",
	"Essence",
})

local rarityByFinisherId = table.freeze({
	Atomic = "Common",
	Confetti = "Common",
	Evaporation = "Common",
	Explosion = "Common",
	Flashbang = "Rare",
	Frostburst = "Rare",
	Light = "Rare",
	Lightning = "Epic",
	Savage = "Epic",
	SoulReaper = "Legendary",
	Essence = "Legendary",
})

local REMOVED_FINISHER_IDS = table.freeze({
	Tornado = true,
})

local icons = {
	Atomic = "rbxassetid://75997776806570",
	Confetti = "rbxassetid://79724344709822",
	Essence = "rbxassetid://133584471585372",
	Evaporation = "rbxassetid://101858483084552",
	Explosion = "rbxassetid://123789047398632",
	Flashbang = "rbxassetid://85856168079516",
	Frostburst = "rbxassetid://96100402352291",
	Light = "rbxassetid://101807095901714",
	Lightning = "rbxassetid://138786882454087",
	Savage = "rbxassetid://124053141692963",
	SoulReaper = "rbxassetid://90311611825385",
}

local function getAliasKey(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end

	return string.lower((string.gsub(value, "[^%w]", "")))
end

local function getAssetsRoot(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return assets and assets:FindFirstChild("Finishers") or nil
end

local function getKnownNames(): { string }
	local names = {}
	local seen = {}
	local assetsRoot = getAssetsRoot()

	if assetsRoot then
		for _, finisherId in ipairs(AUTHORED_ORDER) do
			if not REMOVED_FINISHER_IDS[finisherId] and not seen[finisherId] and assetsRoot:FindFirstChild(finisherId) then
				table.insert(names, finisherId)
				seen[finisherId] = true
			end
		end

		for _, child in ipairs(assetsRoot:GetChildren()) do
			if not REMOVED_FINISHER_IDS[child.Name] and not seen[child.Name] then
				table.insert(names, child.Name)
				seen[child.Name] = true
			end
		end

		return names
	end

	for _, finisherId in ipairs(AUTHORED_ORDER) do
		if not REMOVED_FINISHER_IDS[finisherId] and not seen[finisherId] then
			table.insert(names, finisherId)
			seen[finisherId] = true
		end
	end

	return names
end

local catalogOrderByFinisherId = {}
for index, finisherId in ipairs(AUTHORED_ORDER) do
	catalogOrderByFinisherId[finisherId] = index
end
catalogOrderByFinisherId = table.freeze(catalogOrderByFinisherId)

function FinisherConfig.GetAssetsRoot(): Instance?
	return getAssetsRoot()
end

function FinisherConfig.NormalizeFinisherId(finisherId: any): string
	if typeof(finisherId) ~= "string" or finisherId == "" or #finisherId > FinisherConfig.MaxFinisherIdLength then
		return ""
	end

	local targetKey = getAliasKey(finisherId)
	if targetKey == "" then
		return ""
	end

	for _, knownName in ipairs(getKnownNames()) do
		if getAliasKey(knownName) == targetKey then
			return knownName
		end
	end

	return ""
end

function FinisherConfig.GetAsset(finisherId: any): Instance?
	local normalizedFinisherId = FinisherConfig.NormalizeFinisherId(finisherId)
	if normalizedFinisherId == "" then
		return nil
	end

	local assetsRoot = getAssetsRoot()
	return assetsRoot and assetsRoot:FindFirstChild(normalizedFinisherId) or nil
end

function FinisherConfig.GetIconImage(finisherId: any): string?
	local normalizedFinisherId = FinisherConfig.NormalizeFinisherId(finisherId)
	if normalizedFinisherId == "" then
		return nil
	end

	return icons[normalizedFinisherId]
end

function FinisherConfig.GetDefinition(finisherId: any)
	local normalizedFinisherId = FinisherConfig.NormalizeFinisherId(finisherId)
	if normalizedFinisherId == "" then
		return nil
	end
	local asset = FinisherConfig.GetAsset(normalizedFinisherId)
	if not asset then
		return nil
	end

	return table.freeze({
		id = normalizedFinisherId,
		displayName = normalizedFinisherId,
		assetName = normalizedFinisherId,
		asset = asset,
		rarity = rarityByFinisherId[normalizedFinisherId] or "Common",
		iconImage = FinisherConfig.GetIconImage(normalizedFinisherId),
		catalogOrder = catalogOrderByFinisherId[normalizedFinisherId] or math.huge,
	})
end

function FinisherConfig.IsKnownFinisherId(finisherId: any): boolean
	return FinisherConfig.GetDefinition(finisherId) ~= nil
end

function FinisherConfig.GetCatalogIds(): { string }
	return getKnownNames()
end

FinisherConfig.Icons = table.freeze(icons)
FinisherConfig.Rarities = rarityByFinisherId

return table.freeze(FinisherConfig)
