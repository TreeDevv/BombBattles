local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local WorldTextEffect = {}

local DEFAULT_LIFETIME = 1
local DEFAULT_MAX_ACTIVE = 80
local DEFAULT_MAX_DISTANCE = 300
local FINAL_SIZE_SCALE = 0.5
local START_SIZE_SCALE = 0.2
local POP_SECONDS = 0.22
local TEXT_WHIPS_FOLDER_PATH = { "Assets", "TextWhips" }
local activeAnchors = {}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteVector3(value: any): boolean
	return typeof(value) == "Vector3"
		and isFiniteNumber(value.X)
		and isFiniteNumber(value.Y)
		and isFiniteNumber(value.Z)
end

local function isColor3(value: any): boolean
	return typeof(value) == "Color3"
end

local function playTween(instance: Instance, tweenInfo: TweenInfo, goals)
	local ok, tween = pcall(function()
		return TweenService:Create(instance, tweenInfo, goals)
	end)
	if ok then
		tween:Play()
	end
end

local function getTextWhipsFolder(): Instance?
	local current: Instance? = ReplicatedStorage
	for _, childName in ipairs(TEXT_WHIPS_FOLDER_PATH) do
		current = if current then current:FindFirstChild(childName) else nil
	end
	return current
end

local function getTemplate(templateName: string): Instance?
	local folder = getTextWhipsFolder()
	local template = folder and folder:FindFirstChild(templateName)
	if not template then
		warn(("[WorldTextEffect] Missing TextWhip template %q"):format(templateName))
	end
	return template
end

local function scaleUDim2(value: UDim2, scale: number): UDim2
	return UDim2.new(
		value.X.Scale * scale,
		value.X.Offset * scale,
		value.Y.Scale * scale,
		value.Y.Offset * scale
	)
end

local function sanitizeBasePart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
end

local function prepareClone(clone: Instance, position: Vector3)
	if clone:IsA("BasePart") then
		sanitizeBasePart(clone)
		clone.CFrame = CFrame.new(position)
	elseif clone:IsA("Model") then
		clone:PivotTo(CFrame.new(position))
	end

	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			sanitizeBasePart(descendant)
		elseif descendant:IsA("BaseScript") then
			descendant.Disabled = true
		end
	end
end

local function getBillboards(root: Instance): { BillboardGui }
	local billboards = {}
	if root:IsA("BillboardGui") then
		table.insert(billboards, root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BillboardGui") then
			table.insert(billboards, descendant)
		end
	end
	return billboards
end

local function applyDynamicText(root: Instance, descriptor)
	local text = descriptor.text
	if typeof(text) ~= "string" and typeof(text) ~= "number" then
		return
	end

	local textValue = tostring(text)
	local labelName = if typeof(descriptor.textLabelName) == "string" and descriptor.textLabelName ~= ""
		then descriptor.textLabelName
		else "Value"

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
			if descendant.Name ~= labelName then
				continue
			end

			descendant.Text = textValue
			if isColor3(descriptor.textColor) then
				descendant.TextColor3 = descriptor.textColor
			end
			if isColor3(descriptor.textStrokeColor) then
				descendant.TextStrokeColor3 = descriptor.textStrokeColor
			end
			if isFiniteNumber(descriptor.textStrokeTransparency) then
				descendant.TextStrokeTransparency = math.clamp(descriptor.textStrokeTransparency, 0, 1)
			end
		elseif descendant:IsA("UIStroke") then
			if isColor3(descriptor.strokeColor) then
				descendant.Color = descriptor.strokeColor
			end
			if isFiniteNumber(descriptor.strokeTransparency) then
				descendant.Transparency = math.clamp(descriptor.strokeTransparency, 0, 1)
			end
		end
	end
end

local function animateBillboards(root: Instance, lifetime: number, maxDistance: number?, sizeScale: number?)
	local popTween = TweenInfo.new(math.min(POP_SECONDS, lifetime * 0.4), Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local fadeDelay = math.max(lifetime * 0.45, 0)
	local fadeSeconds = math.max(lifetime - fadeDelay, 0.05)
	local fadeTween = TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local resolvedSizeScale = if isFiniteNumber(sizeScale) then math.clamp(sizeScale, 0.35, 2.5) else 1

	for _, billboard in ipairs(getBillboards(root)) do
		local authoredSize = billboard.Size
		local finalSize = scaleUDim2(authoredSize, FINAL_SIZE_SCALE * resolvedSizeScale)
		billboard.AlwaysOnTop = true
		billboard.MaxDistance = maxDistance or DEFAULT_MAX_DISTANCE
		billboard.Size = scaleUDim2(finalSize, START_SIZE_SCALE)
		playTween(billboard, popTween, {
			Size = finalSize,
		})
	end

	task.delay(fadeDelay, function()
		if not root.Parent then
			return
		end

		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
				playTween(descendant, fadeTween, {
					BackgroundTransparency = 1,
					ImageTransparency = 1,
				})
			elseif descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
				playTween(descendant, fadeTween, {
					BackgroundTransparency = 1,
					TextStrokeTransparency = 1,
					TextTransparency = 1,
				})
			elseif descendant:IsA("GuiObject") then
				playTween(descendant, fadeTween, {
					BackgroundTransparency = 1,
				})
			elseif descendant:IsA("UIStroke") then
				playTween(descendant, fadeTween, {
					Transparency = 1,
				})
			end
		end
	end)
end

local function removeActive(anchor: Instance)
	local index = table.find(activeAnchors, anchor)
	if index then
		table.remove(activeAnchors, index)
	end
end

local function destroyAnchor(anchor: Instance)
	removeActive(anchor)
	if anchor.Parent then
		pcall(function()
			anchor:Destroy()
		end)
	end
end

local function pruneActive(maxActive: number)
	while #activeAnchors >= maxActive do
		local oldest = table.remove(activeAnchors, 1)
		if oldest and oldest.Parent then
			pcall(function()
				oldest:Destroy()
			end)
		end
	end
end

local function tweenAnchor(anchor: Instance, fromPosition: Vector3, toPosition: Vector3, lifetime: number)
	local tweenInfo = TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if anchor:IsA("BasePart") then
		playTween(anchor, tweenInfo, {
			CFrame = CFrame.new(toPosition),
		})
	elseif anchor:IsA("Model") then
		local driver = Instance.new("CFrameValue")
		driver.Value = CFrame.new(fromPosition)
		driver.Parent = anchor
		local connection = driver:GetPropertyChangedSignal("Value"):Connect(function()
			if anchor.Parent then
				anchor:PivotTo(driver.Value)
			end
		end)
		local tween = TweenService:Create(driver, tweenInfo, {
			Value = CFrame.new(toPosition),
		})
		tween.Completed:Connect(function()
			connection:Disconnect()
			driver:Destroy()
		end)
		tween:Play()
	end
end

function WorldTextEffect.Play(parent: Instance, descriptor)
	if not parent or not parent.Parent or typeof(descriptor) ~= "table" then
		return nil
	end

	local templateName = descriptor.templateName
	local position = descriptor.position
	if typeof(templateName) ~= "string" or templateName == "" or not isFiniteVector3(position) then
		return nil
	end

	local lifetime = if isFiniteNumber(descriptor.lifetime) then math.clamp(descriptor.lifetime, 0.15, 5) else DEFAULT_LIFETIME
	local maxActive = if isFiniteNumber(descriptor.maxActive) then math.max(1, math.floor(descriptor.maxActive)) else DEFAULT_MAX_ACTIVE
	local lift = if isFiniteVector3(descriptor.lift) then descriptor.lift else Vector3.new(0, 2.4, 0)
	local maxDistance = if isFiniteNumber(descriptor.maxDistance) then descriptor.maxDistance else DEFAULT_MAX_DISTANCE
	local template = getTemplate(templateName)
	if not template then
		return nil
	end

	pruneActive(maxActive)

	local anchor = template:Clone()
	anchor.Name = "WorldText_" .. templateName
	prepareClone(anchor, position)
	applyDynamicText(anchor, descriptor)
	anchor.Parent = parent
	table.insert(activeAnchors, anchor)

	tweenAnchor(anchor, position, position + lift, lifetime)
	animateBillboards(anchor, lifetime, maxDistance, descriptor.sizeScale)

	task.delay(lifetime + 0.05, function()
		destroyAnchor(anchor)
	end)

	return anchor
end

function WorldTextEffect.Clear()
	for _, anchor in ipairs(table.clone(activeAnchors)) do
		destroyAnchor(anchor)
	end
	table.clear(activeAnchors)
end

return WorldTextEffect
