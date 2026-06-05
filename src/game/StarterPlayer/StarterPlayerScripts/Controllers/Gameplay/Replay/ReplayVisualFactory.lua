local TweenService = game:GetService("TweenService")

local ReplayVisualFactory = {}

function ReplayVisualFactory.MakePart(name: string, size: Vector3, color: Color3, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Size = size
	part.Color = color
	if shape then
		part.Shape = shape
	end
	return part
end

function ReplayVisualFactory.SetPartVisible(part: BasePart, visible: boolean, transparency: number?)
	part.LocalTransparencyModifier = 0
	part.Transparency = if visible then (transparency or 0) else 1
end

function ReplayVisualFactory.SetPartRecordsVisible(records, visible: boolean)
	for _, record in ipairs(records or {}) do
		local part = record.part
		if part and part.Parent then
			ReplayVisualFactory.SetPartVisible(part, visible, record.transparency)
		end
	end
end

function ReplayVisualFactory.ScheduleDestroy(instance: Instance, lifetime: number)
	task.delay(lifetime, function()
		if instance.Parent then
			pcall(function()
				instance:Destroy()
			end)
		end
	end)
end

function ReplayVisualFactory.PlayTween(instance: Instance, tweenInfo: TweenInfo, goals)
	local ok, tween = pcall(function()
		return TweenService:Create(instance, tweenInfo, goals)
	end)
	if ok then
		tween:Play()
	end
end

function ReplayVisualFactory.CreateEffectAnchor(parent: Instance, position: Vector3, name: string): Part
	local anchor = ReplayVisualFactory.MakePart(name, Vector3.new(0.2, 0.2, 0.2), Color3.new(1, 1, 1), nil)
	anchor.Transparency = 1
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = parent
	return anchor
end

function ReplayVisualFactory.CreateFloatingText(
	parent: Instance,
	position: Vector3,
	text: string,
	color: Color3,
	lifetime: number?,
	defaultLifetime: number
)
	local resolvedLifetime = lifetime or defaultLifetime
	local anchor = ReplayVisualFactory.CreateEffectAnchor(parent, position, "ReplayTextMarker")

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Billboard"
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(190, 46)
	billboard.StudsOffset = Vector3.new(0, 2.8, 0)
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextColor3 = color
	label.TextSize = 20
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0.35
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = billboard

	ReplayVisualFactory.PlayTween(anchor, TweenInfo.new(resolvedLifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(position + Vector3.new(0, 2.4, 0)),
	})
	ReplayVisualFactory.PlayTween(label, TweenInfo.new(resolvedLifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	ReplayVisualFactory.ScheduleDestroy(anchor, resolvedLifetime + 0.05)
	return anchor
end

function ReplayVisualFactory.CreatePulseSphere(
	parent: Instance,
	position: Vector3,
	radius: number,
	color: Color3,
	lifetime: number?,
	defaultLifetime: number
)
	local resolvedLifetime = lifetime or defaultLifetime
	local sphere = ReplayVisualFactory.MakePart("ReplayPulseSphere", Vector3.new(0.7, 0.7, 0.7), color, Enum.PartType.Ball)
	sphere.Material = Enum.Material.Neon
	sphere.Transparency = 0.35
	sphere.CFrame = CFrame.new(position)
	sphere.Parent = parent

	local diameter = math.max(radius, 1) * 2
	ReplayVisualFactory.PlayTween(sphere, TweenInfo.new(resolvedLifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(diameter, diameter, diameter),
		Transparency = 1,
	})
	ReplayVisualFactory.ScheduleDestroy(sphere, resolvedLifetime + 0.05)
	return sphere
end

function ReplayVisualFactory.CreateRingMarker(
	parent: Instance,
	position: Vector3,
	radius: number,
	color: Color3,
	lifetime: number?,
	defaultLifetime: number
)
	local resolvedLifetime = lifetime or defaultLifetime
	local ring = ReplayVisualFactory.MakePart("ReplayRingMarker", Vector3.new(0.35, 0.08, 0.35), color, Enum.PartType.Cylinder)
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.22
	ring.CFrame = CFrame.new(position + Vector3.new(0, 0.08, 0))
	ring.Parent = parent

	local diameter = math.max(radius, 1) * 2
	ReplayVisualFactory.PlayTween(ring, TweenInfo.new(resolvedLifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(diameter, 0.08, diameter),
		Transparency = 1,
	})
	ReplayVisualFactory.ScheduleDestroy(ring, resolvedLifetime + 0.05)
	return ring
end

return table.freeze(ReplayVisualFactory)
