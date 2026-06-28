local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local CameraController = require(script.Parent:WaitForChild("CameraController"))

local SHIFT_LOCK_OFF_IMAGE = "rbxasset://textures/ui/mouseLock_off.png"
local SHIFT_LOCK_ON_IMAGE = "rbxasset://textures/ui/mouseLock_on.png"
local SCREEN_GUI_NAME = "Mobile/ConsoleShiftLock"

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local MobileShiftLockController = {}

MobileShiftLockController._connections = {} :: { RBXScriptConnection }
MobileShiftLockController._screenConnections = {} :: { RBXScriptConnection }
MobileShiftLockController._characterConnection = nil :: RBXScriptConnection?
MobileShiftLockController._screenGui = nil :: ScreenGui?
MobileShiftLockController._button = nil :: ImageButton?

local function isTouchPreferred(): boolean
	local ok, preferredInput = pcall(function()
		return UserInputService.PreferredInput
	end)
	if ok and typeof(preferredInput) == "EnumItem" then
		return preferredInput.Name == "Touch"
	end

	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

function MobileShiftLockController:_trackScreenConnection(connection: RBXScriptConnection)
	table.insert(self._screenConnections, connection)
end

function MobileShiftLockController:_disconnectScreen()
	for _, connection in ipairs(self._screenConnections) do
		connection:Disconnect()
	end
	self._screenConnections = {}
	self._screenGui = nil
	self._button = nil
end

function MobileShiftLockController:_syncIcon()
	local button = self._button
	if button then
		button.Image = if CameraController:IsShiftLocked() then SHIFT_LOCK_ON_IMAGE else SHIFT_LOCK_OFF_IMAGE
	end
end

function MobileShiftLockController:_syncVisibility()
	local screenGui = self._screenGui
	if not screenGui then
		return
	end

	screenGui.Enabled = isTouchPreferred()
	self:_syncIcon()
end

function MobileShiftLockController:_ensureButton(screenGui: ScreenGui): ImageButton
	local frame = screenGui:FindFirstChild("BottomLeftControl")
	if not (frame and frame:IsA("Frame")) then
		frame = Instance.new("Frame")
		frame.Name = "BottomLeftControl"
		frame.Size = UDim2.new(0.1, 0, 0.1, 0)
		frame.Position = UDim2.new(1, 0, 1, 0)
		frame.AnchorPoint = Vector2.new(1, 1)
		frame.BackgroundTransparency = 1
		frame.ZIndex = 10
		frame.Parent = screenGui
	end

	local aspectRatio = frame:FindFirstChildWhichIsA("UIAspectRatioConstraint")
	if not aspectRatio then
		aspectRatio = Instance.new("UIAspectRatioConstraint")
		aspectRatio.Parent = frame
	end
	aspectRatio.AspectRatio = 1
	aspectRatio.DominantAxis = Enum.DominantAxis.Height

	local existingButton = frame:FindFirstChild("MouseLockLabel")
	local button: ImageButton
	if existingButton and existingButton:IsA("ImageButton") then
		button = existingButton
	else
		if existingButton then
			existingButton:Destroy()
		end

		button = Instance.new("ImageButton")
		button.Name = "MouseLockLabel"
		button.Parent = frame
	end

	button.Size = UDim2.new(1, 0, 1, 0)
	button.Position = UDim2.new(-2.775, 0, -1.975, 0)
	button.BackgroundTransparency = 1
	button.Visible = true
	button.ZIndex = 10
	button.AutoButtonColor = false

	return button
end

function MobileShiftLockController:_bindScreenGui(screenGui: ScreenGui?)
	self:_disconnectScreen()
	if not screenGui then
		return
	end

	self._screenGui = screenGui
	self._button = self:_ensureButton(screenGui)
	self:_trackScreenConnection(self._button.Activated:Connect(function()
		CameraController:ToggleShiftLocked()
		self:_syncIcon()
	end))

	self:_syncVisibility()
end

function MobileShiftLockController:_bindCurrentScreenGui()
	local screenGui = PlayerGui:FindFirstChild(SCREEN_GUI_NAME)
	self:_bindScreenGui(if screenGui and screenGui:IsA("ScreenGui") then screenGui else nil)
end

function MobileShiftLockController:_bindCharacter(character: Model)
	if self._characterConnection then
		self._characterConnection:Disconnect()
	end

	self._characterConnection = character:GetAttributeChangedSignal("Camera_ShiftLocked"):Connect(function()
		self:_syncIcon()
	end)
	self:_syncIcon()
end

function MobileShiftLockController:OnStart()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self:_disconnectScreen()
	if self._characterConnection then
		self._characterConnection:Disconnect()
		self._characterConnection = nil
	end

	table.insert(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == SCREEN_GUI_NAME and child:IsA("ScreenGui") then
			task.defer(function()
				self:_bindScreenGui(child)
			end)
		end
	end))
	table.insert(self._connections, PlayerGui.ChildRemoved:Connect(function(child)
		if child == self._screenGui then
			self:_disconnectScreen()
		end
	end))
	table.insert(self._connections, UserInputService.LastInputTypeChanged:Connect(function()
		self:_syncVisibility()
	end))

	local preferredSignalOk, preferredSignal = pcall(function()
		return UserInputService:GetPropertyChangedSignal("PreferredInput")
	end)
	if preferredSignalOk then
		table.insert(self._connections, preferredSignal:Connect(function()
			self:_syncVisibility()
		end))
	end

	if LocalPlayer.Character then
		self:_bindCharacter(LocalPlayer.Character)
	end
	table.insert(self._connections, LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end))

	self:_bindCurrentScreenGui()
end

return MobileShiftLockController
