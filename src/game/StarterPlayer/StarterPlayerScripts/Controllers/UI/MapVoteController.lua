local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)

local FrameController = require(script.Parent:WaitForChild("FrameController"))
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAMES_GUI_NAME = "Frames"
local FRAME_NAME = "MapVote"
local AFK_ATTR = "AFK"
local CONTROLLER_AVATAR_ATTR = "MapVoteControllerAvatar"
local CARD_SCALE_NAME = "MapVoteControllerScale"

local SCALE_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SELECTED_SCALE = 1.08
local HOVER_SCALE_BONUS = 0.05
local PRESSED_SCALE = 0.94
local SELECTED_BACK_COLOR = Color3.fromRGB(255, 248, 205)
local SELECTED_STROKE_COLOR = Color3.fromRGB(255, 221, 89)

type VoteChoice = {
	choiceId: string,
	mapId: string,
	displayName: string,
	thumbnailImage: string?,
}

type StrokeState = {
	stroke: UIStroke,
	color: Color3,
	transparency: number,
	thickness: number,
}

type CardRecord = {
	button: ImageButton,
	label: TextLabel?,
	back: ImageLabel?,
	playerList: Frame?,
	playerTemplate: ImageLabel?,
	scale: UIScale,
	defaultBackImage: string,
	defaultBackColor: Color3,
	strokes: { StrokeState },
	choiceId: string,
	hovered: boolean,
	pressed: boolean,
	selected: boolean,
	connections: { RBXScriptConnection },
}

local MapVoteController = {}

MapVoteController._connections = {} :: { RBXScriptConnection }
MapVoteController._frameConnections = {} :: { RBXScriptConnection }
MapVoteController._mapVoteConnections = {} :: { RBXScriptConnection }
MapVoteController._cardConnections = {} :: { RBXScriptConnection }
MapVoteController._frame = nil :: Frame?
MapVoteController._timer = nil :: TextLabel?
MapVoteController._cards = {} :: { CardRecord }
MapVoteController._selectedChoiceId = ""
MapVoteController._pendingChoiceId = ""
MapVoteController._dismissedRoundId = nil :: number?
MapVoteController._openedRoundId = nil :: number?
MapVoteController._votingOpen = false
MapVoteController._suppressDismissOnce = false

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

local function findImageLabel(parent: Instance?, name: string): ImageLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("ImageLabel") then child else nil
end

local function normalizeChoice(rawChoice: any): VoteChoice?
	if typeof(rawChoice) ~= "table" then
		return nil
	end

	local choiceId = if typeof(rawChoice.choiceId) == "string" then rawChoice.choiceId else rawChoice.id
	local mapId = if typeof(rawChoice.mapId) == "string" then rawChoice.mapId else rawChoice.id
	if typeof(choiceId) ~= "string" or choiceId == "" or typeof(mapId) ~= "string" or mapId == "" then
		return nil
	end

	local displayName = rawChoice.displayName
	return {
		choiceId = choiceId,
		mapId = mapId,
		displayName = if typeof(displayName) == "string" and displayName ~= "" then displayName else mapId,
		thumbnailImage = if typeof(rawChoice.thumbnailImage) == "string" then rawChoice.thumbnailImage else nil,
	}
end

local function getVoteChoices(state): { VoteChoice }
	local choices = {}
	local rawChoices = state and state.voteChoices
	if typeof(rawChoices) ~= "table" then
		return choices
	end

	for _, rawChoice in ipairs(rawChoices) do
		local choice = normalizeChoice(rawChoice)
		if choice then
			table.insert(choices, choice)
		end
	end

	return choices
end

local function getChoiceVoters(state, choiceId: string): { number }
	local voteVoters = state and state.voteVoters
	local rawVoters = if typeof(voteVoters) == "table" then voteVoters[choiceId] else nil
	if typeof(rawVoters) ~= "table" then
		return {}
	end

	local voters = {}
	for _, userId in ipairs(rawVoters) do
		if typeof(userId) == "number" then
			table.insert(voters, userId)
		end
	end
	return voters
end

local function getChoiceVoteCount(state, choiceId: string): number
	local voteCounts = state and state.voteCounts
	local count = if typeof(voteCounts) == "table" then voteCounts[choiceId] else nil
	if typeof(count) == "number" then
		return math.max(0, count)
	end

	return #getChoiceVoters(state, choiceId)
end

local function findSelectedChoiceId(state): string
	local choices = getVoteChoices(state)
	for _, choice in ipairs(choices) do
		for _, userId in ipairs(getChoiceVoters(state, choice.choiceId)) do
			if userId == LocalPlayer.UserId then
				return choice.choiceId
			end
		end
	end

	return ""
end

local function hasChoice(choices: { VoteChoice }, choiceId: string): boolean
	if choiceId == "" then
		return false
	end

	for _, choice in ipairs(choices) do
		if choice.choiceId == choiceId then
			return true
		end
	end
	return false
end

local function isLocalPlayerAFK(): boolean
	return LocalPlayer:GetAttribute(AFK_ATTR) == true
end

local function formatTimer(state): string
	local endsAt = if state and typeof(state.endsAt) == "number" then state.endsAt else 0
	local remaining = math.max(endsAt - workspace:GetServerTimeNow(), 0)
	return tostring(math.max(0, math.ceil(remaining))) .. "s"
end

local function getScale(card: CardRecord): number
	if card.pressed then
		return PRESSED_SCALE
	end

	local scale = if card.selected then SELECTED_SCALE else 1
	if card.hovered then
		scale += HOVER_SCALE_BONUS
	end
	return scale
end

function MapVoteController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function MapVoteController:_trackFrameConnection(connection: RBXScriptConnection)
	table.insert(self._frameConnections, connection)
end

function MapVoteController:_trackMapVoteConnection(connection: RBXScriptConnection)
	table.insert(self._mapVoteConnections, connection)
end

function MapVoteController:_trackCardConnection(card: CardRecord, connection: RBXScriptConnection)
	table.insert(card.connections, connection)
	table.insert(self._cardConnections, connection)
end

function MapVoteController:_disconnectAll()
	disconnectAll(self._connections)
	disconnectAll(self._frameConnections)
	disconnectAll(self._mapVoteConnections)
	disconnectAll(self._cardConnections)
	for _, card in ipairs(self._cards) do
		table.clear(card.connections)
	end
end

function MapVoteController:_setCardScale(card: CardRecord, instant: boolean?)
	local targetScale = getScale(card)
	if instant then
		card.scale.Scale = targetScale
		return
	end

	TweenService:Create(card.scale, SCALE_TWEEN, { Scale = targetScale }):Play()
end

function MapVoteController:_setCardSelected(card: CardRecord, selected: boolean)
	card.selected = selected
	self:_setCardScale(card)

	if card.back then
		card.back.ImageColor3 = if selected then SELECTED_BACK_COLOR else card.defaultBackColor
	end

	for _, state in ipairs(card.strokes) do
		if selected and state.color ~= Color3.new(0, 0, 0) then
			state.stroke.Color = SELECTED_STROKE_COLOR
			state.stroke.Transparency = 0
			state.stroke.Thickness = math.max(state.thickness, 0.045)
		else
			state.stroke.Color = state.color
			state.stroke.Transparency = state.transparency
			state.stroke.Thickness = state.thickness
		end
	end
end

function MapVoteController:_clearVoters(card: CardRecord)
	local playerList = card.playerList
	if not playerList then
		return
	end

	for _, child in ipairs(playerList:GetChildren()) do
		if child:IsA("ImageLabel") and child:GetAttribute(CONTROLLER_AVATAR_ATTR) == true then
			child:Destroy()
		end
	end
end

function MapVoteController:_setVoters(card: CardRecord, userIds: { number })
	self:_clearVoters(card)
	if not (card.playerList and card.playerTemplate) then
		return
	end

	for index, userId in ipairs(userIds) do
		local avatar = card.playerTemplate:Clone()
		avatar.Name = "Voter_" .. tostring(userId)
		avatar:SetAttribute(CONTROLLER_AVATAR_ATTR, true)
		avatar.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=420&h=420"):format(userId)
		avatar.LayoutOrder = index
		avatar.Visible = true
		avatar.Parent = card.playerList
	end
end

function MapVoteController:_setCardChoice(card: CardRecord, choice: VoteChoice?, state)
	card.choiceId = if choice then choice.choiceId else ""
	card.button:SetAttribute("ChoiceId", card.choiceId)
	card.button.Visible = choice ~= nil
	card.button.Active = choice ~= nil
	card.button.Selectable = choice ~= nil

	if card.label then
		card.label.Text = if choice
			then ("%s (%d)"):format(choice.displayName, getChoiceVoteCount(state, choice.choiceId))
			else ""
	end
	if card.back then
		local thumbnailImage = choice and choice.thumbnailImage
		card.back.Image = if thumbnailImage and thumbnailImage ~= "" then thumbnailImage else card.defaultBackImage
	end

	local selected = choice ~= nil and choice.choiceId == self._selectedChoiceId
	self:_setCardSelected(card, selected)
	self:_setVoters(card, if choice then getChoiceVoters(state, choice.choiceId) else {})
end

function MapVoteController:_render()
	local state = RoundController:GetState()
	local choices = getVoteChoices(state)
	local serverSelectedChoiceId = findSelectedChoiceId(state)
	if hasChoice(choices, self._pendingChoiceId) then
		self._selectedChoiceId = self._pendingChoiceId
	elseif serverSelectedChoiceId ~= "" then
		self._selectedChoiceId = serverSelectedChoiceId
	elseif not hasChoice(choices, self._selectedChoiceId) then
		self._selectedChoiceId = ""
	end

	if self._timer then
		self._timer.Text = formatTimer(state)
	end

	for index, card in ipairs(self._cards) do
		self:_setCardChoice(card, choices[index], state)
	end
end

function MapVoteController:_syncVisibility()
	local state = RoundController:GetState()
	local roundId = if state and typeof(state.roundId) == "number" then state.roundId else 0
	local votingOpen = state ~= nil
		and state.state == RoundStates.MapVoting
		and state.votingOpen == true
		and #getVoteChoices(state) > 0

	self._votingOpen = votingOpen
	if not votingOpen or isLocalPlayerAFK() then
		if self._frame and self._frame.Visible then
			if isLocalPlayerAFK() then
				self._suppressDismissOnce = true
			end
			FrameController:CloseFrame(FRAME_NAME)
		end
		return
	end

	if self._dismissedRoundId == roundId then
		return
	end
	if self._frame and self._frame.Visible then
		return
	end

	self._openedRoundId = roundId
	FrameController:OpenFrame(FRAME_NAME)
end

function MapVoteController:_sync()
	self:_render()
	self:_syncVisibility()
end

function MapVoteController:_submitChoice(card: CardRecord)
	if card.choiceId == "" then
		return
	end

	self._selectedChoiceId = card.choiceId
	self._pendingChoiceId = card.choiceId
	self:_render()
	RoundController:SubmitMapVote(card.choiceId)
end

function MapVoteController:_captureAvatarTemplate(playerList: Frame?): ImageLabel?
	if not playerList then
		return nil
	end

	local template = nil
	for _, child in ipairs(playerList:GetChildren()) do
		if child:IsA("ImageLabel") and child.Name == "PlayerTemplate" then
			if not template then
				template = child
				template.Visible = false
			else
				child:Destroy()
			end
		end
	end

	return template
end

function MapVoteController:_buildCard(button: ImageButton): CardRecord
	for _, descendant in ipairs(button:GetDescendants()) do
		if descendant:IsA("LocalScript") then
			descendant.Enabled = false
		end
	end

	local scale = button:FindFirstChild(CARD_SCALE_NAME)
	if not (scale and scale:IsA("UIScale")) then
		scale = Instance.new("UIScale")
		scale.Name = CARD_SCALE_NAME
		scale.Parent = button
	end
	scale.Scale = 1

	local back = findImageLabel(button, "Back")
	local playerList = button:FindFirstChild("PlayerList")
	local strokes = {}
	if back then
		for _, descendant in ipairs(back:GetDescendants()) do
			if descendant:IsA("UIStroke") then
				table.insert(strokes, {
					stroke = descendant,
					color = descendant.Color,
					transparency = descendant.Transparency,
					thickness = descendant.Thickness,
				})
			end
		end
	end

	local card: CardRecord = {
		button = button,
		label = findTextLabel(button, "Label"),
		back = back,
		playerList = if playerList and playerList:IsA("Frame") then playerList else nil,
		playerTemplate = nil,
		scale = scale,
		defaultBackImage = if back then back.Image else "",
		defaultBackColor = if back then back.ImageColor3 else Color3.new(1, 1, 1),
		strokes = strokes,
		choiceId = "",
		hovered = false,
		pressed = false,
		selected = false,
		connections = {},
	}
	card.playerTemplate = self:_captureAvatarTemplate(card.playerList)

	self:_trackCardConnection(card, button.MouseEnter:Connect(function()
		card.hovered = true
		self:_setCardScale(card)
	end))
	self:_trackCardConnection(card, button.MouseLeave:Connect(function()
		card.hovered = false
		card.pressed = false
		self:_setCardScale(card)
	end))
	self:_trackCardConnection(card, button.MouseButton1Down:Connect(function()
		card.pressed = true
		self:_setCardScale(card)
	end))
	self:_trackCardConnection(card, button.MouseButton1Up:Connect(function()
		card.pressed = false
		self:_setCardScale(card)
	end))
	self:_trackCardConnection(card, button.Activated:Connect(function()
		card.pressed = false
		self:_submitChoice(card)
	end))

	return card
end

function MapVoteController:_bindMapVote(frame: Instance?)
	disconnectAll(self._mapVoteConnections)
	disconnectAll(self._cardConnections)
	for _, card in ipairs(self._cards) do
		table.clear(card.connections)
	end
	self._frame = nil
	self._timer = nil
	self._cards = {}
	self._selectedChoiceId = ""
	self._pendingChoiceId = ""

	if not (frame and frame:IsA("Frame")) then
		return
	end

	self._frame = frame
	self._timer = findTextLabel(frame, "Timer")
	if not CollectionService:HasTag(frame, FrameController.FrameTag) then
		CollectionService:AddTag(frame, FrameController.FrameTag)
	end
	if frame:GetAttribute(FrameController.ExclusiveAttribute) ~= true then
		frame:SetAttribute(FrameController.ExclusiveAttribute, true)
	end

	self:_trackMapVoteConnection(frame:GetPropertyChangedSignal("Visible"):Connect(function()
		local state = RoundController:GetState()
		local roundId = if state and typeof(state.roundId) == "number" then state.roundId else 0
		if not frame.Visible and self._suppressDismissOnce then
			self._suppressDismissOnce = false
			return
		end
		if not frame.Visible and self._votingOpen and self._openedRoundId == roundId then
			self._dismissedRoundId = roundId
		end
	end))

	local inner = frame:FindFirstChild("Inner")
	if inner then
		for _, child in ipairs(inner:GetChildren()) do
			if child:IsA("ImageButton") then
				table.insert(self._cards, self:_buildCard(child))
			end
		end
	end

	self:_sync()
end

function MapVoteController:_bindFramesGui(frames: Instance?)
	disconnectAll(self._frameConnections)
	if not (frames and frames:IsA("ScreenGui")) then
		self:_bindMapVote(nil)
		return
	end

	self:_bindMapVote(frames:FindFirstChild(FRAME_NAME))
	self:_trackFrameConnection(frames.ChildAdded:Connect(function(child)
		if child.Name == FRAME_NAME then
			task.defer(function()
				self:_bindMapVote(child)
			end)
		end
	end))
end

function MapVoteController:_bindFromPlayerGui()
	self:_bindFramesGui(PlayerGui:FindFirstChild(FRAMES_GUI_NAME))
end

function MapVoteController:OnStart()
	self:_disconnectAll()
	self._dismissedRoundId = nil
	self._openedRoundId = nil
	self._votingOpen = false
	self._suppressDismissOnce = false

	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == FRAMES_GUI_NAME then
			task.defer(function()
				self:_bindFramesGui(child)
			end)
		end
	end))
	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self:_sync()
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "state" or key == "votingOpen" or key == "endsAt" or key == "voteChoices" or key == "voteCounts" or key == "voteVoters" then
			if key == "voteVoters" then
				self._pendingChoiceId = ""
			end
			self:_sync()
		end
	end))
	self:_trackConnection(LocalPlayer:GetAttributeChangedSignal(AFK_ATTR):Connect(function()
		self:_sync()
	end))
	self:_trackConnection(RunService.RenderStepped:Connect(function()
		if self._timer and self._frame and self._frame.Visible then
			self._timer.Text = formatTimer(RoundController:GetState())
		end
	end))

	self:_bindFromPlayerGui()
end

return MapVoteController
