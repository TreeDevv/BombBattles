local TweenService = game:GetService("TweenService")

local TutorialTextGui = {}

local gui: ScreenGui? = nil
local frame: Frame? = nil
local label: TextLabel? = nil
local labelStroke: UIStroke? = nil

function TutorialTextGui.Init(playerGui: PlayerGui)
	if gui then
		return
	end

	gui = Instance.new("ScreenGui")
	gui.Name = "TutorialGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui:SetAttribute("KeepEnabledDuringHatch", true)
	gui.Parent = playerGui

	frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(0.7, 0.1)
	frame.Position = UDim2.fromScale(0.15, 0.08)
	frame.BackgroundTransparency = 1
	frame.ZIndex = 100
	frame.Parent = gui

	label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.Text = ""
	label.TextTransparency = 1
	label.ZIndex = 101
	label.Parent = frame

	labelStroke = Instance.new("UIStroke")
	labelStroke.Name = "NOSCALE"
	labelStroke.Color = Color3.new(0, 0, 0)
	labelStroke.Thickness = 1.5
	labelStroke.Transparency = 1
	labelStroke.Parent = label
end

function TutorialTextGui.SetText(text: string)
	if not label then
		return
	end

	label.Text = text

	if label.TextTransparency > 0 then
		TweenService:Create(label, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			TextTransparency = 0,
		}):Play()
	else
		label.TextTransparency = 0
	end

	if labelStroke then
		if labelStroke.Transparency > 0.2 then
			TweenService:Create(labelStroke, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Transparency = 0.2,
			}):Play()
		else
			labelStroke.Transparency = 0.2
		end
	end
end

function TutorialTextGui.HideText()
	if not label then
		return
	end

	TweenService:Create(label, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextTransparency = 1,
	}):Play()

	if labelStroke then
		TweenService:Create(labelStroke, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1,
		}):Play()
	end
end

return TutorialTextGui
