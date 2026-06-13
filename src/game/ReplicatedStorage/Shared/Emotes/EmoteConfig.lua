local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EmoteConfig = {}

EmoteConfig.RemotesFolderName = "Remotes"
EmoteConfig.RequestRemoteName = "EmoteRequest"
EmoteConfig.StateRemoteName = "EmoteState"

EmoteConfig.Actions = table.freeze({
	Start = "Start",
	Stop = "Stop",
	Snapshot = "Snapshot",
})

EmoteConfig.PageSize = 8
EmoteConfig.OpenKeyCode = Enum.KeyCode.B
EmoteConfig.MaxEmoteIdLength = 64
EmoteConfig.DefaultWalkSpeed = 10
EmoteConfig.DefaultAutoRotate = true
EmoteConfig.CancelMoveSpeed = 0.75
EmoteConfig.MovementCancelGraceSeconds = 0.25

local AUTHORED_ORDER = table.freeze({
	"Billie",
	"Break",
	"Breakdance",
	"California",
	"Cat Dance",
	"Celebration",
	"Cola",
	"Conga",
	"CyberGoth",
	"Default Dance",
	"Distraction",
	"Gambler",
	"Gangnam Style",
	"Garry Dance",
	"Helicopter",
	"Kazotsky Kick",
	"Kazotsky Kick Two",
	"L",
	"Laugh",
	"Laugh Two",
	"Lounge",
	"Parker",
	"Penguin Walk",
	"Reanimated",
	"Relaxed",
	"Shuffle",
	"Shikanoko",
	"Sit",
	"Skipping",
	"Sleep",
	"T Dance",
	"T Pose",
	"Walk",
	"Whip",
	"goop",
})

local definitionCache: { [string]: any }? = nil
local catalogCache: { any }? = nil

local function getAssetsRoot(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	return assets and assets:FindFirstChild("Emotes") or nil
end

local function makeDefinition(emoteId: string, asset: Instance?): any
	return table.freeze({
		id = emoteId,
		displayName = emoteId,
		assetName = emoteId,
		asset = asset,
		animationName = "Animation1",
		walkSpeed = EmoteConfig.DefaultWalkSpeed,
		autoRotate = EmoteConfig.DefaultAutoRotate,
	})
end

local function sortedKeys(map: { [string]: boolean }): { string }
	local ids = {}
	for id in pairs(map) do
		table.insert(ids, id)
	end
	table.sort(ids, function(left, right)
		return string.lower(left) < string.lower(right)
	end)
	return ids
end

local function buildCatalog()
	local found: { [string]: boolean } = {}
	local definitions: { [string]: any } = {}
	local assetsRoot = getAssetsRoot()

	if assetsRoot then
		for _, child in ipairs(assetsRoot:GetChildren()) do
			if child:IsA("Folder") or child:IsA("ModuleScript") then
				found[child.Name] = true
				definitions[child.Name] = makeDefinition(child.Name, child)
			end
		end
	end

	for _, emoteId in ipairs(AUTHORED_ORDER) do
		if not definitions[emoteId] then
			local asset = assetsRoot and assetsRoot:FindFirstChild(emoteId) or nil
			definitions[emoteId] = makeDefinition(emoteId, asset)
		end
		found[emoteId] = true
	end

	local catalog = {}
	for _, emoteId in ipairs(sortedKeys(found)) do
		table.insert(catalog, definitions[emoteId])
	end

	definitionCache = definitions
	catalogCache = table.freeze(catalog)
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

function EmoteConfig.GetDefinition(emoteId: any): any?
	if typeof(emoteId) ~= "string" or emoteId == "" or #emoteId > EmoteConfig.MaxEmoteIdLength then
		return nil
	end
	if not definitionCache then
		buildCatalog()
	end
	return (definitionCache :: { [string]: any })[emoteId]
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
	return if assetsRoot and typeof(emoteId) == "string" then assetsRoot:FindFirstChild(emoteId) else nil
end

function EmoteConfig.GetAnimation(emoteId: any): Animation?
	local asset = EmoteConfig.GetAssetFolder(emoteId)
	if not asset then
		return nil
	end

	local animations = asset:FindFirstChild("Animations")
	local animation = animations and animations:FindFirstChild("Animation1")
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
