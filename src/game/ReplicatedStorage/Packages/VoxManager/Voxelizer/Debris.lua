local DebrisService = game:GetService("Debris")
local RunService = game:GetService("RunService")

local Debris = {}

local DEFAULT_CONFIG = {
	SpeedMin = 22,
	SpeedMax = 42,
	Lifetime = 2,
	ClientSimulated = false,
	UseGraphicsQualitySampling = true,
	AutomaticQualityLevel = 5,
	MaxSamplingDivisor = 10,
}

local MAX_RANDOM_SEED = 2147483647

local function getConfigValue(config, name: string)
	local value = if config then config[name] else nil
	return if typeof(value) == "number" then value else DEFAULT_CONFIG[name]
end

local function getDebrisFolder(parentFolder: Instance?): Folder
	if parentFolder and parentFolder:IsA("Folder") then
		return parentFolder
	end

	local debrisFolder = workspace:FindFirstChild("VoxelDebris")
	if not debrisFolder then
		debrisFolder = Instance.new("Folder")
		debrisFolder.Name = "VoxelDebris"
		debrisFolder.Parent = workspace
	end

	return debrisFolder
end

local function copyRemovedBlocks(removedBlocks)
	local blocks = table.create(#removedBlocks)
	for _, block in ipairs(removedBlocks) do
		table.insert(blocks, {
			center = block.center,
			size = block.size,
		})
	end

	return blocks
end

local function randomUnitVector(random: Random): Vector3
	local vector = Vector3.new(random:NextNumber() - 0.5, random:NextNumber() - 0.25, random:NextNumber() - 0.5)
	if vector.Magnitude < 0.05 then
		return Vector3.yAxis
	end
	return vector.Unit
end

local function getMaterialByName(materialName: any): Enum.Material
	if typeof(materialName) ~= "string" then
		return Enum.Material.Plastic
	end

	for _, material in ipairs(Enum.Material:GetEnumItems()) do
		if material.Name == materialName then
			return material
		end
	end

	return Enum.Material.Plastic
end

local function getManualGraphicsQualityLevel(savedQualityLevel): number?
	if typeof(savedQualityLevel) ~= "EnumItem" then
		return nil
	end

	local qualityLevel = string.match(savedQualityLevel.Name, "^QualityLevel(%d+)$")
	if not qualityLevel then
		return nil
	end

	return tonumber(qualityLevel)
end

local function getClientGraphicsQualityLevel(automaticQualityLevel: number): number
	local ok, savedQualityLevel = pcall(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel
	end)
	if not ok then
		return automaticQualityLevel
	end

	return getManualGraphicsQualityLevel(savedQualityLevel) or automaticQualityLevel
end

local function getSamplingDivisor(payload, options): number
	if not RunService:IsClient() then
		return 1
	end
	if typeof(options) == "table" and options.useGraphicsQualitySampling == false then
		return 1
	end
	if payload.useGraphicsQualitySampling ~= true then
		return 1
	end

	local automaticQualityLevel = math.clamp(
		if typeof(payload.automaticQualityLevel) == "number" then payload.automaticQualityLevel else DEFAULT_CONFIG.AutomaticQualityLevel,
		1,
		10
	)
	local maxSamplingDivisor = math.max(
		if typeof(payload.maxSamplingDivisor) == "number" then payload.maxSamplingDivisor else DEFAULT_CONFIG.MaxSamplingDivisor,
		1
	)
	local graphicsQuality = math.clamp(getClientGraphicsQualityLevel(automaticQualityLevel), 1, 10)

	return math.clamp(11 - graphicsQuality, 1, maxSamplingDivisor)
end

local function shouldSpawnBlock(seed: number, blockIndex: number, samplingDivisor: number): boolean
	if samplingDivisor <= 1 then
		return true
	end

	local blockSeed = ((seed + blockIndex * 7919) % MAX_RANDOM_SEED) + 1
	local random = Random.new(blockSeed)
	return random:NextInteger(1, samplingDivisor) == 1
end

local function getSourceInfoFromPayload(payload)
	return {
		Color = if typeof(payload.color) == "Color3" then payload.color else Color3.new(1, 1, 1),
		Material = getMaterialByName(payload.materialName),
		Transparency = if typeof(payload.transparency) == "number" then payload.transparency else 0,
		Reflectance = if typeof(payload.reflectance) == "number" then payload.reflectance else 0,
	}
end

function Debris.makePayload(
	removedBlocks,
	targetCFrame: CFrame,
	explosionPosition: Vector3,
	originalInfo,
	config
)
	if #removedBlocks == 0 then
		return nil
	end

	return {
		sourceCFrame = targetCFrame,
		explosionPosition = explosionPosition,
		blocks = copyRemovedBlocks(removedBlocks),
		materialName = originalInfo.Material.Name,
		color = originalInfo.Color,
		transparency = originalInfo.Transparency,
		reflectance = originalInfo.Reflectance,
		speedMin = getConfigValue(config, "SpeedMin"),
		speedMax = getConfigValue(config, "SpeedMax"),
		lifetime = getConfigValue(config, "Lifetime"),
		useGraphicsQualitySampling = if typeof(config and config.UseGraphicsQualitySampling) == "boolean"
			then config.UseGraphicsQualitySampling
			else DEFAULT_CONFIG.UseGraphicsQualitySampling,
		automaticQualityLevel = getConfigValue(config, "AutomaticQualityLevel"),
		maxSamplingDivisor = getConfigValue(config, "MaxSamplingDivisor"),
		seed = Random.new():NextInteger(1, MAX_RANDOM_SEED),
	}
end

function Debris.spawnPayload(payload, options)
	if typeof(payload) ~= "table" or typeof(payload.blocks) ~= "table" then
		return 0, 0
	end
	if typeof(payload.sourceCFrame) ~= "CFrame" or typeof(payload.explosionPosition) ~= "Vector3" then
		return 0, 0
	end

	local debrisFolder = getDebrisFolder(if typeof(options) == "table" then options.parentFolder else nil)
	local originalInfo = getSourceInfoFromPayload(payload)
	local speedMin = if typeof(payload.speedMin) == "number" then payload.speedMin else DEFAULT_CONFIG.SpeedMin
	local speedMax = if typeof(payload.speedMax) == "number" then payload.speedMax else DEFAULT_CONFIG.SpeedMax
	local lifetime = if typeof(payload.lifetime) == "number" then payload.lifetime else DEFAULT_CONFIG.Lifetime
	if typeof(options) == "table" and typeof(options.lifetimeScale) == "number" then
		lifetime *= math.clamp(options.lifetimeScale, 0.1, 4)
	end
	local maxParts = if typeof(options) == "table" and typeof(options.maxParts) == "number"
		then math.max(math.floor(options.maxParts), 0)
		else math.huge
	local forceVisible = typeof(options) == "table" and options.forceVisible == true
	local minimumParts = if forceVisible and typeof(options.minimumParts) == "number"
		then math.max(math.floor(options.minimumParts), 1)
		elseif forceVisible
		then 1
		else 0
	minimumParts = math.min(minimumParts, maxParts)
	local seed = if typeof(payload.seed) == "number" then payload.seed else Random.new():NextInteger(1, MAX_RANDOM_SEED)
	local random = Random.new(seed)
	local samplingDivisor = getSamplingDivisor(payload, options)
	local spawnAttempts = 0
	local spawned = 0

	for index, block in ipairs(payload.blocks) do
		if spawned >= maxParts then
			break
		end
		if typeof(block) ~= "table" or typeof(block.center) ~= "Vector3" or typeof(block.size) ~= "Vector3" then
			continue
		end
		local passesSampling = shouldSpawnBlock(seed, index, samplingDivisor)
		if not passesSampling and not (forceVisible and spawned < minimumParts) then
			continue
		end
		spawnAttempts += 1

		local worldCFrame = payload.sourceCFrame * CFrame.new(block.center)
		local worldPosition = worldCFrame.Position
		local away = worldPosition - payload.explosionPosition
		local direction = if away.Magnitude >= 0.05 then away.Unit else randomUnitVector(random)
		direction = (direction + Vector3.yAxis * 0.35 + randomUnitVector(random) * 0.18).Unit

		local debrisPart = Instance.new("Part")
		debrisPart.Size = block.size
		debrisPart.CFrame = worldCFrame
		debrisPart.Anchored = false
		debrisPart.CanCollide = false
		debrisPart.CanQuery = false
		debrisPart.CanTouch = false
		debrisPart.Material = originalInfo.Material
		debrisPart.Color = originalInfo.Color
		debrisPart.Transparency = originalInfo.Transparency
		debrisPart.Reflectance = originalInfo.Reflectance
		debrisPart.Parent = debrisFolder

		local speed = speedMin + random:NextNumber() * math.max(speedMax - speedMin, 0)
		debrisPart.AssemblyLinearVelocity = direction * speed
		debrisPart.AssemblyAngularVelocity = Vector3.new(
			random:NextInteger(-9, 9),
			random:NextInteger(-9, 9),
			random:NextInteger(-9, 9)
		)

		DebrisService:AddItem(debrisPart, lifetime)
		spawned += 1
	end

	return spawned, spawnAttempts
end

function Debris.makeDebris(
	removedBlocks,
	targetCFrame: CFrame,
	explosionPosition: Vector3,
	originalInfo,
	config
)
	local payload = Debris.makePayload(removedBlocks, targetCFrame, explosionPosition, originalInfo, config)
	if not payload then
		return
	end

	Debris.spawnPayload(payload)
end

return Debris
