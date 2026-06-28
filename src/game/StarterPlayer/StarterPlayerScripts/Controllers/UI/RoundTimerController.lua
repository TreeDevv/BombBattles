local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local HUD_GUI_NAME = "HUD"
local FRAMES_GUI_NAME = "Frames"
local TIMER_LABEL_NAME = "RoundTimer"
local MAP_VOTE_FRAME_NAME = "MapVote"
local UPDATE_INTERVAL_SECONDS = 0.1
local FALLBACK_NOTIFICATION_TOP_PADDING = 96
local TOP_HUD_MARGIN = 10
local TOAST_HEIGHT = 34
local TIMER_NOTIFICATION_GAP = 6

local VISIBLE_STATES = {
	[RoundStates.MapVoting] = true,
	[RoundStates.Intermission] = true,
	[RoundStates.RoundStarting] = true,
}

local RoundTimerController = {}

RoundTimerController._connections = {} :: { RBXScriptConnection }
RoundTimerController._uiConnections = {} :: { RBXScriptConnection }
RoundTimerController._timerLabel = nil :: TextLabel?
RoundTimerController._mapVoteFrame = nil :: GuiObject?
RoundTimerController._frameUpdateAccumulator = 0

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function getRemainingSeconds(state): number
	local endsAt = if state and typeof(state.endsAt) == "number" then state.endsAt else 0
	if endsAt <= 0 then
		return 0
	end

	return math.max(endsAt - workspace:GetServerTimeNow(), 0)
end

local function formatSeconds(seconds: number): string
	return tostring(math.max(0, math.ceil(seconds))) .. "s"
end

local function getTopHudBottom(playerGui: PlayerGui): number?
	local hud = playerGui:FindFirstChild(HUD_GUI_NAME)
	if not hud then
		return nil
	end

	if hud:IsA("LayerCollector") and not hud.Enabled then
		return nil
	end

	local top = hud:FindFirstChild("Top")
	if not (top and top:IsA("GuiObject") and top.Visible) then
		return nil
	end

	local size = top.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return nil
	end

	return top.AbsolutePosition.Y + size.Y
end

local function getTimerTopPadding(playerGui: PlayerGui): number
	local notificationTop = (getTopHudBottom(playerGui) or FALLBACK_NOTIFICATION_TOP_PADDING) + TOP_HUD_MARGIN
	return notificationTop + TOAST_HEIGHT + TIMER_NOTIFICATION_GAP
end

function RoundTimerController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function RoundTimerController:_trackUiConnection(connection: RBXScriptConnection)
	table.insert(self._uiConnections, connection)
end

function RoundTimerController:_disconnectAll()
	disconnectAll(self._connections)
	disconnectAll(self._uiConnections)
end

function RoundTimerController:_isMapVoteVisible(): boolean
	local frame = self._mapVoteFrame
	return frame ~= nil and frame.Parent ~= nil and frame.Visible
end

function RoundTimerController:_shouldShow(state): (boolean, number)
	if not state or not VISIBLE_STATES[state.state] then
		return false, 0
	end
	if self:_isMapVoteVisible() then
		return false, 0
	end

	local remaining = getRemainingSeconds(state)
	return remaining > 0, remaining
end

function RoundTimerController:_render()
	local label = self._timerLabel
	if not (label and label.Parent) then
		return
	end

	local shouldShow, remaining = self:_shouldShow(RoundController:GetState())
	label.Position = UDim2.new(0.5, 0, 0, getTimerTopPadding(PlayerGui))
	label.Visible = shouldShow
	label.Text = if shouldShow then formatSeconds(remaining) else ""
end

function RoundTimerController:_bindHud(hud: Instance?)
	self._timerLabel = nil

	if not hud then
		self:_render()
		return
	end

	local label = hud:FindFirstChild(TIMER_LABEL_NAME)
	self._timerLabel = if label and label:IsA("TextLabel") then label else nil
	if self._timerLabel then
		self._timerLabel.Visible = false
		self._timerLabel.Text = ""
	end

	self:_render()
end

function RoundTimerController:_bindFrames(frames: Instance?)
	self._mapVoteFrame = nil

	if not frames then
		self:_render()
		return
	end

	local mapVote = frames:FindFirstChild(MAP_VOTE_FRAME_NAME)
	self._mapVoteFrame = if mapVote and mapVote:IsA("GuiObject") then mapVote else nil
	if self._mapVoteFrame then
		self:_trackUiConnection(self._mapVoteFrame:GetPropertyChangedSignal("Visible"):Connect(function()
			self:_render()
		end))
	end

	self:_render()
end

function RoundTimerController:_bindPlayerGui()
	disconnectAll(self._uiConnections)
	self:_bindHud(PlayerGui:FindFirstChild(HUD_GUI_NAME))
	self:_bindFrames(PlayerGui:FindFirstChild(FRAMES_GUI_NAME))
end

function RoundTimerController:OnStart()
	self:_disconnectAll()
	self._timerLabel = nil
	self._mapVoteFrame = nil
	self._frameUpdateAccumulator = 0

	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == HUD_GUI_NAME or child.Name == FRAMES_GUI_NAME then
			task.defer(function()
				self:_bindPlayerGui()
			end)
		end
	end))
	self:_trackConnection(PlayerGui.ChildRemoved:Connect(function(child)
		if child.Name == HUD_GUI_NAME or child.Name == FRAMES_GUI_NAME then
			task.defer(function()
				self:_bindPlayerGui()
			end)
		end
	end))
	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self:_render()
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "state" or key == "endsAt" or key == "roundId" then
			self:_render()
		end
	end))
	self:_trackConnection(RunService.RenderStepped:Connect(function(deltaTime)
		self._frameUpdateAccumulator += deltaTime
		if self._frameUpdateAccumulator < UPDATE_INTERVAL_SECONDS then
			return
		end
		self._frameUpdateAccumulator = 0
		self:_render()
	end))

	self:_bindPlayerGui()
	if RoundController.Loaded then
		self:_render()
	end
end

return RoundTimerController
