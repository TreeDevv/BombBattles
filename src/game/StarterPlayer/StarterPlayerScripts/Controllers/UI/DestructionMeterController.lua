local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local DestructionMeterConfig = require(ReplicatedStorage.Shared.Config.DestructionMeterConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local UIParticleEmitter = require(ReplicatedStorage.Shared.UI.UIParticleEmitter)

local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local REMOTES_FOLDER_NAME = "Remotes"
local UNCHARGED_FRAME_NAME = DestructionMeterConfig.UnchargedFrameName or "DestructionMeterUncharged"
local RUNTIME_CHIP_LAYER_NAME = "DestructionMeterChipLayer"
local MULTIPLIER_LABEL_NAME = "DestructionMeterMultiplier"
local LABEL_IN_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Back)
local LABEL_FLASH_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Quad)
local COVER_FADE_TWEEN = TweenInfo.new(0.5, Enum.EasingStyle.Quad)
local METER_BUMP_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
local TIER_UP_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, true)
local METER_HIDE_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Quad)
local MIN_CHIP_VALUE = 1
local FADE_IN_TWEEN = TweenInfo.new(DestructionMeterConfig.FadeInSeconds or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_OUT_TWEEN = TweenInfo.new(DestructionMeterConfig.FadeOutSeconds or 0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SCORE_TWEEN = TweenInfo.new(DestructionMeterConfig.ScoreTweenSeconds or 0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local PROGRESS_TWEEN = TweenInfo.new(
	DestructionMeterConfig.ProgressTweenSeconds or 0.18,
	Enum.EasingStyle.Quint,
	Enum.EasingDirection.Out
)

type Tier = {
	id: string,
	text: string,
	threshold: number,
	multiplier: number,
	decaySeconds: number,
}

type VisualState = {
	meterLabelGradient: ColorSequence?,
	meterLabelStrokeColor: Color3?,
	meterLabelStrokeGradient: ColorSequence?,
	fillGradient: ColorSequence?,
}

type Fader = {
	instance: Instance,
	property: string,
	value: number,
}

local DestructionMeterController = {}

DestructionMeterController._connections = {} :: { RBXScriptConnection }
DestructionMeterController._hudConnections = {} :: { RBXScriptConnection }
DestructionMeterController._meter = nil :: Frame?
DestructionMeterController._referenceMeter = nil :: Frame?
DestructionMeterController._bar = nil :: Frame?
DestructionMeterController._fill = nil :: Frame?
DestructionMeterController._cover = nil :: Frame?
DestructionMeterController._label = nil :: TextLabel?
DestructionMeterController._multiplierLabel = nil :: TextLabel?
DestructionMeterController._bonuses = nil :: Frame?
DestructionMeterController._particleHolder = nil :: GuiObject?
DestructionMeterController._chipLayer = nil :: Frame?
DestructionMeterController._bonusLabels = {} :: { [string]: TextLabel }
DestructionMeterController._emitters = {} :: { any }
DestructionMeterController._tweens = {} :: { Tween }
DestructionMeterController._fadeTweens = {} :: { Tween }
DestructionMeterController._activeClones = {} :: { TextLabel }
DestructionMeterController._faders = {} :: { Fader }
DestructionMeterController._baseVisualState = nil :: VisualState?
DestructionMeterController._godlyVisualState = nil :: VisualState?
DestructionMeterController._baseRotation = 0
DestructionMeterController._baseSize = nil :: UDim2?
DestructionMeterController._bigSize = nil :: UDim2?
DestructionMeterController._tierUpSize = nil :: UDim2?
DestructionMeterController._smallSize = nil :: UDim2?
DestructionMeterController._labelSize = nil :: UDim2?
DestructionMeterController._biggerLabelSize = nil :: UDim2?
DestructionMeterController._tierUpLabelSize = nil :: UDim2?
DestructionMeterController._tierIndex = 1
DestructionMeterController._progress = 0
DestructionMeterController._meterScoreTotal = 0
DestructionMeterController._displayScoreTotal = 0
DestructionMeterController._visible = false
DestructionMeterController._fadingOut = false
DestructionMeterController._runId = 0
DestructionMeterController._fadeSerial = 0
DestructionMeterController._queueSerial = 0
DestructionMeterController._batchCancelSerial = 0
DestructionMeterController._pendingRawValue = 0
DestructionMeterController._lastScoredAt = 0
DestructionMeterController._scoreDisplayValue = nil :: NumberValue?
DestructionMeterController._scoreDisplayTween = nil :: Tween?
DestructionMeterController._fillTween = nil :: Tween?
DestructionMeterController._remoteBindSerial = 0
DestructionMeterController._lastFrameTime = 0
DestructionMeterController._warnedMissingMeter = false
DestructionMeterController._pendingWorldPosition = nil :: Vector3?

local function getTiers(): { Tier }
	return DestructionMeterConfig.Tiers :: { Tier }
end

local function getTier(index: number): Tier
	local tiers = getTiers()
	return tiers[math.clamp(index, 1, #tiers)]
end

local function isGodlyTier(index: number): boolean
	return index >= #getTiers()
end

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

local function findFrame(parent: Instance?, name: string): Frame?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("Frame") then child else nil
end

local function findTextLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function getFillGradient(root: Instance?): UIGradient?
	local bar = findFrame(root, "Bar")
	local fill = findFrame(bar, "Fill")
	local gradient = fill and fill:FindFirstChild("FillGradient")
	return if gradient and gradient:IsA("UIGradient") then gradient else nil
end

local function getLabelGradient(root: Instance?): UIGradient?
	local label = findTextLabel(root, "MeterLabel")
	return if label then label:FindFirstChildWhichIsA("UIGradient") else nil
end

local function getLabelStroke(root: Instance?): UIStroke?
	local label = findTextLabel(root, "MeterLabel")
	return if label then label:FindFirstChildWhichIsA("UIStroke") else nil
end

local function cloneColorSequence(sequence: ColorSequence?): ColorSequence?
	if not sequence then
		return nil
	end
	return ColorSequence.new(sequence.Keypoints)
end

local function getFirstColor(sequence: ColorSequence?): Color3?
	if not sequence then
		return nil
	end

	local keypoints = sequence.Keypoints
	return if #keypoints > 0 then keypoints[1].Value else nil
end

local function captureVisualState(root: Instance?): VisualState
	local labelGradient = getLabelGradient(root)
	local labelStroke = getLabelStroke(root)
	local labelStrokeGradient = labelStroke and labelStroke:FindFirstChildWhichIsA("UIGradient")
	local fillGradient = getFillGradient(root)

	return {
		meterLabelGradient = cloneColorSequence(if labelGradient then labelGradient.Color else nil),
		meterLabelStrokeColor = if labelStroke then labelStroke.Color else nil,
		meterLabelStrokeGradient = cloneColorSequence(if labelStrokeGradient then labelStrokeGradient.Color else nil),
		fillGradient = cloneColorSequence(if fillGradient then fillGradient.Color else nil),
	}
end

local function getSequenceFromTierLabel(label: TextLabel?, fallback: ColorSequence?): ColorSequence?
	if not label then
		return fallback
	end

	local gradient = label:FindFirstChildWhichIsA("UIGradient")
	if gradient then
		return cloneColorSequence(gradient.Color)
	end

	return ColorSequence.new(label.TextColor3)
end

local function getStrokeSequenceFromTierLabel(label: TextLabel?, fallback: ColorSequence?): ColorSequence?
	if not label then
		return fallback
	end

	local stroke = label:FindFirstChildWhichIsA("UIStroke")
	local gradient = stroke and stroke:FindFirstChildWhichIsA("UIGradient")
	if gradient then
		return cloneColorSequence(gradient.Color)
	end
	if stroke then
		return ColorSequence.new(stroke.Color)
	end
	return fallback
end

local function getStrokeColorFromTierLabel(label: TextLabel?, fallback: Color3?): Color3?
	local stroke = label and label:FindFirstChildWhichIsA("UIStroke")
	return if stroke then stroke.Color else fallback
end

local function getRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(DestructionMeterConfig.RemoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getAbsoluteCenter(gui: GuiObject): Vector2
	return gui.AbsolutePosition + gui.AbsoluteSize * 0.5
end

local function getProjectedScreenPoint(worldPosition: Vector3?): Vector2?
	if typeof(worldPosition) ~= "Vector3" then
		return nil
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local viewportPoint, onScreen = camera:WorldToViewportPoint(worldPosition)
	if not onScreen or viewportPoint.Z <= 0 then
		return nil
	end

	return Vector2.new(viewportPoint.X, viewportPoint.Y)
end

local function makeChipText(value: number): string
	return "+" .. tostring(math.max(1, math.floor(value + 0.5)))
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

local function getCurrentRoundState(): string?
	local state = RoundController:GetState()
	return if typeof(state) == "table" and typeof(state.state) == "string" then state.state else nil
end

local function scaleUDim2(value: UDim2, factor: number): UDim2
	return UDim2.new(value.X.Scale * factor, value.X.Offset * factor, value.Y.Scale * factor, value.Y.Offset * factor)
end

local function addFader(faders: { Fader }, instance: Instance, property: string)
	table.insert(faders, {
		instance = instance,
		property = property,
		value = (instance :: any)[property],
	})
end

local function collectFaders(root: GuiObject): { Fader }
	local faders = {}

	local function visit(instance: Instance)
		if instance:IsA("GuiObject") then
			addFader(faders, instance, "BackgroundTransparency")
		end
		if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
			addFader(faders, instance, "TextTransparency")
			addFader(faders, instance, "TextStrokeTransparency")
		end
		if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
			addFader(faders, instance, "ImageTransparency")
		end
		if instance:IsA("UIStroke") then
			addFader(faders, instance, "Transparency")
		end
	end

	visit(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		visit(descendant)
	end

	return faders
end

local function getFaderTransparency(fader: Fader, alpha: number): number
	return fader.value + (1 - fader.value) * math.clamp(alpha, 0, 1)
end

function DestructionMeterController:_trackTween(tween: Tween): Tween
	table.insert(self._tweens, tween)
	tween:Play()
	tween.Completed:Once(function()
		local index = table.find(self._tweens, tween)
		if index then
			table.remove(self._tweens, index)
		end
	end)
	return tween
end

function DestructionMeterController:_trackFadeTween(tween: Tween): Tween
	table.insert(self._fadeTweens, tween)
	tween:Play()
	tween.Completed:Once(function()
		local index = table.find(self._fadeTweens, tween)
		if index then
			table.remove(self._fadeTweens, index)
		end
	end)
	return tween
end

function DestructionMeterController:_cancelTweens()
	for _, tween in ipairs(self._tweens) do
		tween:Cancel()
	end
	table.clear(self._tweens)
end

function DestructionMeterController:_cancelFadeTweens()
	for _, tween in ipairs(self._fadeTweens) do
		tween:Cancel()
	end
	table.clear(self._fadeTweens)
end

function DestructionMeterController:_cancelFillTween()
	if self._fillTween then
		self._fillTween:Cancel()
		self._fillTween = nil
	end
end

function DestructionMeterController:_clearActiveClones()
	for _, clone in ipairs(self._activeClones) do
		if clone.Parent then
			clone:Destroy()
		end
	end
	table.clear(self._activeClones)
end

function DestructionMeterController:_setFadeAlpha(alpha: number)
	for _, fader in ipairs(self._faders) do
		if fader.instance.Parent then
			(fader.instance :: any)[fader.property] = getFaderTransparency(fader, alpha)
		end
	end
end

function DestructionMeterController:_tweenFadeAlpha(alpha: number, tweenInfo: TweenInfo, onComplete: (() -> ())?)
	self:_cancelFadeTweens()
	for _, fader in ipairs(self._faders) do
		if fader.instance.Parent then
			local goal = {}
			goal[fader.property] = getFaderTransparency(fader, alpha)
			self:_trackFadeTween(TweenService:Create(fader.instance, tweenInfo, goal))
		end
	end

	if onComplete then
		task.delay(tweenInfo.Time, onComplete)
	end
end

function DestructionMeterController:_applyVisualState(state: VisualState?)
	if not state then
		return
	end

	local labelGradient = getLabelGradient(self._meter)
	if labelGradient and state.meterLabelGradient then
		labelGradient.Color = state.meterLabelGradient
	end

	local labelStroke = getLabelStroke(self._meter)
	if labelStroke and state.meterLabelStrokeColor then
		labelStroke.Color = state.meterLabelStrokeColor
	end

	local labelStrokeGradient = labelStroke and labelStroke:FindFirstChildWhichIsA("UIGradient")
	if labelStrokeGradient and state.meterLabelStrokeGradient then
		labelStrokeGradient.Color = state.meterLabelStrokeGradient
	end

	local fillGradient = getFillGradient(self._meter)
	if fillGradient and state.fillGradient then
		fillGradient.Color = state.fillGradient
	end
end

function DestructionMeterController:_updateMultiplierLabel(state: VisualState?)
	local label = self._multiplierLabel
	if not label then
		return
	end

	local tier = getTier(self._tierIndex)
	label.Text = "x" .. tostring(tier.multiplier)
	label.Visible = true

	local gradient = label:FindFirstChildWhichIsA("UIGradient")
	if gradient and state and state.meterLabelGradient then
		gradient.Color = state.meterLabelGradient
	end

	local stroke = label:FindFirstChildWhichIsA("UIStroke")
	if stroke and state then
		if state.meterLabelStrokeColor then
			stroke.Color = state.meterLabelStrokeColor
		end

		local strokeGradient = stroke:FindFirstChildWhichIsA("UIGradient")
		if strokeGradient and state.meterLabelStrokeGradient then
			strokeGradient.Color = state.meterLabelStrokeGradient
		end
	end

	local fallbackColor = getFirstColor(if state then state.meterLabelGradient else nil)
	if fallbackColor then
		label.TextColor3 = fallbackColor
	end
end

function DestructionMeterController:_buildTierVisualState(tierIndex: number): VisualState?
	if tierIndex <= 1 then
		return self._baseVisualState
	end
	if isGodlyTier(tierIndex) then
		return self._godlyVisualState or self._baseVisualState
	end

	local tier = getTier(tierIndex)
	local tierLabel = self._bonusLabels[tier.id]
	local fallback = self._baseVisualState or {}
	local labelGradient = getSequenceFromTierLabel(tierLabel, fallback.meterLabelGradient)

	return {
		meterLabelGradient = labelGradient,
		meterLabelStrokeColor = getStrokeColorFromTierLabel(tierLabel, fallback.meterLabelStrokeColor),
		meterLabelStrokeGradient = getStrokeSequenceFromTierLabel(tierLabel, fallback.meterLabelStrokeGradient),
		fillGradient = labelGradient or fallback.fillGradient,
	}
end

function DestructionMeterController:_applyTierVisuals()
	local state = self:_buildTierVisualState(self._tierIndex)
	self:_applyVisualState(state)
	self:_updateMultiplierLabel(state)

	local godly = isGodlyTier(self._tierIndex)
	if self._cover then
		self._cover.Visible = godly
		if not godly then
			self._cover.BackgroundTransparency = 1
		end
	end

	for index, configuredTier in ipairs(getTiers()) do
		local bonusLabel = self._bonusLabels[configuredTier.id]
		if bonusLabel then
			local shouldShow = index < self._tierIndex or (godly and index == #getTiers())
			bonusLabel.Visible = shouldShow
		end
	end
end

function DestructionMeterController:_getProgressRatio(): number
	local tier = getTier(self._tierIndex)
	if tier.threshold <= 0 then
		return 0
	end
	return math.clamp(self._progress / tier.threshold, 0, 1)
end

function DestructionMeterController:_setFillRatio(ratio: number, animate: boolean?)
	if self._fill then
		local size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1)
		self:_cancelFillTween()
		if animate then
			local tween = TweenService:Create(self._fill, PROGRESS_TWEEN, { Size = size })
			self._fillTween = tween
			tween:Play()
			tween.Completed:Once(function()
				if self._fillTween == tween then
					self._fillTween = nil
				end
			end)
		else
			self._fill.Size = size
		end
	end
end

function DestructionMeterController:_ensureScoreDisplayValue(): NumberValue
	if self._scoreDisplayValue then
		return self._scoreDisplayValue
	end

	local value = Instance.new("NumberValue")
	value.Name = "DestructionMeterDisplayScore"
	value.Value = self._displayScoreTotal
	self._scoreDisplayValue = value
	track(self._connections, value.Changed:Connect(function()
		self._displayScoreTotal = value.Value
		self:_updateMeterLabel()
	end))
	return value
end

function DestructionMeterController:_updateMeterLabel()
	if self._label then
		self._label.Text = formatInteger(self._displayScoreTotal)
	end
end

function DestructionMeterController:_setDisplayedScore(value: number)
	if self._scoreDisplayTween then
		self._scoreDisplayTween:Cancel()
		self._scoreDisplayTween = nil
	end

	self._displayScoreTotal = value
	local driver = self:_ensureScoreDisplayValue()
	driver.Value = value
	self:_updateMeterLabel()
end

function DestructionMeterController:_tweenDisplayedScore(target: number)
	local driver = self:_ensureScoreDisplayValue()
	if self._scoreDisplayTween then
		self._scoreDisplayTween:Cancel()
		self._scoreDisplayTween = nil
	end

	local tween = TweenService:Create(driver, SCORE_TWEEN, { Value = target })
	self._scoreDisplayTween = tween
	tween:Play()
	tween.Completed:Once(function()
		if self._scoreDisplayTween == tween then
			self._scoreDisplayTween = nil
		end
	end)
end

function DestructionMeterController:_hideImmediate()
	self._visible = false
	self._fadingOut = false
	if self._meter then
		self._meter.Visible = false
		self._meter.Rotation = self._baseRotation
		if self._baseSize then
			self._meter.Size = self._baseSize
		end
	end
	if self._cover then
		self._cover.Visible = isGodlyTier(self._tierIndex)
		self._cover.BackgroundTransparency = 1
	end
	self:_setFadeAlpha(1)
end

function DestructionMeterController:_ensureMeterVisibleForIncomingScore()
	local meter = self._meter
	if not meter then
		return
	end

	self._fadeSerial += 1
	self._fadingOut = false
	if not self._visible or not meter.Visible then
		self._visible = true
		meter.Visible = true
		meter.Rotation = self._baseRotation
		if self._baseSize then
			meter.Size = self._baseSize
		end
		self:_setFadeAlpha(1)
	end

	self:_tweenFadeAlpha(0, FADE_IN_TWEEN)
end

function DestructionMeterController:_beginFadeOutAfterDecay()
	if self._fadingOut then
		return
	end

	local meter = self._meter
	if not meter then
		self:_reset()
		return
	end

	self._fadingOut = true
	self._runId += 1
	self._fadeSerial += 1
	local fadeSerial = self._fadeSerial

	self:_cancelTweens()
	self:_clearActiveClones()
	self:_trackTween(TweenService:Create(meter, METER_HIDE_TWEEN, {
		Size = self._smallSize or scaleUDim2(meter.Size, 0.9),
	}))

	self:_tweenFadeAlpha(1, FADE_OUT_TWEEN, function()
		if self._fadeSerial ~= fadeSerial then
			return
		end

		self._tierIndex = 1
		self._progress = 0
		self._meterScoreTotal = 0
		self:_setDisplayedScore(0)
		self:_setFillRatio(0)
		self:_applyTierVisuals()
		self:_hideImmediate()
	end)
end

function DestructionMeterController:_reset()
	self._runId += 1
	self._tierIndex = 1
	self._progress = 0
	self._meterScoreTotal = 0
	self._pendingRawValue = 0
	self._pendingWorldPosition = nil
	self._queueSerial += 1
	self._batchCancelSerial += 1
	self:_cancelTweens()
	self:_cancelFadeTweens()
	self:_cancelFillTween()
	self:_clearActiveClones()
	self:_setFillRatio(0)
	self:_applyTierVisuals()
	self:_setDisplayedScore(0)

	if self._chipLayer then
		for _, child in ipairs(self._chipLayer:GetChildren()) do
			child:Destroy()
		end
	end
	for _, emitter in ipairs(self._emitters) do
		if emitter.Clear then
			emitter:Clear()
		end
	end

	self:_hideImmediate()
end

function DestructionMeterController:_emitParticles(count: number)
	for _, emitter in ipairs(self._emitters) do
		emitter:Emit(count)
	end
end

function DestructionMeterController:_playLabelFlash(scale: number?)
	local label = self._label
	if not label then
		return
	end

	label.Size = self._labelSize or label.Size
	self:_trackTween(TweenService:Create(label, LABEL_IN_TWEEN, {
		Size = self._labelSize or label.Size,
	}))

	local clone = label:Clone()
	clone.Parent = label.Parent
	clone.TextColor3 = Color3.fromRGB(255, 255, 255)
	clone.TextTransparency = 0
	clone.ZIndex += 1
	clone.Size = self._labelSize or label.Size

	local stroke = clone:FindFirstChildWhichIsA("UIStroke")
	if stroke then
		stroke:Destroy()
	end
	local gradient = clone:FindFirstChildWhichIsA("UIGradient")
	if gradient then
		gradient:Destroy()
	end

	table.insert(self._activeClones, clone)
	self:_trackTween(TweenService:Create(clone, LABEL_FLASH_TWEEN, {
		Size = if scale and self._labelSize then scaleUDim2(self._labelSize, scale) else self._biggerLabelSize or scaleUDim2(clone.Size, 1.5),
		TextTransparency = 1,
	}))

	task.delay(LABEL_FLASH_TWEEN.Time, function()
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

function DestructionMeterController:_playCoverFlash()
	local cover = self._cover
	if not cover then
		return
	end

	cover.Visible = true
	cover.BackgroundTransparency = 0
	cover.Size = UDim2.fromScale(math.max(self:_getProgressRatio(), 0.18), 1)

	local tween = self:_trackTween(TweenService:Create(cover, COVER_FADE_TWEEN, {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0, 1),
	}))
	tween.Completed:Once(function()
		if cover.Parent then
			cover.Visible = isGodlyTier(self._tierIndex)
			cover.BackgroundTransparency = 1
		end
	end)
end

function DestructionMeterController:_playMeterPulse(tierUp: boolean)
	local meter = self._meter
	if not meter then
		return
	end

	local tweenInfo = if tierUp then TIER_UP_TWEEN else METER_BUMP_TWEEN
	local size = if tierUp
		then self._tierUpSize or scaleUDim2(meter.Size, 1.32)
		else self._bigSize or scaleUDim2(meter.Size, 1.2)
	local rotationJitter = if tierUp then math.random(-9, 9) else math.random(-5, 5)
	self:_trackTween(TweenService:Create(meter, tweenInfo, {
		Rotation = self._baseRotation + rotationJitter,
		Size = size,
	}))
end

function DestructionMeterController:_playBonusPop(tierIndex: number)
	local tier = getTier(tierIndex)
	local label = self._bonusLabels[tier.id]
	if not label then
		return
	end

	label.Visible = true
	local scale = label:FindFirstChild("DestructionMeterBonusPopScale")
	if not (scale and scale:IsA("UIScale")) then
		scale = Instance.new("UIScale")
		scale.Name = "DestructionMeterBonusPopScale"
		scale.Parent = label
	end

	scale.Scale = 0.65
	local grow = self:_trackTween(TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1.2,
	}))
	grow.Completed:Once(function()
		if scale.Parent then
			self:_trackTween(TweenService:Create(scale, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Scale = 1,
			}))
		end
	end)
end

function DestructionMeterController:_runBumpSequence(tieredUp: boolean, previousTierIndex: number?)
	self:_cancelTweens()
	self:_clearActiveClones()
	self._visible = true

	local meter = self._meter
	if meter then
		meter.Visible = true
		meter.Rotation = self._baseRotation
		if self._baseSize then
			meter.Size = self._baseSize
		end
	end

	self:_playCoverFlash()
	self:_playLabelFlash(if tieredUp then 1.8 else 1.5)
	self:_playMeterPulse(tieredUp)

	if tieredUp then
		local firstUnlockedIndex = previousTierIndex or math.max(1, self._tierIndex - 1)
		for index = firstUnlockedIndex, math.max(firstUnlockedIndex, self._tierIndex - 1) do
			self:_playBonusPop(index)
		end
		if isGodlyTier(self._tierIndex) then
			self:_playBonusPop(self._tierIndex)
		end
		self:_emitParticles(DestructionMeterConfig.TierUpParticleBurst or 6)
	else
		self:_emitParticles(2)
	end
end

function DestructionMeterController:_addScore(value: number)
	if value <= 0 or getCurrentRoundState() ~= RoundStates.Active then
		return
	end

	local tier = getTier(self._tierIndex)
	local previousTierIndex = self._tierIndex
	local earnedScore = value * tier.multiplier
	self._progress += earnedScore
	self._meterScoreTotal += earnedScore
	self._lastScoredAt = os.clock()

	local tiers = getTiers()
	local tieredUp = false
	while self._progress >= tier.threshold and self._tierIndex < #tiers do
		local overflow = self._progress - tier.threshold
		self._tierIndex += 1
		tier = getTier(self._tierIndex)
		self._progress = math.max(tier.threshold * DestructionMeterConfig.TierStartProgressRatio, overflow)
		tieredUp = true
	end

	if self._tierIndex == #tiers then
		tier = getTier(self._tierIndex)
		self._progress = math.min(self._progress, tier.threshold)
	end

	self:_applyTierVisuals()
	self:_setFillRatio(self:_getProgressRatio(), true)
	self:_tweenDisplayedScore(self._meterScoreTotal)
	self:_runBumpSequence(tieredUp, previousTierIndex)
end

function DestructionMeterController:_getChipStartPosition(worldPosition: Vector3?): Vector2
	local chipLayer = self._chipLayer
	if not chipLayer then
		return Vector2.zero
	end

	local projected = getProjectedScreenPoint(worldPosition)
	if projected then
		local localPoint = projected - chipLayer.AbsolutePosition
		if localPoint.X >= -80
			and localPoint.Y >= -80
			and localPoint.X <= chipLayer.AbsoluteSize.X + 80
			and localPoint.Y <= chipLayer.AbsoluteSize.Y + 80
		then
			return localPoint + Vector2.new(math.random(-28, 28), math.random(-22, 22))
		end
	end

	local startOffset = Vector2.new(math.random(-90, 90), math.random(-42, 38))
	return Vector2.new(chipLayer.AbsoluteSize.X * 0.5, chipLayer.AbsoluteSize.Y * 0.5) + startOffset
end

function DestructionMeterController:_spawnChip(
	value: number,
	delaySeconds: number,
	onLanded: (() -> ())?,
	worldPosition: Vector3?
)
	local chipLayer = self._chipLayer
	local bar = self._bar
	if not (chipLayer and chipLayer.Parent and bar and bar.Parent) then
		if onLanded then
			onLanded()
		end
		return
	end

	task.delay(delaySeconds, function()
		if not (chipLayer.Parent and bar.Parent) then
			if onLanded then
				onLanded()
			end
			return
		end

		local start = self:_getChipStartPosition(worldPosition)
		local target = getAbsoluteCenter(bar) - chipLayer.AbsolutePosition
		local control = (start + target) * 0.5 + Vector2.new(math.random(-90, 90), -math.random(85, 145))
		local driver = Instance.new("NumberValue")
		driver.Value = 0

		local chip = Instance.new("TextLabel")
		chip.Name = "DestructionScoreChip"
		chip.AnchorPoint = Vector2.new(0.5, 0.5)
		chip.BackgroundTransparency = 1
		chip.BorderSizePixel = 0
		chip.Font = Enum.Font.GothamBlack
		chip.Text = makeChipText(value)
		chip.TextColor3 = Color3.fromRGB(255, 255, 255)
		chip.TextScaled = true
		chip.TextStrokeColor3 = Color3.new(0, 0, 0)
		chip.TextStrokeTransparency = 0.35
		chip.Position = UDim2.fromOffset(start.X, start.Y)
		chip.Rotation = math.random(-10, 10)
		chip.Size = UDim2.fromOffset(62, 32)
		chip.ZIndex = 200
		chip.Parent = chipLayer

		local connection = driver.Changed:Connect(function(alpha)
			local t = math.clamp(alpha, 0, 1)
			local inverse = 1 - t
			local point = start * inverse * inverse + control * 2 * inverse * t + target * t * t
			chip.Position = UDim2.fromOffset(point.X, point.Y)
			chip.TextTransparency = math.max(0, (t - 0.82) / 0.18)
			chip.TextStrokeTransparency = 0.35 + math.max(0, (t - 0.76) / 0.24) * 0.65
		end)

		local tween = TweenService:Create(
			driver,
			TweenInfo.new(DestructionMeterConfig.BaseChipDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ Value = 1 }
		)
		tween:Play()
		tween.Completed:Once(function()
			connection:Disconnect()
			driver:Destroy()
			if chip.Parent then
				chip:Destroy()
			end
			if onLanded then
				onLanded()
			end
		end)
	end)
end

function DestructionMeterController:_animateScore(value: number, worldPosition: Vector3?)
	local chipCount = math.clamp(math.ceil(math.sqrt(value)), 1, DestructionMeterConfig.MaxScoreChipsPerEvent)
	local baseValue = math.floor(value / chipCount)
	local remainder = value - baseValue * chipCount
	local scored = false

	local function onPrimaryChipLanded()
		if scored then
			return
		end

		scored = true
		self:_addScore(value)
	end

	for index = 1, chipCount do
		local chipValue = math.max(MIN_CHIP_VALUE, baseValue + (if index <= remainder then 1 else 0))
		self:_spawnChip(
			chipValue,
			(index - 1) * DestructionMeterConfig.ChipStaggerSeconds,
			if index == 1 then onPrimaryChipLanded else nil,
			worldPosition
		)
	end
end

function DestructionMeterController:_flushPendingScore(serial: number)
	if serial ~= self._queueSerial then
		return
	end

	local value = self._pendingRawValue
	local worldPosition = self._pendingWorldPosition
	self._pendingRawValue = 0
	self._pendingWorldPosition = nil
	if value <= 0 then
		return
	end

	local batchCancelSerial = self._batchCancelSerial
	local maxWaves = math.max(1, DestructionMeterConfig.MaxCadenceWaves or 3)
	local waveSize = math.max(1, DestructionMeterConfig.ScoreWaveSize or value)
	local waveCount = math.clamp(math.ceil(value / waveSize), 1, maxWaves)
	local baseValue = math.floor(value / waveCount)
	local remainder = value - baseValue * waveCount

	for waveIndex = 1, waveCount do
		local waveValue = baseValue + (if waveIndex <= remainder then 1 else 0)
		local delaySeconds = (DestructionMeterConfig.PreChipDelaySeconds or 0.18)
			+ (waveIndex - 1) * (DestructionMeterConfig.CadenceWaveDelaySeconds or 0.14)
		task.delay(delaySeconds, function()
			if batchCancelSerial ~= self._batchCancelSerial then
				return
			end
			self:_animateScore(waveValue, worldPosition)
		end)
	end
end

function DestructionMeterController:Bump(value: number, options: any?)
	if typeof(value) ~= "number" or value ~= value or value <= 0 then
		return
	end

	self:_ensureMeterVisibleForIncomingScore()
	self._pendingRawValue += math.clamp(math.floor(value + 0.5), 1, DestructionMeterConfig.MaxRemoteValue)
	if typeof(options) == "table" and typeof(options.worldPosition) == "Vector3" then
		self._pendingWorldPosition = options.worldPosition
	end
	self._queueSerial += 1
	local serial = self._queueSerial
	task.delay(DestructionMeterConfig.BumpMergeWindowSeconds or 0.12, function()
		self:_flushPendingScore(serial)
	end)
end

function DestructionMeterController:_updateDecay(deltaTime: number)
	if not self._visible or self._progress <= 0 then
		return
	end
	if self._pendingRawValue > 0 then
		return
	end
	if os.clock() - self._lastScoredAt < (DestructionMeterConfig.ComboGraceSeconds or 0.45) then
		return
	end

	local tier = getTier(self._tierIndex)
	local decaySeconds = math.max(0.1, tier.decaySeconds)
	self._progress = math.max(0, self._progress - tier.threshold * (deltaTime / decaySeconds))
	self:_setFillRatio(self:_getProgressRatio(), false)

	if self._progress <= 0 then
		self:_beginFadeOutAfterDecay()
	end
end

function DestructionMeterController:_createMultiplierLabel(meter: Frame, sourceLabel: TextLabel?): TextLabel?
	local existing = meter:FindFirstChild(MULTIPLIER_LABEL_NAME)
	if existing then
		existing:Destroy()
	end
	if not sourceLabel then
		return nil
	end

	local label = sourceLabel:Clone()
	label.Name = MULTIPLIER_LABEL_NAME
	label.Text = "x1"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Size = scaleUDim2(sourceLabel.Size, 0.38)
	label.Position = UDim2.new(
		sourceLabel.Position.X.Scale + sourceLabel.Size.X.Scale * 0.34,
		sourceLabel.Position.X.Offset + sourceLabel.Size.X.Offset * 0.34,
		sourceLabel.Position.Y.Scale + sourceLabel.Size.Y.Scale * 0.36,
		sourceLabel.Position.Y.Offset + sourceLabel.Size.Y.Offset * 0.36
	)
	label.Rotation = 0
	label.Visible = true
	label.ZIndex = sourceLabel.ZIndex + 2
	label.Parent = meter

	return label
end

function DestructionMeterController:_createChipLayer(hud: ScreenGui): Frame
	local existing = hud:FindFirstChild(RUNTIME_CHIP_LAYER_NAME)
	if existing then
		existing:Destroy()
	end

	local layer = Instance.new("Frame")
	layer.Name = RUNTIME_CHIP_LAYER_NAME
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.ClipsDescendants = false
	layer.Size = UDim2.fromScale(1, 1)
	layer.Position = UDim2.fromScale(0, 0)
	layer.ZIndex = 190
	layer.Parent = hud
	return layer
end

function DestructionMeterController:_findPresetFolder(): Folder?
	local current: Instance = ReplicatedStorage
	for _, childName in ipairs(DestructionMeterConfig.ParticlePresetPath) do
		local child = current:FindFirstChild(childName)
		if not child then
			return nil
		end
		current = child
	end
	return if current:IsA("Folder") then current else nil
end

function DestructionMeterController:_bindParticles()
	for _, emitter in ipairs(self._emitters) do
		if emitter.Destroy then
			emitter:Destroy()
		end
	end
	table.clear(self._emitters)

	local holder = self._particleHolder
	local presetFolder = self:_findPresetFolder()
	if not (holder and presetFolder) then
		return
	end

	for _, preset in ipairs(presetFolder:GetChildren()) do
		if preset:IsA("Configuration") then
			local emitter = UIParticleEmitter.new(preset)
			emitter:SetParent(holder)
			emitter:Disable()
			table.insert(self._emitters, emitter)
		end
	end
end

function DestructionMeterController:_cacheSizing(meter: Frame, label: TextLabel?)
	self._baseRotation = meter.Rotation
	self._baseSize = meter.Size
	self._bigSize = scaleUDim2(meter.Size, 1.2)
	self._tierUpSize = scaleUDim2(meter.Size, 1.32)
	self._smallSize = scaleUDim2(meter.Size, 0.9)
	if label then
		self._labelSize = label.Size
		self._biggerLabelSize = scaleUDim2(label.Size, 1.5)
		self._tierUpLabelSize = scaleUDim2(label.Size, 1.8)
	else
		self._labelSize = nil
		self._biggerLabelSize = nil
		self._tierUpLabelSize = nil
	end
end

function DestructionMeterController:_bindMeter(meter: Instance?, referenceMeter: Instance?, hud: ScreenGui?)
	self:_reset()
	self._meter = nil
	self._referenceMeter = nil
	self._bar = nil
	self._fill = nil
	self._cover = nil
	self._label = nil
	self._multiplierLabel = nil
	self._bonuses = nil
	self._particleHolder = nil
	self._chipLayer = nil
	self._bonusLabels = {}
	self._faders = {}
	self._baseVisualState = nil
	self._godlyVisualState = nil

	if not (meter and meter:IsA("Frame")) then
		return
	end

	self._meter = meter
	self._referenceMeter = if referenceMeter and referenceMeter:IsA("Frame") then referenceMeter else nil
	self._bar = findFrame(meter, "Bar")
	self._fill = findFrame(self._bar, "Fill")
	self._cover = findFrame(self._bar, "Cover")
	self._label = findTextLabel(meter, "MeterLabel")
	self._bonuses = findFrame(meter, "Bonuses")
	self._particleHolder = findFrame(meter, "ParticleHolder")
	self._chipLayer = if hud then self:_createChipLayer(hud) else nil
	self._multiplierLabel = self:_createMultiplierLabel(meter, self._label)
	self._faders = collectFaders(meter)

	self:_cacheSizing(meter, self._label)
	self._baseVisualState = captureVisualState(self._referenceMeter or meter)
	self._godlyVisualState = captureVisualState(meter)

	if self._referenceMeter then
		self._referenceMeter.Visible = false
	end

	for _, tier in ipairs(getTiers()) do
		local bonusLabel = findTextLabel(self._bonuses, tier.id)
		if bonusLabel then
			self._bonusLabels[tier.id] = bonusLabel
		end
	end

	meter.Visible = false
	self:_setFadeAlpha(1)
	self:_setFillRatio(0)
	self:_applyTierVisuals()
	self:_setDisplayedScore(0)
	self:_bindParticles()
end

function DestructionMeterController:_bindHud(hud: Instance?)
	disconnectAll(self._hudConnections)
	if not (hud and hud:IsA("ScreenGui")) then
		self:_bindMeter(nil, nil, nil)
		return
	end

	self:_bindMeter(hud:FindFirstChild(DestructionMeterConfig.MeterFrameName), hud:FindFirstChild(UNCHARGED_FRAME_NAME), hud)
	track(self._hudConnections, hud.ChildAdded:Connect(function(child)
		if child.Name == DestructionMeterConfig.MeterFrameName or child.Name == UNCHARGED_FRAME_NAME then
			task.defer(function()
				self:_bindMeter(hud:FindFirstChild(DestructionMeterConfig.MeterFrameName), hud:FindFirstChild(UNCHARGED_FRAME_NAME), hud)
			end)
		end
	end))
end

function DestructionMeterController:_bindCurrentHud()
	local hud = PlayerGui:FindFirstChild(DestructionMeterConfig.HudName)
	if not hud and not self._warnedMissingMeter then
		self._warnedMissingMeter = true
		warn("[DestructionMeterController] HUD not available yet; waiting for meter UI.")
	end
	self:_bindHud(hud)
end

function DestructionMeterController:_bindRemote()
	self._remoteBindSerial += 1
	local serial = self._remoteBindSerial

	task.spawn(function()
		local remote = getRemote()
		if serial ~= self._remoteBindSerial or not remote then
			return
		end

		track(self._connections, remote.OnClientEvent:Connect(function(payload)
			if typeof(payload) ~= "table" then
				return
			end
			local value = payload.value
			if typeof(value) == "number" then
				self:Bump(value, {
					worldPosition = payload.position,
				})
			end
		end))
	end)
end

function DestructionMeterController:_bindRoundResets()
	track(self._connections, RoundController.StateReceived:Connect(function()
		self:_reset()
	end))
	track(self._connections, RoundController.StateUpdated:Connect(function(key, value)
		if key == "roundId" then
			self:_reset()
		elseif key == "state" and value ~= RoundStates.Active then
			self:_reset()
		end
	end))
	track(self._connections, LocalPlayer.CharacterAdded:Connect(function()
		self:_reset()
	end))
	track(self._connections, LocalPlayer.CharacterRemoving:Connect(function()
		self:_reset()
	end))
end

function DestructionMeterController:_disconnectAll()
	self._remoteBindSerial += 1
	self._batchCancelSerial += 1
	disconnectAll(self._connections)
	disconnectAll(self._hudConnections)
	for _, emitter in ipairs(self._emitters) do
		if emitter.Destroy then
			emitter:Destroy()
		end
	end
	table.clear(self._emitters)
	self:_cancelTweens()
	self:_cancelFadeTweens()
	self:_cancelFillTween()
	self:_clearActiveClones()
	if self._scoreDisplayTween then
		self._scoreDisplayTween:Cancel()
		self._scoreDisplayTween = nil
	end
	if self._scoreDisplayValue then
		self._scoreDisplayValue:Destroy()
		self._scoreDisplayValue = nil
	end
end

function DestructionMeterController:OnStart()
	self:_disconnectAll()
	self._warnedMissingMeter = false
	self._tierIndex = 1
	self._progress = 0
	self._meterScoreTotal = 0
	self._displayScoreTotal = 0
	self._pendingRawValue = 0
	self._pendingWorldPosition = nil
	self._lastScoredAt = 0
	self._visible = false
	self._fadingOut = false
	self._lastFrameTime = os.clock()

	track(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == DestructionMeterConfig.HudName then
			task.defer(function()
				self:_bindHud(child)
			end)
		end
	end))
	track(self._connections, PlayerGui.ChildRemoved:Connect(function(child)
		if child.Name == DestructionMeterConfig.HudName then
			self:_bindHud(nil)
		end
	end))
	track(self._connections, RunService.RenderStepped:Connect(function()
		local now = os.clock()
		local deltaTime = math.min(now - self._lastFrameTime, 0.1)
		self._lastFrameTime = now
		self:_updateDecay(deltaTime)
	end))

	self:_bindRoundResets()
	self:_bindCurrentHud()
	self:_bindRemote()
end

return DestructionMeterController
