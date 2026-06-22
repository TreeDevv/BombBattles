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
	CompactPayloads = false,
	CompactSamplesPerPayload = 3,
	CompactMaxSamples = 24,
	CompactMaxPayloads = 12,
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

local function getCompactBlockSampleCount(config): number
	local value = if config then config.CompactSamplesPerPayload or config.DebrisCompactSamplesPerPayload else nil
	return math.clamp(math.floor(if typeof(value) == "number" then value else DEFAULT_CONFIG.CompactSamplesPerPayload), 1, 12)
end

local function getDebrisMaterialFields(originalInfo, config)
	return {
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

local function getAverageCompactSize(totalSize: Vector3, count: number): Vector3
	if count <= 0 then
		return Vector3.new(1.25, 1.25, 1.25)
	end

	local average = totalSize / count
	return Vector3.new(
		math.clamp(average.X, 0.4, 7),
		math.clamp(average.Y, 0.4, 7),
		math.clamp(average.Z, 0.4, 7)
	)
end

local function getBlockWorldCFrame(payload, block): CFrame?
	if typeof(block.cframe) == "CFrame" then
		return block.cframe
	end
	if typeof(payload.sourceCFrame) == "CFrame" and typeof(block.center) == "Vector3" then
		return payload.sourceCFrame * CFrame.new(block.center)
	end
	return nil
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

	local payload = {
		sourceCFrame = targetCFrame,
		explosionPosition = explosionPosition,
		blocks = copyRemovedBlocks(removedBlocks),
	}
	for key, value in pairs(getDebrisMaterialFields(originalInfo, config)) do
		payload[key] = value
	end
	return payload
end

function Debris.makeCompactPayload(
	removedBlocks,
	targetCFrame: CFrame,
	explosionPosition: Vector3,
	originalInfo,
	config
)
	if #removedBlocks == 0 then
		return nil
	end

	local sampleCount = math.min(#removedBlocks, getCompactBlockSampleCount(config))
	local totalSize = Vector3.zero
	local maxRadius = 0
	for _, block in ipairs(removedBlocks) do
		if typeof(block) == "table" and typeof(block.size) == "Vector3" and typeof(block.center) == "Vector3" then
			totalSize += block.size
			local worldPosition = targetCFrame:PointToWorldSpace(block.center)
			maxRadius = math.max(maxRadius, (worldPosition - explosionPosition).Magnitude + block.size.Magnitude * 0.5)
		end
	end

	local payload = {
		compact = true,
		explosionPosition = explosionPosition,
		sourceBlockCount = #removedBlocks,
		sampleCount = sampleCount,
		averageSize = getAverageCompactSize(totalSize, #removedBlocks),
		radius = math.clamp(maxRadius, 2, 80),
	}
	for key, value in pairs(getDebrisMaterialFields(originalInfo, config)) do
		payload[key] = value
	end
	return payload
end

local function spawnCompactPayload(payload, options)
	if typeof(payload) ~= "table" or payload.compact ~= true or typeof(payload.explosionPosition) ~= "Vector3" then
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
	local minimumParts = if forceVisible and typeof(options) == "table" and typeof(options.minimumParts) == "number"
		then math.max(math.floor(options.minimumParts), 1)
		elseif forceVisible
		then 1
		else 0
	local seed = if typeof(payload.seed) == "number" then payload.seed else Random.new():NextInteger(1, MAX_RANDOM_SEED)
	local random = Random.new(seed)
	local samplingDivisor = getSamplingDivisor(payload, options)
	local desiredCount = math.max(math.floor(if typeof(payload.sampleCount) == "number" then payload.sampleCount else 1), 0)
	local maxCompactSamples = if typeof(payload.maxSamples) == "number" then math.max(math.floor(payload.maxSamples), 1) else DEFAULT_CONFIG.CompactMaxSamples
	desiredCount = math.min(desiredCount, maxCompactSamples)
	local sampledCount = if samplingDivisor <= 1 then desiredCount else math.ceil(desiredCount / samplingDivisor)
	local spawnCount = math.min(math.max(sampledCount, math.min(minimumParts, desiredCount)), maxParts)
	local averageSize = if typeof(payload.averageSize) == "Vector3" then payload.averageSize else Vector3.new(1.25, 1.25, 1.25)
	local radius = math.max(if typeof(payload.radius) == "number" then payload.radius else 5, 1)
	local spawned = 0

	for index = 1, spawnCount do
		local direction = randomUnitVector(random)
		local distance = radius * random:NextNumber(0.15, 0.95)
		local position = payload.explosionPosition + direction * distance
		local scale = random:NextNumber(0.65, 1.2)
		local debrisPart = Instance.new("Part")
		debrisPart.Size = Vector3.new(
			math.clamp(averageSize.X * scale, 0.3, 8),
			math.clamp(averageSize.Y * random:NextNumber(0.45, 1.1), 0.3, 8),
			math.clamp(averageSize.Z * scale, 0.3, 8)
		)
		debrisPart.CFrame = CFrame.new(position) * CFrame.Angles(
			random:NextNumber(-math.pi, math.pi),
			random:NextNumber(-math.pi, math.pi),
			random:NextNumber(-math.pi, math.pi)
		)
		debrisPart.Anchored = false
		debrisPart.CanCollide = false
		debrisPart.CanQuery = false
		debrisPart.CanTouch = false
		debrisPart.Material = originalInfo.Material
		debrisPart.Color = originalInfo.Color
		debrisPart.Transparency = originalInfo.Transparency
		debrisPart.Reflectance = originalInfo.Reflectance
		debrisPart.Parent = debrisFolder

		local away = position - payload.explosionPosition
		local velocityDirection = if away.Magnitude >= 0.05 then away.Unit else direction
		velocityDirection = (velocityDirection + Vector3.yAxis * 0.35 + randomUnitVector(random) * 0.18).Unit
		local speed = speedMin + random:NextNumber() * math.max(speedMax - speedMin, 0)
		debrisPart.AssemblyLinearVelocity = velocityDirection * speed
		debrisPart.AssemblyAngularVelocity = Vector3.new(
			random:NextInteger(-9, 9),
			random:NextInteger(-9, 9),
			random:NextInteger(-9, 9)
		)

		DebrisService:AddItem(debrisPart, lifetime)
		spawned += 1
	end

	return spawned, desiredCount
end

function Debris.spawnPayload(payload, options)
	if typeof(payload) == "table" and payload.compact == true then
		return spawnCompactPayload(payload, options)
	end
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
		if typeof(block) ~= "table" or typeof(block.size) ~= "Vector3" then
			continue
		end
		local worldCFrame = getBlockWorldCFrame(payload, block)
		if not worldCFrame then
			continue
		end
		local passesSampling = shouldSpawnBlock(seed, index, samplingDivisor)
		if not passesSampling and not (forceVisible and spawned < minimumParts) then
			continue
		end
		spawnAttempts += 1

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
