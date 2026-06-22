local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)

local BombImpactEffects = {}

local DEFAULT_DRILL_COLOR = Color3.fromRGB(255, 207, 84)

local function configureEffectPart(part: BasePart, position: Vector3, color: Color3, transparency: number)
	part.CFrame = CFrame.new(position)
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = transparency
	part.Parent = workspace
end

function BombImpactEffects.PlayImpact(position: Vector3)
	local part = Instance.new("Part")
	part.Name = "BombImpactEffect"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.45, 0.45, 0.45)
	configureEffectPart(part, position, BombConfig.PreviewColor, 0.15)

	local tween = TweenService:Create(part, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(3, 3, 3),
		Transparency = 1,
	})
	tween.Completed:Connect(function()
		part:Destroy()
	end)
	tween:Play()
end

function BombImpactEffects.PlayDrillPulse(position: Vector3, radius: number?, color: Color3?, duration: number?)
	local part = Instance.new("Part")
	part.Name = "DrillBombPulse"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.35, 0.35, 0.35)
	configureEffectPart(part, position, color or DEFAULT_DRILL_COLOR, 0.2)

	local finalRadius = math.max(radius or 4, 0.5)
	local tween = TweenService:Create(part, TweenInfo.new(duration or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(finalRadius, finalRadius, finalRadius),
		Transparency = 1,
	})
	tween.Completed:Connect(function()
		part:Destroy()
	end)
	tween:Play()
end

function BombImpactEffects.PlayDrillTrail(fromPosition: Vector3, toPosition: Vector3, radius: number?, color: Color3?)
	local delta = toPosition - fromPosition
	local distance = delta.Magnitude
	if distance <= 0.05 then
		BombImpactEffects.PlayDrillPulse(toPosition, radius, color, 0.12)
		return
	end

	local part = Instance.new("Part")
	part.Name = "DrillBombTrail"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(math.max(radius or 1.8, 0.2), distance, math.max(radius or 1.8, 0.2))
	configureEffectPart(part, fromPosition, color or DEFAULT_DRILL_COLOR, 0.58)
	part.CFrame = CFrame.lookAt(fromPosition + delta * 0.5, toPosition) * CFrame.Angles(math.pi / 2, 0, 0)

	local tween = TweenService:Create(part, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(part.Size.X * 1.6, part.Size.Y, part.Size.Z * 1.6),
		Transparency = 1,
	})
	tween.Completed:Connect(function()
		part:Destroy()
	end)
	tween:Play()
end

return table.freeze(BombImpactEffects)
