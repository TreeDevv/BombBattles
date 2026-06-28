local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local NumberFormatter = require(ReplicatedStorage.Shared.Formatting.NumberFormatter)

local DataController = require(script.Parent:WaitForChild("DataController"))
local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = "Stats"
local PERSONAL_STATS_NAME = "PersonalStats"
local MAIN_NAME = "Main"
local SCROLLING_FRAME_NAME = "ScrollingFrame"
local TEMPLATE_NAME = "Template"
local INNER_NAME = "Inner"
local BAR_NAME = "Bar"
local ICON_NAME = "ImageLabel"
local ABILITY_NAME_LABEL = "AbilityName"
local CLOSE_BUTTON_NAME = "CloseButton"
local RUNTIME_ROW_ATTRIBUTE = "RuntimeStatsAbilityRow"
local VALUE_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local BAR_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local TIME_PLAYED_KEY = Schema.TimePlayed and Schema.TimePlayed.key or "timePlayed"
local LIFETIME_KILLS_KEY = Schema.LifetimeKills and Schema.LifetimeKills.key or "lifetimeKills"
local LIFETIME_WINS_KEY = Schema.LifetimeWins and Schema.LifetimeWins.key or "lifetimeWins"
local OWNED_ABILITIES_KEY = Schema.OwnedAbilities and Schema.OwnedAbilities.key or "ownedAbilities"
local GAMES_PLAYED_KEY = Schema.GamesPlayed and Schema.GamesPlayed.key or "gamesPlayed"
local LOSSES_KEY = Schema.Losses and Schema.Losses.key or "losses"
local BEST_WIN_STREAK_KEY = Schema.BestWinStreak and Schema.BestWinStreak.key or "bestWinStreak"
local ABILITY_GAMES_USED_KEY = Schema.AbilityGamesUsed and Schema.AbilityGamesUsed.key or "abilityGamesUsed"

type ValueTweenRecord = {
	tween: Tween,
	value: NumberValue,
	connection: RBXScriptConnection,
}

type AbilityRowRecord = {
	row: GuiObject,
	nameLabel: TextLabel?,
	amountLabel: TextLabel?,
	icon: ImageLabel?,
	bar: GuiObject?,
	barBaseSize: UDim2?,
}

local PERSONAL_STAT_BINDINGS = {
	["TIME PLAYED"] = TIME_PLAYED_KEY,
	["Games Played"] = GAMES_PLAYED_KEY,
	["Games Won"] = LIFETIME_WINS_KEY,
	Eliminations = LIFETIME_KILLS_KEY,
	Losses = LOSSES_KEY,
	["Best Win Streak"] = BEST_WIN_STREAK_KEY,
}

local WATCHED_DATA_KEYS = {
	[TIME_PLAYED_KEY] = true,
	[LIFETIME_KILLS_KEY] = true,
	[LIFETIME_WINS_KEY] = true,
	[OWNED_ABILITIES_KEY] = true,
	[GAMES_PLAYED_KEY] = true,
	[LOSSES_KEY] = true,
	[BEST_WIN_STREAK_KEY] = true,
	[ABILITY_GAMES_USED_KEY] = true,
}

local StatsController = {}

StatsController._connections = {} :: { RBXScriptConnection }
StatsController._frameConnections = {} :: { RBXScriptConnection }
StatsController._frame = nil :: GuiObject?
StatsController._scrollingFrame = nil :: ScrollingFrame?
StatsController._personalLabels = {} :: { [string]: TextLabel }
StatsController._rows = {} :: { AbilityRowRecord }
StatsController._valueTweens = {} :: { [TextLabel]: ValueTweenRecord }
StatsController._displayValues = {} :: { [TextLabel]: number }
StatsController._barTweens = {} :: { [GuiObject]: Tween }
StatsController._rebindQueued = false
StatsController._warnedMissingFrame = false

local function track(list: { RBXScriptConnection }, connection: RBXScriptConnection?)
	if connection then
		table.insert(list, connection)
	end
end

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in ipairs(list) do
		connection:Disconnect()
	end
	table.clear(list)
end

local function findTextLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findGuiObject(parent: Instance?, name: string): GuiObject?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("GuiObject") then child else nil
end

local function findImageLabel(parent: Instance?, name: string): ImageLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("ImageLabel") then child else nil
end

local function findScrollingFrame(parent: Instance?, name: string): ScrollingFrame?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("ScrollingFrame") then child else nil
end

local function roundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue < 0 then
		return 0
	end
	return math.floor(numberValue + 0.5)
end

local function formatInteger(value: number): string
	return NumberFormatter.Format(roundNonNegative(value))
end

local function formatHours(seconds: number): string
	local hours = math.floor(roundNonNegative(seconds) / 3600)
	local unit = if hours == 1 then "Hour" else "Hours"
	return ("%s %s"):format(formatInteger(hours), unit)
end

local function formatGames(value: number): string
	local rounded = roundNonNegative(value)
	local unit = if rounded == 1 then "Game" else "Games"
	return ("%s %s"):format(formatInteger(rounded), unit)
end

local function scaleUDim2X(size: UDim2, ratio: number): UDim2
	local clamped = math.clamp(ratio, 0, 1)
	return UDim2.new(size.X.Scale * clamped, math.floor(size.X.Offset * clamped + 0.5), size.Y.Scale, size.Y.Offset)
end

local function sortGuiObjectsByLayout(left: GuiObject, right: GuiObject): boolean
	if left.LayoutOrder ~= right.LayoutOrder then
		return left.LayoutOrder < right.LayoutOrder
	end
	if math.abs(left.Position.Y.Scale - right.Position.Y.Scale) > 0.0001 then
		return left.Position.Y.Scale < right.Position.Y.Scale
	end
	if math.abs(left.Position.X.Scale - right.Position.X.Scale) > 0.0001 then
		return left.Position.X.Scale < right.Position.X.Scale
	end
	return left.Position.X.Offset < right.Position.X.Offset
end

local function getCatalogOrder(): { [string]: number }
	local order = {}
	local index = 0
	for _, slot in ipairs(AbilityConfig.SlotOrder) do
		for _, abilityId in ipairs(AbilityConfig.GetCatalogIds(slot)) do
			index += 1
			order[abilityId] = index
		end
	end
	return order
end

local function getAbilityGamesUsed(gamesUsed: any, abilityId: string): number
	if typeof(gamesUsed) ~= "table" then
		return 0
	end

	local record = gamesUsed[abilityId]
	if typeof(record) == "table" then
		return roundNonNegative(record.count)
	end
	return 0
end

local function getOwnedAbilities(): { string }
	local rawOwned = DataController:Get(OWNED_ABILITIES_KEY)
	local ownedMap = {}
	if typeof(rawOwned) == "table" then
		for key, child in pairs(rawOwned) do
			local abilityId = nil
			if typeof(key) == "string" and child == true then
				abilityId = key
			elseif typeof(child) == "string" then
				abilityId = child
			end

			if abilityId then
				local normalizedAbilityId = AbilityConfig.NormalizeAbilityId(abilityId)
				if AbilityConfig.IsCatalogAbility(normalizedAbilityId) then
					ownedMap[normalizedAbilityId] = true
				end
			end
		end
	end

	local gamesUsed = DataController:Get(ABILITY_GAMES_USED_KEY)
	local catalogOrder = getCatalogOrder()
	local owned = {}
	for abilityId in pairs(ownedMap) do
		table.insert(owned, abilityId)
	end
	table.sort(owned, function(leftId, rightId)
		local leftUsage = getAbilityGamesUsed(gamesUsed, leftId)
		local rightUsage = getAbilityGamesUsed(gamesUsed, rightId)
		if leftUsage ~= rightUsage then
			return leftUsage > rightUsage
		end
		return (catalogOrder[leftId] or math.huge) < (catalogOrder[rightId] or math.huge)
	end)
	return owned
end

local function getAbilityNameLabels(inner: Instance?): (TextLabel?, TextLabel?)
	local labels = {}
	if inner then
		for _, child in ipairs(inner:GetChildren()) do
			if child:IsA("TextLabel") and child.Name == ABILITY_NAME_LABEL then
				table.insert(labels, child)
			end
		end
	end
	table.sort(labels, function(left, right)
		return left.Position.X.Scale < right.Position.X.Scale
	end)
	return labels[1], labels[#labels]
end

function StatsController:_clearValueTween(label: TextLabel)
	local record = self._valueTweens[label]
	if not record then
		return
	end

	record.tween:Cancel()
	record.connection:Disconnect()
	record.value:Destroy()
	self._valueTweens[label] = nil
end

function StatsController:_setAnimatedNumber(label: TextLabel?, targetValue: number, formatter)
	if not label then
		return
	end

	local roundedTarget = roundNonNegative(targetValue)
	local startValue = self._displayValues[label]
	if startValue == nil then
		startValue = 0
	end

	self:_clearValueTween(label)
	if startValue == roundedTarget then
		label.Text = formatter(roundedTarget)
		self._displayValues[label] = roundedTarget
		return
	end

	local numberValue = Instance.new("NumberValue")
	numberValue.Value = startValue
	local connection = numberValue.Changed:Connect(function(value)
		local roundedValue = roundNonNegative(value)
		label.Text = formatter(roundedValue)
		self._displayValues[label] = roundedValue
	end)
	local tween = TweenService:Create(numberValue, VALUE_TWEEN, { Value = roundedTarget })
	self._valueTweens[label] = {
		tween = tween,
		value = numberValue,
		connection = connection,
	}
	tween.Completed:Once(function(playbackState)
		local record = self._valueTweens[label]
		if playbackState ~= Enum.PlaybackState.Completed or not record or record.tween ~= tween then
			return
		end

		record.connection:Disconnect()
		record.value:Destroy()
		self._valueTweens[label] = nil
		label.Text = formatter(roundedTarget)
		self._displayValues[label] = roundedTarget
	end)
	tween:Play()
end

function StatsController:_setAnimatedBar(bar: GuiObject?, baseSize: UDim2?, ratio: number)
	if not (bar and baseSize) then
		return
	end

	local existingTween = self._barTweens[bar]
	if existingTween then
		existingTween:Cancel()
	end

	local tween = TweenService:Create(bar, BAR_TWEEN, {
		Size = scaleUDim2X(baseSize, ratio),
	})
	self._barTweens[bar] = tween
	tween.Completed:Once(function()
		if self._barTweens[bar] == tween then
			self._barTweens[bar] = nil
		end
	end)
	tween:Play()
end

function StatsController:_bindPersonalStats(frame: GuiObject)
	table.clear(self._personalLabels)

	local personalStats = frame:FindFirstChild(PERSONAL_STATS_NAME)
	if not personalStats then
		return
	end

	for _, card in ipairs(personalStats:GetChildren()) do
		if not card:IsA("GuiObject") then
			continue
		end

		local label = findTextLabel(card, "Label")
		local amount = findTextLabel(card, "Amount")
		if label and amount then
			local key = PERSONAL_STAT_BINDINGS[label.Text]
			if key then
				self._personalLabels[key] = amount
			end
		end
	end
end

function StatsController:_recordRow(row: GuiObject): AbilityRowRecord
	local inner = findGuiObject(row, INNER_NAME)
	local nameLabel, amountLabel = getAbilityNameLabels(inner)
	local bar = findGuiObject(inner, BAR_NAME)
	return {
		row = row,
		nameLabel = nameLabel,
		amountLabel = amountLabel,
		icon = findImageLabel(inner, ICON_NAME),
		bar = bar,
		barBaseSize = bar and bar.Size or nil,
	}
end

function StatsController:_bindAbilityRows()
	self._rows = {}
	local scrollingFrame = self._scrollingFrame
	if not scrollingFrame then
		return
	end

	local templates = {}
	for _, child in ipairs(scrollingFrame:GetChildren()) do
		if child:IsA("GuiObject") and child.Name == TEMPLATE_NAME then
			table.insert(templates, child)
		end
	end
	table.sort(templates, sortGuiObjectsByLayout)

	for _, row in ipairs(templates) do
		table.insert(self._rows, self:_recordRow(row))
	end
end

function StatsController:_ensureRowCount(count: number)
	local scrollingFrame = self._scrollingFrame
	if not scrollingFrame then
		return
	end

	if #self._rows <= 0 then
		self:_bindAbilityRows()
	end
	local source = self._rows[1] and self._rows[1].row
	if not source then
		return
	end

	while #self._rows < count do
		local clone = source:Clone()
		clone.Name = TEMPLATE_NAME
		clone:SetAttribute(RUNTIME_ROW_ATTRIBUTE, true)
		clone.Parent = scrollingFrame
		table.insert(self._rows, self:_recordRow(clone))
	end
end

function StatsController:_renderPersonalStats()
	self:_setAnimatedNumber(self._personalLabels[TIME_PLAYED_KEY], roundNonNegative(DataController:Get(TIME_PLAYED_KEY)), formatHours)
	self:_setAnimatedNumber(self._personalLabels[GAMES_PLAYED_KEY], roundNonNegative(DataController:Get(GAMES_PLAYED_KEY)), formatInteger)
	self:_setAnimatedNumber(self._personalLabels[LIFETIME_WINS_KEY], roundNonNegative(DataController:Get(LIFETIME_WINS_KEY)), formatInteger)
	self:_setAnimatedNumber(self._personalLabels[LIFETIME_KILLS_KEY], roundNonNegative(DataController:Get(LIFETIME_KILLS_KEY)), formatInteger)
	self:_setAnimatedNumber(self._personalLabels[LOSSES_KEY], roundNonNegative(DataController:Get(LOSSES_KEY)), formatInteger)
	self:_setAnimatedNumber(self._personalLabels[BEST_WIN_STREAK_KEY], roundNonNegative(DataController:Get(BEST_WIN_STREAK_KEY)), formatInteger)
end

function StatsController:_renderAbilityRows()
	local ownedAbilities = getOwnedAbilities()
	local gamesUsed = DataController:Get(ABILITY_GAMES_USED_KEY)
	self:_ensureRowCount(#ownedAbilities)

	local topUsage = 0
	for _, abilityId in ipairs(ownedAbilities) do
		local count = getAbilityGamesUsed(gamesUsed, abilityId)
		topUsage = math.max(topUsage, count)
	end

	for index, rowRecord in ipairs(self._rows) do
		local abilityId = ownedAbilities[index]
		if not abilityId then
			rowRecord.row.Visible = false
			self:_setAnimatedBar(rowRecord.bar, rowRecord.barBaseSize, 0)
			continue
		end

		local definition = AbilityConfig.GetDefinition(abilityId)
		local count = getAbilityGamesUsed(gamesUsed, abilityId)
		local ratio = if topUsage > 0 then count / topUsage else 0

		rowRecord.row.LayoutOrder = index
		rowRecord.row.Visible = true
		if rowRecord.nameLabel then
			rowRecord.nameLabel.Text = definition and definition.displayName or abilityId
		end
		if rowRecord.icon and definition then
			rowRecord.icon.Image = definition.icon
		end
		self:_setAnimatedNumber(rowRecord.amountLabel, count, formatGames)
		self:_setAnimatedBar(rowRecord.bar, rowRecord.barBaseSize, ratio)
	end
end

function StatsController:_render()
	self:_renderPersonalStats()
	self:_renderAbilityRows()
end

function StatsController:_bindFrame(frame: Instance?)
	disconnectAll(self._frameConnections)
	for label in pairs(self._valueTweens) do
		self:_clearValueTween(label)
	end
	for bar, tween in pairs(self._barTweens) do
		tween:Cancel()
		self._barTweens[bar] = nil
	end

	self._frame = nil
	self._scrollingFrame = nil
	table.clear(self._personalLabels)
	self._rows = {}
	self._displayValues = {}

	if not (frame and frame:IsA("GuiObject")) then
		return
	end

	self._frame = frame
	local main = frame:FindFirstChild(MAIN_NAME)
	self._scrollingFrame = findScrollingFrame(main, SCROLLING_FRAME_NAME)

	self:_bindPersonalStats(frame)
	self:_bindAbilityRows()

	local closeButton = frame:FindFirstChild(CLOSE_BUTTON_NAME)
	if closeButton and closeButton:IsA("GuiButton") then
		track(self._frameConnections, closeButton.Activated:Connect(function()
			FrameController:CloseFrame(FRAME_NAME)
		end))
	end

	self:_render()
end

function StatsController:_bindPlayerGui(root: Instance?)
	local frame = root and root:FindFirstChild(FRAME_NAME, true)
	self:_bindFrame(frame)
	if frame then
		self._warnedMissingFrame = false
	elseif not self._warnedMissingFrame then
		self._warnedMissingFrame = true
		warn(("[StatsController] Could not find %s under PlayerGui."):format(FRAME_NAME))
	end
end

function StatsController:_scheduleRebind()
	if self._rebindQueued then
		return
	end

	self._rebindQueued = true
	task.defer(function()
		self._rebindQueued = false
		if PlayerGui.Parent then
			self:_bindPlayerGui(PlayerGui)
		end
	end)
end

function StatsController:OnStart()
	disconnectAll(self._connections)
	self._rebindQueued = false

	track(self._connections, PlayerGui.ChildAdded:Connect(function()
		self:_scheduleRebind()
	end))
	track(self._connections, DataController.DataReceived:Connect(function()
		self:_render()
	end))
	track(self._connections, DataController.DataUpdated:Connect(function(key)
		if WATCHED_DATA_KEYS[key] then
			self:_render()
		end
	end))

	self:_bindPlayerGui(PlayerGui)
end

return StatsController
