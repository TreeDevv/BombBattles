local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Spring = require(ReplicatedStorage.Shared.Common.Spring)

local hatchGui = playerGui:FindFirstChild("Hatch")

local clickSound = playerGui:FindFirstChild("UIButtonClickSound")
if not clickSound then
	clickSound = Instance.new("Sound")
	clickSound.Name = "UIButtonClickSound"
	clickSound.SoundId = "rbxassetid://5852470908"
	clickSound.Volume = 0.6
	clickSound.Parent = playerGui
end

local function shouldPlayClick(button)
	if button.Name == "TapCatcher" and hatchGui and button:IsDescendantOf(hatchGui) then
		return false
	end

	return true
end

local function playClick()
	clickSound.TimePosition = 0
	clickSound:Play()
end

local function loadConnectionsFor(button)
	local normalSize = button.Size
	local factor = 1.07

	local hoverSize = UDim2.new(
		normalSize.X.Scale * factor,
		math.floor((normalSize.X.Offset * factor) + 0.5),
		normalSize.Y.Scale * factor,
		math.floor((normalSize.Y.Offset * factor) + 0.5)
	)

	local isHovering = false

	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			isHovering = true
			Spring.stop(button)
			Spring.target(button, 0.7, 6, { Size = hoverSize })
		end
	end)

	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			isHovering = false
			Spring.stop(button)
			Spring.target(button, 0.7, 6, { Size = normalSize })
		end
	end)

	button.MouseButton1Click:Connect(function()
		if shouldPlayClick(button) then
			playClick()
		end

		Spring.stop(button)
		Spring.target(button, 0.4, 5, { Size = normalSize })
		task.wait(0.1)

		if isHovering then
			Spring.target(button, 0.4, 5, { Size = hoverSize })
		end
	end)
end

for _, button in playerGui:GetDescendants() do
	if button:IsA("TextButton") or button:IsA("ImageButton") then
		loadConnectionsFor(button)
	end
end
