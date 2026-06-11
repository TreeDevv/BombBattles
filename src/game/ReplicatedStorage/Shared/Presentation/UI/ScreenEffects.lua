local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ScreenEffects = {}

local activeVignette: ImageLabel? = nil
local activeTween: Tween? = nil
local activeFadeDelay: any? = nil

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

function ScreenEffects.FlashDark(duration: number, initialTransparency: number?)
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
	vignette.ImageColor3 = Color3.fromRGB(0, 0, 0)

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

function ScreenEffects.FlashBlack(duration: number, initialTransparency: number?)
	ScreenEffects.FlashDark(duration, initialTransparency)
end

return ScreenEffects
