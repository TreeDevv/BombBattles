local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local BombController = require(script.Parent:WaitForChild("BombController"))

local SCREEN_GUI_NAME = "Crosshair"
local RETICLE_FRAME_NAME = "Crosshair"
local REMOTES_FOLDER_NAME = "Remotes"
local HIT_REMOTE_NAME = "Hit"
local RENDER_STEP_NAME = "BombBattlesCrosshairController"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3

local DEFAULT_RADIUS = 5
local DEFAULT_LERP = 0.1
local DEFAULT_EASING_STYLE = Enum.EasingStyle.Quad
local DEFAULT_EASING_DIRECTION = Enum.EasingDirection.Out
local THROW_BUMP_RADIUS = 3
local HIT_BUMP_MIN_RADIUS = 4
local HIT_BUMP_MAX_RADIUS = 8
local SHOW_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local HIDE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SCALE_NAME = "CrosshairControllerScale"
local HIDDEN_SCALE = 0.82

type TransparencyRecord = {
	instance: Instance,
	backgroundTransparency: number?,
	imageTransparency: number?,
	textTransparency: number?,
	textStrokeTransparency: number?,
	strokeTransparency: number?,
}

local CrosshairController = {}

CrosshairController._started = false
CrosshairController._connections = {} :: { RBXScriptConnection }
CrosshairController._screenGui = nil :: ScreenGui?
CrosshairController._reticle = nil :: Frame?
CrosshairController._scale = nil :: UIScale?
CrosshairController._radius = DEFAULT_RADIUS
CrosshairController._visible = nil :: boolean?
CrosshairController._visibilitySerial = 0
CrosshairController._visibilityTweens = {} :: { Tween }
CrosshairController._radiusTweens = {} :: { Tween }
CrosshairController._transparencyRecords = {} :: { TransparencyRecord }

local function getReticlePositions(radius: number): { [string]: UDim2 }
	return {
		Top = UDim2.new(0, 0, 0, -radius - 7),
		Left = UDim2.new(0, -radius - 7, 0, 0),
		Right = UDim2.new(0, radius, 0, 0),
		Bottom = UDim2.new(0, 0, 0, radius),
	}
end

local function getEffectiveShiftLocked(): boolean
	local character = LocalPlayer.Character
	return character ~= nil and character:GetAttribute("Camera_ShiftLocked") == true
end

local function getHitBumpRadius(amount: any): number
	if typeof(amount) ~= "number" then
		return HIT_BUMP_MIN_RADIUS
	end

	return math.clamp(amount / 10, HIT_BUMP_MIN_RADIUS, HIT_BUMP_MAX_RADIUS)
end

local function setRecordTransparency(record: TransparencyRecord, hiddenAlpha: number)
	local instance = record.instance
	if not instance.Parent then
		return
	end

	if record.backgroundTransparency ~= nil and instance:IsA("GuiObject") then
		instance.BackgroundTransparency = record.backgroundTransparency
			+ ((1 - record.backgroundTransparency) * hiddenAlpha)
	end
	if record.imageTransparency ~= nil and (instance:IsA("ImageLabel") or instance:IsA("ImageButton")) then
		instance.ImageTransparency = record.imageTransparency + ((1 - record.imageTransparency) * hiddenAlpha)
	end
	if record.textTransparency ~= nil and (instance:IsA("TextLabel") or instance:IsA("TextButton")) then
		instance.TextTransparency = record.textTransparency + ((1 - record.textTransparency) * hiddenAlpha)
	end
	if record.textStrokeTransparency ~= nil and (instance:IsA("TextLabel") or instance:IsA("TextButton")) then
		instance.TextStrokeTransparency = record.textStrokeTransparency
			+ ((1 - record.textStrokeTransparency) * hiddenAlpha)
	end
	if record.strokeTransparency ~= nil and instance:IsA("UIStroke") then
		instance.Transparency = record.strokeTransparency + ((1 - record.strokeTransparency) * hiddenAlpha)
	end
end

local function tweenRecordTransparency(record: TransparencyRecord, tweenInfo: TweenInfo, hiddenAlpha: number): Tween?
	local instance = record.instance
	if not instance.Parent then
		return nil
	end

	local properties = {}
	if record.backgroundTransparency ~= nil and instance:IsA("GuiObject") then
		properties.BackgroundTransparency = record.backgroundTransparency
			+ ((1 - record.backgroundTransparency) * hiddenAlpha)
	end
	if record.imageTransparency ~= nil and (instance:IsA("ImageLabel") or instance:IsA("ImageButton")) then
		properties.ImageTransparency = record.imageTransparency + ((1 - record.imageTransparency) * hiddenAlpha)
	end
	if record.textTransparency ~= nil and (instance:IsA("TextLabel") or instance:IsA("TextButton")) then
		properties.TextTransparency = record.textTransparency + ((1 - record.textTransparency) * hiddenAlpha)
	end
	if record.textStrokeTransparency ~= nil and (instance:IsA("TextLabel") or instance:IsA("TextButton")) then
		properties.TextStrokeTransparency = record.textStrokeTransparency
			+ ((1 - record.textStrokeTransparency) * hiddenAlpha)
	end
	if record.strokeTransparency ~= nil and instance:IsA("UIStroke") then
		properties.Transparency = record.strokeTransparency + ((1 - record.strokeTransparency) * hiddenAlpha)
	end

	if next(properties) == nil then
		return nil
	end

	local tween = TweenService:Create(instance, tweenInfo, properties)
	return tween
end

function CrosshairController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function CrosshairController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
end

function CrosshairController:_cancelVisibilityTweens()
	for _, tween in ipairs(self._visibilityTweens) do
		tween:Cancel()
	end
	self._visibilityTweens = {}
end

function CrosshairController:_cancelRadiusTweens()
	for _, tween in ipairs(self._radiusTweens) do
		tween:Cancel()
	end
	self._radiusTweens = {}
end

function CrosshairController:_setAllTransparent(hiddenAlpha: number)
	for _, record in ipairs(self._transparencyRecords) do
		setRecordTransparency(record, hiddenAlpha)
	end
end

function CrosshairController:_captureTransparencyRecords(reticle: Frame)
	self._transparencyRecords = {}

	local function capture(instance: Instance)
		local record: TransparencyRecord = {
			instance = instance,
			backgroundTransparency = nil,
			imageTransparency = nil,
			textTransparency = nil,
			textStrokeTransparency = nil,
			strokeTransparency = nil,
		}

		if instance:IsA("GuiObject") then
			record.backgroundTransparency = instance.BackgroundTransparency
		end
		if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
			record.imageTransparency = instance.ImageTransparency
		end
		if instance:IsA("TextLabel") or instance:IsA("TextButton") then
			record.textTransparency = instance.TextTransparency
			record.textStrokeTransparency = instance.TextStrokeTransparency
		end
		if instance:IsA("UIStroke") then
			record.strokeTransparency = instance.Transparency
		end

		if
			record.backgroundTransparency ~= nil
			or record.imageTransparency ~= nil
			or record.textTransparency ~= nil
			or record.textStrokeTransparency ~= nil
			or record.strokeTransparency ~= nil
		then
			table.insert(self._transparencyRecords, record)
		end
	end

	capture(reticle)
	for _, descendant in ipairs(reticle:GetDescendants()) do
		capture(descendant)
	end
end

function CrosshairController:_ensureScale(reticle: Frame): UIScale
	local scale = reticle:FindFirstChild(SCALE_NAME)
	if scale and scale:IsA("UIScale") then
		return scale
	end

	local newScale = Instance.new("UIScale")
	newScale.Name = SCALE_NAME
	newScale.Scale = 1
	newScale.Parent = reticle
	return newScale
end

function CrosshairController:_bindReticle(reticle: Frame)
	if self._reticle == reticle then
		return
	end

	self:_cancelVisibilityTweens()
	self:_cancelRadiusTweens()
	self._reticle = reticle
	self._scale = self:_ensureScale(reticle)
	self._visible = nil
	self:_captureTransparencyRecords(reticle)
	self:Set(self._radius, true, DEFAULT_EASING_STYLE, DEFAULT_EASING_DIRECTION, DEFAULT_LERP)
	self:_syncVisibility(true)
end

function CrosshairController:_bindCurrentGui()
	local screenGui = PlayerGui:FindFirstChild(SCREEN_GUI_NAME)
	if not (screenGui and screenGui:IsA("ScreenGui")) then
		self._screenGui = nil
		self._reticle = nil
		self._scale = nil
		self._visible = nil
		return
	end

	self._screenGui = screenGui
	local reticle = screenGui:FindFirstChild(RETICLE_FRAME_NAME)
	if reticle and reticle:IsA("Frame") then
		self:_bindReticle(reticle)
	end
end

function CrosshairController:_setReticleVisible(visible: boolean, instant: boolean?)
	local reticle = self._reticle
	local scale = self._scale
	if not reticle then
		return
	end
	if self._visible == visible then
		return
	end

	self._visible = visible
	self._visibilitySerial += 1
	local serial = self._visibilitySerial
	self:_cancelVisibilityTweens()

	if instant then
		reticle.Visible = visible
		if scale then
			scale.Scale = if visible then 1 else HIDDEN_SCALE
		end
		self:_setAllTransparent(if visible then 0 else 1)
		return
	end

	if visible then
		reticle.Visible = true
		if scale then
			scale.Scale = HIDDEN_SCALE
			table.insert(self._visibilityTweens, TweenService:Create(scale, SHOW_TWEEN, { Scale = 1 }))
		end
		self:_setAllTransparent(1)
		for _, record in ipairs(self._transparencyRecords) do
			local tween = tweenRecordTransparency(record, SHOW_TWEEN, 0)
			if tween then
				table.insert(self._visibilityTweens, tween)
			end
		end
	else
		if scale then
			table.insert(self._visibilityTweens, TweenService:Create(scale, HIDE_TWEEN, { Scale = HIDDEN_SCALE }))
		end
		for _, record in ipairs(self._transparencyRecords) do
			local tween = tweenRecordTransparency(record, HIDE_TWEEN, 1)
			if tween then
				table.insert(self._visibilityTweens, tween)
			end
		end

		task.delay(HIDE_TWEEN.Time, function()
			if serial == self._visibilitySerial and self._reticle == reticle and not self._visible then
				reticle.Visible = false
			end
		end)
	end

	for _, tween in ipairs(self._visibilityTweens) do
		tween:Play()
	end
end

function CrosshairController:_syncVisibility(instant: boolean?)
	self:_setReticleVisible(getEffectiveShiftLocked(), instant)
end

function CrosshairController:_updatePosition()
	local reticle = self._reticle
	if not reticle or not reticle.Visible then
		return
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	reticle.Position = UDim2.new(0, mouseLocation.X, 0, mouseLocation.Y)
end

function CrosshairController:Set(
	radius: number,
	canAnimate: boolean?,
	easingStyle: Enum.EasingStyle?,
	easingDirection: Enum.EasingDirection?,
	lerp: number?
)
	if typeof(radius) ~= "number" then
		warn("[CrosshairController] Radius must be a number")
		return
	end

	self._radius = radius
	local reticle = self._reticle
	if not reticle or not reticle.Parent then
		self:_bindCurrentGui()
		reticle = self._reticle
	end
	if not reticle then
		return
	end

	local positions = getReticlePositions(radius)
	self:_cancelRadiusTweens()

	for childName, position in pairs(positions) do
		local child = reticle:FindFirstChild(childName)
		if child and child:IsA("GuiObject") then
			if canAnimate == true then
				local tween = TweenService:Create(
					child,
					TweenInfo.new(
						lerp or DEFAULT_LERP,
						easingStyle or DEFAULT_EASING_STYLE,
						easingDirection or DEFAULT_EASING_DIRECTION
					),
					{ Position = position }
				)
				table.insert(self._radiusTweens, tween)
				tween:Play()
			else
				child.Position = position
			end
		end
	end
end

function CrosshairController:Shove(
	radius: number,
	easingStyle: Enum.EasingStyle?,
	easingDirection: Enum.EasingDirection?,
	lerp: number?
)
	if typeof(radius) ~= "number" then
		warn("[CrosshairController] Radius must be a number")
		return
	end

	local reticle = self._reticle
	if not reticle or not reticle.Parent then
		self:_bindCurrentGui()
		reticle = self._reticle
	end
	if not reticle then
		return
	end

	local shovePositions = getReticlePositions(self._radius + radius)
	for childName, position in pairs(shovePositions) do
		local child = reticle:FindFirstChild(childName)
		if child and child:IsA("GuiObject") then
			child.Position = position
		end
	end

	self:Set(self._radius, true, easingStyle, easingDirection, lerp)
end

function CrosshairController:_bump(radius: number, duration: number?)
	self:Shove(radius, DEFAULT_EASING_STYLE, DEFAULT_EASING_DIRECTION, duration or DEFAULT_LERP)
end

function CrosshairController:_bindThrowBump()
	self:_trackConnection(BombController.ThrowReleased:Connect(function()
		self:_bump(THROW_BUMP_RADIUS, 0.1)
	end))
end

function CrosshairController:_bindHitBump()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
		if not remotes then
			return
		end

		local remote = remotes:WaitForChild(HIT_REMOTE_NAME, 10)
		if not (remote and remote:IsA("RemoteEvent")) then
			return
		end

		self:_trackConnection(remote.OnClientEvent:Connect(function(amount)
			self:_bump(getHitBumpRadius(amount), 0.12)
		end))
	end)
end

function CrosshairController:_step()
	if not self._reticle or not self._reticle.Parent then
		self:_bindCurrentGui()
	end

	self:_syncVisibility(false)
	self:_updatePosition()
end

function CrosshairController:OnStart()
	if self._started then
		return
	end
	self._started = true

	self:_disconnectAll()
	self:_bindCurrentGui()
	self:_bindThrowBump()
	self:_bindHitBump()

	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == SCREEN_GUI_NAME then
			task.defer(function()
				self:_bindCurrentGui()
			end)
		end
	end))

	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function()
		self:_step()
	end)
end

return CrosshairController
