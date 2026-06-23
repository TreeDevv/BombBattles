local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AudioSettings = require(ReplicatedStorage.Shared.Audio.AudioSettings)
local Spring = require(ReplicatedStorage.Shared.Common.Spring)

local TOOL_CONNECTION: RBXScriptConnection? = nil

local function getCamera(): Camera?
	return workspace.CurrentCamera
end

local function getBlurEffect(): BlurEffect
	local existing = Lighting:FindFirstChild("TemplateUIBlur")
	if existing and existing:IsA("BlurEffect") then
		return existing
	end

	local blur = Instance.new("BlurEffect")
	blur.Name = "TemplateUIBlur"
	blur.Size = 0
	blur.Enabled = true
	blur.Parent = Lighting
	return blur
end

local function playOptionalSound(container: Instance, soundName: string)
	local sound = container:FindFirstChild(soundName)
	if sound and sound:IsA("Sound") then
		sound.SoundGroup = AudioSettings.GetGroup("UI")
		sound:Play()
	end
end

local function setUpUIStrokes()
	local camera = getCamera()
	if not camera then
		return
	end

	local baseSize = 800
	local attribute = "initial"
	local strokes = {}
	local playerGui = Players.LocalPlayer.PlayerGui
	local frames = playerGui:FindFirstChild("Frames")
	local bundlesFrame = frames and frames:FindFirstChild("Bundles")

	for _, container in { playerGui, Players.LocalPlayer.PlayerScripts } do
		for _, item in container:GetDescendants() do
			if item:IsA("UIStroke") and not (bundlesFrame and item:IsDescendantOf(bundlesFrame)) then
				item:SetAttribute(attribute, item.Thickness)
				table.insert(strokes, item)
			end
		end
	end

	local function update()
		for _, stroke in strokes do
			local initial = stroke:GetAttribute(attribute)
			if typeof(initial) == "number" then
				stroke.Thickness = initial * camera.ViewportSize.Y / baseSize
			end
		end
	end

	update()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
end

local UIController = {}
UIController.ContainersOpen = {}

function UIController:OnStart()
	task.delay(1, setUpUIStrokes)
end

function UIController:CreateButton(button: GuiButton, activatedFn: () -> ())
	button.AutoButtonColor = false

	local uiScale = button:FindFirstChildWhichIsA("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = button
	end

	button.MouseEnter:Connect(function()
		Spring.target(uiScale, 0.65, 5, { Scale = 1.05 })
	end)

	button.MouseLeave:Connect(function()
		Spring.target(uiScale, 0.65, 5, { Scale = 1 })
	end)

	button.MouseButton1Down:Connect(function()
		Spring.target(uiScale, 0.65, 5, { Scale = 0.92 })
	end)

	button.MouseButton1Up:Connect(function()
		playOptionalSound(script, "Open")
		Spring.target(uiScale, 0.65, 5, { Scale = 1 })
	end)

	button.Activated:Connect(activatedFn)
end

function UIController:OpenContainer(container: ScreenGui)
	if not table.find(UIController.ContainersOpen, container) then
		table.insert(UIController.ContainersOpen, container)
	end

	local character = Players.LocalPlayer.Character
	if character then
		local humanoid = character:FindFirstChildWhichIsA("Humanoid")
		if humanoid then
			humanoid:UnequipTools()

			if TOOL_CONNECTION then
				TOOL_CONNECTION:Disconnect()
			end

			TOOL_CONNECTION = character.ChildAdded:Connect(function(child)
				if child:IsA("Tool") then
					humanoid:UnequipTools()
				end
			end)
		end
	end

	container.Enabled = true

	local blur = getBlurEffect()
	local camera = getCamera()
	Spring.target(blur, 1, 3, { Size = 25 })
	if camera then
		Spring.target(camera, 1, 3, { FieldOfView = 80 })
	end
end

function UIController:CloseContainer(container: ScreenGui)
	local index = table.find(UIController.ContainersOpen, container)
	if index then
		table.remove(UIController.ContainersOpen, index)
	end

	if TOOL_CONNECTION then
		TOOL_CONNECTION:Disconnect()
		TOOL_CONNECTION = nil
	end

	container.Enabled = false

	if #UIController.ContainersOpen > 0 then
		return
	end

	local blur = getBlurEffect()
	local camera = getCamera()
	if camera then
		Spring.target(camera, 1, 3, { FieldOfView = 70 })
	end
	Spring.target(blur, 1, 3, { Size = 0 })
end

return UIController
