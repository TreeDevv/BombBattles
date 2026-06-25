local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

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
local INVITE_PROMPT_DELAY_SECONDS = 1

local MoneyHudController = {}

MoneyHudController._connections = {} :: { RBXScriptConnection }
MoneyHudController._amountLabel = nil :: TextLabel?
MoneyHudController._moneyButtonConnection = nil :: RBXScriptConnection?
MoneyHudController._invitePromptPending = false
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

function MoneyHudController:_promptInviteFriends()
	if self._invitePromptPending then
		return
	end

	self._invitePromptPending = true
	task.spawn(function()
		local okCanInvite, canInvite = pcall(function()
			return SocialService:CanSendGameInviteAsync(LocalPlayer)
		end)
		if not okCanInvite then
			self._invitePromptPending = false
			warn("[MoneyHudController] CanSendGameInviteAsync failed: " .. tostring(canInvite))
			return
		end
		if canInvite ~= true then
			self._invitePromptPending = false
			return
		end
		task.wait(INVITE_PROMPT_DELAY_SECONDS)

		local okPrompt, promptResult = pcall(function()
			SocialService:PromptGameInvite(LocalPlayer)
		end)
		if not okPrompt then
			self._invitePromptPending = false
			warn("[MoneyHudController] PromptGameInvite failed: " .. tostring(promptResult))
		end
	end)
end

function MoneyHudController:_bindHud(hud: Instance?)
	if self._moneyButtonConnection then
		self._moneyButtonConnection:Disconnect()
		self._moneyButtonConnection = nil
	end
	self._amountLabel = nil

	local sideButtons = hud and hud:FindFirstChild(SIDE_BUTTONS_NAME)
	local moneyButton = sideButtons and sideButtons:FindFirstChild(MONEY_BUTTON_NAME)
	self._amountLabel = findAmountLabel(moneyButton)
	if moneyButton and moneyButton:IsA("GuiButton") then
		moneyButton.Active = true
		moneyButton.Selectable = true
		self._moneyButtonConnection = moneyButton.Activated:Connect(function()
			self:_promptInviteFriends()
		end)
	end

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
	if self._moneyButtonConnection then
		self._moneyButtonConnection:Disconnect()
		self._moneyButtonConnection = nil
	end
	disconnectAll(self._connections)
	self._amountLabel = nil
	self._invitePromptPending = false
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
	self:_trackConnection(SocialService.GameInvitePromptClosed:Connect(function(player)
		if player == LocalPlayer then
			self._invitePromptPending = false
		end
	end))

	self:_bindHud(PlayerGui:FindFirstChild(HUD_NAME))
end

return MoneyHudController
