local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local QuestConfig = require(ReplicatedStorage.Shared.Config.QuestConfig)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local DataController = require(script.Parent:WaitForChild("DataController"))
local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = "QuestMenu"
local SIDE_BUTTONS_NAME = "SideButtons"
local QUESTS_LABEL_TEXT = "QUESTS"
local QUESTS_KEY = Schema.Quests and Schema.Quests.key or "quests"
local RUNTIME_ROW_ATTRIBUTE = "QuestControllerRuntimeRow"
local PROGRESS_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local BUTTON_TOGGLE_DEBOUNCE_SECONDS = 0.08

type RowRecord = {
	root: Frame,
	questId: string,
	progressLabel: TextLabel?,
	timer: TextLabel?,
	claimButton: ImageButton?,
	claimLabel: TextLabel?,
	slider: UIGradient?,
	progressValue: NumberValue,
	tween: Tween?,
	connections: { RBXScriptConnection },
}

local QuestController = {}

QuestController._connections = {} :: { RBXScriptConnection }
QuestController._frameConnections = {} :: { RBXScriptConnection }
QuestController._rowConnections = {} :: { RBXScriptConnection }
QuestController._screenGuiConnections = {} :: { RBXScriptConnection }
QuestController._frame = nil :: GuiObject?
QuestController._scroller = nil :: ScrollingFrame?
QuestController._template = nil :: Frame?
QuestController._rows = {} :: { RowRecord }
QuestController._rowsByQuestId = {} :: { [string]: RowRecord }
QuestController._renderedDayKey = nil :: string?
QuestController._remote = nil :: RemoteEvent?
QuestController._lastToggleAt = 0
QuestController._timerLoopStarted = false
QuestController._rebindQueued = false
QuestController._warnedMissingFrame = false
QuestController._warnedMissingButton = false

local function track(list: { RBXScriptConnection }, connection: RBXScriptConnection?)
	if connection then
		table.insert(list, connection)
	end
end

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in ipairs(list) do
		connection:Disconnect()
	end
	table.clear(list)
end

local function findTextLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findButton(parent: Instance?, name: string): ImageButton?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("ImageButton") then child else nil
end

local function findFrame(parent: Instance?, name: string): Frame?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("Frame") then child else nil
end

local function getRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(QuestConfig.RemotesFolderName, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(QuestConfig.RequestRemoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function formatInteger(value: number): string
	local rounded = tostring(math.max(0, math.floor(value + 0.5)))
	local formatted = rounded
	while true do
		local nextFormatted, count = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2", 1)
		formatted = nextFormatted
		if count == 0 then
			return formatted
		end
	end
end

local function formatDuration(seconds: number): string
	local wholeSeconds = math.max(0, math.floor(seconds + 0.5))
	if wholeSeconds >= 3600 then
		local hours = math.floor(wholeSeconds / 3600)
		local minutes = math.floor((wholeSeconds % 3600) / 60)
		return string.format("%dh %02dm", hours, minutes)
	end
	if wholeSeconds >= 60 then
		return string.format("%dm", math.floor(wholeSeconds / 60))
	end
	return string.format("%ds", wholeSeconds)
end

local function formatResetTimer(resetAtUnix: any): string
	local resetAt = if typeof(resetAtUnix) == "number" then resetAtUnix else 0
	local remaining = math.max(0, resetAt - workspace:GetServerTimeNow())
	if remaining >= 3600 then
		local hours = math.floor(remaining / 3600)
		local minutes = math.floor((remaining % 3600) / 60)
		return string.format("%02dh %02dm", hours, minutes)
	end

	local minutes = math.floor(remaining / 60)
	local seconds = math.floor(remaining % 60)
	return string.format("%02dm %02ds", minutes, seconds)
end

local function formatProgress(definition, progress: number): string
	local target = math.max(0, tonumber(definition.target) or 0)
	if definition.metric == QuestConfig.Metrics.TimePlayed then
		return ("%s / %s"):format(formatDuration(progress), formatDuration(target))
	end

	return ("%s / %s"):format(formatInteger(progress), formatInteger(target))
end

local function getQuestState()
	local state = DataController:Get(QUESTS_KEY)
	if typeof(state) ~= "table" or typeof(state.dayKey) ~= "string" or state.dayKey == "" then
		return nil
	end
	return state
end

local function getProgress(state, questId: string): number
	local progress = state and state.progress
	local value = if typeof(progress) == "table" then progress[questId] else 0
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue < 0 then
		return 0
	end
	return math.floor(numberValue + 0.5)
end

local function isClaimed(state, questId: string): boolean
	local claimed = state and state.claimed
	return typeof(claimed) == "table" and claimed[questId] == true
end

local function setSliderProgress(slider: UIGradient?, ratio: number)
	if not slider then
		return
	end

	local clamped = math.clamp(ratio, 0, 1)
	if clamped <= 0 then
		slider.Transparency = NumberSequence.new(1)
		return
	end
	if clamped >= 1 then
		slider.Transparency = NumberSequence.new(0)
		return
	end

	local edge = math.clamp(clamped, 0.001, 0.999)
	local fadeEdge = math.clamp(edge + 0.002, 0.001, 1)
	slider.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(edge, 0),
		NumberSequenceKeypoint.new(fadeEdge, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function setButtonEnabled(button: ImageButton?, enabled: boolean)
	if not button then
		return
	end

	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
	button.ImageTransparency = if enabled then 0 else 0.35
end

local function setLabelMuted(label: TextLabel?, muted: boolean)
	if label then
		label.TextTransparency = if muted then 0.32 else 0
	end
end

local function getSortedTemplates(scroller: ScrollingFrame): { Frame }
	local templates = {}
	for index, child in ipairs(scroller:GetChildren()) do
		if child:IsA("Frame") and child.Name == "Template" and child:GetAttribute(RUNTIME_ROW_ATTRIBUTE) ~= true then
			table.insert(templates, {
				frame = child,
				index = index,
			})
		end
	end

	table.sort(templates, function(left, right)
		if left.frame.LayoutOrder == right.frame.LayoutOrder then
			return left.index < right.index
		end
		return left.frame.LayoutOrder < right.frame.LayoutOrder
	end)

	local frames = {}
	for _, entry in ipairs(templates) do
		table.insert(frames, entry.frame)
	end
	return frames
end

local function findQuestButton(root: Instance?): ImageButton?
	if not root then
		return nil
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
		local namedButton = sideButtons:FindFirstChild("Quests")
		if namedButton and namedButton:IsA("ImageButton") then
			return namedButton
		end

		for _, child in ipairs(sideButtons:GetChildren()) do
			if child:IsA("ImageButton") then
				local label = findTextLabel(child, "Label")
				if label and string.upper(label.Text) == QUESTS_LABEL_TEXT then
					return child
				end
			end
		end
	end

	return nil
end

local function shouldRebindFor(descendant: Instance): boolean
	if descendant.Name == FRAME_NAME or descendant.Name == SIDE_BUTTONS_NAME or descendant.Name == "Quests" then
		return true
	end

	if descendant.Name == "Label" and descendant:FindFirstAncestor(SIDE_BUTTONS_NAME) then
		return true
	end

	return false
end

function QuestController:_destroyRows()
	for _, row in ipairs(self._rows) do
		if row.tween then
			row.tween:Cancel()
			row.tween = nil
		end
		for _, connection in ipairs(row.connections) do
			connection:Disconnect()
		end
		row.progressValue:Destroy()
		if row.root.Parent then
			row.root:Destroy()
		end
	end

	self._rows = {}
	self._rowsByQuestId = {}
	disconnectAll(self._rowConnections)
end

function QuestController:_setClaimState(row: RowRecord, complete: boolean, claimed: boolean)
	setButtonEnabled(row.claimButton, complete and not claimed)
	if row.claimLabel then
		row.claimLabel.Text = if claimed then "CLAIMED" else "CLAIM"
	end
	setLabelMuted(row.claimLabel, not complete or claimed)
end

function QuestController:_updateRow(row: RowRecord, state)
	local definition = QuestConfig.GetDefinition(row.questId)
	if not definition then
		row.root.Visible = false
		return
	end

	local progress = getProgress(state, row.questId)
	local target = math.max(0, tonumber(definition.target) or 0)
	local ratio = if target > 0 then math.clamp(progress / target, 0, 1) else 0
	local claimed = isClaimed(state, row.questId)
	local complete = target > 0 and progress >= target

	if row.progressLabel then
		row.progressLabel.Text = formatProgress(definition, progress)
	end
	self:_setClaimState(row, complete, claimed)

	if row.tween then
		row.tween:Cancel()
	end
	row.tween = TweenService:Create(row.progressValue, PROGRESS_TWEEN, { Value = ratio })
	row.tween:Play()
end

function QuestController:_buildRow(template: Frame, questId: string, layoutOrder: number): RowRecord?
	local definition = QuestConfig.GetDefinition(questId)
	if not definition then
		return nil
	end

	local rowRoot = template:Clone()
	rowRoot.Name = "Quest_" .. questId
	rowRoot.LayoutOrder = layoutOrder
	rowRoot.Visible = true
	rowRoot:SetAttribute(RUNTIME_ROW_ATTRIBUTE, true)
	rowRoot.Parent = self._scroller

	local questLabel = findTextLabel(rowRoot, "Quest")
	if questLabel then
		questLabel.Text = ("%s (+$%s)"):format(definition.displayName or definition.id, formatInteger(definition.rewardCash or 0))
	end

	local bar = findFrame(rowRoot, "Bar")
	local progressLabel = findTextLabel(bar, "ProgressLabel")
	local slider = bar and bar:FindFirstChild("Slider")
	local claimButton = findButton(rowRoot, "ClaimButton")
	local progressValue = Instance.new("NumberValue")
	progressValue.Value = 0

	local row: RowRecord = {
		root = rowRoot,
		questId = questId,
		progressLabel = progressLabel,
		timer = findTextLabel(rowRoot, "Timer"),
		claimButton = claimButton,
		claimLabel = findTextLabel(claimButton, "Label"),
		slider = if slider and slider:IsA("UIGradient") then slider else nil,
		progressValue = progressValue,
		tween = nil,
		connections = {},
	}

	setSliderProgress(row.slider, 0)
	track(row.connections, progressValue.Changed:Connect(function(value)
		setSliderProgress(row.slider, value)
	end))
	track(row.connections, claimButton and claimButton.Activated:Connect(function()
		self:_claimQuest(questId)
	end))

	return row
end

function QuestController:_rebuildRows(state)
	self:_destroyRows()
	self._renderedDayKey = if state then state.dayKey else nil

	local scroller = self._scroller
	local template = self._template
	if not (scroller and template and state and typeof(state.dayKey) == "string") then
		return
	end

	for layoutOrder, questId in ipairs(QuestConfig.GetActiveQuestIds(state.dayKey)) do
		local row = self:_buildRow(template, questId, layoutOrder)
		if row then
			table.insert(self._rows, row)
			self._rowsByQuestId[questId] = row
		end
	end
end

function QuestController:_updateTimers()
	local state = getQuestState()
	for _, row in ipairs(self._rows) do
		if row.timer then
			row.timer.Text = formatResetTimer(state and state.resetAtUnix)
		end
	end
end

function QuestController:_render()
	local state = getQuestState()
	if not state then
		return
	end

	if self._renderedDayKey ~= state.dayKey or #self._rows == 0 then
		self:_rebuildRows(state)
	end

	for _, row in ipairs(self._rows) do
		self:_updateRow(row, state)
	end
	self:_updateTimers()
end

function QuestController:_claimQuest(questId: string)
	local remote = self._remote
	if not remote then
		return
	end

	remote:FireServer({
		action = QuestConfig.Actions.Claim,
		questId = questId,
	})
end

function QuestController:_ensureFrameRegistered(frame: GuiObject)
	if not CollectionService:HasTag(frame, FrameController.FrameTag) then
		CollectionService:AddTag(frame, FrameController.FrameTag)
	end

	if frame:GetAttribute(FrameController.ExclusiveAttribute) ~= false then
		frame:SetAttribute(FrameController.ExclusiveAttribute, false)
	end

	local slideFromAttribute = FrameController.SlideFromAttribute or "SlideFrom"
	local slideFromRight = FrameController.SlideFromRight or "Right"
	if frame:GetAttribute(slideFromAttribute) ~= slideFromRight then
		frame:SetAttribute(slideFromAttribute, slideFromRight)
	end
end

function QuestController:_bindFrame(frame: Instance?)
	disconnectAll(self._frameConnections)
	self:_destroyRows()
	self._frame = nil
	self._scroller = nil
	self._template = nil
	self._renderedDayKey = nil

	if not (frame and frame:IsA("GuiObject")) then
		return
	end

	self._frame = frame
	self:_ensureFrameRegistered(frame)

	local closeButton = findButton(frame, "CloseButton")
	track(self._frameConnections, closeButton and closeButton.Activated:Connect(function()
		FrameController:CloseFrame(FRAME_NAME)
	end))

	local scroller = frame:FindFirstChild("ScrollingFrame")
	if scroller and scroller:IsA("ScrollingFrame") then
		self._scroller = scroller
		scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y

		local templates = getSortedTemplates(scroller)
		self._template = templates[1]
		for _, template in ipairs(templates) do
			template.Visible = false
		end
	end

	self:_render()
end

function QuestController:_toggleFrame()
	local now = os.clock()
	if now - self._lastToggleAt < BUTTON_TOGGLE_DEBOUNCE_SECONDS then
		return
	end

	self._lastToggleAt = now
	FrameController:ToggleFrame(FRAME_NAME)
end

function QuestController:_warnMissingFrame()
	if self._warnedMissingFrame then
		return
	end

	self._warnedMissingFrame = true
	warn(("[QuestController] Could not find %s under PlayerGui; quests button cannot open the frame yet."):format(FRAME_NAME))
end

function QuestController:_warnMissingButton()
	if self._warnedMissingButton then
		return
	end

	self._warnedMissingButton = true
	warn(("[QuestController] Could not find a %s button under any %s frame in PlayerGui."):format(QUESTS_LABEL_TEXT, SIDE_BUTTONS_NAME))
end

function QuestController:_scheduleRebind()
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

function QuestController:_bindPlayerGui(root: Instance?)
	disconnectAll(self._screenGuiConnections)

	if not root then
		self:_bindFrame(nil)
		return
	end

	local frame = root:FindFirstChild(FRAME_NAME, true)
	self:_bindFrame(frame)
	if frame then
		self._warnedMissingFrame = false
	else
		self:_warnMissingFrame()
	end

	local questButton = findQuestButton(root)
	if questButton then
		self._warnedMissingButton = false
		questButton.Active = true
		questButton.Selectable = true
		track(self._screenGuiConnections, questButton.Activated:Connect(function()
			self:_toggleFrame()
		end))
		track(self._screenGuiConnections, questButton.MouseButton1Click:Connect(function()
			self:_toggleFrame()
		end))
	else
		self:_warnMissingButton()
	end

	track(self._screenGuiConnections, root.DescendantAdded:Connect(function(descendant)
		if shouldRebindFor(descendant) then
			self:_scheduleRebind()
		end
	end))
end

function QuestController:_bindCurrentScreenGui()
	self:_bindPlayerGui(PlayerGui)
end

function QuestController:_bindRemote()
	self._remote = getRemote()
	if not self._remote then
		return
	end

	track(self._connections, self._remote.OnClientEvent:Connect(function()
		self:_render()
	end))
end

function QuestController:_startTimerLoop()
	if self._timerLoopStarted then
		return
	end

	self._timerLoopStarted = true
	task.spawn(function()
		while self._timerLoopStarted do
			self:_updateTimers()
			task.wait(1)
		end
	end)
end

function QuestController:OnStart()
	disconnectAll(self._connections)
	disconnectAll(self._frameConnections)
	disconnectAll(self._screenGuiConnections)
	self:_destroyRows()

	self:_bindCurrentScreenGui()
	task.spawn(function()
		self:_bindRemote()
	end)
	self:_startTimerLoop()

	track(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == FRAME_NAME or child.Name == SIDE_BUTTONS_NAME or child:IsA("ScreenGui") then
			self:_scheduleRebind()
		end
	end))

	track(self._connections, DataController.DataReceived:Connect(function()
		self:_render()
	end))
	track(self._connections, DataController.DataUpdated:Connect(function(key)
		if key == QUESTS_KEY then
			self:_render()
		end
	end))
end

return QuestController
