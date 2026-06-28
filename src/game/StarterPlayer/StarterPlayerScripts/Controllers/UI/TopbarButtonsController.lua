local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Icon = require(ReplicatedStorage.Packages.topbarplus)
local DailyRewardController = require(script.Parent:WaitForChild("DailyRewardController"))
local FrameController = require(script.Parent:WaitForChild("FrameController"))
local PlaytimeRewardController = require(script.Parent:WaitForChild("PlaytimeRewardController"))

local ICON_STATES = { "Deselected", "Selected", "Viewing" }
local PLAYTIME_REWARDS_ICON_NAME = "TopbarPlaytimeRewards"
local PLAYTIME_NOTICE_ID_PREFIX = "PlaytimeRewardClaimable"

local TOPBAR_ITEMS = {
	{
		name = "TopbarLoginRewards",
		label = "📅",
		caption = "Login Rewards",
		order = 10,
		width = 48,
		open = function()
			DailyRewardController:OpenMenu()
		end,
	},
	{
		name = "TopbarCodes",
		label = "🎟️",
		caption = "Codes",
		order = 20,
		width = 48,
		frameName = "Codes",
	},
	{
		name = PLAYTIME_REWARDS_ICON_NAME,
		label = "🎁",
		caption = "Playtime Rewards",
		order = 30,
		width = 48,
		frameName = "PlaytimeRewards",
	},
	{
		name = "TopbarStats",
		label = "📊",
		caption = "Stats",
		order = 40,
		width = 48,
		frameName = "Stats",
	},
	{
		name = "TopbarSettings",
		label = "⚙️",
		caption = "Settings",
		order = 50,
		width = 48,
		frameName = "Settings",
	},
}

local TopbarButtonsController = {}

TopbarButtonsController._icons = {} :: { any }
TopbarButtonsController._iconsByName = {} :: { [string]: any }
TopbarButtonsController._rebuildSerial = 0
TopbarButtonsController._playtimeClaimableCount = 0
TopbarButtonsController._playtimeNoticeClear = Instance.new("BindableEvent")

local function destroyExistingIcon(name: string)
	local existingIcon = Icon.getIcon(name)
	if existingIcon then
		existingIcon:destroy()
	end
end

local function applyDesiredWidth(icon: any, width: number?)
	if not width then
		return
	end

	for _, stateName in ipairs(ICON_STATES) do
		icon:modifyTheme({ "Widget", "DesiredWidth", width, stateName })
	end
end

local function createTextIcon(config): any
	destroyExistingIcon(config.name)

	local icon = Icon.new()
		:setName(config.name)

	for _, stateName in ipairs(ICON_STATES) do
		icon:setLabel(config.label, stateName)
	end

	if config.caption then
		icon:setCaption(config.caption)
	end

	applyDesiredWidth(icon, config.width)

	if config.order then
		icon:setOrder(config.order)
	end

	return icon
end

function TopbarButtonsController:_setPlaytimeClaimableCount(count: number)
	local normalizedCount = math.max(0, math.floor(tonumber(count) or 0))
	self._playtimeClaimableCount = normalizedCount

	local icon = self._iconsByName[PLAYTIME_REWARDS_ICON_NAME]
	if not icon then
		return
	end

	self._playtimeNoticeClear:Fire()
	icon:clearNotices()

	for index = 1, normalizedCount do
		icon:notify(self._playtimeNoticeClear.Event, PLAYTIME_NOTICE_ID_PREFIX .. tostring(index))
	end
end

local function bindIconAction(icon: any, config)
	if config.open then
		icon:bindEvent("selected", config.open)
	elseif config.frameName then
		icon:bindEvent("selected", function()
			FrameController:OpenFrame(config.frameName)
		end)
	end
end

function TopbarButtonsController:_destroyIcons()
	for _, icon in ipairs(self._icons) do
		icon:destroy()
	end
	self._icons = {}
	self._iconsByName = {}

	for _, config in ipairs(TOPBAR_ITEMS) do
		destroyExistingIcon(config.name)
	end
end

function TopbarButtonsController:_trackIcon(icon: any, name: string)
	table.insert(self._icons, icon)
	self._iconsByName[name] = icon
end

function TopbarButtonsController:_createIcon(config): any
	local icon = createTextIcon(config):setRight()

	bindIconAction(icon, config)
	icon:oneClick(true)

	self:_trackIcon(icon, config.name)
	return icon
end

function TopbarButtonsController:_rebuildIcons()
	self:_destroyIcons()

	for _, config in ipairs(TOPBAR_ITEMS) do
		self:_createIcon(config)
	end
	self:_setPlaytimeClaimableCount(self._playtimeClaimableCount)
end

function TopbarButtonsController:OnStart()
	self._rebuildSerial += 1
	local serial = self._rebuildSerial
	self:_rebuildIcons()
	self:_setPlaytimeClaimableCount(PlaytimeRewardController:GetClaimableCount())

	PlaytimeRewardController.ClaimableCountChanged:Connect(function(count)
		self:_setPlaytimeClaimableCount(count)
	end)

	for _, delaySeconds in ipairs({ 0.5, 2, 5, 8, 15, 25 }) do
		task.delay(delaySeconds, function()
			if self._rebuildSerial == serial and not Icon.getIcon("TopbarLoginRewards") then
				self:_rebuildIcons()
			end
		end)
	end
end

return TopbarButtonsController
