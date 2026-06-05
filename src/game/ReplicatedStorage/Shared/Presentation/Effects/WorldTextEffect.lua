local TweenService = game:GetService("TweenService")

local WorldTextEffect = {}

local DEFAULT_LIFETIME = 1
local DEFAULT_MAX_ACTIVE = 80
local DEFAULT_SIZE = UDim2.fromOffset(190, 46)
local DEFAULT_STUDS_OFFSET = Vector3.new(0, 2.8, 0)
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

local function isFiniteColor3(value: any): boolean
	return typeof(value) == "Color3"
		and isFiniteNumber(value.R)
		and isFiniteNumber(value.G)
		and isFiniteNumber(value.B)
end

local function playTween(instance: Instance, tweenInfo: TweenInfo, goals)
	local ok, tween = pcall(function()
		return TweenService:Create(instance, tweenInfo, goals)
	end)
	if ok then
		tween:Play()
	end
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

function WorldTextEffect.Play(parent: Instance, descriptor)
	if not parent or not parent.Parent or typeof(descriptor) ~= "table" then
		return nil
	end

	local text = descriptor.text
	local position = descriptor.position
	if typeof(text) ~= "string" or text == "" or not isFiniteVector3(position) then
		return nil
	end

	local lifetime = if isFiniteNumber(descriptor.lifetime) then math.clamp(descriptor.lifetime, 0.15, 5) else DEFAULT_LIFETIME
	local maxActive = if isFiniteNumber(descriptor.maxActive) then math.max(1, math.floor(descriptor.maxActive)) else DEFAULT_MAX_ACTIVE
	local color = if isFiniteColor3(descriptor.color) then descriptor.color else Color3.fromRGB(255, 255, 255)
	local strokeColor = if isFiniteColor3(descriptor.strokeColor) then descriptor.strokeColor else Color3.fromRGB(0, 0, 0)
	local textSize = if isFiniteNumber(descriptor.textSize) then math.clamp(descriptor.textSize, 10, 64) else 20
	local lift = if isFiniteVector3(descriptor.lift) then descriptor.lift else Vector3.new(0, 2.4, 0)
	local studsOffset = if isFiniteVector3(descriptor.studsOffset) then descriptor.studsOffset else DEFAULT_STUDS_OFFSET

	pruneActive(maxActive)

	local anchor = Instance.new("Part")
	anchor.Name = "WorldTextMarker"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = parent
	table.insert(activeAnchors, anchor)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Billboard"
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = if isFiniteNumber(descriptor.maxDistance) then descriptor.maxDistance else 300
	billboard.Size = DEFAULT_SIZE
	billboard.StudsOffset = studsOffset
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextColor3 = color
	label.TextSize = textSize
	label.TextStrokeColor3 = strokeColor
	label.TextStrokeTransparency = 0.35
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = billboard

	local scale = Instance.new("UIScale")
	scale.Scale = 0.78
	scale.Parent = label

	playTween(anchor, TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(position + lift),
	})
	playTween(scale, TweenInfo.new(math.min(lifetime * 0.35, 0.25), Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	})
	playTween(label, TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})

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
