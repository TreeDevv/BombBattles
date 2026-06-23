local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local FrameController = require(script.Parent:WaitForChild("FrameController"))
local ReplayClient = require(script.Parent:WaitForChild("Replay"):WaitForChild("ReplayClient"))
local RoundController = require(script.Parent:WaitForChild("RoundController"))
local RoundEndFlowConfig = require(ReplicatedStorage.Shared.Config.RoundEndFlowConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local ScreenEffects = require(ReplicatedStorage.Shared.UI.ScreenEffects)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local OVERLAY_GUI_NAME = "RoundEndFlowOverlay"
local ROUND_TEAM_ATTR = "RoundTeam"
local OVERLAY_DISPLAY_ORDER = 900
local TITLE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local OUT_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.In)

local TEAM_COLORS = {
	Red = Color3.fromRGB(255, 72, 72),
	Blue = Color3.fromRGB(72, 146, 255),
	Draw = Color3.fromRGB(255, 209, 92),
}

local RoundEndFlowController = {}

RoundEndFlowController._connections = {} :: { RBXScriptConnection }
RoundEndFlowController._winnerRoundId = nil :: number?
RoundEndFlowController._winnerSerial = 0
RoundEndFlowController._pendingLobbyFade = false

local function getRoundId(state): number?
	return if typeof(state) == "table" and typeof(state.roundId) == "number" then state.roundId else nil
end

local function getOverlay(): (ScreenGui, Frame, TextLabel, TextLabel)
	local existing = PlayerGui:FindFirstChild(OVERLAY_GUI_NAME)
	if existing and existing:IsA("ScreenGui") then
		local root = existing:FindFirstChild("Root")
		local title = root and root:FindFirstChild("Title")
		local subtitle = root and root:FindFirstChild("Subtitle")
		if root and root:IsA("Frame") and title and title:IsA("TextLabel") and subtitle and subtitle:IsA("TextLabel") then
			return existing, root, title, subtitle
		end
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = OVERLAY_GUI_NAME
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = OVERLAY_DISPLAY_ORDER
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = PlayerGui

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Size = UDim2.fromScale(1, 1)
	root.Visible = false
	root.Parent = screenGui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.Position = UDim2.fromScale(0.5, 0.43)
	title.Size = UDim2.fromScale(0.86, 0.12)
	title.TextScaled = true
	title.TextTransparency = 1
	title.TextStrokeTransparency = 1
	title.ZIndex = 2
	title.Parent = root

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.AnchorPoint = Vector2.new(0.5, 0.5)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.GothamBold
	subtitle.Position = UDim2.fromScale(0.5, 0.53)
	subtitle.Size = UDim2.fromScale(0.8, 0.055)
	subtitle.TextColor3 = Color3.fromRGB(255, 255, 255)
	subtitle.TextScaled = true
	subtitle.TextTransparency = 1
	subtitle.TextStrokeTransparency = 1
	subtitle.ZIndex = 2
	subtitle.Parent = root

	return screenGui, root, title, subtitle
end

local function getWinnerText(winnerTeam: string): (string, string, Color3)
	if winnerTeam == "Draw" then
		return "DRAW", "NO TEAM WINS", TEAM_COLORS.Draw
	end

	local localTeam = LocalPlayer:GetAttribute(ROUND_TEAM_ATTR)
	local winnerLabel = string.upper(winnerTeam) .. " WINS"
	if localTeam == winnerTeam then
		return "VICTORY", winnerLabel, TEAM_COLORS[winnerTeam] or Color3.fromRGB(255, 255, 255)
	end
	if typeof(localTeam) == "string" and localTeam ~= "" then
		return "DEFEAT", winnerLabel, TEAM_COLORS[winnerTeam] or Color3.fromRGB(255, 255, 255)
	end
	return winnerLabel, "PLAY OF THE GAME", TEAM_COLORS[winnerTeam] or Color3.fromRGB(255, 255, 255)
end

function RoundEndFlowController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function RoundEndFlowController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
end

function RoundEndFlowController:_hideWinnerOverlay()
	local existing = PlayerGui:FindFirstChild(OVERLAY_GUI_NAME)
	if not (existing and existing:IsA("ScreenGui")) then
		return
	end

	local root = existing:FindFirstChild("Root")
	if root and root:IsA("Frame") then
		root.Visible = false
	end
end

function RoundEndFlowController:_showWinnerBeat(state)
	local roundId = getRoundId(state)
	if not roundId or self._winnerRoundId == roundId then
		return
	end

	self._winnerRoundId = roundId
	self._winnerSerial += 1
	local serial = self._winnerSerial
	local winnerTeam = if typeof(state.winnerTeam) == "string" and state.winnerTeam ~= "" then state.winnerTeam else "Draw"
	local titleText, subtitleText, titleColor = getWinnerText(winnerTeam)
	local _, root, title, subtitle = getOverlay()

	FrameController:CloseCurrentFrame(true)
	root.Visible = true
	title.Text = titleText
	title.TextColor3 = titleColor
	title.TextTransparency = 1
	title.TextStrokeTransparency = 1
	subtitle.Text = subtitleText
	subtitle.TextTransparency = 1
	subtitle.TextStrokeTransparency = 1

	TweenService:Create(title, TITLE_TWEEN, {
		TextTransparency = 0,
		TextStrokeTransparency = 0.45,
	}):Play()
	TweenService:Create(subtitle, TITLE_TWEEN, {
		TextTransparency = 0,
		TextStrokeTransparency = 0.55,
	}):Play()

	task.delay(math.max(RoundEndFlowConfig.WinnerBeatSeconds - 0.18, 0.1), function()
		if self._winnerSerial ~= serial then
			return
		end

		local outTitle = TweenService:Create(title, OUT_TWEEN, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		})
		local outSubtitle = TweenService:Create(subtitle, OUT_TWEEN, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		})
		outTitle:Play()
		outSubtitle:Play()
		outTitle.Completed:Once(function()
			if self._winnerSerial == serial then
				root.Visible = false
			end
		end)
	end)
end

function RoundEndFlowController:_syncState()
	local state = RoundController:GetState()
	if typeof(state) ~= "table" then
		return
	end

	local stateName = state.state
	if stateName == RoundStates.PlayOfTheGame then
		self:_showWinnerBeat(state)
	elseif stateName == RoundStates.Resetting then
		self._pendingLobbyFade = true
		self:_hideWinnerOverlay()
		FrameController:CloseCurrentFrame(true)
		ScreenEffects.FadeToBlack(0.25)
	elseif stateName == RoundStates.Intermission or stateName == RoundStates.WaitingForPlayers then
		self._winnerRoundId = nil
		self:_hideWinnerOverlay()
		if self._pendingLobbyFade or ScreenEffects.IsBlack(0.05) then
			self._pendingLobbyFade = false
			ScreenEffects.FadeFromBlack(0.35)
		end
	end
end

function RoundEndFlowController:_bindReplaySignals()
	if ReplayClient.ReplayStarted and type(ReplayClient.ReplayStarted.Connect) == "function" then
		self:_trackConnection(ReplayClient.ReplayStarted:Connect(function(payload)
			if typeof(payload) == "table" and payload.type == "POTGReplay" then
				self:_hideWinnerOverlay()
			end
		end))
	end

	if ReplayClient.ReplayEnded and type(ReplayClient.ReplayEnded.Connect) == "function" then
		self:_trackConnection(ReplayClient.ReplayEnded:Connect(function(payload)
			if typeof(payload) == "table" and payload.type == "POTGReplay" then
				ScreenEffects.FadeToBlack(0.35)
			end
		end))
	end
end

function RoundEndFlowController:OnStart()
	self:_disconnectAll()
	self._winnerRoundId = nil
	self._winnerSerial = 0
	self._pendingLobbyFade = false

	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self:_syncState()
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "state" or key == "roundId" or key == "winnerTeam" then
			self:_syncState()
		end
	end))
	self:_bindReplaySignals()

	if RoundController.Loaded then
		self:_syncState()
	end
end

return RoundEndFlowController
