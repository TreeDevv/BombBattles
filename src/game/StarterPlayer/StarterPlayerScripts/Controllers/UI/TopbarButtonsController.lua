local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Icon = require(ReplicatedStorage.Packages.topbarplus)
local BundlesController = require(script.Parent:WaitForChild("BundlesController"))
local DailyRewardController = require(script.Parent:WaitForChild("DailyRewardController"))
local FrameController = require(script.Parent:WaitForChild("FrameController"))
local GameUiVisibilityController = require(script.Parent:WaitForChild("GameUiVisibilityController"))

local ICON_STATES = { "Deselected", "Selected", "Viewing" }
local HIDE_UI_ICON_NAME = "TopbarHideUI"
local HIDE_UI_LABEL = "Hide UI"
local SHOW_UI_LABEL = "Show UI"

local TOPBAR_ITEMS = {
	{
		name = "TopbarLoginRewards",
		label = "Login Rewards",
		order = 10,
		width = 132,
		open = function()
			DailyRewardController:OpenMenu()
		end,
	},
	{
		name = "TopbarExtra",
		label = "EXTRA",
		order = 20,
		width = 78,
		dropdown = {
			{
				name = "TopbarCodes",
				label = "Codes",
				frameName = "Codes",
			},
			{
				name = "TopbarPlaytimeRewards",
				label = "Playtime Rewards",
				frameName = "PlaytimeRewards",
			},
		},
	},
	{
		name = "TopbarStats",
		label = "Stats",
		order = 30,
		width = 72,
		frameName = "Stats",
	},
	{
		name = "TopbarBundles",
		label = "Bundles",
		order = 35,
		width = 96,
		open = function()
			BundlesController:Open()
		end,
	},
	{
		name = HIDE_UI_ICON_NAME,
		label = HIDE_UI_LABEL,
		order = 40,
		width = 92,
		hideUiToggle = true,
	},
	{
		name = "TopbarSettings",
		label = "Settings",
		order = 50,
		width = 96,
		frameName = "Settings",
	},
}

local TopbarButtonsController = {}

TopbarButtonsController._icons = {} :: { any }
TopbarButtonsController._iconsByName = {} :: { [string]: any }
TopbarButtonsController._rebuildSerial = 0

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

	applyDesiredWidth(icon, config.width)

	if config.order then
		icon:setOrder(config.order)
	end

	return icon
end

local function setIconLabel(icon: any, label: string)
	for _, stateName in ipairs(ICON_STATES) do
		icon:setLabel(label, stateName)
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

local function createDropdownItem(config): any
	local icon = createTextIcon(config)
	bindIconAction(icon, config)
	icon:oneClick(true)
	return icon
end

function TopbarButtonsController:_destroyIcons()
	for _, icon in ipairs(self._icons) do
		icon:destroy()
	end
	self._icons = {}
	self._iconsByName = {}

	for _, config in ipairs(TOPBAR_ITEMS) do
		destroyExistingIcon(config.name)
		for _, dropdownConfig in ipairs(config.dropdown or {}) do
			destroyExistingIcon(dropdownConfig.name)
		end
	end
end

function TopbarButtonsController:_trackIcon(icon: any, name: string)
	table.insert(self._icons, icon)
	self._iconsByName[name] = icon
end

function TopbarButtonsController:_syncHiddenState()
	local hidden = GameUiVisibilityController:IsHidden()
	local hideIcon = self._iconsByName[HIDE_UI_ICON_NAME]

	for name, icon in pairs(self._iconsByName) do
		if name ~= HIDE_UI_ICON_NAME then
			icon:setEnabled(not hidden)
		end
	end

	if hideIcon then
		hideIcon:setEnabled(true)
		setIconLabel(hideIcon, if hidden then SHOW_UI_LABEL else HIDE_UI_LABEL)
	end
end

function TopbarButtonsController:_toggleUiHidden()
	GameUiVisibilityController:ToggleHidden()
	self:_syncHiddenState()
end

function TopbarButtonsController:_createIcon(config): any
	local icon = createTextIcon(config):setRight()

	if config.dropdown then
		local dropdownIcons = {}
		for _, dropdownConfig in ipairs(config.dropdown) do
			local dropdownIcon = createDropdownItem(dropdownConfig)
			self._iconsByName[dropdownConfig.name] = dropdownIcon
			table.insert(dropdownIcons, dropdownIcon)
		end
		icon:setDropdown(dropdownIcons)
	else
		if config.hideUiToggle then
			icon:bindEvent("selected", function()
				self:_toggleUiHidden()
			end)
		else
			bindIconAction(icon, config)
		end
		icon:oneClick(true)
	end

	self:_trackIcon(icon, config.name)
	return icon
end

function TopbarButtonsController:_rebuildIcons()
	self:_destroyIcons()

	for _, config in ipairs(TOPBAR_ITEMS) do
		self:_createIcon(config)
	end
	self:_syncHiddenState()
end

function TopbarButtonsController:OnStart()
	self._rebuildSerial += 1
	local serial = self._rebuildSerial
	self:_rebuildIcons()

	for _, delaySeconds in ipairs({ 0.5, 2, 5, 8, 15, 25 }) do
		task.delay(delaySeconds, function()
			if self._rebuildSerial == serial and not Icon.getIcon("TopbarLoginRewards") then
				self:_rebuildIcons()
			end
		end)
	end
end

return TopbarButtonsController
