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
	"Tornado",
	"Essence",
})

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
			if not seen[finisherId] and assetsRoot:FindFirstChild(finisherId) then
				table.insert(names, finisherId)
				seen[finisherId] = true
			end
		end

		for _, child in ipairs(assetsRoot:GetChildren()) do
			if not seen[child.Name] then
				table.insert(names, child.Name)
				seen[child.Name] = true
			end
		end

		return names
	end

	for _, finisherId in ipairs(AUTHORED_ORDER) do
		if not seen[finisherId] then
			table.insert(names, finisherId)
			seen[finisherId] = true
		end
	end

	return names
end

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
	})
end

function FinisherConfig.IsKnownFinisherId(finisherId: any): boolean
	return FinisherConfig.GetDefinition(finisherId) ~= nil
end

function FinisherConfig.GetCatalogIds(): { string }
	return getKnownNames()
end

return table.freeze(FinisherConfig)
