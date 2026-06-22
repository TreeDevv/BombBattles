local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Icon = require(ReplicatedStorage.Packages.topbarplus)
local FrameController = require(script.Parent:WaitForChild("FrameController"))

local ICON_STATES = { "Deselected", "Selected", "Viewing" }

local TOPBAR_ITEMS = {
	{
		name = "TopbarLoginRewards",
		label = "Login Rewards",
		order = 10,
		width = 132,
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
	},
	{
		name = "TopbarHideUI",
		label = "Hide UI",
		order = 40,
		width = 92,
	},
	{
		name = "TopbarSettings",
		label = "Settings",
		order = 50,
		width = 96,
	},
}

local TopbarButtonsController = {}

TopbarButtonsController._icons = {} :: { any }

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

local function createDropdownItem(config): any
	local icon = createTextIcon(config)
	if config.frameName then
		icon:bindEvent("selected", function()
			FrameController:OpenFrame(config.frameName)
		end)
	end
	icon:oneClick(true)
	return icon
end

function TopbarButtonsController:_destroyIcons()
	for _, icon in ipairs(self._icons) do
		icon:destroy()
	end
	self._icons = {}

	for _, config in ipairs(TOPBAR_ITEMS) do
		destroyExistingIcon(config.name)
		for _, dropdownConfig in ipairs(config.dropdown or {}) do
			destroyExistingIcon(dropdownConfig.name)
		end
	end
end

function TopbarButtonsController:_createIcon(config): any
	local icon = createTextIcon(config):setRight()

	if config.dropdown then
		local dropdownIcons = {}
		for _, dropdownConfig in ipairs(config.dropdown) do
			table.insert(dropdownIcons, createDropdownItem(dropdownConfig))
		end
		icon:setDropdown(dropdownIcons)
	else
		icon:oneClick(true)
	end

	table.insert(self._icons, icon)
	return icon
end

function TopbarButtonsController:OnStart()
	self:_destroyIcons()

	for _, config in ipairs(TOPBAR_ITEMS) do
		self:_createIcon(config)
	end
end

return TopbarButtonsController
