local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local HUDWindowController = {}

HUDWindowController.PopScale = 0.9
HUDWindowController.OpenTween = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
HUDWindowController.CloseTween = TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
HUDWindowController.EffectsTween = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
HUDWindowController.BlurName = "HUDWindowBlur"
HUDWindowController.BlurSize = 18
HUDWindowController.UseBlur = true
HUDWindowController.UseFOV = true
HUDWindowController.OpenFOV = 72
HUDWindowController.ClosedFOV = 70
HUDWindowController.AutoBindCloseButtons = false
HUDWindowController.CloseButtonName = "Close"

local function scaleUDim2(value: UDim2, factor: number): UDim2
	return UDim2.new(
		value.X.Scale * factor,
		value.X.Offset * factor,
		value.Y.Scale * factor,
		value.Y.Offset * factor
	)
end

function HUDWindowController:_ensureState()
	if self._started then
		return
	end

	self._windows = {}
	self._buttons = {}
	self._closeButtons = {}
	self._hudObjects = {}
	self._windowConnections = {}
	self._buttonConnections = {}
	self._closeButtonConnections = {}
	self._openSizes = {}
	self._faders = {}
	self._tweens = {}
	self._fadeTweens = {}
	self._hudVisibility = {}
	self._currentOpen = nil
	self._blur = nil
	self._blurTween = nil
	self._fovTween = nil
	self._started = true
end

function HUDWindowController:_getBlur(): BlurEffect
	if self._blur and self._blur.Parent == Lighting then
		return self._blur
	end

	local existing = Lighting:FindFirstChild(self.BlurName)
	if existing and existing:IsA("BlurEffect") then
		self._blur = existing
	else
		local blur = Instance.new("BlurEffect")
		blur.Name = self.BlurName
		blur.Size = 0
		blur.Enabled = true
		blur.Parent = Lighting
		self._blur = blur
	end

	return self._blur
end

function HUDWindowController:_cancelSceneTweens()
	if self._blurTween then
		self._blurTween:Cancel()
		self._blurTween = nil
	end

	if self._fovTween then
		self._fovTween:Cancel()
		self._fovTween = nil
	end
end

function HUDWindowController:_setSceneEffects(active: boolean, instant: boolean)
	local camera = workspace.CurrentCamera

	self:_cancelSceneTweens()

	if self.UseBlur then
		local blur = self:_getBlur()
		local blurTarget = active and self.BlurSize or 0

		if instant then
			blur.Size = blurTarget
		else
			self._blurTween = TweenService:Create(blur, self.EffectsTween, { Size = blurTarget })
			self._blurTween:Play()
		end
	end

	if self.UseFOV and camera then
		local fovTarget = active and self.OpenFOV or self.ClosedFOV

		if instant then
			camera.FieldOfView = fovTarget
		else
			self._fovTween = TweenService:Create(camera, self.EffectsTween, { FieldOfView = fovTarget })
			self._fovTween:Play()
		end
	end
end

function HUDWindowController:_cancelWindowTweens(name: string)
	if self._tweens[name] then
		self._tweens[name]:Cancel()
		self._tweens[name] = nil
	end

	if self._fadeTweens[name] then
		self._fadeTweens[name]:Cancel()
		self._fadeTweens[name] = nil
	end
end

function HUDWindowController:_getFader(window: GuiObject): CanvasGroup?
	if window:IsA("CanvasGroup") then
		return window
	end

	return window:FindFirstChildWhichIsA("CanvasGroup", true)
end

function HUDWindowController:_setHudVisible(visible: boolean)
	for _, guiObject in ipairs(self._hudObjects) do
		if guiObject and guiObject.Parent then
			if self._hudVisibility[guiObject] == nil then
				self._hudVisibility[guiObject] = guiObject.Visible
			end

			if visible then
				guiObject.Visible = self._hudVisibility[guiObject] ~= false
			else
				guiObject.Visible = false
			end
		end
	end
end

function HUDWindowController:_prepareWindow(name: string)
	local window = self._windows[name]
	if not window then
		return
	end

	self._openSizes[name] = window.Size
	self._faders[name] = self:_getFader(window)

	if self._faders[name] then
		self._faders[name].GroupTransparency = 1
	end

	window.Visible = false

	if self.AutoBindCloseButtons then
		local closeButton = window:FindFirstChild(self.CloseButtonName, true)
		if closeButton and closeButton:IsA("GuiButton") then
			self:RegisterCloseButton(name, closeButton)
		end
	end
end

function HUDWindowController:RegisterWindow(name: string, window: GuiObject)
	self:_ensureState()
	if not window then
		return
	end

	self._windows[name] = window
	self:_prepareWindow(name)
end

function HUDWindowController:RegisterButton(name: string, button: GuiButton)
	self:_ensureState()

	self._buttons[name] = self._buttons[name] or {}
	table.insert(self._buttons[name], button)

	local connection = button.Activated:Connect(function()
		self:ToggleWindow(name)
	end)

	self._buttonConnections[name] = self._buttonConnections[name] or {}
	table.insert(self._buttonConnections[name], connection)
end

function HUDWindowController:RegisterCloseButton(name: string, button: GuiButton)
	self:_ensureState()

	self._closeButtons[name] = self._closeButtons[name] or {}
	table.insert(self._closeButtons[name], button)

	local connection = button.Activated:Connect(function()
		self:CloseWindow(name)
	end)

	self._closeButtonConnections[name] = self._closeButtonConnections[name] or {}
	table.insert(self._closeButtonConnections[name], connection)
end

function HUDWindowController:AddHudObject(guiObject: GuiObject)
	self:_ensureState()
	table.insert(self._hudObjects, guiObject)
end

function HUDWindowController:RemoveHudObject(guiObject: GuiObject)
	self:_ensureState()

	for index = #self._hudObjects, 1, -1 do
		if self._hudObjects[index] == guiObject then
			table.remove(self._hudObjects, index)
		end
	end

	self._hudVisibility[guiObject] = nil
end

function HUDWindowController:OpenWindow(name: string, forceOpen: boolean?)
	self:_ensureState()

	local window = self._windows[name]
	if not window then
		return
	end

	if self._currentOpen == name and window.Visible then
		if forceOpen then
			return
		end

		self:CloseWindow(name)
		return
	end

	if self._currentOpen and self._currentOpen ~= name then
		self:CloseWindow(self._currentOpen, false)
	end

	self:_cancelWindowTweens(name)

	local baseSize = self._openSizes[name] or window.Size
	self._openSizes[name] = baseSize

	local smallSize = scaleUDim2(baseSize, self.PopScale)
	local fader = self._faders[name]

	if fader then
		fader.GroupTransparency = 1
	end

	window.Visible = true
	window.Size = smallSize

	self._tweens[name] = TweenService:Create(window, self.OpenTween, { Size = baseSize })
	self._tweens[name]:Play()

	if fader then
		self._fadeTweens[name] = TweenService:Create(fader, self.OpenTween, { GroupTransparency = 0 })
		self._fadeTweens[name]:Play()
	end

	self._currentOpen = name
	self:_setHudVisible(false)
	self:_setSceneEffects(true, false)
end

function HUDWindowController:CloseWindow(name: string, instant: boolean?)
	self:_ensureState()

	local window = self._windows[name]
	if not window then
		return
	end

	if not window.Visible and not instant then
		return
	end

	self:_cancelWindowTweens(name)

	local baseSize = self._openSizes[name] or window.Size
	self._openSizes[name] = baseSize
	local smallSize = scaleUDim2(baseSize, self.PopScale)
	local fader = self._faders[name]

	if instant then
		if fader then
			fader.GroupTransparency = 1
		end

		window.Visible = false
		window.Size = baseSize

		if self._currentOpen == name then
			self._currentOpen = nil
			self:_setHudVisible(true)
			self:_setSceneEffects(false, true)
		end

		return
	end

	self._tweens[name] = TweenService:Create(window, self.CloseTween, { Size = smallSize })
	self._tweens[name]:Play()

	if fader then
		self._fadeTweens[name] = TweenService:Create(fader, self.CloseTween, { GroupTransparency = 1 })
		self._fadeTweens[name]:Play()
	end

	local connection: RBXScriptConnection?
	connection = self._tweens[name].Completed:Connect(function()
		if connection then
			connection:Disconnect()
		end

		window.Visible = false
		window.Size = baseSize

		if self._currentOpen == name then
			self._currentOpen = nil
			self:_setHudVisible(true)
			self:_setSceneEffects(false, false)
		end
	end)
end

function HUDWindowController:ToggleWindow(name: string)
	self:_ensureState()

	local window = self._windows[name]
	if not window then
		return
	end

	if self._currentOpen == name and window.Visible then
		self:CloseWindow(name)
	else
		self:OpenWindow(name)
	end
end

function HUDWindowController:CloseCurrentWindow(instant: boolean?)
	self:_ensureState()
	if self._currentOpen then
		self:CloseWindow(self._currentOpen, instant)
	end
end

function HUDWindowController:OnStart()
	self:_ensureState()
	print("HUDWindowController client initialized!")
end

return HUDWindowController
