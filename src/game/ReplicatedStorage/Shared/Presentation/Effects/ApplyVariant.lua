local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MutationConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("MutationConfig"))

local ApplyVariant = {}

local function getAssetsFolder(): Folder?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if assets and assets:IsA("Folder") then
		return assets
	end

	return nil
end

local function getParts(instance: Instance): { BasePart }
	local parts = {}

	if instance:IsA("BasePart") then
		table.insert(parts, instance)
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	return parts
end

local function applyTint(part: BasePart, tint: Color3)
	local h = select(1, Color3.toHSV(tint))
	local _, s, v = Color3.toHSV(part.Color)
	part.Color = Color3.fromHSV(h, math.max(s, 0.45), math.clamp(v + 0.1, 0, 1))
end

local function applyParticles(target: Instance, particleName: string)
	local assets = getAssetsFolder()
	if not assets then
		return
	end

	local particlesFolder = assets:FindFirstChild("Particles") or assets:FindFirstChild("MutationParticles")
	if not particlesFolder then
		return
	end

	local source = particlesFolder:FindFirstChild(particleName) or particlesFolder:FindFirstChild(particleName, true)
	if not source then
		return
	end

	local attachTarget = if target:IsA("BasePart") then target else target:FindFirstChildWhichIsA("BasePart", true)
	if not attachTarget then
		return
	end

	for _, child in ipairs(source:GetDescendants()) do
		if child:IsA("ParticleEmitter") or child:IsA("Trail") or child:IsA("Beam") or child:IsA("Attachment") then
			local clone = child:Clone()
			clone.Parent = attachTarget
		end
	end
end

function ApplyVariant.Apply(model: Instance, mutationInput)
	if typeof(model) ~= "Instance" then
		return
	end

	local names = MutationConfig.NormalizeNames(mutationInput)
	local primary = names[1]
	if not primary or primary == "Default" then
		return
	end

	local visual = MutationConfig.GetVisual(primary)
	if typeof(visual) ~= "table" then
		return
	end

	for _, part in ipairs(getParts(model)) do
		if visual.material then
			part.Material = visual.material
		end
		if visual.tint then
			applyTint(part, visual.tint)
		end
	end

	local particleName = visual.particle or primary
	if typeof(particleName) == "string" and particleName ~= "" then
		applyParticles(model, particleName)
	end

	if model:IsA("Model") or model:IsA("Tool") then
		model:SetAttribute("FruitVariant", primary)
	end
end

return ApplyVariant
