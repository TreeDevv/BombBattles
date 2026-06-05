--[[
	Octree Meshing & Greedy Merging Module / Voxelizer by @LxckyDev

	This module subtracts a spherical part from target parts using octree
	subdivision, then uses greedy merging to combine adjacent remaining blocks.
]]

local Voxelizer = require(script.Voxelizer)
local ObjectCache = require(script.ObjectCache)

local VoxManager = {
	VoxelCache = nil,
	VoxelFolder = nil,
	DebrisSizeMultiplier = 0.3,
	GeneratedVoxelTag = nil,
	TerrainConfig = {
		CellSize = 8,
		CellHealth = 80,
		HealthAttribute = "DestructionHealth",
		DamageMultiplierAttribute = "DestructionDamageMultiplier",
		InnerRadius = 4,
		NearRadius = 10,
		InnerDamage = 100,
		NearDamageMax = 70,
		NearDamageMin = 35,
		OuterDamageMax = 25,
		OuterDamageMin = 8,
	},
	DebrisConfig = {
		SpeedMin = 22,
		SpeedMax = 42,
		Lifetime = 2,
		ClientSimulated = false,
		UseGraphicsQualitySampling = true,
		AutomaticQualityLevel = 5,
		MaxSamplingDivisor = 10,
	},
	TerrainDebugConfig = {
		Visualize = false,
		StudioOnly = true,
		FolderName = "DamageGridDebug",
		Transparency = 0.65,
		Inset = 0.08,
		HealthyColor = Color3.fromRGB(70, 230, 90),
		DamagedColor = Color3.fromRGB(255, 210, 60),
		CriticalColor = Color3.fromRGB(255, 80, 70),
	},
}

function VoxManager:_createVoxelCache()
	local template = Instance.new("Part")
	template.Anchored = true

	VoxManager.VoxelFolder = Instance.new("Folder")
	VoxManager.VoxelFolder.Name = "VoxelCache"
	VoxManager.VoxelFolder.Parent = workspace

	VoxManager.VoxelCache = ObjectCache.new(template, 10000, VoxManager.VoxelFolder)
	VoxManager.VoxelCache:SetExpandAmount(100)

	template:Destroy()
end

function VoxManager:voxelize(
	sphereHitbox: Part,
	minimumVoxelSize: number,
	finalVoxelSize: number,
	randomColor: boolean,
	debris: boolean,
	debrisAmount: number,
	ignore: { Instance }?,
	include: { Instance }?,
	outputFolder: Instance?,
	options
)
	assert(sphereHitbox, "Hitbox provided was nil.")
	if sphereHitbox.Shape ~= Enum.PartType.Ball then
		error('Hitbox provided was not of shape "Ball"')
	end

	if not VoxManager.VoxelCache then
		VoxManager:_createVoxelCache()
	end

	minimumVoxelSize = minimumVoxelSize or 2
	finalVoxelSize = finalVoxelSize or minimumVoxelSize
	debrisAmount = debrisAmount or 1
	ignore = ignore or {}

	if randomColor == nil then
		randomColor = false
	end
	if debris == nil then
		debris = true
	end

	return Voxelizer.subtractHitbox(
		sphereHitbox,
		minimumVoxelSize,
		finalVoxelSize,
		randomColor,
		debris,
		debrisAmount,
		ignore,
		VoxManager.VoxelCache,
		VoxManager.DebrisSizeMultiplier,
		VoxManager.DebrisConfig,
		VoxManager.GeneratedVoxelTag,
		VoxManager.TerrainConfig,
		include,
		outputFolder,
		options
	)
end

function VoxManager:voxelizePosition(
	position: Vector3,
	radius: number,
	minimumVoxelSize: number,
	finalVoxelSize: number,
	randomColor: boolean,
	debris: boolean,
	debrisAmount: number,
	ignore: { Instance }?,
	include: { Instance }?,
	outputFolder: Instance?,
	options
)
	assert(position, "Please enter a valid position.")
	if typeof(position) ~= "Vector3" then
		error("Position must be a Vector3")
	end

	if not VoxManager.VoxelCache then
		VoxManager:_createVoxelCache()
	end

	minimumVoxelSize = minimumVoxelSize or 2
	finalVoxelSize = finalVoxelSize or minimumVoxelSize
	debrisAmount = debrisAmount or 1
	ignore = ignore or {}

	if randomColor == nil then
		randomColor = false
	end
	if debris == nil then
		debris = true
	end

	local hitbox = Instance.new("Part")
	hitbox.Name = "VoxManagerHitbox"
	hitbox.Shape = Enum.PartType.Ball
	hitbox.Position = position
	hitbox.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanQuery = false
	hitbox.Transparency = 1
	hitbox.Parent = workspace

	return Voxelizer.subtractHitbox(
		hitbox,
		minimumVoxelSize,
		finalVoxelSize,
		randomColor,
		debris,
		debrisAmount,
		ignore,
		VoxManager.VoxelCache,
		VoxManager.DebrisSizeMultiplier,
		VoxManager.DebrisConfig,
		VoxManager.GeneratedVoxelTag,
		VoxManager.TerrainConfig,
		include,
		outputFolder,
		options
	)
end

function VoxManager:setDebrisSize(multiplier: number)
	assert(multiplier, "Debris multiplier needs to be a valid number.")
	if multiplier <= 0 then
		error("Debris multiplier needs to be greater than 0.")
	end

	VoxManager.DebrisSizeMultiplier = multiplier
end

function VoxManager:setDebrisConfig(config)
	if typeof(config) ~= "table" then
		return
	end

	local fields = {
		SpeedMin = "DebrisSpeedMin",
		SpeedMax = "DebrisSpeedMax",
		Lifetime = "DebrisLifetime",
		AutomaticQualityLevel = "DebrisAutomaticQualityLevel",
		MaxSamplingDivisor = "DebrisMaxSamplingDivisor",
	}

	for targetName, sourceName in pairs(fields) do
		local value = config[sourceName] or config[targetName]
		if typeof(value) == "number" then
			VoxManager.DebrisConfig[targetName] = value
		end
	end

	if typeof(config.ClientSimulatedDebris) == "boolean" then
		VoxManager.DebrisConfig.ClientSimulated = config.ClientSimulatedDebris
	elseif typeof(config.ClientSimulated) == "boolean" then
		VoxManager.DebrisConfig.ClientSimulated = config.ClientSimulated
	end

	if typeof(config.DebrisUseGraphicsQualitySampling) == "boolean" then
		VoxManager.DebrisConfig.UseGraphicsQualitySampling = config.DebrisUseGraphicsQualitySampling
	elseif typeof(config.UseGraphicsQualitySampling) == "boolean" then
		VoxManager.DebrisConfig.UseGraphicsQualitySampling = config.UseGraphicsQualitySampling
	end
end

function VoxManager:setGeneratedVoxelTag(tagName: string?)
	if typeof(tagName) == "string" and tagName ~= "" then
		VoxManager.GeneratedVoxelTag = tagName
	else
		VoxManager.GeneratedVoxelTag = nil
	end
end

function VoxManager:setTerrainConfig(config)
	if typeof(config) ~= "table" then
		return
	end

	local fields = {
		CellSize = "TerrainCellSize",
		CellHealth = "TerrainCellHealth",
		InnerRadius = "TerrainInnerRadius",
		NearRadius = "TerrainNearRadius",
		InnerDamage = "TerrainInnerDamage",
		NearDamageMax = "TerrainNearDamageMax",
		NearDamageMin = "TerrainNearDamageMin",
		OuterDamageMax = "TerrainOuterDamageMax",
		OuterDamageMin = "TerrainOuterDamageMin",
	}

	for targetName, sourceName in pairs(fields) do
		local value = config[sourceName] or config[targetName]
		if typeof(value) == "number" then
			VoxManager.TerrainConfig[targetName] = value
		end
	end

	local healthAttribute = config.TerrainHealthAttribute or config.HealthAttribute
	if typeof(healthAttribute) == "string" and healthAttribute ~= "" then
		VoxManager.TerrainConfig.HealthAttribute = healthAttribute
	end

	local damageMultiplierAttribute = config.TerrainDamageMultiplierAttribute or config.DamageMultiplierAttribute
	if typeof(damageMultiplierAttribute) == "string" and damageMultiplierAttribute ~= "" then
		VoxManager.TerrainConfig.DamageMultiplierAttribute = damageMultiplierAttribute
	end
end

function VoxManager:setTerrainDebugConfig(config)
	if typeof(config) ~= "table" then
		return
	end

	if typeof(config.DebugVisualizeDamageGrid) == "boolean" then
		VoxManager.TerrainDebugConfig.Visualize = config.DebugVisualizeDamageGrid
	end
	if typeof(config.DebugDamageGridStudioOnly) == "boolean" then
		VoxManager.TerrainDebugConfig.StudioOnly = config.DebugDamageGridStudioOnly
	end
	if typeof(config.DebugDamageGridFolderName) == "string" and config.DebugDamageGridFolderName ~= "" then
		VoxManager.TerrainDebugConfig.FolderName = config.DebugDamageGridFolderName
	end
	if typeof(config.DebugDamageGridTransparency) == "number" then
		VoxManager.TerrainDebugConfig.Transparency = math.clamp(config.DebugDamageGridTransparency, 0, 1)
	end
	if typeof(config.DebugDamageGridInset) == "number" then
		VoxManager.TerrainDebugConfig.Inset = math.max(config.DebugDamageGridInset, 0)
	end
	if typeof(config.DebugDamageGridHealthyColor) == "Color3" then
		VoxManager.TerrainDebugConfig.HealthyColor = config.DebugDamageGridHealthyColor
	end
	if typeof(config.DebugDamageGridDamagedColor) == "Color3" then
		VoxManager.TerrainDebugConfig.DamagedColor = config.DebugDamageGridDamagedColor
	end
	if typeof(config.DebugDamageGridCriticalColor) == "Color3" then
		VoxManager.TerrainDebugConfig.CriticalColor = config.DebugDamageGridCriticalColor
	end

	Voxelizer.setTerrainDebugConfig(VoxManager.TerrainDebugConfig)
end

function VoxManager:cleanupVoxelCache()
	if VoxManager.VoxelCache then
		VoxManager.VoxelCache:Destroy()
		VoxManager.VoxelCache = nil
	end
	if VoxManager.VoxelFolder then
		VoxManager.VoxelFolder:Destroy()
		VoxManager.VoxelFolder = nil
	end
end

function VoxManager:resetTerrainState()
	Voxelizer.clearTerrainDebugVisuals()

	local voxelizerTerrainCells = Voxelizer.TerrainCells
	if voxelizerTerrainCells then
		table.clear(voxelizerTerrainCells)
	end
end

function VoxManager:cleanup()
	VoxManager:resetTerrainState()
	VoxManager:cleanupVoxelCache()

	local currentVoxels = workspace:FindFirstChild("CurrentVoxels")
	if currentVoxels then
		currentVoxels:Destroy()
	end

	local voxelDebris = workspace:FindFirstChild("VoxelDebris")
	if voxelDebris then
		voxelDebris:Destroy()
	end
end

return VoxManager
