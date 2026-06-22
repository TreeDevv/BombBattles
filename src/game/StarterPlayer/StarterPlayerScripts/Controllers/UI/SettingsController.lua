local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local ColorPicker = require(ReplicatedStorage.Shared.UI.ColorPicker)
local PlayerSettings = require(ReplicatedStorage.Shared.Common.PlayerSettings)
local SettingsConfig = require(ReplicatedStorage.Shared.Config.SettingsConfig)
local AudioSettings = require(ReplicatedStorage.Shared.Audio.AudioSettings)
local DataController = require(script.Parent:WaitForChild("DataController"))
local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local SETTINGS_KEY = "playerSettings"
local FRAMES_GUI_NAME = "Frames"
local FRAME_NAME = "Settings"
local TEMPLATE_NAMES = {
	KeybindTemplate = true,
	SliderTemplate = true,
	ToggleTemplate = true,
	ColorTemplate = true,
	CategoryTemplate = true,
}
local ROW_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

type RowRecord = {
	id: string?,
	definition: any?,
	row: GuiObject,
	kind: string,
	connections: { RBXScriptConnection },
}

local SettingsController = {}

SettingsController._connections = {} :: { RBXScriptConnection }
SettingsController._rowRecords = {} :: { RowRecord }
SettingsController._frame = nil :: GuiObject?
SettingsController._scrollingFrame = nil :: ScrollingFrame?
SettingsController._templates = {} :: { [string]: GuiObject }
SettingsController._updateRemote = nil :: RemoteEvent?
SettingsController._listeningForKey = nil :: string?
SettingsController._keyCaptureConnection = nil :: RBXScriptConnection?
SettingsController._colorPicker = nil :: any?

local function getRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(SettingsConfig.RemotesFolderName, 15)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(SettingsConfig.UpdateRemoteName, 15)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function findSettingsFrame(): GuiObject?
	local frames = PlayerGui:FindFirstChild(FRAMES_GUI_NAME)
	local frame = frames and frames:FindFirstChild(FRAME_NAME)
	return if frame and frame:IsA("GuiObject") then frame else nil
end

local function findScrollingFrame(frame: GuiObject): ScrollingFrame?
	local scrollingFrame = frame:FindFirstChild("ScrollingFrame", true)
	return if scrollingFrame and scrollingFrame:IsA("ScrollingFrame") then scrollingFrame else nil
end

local function sortByPosition(a: GuiObject, b: GuiObject): boolean
	if math.abs(a.Position.Y.Scale - b.Position.Y.Scale) > 0.001 then
		return a.Position.Y.Scale < b.Position.Y.Scale
	end
	return a.Position.Y.Offset < b.Position.Y.Offset
end

local function getRowLabels(row: Instance): { TextLabel }
	local labels = {}
	for _, descendant in ipairs(row:GetDescendants()) do
		if descendant:IsA("TextLabel") and descendant.Name == "Label" then
			table.insert(labels, descendant)
		end
	end
	table.sort(labels, sortByPosition)
	return labels
end

local function setRowText(row: GuiObject, title: string, description: string?)
	local labels = getRowLabels(row)
	if labels[1] then
		labels[1].Text = title
	end
	if labels[2] then
		labels[2].Text = description or ""
	end
end

local function disableLocalScripts(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("LocalScript") then
			descendant.Enabled = false
		end
	end
end

local function getRestoreButton(row: Instance): GuiButton?
	local button = row:FindFirstChild("RestoreButton", true)
	return if button and button:IsA("GuiButton") then button else nil
end

local function getSliderParts(row: Instance): (GuiButton?, GuiObject?, TextBox?)
	local max = row:FindFirstChild("Max", true)
	local bar = max and max:FindFirstChild("Bar")
	local numberInput = row:FindFirstChild("NumberInput", true)
	local textBox = numberInput and numberInput:FindFirstChild("TextBox", true)
	return if max and max:IsA("GuiButton") then max else nil,
		if bar and bar:IsA("GuiObject") then bar else nil,
		if textBox and textBox:IsA("TextBox") then textBox else nil
end

local function getToggleParts(row: Instance): (GuiButton?, GuiObject?)
	local button = row:FindFirstChild("ToggleButton", true)
	local icon = button and button:FindFirstChild("ToggledOnIcon")
	return if button and button:IsA("GuiButton") then button else nil,
		if icon and icon:IsA("GuiObject") then icon else nil
end

local function getColorButton(row: Instance): GuiButton?
	local button = row:FindFirstChild("ColorButton", true)
	return if button and button:IsA("GuiButton") then button else nil
end

local function getKeyButton(row: Instance): TextButton?
	local namedButton = row:FindFirstChild("KeyButton", true)
	if namedButton and namedButton:IsA("TextButton") then
		return namedButton
	end

	local buttons = {}
	for _, descendant in ipairs(row:GetDescendants()) do
		if descendant:IsA("TextButton") and descendant.Name ~= "RestoreButton" then
			table.insert(buttons, descendant)
		end
	end
	table.sort(buttons, sortByPosition)
	return buttons[1]
end

local function keepSingleKeyButton(row: Instance): TextButton?
	local primary = getKeyButton(row)
	for _, descendant in ipairs(row:GetDescendants()) do
		if descendant:IsA("TextButton") and descendant.Name ~= "RestoreButton" and descendant ~= primary then
			descendant.Visible = false
			descendant.Active = false
			descendant.Interactable = false
		end
	end
	if primary then
		primary.Name = "KeyButton"
		primary.Visible = true
		primary.Active = true
		primary.Interactable = true
	end
	return primary
end

local function playButtonPress(button: GuiObject)
	local scale = math.clamp(PlayerSettings:GetNumberScale("uiAnimationScale"), 0, 1)
	if scale <= 0 then
		return
	end

	local originalSize = button:GetAttribute("SettingsOriginalSize")
	if typeof(originalSize) ~= "UDim2" then
		originalSize = button.Size
		button:SetAttribute("SettingsOriginalSize", originalSize)
	end

	local smallSize = UDim2.new(
		originalSize.X.Scale * (1 - 0.06 * scale),
		originalSize.X.Offset * (1 - 0.06 * scale),
		originalSize.Y.Scale * (1 - 0.06 * scale),
		originalSize.Y.Offset * (1 - 0.06 * scale)
	)
	TweenService:Create(button, ROW_TWEEN, { Size = smallSize }):Play()
	task.delay(0.08, function()
		if button.Parent then
			TweenService:Create(button, ROW_TWEEN, { Size = originalSize }):Play()
		end
	end)
end

local function keyDisplayName(keyName: string): string
	return tostring(keyName):gsub("Left", "L "):gsub("Right", "R ")
end

function SettingsController:_disconnectRows()
	for _, record in ipairs(self._rowRecords) do
		for _, connection in ipairs(record.connections) do
			connection:Disconnect()
		end
		if record.row.Parent and not TEMPLATE_NAMES[record.row.Name] then
			record.row:Destroy()
		end
	end
	self._rowRecords = {}
end

function SettingsController:_trackRecord(record: RowRecord, connection: RBXScriptConnection)
	table.insert(record.connections, connection)
end

function SettingsController:_sendSetting(id: string, value: any)
	local normalized = PlayerSettings:ApplyLocal(id, value)
	if normalized == nil then
		return
	end

	local remote = self._updateRemote
	if remote then
		remote:FireServer(id, normalized)
	end
	self:_syncRows()
end

function SettingsController:_previewSetting(id: string, value: any): any
	local normalized = PlayerSettings:ApplyLocal(id, value)
	if normalized == nil then
		return nil
	end
	self:_syncRows()
	return normalized
end

function SettingsController:_resetSetting(definition)
	self:_sendSetting(definition.id, definition.default)
end

function SettingsController:_cloneTemplate(templateName: string, rowName: string): GuiObject?
	local template = self._templates[templateName]
	local scrollingFrame = self._scrollingFrame
	if not (template and scrollingFrame) then
		return nil
	end

	local row = template:Clone()
	row.Name = rowName
	row.LayoutOrder = (#self._rowRecords + 1) * 10
	row.Visible = true
	disableLocalScripts(row)
	row.Parent = scrollingFrame
	return row
end

function SettingsController:_bindRestore(record: RowRecord)
	local restoreButton = getRestoreButton(record.row)
	if not (restoreButton and record.definition) then
		return
	end

	self:_trackRecord(record, restoreButton.Activated:Connect(function()
		playButtonPress(restoreButton)
		self:_resetSetting(record.definition)
	end))
end

function SettingsController:_addCategory(section): RowRecord?
	local row = self:_cloneTemplate("CategoryTemplate", "Category_" .. section.id)
	if not row then
		return nil
	end
	if row:IsA("TextLabel") or row:IsA("TextButton") then
		row.Text = section.label
	end

	local record = {
		id = nil,
		definition = nil,
		row = row,
		kind = "category",
		connections = {},
	}
	table.insert(self._rowRecords, record)
	return record
end

function SettingsController:_addToggle(definition): RowRecord?
	local row = self:_cloneTemplate("ToggleTemplate", definition.id)
	if not row then
		return nil
	end

	setRowText(row, definition.label, definition.description)
	local record = {
		id = definition.id,
		definition = definition,
		row = row,
		kind = "toggle",
		connections = {},
	}
	table.insert(self._rowRecords, record)
	self:_bindRestore(record)

	local button = getToggleParts(row)
	if button then
		self:_trackRecord(record, button.Activated:Connect(function()
			playButtonPress(button)
			self:_sendSetting(definition.id, not PlayerSettings:Get(definition.id))
		end))
	end
	return record
end

function SettingsController:_addSlider(definition): RowRecord?
	local row = self:_cloneTemplate("SliderTemplate", definition.id)
	if not row then
		return nil
	end

	setRowText(row, definition.label, definition.description)
	local record = {
		id = definition.id,
		definition = definition,
		row = row,
		kind = "slider",
		connections = {},
	}
	table.insert(self._rowRecords, record)
	self:_bindRestore(record)

	local maxButton, _, textBox = getSliderParts(row)
	local dragging = false
	local pendingValue = nil

	local function setFromScreenX(x: number)
		if not maxButton then
			return
		end
		local alpha = math.clamp((x - maxButton.AbsolutePosition.X) / math.max(maxButton.AbsoluteSize.X, 1), 0, 1)
		local value = (definition.min or 0) + ((definition.max or 100) - (definition.min or 0)) * alpha
		pendingValue = self:_previewSetting(definition.id, value)
	end

	if maxButton then
		self:_trackRecord(record, maxButton.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				pendingValue = nil
				setFromScreenX(input.Position.X)
			end
		end))
		self:_trackRecord(record, UserInputService.InputChanged:Connect(function(input)
			if not dragging then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
				setFromScreenX(input.Position.X)
			end
		end))
		self:_trackRecord(record, UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				if dragging and pendingValue ~= nil then
					self:_sendSetting(definition.id, pendingValue)
				end
				dragging = false
				pendingValue = nil
			end
		end))
	end

	if textBox then
		self:_trackRecord(record, textBox.FocusLost:Connect(function()
			self:_sendSetting(definition.id, textBox.Text)
		end))
	end
	return record
end

function SettingsController:_addColor(definition): RowRecord?
	local row = self:_cloneTemplate("ColorTemplate", definition.id)
	if not row then
		return nil
	end

	setRowText(row, definition.label, definition.description)
	local record = {
		id = definition.id,
		definition = definition,
		row = row,
		kind = "color",
		connections = {},
	}
	table.insert(self._rowRecords, record)
	self:_bindRestore(record)

	local button = getColorButton(row)
	if button then
		self:_trackRecord(record, button.Activated:Connect(function()
			playButtonPress(button)
			if self._colorPicker then
				self._colorPicker:Destroy()
				self._colorPicker = nil
			end

			local picker = ColorPicker.new()
			self._colorPicker = picker
			local currentColor = SettingsConfig.HexToColor3(PlayerSettings:Get(definition.id))
			if currentColor then
				picker:SetColor(currentColor)
			end
			picker:Start()
			picker.Closed:Once(function(color: Color3, confirmed: boolean?)
				if confirmed == true then
					self:_sendSetting(definition.id, SettingsConfig.Color3ToHex(color))
				end
				if self._colorPicker == picker then
					self._colorPicker = nil
				end
				picker:Destroy()
			end)
		end))
	end
	return record
end

function SettingsController:_beginKeyCapture(definition)
	self._listeningForKey = definition.id
	self:_syncRows()
	if self._keyCaptureConnection then
		self._keyCaptureConnection:Disconnect()
	end

	self._keyCaptureConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if self._listeningForKey ~= definition.id then
			return
		end
		if gameProcessed and not UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.Unknown then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			self._listeningForKey = nil
			if self._keyCaptureConnection then
				self._keyCaptureConnection:Disconnect()
				self._keyCaptureConnection = nil
			end
			self:_syncRows()
			return
		end

		self._listeningForKey = nil
		if self._keyCaptureConnection then
			self._keyCaptureConnection:Disconnect()
			self._keyCaptureConnection = nil
		end
		self:_sendSetting(definition.id, input.KeyCode.Name)
	end)
end

function SettingsController:_addKeybind(definition): RowRecord?
	local row = self:_cloneTemplate("KeybindTemplate", definition.id)
	if not row then
		return nil
	end

	setRowText(row, definition.label, definition.description)
	local record = {
		id = definition.id,
		definition = definition,
		row = row,
		kind = "keybind",
		connections = {},
	}
	table.insert(self._rowRecords, record)
	self:_bindRestore(record)

	local button = keepSingleKeyButton(row)
	if button then
		self:_trackRecord(record, button.Activated:Connect(function()
			playButtonPress(button)
			self:_beginKeyCapture(definition)
		end))
	end
	return record
end

function SettingsController:_buildRows()
	self:_disconnectRows()
	local scrollingFrame = self._scrollingFrame
	if not scrollingFrame then
		return
	end

	for _, child in ipairs(scrollingFrame:GetChildren()) do
		if child:IsA("GuiObject") and TEMPLATE_NAMES[child.Name] then
			child.Visible = false
			self._templates[child.Name] = child
		end
	end

	for _, section in ipairs(SettingsConfig.Sections) do
		self:_addCategory(section)
		for _, definition in ipairs(section.settings) do
			if definition.kind == "toggle" then
				self:_addToggle(definition)
			elseif definition.kind == "slider" then
				self:_addSlider(definition)
			elseif definition.kind == "color" then
				self:_addColor(definition)
			elseif definition.kind == "keybind" then
				self:_addKeybind(definition)
			end
		end
	end

	self:_syncRows()
end

function SettingsController:_syncSlider(record: RowRecord)
	local definition = record.definition
	local _, bar, textBox = getSliderParts(record.row)
	if not definition then
		return
	end

	local rawValue = PlayerSettings:Get(definition.id)
	local displayValue = rawValue
	if definition.id == "explosionVfxQuality" or definition.id == "debrisVfxQuality" then
		displayValue = SettingsConfig.QualityToSlider(rawValue)
	end

	local minValue = tonumber(definition.min) or 0
	local maxValue = tonumber(definition.max) or 100
	local numberValue = math.clamp(tonumber(displayValue) or minValue, minValue, maxValue)
	local alpha = (numberValue - minValue) / math.max(maxValue - minValue, 1)
	if bar then
		bar.Size = UDim2.new(alpha, 0, bar.Size.Y.Scale, bar.Size.Y.Offset)
	end
	if textBox then
		textBox.Text = tostring(math.floor(numberValue + 0.5))
	end
end

function SettingsController:_syncToggle(record: RowRecord)
	local _, icon = getToggleParts(record.row)
	if icon and record.id then
		icon.Visible = PlayerSettings:Get(record.id) == true
	end
end

function SettingsController:_syncColor(record: RowRecord)
	local button = getColorButton(record.row)
	if not (button and record.id) then
		return
	end

	local color = SettingsConfig.HexToColor3(PlayerSettings:Get(record.id))
	button.BackgroundColor3 = color or Color3.fromRGB(255, 255, 255)
end

function SettingsController:_syncKeybind(record: RowRecord)
	if not record.id then
		return
	end

	local text = if self._listeningForKey == record.id then "..." else keyDisplayName(PlayerSettings:Get(record.id))
	local button = getKeyButton(record.row)
	if button then
		button.Text = text
	end
end

function SettingsController:_syncRows()
	for _, record in ipairs(self._rowRecords) do
		if record.kind == "slider" then
			self:_syncSlider(record)
		elseif record.kind == "toggle" then
			self:_syncToggle(record)
		elseif record.kind == "color" then
			self:_syncColor(record)
		elseif record.kind == "keybind" then
			self:_syncKeybind(record)
		end
	end
	AudioSettings.Apply(PlayerSettings:GetAll())
end

function SettingsController:_bindFrame()
	local frame = findSettingsFrame()
	if not frame or frame == self._frame then
		return
	end

	self._frame = frame
	self._scrollingFrame = findScrollingFrame(frame)
	self._templates = {}

	local closeButton = frame:FindFirstChild("CloseButton", true)
	if closeButton and closeButton:IsA("GuiButton") then
		table.insert(self._connections, closeButton.Activated:Connect(function()
			FrameController:CloseFrame(FRAME_NAME)
		end))
	end

	self:_buildRows()
end

function SettingsController:_applyData(data)
	local settings = if typeof(data) == "table" then data[SETTINGS_KEY] else nil
	PlayerSettings:ApplySnapshot(settings)
	self:_syncRows()
end

function SettingsController:OnStart()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self:_disconnectRows()
	self._updateRemote = getRemote()

	table.insert(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == FRAMES_GUI_NAME then
			task.defer(function()
				self:_bindFrame()
			end)
		end
	end))
	table.insert(self._connections, DataController.DataReceived:Connect(function(data)
		self:_applyData(data)
	end))
	table.insert(self._connections, DataController.DataUpdated:Connect(function(key, value)
		if key == SETTINGS_KEY then
			PlayerSettings:ApplySnapshot(value)
			self:_syncRows()
		end
	end))
	table.insert(self._connections, PlayerSettings.Changed:Connect(function()
		self:_syncRows()
	end))

	self:_bindFrame()
	self:_applyData(DataController:Get())
end

return SettingsController
