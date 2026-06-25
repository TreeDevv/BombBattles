local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local PurchasePromptFX = require(ReplicatedStorage.Shared.UI.SpinWheel.PurchasePromptFX)
local RewardScreen = require(ReplicatedStorage.Shared.UI.SpinWheel.RewardScreen)
local RobuxPurchases = require(ReplicatedStorage.Shared.Config.Lists.RobuxPurchases)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local SEGMENT_COUNT = 6
local SEGMENT_ANGLE = 360 / SEGMENT_COUNT
local RIG_BASE = UDim2.fromScale(0.5, 0.5)
local RIG_HIDDEN = UDim2.new(0.5, 0, -1.2, 0)
local FIREWORK_IMAGE = "rbxassetid://70972086856551"
local STAR_IMAGE = "rbxassetid://3926305904"
local PORTED_STUDIO_WHEEL_CLIENT_VERSION = 1

local FIREWORK_COLORS = {
	Color3.fromRGB(255, 73, 103),
	Color3.fromRGB(255, 214, 73),
	Color3.fromRGB(91, 255, 156),
	Color3.fromRGB(73, 187, 255),
	Color3.fromRGB(205, 103, 255),
}

local SpinWheelController = {}

SpinWheelController._started = false
SpinWheelController._model = nil :: Model?
SpinWheelController._touchPart = nil :: BasePart?
SpinWheelController._worldWheelImage = nil :: GuiObject?
SpinWheelController._billboardHeader = nil :: TextLabel?
SpinWheelController._billboardGradient = nil :: UIGradient?
SpinWheelController._billboardBaseColor = nil :: Color3?
SpinWheelController._gui = nil :: ScreenGui?
SpinWheelController._root = nil :: Frame?
SpinWheelController._rig = nil :: Frame?
SpinWheelController._rigScale = nil :: UIScale?
SpinWheelController._popGroup = nil :: Frame?
SpinWheelController._wheel = nil :: Frame?
SpinWheelController._tick = nil :: GuiObject?
SpinWheelController._spinButton = nil :: ImageButton?
SpinWheelController._buy1 = nil :: ImageButton?
SpinWheelController._buy3 = nil :: ImageButton?
SpinWheelController._closeButton = nil :: GuiButton?
SpinWheelController._spinTimer = nil :: TextLabel?
SpinWheelController._landFlash = nil :: GuiObject?
SpinWheelController._shineBar = nil :: GuiObject?
SpinWheelController._confettiLayer = nil :: Frame?
SpinWheelController._requestSpinRemote = nil :: RemoteFunction?
SpinWheelController._getStateRemote = nil :: RemoteFunction?
SpinWheelController._stateChangedRemote = nil :: RemoteEvent?
SpinWheelController._spins = 0
SpinWheelController._freeReadyClock = 0
SpinWheelController._opened = false
SpinWheelController._animating = false
SpinWheelController._suppressed = false
SpinWheelController._stateDirty = false
SpinWheelController._uiState = "closed"
SpinWheelController._blur = nil :: BlurEffect?
SpinWheelController._savedFov = nil :: number?
SpinWheelController._spinToken = 0
SpinWheelController._sessionRewards = {}
SpinWheelController._sparkles = {}
SpinWheelController._popScales = {}
SpinWheelController._rainbowGradients = {}
SpinWheelController._promptInFlight = false
SpinWheelController._pendingPurchaseProduct = 0
SpinWheelController._pendingPurchaseSpins = 0
SpinWheelController._purchaseCelebrated = false

local function findPath(root: Instance, pathParts: { string }): Instance?
	local current: Instance? = root
	for _, name in ipairs(pathParts) do
		current = current and current:FindFirstChild(name)
		if not current then
			return nil
		end
	end
	return current
end

local function findTextLabel(root: Instance?, name: string): TextLabel?
	if not root then
		return nil
	end
	local child = root:FindFirstChild(name, true)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findNumberHeader(root: Instance?): TextLabel?
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("TextLabel") and tonumber(descendant.Text) then
			return descendant
		end
	end
	return nil
end

local function findHeaderContaining(root: Instance?, text: string): TextLabel?
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("TextLabel") and string.find(descendant.Text, text, 1, true) then
			return descendant
		end
	end
	return nil
end

local function fmtPct(weight: number, total: number): string
	if total <= 0 then
		return "0%"
	end
	local pct = weight / total * 100
	if pct == math.floor(pct) then
		return string.format("%d%%", pct)
	end
	return string.format("%.1f%%", pct)
end

local function getProductId(productKey: string): number
	local config = RobuxPurchases.Products[productKey]
	return math.floor(tonumber(config and config.id) or 0)
end

local function getProductPrice(productKey: string): number
	local config = RobuxPurchases.Products[productKey]
	return math.floor(tonumber(config and config.price) or 0)
end

local function getOrCreateScale(guiObject: GuiObject): UIScale
	local scale = guiObject:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = guiObject
	end
	return scale
end

function SpinWheelController:_getRemotes(): boolean
	local folder = ReplicatedStorage:FindFirstChild(SpinWheelConfig.RemotesFolderName)
	local requestSpin = folder and folder:FindFirstChild(SpinWheelConfig.RequestSpinRemoteName)
	local getState = folder and folder:FindFirstChild(SpinWheelConfig.GetStateRemoteName)
	local stateChanged = folder and folder:FindFirstChild(SpinWheelConfig.StateChangedRemoteName)

	if not (requestSpin and requestSpin:IsA("RemoteFunction") and getState and getState:IsA("RemoteFunction") and stateChanged and stateChanged:IsA("RemoteEvent")) then
		local model = self._model or self:_findModel()
		local legacyFolder = model and model:FindFirstChild(SpinWheelConfig.RemotesFolderName)
		requestSpin = legacyFolder and legacyFolder:FindFirstChild(SpinWheelConfig.LegacyRequestSpinRemoteName)
		getState = legacyFolder and legacyFolder:FindFirstChild(SpinWheelConfig.LegacyGetStateRemoteName)
		stateChanged = legacyFolder and legacyFolder:FindFirstChild(SpinWheelConfig.LegacyStateChangedRemoteName)
	end

	if not (requestSpin and requestSpin:IsA("RemoteFunction")) then
		return false
	end
	if not (getState and getState:IsA("RemoteFunction")) then
		return false
	end
	if not (stateChanged and stateChanged:IsA("RemoteEvent")) then
		return false
	end

	self._requestSpinRemote = requestSpin
	self._getStateRemote = getState
	self._stateChangedRemote = stateChanged
	return true
end

function SpinWheelController:_findModel(): Model?
	local instance = findPath(workspace, SpinWheelConfig.ModelPath)
	return if instance and instance:IsA("Model") then instance else nil
end

function SpinWheelController:_playSound(name: string, speed: number?, volume: number?): Sound?
	local model = self._model
	local sounds = model and model:FindFirstChild("Sounds")
	local template = sounds and sounds:FindFirstChild(name)
	if not (template and template:IsA("Sound")) then
		return nil
	end

	local sound = template:Clone()
	if typeof(speed) == "number" then
		sound.PlaybackSpeed *= speed
	end
	if typeof(volume) == "number" then
		sound.Volume = volume
	end
	sound.Parent = sounds
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	return sound
end

function SpinWheelController:_emitWheelVfx(jackpot: boolean?)
	local model = self._model
	if not model then
		return
	end

	local targets = {}
	local uipart = model:FindFirstChild("UIPART")
	local confetti = uipart and uipart:FindFirstChild("Confetti")
	if confetti then
		table.insert(targets, {
			instance = confetti,
			count = if jackpot then 90 else 30,
		})
	end
	if jackpot then
		local stars = uipart and uipart:FindFirstChild("VFX_Stars")
		if stars then
			table.insert(targets, {
				instance = stars,
				count = 18,
			})
		end
	end

	for _, target in ipairs(targets) do
		local instance = target.instance
		if instance:IsA("ParticleEmitter") then
			instance:SetAttribute("EmitCount", target.count)
		else
			for _, descendant in ipairs(instance:GetDescendants()) do
				if descendant:IsA("ParticleEmitter") then
					descendant:SetAttribute("EmitCount", target.count)
				end
			end
		end
		EmitService.Emit(instance, "[SpinWheel]", 10)
	end
end

function SpinWheelController:_populateSegments(wheel: Frame)
	local totalWeight = SpinWheelConfig.GetTotalWeight()
	for index, reward in ipairs(SpinWheelConfig.Rewards) do
		local segment = wheel:FindFirstChild(tostring(index))
		if not segment then
			continue
		end

		local header = segment:FindFirstChild("Header")
		if header and header:IsA("TextLabel") then
			header.Text = tostring(reward.label or "")
		end

		local subheader = segment:FindFirstChild("Subheader")
		if subheader and subheader:IsA("TextLabel") then
			subheader.Text = tostring(reward.category or "")
		end

		local odds = segment:FindFirstChild("Odds")
		if odds and odds:IsA("TextLabel") then
			odds.Text = fmtPct(tonumber(reward.weight) or 0, totalWeight)
		end

		local iconFrame = segment:FindFirstChild("Icon")
		local icon = iconFrame and (iconFrame:FindFirstChild("Icon") or iconFrame)
		if icon and icon:IsA("ImageLabel") and typeof(reward.imageId) == "string" then
			icon.Image = reward.imageId
		end
	end
end

function SpinWheelController:_mirrorWorldWheel(wheel: Frame)
	local model = self._model
	if not model then
		return
	end

	local uipart = model:FindFirstChild("UIPART")
	local surfaceGui = uipart and uipart:FindFirstChild("SurfaceGui")
	if not (surfaceGui and surfaceGui:IsA("SurfaceGui")) then
		return
	end

	local existing = surfaceGui:FindFirstChild("FaceWheel")
	if existing and existing:IsA("GuiObject") then
		self._worldWheelImage = existing
	else
		local sourceImage = surfaceGui:FindFirstChildWhichIsA("ImageLabel")
		local clone = wheel:Clone()
		clone.Name = "FaceWheel"
		clone.AnchorPoint = Vector2.new(0.5, 0.5)
		clone.Position = UDim2.fromScale(0.5, 0.5)
		clone.Size = UDim2.fromScale(1, 1)
		clone.Rotation = sourceImage and sourceImage.Rotation or 0
		clone.Parent = surfaceGui
		if sourceImage then
			sourceImage.Visible = false
		end
		self._worldWheelImage = clone
	end

	for _, descendant in ipairs(surfaceGui:GetDescendants()) do
		if descendant:IsA("UIGradient") then
			table.insert(self._rainbowGradients, descendant)
		end
	end
end

function SpinWheelController:_collectGradients(root: Instance)
	table.clear(self._rainbowGradients)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("UIGradient") then
			table.insert(self._rainbowGradients, descendant)
		end
	end
end

function SpinWheelController:_setupRig(root: Frame, wheel: Frame, tick: GuiObject?)
	local rig = root:FindFirstChild("WheelRig")
	if not (rig and rig:IsA("Frame")) then
		rig = Instance.new("Frame")
		rig.Name = "WheelRig"
		rig.AnchorPoint = Vector2.new(0.5, 0.5)
		rig.BackgroundTransparency = 1
		rig.BorderSizePixel = 0
		rig.Position = RIG_BASE
		rig.Size = UDim2.fromScale(1, 1)
		rig.Parent = root
	end
	self._rig = rig
	self._rigScale = getOrCreateScale(rig)

	wheel.Parent = rig
	if tick then
		tick.Parent = rig
	end
	for _, name in ipairs({ "Decor1", "Decor2", "Decor3" }) do
		local decor = root:FindFirstChild(name)
		if decor and decor:IsA("GuiObject") then
			decor.Parent = rig
		end
	end

	local popGroup = root:FindFirstChild("PopGroup")
	if not (popGroup and popGroup:IsA("Frame")) then
		popGroup = Instance.new("Frame")
		popGroup.Name = "PopGroup"
		popGroup.BackgroundTransparency = 1
		popGroup.BorderSizePixel = 0
		popGroup.Size = UDim2.fromScale(1, 1)
		popGroup.Parent = root
	end
	self._popGroup = popGroup
	for _, child in ipairs(root:GetChildren()) do
		if child ~= rig and child ~= popGroup and child:IsA("GuiObject") then
			child.Parent = popGroup
		end
	end

	table.clear(self._popScales)
	for _, descendant in ipairs(popGroup:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			table.insert(self._popScales, getOrCreateScale(descendant))
		end
	end
end

function SpinWheelController:_createEntranceEffects(root: Frame)
	local flash = root:FindFirstChild("LandFlash")
	if not (flash and flash:IsA("GuiObject")) then
		local frame = Instance.new("Frame")
		frame.Name = "LandFlash"
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.BackgroundColor3 = Color3.new(1, 1, 1)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Position = UDim2.fromScale(0.5, 0.5)
		frame.Size = UDim2.fromScale(0.62, 0.62)
		frame.ZIndex = 90
		frame.Parent = root
		flash = frame
	end
	self._landFlash = flash

	local shine = root:FindFirstChild("ShineBar")
	if not (shine and shine:IsA("GuiObject")) then
		local bar = Instance.new("Frame")
		bar.Name = "ShineBar"
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.BackgroundColor3 = Color3.new(1, 1, 1)
		bar.BackgroundTransparency = 0.35
		bar.BorderSizePixel = 0
		bar.Position = UDim2.fromScale(-0.18, 0.5)
		bar.Rotation = 24
		bar.Size = UDim2.fromScale(0.06, 1.1)
		bar.Visible = false
		bar.ZIndex = 95
		bar.Parent = root
		shine = bar
	end
	self._shineBar = shine

	local confettiLayer = root:FindFirstChild("ButtonConfetti")
	if not (confettiLayer and confettiLayer:IsA("Frame")) then
		confettiLayer = Instance.new("Frame")
		confettiLayer.Name = "ButtonConfetti"
		confettiLayer.BackgroundTransparency = 1
		confettiLayer.BorderSizePixel = 0
		confettiLayer.Size = UDim2.fromScale(1, 1)
		confettiLayer.ZIndex = 100
		confettiLayer.Parent = root
	end
	self._confettiLayer = confettiLayer

	table.clear(self._sparkles)
	for index = 1, 10 do
		local sparkle = root:FindFirstChild("Sparkle" .. index)
		if not (sparkle and sparkle:IsA("ImageLabel")) then
			sparkle = Instance.new("ImageLabel")
			sparkle.Name = "Sparkle" .. index
			sparkle.AnchorPoint = Vector2.new(0.5, 0.5)
			sparkle.BackgroundTransparency = 1
			sparkle.Image = STAR_IMAGE
			sparkle.ImageRectOffset = Vector2.new(4, 4)
			sparkle.ImageRectSize = Vector2.new(36, 36)
			sparkle.ImageTransparency = 1
			sparkle.Size = UDim2.fromOffset(28, 28)
			sparkle.ZIndex = 96
			sparkle.Parent = root
		end
		table.insert(self._sparkles, sparkle)
	end
	self:_resetSparkles()
end

function SpinWheelController:_resetSparkles()
	for index, sparkle in ipairs(self._sparkles) do
		local angle = math.rad((index - 1) / math.max(#self._sparkles, 1) * 360)
		sparkle.Position = UDim2.fromScale(0.5 + math.cos(angle) * 0.36, 0.5 + math.sin(angle) * 0.36)
		sparkle.Rotation = math.deg(angle)
		sparkle.ImageTransparency = 1
	end
end

function SpinWheelController:_sparkleFlyOut()
	for index, sparkle in ipairs(self._sparkles) do
		local angle = math.rad((index - 1) / math.max(#self._sparkles, 1) * 360)
		TweenService:Create(sparkle, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(0.5 + math.cos(angle) * 0.48, 0.5 + math.sin(angle) * 0.48),
			ImageTransparency = 0.18,
		}):Play()
	end
end

function SpinWheelController:_sparkleReturn()
	self:_resetSparkles()
	for index, sparkle in ipairs(self._sparkles) do
		task.delay(index * 0.015, function()
			if sparkle.Parent then
				local originalTransparency = sparkle.ImageTransparency
				sparkle.ImageTransparency = 0.1
				TweenService:Create(sparkle, TweenInfo.new(0.28), {
					ImageTransparency = originalTransparency,
				}):Play()
			end
		end)
	end
end

function SpinWheelController:_shineSweep()
	local shine = self._shineBar
	if not shine then
		return
	end
	shine.Visible = true
	shine.Position = UDim2.fromScale(-0.18, 0.5)
	shine.BackgroundTransparency = 0.35
	local tween = TweenService:Create(shine, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(1.18, 0.5),
		BackgroundTransparency = 1,
	})
	tween.Completed:Once(function()
		shine.Visible = false
	end)
	tween:Play()
end

function SpinWheelController:_runEntranceCascade()
	for index, scale in ipairs(self._popScales) do
		scale.Scale = 0.68
		task.delay(index * 0.018, function()
			if scale.Parent then
				TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Scale = 1,
				}):Play()
			end
		end)
	end
end

function SpinWheelController:_shake(guiObject: GuiObject?)
	if not guiObject then
		return
	end
	local base = guiObject.Position
	local offsets = { -10, 10, -7, 7, -3, 0 }
	for index, offset in ipairs(offsets) do
		task.delay((index - 1) * 0.035, function()
			if guiObject.Parent then
				guiObject.Position = base + UDim2.fromOffset(offset, 0)
			end
		end)
	end
	task.delay(#offsets * 0.035 + 0.02, function()
		if guiObject.Parent then
			guiObject.Position = base
		end
	end)
end

function SpinWheelController:_setupButtonJuice(button: GuiButton?)
	if not button then
		return
	end
	local scale = getOrCreateScale(button)
	button.MouseEnter:Connect(function()
		self:_playSound("hover")
		TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1.05 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)
	button.MouseButton1Down:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.08), { Scale = 0.94 }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.05 }):Play()
	end)
end

function SpinWheelController:_buttonConfetti(button: GuiObject?, count: number)
	local layer = self._confettiLayer
	if not (layer and button) then
		return
	end

	local center = button.AbsolutePosition + button.AbsoluteSize / 2
	local parentPos = layer.AbsolutePosition
	local relative = center - parentPos
	for index = 1, count do
		local particle = Instance.new("Frame")
		particle.Name = "ButtonConfettiBit"
		particle.AnchorPoint = Vector2.new(0.5, 0.5)
		particle.BackgroundColor3 = FIREWORK_COLORS[((index - 1) % #FIREWORK_COLORS) + 1]
		particle.BorderSizePixel = 0
		particle.Position = UDim2.fromOffset(relative.X, relative.Y)
		particle.Rotation = math.random(0, 360)
		particle.Size = UDim2.fromOffset(math.random(5, 10), math.random(7, 15))
		particle.Parent = layer

		local direction = Vector2.new(math.random(-100, 100), math.random(-140, -35))
		local tween = TweenService:Create(particle, TweenInfo.new(math.random(45, 75) / 100, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromOffset(relative.X + direction.X, relative.Y + direction.Y),
			Rotation = particle.Rotation + math.random(-180, 180),
			BackgroundTransparency = 1,
		})
		tween.Completed:Once(function()
			particle:Destroy()
		end)
		tween:Play()
	end
end

function SpinWheelController:_purchaseCelebration(diff: number)
	self:_playSound("purchase")
	self:_emitWheelVfx(false)
	self:_buttonConfetti(self._spinButton, 45)
	local spinButton = self._spinButton
	if spinButton then
		local scale = getOrCreateScale(spinButton)
		scale.Scale = 1.18
		TweenService:Create(scale, TweenInfo.new(0.42, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()

		local float = Instance.new("TextLabel")
		float.Name = "PurchaseDiff"
		float.AnchorPoint = Vector2.new(0.5, 0.5)
		float.BackgroundTransparency = 1
		float.Font = Enum.Font.GothamBlack
		float.Text = ("+%d"):format(math.max(1, diff))
		float.TextColor3 = Color3.fromRGB(130, 255, 130)
		float.TextScaled = true
		float.Position = UDim2.fromScale(0.5, 0)
		float.Size = UDim2.fromScale(0.5, 0.3)
		float.ZIndex = (spinButton.ZIndex or 1) + 10
		float.Parent = spinButton
		local tween = TweenService:Create(float, TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(0.5, -0.35),
			TextTransparency = 1,
		})
		tween.Completed:Once(function()
			float:Destroy()
		end)
		tween:Play()
	end
end

function SpinWheelController:_setupBuy(button: ImageButton?, productKey: string)
	if not button then
		return
	end
	self:_setupButtonJuice(button)

	local productId = getProductId(productKey)
	local priceLabel = findNumberHeader(button)
	if priceLabel then
		local price = getProductPrice(productKey)
		if price > 0 then
			priceLabel.Text = tostring(price)
		end
		task.spawn(function()
			if productId <= 0 then
				return
			end
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
			end)
			if ok and typeof(info) == "table" and tonumber(info.PriceInRobux) then
				priceLabel.Text = tostring(info.PriceInRobux)
			end
		end)
	end

	button.Activated:Connect(function()
		if self._animating or self._promptInFlight then
			self:_playSound("deny")
			self:_shake(button)
			return
		end
		if productId <= 0 then
			self:_playSound("deny")
			self:_shake(button)
			return
		end
		self._promptInFlight = true
		self._pendingPurchaseProduct = productId
		self._pendingPurchaseSpins = self._spins
		self._purchaseCelebrated = false
		self:_playSound("click")
		PurchasePromptFX.Notify("started", 30)
		MarketplaceService:PromptProductPurchase(LocalPlayer, productId)
	end)
end

function SpinWheelController:_setupButtons()
	local spinButton = self._spinButton
	if spinButton then
		self:_setupButtonJuice(spinButton)
		spinButton.Activated:Connect(function()
			self:_requestSpin()
		end)
	end

	if self._closeButton then
		self:_setupButtonJuice(self._closeButton)
		self._closeButton.Activated:Connect(function()
			if self._animating then
				return
			end
			self._suppressed = true
			self:_close()
		end)
	end

	self:_setupBuy(self._buy1, SpinWheelConfig.ProductKeys.Buy1)
	self:_setupBuy(self._buy3, SpinWheelConfig.ProductKeys.Buy3)
end

function SpinWheelController:_bindGui(): boolean
	if self._gui and self._gui.Parent then
		return true
	end

	local model = self._model or self:_findModel()
	if not model then
		warn("[SpinWheelController] Missing Workspace.Lobby.MonetizationArea.SpinWheel")
		return false
	end
	self._model = model

	local touchPart = model:FindFirstChild("TouchPart")
	local uipart = model:FindFirstChild("UIPART")
	local template = model:FindFirstChild("WheelGui")
	if not (touchPart and touchPart:IsA("BasePart")) then
		warn("[SpinWheelController] Missing SpinWheel.TouchPart")
		return false
	end
	if not (uipart and uipart:IsA("BasePart")) then
		warn("[SpinWheelController] Missing SpinWheel.UIPART")
		return false
	end
	if not (template and template:IsA("ScreenGui")) then
		warn("[SpinWheelController] Missing SpinWheel.WheelGui")
		return false
	end

	self._touchPart = touchPart

	local gui = template:Clone()
	gui.Name = "SpinWheelGui"
	gui.Enabled = false
	gui.Parent = PlayerGui
	self._gui = gui

	local root = gui:WaitForChild("FortuneWheel", 10)
	if not (root and root:IsA("Frame")) then
		warn("[SpinWheelController] Missing WheelGui.FortuneWheel")
		return false
	end
	self._root = root

	local wheel = root:WaitForChild("Wheel", 10)
	local buttons = root:WaitForChild("Buttons", 10)
	local tick = root:FindFirstChild("Tick")
	if not (wheel and wheel:IsA("Frame") and buttons and buttons:IsA("Frame")) then
		warn("[SpinWheelController] Wheel GUI is missing required children")
		return false
	end
	if tick and not tick:IsA("GuiObject") then
		tick = nil
	end

	self._wheel = wheel
	self._tick = tick :: GuiObject?
	self:_populateSegments(wheel)
	self:_collectGradients(gui)
	self:_setupRig(root, wheel, tick :: GuiObject?)
	self:_createEntranceEffects(root)
	self:_mirrorWorldWheel(wheel)

	self._spinButton = buttons:FindFirstChild("Spin") :: ImageButton?
	self._buy1 = buttons:FindFirstChild("Buy1") :: ImageButton?
	self._buy3 = buttons:FindFirstChild("Buy3") :: ImageButton?
	self._closeButton = root:FindFirstChild("Close", true) :: GuiButton?
	self._spinTimer = self._spinButton and self._spinButton:FindFirstChild("Timer", true) :: TextLabel?

	local billboard = model:FindFirstChild("BillboardGui", true)
	self._billboardHeader = if billboard then findTextLabel(billboard, "Header") else nil
	self._billboardGradient = self._billboardHeader and self._billboardHeader:FindFirstChildOfClass("UIGradient") or nil
	self._billboardBaseColor = self._billboardHeader and self._billboardHeader.TextColor3 or Color3.new(1, 1, 1)

	local rewardGui = model:FindFirstChild("RewardGui")
	RewardScreen.Init(model, if rewardGui and rewardGui:IsA("ScreenGui") then rewardGui else nil)
	self:_setupButtons()
	return true
end

function SpinWheelController:_freeReady(): boolean
	return os.clock() >= self._freeReadyClock
end

function SpinWheelController:_applyState(state)
	if typeof(state) ~= "table" then
		return
	end
	if self._animating then
		self._stateDirty = true
	end
	self._spins = math.max(0, math.floor(tonumber(state.Spins) or 0))
	self._freeReadyClock = os.clock() + math.max(0, (tonumber(state.NextFreeAt) or 0) - (tonumber(state.Now) or os.time()))
	if not self._animating then
		self:_refreshLabels()
	end
end

function SpinWheelController:_refreshLabels()
	if self._animating then
		self._stateDirty = true
		return
	end

	local spinButton = self._spinButton
	local spinLabel = spinButton and findHeaderContaining(spinButton, "Spin")
	local spinCaption = spinButton and findHeaderContaining(spinButton, "Buy")
	local ready = self:_freeReady()

	if spinLabel then
		if self._spins > 0 then
			spinLabel.Text = ("Spin (%d)"):format(self._spins)
		elseif ready then
			spinLabel.Text = "FREE SPIN!"
		else
			spinLabel.Text = "Spin (0)"
		end
	end
	if spinCaption then
		spinCaption.Text = if ready and self._spins == 0 then "FREE!" else ""
	end
end

function SpinWheelController:_cameraIn()
	if not SpinWheelConfig.cameraEffects then
		return
	end
	if not self._blur then
		local blur = Instance.new("BlurEffect")
		blur.Name = "SpinWheelBlur"
		blur.Size = 0
		blur.Parent = Lighting
		self._blur = blur
	end
	TweenService:Create(self._blur :: BlurEffect, TweenInfo.new(0.25), { Size = 8 }):Play()

	local camera = workspace.CurrentCamera
	if camera and not self._savedFov then
		self._savedFov = camera.FieldOfView
		TweenService:Create(camera, TweenInfo.new(0.25), { FieldOfView = self._savedFov - 3 }):Play()
	end
end

function SpinWheelController:_cameraOut()
	if self._blur then
		TweenService:Create(self._blur, TweenInfo.new(0.2), { Size = 0 }):Play()
	end
	local camera = workspace.CurrentCamera
	if camera and self._savedFov then
		TweenService:Create(camera, TweenInfo.new(0.25), { FieldOfView = self._savedFov }):Play()
		self._savedFov = nil
	end
end

function SpinWheelController:_maybeShowRecap()
	if #self._sessionRewards == 0 then
		return
	end
	local rewards = table.clone(self._sessionRewards)
	table.clear(self._sessionRewards)
	RewardScreen.Show(rewards)
end

function SpinWheelController:_open()
	if self._opened or not self:_bindGui() then
		return
	end

	local gui = self._gui
	local rig = self._rig
	local rigScale = self._rigScale
	if not (gui and rig and rigScale) then
		return
	end

	self._opened = true
	self._uiState = "dropping"
	gui.Enabled = true
	rig.Position = RIG_HIDDEN
	rigScale.Scale = 0.88
	for _, scale in ipairs(self._popScales) do
		scale.Scale = 0
	end
	self:_resetSparkles()
	self:_playSound("pop", nil, 4)
	self:_cameraIn()

	local tween = TweenService:Create(rig, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Position = RIG_BASE,
	})
	tween.Completed:Once(function()
		if not self._opened then
			return
		end
		self._uiState = "idle"
		TweenService:Create(rigScale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		local flash = self._landFlash
		if flash then
			flash.BackgroundTransparency = 0.72
			TweenService:Create(flash, TweenInfo.new(0.28), { BackgroundTransparency = 1 }):Play()
		end
		self:_playSound("shine")
		self:_shineSweep()
		self:_runEntranceCascade()
	end)
	tween:Play()
	self:_refreshLabels()
end

function SpinWheelController:_close()
	if not self._opened then
		return
	end

	local gui = self._gui
	local rig = self._rig
	self._opened = false
	self._uiState = "rising"
	self:_playSound("close")

	for index, scale in ipairs(self._popScales) do
		task.delay(index * 0.01, function()
			if scale.Parent then
				TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					Scale = 0,
				}):Play()
			end
		end)
	end

	if rig then
		local tween = TweenService:Create(rig, TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
			Position = RIG_HIDDEN,
		})
		tween.Completed:Once(function()
			if not self._opened and gui then
				gui.Enabled = false
				self._uiState = "closed"
				self:_maybeShowRecap()
			end
		end)
		tween:Play()
	elseif gui then
		gui.Enabled = false
		self._uiState = "closed"
		self:_maybeShowRecap()
	end

	self:_cameraOut()
end

function SpinWheelController:_requestSpin()
	if self._animating or not self._opened then
		return
	end
	if self._spins <= 0 and not self:_freeReady() then
		self:_playSound("deny")
		self:_shake(self._spinButton)
		return
	end

	local remote = self._requestSpinRemote
	if not remote then
		self:_playSound("deny")
		self:_shake(self._spinButton)
		return
	end

	self._animating = true
	self._stateDirty = false
	self._uiState = "spinning"
	self._spinToken += 1
	local token = self._spinToken
	self:_playSound("pop")

	task.delay(13, function()
		if self._animating and self._spinToken == token then
			self._animating = false
			self._uiState = if self._opened then "idle" else "closed"
			self:_refreshLabels()
		end
	end)

	task.spawn(function()
		local ok, result = pcall(function()
			return remote:InvokeServer()
		end)
		if token ~= self._spinToken then
			return
		end
		if not (ok and typeof(result) == "table" and result.ok == true) then
			self._animating = false
			self._uiState = if self._opened then "idle" else "closed"
			self:_playSound("deny")
			self:_shake(self._spinButton)
			if typeof(result) == "table" and result.state then
				self:_applyState(result.state)
			else
				self:_refreshLabels()
			end
			return
		end

		if result.reward then
			table.insert(self._sessionRewards, result.reward)
		end
		if result.state then
			self:_applyState(result.state)
		end
		self:_runSpinAnimation(tonumber(result.segment) or 1, result.reward or {}, token)
	end)
end

function SpinWheelController:_runSpinAnimation(segment: number, reward, token: number)
	local wheel = self._wheel
	local tick = self._tick
	if not wheel then
		self._animating = false
		return
	end

	self:_sparkleFlyOut()
	local base = wheel.Rotation
	local windupTween = TweenService:Create(wheel, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Rotation = base - 22,
	})
	windupTween:Play()
	windupTween.Completed:Wait()
	if token ~= self._spinToken then
		return
	end

	local targetMod = (-((segment - 1) * SEGMENT_ANGLE)) % 360
	local current = wheel.Rotation
	local delta = (targetMod - (current % 360) + 360) % 360
	local target = current + delta + 9 * 360 + (math.random() - 0.5) * 38
	local settledTarget = targetMod
	local lastTickIndex = math.floor((current + SEGMENT_ANGLE / 2) / SEGMENT_ANGLE)
	local watcher = RunService.Heartbeat:Connect(function()
		local idx = math.floor((wheel.Rotation + SEGMENT_ANGLE / 2) / SEGMENT_ANGLE)
		if idx ~= lastTickIndex then
			lastTickIndex = idx
			self:_playSound("tick", 1 + math.random(-6, 6) / 100)
			if tick then
				tick.Rotation = -13
				TweenService:Create(tick, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Rotation = 0,
				}):Play()
			end
		end
	end)

	local spinSound = self:_playSound("spin", 9 / 7.3)
	local tween = TweenService:Create(wheel, TweenInfo.new(8.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Rotation = target,
	})
	tween:Play()
	local startedAt = os.clock()
	while token == self._spinToken and os.clock() - startedAt < 9 do
		if math.abs((wheel.Rotation % 360) - (target % 360)) < 0.6 then
			break
		end
		RunService.Heartbeat:Wait()
	end
	tween:Cancel()
	watcher:Disconnect()

	local settle = TweenService:Create(wheel, TweenInfo.new(0.12, Enum.EasingStyle.Linear), {
		Rotation = settledTarget,
	})
	settle:Play()
	settle.Completed:Wait()

	if spinSound and spinSound.Parent then
		TweenService:Create(spinSound, TweenInfo.new(0.16), { Volume = 0 }):Play()
	end
	task.wait(0.2)
	if token ~= self._spinToken then
		return
	end
	self:_revealReward(segment, reward)
	self._animating = false
	self._uiState = if self._opened then "idle" else "closed"
	self:_sparkleReturn()
	if self._stateDirty then
		self._stateDirty = false
	end
	self:_refreshLabels()
end

function SpinWheelController:_makeExplosion(position: UDim2, color: Color3)
	local layer = self._confettiLayer
	if not layer then
		return
	end
	for index = 1, 18 do
		local shard = Instance.new("ImageLabel")
		shard.Name = "FireworkShard"
		shard.AnchorPoint = Vector2.new(0.5, 0.5)
		shard.BackgroundTransparency = 1
		shard.Image = FIREWORK_IMAGE
		shard.ImageColor3 = color
		shard.Position = position
		shard.Rotation = math.random(0, 360)
		shard.Size = UDim2.fromOffset(18, 18)
		shard.ZIndex = 110
		shard.Parent = layer
		local angle = math.rad(index / 18 * 360)
		local distance = math.random(55, 125)
		local tween = TweenService:Create(shard, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = position + UDim2.fromOffset(math.cos(angle) * distance, math.sin(angle) * distance),
			ImageTransparency = 1,
			Rotation = shard.Rotation + math.random(-180, 180),
		})
		tween.Completed:Once(function()
			shard:Destroy()
		end)
		tween:Play()
	end
end

function SpinWheelController:_launchFirework()
	local layer = self._confettiLayer
	if not layer then
		return
	end
	local color = FIREWORK_COLORS[math.random(1, #FIREWORK_COLORS)]
	local start = UDim2.fromScale(math.random(20, 80) / 100, 1.08)
	local finish = UDim2.fromScale(math.random(20, 80) / 100, math.random(12, 42) / 100)
	local rocket = Instance.new("ImageLabel")
	rocket.Name = "FireworkRocket"
	rocket.AnchorPoint = Vector2.new(0.5, 0.5)
	rocket.BackgroundTransparency = 1
	rocket.Image = FIREWORK_IMAGE
	rocket.ImageColor3 = color
	rocket.Position = start
	rocket.Size = UDim2.fromOffset(24, 24)
	rocket.ZIndex = 109
	rocket.Parent = layer
	local tween = TweenService:Create(rocket, TweenInfo.new(0.38, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = finish,
		ImageTransparency = 0.2,
	})
	tween.Completed:Once(function()
		rocket:Destroy()
		self:_makeExplosion(finish, color)
	end)
	tween:Play()
end

function SpinWheelController:_jackpotFireworks()
	for index = 1, 5 do
		task.delay(index * 0.12, function()
			self:_launchFirework()
		end)
	end
end

function SpinWheelController:_revealReward(segment: number, reward)
	local jackpot = typeof(reward) == "table" and reward.jackpot == true
	self:_playSound(if jackpot then "winJackpot" else "winCommon")
	self:_emitWheelVfx(jackpot)
	if jackpot then
		self:_jackpotFireworks()
	end

	local camera = workspace.CurrentCamera
	if camera and self._savedFov then
		TweenService:Create(camera, TweenInfo.new(0.08), { FieldOfView = self._savedFov - 6 }):Play()
		task.delay(0.1, function()
			if camera and self._savedFov then
				TweenService:Create(camera, TweenInfo.new(0.24), { FieldOfView = self._savedFov - 3 }):Play()
			end
		end)
	end

	local wheel = self._wheel
	local segmentFrame = wheel and wheel:FindFirstChild(tostring(segment))
	local icon = segmentFrame and segmentFrame:FindFirstChild("Icon")
	if icon and icon:IsA("GuiObject") then
		local scale = getOrCreateScale(icon)
		scale.Scale = 1.35
		TweenService:Create(scale, TweenInfo.new(0.5, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
	end
end

function SpinWheelController:_inZone(margin: number): boolean
	local touchPart = self._touchPart
	if not touchPart then
		return false
	end
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return false
	end
	local localPosition = touchPart.CFrame:PointToObjectSpace(root.Position)
	return math.abs(localPosition.X) <= touchPart.Size.X / 2 + margin
		and math.abs(localPosition.Z) <= touchPart.Size.Z / 2 + margin
		and math.abs(localPosition.Y) <= 10
end

function SpinWheelController:_tickWorld(dt: number)
	if self._worldWheelImage then
		self._worldWheelImage.Rotation = (self._worldWheelImage.Rotation + SpinWheelConfig.IdleWheelSpeedDegreesPerSecond * dt) % 360
	end
	if self._opened and not self._animating and self._wheel then
		self._wheel.Rotation = (self._wheel.Rotation + 4 * dt) % 360
	end

	local offset = math.sin(os.clock() * 1.6) * 0.5
	for _, gradient in ipairs(self._rainbowGradients) do
		if gradient.Parent then
			gradient.Offset = Vector2.new(offset, 0)
		end
	end

	for index, sparkle in ipairs(self._sparkles) do
		if sparkle.Parent then
			local alpha = (math.sin(os.clock() * 3 + index) + 1) * 0.5
			sparkle.ImageTransparency = if self._animating then 0.15 + alpha * 0.35 else 0.78 + alpha * 0.2
			sparkle.Rotation += dt * 25
		end
	end

	local remaining = self._freeReadyClock - os.clock()
	if self._billboardHeader then
		if remaining <= 0 then
			self._billboardHeader.Text = "FREE SPIN READY!"
			self._billboardHeader.TextColor3 = Color3.fromRGB(130, 255, 130)
			if self._billboardGradient then
				self._billboardGradient.Enabled = false
			end
		else
			self._billboardHeader.Text = ("FREE SPIN IN: %d:%02d"):format(math.floor(remaining / 60), math.floor(remaining % 60))
			self._billboardHeader.TextColor3 = self._billboardBaseColor or Color3.new(1, 1, 1)
			if self._billboardGradient then
				self._billboardGradient.Enabled = true
			end
		end
	end
	if self._spinTimer then
		if remaining <= 0 then
			self._spinTimer.Text = "FREE SPIN READY!"
			self._spinTimer.TextColor3 = Color3.fromRGB(130, 255, 130)
		else
			self._spinTimer.Text = ("Free Spin in %d:%02d"):format(math.floor(remaining / 60), math.floor(remaining % 60))
			self._spinTimer.TextColor3 = Color3.new(1, 1, 1)
		end
	end
	self:_refreshLabels()
end

function SpinWheelController:_fetchState()
	local remote = self._getStateRemote
	if not remote then
		return
	end
	task.spawn(function()
		local ok, state = pcall(function()
			return remote:InvokeServer()
		end)
		if ok then
			self:_applyState(state)
		end
	end)
end

function SpinWheelController:_bindCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Once(function()
			self._suppressed = false
			self:_close()
		end)
	end
end

function SpinWheelController:OnStart()
	if self._started then
		return
	end
	self._started = true
	PurchasePromptFX.Start()

	task.spawn(function()
		self._model = self:_findModel()
		local remotes = ReplicatedStorage:WaitForChild(SpinWheelConfig.RemotesFolderName, 15)
		if remotes or self._model then
			self:_getRemotes()
			if self._stateChangedRemote then
				self._stateChangedRemote.OnClientEvent:Connect(function(state)
					local previousSpins = self._spins
					self:_applyState(state)
					if self._promptInFlight and not self._purchaseCelebrated and self._pendingPurchaseProduct > 0 and self._spins > previousSpins then
						self._purchaseCelebrated = true
						self:_purchaseCelebration(self._spins - previousSpins)
					end
				end)
			end
			self:_fetchState()
		end
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, wasPurchased: boolean)
		if userId ~= LocalPlayer.UserId or productId ~= self._pendingPurchaseProduct then
			return
		end
		PurchasePromptFX.Notify("finished", nil, wasPurchased)
		local before = self._pendingPurchaseSpins
		self._promptInFlight = false
		self._pendingPurchaseProduct = 0
		task.delay(0.5, function()
			self:_fetchState()
			local diff = math.max(0, self._spins - before)
			if wasPurchased and diff > 0 and not self._purchaseCelebrated then
				self._purchaseCelebrated = true
				self:_purchaseCelebration(diff)
			end
		end)
	end)

	task.defer(function()
		self:_bindGui()
	end)
	if LocalPlayer.Character then
		task.defer(function()
			self:_bindCharacter(LocalPlayer.Character :: Model)
		end)
	end
	LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)

	local proximityAcc = 0
	RunService.Heartbeat:Connect(function(dt)
		self:_tickWorld(dt)
		proximityAcc += dt
		if proximityAcc < 0.15 then
			return
		end
		proximityAcc = 0
		if not self._touchPart then
			self:_bindGui()
			return
		end
		if self._opened then
			if not self._animating and not self:_inZone(SpinWheelConfig.CloseMarginStuds) then
				self:_close()
			end
		elseif self:_inZone(SpinWheelConfig.OpenMarginStuds) then
			if not self._suppressed then
				self:_open()
			end
		else
			self._suppressed = false
		end
	end)
end

return SpinWheelController
