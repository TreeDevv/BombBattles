local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ScreenEffects = {}

local activeVignette: ImageLabel? = nil
local activeTween: Tween? = nil
local activeFadeDelay: any? = nil
local activeBlackOverlay: Frame? = nil
local activeBlackTween: Tween? = nil

local function getScreenGui(): ScreenGui?
	local player = Players.LocalPlayer
	if not player then
		return nil
	end

	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	local screenGui = playerGui:FindFirstChild("ScreenEffects")
	if screenGui and screenGui:IsA("ScreenGui") then
		return screenGui
	end
	return nil
end

local function getVignette(): ImageLabel?
	if activeVignette and activeVignette.Parent then
		return activeVignette
	end

	local screenGui = getScreenGui()
	if not screenGui then
		return nil
	end

	for _, child in ipairs(screenGui:GetChildren()) do
		if child.Name == "BlackFlash" and child:IsA("ImageLabel") then
			if not activeVignette then
				activeVignette = child
			else
				child:Destroy()
			end
		end
	end
	if activeVignette and activeVignette.Parent then
		return activeVignette
	end

	local template = screenGui:FindFirstChild("Vignette")
	if not (template and template:IsA("ImageLabel")) then
		return nil
	end

	activeVignette = template:Clone()
	activeVignette.Name = "BlackFlash"
	activeVignette.ImageTransparency = 1
	activeVignette.ImageColor3 = Color3.fromRGB(0, 0, 0)
	activeVignette.Parent = screenGui
	return activeVignette
end

local function getBlackOverlay(): Frame?
	if activeBlackOverlay and activeBlackOverlay.Parent then
		return activeBlackOverlay
	end

	local screenGui = getScreenGui()
	if not screenGui then
		return nil
	end

	screenGui.DisplayOrder = math.max(screenGui.DisplayOrder, 10000)

	local existing = screenGui:FindFirstChild("BlackFade")
	if existing and existing:IsA("Frame") then
		activeBlackOverlay = existing
		return existing
	end

	local overlay = Instance.new("Frame")
	overlay.Name = "BlackFade"
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Position = UDim2.fromScale(0, 0)
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = 10000
	overlay.Visible = false
	overlay.Parent = screenGui

	activeBlackOverlay = overlay
	return overlay
end

local function cancelBlackTween()
	if activeBlackTween then
		activeBlackTween:Cancel()
		activeBlackTween = nil
	end
end

function ScreenEffects.FadeToBlack(duration: number?): boolean
	local overlay = getBlackOverlay()
	if not overlay then
		return false
	end

	cancelBlackTween()
	overlay.Visible = true
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)

	local resolvedDuration = math.max(tonumber(duration) or 0.25, 0)
	if resolvedDuration <= 0 then
		overlay.BackgroundTransparency = 0
		return true
	end

	activeBlackTween = TweenService:Create(
		overlay,
		TweenInfo.new(resolvedDuration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ BackgroundTransparency = 0 }
	)
	activeBlackTween:Play()
	return true
end

function ScreenEffects.FadeFromBlack(duration: number?): boolean
	local overlay = getBlackOverlay()
	if not overlay then
		return false
	end

	cancelBlackTween()
	local resolvedDuration = math.max(tonumber(duration) or 0.25, 0)
	if resolvedDuration <= 0 then
		overlay.BackgroundTransparency = 1
		overlay.Visible = false
		return true
	end

	overlay.Visible = true
	activeBlackTween = TweenService:Create(
		overlay,
		TweenInfo.new(resolvedDuration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ BackgroundTransparency = 1 }
	)
	local tween = activeBlackTween
	tween:Play()
	tween.Completed:Once(function(playbackState)
		if activeBlackTween == tween then
			activeBlackTween = nil
		end
		if playbackState == Enum.PlaybackState.Completed and overlay.Parent and overlay.BackgroundTransparency >= 1 then
			overlay.Visible = false
		end
	end)
	return true
end

function ScreenEffects.HoldBlack(): boolean
	local overlay = getBlackOverlay()
	if not overlay then
		return false
	end

	cancelBlackTween()
	overlay.Visible = true
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0
	return true
end

function ScreenEffects.IsBlack(threshold: number?): boolean
	local overlay = activeBlackOverlay
	if not (overlay and overlay.Parent) then
		local screenGui = getScreenGui()
		local existing = screenGui and screenGui:FindFirstChild("BlackFade")
		overlay = if existing and existing:IsA("Frame") then existing else nil
		activeBlackOverlay = overlay
	end
	if not (overlay and overlay.Visible) then
		return false
	end

	local resolvedThreshold = math.clamp(tonumber(threshold) or 0.01, 0, 1)
	return overlay.BackgroundTransparency <= resolvedThreshold
end

function ScreenEffects.ClearBlack(duration: number?): boolean
	if typeof(duration) == "number" and duration > 0 then
		local overlay = activeBlackOverlay
		if not (overlay and overlay.Parent) then
			local screenGui = getScreenGui()
			local existing = screenGui and screenGui:FindFirstChild("BlackFade")
			if existing and existing:IsA("Frame") then
				activeBlackOverlay = existing
			else
				return false
			end
		end
		return ScreenEffects.FadeFromBlack(duration)
	end

	local overlay = activeBlackOverlay
	if not (overlay and overlay.Parent) then
		local screenGui = getScreenGui()
		local existing = screenGui and screenGui:FindFirstChild("BlackFade")
		overlay = if existing and existing:IsA("Frame") then existing else nil
		activeBlackOverlay = overlay
	end
	if not overlay then
		return false
	end

	cancelBlackTween()
	overlay.BackgroundTransparency = 1
	overlay.Visible = false
	return true
end

function ScreenEffects.FlashColor(color: Color3?, duration: number, initialTransparency: number?)
	duration = math.max(tonumber(duration) or 0.35, 0.1)
	initialTransparency = math.clamp(tonumber(initialTransparency) or 0, 0, 1)

	local vignette = getVignette()
	if not vignette then
		return
	end

	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end
	if activeFadeDelay then
		task.cancel(activeFadeDelay)
		activeFadeDelay = nil
	end

	vignette.Visible = true
	vignette.ImageColor3 = if typeof(color) == "Color3" then color else Color3.fromRGB(0, 0, 0)

	activeTween = TweenService:Create(vignette, TweenInfo.new(0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
		ImageTransparency = initialTransparency,
	})
	activeTween:Play()

	activeFadeDelay = task.delay(0.1, function()
		activeFadeDelay = nil
		activeTween = TweenService:Create(vignette, TweenInfo.new(math.max(duration - 0.1, 0.01), Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
			ImageTransparency = 1,
		})
		activeTween:Play()
	end)
end

function ScreenEffects.ImpactFrames(frames: number?, color: Color3?)
	local resolvedFrames = math.max(math.floor(tonumber(frames) or 1), 1)
	local correction = Instance.new("ColorCorrectionEffect")
	correction.TintColor = if typeof(color) == "Color3" then color else Color3.new(1, 1, 1)
	correction.Contrast = 0
	correction.Saturation = -1
	correction.Parent = Lighting

	for _ = 1, resolvedFrames do
		correction.Contrast = 100
		task.wait(1 / 50)

		correction.Contrast = -100
		task.wait(1 / 25)
	end

	correction:Destroy()
end

function ScreenEffects.FlashDark(duration: number, initialTransparency: number?)
	ScreenEffects.FlashColor(Color3.fromRGB(0, 0, 0), duration, initialTransparency)
end

function ScreenEffects.FlashBlack(duration: number, initialTransparency: number?)
	ScreenEffects.FlashDark(duration, initialTransparency)
end

return ScreenEffects
