local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

export type ColorPicker = {
	currentColor: Color3,
	active: boolean,
	Opened: RBXScriptSignal,
	Closed: RBXScriptSignal,
	Changed: RBXScriptSignal,
	SetColor: (self: ColorPicker, color: Color3) -> (),
	GetColor: (self: ColorPicker) -> Color3,
	Start: (self: ColorPicker) -> (),
	Cancel: (self: ColorPicker) -> (),
	Destroy: (self: ColorPicker) -> (),
}

local LocalPlayer = Players.LocalPlayer

local ColorPicker = {}
ColorPicker.__index = ColorPicker

local function getTemplate(): GuiObject?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local ui = assets and assets:FindFirstChild("UI")
	local colorPicker = ui and ui:FindFirstChild("ColorPicker")
	local template = colorPicker and colorPicker:FindFirstChild("Main")
	return if template and template:IsA("GuiObject") then template else nil
end

local function getPickerGui(): ScreenGui
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("ColorPicker")
	if existing and existing:IsA("ScreenGui") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ColorPicker"
	screenGui.DisplayOrder = 1000
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.ScreenInsets = Enum.ScreenInsets.None
	screenGui.Parent = playerGui
	return screenGui
end

local function updateTextBoxNumber(textBox: TextBox, value: number | string, multiplier: number?)
	local text: string
	if typeof(value) == "number" and multiplier then
		text = tostring(math.round(value * multiplier))
	else
		text = tostring(value)
	end
	textBox.Text = text
	textBox.PlaceholderText = text
end

local function updateColor(self, arg1: Color3 | number, arg2: number?, arg3: number?)
	local hue: number
	local sat: number
	local val: number

	if typeof(arg1) == "Color3" then
		hue, sat, val = arg1:ToHSV()
		self.currentColor = arg1
	elseif typeof(arg1) == "number" and typeof(arg2) == "number" and typeof(arg3) == "number" then
		hue = arg1
		sat = arg2
		val = arg3
		self.currentColor = Color3.fromHSV(hue, sat, val)
	else
		return
	end

	self.hue = hue
	self.sat = sat
	self.val = val
	self.previewColor.BackgroundColor3 = self.currentColor

	updateTextBoxNumber(self.textBoxNumber.Hue, hue, 359)
	updateTextBoxNumber(self.textBoxNumber.Saturation, sat, 255)
	updateTextBoxNumber(self.textBoxNumber.Value, val, 255)
	updateTextBoxNumber(self.textBoxNumber.Red, self.currentColor.R, 255)
	updateTextBoxNumber(self.textBoxNumber.Green, self.currentColor.G, 255)
	updateTextBoxNumber(self.textBoxNumber.Blue, self.currentColor.B, 255)
	updateTextBoxNumber(self.textBoxNumber.HTML, self.currentColor:ToHex())

	self.valUiGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)),
		ColorSequenceKeypoint.new(1, Color3.fromHSV(hue, sat, 1)),
	})
	self.valueCursor.Position = UDim2.fromScale(0, 1 - val)
	self.colorCursor.Position = UDim2.fromScale(1 - hue, 1 - sat)
	self._Changed:Fire(self.currentColor)
end

local function processTextBoxNumber(self, text: string): number?
	local numberValue = tonumber(text)
	if not numberValue then
		updateColor(self, self.currentColor)
		return nil
	end
	return numberValue
end

local function connect(connectionTable: { RBXScriptConnection }, signal: RBXScriptSignal, callback)
	table.insert(connectionTable, signal:Connect(callback))
end

local function connectEvents(self)
	local function updateBounds()
		local absoluteColorPos = self.colorButton.AbsolutePosition
		local absoluteColorSize = self.colorButton.AbsoluteSize
		self.minX = absoluteColorPos.X
		self.maxX = absoluteColorPos.X + absoluteColorSize.X
		self.minY = absoluteColorPos.Y + GuiService.TopbarInset.Height
		self.maxY = absoluteColorPos.Y + absoluteColorSize.Y + GuiService.TopbarInset.Height
	end

	connect(self._connections, self.colorButton:GetPropertyChangedSignal("AbsolutePosition"), updateBounds)
	connect(self._connections, self.colorButton:GetPropertyChangedSignal("AbsoluteSize"), updateBounds)
	connect(self._connections, GuiService:GetPropertyChangedSignal("TopbarInset"), updateBounds)
	updateBounds()

	connect(self._connections, self.colorButton.MouseButton1Down, function()
		while UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) and self.active do
			local mousePos = UserInputService:GetMouseLocation()
			local percentX = 1 - math.clamp((mousePos.X - self.minX) / math.max(self.maxX - self.minX, 1), 0, 1)
			local percentY = 1 - math.clamp((mousePos.Y - self.minY) / math.max(self.maxY - self.minY, 1), 0, 1)
			updateColor(self, percentX, percentY, self.val)
			task.wait()
		end
	end)

	local function dragValue()
		while UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) and self.active do
			local mousePos = UserInputService:GetMouseLocation()
			local percent = 1 - math.clamp((mousePos.Y - self.minY) / math.max(self.maxY - self.minY, 1), 0, 1)
			updateColor(self, self.hue, self.sat, percent)
			task.wait()
		end
	end

	connect(self._connections, self.valueButton.MouseButton1Down, dragValue)
	connect(self._connections, self.valueCursor.TextButton.MouseButton1Down, dragValue)
	connect(self._connections, self.okButton.MouseButton1Click, function()
		self.frame.Visible = false
		self.active = false
		self._Closed:Fire(self.currentColor, true)
	end)
	connect(self._connections, self.cancelButton.MouseButton1Click, function()
		self.frame.Visible = false
		self.active = false
		self._Closed:Fire(self.currentColor, false)
	end)

	connect(self._connections, self.textBoxNumber.Red.FocusLost, function()
		local red = processTextBoxNumber(self, self.textBoxNumber.Red.Text)
		if red then
			updateColor(self, Color3.new(math.clamp(red, 0, 255) / 255, self.currentColor.G, self.currentColor.B))
		end
	end)
	connect(self._connections, self.textBoxNumber.Green.FocusLost, function()
		local green = processTextBoxNumber(self, self.textBoxNumber.Green.Text)
		if green then
			updateColor(self, Color3.new(self.currentColor.R, math.clamp(green, 0, 255) / 255, self.currentColor.B))
		end
	end)
	connect(self._connections, self.textBoxNumber.Blue.FocusLost, function()
		local blue = processTextBoxNumber(self, self.textBoxNumber.Blue.Text)
		if blue then
			updateColor(self, Color3.new(self.currentColor.R, self.currentColor.G, math.clamp(blue, 0, 255) / 255))
		end
	end)
	connect(self._connections, self.textBoxNumber.Hue.FocusLost, function()
		local hue = processTextBoxNumber(self, self.textBoxNumber.Hue.Text)
		if hue then
			updateColor(self, math.clamp(hue, 0, 359) / 359, self.sat, self.val)
		end
	end)
	connect(self._connections, self.textBoxNumber.Saturation.FocusLost, function()
		local sat = processTextBoxNumber(self, self.textBoxNumber.Saturation.Text)
		if sat then
			updateColor(self, self.hue, math.clamp(sat, 0, 255) / 255, self.val)
		end
	end)
	connect(self._connections, self.textBoxNumber.Value.FocusLost, function()
		local val = processTextBoxNumber(self, self.textBoxNumber.Value.Text)
		if val then
			updateColor(self, self.hue, self.sat, math.clamp(val, 0, 255) / 255)
		end
	end)
	connect(self._connections, self.textBoxNumber.HTML.FocusLost, function()
		local ok, color = pcall(function()
			return Color3.fromHex(self.textBoxNumber.HTML.Text)
		end)
		updateColor(self, if ok then color else self.currentColor)
	end)
end

function ColorPicker.new(): ColorPicker
	local template = getTemplate()
	if not template then
		error("ColorPicker template missing at ReplicatedStorage.Assets.UI.ColorPicker.Main", 2)
	end

	local self = setmetatable({}, ColorPicker)
	self.currentColor = Color3.new(1, 1, 1)
	self.active = false
	self._connections = {}
	self._Opened = Instance.new("BindableEvent")
	self._Closed = Instance.new("BindableEvent")
	self._Changed = Instance.new("BindableEvent")
	self.Opened = self._Opened.Event
	self.Closed = self._Closed.Event
	self.Changed = self._Changed.Event
	self.hue, self.sat, self.val = self.currentColor:ToHSV()

	self.frame = template:Clone()
	self.frame.Name = "Picker"
	self.frame.Visible = false
	self.frame.Parent = getPickerGui()
	self.sliders = self.frame.Sliders
	self.numeric = self.frame.Numeric
	self.previewColor = self.numeric.Preview
	self.okButton = self.numeric.Ok
	self.cancelButton = self.numeric.Cancel
	self.textBoxNumber = self.numeric.TextBox
	self.colorButton = self.sliders.Color.Button
	self.colorCursor = self.sliders.Color.White.Cursor
	self.valueButton = self.sliders.Value.Button
	self.valueCursor = self.sliders.Value.Cursor
	self.valUiGradient = self.sliders.Value.UIGradient

	updateColor(self, self.currentColor)
	connectEvents(self)
	return self
end

function ColorPicker:SetColor(color: Color3)
	if typeof(color) ~= "Color3" then
		error("Color3 expected", 2)
	end
	updateColor(self, color)
end

function ColorPicker:GetColor(): Color3
	return self.currentColor
end

function ColorPicker:Start()
	if self.active then
		return
	end
	self.frame.Visible = true
	self.active = true
	self._Opened:Fire()
end

function ColorPicker:Cancel()
	if not self.active then
		return
	end
	self.frame.Visible = false
	self.active = false
	self._Closed:Fire(self.currentColor)
end

function ColorPicker:Destroy()
	self.active = false
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._Changed:Destroy()
	self._Opened:Destroy()
	self._Closed:Destroy()
	if self.frame and self.frame.Parent then
		self.frame:Destroy()
	end
	setmetatable(self, nil)
end

return ColorPicker
