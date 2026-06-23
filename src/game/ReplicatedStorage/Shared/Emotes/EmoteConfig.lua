local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EmoteConfig = {}

EmoteConfig.RemotesFolderName = "Remotes"
EmoteConfig.RequestRemoteName = "EmoteRequest"
EmoteConfig.StateRemoteName = "EmoteState"

EmoteConfig.Actions = table.freeze({
	Start = "Start",
	Stop = "Stop",
	Snapshot = "Snapshot",
	SwapSlots = "SwapSlots",
	ToggleFavorite = "ToggleFavorite",
})

EmoteConfig.PageSize = 8
EmoteConfig.OpenKeyCode = Enum.KeyCode.B
EmoteConfig.MaxEmoteIdLength = 64
EmoteConfig.DefaultRarity = "Rare"
EmoteConfig.DefaultWalkSpeed = 10
EmoteConfig.DefaultAutoRotate = true
EmoteConfig.DefaultPreviewPauseTimeSeconds = 0
EmoteConfig.CancelMoveSpeed = 0.75
EmoteConfig.MovementCancelGraceSeconds = 0.25
EmoteConfig.DefaultAnimationName = "Animation1"

local definitionCache: { [string]: any }? = nil
local catalogCache: { any }? = nil
local normalizedIdCache: { [string]: string }? = nil

local function getAssetsRoot(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return assets and assets:FindFirstChild("Emotes") or nil
end

local function getBehaviorsRoot(): Instance?
	return script.Parent:FindFirstChild("EmoteBehaviors")
end

local function makeDefinition(behavior: any, asset: Instance?, fallbackOrder: number): any?
	if typeof(behavior) ~= "table" or typeof(behavior.id) ~= "string" or behavior.id == "" then
		return nil
	end

	local catalogOrder = if typeof(behavior.catalogOrder) == "number" then behavior.catalogOrder else fallbackOrder
	local previewPauseTimeSeconds = if typeof(behavior.previewPauseTimeSeconds) == "number"
		then math.max(behavior.previewPauseTimeSeconds, 0)
		else EmoteConfig.DefaultPreviewPauseTimeSeconds

	return table.freeze({
		id = behavior.id,
		displayName = if typeof(behavior.displayName) == "string" then behavior.displayName else behavior.id,
		assetName = if typeof(behavior.assetName) == "string" then behavior.assetName else behavior.id,
		asset = asset,
		animationName = if typeof(behavior.animationName) == "string" then behavior.animationName else EmoteConfig.DefaultAnimationName,
		rarity = if typeof(behavior.rarity) == "string" then behavior.rarity else EmoteConfig.DefaultRarity,
		catalogOrder = catalogOrder,
		walkSpeed = if typeof(behavior.walkSpeed) == "number" then behavior.walkSpeed else EmoteConfig.DefaultWalkSpeed,
		autoRotate = if typeof(behavior.autoRotate) == "boolean" then behavior.autoRotate else EmoteConfig.DefaultAutoRotate,
		previewPauseTimeSeconds = previewPauseTimeSeconds,
		behavior = behavior,
	})
end

local function loadBehavior(child: Instance): any?
	if not child:IsA("ModuleScript") then
		return nil
	end

	local ok, behavior = pcall(require, child)
	if ok and typeof(behavior) == "table" then
		return behavior
	end

	warn("[EmoteConfig] Failed to load emote behavior " .. child:GetFullName() .. ": " .. tostring(behavior))
	return nil
end

local function sortDefinitions(left: any, right: any): boolean
	if left.catalogOrder == right.catalogOrder then
		return string.lower(left.id) < string.lower(right.id)
	end
	return left.catalogOrder < right.catalogOrder
end

local function buildCatalog()
	local assetsRoot = getAssetsRoot()
	local behaviorsRoot = getBehaviorsRoot()
	local definitions: { [string]: any } = {}
	local catalog = {}
	local normalizedIds: { [string]: string } = {}

	if behaviorsRoot then
		local fallbackOrder = 0
		for _, child in ipairs(behaviorsRoot:GetChildren()) do
			local behavior = loadBehavior(child)
			if not behavior then
				continue
			end

			fallbackOrder += 1
			local assetName = if typeof(behavior.assetName) == "string" then behavior.assetName else behavior.id
			local asset = if assetsRoot and typeof(assetName) == "string" then assetsRoot:FindFirstChild(assetName) else nil
			local definition = makeDefinition(behavior, asset, fallbackOrder)
			if not definition then
				continue
			end

			if definitions[definition.id] then
				warn("[EmoteConfig] Duplicate emote behavior id " .. definition.id)
				continue
			end

			definitions[definition.id] = definition
			table.insert(catalog, definition)
			normalizedIds[string.lower(definition.id)] = definition.id
		end
	end

	table.sort(catalog, sortDefinitions)

	definitionCache = definitions
	catalogCache = table.freeze(catalog)
	normalizedIdCache = normalizedIds
end

function EmoteConfig.GetAssetsRoot(): Instance?
	return getAssetsRoot()
end

function EmoteConfig.GetCatalog(): { any }
	if not catalogCache then
		buildCatalog()
	end
	return catalogCache :: { any }
end

function EmoteConfig.GetCatalogIds(): { string }
	local ids = {}
	for _, definition in ipairs(EmoteConfig.GetCatalog()) do
		table.insert(ids, definition.id)
	end
	return ids
end

function EmoteConfig.NormalizeEmoteId(emoteId: any): string
	if typeof(emoteId) ~= "string" then
		return ""
	end

	local trimmed = string.gsub(emoteId, "^%s+", "")
	trimmed = string.gsub(trimmed, "%s+$", "")
	if trimmed == "" or #trimmed > EmoteConfig.MaxEmoteIdLength then
		return ""
	end

	if not definitionCache then
		buildCatalog()
	end

	if (definitionCache :: { [string]: any })[trimmed] then
		return trimmed
	end

	local normalized = (normalizedIdCache :: { [string]: string })[string.lower(trimmed)]
	return normalized or ""
end

function EmoteConfig.GetDefinition(emoteId: any): any?
	local normalizedEmoteId = EmoteConfig.NormalizeEmoteId(emoteId)
	if normalizedEmoteId == "" then
		return nil
	end
	if not definitionCache then
		buildCatalog()
	end
	return (definitionCache :: { [string]: any })[normalizedEmoteId]
end

function EmoteConfig.IsKnownEmoteId(emoteId: any): boolean
	return EmoteConfig.GetDefinition(emoteId) ~= nil
end

function EmoteConfig.GetAssetFolder(emoteId: any): Instance?
	local definition = EmoteConfig.GetDefinition(emoteId)
	if definition and definition.asset and definition.asset.Parent then
		return definition.asset
	end

	local assetsRoot = getAssetsRoot()
	local normalizedEmoteId = EmoteConfig.NormalizeEmoteId(emoteId)
	return if assetsRoot and normalizedEmoteId ~= "" then assetsRoot:FindFirstChild(normalizedEmoteId) else nil
end

function EmoteConfig.GetAnimation(emoteId: any): Animation?
	local definition = EmoteConfig.GetDefinition(emoteId)
	local asset = EmoteConfig.GetAssetFolder(emoteId)
	if not (definition and asset) then
		return nil
	end

	local animations = asset:FindFirstChild("Animations")
	local animation = animations and animations:FindFirstChild(definition.animationName)
	return if animation and animation:IsA("Animation") then animation else nil
end

function EmoteConfig.GetPage(pageIndex: number): ({ any }, number)
	local catalog = EmoteConfig.GetCatalog()
	local pageCount = math.max(math.ceil(#catalog / EmoteConfig.PageSize), 1)
	local resolvedPage = math.clamp(math.floor(pageIndex), 1, pageCount)
	local first = ((resolvedPage - 1) * EmoteConfig.PageSize) + 1
	local page = {}

	for index = first, math.min(first + EmoteConfig.PageSize - 1, #catalog) do
		table.insert(page, catalog[index])
	end

	return page, pageCount
end

return table.freeze(EmoteConfig)
