local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local PlayerSettings = require(ReplicatedStorage.Shared.Common.PlayerSettings)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local HUD_ROOT_NAMES = table.freeze({ "HUD", "ScreenGui" })
local PC_CONTROLS_NAME = "PCControls"
local ACTION_SETTING_BY_LABEL = table.freeze({
	Emote = "emoteKey",
	["Camera Lock"] = "shiftLockKey",
})
local KEY_DISPLAY_NAMES = table.freeze({
	LeftControl = "CTRL",
	RightControl = "R CTRL",
	LeftShift = "SHIFT",
	RightShift = "R SHIFT",
	LeftAlt = "ALT",
	RightAlt = "R ALT",
	Return = "ENTER",
	Backspace = "BACK",
	Space = "SPACE",
	Tab = "TAB",
})

local PCControlsController = {}

PCControlsController._connections = {} :: { RBXScriptConnection }
PCControlsController._pcControls = nil :: GuiObject?

local function track(connections: { RBXScriptConnection }, connection: RBXScriptConnection?)
	if connection then
		table.insert(connections, connection)
	end
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function findPCControls(): GuiObject?
	for _, rootName in ipairs(HUD_ROOT_NAMES) do
		local root = PlayerGui:FindFirstChild(rootName)
		local controls = root and root:FindFirstChild(PC_CONTROLS_NAME)
		if controls and controls:IsA("GuiObject") then
			return controls
		end
	end
	return nil
end

local function findActionLabel(row: Instance): TextLabel?
	for _, child in ipairs(row:GetChildren()) do
		if child:IsA("TextLabel") then
			return child
		end
	end
	return nil
end

local function findKeybindLabel(row: Instance): TextLabel?
	local keybindContainer = row:FindFirstChild("Keybind")
	if keybindContainer then
		local label = keybindContainer:FindFirstChild("Keybind", true)
		if label and label:IsA("TextLabel") then
			return label
		end
	end
	return nil
end

local function normalizeActionText(text: string): string
	return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function keyDisplayName(keyName: any): string
	keyName = tostring(keyName)
	local mapped = KEY_DISPLAY_NAMES[keyName]
	if mapped then
		return mapped
	end
	if #keyName == 1 then
		return string.upper(keyName)
	end
	return keyName:gsub("Left", "L "):gsub("Right", "R "):upper()
end

local function isKeyboardAndMousePreferred(): boolean
	local ok, preferredInput = pcall(function()
		return UserInputService.PreferredInput
	end)
	if ok and typeof(preferredInput) == "EnumItem" then
		return preferredInput.Name == "KeyboardAndMouse"
	end

	return UserInputService.KeyboardEnabled and UserInputService.MouseEnabled and not UserInputService.TouchEnabled
end

function PCControlsController:_syncLabels()
	local controls = self._pcControls
	if not controls then
		return
	end

	for _, child in ipairs(controls:GetChildren()) do
		if not child:IsA("GuiObject") then
			continue
		end

		local actionLabel = findActionLabel(child)
		local keybindLabel = findKeybindLabel(child)
		if not (actionLabel and keybindLabel) then
			continue
		end

		local settingId = ACTION_SETTING_BY_LABEL[normalizeActionText(actionLabel.Text)]
			or ACTION_SETTING_BY_LABEL[child.Name]
		if settingId then
			keybindLabel.Text = keyDisplayName(PlayerSettings:Get(settingId))
		end
	end
end

function PCControlsController:_syncVisibility()
	local controls = self._pcControls
	if controls then
		controls.Visible = isKeyboardAndMousePreferred()
	end
end

function PCControlsController:_sync()
	self._pcControls = findPCControls()
	self:_syncLabels()
	self:_syncVisibility()
end

function PCControlsController:OnStart()
	disconnectAll(self._connections)

	track(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" or child.Name == "ScreenGui" then
			task.defer(function()
				self:_sync()
			end)
		end
	end))
	track(self._connections, PlayerGui.DescendantAdded:Connect(function(descendant)
		if descendant.Name == PC_CONTROLS_NAME then
			task.defer(function()
				self:_sync()
			end)
		end
	end))
	track(self._connections, PlayerSettings.Changed:Connect(function(id)
		if id == "emoteKey" or id == "shiftLockKey" then
			self:_syncLabels()
		end
	end))
	track(self._connections, UserInputService.LastInputTypeChanged:Connect(function()
		self:_syncVisibility()
	end))
	local preferredSignalOk, preferredSignal = pcall(function()
		return UserInputService:GetPropertyChangedSignal("PreferredInput")
	end)
	if preferredSignalOk then
		track(self._connections, preferredSignal:Connect(function()
			self:_syncVisibility()
		end))
	end

	self:_sync()
end

return PCControlsController
