local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local BUTTONS_SLIDE_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local BUTTONS_HIDE_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HIDDEN_BOTTOM_MARGIN_SCALE = 0.02

local BottomButtonsController = {}

BottomButtonsController._connections = {} :: { RBXScriptConnection }
BottomButtonsController._buttons = nil :: Frame?
BottomButtonsController._nativePosition = nil :: UDim2?
BottomButtonsController._hiddenPosition = nil :: UDim2?
BottomButtonsController._shown = false
BottomButtonsController._tween = nil :: Tween?
BottomButtonsController._spectate = nil :: GuiObject?
BottomButtonsController._spectateConnection = nil :: RBXScriptConnection?

local function shouldShowButtons(state: string?, spectateVisible: boolean): boolean
	return (state == RoundStates.Active or CombatEligibility.IsPracticeRangeActive(LocalPlayer)) and not spectateVisible
end

local function getHiddenBottomPosition(buttons: GuiObject): UDim2
	local position = buttons.Position
	local size = buttons.Size
	return UDim2.new(
		position.X.Scale,
		position.X.Offset,
		1 + size.Y.Scale + HIDDEN_BOTTOM_MARGIN_SCALE,
		size.Y.Offset
	)
end

function BottomButtonsController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self:_disconnectHudConnections()
end

function BottomButtonsController:_cancelTween()
	if self._tween then
		self._tween:Cancel()
		self._tween = nil
	end
end

function BottomButtonsController:_disconnectHudConnections()
	if self._spectateConnection then
		self._spectateConnection:Disconnect()
		self._spectateConnection = nil
	end
end

function BottomButtonsController:_setButtonsVisible(visible: boolean, instant: boolean?)
	local buttons = self._buttons
	if not (buttons and self._nativePosition and self._hiddenPosition) then
		return
	end
	if self._shown == visible and buttons.Visible == visible and not instant then
		return
	end

	self._shown = visible
	self:_cancelTween()

	local targetPosition = if visible then self._nativePosition else self._hiddenPosition
	if visible then
		buttons.Visible = true
	end

	if instant then
		buttons.Position = targetPosition
		buttons.Visible = visible
		return
	end

	local tweenInfo = if visible then BUTTONS_SLIDE_TWEEN else BUTTONS_HIDE_TWEEN
	self._tween = TweenService:Create(buttons, tweenInfo, { Position = targetPosition })
	self._tween:Play()
	self._tween.Completed:Once(function()
		if self._buttons == buttons and not self._shown then
			buttons.Visible = false
		end
	end)
end

function BottomButtonsController:_updateVisibility(instant: boolean?)
	local state = RoundController:GetState()
	local spectateVisible = self._spectate ~= nil and self._spectate.Visible
	self:_setButtonsVisible(shouldShowButtons(state and state.state, spectateVisible), instant)
end

function BottomButtonsController:_bindHud(hud: Instance?)
	self:_cancelTween()
	self:_disconnectHudConnections()
	self._buttons = nil
	self._nativePosition = nil
	self._hiddenPosition = nil
	self._shown = false
	self._spectate = nil

	if not hud then
		return
	end

	local buttons = hud:FindFirstChild("Buttons")
	if not (buttons and buttons:IsA("Frame")) then
		return
	end

	self._buttons = buttons
	self._nativePosition = buttons.Position
	self._hiddenPosition = getHiddenBottomPosition(buttons)
	buttons.Position = self._hiddenPosition
	buttons.Visible = false

	local spectate = hud:FindFirstChild("Spectate")
	if spectate and spectate:IsA("GuiObject") then
		self._spectate = spectate
		self._spectateConnection = spectate:GetPropertyChangedSignal("Visible"):Connect(function()
			self:_updateVisibility(false)
		end)
	end

	self:_updateVisibility(true)
end

function BottomButtonsController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild("HUD"))
end

function BottomButtonsController:OnStart()
	self:_disconnectAll()

	table.insert(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" then
			task.defer(function()
				self:_bindHud(child)
			end)
		end
	end))
	table.insert(self._connections, RoundController.StateReceived:Connect(function()
		self:_updateVisibility(true)
	end))
	table.insert(self._connections, RoundController.StateUpdated:Connect(function(key)
		if key == "state" then
			self:_updateVisibility(false)
		end
	end))
	table.insert(self._connections, LocalPlayer:GetAttributeChangedSignal(CombatEligibility.PracticeRangeActiveAttribute):Connect(function()
		self:_updateVisibility(false)
	end))
	table.insert(self._connections, LocalPlayer:GetAttributeChangedSignal(CombatEligibility.AFKAttribute):Connect(function()
		self:_updateVisibility(false)
	end))

	self:_bindCurrentHud()
end

return BottomButtonsController
