local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local ReplayOverlay = {}

function ReplayOverlay.Create(payload, options)
	options = options or {}
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	local overlayName = options.overlayName or "_KillReplayOverlay"
	local localReplayAttribute = options.localReplayAttribute or "BombBattlesLocalReplay"
	local existing = playerGui:FindFirstChild(overlayName)
	if existing and existing:GetAttribute(localReplayAttribute) == true then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = overlayName
	gui:SetAttribute(localReplayAttribute, true)
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Bar"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.fromScale(0.5, 0)
	frame.Size = UDim2.new(1, 0, 0, 94)
	frame.BackgroundColor3 = Color3.fromRGB(12, 12, 14)
	frame.BackgroundTransparency = 0.18
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local getPlayerDisplayName = options.getPlayerDisplayName
	local isFiniteNumber = options.isFiniteNumber or function(value)
		return typeof(value) == "number" and value == value and math.abs(value) < math.huge
	end
	local titleText = if payload.type == "POTGReplay"
		then "PLAY OF THE GAME"
		else "KILLED BY: " .. (if getPlayerDisplayName then getPlayerDisplayName(payload.killerUserId) else tostring(payload.killerUserId))

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 24, 0, 14)
	title.Size = UDim2.new(1, -48, 0, 36)
	title.Font = Enum.Font.GothamBold
	title.Text = titleText
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 24
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Parent = frame

	local sourceText = ""
	if payload.type == "POTGReplay" then
		sourceText = if getPlayerDisplayName then getPlayerDisplayName(payload.playerUserId) else tostring(payload.playerUserId)
		if typeof(payload.reason) == "string" and payload.reason ~= "" then
			sourceText ..= " / " .. payload.reason
		end
		if isFiniteNumber(payload.score) then
			sourceText ..= " / Score: " .. tostring(math.floor(payload.score + 0.5))
		end
	elseif typeof(payload.sourceType) == "string" and payload.sourceType ~= "" then
		sourceText = payload.sourceType
		if typeof(payload.sourceId) == "string" and payload.sourceId ~= "" then
			sourceText ..= " / " .. payload.sourceId
		end
	end

	local source = Instance.new("TextLabel")
	source.Name = "Source"
	source.BackgroundTransparency = 1
	source.Position = UDim2.new(0, 24, 0, 52)
	source.Size = UDim2.new(1, -48, 0, 24)
	source.Font = Enum.Font.Gotham
	source.Text = sourceText
	source.TextColor3 = Color3.fromRGB(220, 226, 235)
	source.TextSize = 16
	source.TextXAlignment = Enum.TextXAlignment.Left
	source.TextTruncate = Enum.TextTruncate.AtEnd
	source.Visible = sourceText ~= ""
	source.Parent = frame

	return gui
end

return ReplayOverlay
