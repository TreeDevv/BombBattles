local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local CameraShaker = require(ReplicatedStorage.Shared.Camera.CameraShaker)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local RewardScreen = {}

local screenGui: ScreenGui? = nil
local mainFrame: Frame? = nil
local barFrame: Frame? = nil
local templatesRoot: Instance? = nil
local barFullSize: UDim2? = nil
local dismissToken = 0
local inputConnection: RBXScriptConnection? = nil
local cameraShake: any? = nil

local function getCameraShake()
	if cameraShake ~= nil then
		return cameraShake
	end

	local ok, shaker = pcall(function()
		return CameraShaker.new(Enum.RenderPriority.Camera.Value + 1, function(shakeCFrame: CFrame)
			local camera = workspace.CurrentCamera
			if not camera or camera.CameraType == Enum.CameraType.Scriptable then
				return
			end
			camera.CFrame *= shakeCFrame
		end)
	end)
	if ok then
		cameraShake = shaker
		cameraShake:Start()
	end
	return cameraShake
end

local function findTemplatesRoot(model: Model?): Instance?
	if not model then
		return nil
	end
	local modules = model:FindFirstChild("Modules")
	local moved = modules and modules:FindFirstChild("RewardScreenTemplates")
	if moved then
		return moved
	end
	local legacy = modules and modules:FindFirstChild("RewardScreen")
	return legacy
end

local function clearCards()
	local bar = barFrame
	if not bar then
		return
	end

	for _, child in ipairs(bar:GetChildren()) do
		if child:IsA("GuiObject") and child.Name ~= "Template" and child.Name ~= "CashTemplate" and child.Name ~= "SpinTemplate" and child.Name ~= "PrizeTemplate" then
			child:Destroy()
		end
	end
end

local function getTemplate(name: string): GuiObject?
	local root = templatesRoot
	local candidate = root and root:FindFirstChild(name)
	if candidate and candidate:IsA("GuiObject") then
		return candidate
	end
	local bar = barFrame
	candidate = bar and bar:FindFirstChild(name)
	return if candidate and candidate:IsA("GuiObject") then candidate else nil
end

local function setText(root: Instance, name: string, value: string)
	local label = root:FindFirstChild(name, true)
	if label and label:IsA("TextLabel") then
		label.Text = value
	end
end

local function setupCard(card: GuiObject, data)
	card.Visible = true
	card.Name = tostring(data.kind or "Reward") .. "Reward"
	setText(card, "Header", tostring(data.header or data.label or "Reward"))
	setText(card, "Subheader", tostring(data.subheader or ""))
	setText(card, "Amount", tostring(data.amountText or ""))
	setText(card, "Value", tostring(data.amountText or ""))

	local image = data.imageId
	if typeof(image) == "string" and image ~= "" then
		local icon = card:FindFirstChild("Icon", true)
		if icon and icon:IsA("ImageLabel") then
			icon.Image = image
		end
	end

	local scale = card:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Scale = 0.72
	scale.Parent = card
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
end

local function makeEntries(rewards: { any }): { any }
	local cash = 0
	local spins = 0
	local entries = {}

	for _, reward in ipairs(rewards) do
		if typeof(reward) ~= "table" then
			continue
		end
		if reward.type == "cash" then
			cash += math.max(0, math.floor(tonumber(reward.amount) or 0))
		elseif reward.type == "spins" then
			spins += math.max(0, math.floor(tonumber(reward.amount) or 0))
		else
			table.insert(entries, {
				kind = if reward.type == "crateToken" or reward.type == "crateRoll" then "crate" else "prize",
				header = tostring(reward.label or reward.id or "Prize"),
				subheader = tostring(reward.category or "Reward"),
				amountText = if reward.amount then ("x%d"):format(math.max(1, math.floor(tonumber(reward.amount) or 1))) else "",
				imageId = reward.imageId,
			})
		end
	end

	if cash > 0 then
		table.insert(entries, 1, {
			kind = "cash",
			header = "Coins",
			subheader = "Wheel Reward",
			amountText = tostring(cash),
		})
	end
	if spins > 0 then
		table.insert(entries, {
			kind = "spin",
			header = "Bonus Spins",
			subheader = "Wheel Reward",
			amountText = tostring(spins),
		})
	end

	return entries
end

function RewardScreen.Init(model: Model?, guiTemplate: ScreenGui?)
	templatesRoot = findTemplatesRoot(model)

	if screenGui and screenGui.Parent then
		return
	end
	if not guiTemplate then
		return
	end

	screenGui = guiTemplate:Clone()
	screenGui.Name = "SpinWheelRewardGui"
	screenGui.Enabled = false
	screenGui.Parent = PlayerGui

	mainFrame = screenGui:FindFirstChild("Main", true) :: Frame?
	barFrame = mainFrame and mainFrame:FindFirstChild("Bar", true) :: Frame?
	if barFrame then
		barFullSize = barFrame.Size
	end
end

function RewardScreen.Show(rewards: { any })
	if not (screenGui and mainFrame and barFrame) then
		return
	end

	local entries = makeEntries(rewards)
	if #entries == 0 then
		return
	end

	dismissToken += 1
	local token = dismissToken
	clearCards()

	screenGui.Enabled = true
	mainFrame.Visible = true
	barFrame.ClipsDescendants = true
	barFrame.Size = UDim2.fromScale(0, barFullSize and barFullSize.Y.Scale or barFrame.Size.Y.Scale)

	local layoutOrder = 0
	for _, entry in ipairs(entries) do
		local templateName = if entry.kind == "cash" then "CashTemplate" elseif entry.kind == "spin" then "SpinTemplate" elseif entry.kind == "crate" then "PrizeTemplate" else "Template"
		local template = getTemplate(templateName) or getTemplate("Template")
		if template then
			layoutOrder += 1
			local card = template:Clone()
			card.LayoutOrder = layoutOrder
			card.Parent = barFrame
			setupCard(card, entry)
		end
	end

	local fullSize = barFullSize or barFrame.Size
	TweenService:Create(barFrame, TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Size = fullSize,
	}):Play()

	local unlock = templatesRoot and templatesRoot:FindFirstChild("Unlock")
	if unlock and unlock:IsA("Sound") then
		local sound = unlock:Clone()
		sound.Parent = screenGui
		sound:Play()
		sound.Ended:Once(function()
			sound:Destroy()
		end)
	end

	local shaker = getCameraShake()
	if shaker then
		local ok, preset = pcall(function()
			return CameraShaker.Presets.Bump
		end)
		if ok then
			shaker:Shake(preset)
		end
	end

	local dismissReadyAt = os.clock() + 0.5
	if inputConnection then
		inputConnection:Disconnect()
	end
	inputConnection = UserInputService.InputBegan:Connect(function(_, gameProcessed)
		if gameProcessed or os.clock() < dismissReadyAt then
			return
		end
		RewardScreen.Hide(token)
	end)

	task.delay(8, function()
		RewardScreen.Hide(token)
	end)
end

function RewardScreen.Hide(token: number?)
	if token and token ~= dismissToken then
		return
	end
	if inputConnection then
		inputConnection:Disconnect()
		inputConnection = nil
	end
	local gui = screenGui
	local bar = barFrame
	if not (gui and bar) then
		return
	end
	local targetSize = UDim2.fromScale(0, (barFullSize or bar.Size).Y.Scale)
	local tween = TweenService:Create(bar, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = targetSize,
	})
	tween.Completed:Once(function()
		if gui then
			gui.Enabled = false
		end
		clearCards()
	end)
	tween:Play()
end

return RewardScreen
