local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local PurchasePromptFX = {}

local gui: ScreenGui? = nil
local overlay: Frame? = nil
local title: TextLabel? = nil
local confettiLayer: Frame? = nil
local blur: BlurEffect? = nil
local savedFov: number? = nil
local startedAt = 0
local timeoutAt = 0
local active = false
local connection: RBXScriptConnection? = nil
local finishConnection: RBXScriptConnection? = nil

local COLORS = {
	Color3.fromRGB(255, 83, 83),
	Color3.fromRGB(255, 213, 74),
	Color3.fromRGB(89, 255, 142),
	Color3.fromRGB(86, 198, 255),
	Color3.fromRGB(205, 104, 255),
}

local function ensureGui()
	if gui and gui.Parent then
		return
	end

	gui = Instance.new("ScreenGui")
	gui.Name = "PurchasePromptFXGui"
	gui.DisplayOrder = 10000
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.Parent = PlayerGui

	overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.BackgroundColor3 = Color3.fromRGB(12, 10, 20)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.Parent = gui

	title = Instance.new("TextLabel")
	title.Name = "Header"
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.Text = "Complete Purchase"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.TextTransparency = 1
	title.Position = UDim2.fromScale(0.5, 0.2)
	title.Size = UDim2.fromScale(0.44, 0.08)
	title.Parent = overlay

	confettiLayer = Instance.new("Frame")
	confettiLayer.Name = "Confetti"
	confettiLayer.BackgroundTransparency = 1
	confettiLayer.BorderSizePixel = 0
	confettiLayer.Size = UDim2.fromScale(1, 1)
	confettiLayer.Parent = overlay
end

local function emitConfetti(count: number)
	ensureGui()
	local layer = confettiLayer
	if not layer then
		return
	end

	for index = 1, count do
		local bit = Instance.new("Frame")
		bit.Name = "ConfettiBit"
		bit.AnchorPoint = Vector2.new(0.5, 0.5)
		bit.BackgroundColor3 = COLORS[((index - 1) % #COLORS) + 1]
		bit.BorderSizePixel = 0
		bit.Position = UDim2.fromScale(math.random(), -0.05)
		bit.Rotation = math.random(0, 360)
		bit.Size = UDim2.fromOffset(math.random(6, 12), math.random(10, 20))
		bit.Parent = layer

		local target = UDim2.fromScale(math.random(), 1.12)
		local tween = TweenService:Create(bit, TweenInfo.new(math.random(75, 125) / 100, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = target,
			Rotation = bit.Rotation + math.random(-220, 220),
			BackgroundTransparency = 1,
		})
		tween.Completed:Once(function()
			bit:Destroy()
		end)
		tween:Play()
	end
end

local function startCamera()
	local camera = workspace.CurrentCamera
	if camera and not savedFov then
		savedFov = camera.FieldOfView
	end
	if not blur then
		blur = Instance.new("BlurEffect")
		blur.Name = "PurchasePromptFXBlur"
		blur.Size = 0
		blur.Parent = Lighting
	end
	TweenService:Create(blur, TweenInfo.new(0.18), { Size = 10 }):Play()
	if camera and savedFov then
		TweenService:Create(camera, TweenInfo.new(0.18), { FieldOfView = savedFov - 4 }):Play()
	end
end

local function stopCamera(success: boolean?)
	if blur then
		TweenService:Create(blur, TweenInfo.new(0.25), { Size = 0 }):Play()
	end
	local camera = workspace.CurrentCamera
	if camera and savedFov then
		TweenService:Create(camera, TweenInfo.new(0.25), { FieldOfView = savedFov }):Play()
	end
	savedFov = nil
	if success then
		emitConfetti(55)
	end
end

function PurchasePromptFX.Start()
	ensureGui()
	if finishConnection then
		return
	end

	finishConnection = MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, _productId, wasPurchased)
		if userId == LocalPlayer.UserId then
			PurchasePromptFX.Notify("finished", nil, wasPurchased)
		end
	end)

	_G.__PurchasePromptFXNotify = function(state, timeoutSeconds, wasPurchased)
		PurchasePromptFX.Notify(state, timeoutSeconds, wasPurchased)
	end
end

function PurchasePromptFX.Notify(state: string, timeoutSeconds: number?, wasPurchased: boolean?)
	ensureGui()
	if state == "started" then
		active = true
		startedAt = os.clock()
		timeoutAt = startedAt + math.max(1, tonumber(timeoutSeconds) or 8)
		if gui then
			gui.Enabled = true
		end
		if overlay then
			overlay.BackgroundTransparency = 1
			TweenService:Create(overlay, TweenInfo.new(0.18), { BackgroundTransparency = 0.32 }):Play()
		end
		if title then
			title.Text = "Complete Purchase"
			title.TextTransparency = 1
			title.Position = UDim2.fromScale(0.5, 0.18)
			TweenService:Create(title, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				TextTransparency = 0,
				Position = UDim2.fromScale(0.5, 0.2),
			}):Play()
		end
		startCamera()
		if connection then
			connection:Disconnect()
		end
		connection = RunService.Heartbeat:Connect(function()
			if active and os.clock() >= timeoutAt then
				PurchasePromptFX.Notify("finished", nil, false)
			end
		end)
		return
	end

	if state ~= "finished" or not active then
		return
	end
	active = false
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if title then
		title.Text = if wasPurchased then "Purchase Complete" else "Purchase Cancelled"
		TweenService:Create(title, TweenInfo.new(0.15), { TextTransparency = if wasPurchased then 0 else 0.25 }):Play()
	end
	stopCamera(wasPurchased == true)
	task.delay(if wasPurchased then 0.75 else 0.18, function()
		if active then
			return
		end
		if overlay then
			TweenService:Create(overlay, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
		end
		if title then
			TweenService:Create(title, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
		end
		task.wait(0.22)
		if gui and not active then
			gui.Enabled = false
		end
	end)
end

function PurchasePromptFX.Destroy()
	if connection then
		connection:Disconnect()
		connection = nil
	end
	if finishConnection then
		finishConnection:Disconnect()
		finishConnection = nil
	end
	if _G.__PurchasePromptFXNotify then
		_G.__PurchasePromptFXNotify = nil
	end
	if gui then
		gui:Destroy()
		gui = nil
	end
	if blur then
		blur:Destroy()
		blur = nil
	end
end

return PurchasePromptFX
