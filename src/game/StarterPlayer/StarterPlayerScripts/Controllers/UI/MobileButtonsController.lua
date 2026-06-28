local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local MovementController = require(script.Parent:WaitForChild("MovementController"))
local ScoreboardController = require(script.Parent:WaitForChild("ScoreboardController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local MobileButtonsController = {}

MobileButtonsController._connections = {} :: { RBXScriptConnection }
MobileButtonsController._buttonConnections = {} :: { RBXScriptConnection }
MobileButtonsController._mobileButtons = nil :: Frame?
MobileButtonsController._sprintHeld = false
MobileButtonsController._crouchHeld = false
MobileButtonsController._scoreboardHeld = false
MobileButtonsController._buttonVisuals = {} :: { [GuiButton]: any }

local ACTIVE_BACKGROUND_COLOR = Color3.fromRGB(74, 210, 112)
local ACTIVE_BACKGROUND_TRANSPARENCY = 0.12
local ACTIVE_STROKE_COLOR = Color3.fromRGB(210, 255, 224)
local ACTIVE_IMAGE_TRANSPARENCY = 0

local function isTouchPreferred(): boolean
	local ok, preferredInput = pcall(function()
		return UserInputService.PreferredInput
	end)
	if ok and typeof(preferredInput) == "EnumItem" then
		return preferredInput.Name == "Touch"
	end

	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function findButton(parent: Instance?, name: string): GuiButton?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("GuiButton") then child else nil
end

function MobileButtonsController:_setSprintHeld(held: boolean)
	local nextHeld = held == true
	if self._sprintHeld == nextHeld then
		return
	end

	self._sprintHeld = nextHeld
	MovementController:SetSprintHeld(nextHeld)
end

function MobileButtonsController:_setCrouchHeld(held: boolean)
	local nextHeld = held == true
	if self._crouchHeld == nextHeld then
		return
	end

	self._crouchHeld = nextHeld
	MovementController:SetCrouchHeld(nextHeld)
end

function MobileButtonsController:_setScoreboardHeld(held: boolean)
	local nextHeld = held == true
	if self._scoreboardHeld == nextHeld then
		return
	end

	self._scoreboardHeld = nextHeld
	ScoreboardController:SetMobileHeld(nextHeld)
end

function MobileButtonsController:_releaseHeldButtons()
	self:_setSprintHeld(false)
	self:_setCrouchHeld(false)
	self:_setScoreboardHeld(false)
end

function MobileButtonsController:_captureButtonVisual(button: GuiButton)
	if self._buttonVisuals[button] then
		return
	end

	local strokes = {}
	for _, child in ipairs(button:GetChildren()) do
		if child:IsA("UIStroke") then
			table.insert(strokes, {
				instance = child,
				color = child.Color,
				transparency = child.Transparency,
			})
		end
	end

	local icon = button:FindFirstChildWhichIsA("ImageLabel")
	self._buttonVisuals[button] = {
		backgroundColor = button.BackgroundColor3,
		backgroundTransparency = button.BackgroundTransparency,
		icon = icon,
		iconImageTransparency = if icon then icon.ImageTransparency else nil,
		strokes = strokes,
	}
end

function MobileButtonsController:_setButtonActive(button: GuiButton?, active: boolean)
	if not button then
		return
	end

	self:_captureButtonVisual(button)
	local visual = self._buttonVisuals[button]
	button:SetAttribute("MobileToggleActive", active == true)

	if active then
		button.BackgroundColor3 = ACTIVE_BACKGROUND_COLOR
		button.BackgroundTransparency = ACTIVE_BACKGROUND_TRANSPARENCY
		if visual.icon then
			visual.icon.ImageTransparency = ACTIVE_IMAGE_TRANSPARENCY
		end
		for _, strokeRecord in ipairs(visual.strokes) do
			local stroke = strokeRecord.instance
			if stroke and stroke.Parent then
				stroke.Color = ACTIVE_STROKE_COLOR
				stroke.Transparency = 0
			end
		end
		return
	end

	button.BackgroundColor3 = visual.backgroundColor
	button.BackgroundTransparency = visual.backgroundTransparency
	if visual.icon and visual.iconImageTransparency ~= nil then
		visual.icon.ImageTransparency = visual.iconImageTransparency
	end
	for _, strokeRecord in ipairs(visual.strokes) do
		local stroke = strokeRecord.instance
		if stroke and stroke.Parent then
			stroke.Color = strokeRecord.color
			stroke.Transparency = strokeRecord.transparency
		end
	end
end

function MobileButtonsController:_disconnectButtons()
	local mobileButtons = self._mobileButtons
	if mobileButtons then
		self:_setButtonActive(findButton(mobileButtons, "Sprint"), false)
		self:_setButtonActive(findButton(mobileButtons, "Crouch"), false)
		self:_setButtonActive(findButton(mobileButtons, "Scoreboard"), false)
	end
	for _, connection in ipairs(self._buttonConnections) do
		connection:Disconnect()
	end
	self._buttonConnections = {}
	self:_releaseHeldButtons()
	self._buttonVisuals = {}
	self._mobileButtons = nil
end

function MobileButtonsController:_syncVisibility()
	local mobileButtons = self._mobileButtons
	if not mobileButtons then
		return
	end

	local visible = isTouchPreferred()
	mobileButtons.Visible = visible
	if not visible then
		self:_releaseHeldButtons()
		self:_syncButtonVisuals()
	end
end

function MobileButtonsController:_syncButtonVisuals()
	local mobileButtons = self._mobileButtons
	if not mobileButtons then
		return
	end

	self:_setButtonActive(findButton(mobileButtons, "Sprint"), self._sprintHeld)
	self:_setButtonActive(findButton(mobileButtons, "Crouch"), self._crouchHeld)
	self:_setButtonActive(findButton(mobileButtons, "Scoreboard"), self._scoreboardHeld)
end

function MobileButtonsController:_bindToggleButton(button: GuiButton?, setHeld: (any, boolean) -> (), getHeld: (any) -> boolean)
	if not button then
		return
	end

	self:_captureButtonVisual(button)
	table.insert(self._buttonConnections, button.Activated:Connect(function()
		setHeld(self, not getHeld(self))
		self:_syncButtonVisuals()
	end))
end

function MobileButtonsController:_bindHud(hud: Instance?)
	self:_disconnectButtons()
	if not hud then
		return
	end

	local mobileButtons = hud:FindFirstChild("MobileButtons")
	if not (mobileButtons and mobileButtons:IsA("Frame")) then
		return
	end

	self._mobileButtons = mobileButtons
	self:_bindToggleButton(findButton(mobileButtons, "Sprint"), self._setSprintHeld, function(controller)
		return controller._sprintHeld
	end)
	self:_bindToggleButton(findButton(mobileButtons, "Crouch"), self._setCrouchHeld, function(controller)
		return controller._crouchHeld
	end)
	self:_bindToggleButton(findButton(mobileButtons, "Scoreboard"), self._setScoreboardHeld, function(controller)
		return controller._scoreboardHeld
	end)
	self:_syncVisibility()
	self:_syncButtonVisuals()
end

function MobileButtonsController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild("HUD"))
end

function MobileButtonsController:OnStart()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self:_disconnectButtons()

	table.insert(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" then
			task.defer(function()
				self:_bindHud(child)
			end)
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

	self:_bindCurrentHud()
end

return MobileButtonsController
