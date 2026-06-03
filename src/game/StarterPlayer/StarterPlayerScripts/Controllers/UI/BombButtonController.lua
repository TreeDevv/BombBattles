local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local BombController = require(script.Parent:WaitForChild("BombController"))

local ATTR = BombConfig.Attributes

local SIZE_TWEEN = TweenInfo.new(0.24, Enum.EasingStyle.Back)
local FADE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad)
local HOLD_COLOR = Color3.fromRGB(102, 255, 0)
local READY_COLOR = Color3.fromRGB(255, 255, 255)
local COOK_WARNING_COLOR = BombConfig.PreviewColor
local TIMER_READY_COLOR = Color3.fromRGB(26, 255, 0)
local TIMER_DANGER_COLOR = Color3.fromRGB(255, 0, 0)
local FLIPBOOK_LIFETIME = 0.357

local BombButtonController = {}

BombButtonController._connections = {} :: { RBXScriptConnection }
BombButtonController._buttonConnections = {} :: { RBXScriptConnection }
BombButtonController._button = nil :: ImageButton?
BombButtonController._normalSize = nil :: UDim2?
BombButtonController._countLabel = nil :: TextLabel?
BombButtonController._icon = nil :: ImageLabel?
BombButtonController._keybindCover = nil :: ImageLabel?
BombButtonController._explodeEffect = nil :: ImageLabel?
BombButtonController._cooldownEffect = nil :: Frame?
BombButtonController._bombProgress = nil :: GuiObject?
BombButtonController._progressValue = nil :: NumberValue?
BombButtonController._progressLabel = nil :: TextLabel?
BombButtonController._leftCircle = nil :: ImageLabel?
BombButtonController._rightCircle = nil :: ImageLabel?
BombButtonController._leftGradient = nil :: UIGradient?
BombButtonController._rightGradient = nil :: UIGradient?
BombButtonController._rope = nil :: ImageLabel?
BombButtonController._ropeGradient = nil :: UIGradient?
BombButtonController._fire = nil :: ImageLabel?
BombButtonController._path2d = nil :: any
BombButtonController._elementsToTween = {} :: { Instance }
BombButtonController._hovering = false
BombButtonController._pressing = false
BombButtonController._timerRunning = false
BombButtonController._cooldownSerial = 0
BombButtonController._timerSerial = 0
BombButtonController._activeTimerTweens = {} :: { Tween }
BombButtonController._pathSampleValue = nil :: NumberValue?
BombButtonController._buttonColorSample = nil :: NumberValue?
BombButtonController._buttonColorTween = nil :: Tween?
BombButtonController._buttonColorConnection = nil :: RBXScriptConnection?
BombButtonController._cooldownRechargeEndsAt = 0
BombButtonController._lastBombCount = nil :: number?

local function getServerTime(): number
	return workspace:GetServerTimeNow()
end

local function getNumberAttribute(name: string, fallback: number): number
	local value = LocalPlayer:GetAttribute(name)
	return if typeof(value) == "number" then value else fallback
end

local function getBombMax(): number
	return math.max(1, math.floor(getNumberAttribute(ATTR.Max, BombConfig.MaxBombs)))
end

local function getBombCount(): number
	return math.clamp(math.floor(getNumberAttribute(ATTR.Count, BombConfig.MaxBombs)), 0, getBombMax())
end

local function getRechargeEndsAt(): number
	return getNumberAttribute(ATTR.RechargeEndsAt, 0)
end

local function isCooking(): boolean
	return LocalPlayer:GetAttribute(ATTR.Cooking) == true
end

local function scaleUDim2(value: UDim2, factor: number): UDim2
	return UDim2.new(value.X.Scale * factor, value.X.Offset * factor, value.Y.Scale * factor, value.Y.Offset * factor)
end

local function findChild(parent: Instance?, childName: string): Instance?
	return if parent then parent:FindFirstChild(childName) else nil
end

local function getDefaultSize(button: GuiObject): UDim2
	local value = button:GetAttribute("defaultSize")
	return if typeof(value) == "UDim2" then value else button.Size
end

function BombButtonController:_disconnectButton()
	for _, connection in ipairs(self._buttonConnections) do
		connection:Disconnect()
	end
	self._buttonConnections = {}
end

function BombButtonController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self:_disconnectButton()
end

function BombButtonController:_cancelTimerTweens()
	for _, tween in ipairs(self._activeTimerTweens) do
		tween:Cancel()
	end
	self._activeTimerTweens = {}

	if self._pathSampleValue then
		self._pathSampleValue:Destroy()
		self._pathSampleValue = nil
	end
end

function BombButtonController:_cancelButtonColorFade()
	if self._buttonColorTween then
		self._buttonColorTween:Cancel()
		self._buttonColorTween = nil
	end

	if self._buttonColorConnection then
		self._buttonColorConnection:Disconnect()
		self._buttonColorConnection = nil
	end

	if self._buttonColorSample then
		self._buttonColorSample:Destroy()
		self._buttonColorSample = nil
	end
end

function BombButtonController:_getCookButtonColor(progress: number): Color3
	progress = math.clamp(progress, 0, 1)
	if progress <= 0.5 then
		return HOLD_COLOR:Lerp(COOK_WARNING_COLOR, progress / 0.5)
	end

	return COOK_WARNING_COLOR:Lerp(TIMER_DANGER_COLOR, (progress - 0.5) / 0.5)
end

function BombButtonController:_startButtonColorFade(duration: number)
	local button = self._button
	if not button or duration <= 0 then
		return
	end

	self:_cancelButtonColorFade()

	local sample = Instance.new("NumberValue")
	sample.Value = 0
	self._buttonColorSample = sample
	self._buttonColorConnection = sample.Changed:Connect(function(value)
		if self._button then
			self._button.ImageColor3 = self:_getCookButtonColor(value)
		end
	end)

	button.ImageColor3 = HOLD_COLOR
	self._buttonColorTween = TweenService:Create(
		sample,
		TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut),
		{ Value = 1 }
	)
	self._buttonColorTween:Play()
end

function BombButtonController:_trackTimerTween(tween: Tween)
	table.insert(self._activeTimerTweens, tween)
	tween:Play()
	return tween
end

function BombButtonController:_tweenButton(properties)
	local button = self._button
	if not button then
		return
	end
	TweenService:Create(button, SIZE_TWEEN, properties):Play()
end

function BombButtonController:_getHoverSize(): UDim2?
	return if self._normalSize then scaleUDim2(self._normalSize, 1.1) else nil
end

function BombButtonController:_getSmallSize(): UDim2?
	return if self._normalSize then scaleUDim2(self._normalSize, 0.9) else nil
end

function BombButtonController:_playFlipbook(button: ImageButton)
	local template = self._explodeEffect
	local keybind = findChild(button, "Keybind")
	if not (template and keybind and keybind:IsA("ImageLabel")) then
		return
	end

	local clone = template:Clone()
	clone.Parent = button
	clone.ImageColor3 = keybind.ImageColor3

	local playSprite = clone:FindFirstChild("PlaySprite")
	if playSprite and playSprite:IsA("LocalScript") then
		playSprite.Enabled = true
	end

	task.delay(FLIPBOOK_LIFETIME, function()
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

function BombButtonController:_playCooldownFinishedEffect(button: ImageButton)
	local template = self._cooldownEffect
	local keybind = findChild(button, "Keybind")
	if not (template and keybind and keybind:IsA("ImageLabel")) then
		return
	end

	local clone = template:Clone()
	clone.Parent = button
	clone.Size = UDim2.fromScale(0, 0)
	clone.BackgroundTransparency = 0
	clone.BackgroundColor3 = keybind.ImageColor3

	local stroke = clone:FindFirstChildWhichIsA("UIStroke")
	if stroke then
		stroke.Color = keybind.ImageColor3
		stroke.Transparency = 0
	end

	TweenService:Create(clone, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
		Size = UDim2.fromScale(1.1, 1.1),
		BackgroundTransparency = 1,
	}):Play()

	if stroke then
		TweenService:Create(stroke, TweenInfo.new(0.4, Enum.EasingStyle.Quad), {
			Thickness = 0,
			Transparency = 1,
		}):Play()
	end

	task.delay(0.3, function()
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

function BombButtonController:_setTimerTransparent(transparent: boolean, tween: boolean)
	local value = if transparent then 1 else 0
	for _, item in ipairs(self._elementsToTween) do
		if item:IsA("ImageLabel") then
			if tween then
				TweenService:Create(item, FADE_TWEEN, { ImageTransparency = value }):Play()
			else
				item.ImageTransparency = value
			end
		elseif item:IsA("UIStroke") then
			if tween then
				TweenService:Create(item, FADE_TWEEN, { Transparency = value }):Play()
			else
				item.Transparency = value
			end
		elseif item:IsA("TextLabel") then
			if tween then
				TweenService:Create(item, FADE_TWEEN, { TextTransparency = value }):Play()
			else
				item.TextTransparency = value
			end
		end
	end
end

function BombButtonController:_updateMeterGradients()
	if not self._progressValue then
		return
	end

	local progress = self._progressValue.Value
	if self._rightGradient then
		self._rightGradient.Rotation = math.clamp(progress * 360, 0, 180)
	end
	if self._leftGradient then
		self._leftGradient.Rotation = math.clamp(progress * 360, 180, 360)
	end
end

function BombButtonController:_getCookRemainingSeconds(): number
	local cookStartedAt = getNumberAttribute(ATTR.CookStartedAt, 0)
	if cookStartedAt <= 0 then
		return BombConfig.FuseSeconds
	end
	return math.max(BombConfig.FuseSeconds - (getServerTime() - cookStartedAt), 0)
end

function BombButtonController:_getCooldownRemainingSeconds(): number
	local rechargeEndsAt = getRechargeEndsAt()
	if rechargeEndsAt <= 0 then
		return BombConfig.RechargeSeconds
	end
	return math.clamp(rechargeEndsAt - getServerTime(), 0, BombConfig.RechargeSeconds)
end

function BombButtonController:_startHoldVisual()
	local button = self._button
	if not (button and self._normalSize) then
		return
	end

	local defaultSize = getDefaultSize(button)
	button.Size = defaultSize
	self:_tweenButton({
		Size = scaleUDim2(defaultSize, 1.1),
		ImageColor3 = HOLD_COLOR,
	})
end

function BombButtonController:_finishCooldownVisual(playEffect: boolean)
	local button = self._button
	if not (button and self._normalSize) then
		return
	end

	self._cooldownRechargeEndsAt = 0
	button:SetAttribute("OnCooldown", false)
	self:_tweenButton({ Size = getDefaultSize(button) })

	if self._keybindCover then
		TweenService:Create(self._keybindCover, SIZE_TWEEN, {
			ImageTransparency = 1,
		}):Play()
	end

	if playEffect then
		self:_playCooldownFinishedEffect(button)
	end
end

function BombButtonController:_startCooldownVisual(cooldownLength: number, rechargeEndsAt: number)
	local button = self._button
	if not (button and self._normalSize) then
		return
	end
	if cooldownLength <= 0 then
		self:_finishCooldownVisual(false)
		return
	end

	self:_cancelButtonColorFade()
	self._cooldownSerial += 1
	local serial = self._cooldownSerial
	self._cooldownRechargeEndsAt = rechargeEndsAt
	local defaultSize = getDefaultSize(button)
	local cooldownCover = findChild(button, "CooldownCover")
	local cooldownGradient = if cooldownCover then cooldownCover:FindFirstChildWhichIsA("UIGradient") else nil

	button:SetAttribute("OnCooldown", true)
	self:_tweenButton({ ImageColor3 = READY_COLOR })

	if cooldownGradient then
		local remainingAlpha = math.clamp(cooldownLength / math.max(BombConfig.RechargeSeconds, 0.001), 0, 1)
		cooldownGradient.Offset = Vector2.new(0, remainingAlpha - 0.5)
		TweenService:Create(cooldownGradient, TweenInfo.new(cooldownLength), {
			Offset = Vector2.new(0, -0.5),
		}):Play()
	end

	self:_tweenButton({
		Size = scaleUDim2(defaultSize, 0.9),
	})

	if self._keybindCover then
		TweenService:Create(self._keybindCover, SIZE_TWEEN, {
			ImageTransparency = 0.25,
		}):Play()
	end

	self:_playFlipbook(button)

	task.delay(cooldownLength, function()
		if serial ~= self._cooldownSerial or not button.Parent then
			return
		end

		self:_finishCooldownVisual(false)
	end)
end

function BombButtonController:_syncCooldown()
	local count = getBombCount()
	local rechargeEndsAt = getRechargeEndsAt()
	local remaining = self:_getCooldownRemainingSeconds()

	if count < getBombMax() and rechargeEndsAt > getServerTime() and remaining > 0 then
		if self._cooldownRechargeEndsAt ~= rechargeEndsAt then
			self:_startCooldownVisual(remaining, rechargeEndsAt)
		end
	elseif self._button and self._button:GetAttribute("OnCooldown") then
		self._cooldownSerial += 1
		self:_finishCooldownVisual(false)
	end
end

function BombButtonController:_startCookTimer(duration: number)
	if duration <= 0 or not self._progressValue then
		return
	end

	self._timerRunning = true
	self._timerSerial += 1
	local serial = self._timerSerial
	self:_cancelTimerTweens()
	self:_startButtonColorFade(duration)
	self:_setTimerTransparent(true, false)
	self:_setTimerTransparent(false, true)

	self._progressValue.Value = 1
	self:_updateMeterGradients()

	if self._leftCircle then
		self._leftCircle.ImageColor3 = TIMER_READY_COLOR
	end
	if self._rightCircle then
		self._rightCircle.ImageColor3 = TIMER_READY_COLOR
	end

	self:_trackTimerTween(TweenService:Create(self._progressValue, TweenInfo.new(duration), {
		Value = 0,
	}))

	if self._leftCircle then
		self:_trackTimerTween(TweenService:Create(self._leftCircle, TweenInfo.new(duration), {
			ImageColor3 = TIMER_DANGER_COLOR,
		}))
	end
	if self._rightCircle then
		self:_trackTimerTween(TweenService:Create(self._rightCircle, TweenInfo.new(duration), {
			ImageColor3 = TIMER_DANGER_COLOR,
		}))
	end

	if self._ropeGradient then
		self._ropeGradient.Offset = Vector2.new(-1, -1)
		self:_trackTimerTween(TweenService:Create(self._ropeGradient, TweenInfo.new(duration), {
			Offset = Vector2.new(0, 0),
		}))
	end

	if self._fire and self._path2d then
		local pathSampleValue = Instance.new("NumberValue")
		self._pathSampleValue = pathSampleValue
		pathSampleValue.Value = 0
		pathSampleValue.Changed:Connect(function()
			if self._fire and self._path2d then
				self._fire.Position = self._path2d:GetPositionOnCurveArcLength(pathSampleValue.Value)
			end
		end)

		local tween = TweenService:Create(
			pathSampleValue,
			TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut),
			{ Value = 1 }
		)
		tween.Completed:Once(function()
			if self._pathSampleValue == pathSampleValue then
				self._pathSampleValue = nil
			end
			pathSampleValue:Destroy()
		end)
		self:_trackTimerTween(tween)
	end

	if self._progressLabel then
		self._progressLabel.Text = string.format("%.1fs", duration)
	end

	task.spawn(function()
		local startedAt = getServerTime()
		while serial == self._timerSerial and getServerTime() - startedAt < duration do
			local remaining = math.max(duration - (getServerTime() - startedAt), 0)
			if self._progressLabel then
				self._progressLabel.Text = string.format("%.1fs", remaining)
			end
			task.wait()
		end

		if serial == self._timerSerial then
			if self._progressLabel then
				self._progressLabel.Text = "0.0s"
			end
			self:_setTimerTransparent(true, true)
		end
	end)
end

function BombButtonController:_endCookTimer()
	if not self._timerRunning and #self._activeTimerTweens == 0 then
		return
	end

	self._timerRunning = false
	self._timerSerial += 1
	self:_cancelTimerTweens()
	self:_cancelButtonColorFade()
	if self._progressLabel then
		self._progressLabel.Text = "0.0s"
	end
	self:_setTimerTransparent(true, true)
end

function BombButtonController:_syncCount()
	local count = getBombCount()
	local previousCount = self._lastBombCount

	if self._countLabel then
		self._countLabel.Text = tostring(count)
	end
	if self._button then
		self._button.Selectable = count > 0
		self._button.AutoButtonColor = false
		if previousCount ~= nil and count > previousCount then
			self:_playCooldownFinishedEffect(self._button)
		end
	end
	self._lastBombCount = count
	self:_syncCooldown()
end

function BombButtonController:_onHoldStarted()
	self._pressing = true
	self:_startHoldVisual()
	self:_syncCount()
end

function BombButtonController:_onHoldReleased()
	self._pressing = false
	self:_endCookTimer()
	self:_syncCount()
end

function BombButtonController:_onCookingChanged()
	if isCooking() and BombController:IsHoldingBomb() then
		if not self._timerRunning then
			self:_startCookTimer(self:_getCookRemainingSeconds())
		end
	elseif not BombController:IsHoldingBomb() then
		self:_endCookTimer()
	end
end

function BombButtonController:_bindButton(button: ImageButton)
	self:_disconnectButton()

	self._button = button
	self._normalSize = button.Size
	self._hovering = false
	self._pressing = false
	button:SetAttribute("defaultSize", button.Size)
	button.AutoButtonColor = false

	table.insert(self._buttonConnections, button.MouseEnter:Connect(function()
		self._hovering = true
		if not button:GetAttribute("OnCooldown") then
			local hoverSize = self:_getHoverSize()
			if hoverSize then
				self:_tweenButton({ Size = hoverSize })
			end
		end
	end))

	table.insert(self._buttonConnections, button.MouseButton1Down:Connect(function()
		if not BombController:BeginBombHold() then
			return
		end

		if not button:GetAttribute("OnCooldown") then
			local smallSize = self:_getSmallSize()
			if smallSize then
				self:_tweenButton({ Size = smallSize })
			end
		end
	end))

	table.insert(self._buttonConnections, button.MouseButton1Up:Connect(function()
		if not button:GetAttribute("OnCooldown") then
			local hoverSize = self:_getHoverSize()
			if hoverSize then
				self:_tweenButton({ Size = hoverSize })
			end
		end
		BombController:ReleaseBombHold()
	end))

	table.insert(self._buttonConnections, button.MouseLeave:Connect(function()
		self._hovering = false
		if not button:GetAttribute("OnCooldown") then
			self:_tweenButton({ Size = self._normalSize })
		end
	end))
end

function BombButtonController:_bindHud(hud: Instance?)
	self:_disconnectButton()
	self:_cancelTimerTweens()
	self:_cancelButtonColorFade()
	self._button = nil
	self._normalSize = nil
	self._countLabel = nil
	self._icon = nil
	self._keybindCover = nil
	self._explodeEffect = nil
	self._cooldownEffect = nil
	self._bombProgress = nil
	self._progressValue = nil
	self._progressLabel = nil
	self._leftCircle = nil
	self._rightCircle = nil
	self._leftGradient = nil
	self._rightGradient = nil
	self._rope = nil
	self._ropeGradient = nil
	self._fire = nil
	self._path2d = nil
	self._elementsToTween = {}
	self._cooldownRechargeEndsAt = 0
	self._lastBombCount = nil

	if not hud then
		return
	end

	local buttons = hud:FindFirstChild("Buttons")
	local button = findChild(buttons, "Bomb")
	if not (button and button:IsA("ImageButton")) then
		return
	end

	self:_bindButton(button)
	self._countLabel = findChild(button, "Count") :: TextLabel?
	self._icon = findChild(button, "Icon") :: ImageLabel?

	local keybind = findChild(button, "Keybind")
	self._keybindCover = findChild(keybind, "CooldownCover") :: ImageLabel?

	local buttonControls = findChild(buttons, "ButtonControls")
	self._explodeEffect = findChild(buttonControls, "Flipbook") :: ImageLabel?
	self._cooldownEffect = findChild(buttonControls, "CooldownEffect") :: Frame?

	local bombProgress = hud:FindFirstChild("BombProgress")
	if bombProgress and bombProgress:IsA("GuiObject") then
		self._bombProgress = bombProgress
	end

	local progressBomb = findChild(bombProgress, "Bomb") :: ImageLabel?
	local rope = findChild(progressBomb, "Rope") :: ImageLabel?
	local roundMeter = findChild(bombProgress, "RoundMeter")
	local progressLabel = findChild(roundMeter, "ProgressLabel") :: TextLabel?
	local progressLabelStroke = if progressLabel then progressLabel:FindFirstChildWhichIsA("UIStroke") else nil
	local leftHalf = findChild(roundMeter, "LHalf")
	local rightHalf = findChild(roundMeter, "RHalf")
	local leftCircle = findChild(leftHalf, "Circle") :: ImageLabel?
	local rightCircle = findChild(rightHalf, "Circle") :: ImageLabel?

	self._progressValue = findChild(roundMeter, "Progress") :: NumberValue?
	self._progressLabel = progressLabel
	self._leftCircle = leftCircle
	self._rightCircle = rightCircle
	self._leftGradient = if leftCircle then leftCircle:FindFirstChildWhichIsA("UIGradient") else nil
	self._rightGradient = if rightCircle then rightCircle:FindFirstChildWhichIsA("UIGradient") else nil
	self._rope = rope
	self._ropeGradient = if rope then rope:FindFirstChildWhichIsA("UIGradient") else nil
	self._fire = findChild(rope, "Fire") :: ImageLabel?
	self._path2d = findChild(rope, "Path2D")

	for _, item in ipairs({
		progressBomb,
		rope,
		self._fire,
		progressLabel,
		progressLabelStroke,
		leftCircle,
		rightCircle,
	}) do
		if item then
			table.insert(self._elementsToTween, item)
		end
	end

	if self._progressValue then
		table.insert(self._connections, self._progressValue:GetPropertyChangedSignal("Value"):Connect(function()
			self:_updateMeterGradients()
		end))
	end

	self:_setTimerTransparent(true, false)
	self:_syncCount()
	self:_onCookingChanged()
end

function BombButtonController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild("HUD"))
end

function BombButtonController:OnStart()
	self:_disconnectAll()

	table.insert(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" then
			task.defer(function()
				self:_bindHud(child)
			end)
		end
	end))

	table.insert(self._connections, LocalPlayer:GetAttributeChangedSignal(ATTR.Count):Connect(function()
		self:_syncCount()
	end))
	table.insert(self._connections, LocalPlayer:GetAttributeChangedSignal(ATTR.Max):Connect(function()
		self:_syncCount()
	end))
	table.insert(self._connections, LocalPlayer:GetAttributeChangedSignal(ATTR.RechargeEndsAt):Connect(function()
		self:_syncCooldown()
	end))
	table.insert(self._connections, LocalPlayer:GetAttributeChangedSignal(ATTR.Cooking):Connect(function()
		self:_onCookingChanged()
	end))

	table.insert(self._connections, BombController.HoldStarted:Connect(function()
		self:_onHoldStarted()
	end))
	table.insert(self._connections, BombController.HoldReleased:Connect(function()
		self:_onHoldReleased()
	end))

	self:_bindCurrentHud()
end

return BombButtonController
