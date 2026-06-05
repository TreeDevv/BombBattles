local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local SIDE_BUTTONS_NAME = "SideButtons"
local AFK_ATTR = "AFK"
local AFK_SOURCE_ATTR = "AFKSource"
local AFK_STARTED_AT_ATTR = "AFKStartedAt"
local AFK_MARKER_NAME = "AFK"
local ROUND_ID_ATTR = "RoundId"
local IDLE_SECONDS = 300
local BUTTON_TOGGLE_DEBOUNCE_SECONDS = 0.08

local AFKController = {}

AFKController._connections = {} :: { RBXScriptConnection }
AFKController._screenGuiConnections = {} :: { RBXScriptConnection }
AFKController._button = nil :: GuiButton?
AFKController._label = nil :: TextLabel?
AFKController._lastInputAt = os.clock()
AFKController._pendingAutoAFKAfterRound = false
AFKController._autoRequestSent = false
AFKController._idleAccumulator = 0
AFKController._lastToggleAt = 0
AFKController._rebindQueued = false
AFKController._warnedMissingButton = false

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function findTextLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function isAFK(): boolean
	return LocalPlayer:GetAttribute(AFK_ATTR) == true
end

local function formatDuration(seconds: number): string
	local wholeSeconds = math.max(0, math.floor(seconds))
	local hours = math.floor(wholeSeconds / 3600)
	local minutes = math.floor((wholeSeconds % 3600) / 60)
	local remainingSeconds = wholeSeconds % 60

	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, remainingSeconds)
	end

	return string.format("%d:%02d", minutes, remainingSeconds)
end

local function getAFKSource(): string
	local source = LocalPlayer:GetAttribute(AFK_SOURCE_ATTR)
	return if typeof(source) == "string" then source else ""
end

local function isActiveRoundParticipant(): boolean
	local state = RoundController:GetState()
	return state ~= nil and state.state == RoundStates.Active and LocalPlayer:GetAttribute(ROUND_ID_ATTR) ~= nil
end

local function isAFKButtonLabel(label: TextLabel?): boolean
	if not label then
		return false
	end

	local text = string.upper(label.Text)
	return text == "AFK" or text == "PLAY"
end

local function findAFKButton(root: Instance?): (GuiButton?, TextLabel?)
	if not root then
		return nil, nil
	end

	local sideButtonsContainers = {}
	if root.Name == SIDE_BUTTONS_NAME and root:IsA("GuiObject") then
		table.insert(sideButtonsContainers, root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == SIDE_BUTTONS_NAME and descendant:IsA("GuiObject") then
			table.insert(sideButtonsContainers, descendant)
		end
	end

	for _, sideButtons in ipairs(sideButtonsContainers) do
		for _, child in ipairs(sideButtons:GetChildren()) do
			if child:IsA("GuiButton") then
				local label = findTextLabel(child, "Label")
				if isAFKButtonLabel(label) then
					return child, label
				end
			end
		end
	end

	return nil, nil
end

local function shouldRebindFor(descendant: Instance): boolean
	if descendant:IsA("ScreenGui") or descendant.Name == SIDE_BUTTONS_NAME or descendant.Name == "AFK" then
		return true
	end

	if descendant.Name == "Label" and descendant:FindFirstAncestor(SIDE_BUTTONS_NAME) then
		return true
	end

	return false
end

function AFKController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function AFKController:_trackScreenGuiConnection(connection: RBXScriptConnection)
	table.insert(self._screenGuiConnections, connection)
end

function AFKController:_syncButton()
	local button = self._button
	local label = self._label
	if not (button and label) then
		return
	end

	button.Active = true
	button.Selectable = true
	label.Text = if isAFK() then "PLAY" else "AFK"
end

function AFKController:_requestAFK(afk: boolean, source: string)
	RoundController:SetAFK(afk, source)
end

function AFKController:_handleButtonActivated()
	local now = os.clock()
	if now - self._lastToggleAt < BUTTON_TOGGLE_DEBOUNCE_SECONDS then
		return
	end
	self._lastToggleAt = now

	if isAFK() then
		self:_requestAFK(false, "Manual")
		return
	end

	self:_requestAFK(true, "Manual")
end

function AFKController:_warnMissingButton()
	if self._warnedMissingButton then
		return
	end

	self._warnedMissingButton = true
	warn(("[AFKController] Could not find an AFK button under any %s frame in PlayerGui."):format(SIDE_BUTTONS_NAME))
end

function AFKController:_scheduleRebind()
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

function AFKController:_bindPlayerGui(root: Instance?)
	disconnectAll(self._screenGuiConnections)
	self._button = nil
	self._label = nil

	if not root then
		return
	end

	local button, label = findAFKButton(root)
	self._button = button
	self._label = label

	if button then
		self._warnedMissingButton = false
		button.Active = true
		button.Selectable = true
		self:_trackScreenGuiConnection(button.Activated:Connect(function()
			self:_handleButtonActivated()
		end))
		self:_trackScreenGuiConnection(button.MouseButton1Click:Connect(function()
			self:_handleButtonActivated()
		end))
	else
		self:_warnMissingButton()
	end

	self:_trackScreenGuiConnection(root.DescendantAdded:Connect(function(descendant)
		if shouldRebindFor(descendant) then
			self:_scheduleRebind()
		end
	end))

	self:_syncButton()
end

function AFKController:_bindCurrentPlayerGui()
	self:_bindPlayerGui(PlayerGui)
end

function AFKController:_handleInput()
	self._lastInputAt = os.clock()
	self._autoRequestSent = false

	if self._pendingAutoAFKAfterRound then
		self._pendingAutoAFKAfterRound = false
	end

	if isAFK() and getAFKSource() == "Auto" then
		self:_requestAFK(false, "Auto")
	end
end

function AFKController:_handleAFKChanged()
	if not isAFK() then
		self._lastInputAt = os.clock()
		self._pendingAutoAFKAfterRound = false
		self._autoRequestSent = false
	end

	self:_syncButton()
end

function AFKController:_tryApplyPendingAutoAFK()
	if not self._pendingAutoAFKAfterRound then
		return
	end
	if isAFK() or isActiveRoundParticipant() then
		return
	end
	if os.clock() - self._lastInputAt < IDLE_SECONDS then
		self._pendingAutoAFKAfterRound = false
		self._autoRequestSent = false
		return
	end

	self._pendingAutoAFKAfterRound = false
	self._autoRequestSent = true
	self:_requestAFK(true, "Auto")
end

function AFKController:_updateIdle()
	if isAFK() or self._autoRequestSent then
		return
	end
	if os.clock() - self._lastInputAt < IDLE_SECONDS then
		return
	end

	if isActiveRoundParticipant() then
		self._pendingAutoAFKAfterRound = true
		self._autoRequestSent = true
		return
	end

	self._autoRequestSent = true
	self:_requestAFK(true, "Auto")
end

function AFKController:_updateAFKTimers()
	local now = workspace:GetServerTimeNow()

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		local marker = rootPart and rootPart:FindFirstChild(AFK_MARKER_NAME)
		local billboardGui = marker and marker:FindFirstChild("BillboardGui")
		local frame = billboardGui and billboardGui:FindFirstChild("Frame")
		local timerLabel = frame and frame:FindFirstChild("Timer")
		if not (timerLabel and timerLabel:IsA("TextLabel")) then
			continue
		end

		local startedAt = player:GetAttribute(AFK_STARTED_AT_ATTR)
		if typeof(startedAt) ~= "number" then
			timerLabel.Text = "0:00"
			continue
		end

		timerLabel.Text = formatDuration(now - startedAt)
	end
end

function AFKController:_disconnectAll()
	disconnectAll(self._connections)
	disconnectAll(self._screenGuiConnections)
	self._button = nil
	self._label = nil
end

function AFKController:OnStart()
	self:_disconnectAll()
	self._lastInputAt = os.clock()
	self._pendingAutoAFKAfterRound = false
	self._autoRequestSent = false
	self._idleAccumulator = 0

	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if shouldRebindFor(child) then
			self:_scheduleRebind()
		end
	end))
	self:_trackConnection(LocalPlayer:GetAttributeChangedSignal(AFK_ATTR):Connect(function()
		self:_handleAFKChanged()
	end))
	self:_trackConnection(LocalPlayer:GetAttributeChangedSignal(AFK_SOURCE_ATTR):Connect(function()
		self:_syncButton()
	end))
	self:_trackConnection(UserInputService.InputBegan:Connect(function()
		self:_handleInput()
	end))
	self:_trackConnection(UserInputService.InputChanged:Connect(function()
		self:_handleInput()
	end))
	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self:_tryApplyPendingAutoAFK()
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "state" or key == "roundId" then
			self:_tryApplyPendingAutoAFK()
		end
	end))
	self:_trackConnection(RunService.Heartbeat:Connect(function(deltaTime)
		self._idleAccumulator += deltaTime
		if self._idleAccumulator < 1 then
			return
		end

		self._idleAccumulator = 0
		self:_updateIdle()
		self:_updateAFKTimers()
	end))

	self:_bindCurrentPlayerGui()
	self:_syncButton()
end

return AFKController
