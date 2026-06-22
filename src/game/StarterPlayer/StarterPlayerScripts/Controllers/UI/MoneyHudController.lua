local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent:WaitForChild("DataController"))
local NumberFormatter = require(ReplicatedStorage.Shared.Formatting.NumberFormatter)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local HUD_NAME = "HUD"
local SIDE_BUTTONS_NAME = "SideButtons"
local MONEY_BUTTON_NAME = "Money"
local LABEL_NAME = "Label"
local CASH_KEY = "cash"
local CASH_ATTRIBUTE = "Cash"
local PLUS_TEXT = "+"

local MoneyHudController = {}

MoneyHudController._connections = {} :: { RBXScriptConnection }
MoneyHudController._amountLabel = nil :: TextLabel?
MoneyHudController._rebindQueued = false

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function findAmountLabel(moneyButton: Instance?): TextLabel?
	if not moneyButton then
		return nil
	end

	for _, child in ipairs(moneyButton:GetChildren()) do
		if child:IsA("TextLabel") and child.Name == LABEL_NAME and child.Text ~= PLUS_TEXT then
			return child
		end
	end

	return nil
end

local function getCashValue(): number
	local cash = DataController:Get(CASH_KEY)
	if cash == nil then
		cash = LocalPlayer:GetAttribute(CASH_ATTRIBUTE)
	end

	return tonumber(cash) or 0
end

function MoneyHudController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function MoneyHudController:_refresh()
	local amountLabel = self._amountLabel
	if not amountLabel then
		return
	end

	amountLabel.Text = NumberFormatter.Format(getCashValue())
end

function MoneyHudController:_bindHud(hud: Instance?)
	self._amountLabel = nil

	local sideButtons = hud and hud:FindFirstChild(SIDE_BUTTONS_NAME)
	local moneyButton = sideButtons and sideButtons:FindFirstChild(MONEY_BUTTON_NAME)
	self._amountLabel = findAmountLabel(moneyButton)

	self:_refresh()
end

function MoneyHudController:_scheduleRebind()
	if self._rebindQueued then
		return
	end

	self._rebindQueued = true
	task.defer(function()
		self._rebindQueued = false
		self:_bindHud(PlayerGui:FindFirstChild(HUD_NAME))
	end)
end

function MoneyHudController:OnStart()
	disconnectAll(self._connections)
	self._amountLabel = nil
	self._rebindQueued = false

	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == HUD_NAME then
			self:_scheduleRebind()
		end
	end))
	self:_trackConnection(DataController.DataReceived:Connect(function()
		self:_refresh()
	end))
	self:_trackConnection(DataController.DataUpdated:Connect(function(key)
		if key == CASH_KEY then
			self:_refresh()
		end
	end))
	self:_trackConnection(LocalPlayer:GetAttributeChangedSignal(CASH_ATTRIBUTE):Connect(function()
		self:_refresh()
	end))

	self:_bindHud(PlayerGui:FindFirstChild(HUD_NAME))
end

return MoneyHudController
