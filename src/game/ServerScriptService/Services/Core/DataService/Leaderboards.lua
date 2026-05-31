local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Globals = require(ReplicatedStorage.Shared.Config.Lists.Globals)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local REFRESH_TIME = 30
local MAX_ENTRIES = 25
local LEADERBOARD_FOLDER_NAME = "Leaderboards"
local ENTRY_NAME_PREFIX = "Entry_"
local SCOPE = Globals.SCOPE

local CASH_KEY = Schema.Cash and Schema.Cash.key or "cash"
local TIME_PLAYED_KEY = Schema.TimePlayed and Schema.TimePlayed.key or "timePlayed"

local BOARD_CONFIGS = {
	Leaderboard_money = {
		key = CASH_KEY,
		heading = "TOP MONEY",
		format = "Cash",
		models = { "Leaderboard_money", "Leaderboard_money2" },
	},
	Leaderboard_timeplayed = {
		key = TIME_PLAYED_KEY,
		heading = "TOP TIME PLAYED",
		format = "TimePlayed",
		models = { "Leaderboard_timeplayed", "Leaderboard_timeplayed2" },
	},
}

local usernameCache = {}
local orderedStores = {}
local started = false

local function formatCash(value)
	return Globals.formatNumber(math.max(0, math.floor((tonumber(value) or 0) + 0.5)), false, true)
end

local function formatTimePlayed(value)
	local totalSeconds = math.max(0, math.floor(tonumber(value) or 0))
	local days = math.floor(totalSeconds / 86400)
	local hours = math.floor((totalSeconds % 86400) / 3600)
	local minutes = math.floor((totalSeconds % 3600) / 60)

	if days > 0 then
		return string.format("%dd %02dh %02dm", days, hours, minutes)
	end

	return string.format("%02dh %02dm", hours, minutes)
end

local FORMATTERS = {
	Cash = formatCash,
	TimePlayed = formatTimePlayed,
}

local function getLeaderboardFolder()
	return Workspace:FindFirstChild(LEADERBOARD_FOLDER_NAME)
end

local function getUsernameForUserId(userId)
	if usernameCache[userId] then
		return usernameCache[userId]
	end

	local success, result = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if not success then
		return tostring(userId)
	end

	usernameCache[userId] = result
	return result
end

local function getBoardWidgets(boardModel)
	if not boardModel then
		return nil
	end

	local surfaceGui = nil
	for _, child in ipairs(boardModel:GetChildren()) do
		if child:IsA("BasePart") then
			surfaceGui = child:FindFirstChildOfClass("SurfaceGui")
			if surfaceGui then
				break
			end
		end
	end

	if not surfaceGui then
		return nil
	end

	local frame = surfaceGui:FindFirstChild("Frame")
	local contents = frame and frame:FindFirstChild("Contents")
	local guideTopBar = contents and contents:FindFirstChild("GuideTopBar")
	local items = contents and contents:FindFirstChild("Items")
	local heading = frame and frame:FindFirstChild("Heading")
	local headingLabel = heading and heading:FindFirstChild("Heading")
	if not (frame and contents and guideTopBar and items and headingLabel) then
		return nil
	end

	return {
		surfaceGui = surfaceGui,
		guideTopBar = guideTopBar,
		items = items,
		nothingLabel = items:FindFirstChild("Nothing"),
		headingLabel = headingLabel,
	}
end

local function disableLegacyBoardScripts(boardModel)
	local widgets = getBoardWidgets(boardModel)
	if not widgets then
		return
	end

	for _, child in ipairs(widgets.surfaceGui:GetChildren()) do
		if child:IsA("Script") then
			child.Disabled = true
		end
	end
end

local function ensureItemsLayout(items)
	items.AutomaticCanvasSize = Enum.AutomaticSize.Y

	local layout = items:FindFirstChildWhichIsA("UIListLayout")
	if layout then
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, 6)
		return
	end

	layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = items
end

local function clearRenderedEntries(items)
	for _, child in ipairs(items:GetChildren()) do
		if child:IsA("GuiObject") and string.sub(child.Name, 1, #ENTRY_NAME_PREFIX) == ENTRY_NAME_PREFIX then
			child:Destroy()
		end
	end
end

local function createBoardEntry(widgets, rank, entryData)
	local row = widgets.guideTopBar:Clone()
	row.Name = ENTRY_NAME_PREFIX .. tostring(rank)
	row.LayoutOrder = rank
	row.Parent = widgets.items

	local rankLabel = row:FindFirstChild("Number")
	local usernameLabel = row:FindFirstChild("Username")
	local valueLabel = row:FindFirstChild("Value")

	if rankLabel and rankLabel:IsA("TextLabel") then
		rankLabel.Text = string.format("#%d", rank)
	end
	if usernameLabel and usernameLabel:IsA("TextLabel") then
		usernameLabel.Text = entryData.name
	end
	if valueLabel and valueLabel:IsA("TextLabel") then
		local formatter = FORMATTERS[entryData.format] or tostring
		valueLabel.Text = formatter(entryData.value)
	end
end

local function renderBoard(boardModel, config, entries)
	local widgets = getBoardWidgets(boardModel)
	if not widgets then
		return
	end

	disableLegacyBoardScripts(boardModel)
	ensureItemsLayout(widgets.items)
	clearRenderedEntries(widgets.items)

	if widgets.headingLabel:IsA("TextLabel") then
		widgets.headingLabel.Text = config.heading
	end

	local hasEntries = #entries > 0
	if widgets.nothingLabel and widgets.nothingLabel:IsA("TextLabel") then
		widgets.nothingLabel.Visible = not hasEntries
	end

	for rank, entryData in ipairs(entries) do
		createBoardEntry(widgets, rank, {
			name = entryData.name,
			value = entryData.value,
			format = config.format,
		})
	end
end

local function getCurrentPlayerEntries(dataService, key)
	local entries = {}

	for _, player in ipairs(Players:GetPlayers()) do
		local value = tonumber(dataService:Get(player, key)) or 0
		if value > 0 then
			entries[#entries + 1] = {
				userId = player.UserId,
				name = player.Name,
				value = value,
			}
		end
	end

	table.sort(entries, function(a, b)
		if a.value ~= b.value then
			return a.value > b.value
		end
		return a.userId < b.userId
	end)

	while #entries > MAX_ENTRIES do
		table.remove(entries)
	end

	return entries
end

local function pushCurrentPlayerData(dataService, key, store)
	for _, player in ipairs(Players:GetPlayers()) do
		local value = math.max(0, math.floor(tonumber(dataService:Get(player, key)) or 0))
		if value > 0 then
			pcall(function()
				store:SetAsync(player.UserId, value)
			end)
		end
	end
end

local function getOrderedStoreEntries(store)
	local success, pages = pcall(function()
		return store:GetSortedAsync(false, MAX_ENTRIES)
	end)
	if not success or not pages then
		return {}
	end

	local currentPage = pages:GetCurrentPage()
	local entries = {}
	for _, item in ipairs(currentPage) do
		local userId = tonumber(item.key)
		if userId then
			entries[#entries + 1] = {
				userId = userId,
				name = getUsernameForUserId(userId),
				value = tonumber(item.value) or 0,
			}
		end
	end

	return entries
end

local Leaderboards = {}

function Leaderboards.refresh(dataService)
	local leaderboardFolder = getLeaderboardFolder()
	if not leaderboardFolder then
		return
	end

	for boardName, config in pairs(BOARD_CONFIGS) do
		local boardModels = {}
		for _, modelName in ipairs(config.models or { boardName }) do
			local boardModel = leaderboardFolder:FindFirstChild(modelName)
			if boardModel then
				table.insert(boardModels, boardModel)
			end
		end

		if #boardModels > 0 then
			local entries = nil
			if RunService:IsStudio() then
				entries = getCurrentPlayerEntries(dataService, config.key)
			else
				local store = orderedStores[boardName]
				if store then
					pushCurrentPlayerData(dataService, config.key, store)
					entries = getOrderedStoreEntries(store)
				else
					entries = {}
				end
			end

			for _, boardModel in ipairs(boardModels) do
				disableLegacyBoardScripts(boardModel)
				renderBoard(boardModel, config, entries or {})
			end
		end
	end
end

function Leaderboards.start(dataService)
	local leaderboardFolder = getLeaderboardFolder()
	if not leaderboardFolder then
		warn("[Leaderboards] Missing workspace.Leaderboards folder")
		return
	end

	if started then
		Leaderboards.refresh(dataService)
		return
	end
	started = true

	if not RunService:IsStudio() then
		for boardName, config in pairs(BOARD_CONFIGS) do
			orderedStores[boardName] = DataStoreService:GetOrderedDataStore(config.key .. SCOPE)
		end
	end

	Leaderboards.refresh(dataService)
	task.spawn(function()
		while true do
			Leaderboards.refresh(dataService)
			task.wait(REFRESH_TIME)
		end
	end)
end

return Leaderboards
