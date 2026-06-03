local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local Utils = require(script.Utils)
local Mesh = require(script.Mesh)
local Cleanup = require(script.Cleanup)
local Debris = require(script.Debris)

local VoxDestruct = {
	VoxelCache = nil,
	TerrainCells = {},
	TerrainDebugParts = {},
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

local BLOCK_EPSILON = 0.001

local function getConfigNumber(config, name: string, fallback: number): number
	local value = if config then config[name] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getConfigString(config, name: string, fallback: string): string
	local value = if config then config[name] else nil
	return if typeof(value) == "string" and value ~= "" then value else fallback
end

local function isTerrainDebugEnabled(): boolean
	local config = VoxDestruct.TerrainDebugConfig
	if not config.Visualize then
		return false
	end

	return not config.StudioOnly or RunService:IsStudio()
end

local function getTerrainDebugFolder(): Folder
	local folderName = VoxDestruct.TerrainDebugConfig.FolderName
	local folder = workspace:FindFirstChild(folderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = folderName
		folder.Parent = workspace
	end

	return folder
end

local function getHealthColor(healthRatio: number): Color3
	local config = VoxDestruct.TerrainDebugConfig
	local ratio = math.clamp(healthRatio, 0, 1)
	if ratio >= 0.5 then
		return config.DamagedColor:Lerp(config.HealthyColor, (ratio - 0.5) / 0.5)
	end

	return config.CriticalColor:Lerp(config.DamagedColor, ratio / 0.5)
end

local function getInsetSize(size: Vector3): Vector3
	local inset = VoxDestruct.TerrainDebugConfig.Inset
	return Vector3.new(
		math.max(size.X - inset * 2, 0.1),
		math.max(size.Y - inset * 2, 0.1),
		math.max(size.Z - inset * 2, 0.1)
	)
end

local function removeTerrainDebugPart(key: string)
	local part = VoxDestruct.TerrainDebugParts[key]
	if part then
		part:Destroy()
		VoxDestruct.TerrainDebugParts[key] = nil
	end
end

local function syncTerrainDebugCell(key: string, cell)
	if cell.Destroyed then
		removeTerrainDebugPart(key)
		return
	end
	if not isTerrainDebugEnabled() then
		return
	end
	if not cell.CFrame or not cell.Size then
		return
	end

	local part = VoxDestruct.TerrainDebugParts[key]
	if not part then
		part = Instance.new("Part")
		part.Name = "DamageGridCell"
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Locked = true
		part.Material = Enum.Material.Neon
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part:SetAttribute("DamageGridKey", key)
		part.Parent = getTerrainDebugFolder()
		VoxDestruct.TerrainDebugParts[key] = part
	end

	local maxHealth = math.max(cell.MaxHealth or 1, 0.001)
	part.Size = getInsetSize(cell.Size)
	part.CFrame = cell.CFrame
	part.Transparency = VoxDestruct.TerrainDebugConfig.Transparency
	part.Color = getHealthColor((cell.Health or 0) / maxHealth)
end

local function getCellKey(worldPosition: Vector3, terrainConfig): string
	local cellSize = getConfigNumber(terrainConfig, "CellSize", 8)
	local x = math.floor((worldPosition.X / cellSize) + 0.5)
	local y = math.floor((worldPosition.Y / cellSize) + 0.5)
	local z = math.floor((worldPosition.Z / cellSize) + 0.5)
	return `{x}:{y}:{z}`
end

local function getTaggedAncestorAttribute(instance: Instance, tagName: string?, attributeName: string): any
	local directValue = instance:GetAttribute(attributeName)
	if directValue ~= nil then
		return directValue
	end
	if not tagName then
		return nil
	end

	local current = instance.Parent
	while current and current ~= workspace do
		if CollectionService:HasTag(current, tagName) then
			local value = current:GetAttribute(attributeName)
			if value ~= nil then
				return value
			end
		end
		current = current.Parent
	end

	return nil
end

local function getSourceInfo(target: BasePart, generatedVoxelTag: string?, terrainConfig)
	local healthAttribute = getConfigString(terrainConfig, "HealthAttribute", "DestructionHealth")
	local damageMultiplierAttribute =
		getConfigString(terrainConfig, "DamageMultiplierAttribute", "DestructionDamageMultiplier")

	local maxHealth = getTaggedAncestorAttribute(target, generatedVoxelTag, healthAttribute)
	if typeof(maxHealth) ~= "number" or maxHealth <= 0 then
		maxHealth = getConfigNumber(terrainConfig, "CellHealth", 80)
	end

	local damageMultiplier = getTaggedAncestorAttribute(target, generatedVoxelTag, damageMultiplierAttribute)
	if typeof(damageMultiplier) ~= "number" or damageMultiplier < 0 then
		damageMultiplier = 1
	end

	return {
		HealthAttribute = healthAttribute,
		DamageMultiplierAttribute = damageMultiplierAttribute,
		MaxHealth = maxHealth,
		DamageMultiplier = damageMultiplier,
	}
end

local function getTerrainDamage(distance: number, sphereRadius: number, terrainConfig): number
	local innerRadius = math.min(getConfigNumber(terrainConfig, "InnerRadius", sphereRadius * 0.25), sphereRadius)
	local nearRadius = math.min(getConfigNumber(terrainConfig, "NearRadius", sphereRadius * 0.6), sphereRadius)
	if nearRadius < innerRadius then
		nearRadius = innerRadius
	end

	if distance <= innerRadius then
		return getConfigNumber(terrainConfig, "InnerDamage", 100)
	end
	if distance <= nearRadius then
		local alpha = (distance - innerRadius) / math.max(nearRadius - innerRadius, 0.001)
		local nearMax = getConfigNumber(terrainConfig, "NearDamageMax", 70)
		local nearMin = getConfigNumber(terrainConfig, "NearDamageMin", 35)
		return nearMax + (nearMin - nearMax) * alpha
	end
	if distance <= sphereRadius then
		local alpha = (distance - nearRadius) / math.max(sphereRadius - nearRadius, 0.001)
		local outerMax = getConfigNumber(terrainConfig, "OuterDamageMax", 25)
		local outerMin = getConfigNumber(terrainConfig, "OuterDamageMin", 8)
		return outerMax + (outerMin - outerMax) * alpha
	end

	return 0
end

local function applyTerrainDamageToBlock(block, targetCFrame: CFrame, sphereCenter: Vector3, sphereRadius: number, terrainConfig, sourceInfo)
	local worldPosition = targetCFrame:PointToWorldSpace(block.center)
	local distance = (worldPosition - sphereCenter).Magnitude
	if distance > sphereRadius then
		return false
	end

	local key = getCellKey(worldPosition, terrainConfig)
	local cell = VoxDestruct.TerrainCells[key]
	if not cell then
		cell = {
			Key = key,
			CFrame = targetCFrame * CFrame.new(block.center),
			Size = block.size,
			Health = sourceInfo.MaxHealth,
			MaxHealth = sourceInfo.MaxHealth,
			DamageMultiplier = sourceInfo.DamageMultiplier,
			Destroyed = false,
		}
		VoxDestruct.TerrainCells[key] = cell
	else
		cell.CFrame = targetCFrame * CFrame.new(block.center)
		cell.Size = block.size
	end
	if cell.Destroyed then
		syncTerrainDebugCell(key, cell)
		return true
	end

	local damage = getTerrainDamage(distance, sphereRadius, terrainConfig) * cell.DamageMultiplier
	if damage <= 0 then
		syncTerrainDebugCell(key, cell)
		return false
	end

	cell.Health -= damage
	if cell.Health <= 0 then
		cell.Health = 0
		cell.Destroyed = true
		syncTerrainDebugCell(key, cell)
		return true
	end

	syncTerrainDebugCell(key, cell)
	return false
end

local function addBlock(blocks, minCorner: Vector3, maxCorner: Vector3)
	local size = maxCorner - minCorner
	if size.X <= BLOCK_EPSILON or size.Y <= BLOCK_EPSILON or size.Z <= BLOCK_EPSILON then
		return
	end

	table.insert(blocks, {
		center = (minCorner + maxCorner) * 0.5,
		size = size,
	})
end

local function getSubdivisionSteps(axisHalfSize: number, axisSize: number, minSize: number)
	if axisSize <= minSize then
		return {
			{ offset = 0, halfSize = axisHalfSize },
		}
	end

	local childHalfSize = axisHalfSize * 0.5
	return {
		{ offset = -childHalfSize, halfSize = childHalfSize },
		{ offset = childHalfSize, halfSize = childHalfSize },
	}
end

local function subdivideAABB(
	aabbCenter: Vector3,
	halfSize: Vector3,
	sphereCenter: Vector3,
	sphereCenterWorld: Vector3,
	sphereRadius: number,
	minSize: number,
	targetCFrame: CFrame,
	terrainConfig,
	sourceInfo
)
	local remainingBlocks = {}
	local removedBlocks = {}
	local fullSize = halfSize * 2
	local isTerminal = fullSize.X <= minSize and fullSize.Y <= minSize and fullSize.Z <= minSize

	if Utils.isAABBOutsideSphere(aabbCenter, halfSize, sphereCenter, sphereRadius) then
		table.insert(remainingBlocks, { center = aabbCenter, size = fullSize })
		return remainingBlocks, removedBlocks
	end

	if isTerminal then
		local block = { center = aabbCenter, size = fullSize }
		if applyTerrainDamageToBlock(block, targetCFrame, sphereCenterWorld, sphereRadius, terrainConfig, sourceInfo) then
			table.insert(removedBlocks, { center = aabbCenter, size = fullSize })
		else
			table.insert(remainingBlocks, { center = aabbCenter, size = fullSize })
		end
		return remainingBlocks, removedBlocks
	end

	local xSteps = getSubdivisionSteps(halfSize.X, fullSize.X, minSize)
	local ySteps = getSubdivisionSteps(halfSize.Y, fullSize.Y, minSize)
	local zSteps = getSubdivisionSteps(halfSize.Z, fullSize.Z, minSize)

	for _, x in ipairs(xSteps) do
		for _, y in ipairs(ySteps) do
			for _, z in ipairs(zSteps) do
				local offset = Vector3.new(x.offset, y.offset, z.offset)
				local newCenter = aabbCenter + offset
				local newHalf = Vector3.new(x.halfSize, y.halfSize, z.halfSize)
				local subRemaining, subRemoved =
					subdivideAABB(
						newCenter,
						newHalf,
						sphereCenter,
						sphereCenterWorld,
						sphereRadius,
						minSize,
						targetCFrame,
						terrainConfig,
						sourceInfo
					)

				for _, block in ipairs(subRemaining) do
					table.insert(remainingBlocks, block)
				end
				for _, block in ipairs(subRemoved) do
					table.insert(removedBlocks, block)
				end
			end
		end
	end

	return remainingBlocks, removedBlocks
end

local function partitionTargetBlocks(targetSize: Vector3, localSphereCenter: Vector3, sphereRadius: number)
	local targetHalf = targetSize * 0.5
	local targetMin = -targetHalf
	local targetMax = targetHalf
	local impactMin = Vector3.new(
		math.clamp(localSphereCenter.X - sphereRadius, targetMin.X, targetMax.X),
		math.clamp(localSphereCenter.Y - sphereRadius, targetMin.Y, targetMax.Y),
		math.clamp(localSphereCenter.Z - sphereRadius, targetMin.Z, targetMax.Z)
	)
	local impactMax = Vector3.new(
		math.clamp(localSphereCenter.X + sphereRadius, targetMin.X, targetMax.X),
		math.clamp(localSphereCenter.Y + sphereRadius, targetMin.Y, targetMax.Y),
		math.clamp(localSphereCenter.Z + sphereRadius, targetMin.Z, targetMax.Z)
	)
	local outsideBlocks = {}

	if impactMax.X - impactMin.X <= BLOCK_EPSILON
		or impactMax.Y - impactMin.Y <= BLOCK_EPSILON
		or impactMax.Z - impactMin.Z <= BLOCK_EPSILON
	then
		addBlock(outsideBlocks, targetMin, targetMax)
		return outsideBlocks, nil
	end

	addBlock(outsideBlocks, targetMin, Vector3.new(impactMin.X, targetMax.Y, targetMax.Z))
	addBlock(outsideBlocks, Vector3.new(impactMax.X, targetMin.Y, targetMin.Z), targetMax)

	local centerXMin = Vector3.new(impactMin.X, targetMin.Y, targetMin.Z)
	local centerXMax = Vector3.new(impactMax.X, targetMax.Y, targetMax.Z)
	addBlock(outsideBlocks, centerXMin, Vector3.new(centerXMax.X, impactMin.Y, centerXMax.Z))
	addBlock(outsideBlocks, Vector3.new(centerXMin.X, impactMax.Y, centerXMin.Z), centerXMax)

	local centerXYMin = Vector3.new(impactMin.X, impactMin.Y, targetMin.Z)
	local centerXYMax = Vector3.new(impactMax.X, impactMax.Y, targetMax.Z)
	addBlock(outsideBlocks, centerXYMin, Vector3.new(centerXYMax.X, centerXYMax.Y, impactMin.Z))
	addBlock(outsideBlocks, Vector3.new(centerXYMin.X, centerXYMin.Y, impactMax.Z), centerXYMax)

	return outsideBlocks, {
		center = (impactMin + impactMax) * 0.5,
		size = impactMax - impactMin,
	}
end

function VoxDestruct.clearTerrainDebugVisuals()
	for _, part in pairs(VoxDestruct.TerrainDebugParts) do
		part:Destroy()
	end
	table.clear(VoxDestruct.TerrainDebugParts)

	local folder = workspace:FindFirstChild(VoxDestruct.TerrainDebugConfig.FolderName)
	if folder then
		folder:Destroy()
	end
end

function VoxDestruct.setTerrainDebugConfig(config)
	if typeof(config) ~= "table" then
		return
	end

	local oldFolderName = VoxDestruct.TerrainDebugConfig.FolderName

	if typeof(config.Visualize) == "boolean" then
		VoxDestruct.TerrainDebugConfig.Visualize = config.Visualize
	end
	if typeof(config.StudioOnly) == "boolean" then
		VoxDestruct.TerrainDebugConfig.StudioOnly = config.StudioOnly
	end
	if typeof(config.FolderName) == "string" and config.FolderName ~= "" then
		VoxDestruct.TerrainDebugConfig.FolderName = config.FolderName
	end
	if typeof(config.Transparency) == "number" then
		VoxDestruct.TerrainDebugConfig.Transparency = math.clamp(config.Transparency, 0, 1)
	end
	if typeof(config.Inset) == "number" then
		VoxDestruct.TerrainDebugConfig.Inset = math.max(config.Inset, 0)
	end
	if typeof(config.HealthyColor) == "Color3" then
		VoxDestruct.TerrainDebugConfig.HealthyColor = config.HealthyColor
	end
	if typeof(config.DamagedColor) == "Color3" then
		VoxDestruct.TerrainDebugConfig.DamagedColor = config.DamagedColor
	end
	if typeof(config.CriticalColor) == "Color3" then
		VoxDestruct.TerrainDebugConfig.CriticalColor = config.CriticalColor
	end

	if oldFolderName ~= VoxDestruct.TerrainDebugConfig.FolderName then
		local oldFolder = workspace:FindFirstChild(oldFolderName)
		if oldFolder then
			oldFolder:Destroy()
		end
		table.clear(VoxDestruct.TerrainDebugParts)
	end

	if not isTerrainDebugEnabled() then
		VoxDestruct.clearTerrainDebugVisuals()
		return
	end

	for key, cell in pairs(VoxDestruct.TerrainCells) do
		syncTerrainDebugCell(key, cell)
	end
end

function VoxDestruct.octreeMeshSubtraction(
	target: BasePart,
	sphereHitbox: Part,
	minSize: number,
	finalVoxelSize: number,
	randomColor: boolean,
	debris: boolean,
	debrisAmount: number,
	debrisSizeMultiplier: number,
	debrisConfig,
	generatedVoxelTag: string?,
	terrainConfig
)
	local sphereCenterWorld = sphereHitbox.Position
	local sphereRadius = sphereHitbox.Size.X / 2

	local targetCFrame = target.CFrame
	local targetSize = target.Size

	local localSphereCenter = targetCFrame:PointToObjectSpace(sphereCenterWorld)
	local outsideBlocks, impactBlock = partitionTargetBlocks(targetSize, localSphereCenter, sphereRadius)
	local remainingBlocks = table.clone(outsideBlocks)
	local removedBlocks = {}
	local sourceInfo = getSourceInfo(target, generatedVoxelTag, terrainConfig)

	if impactBlock then
		local impactRemaining, impactRemoved =
			subdivideAABB(
				impactBlock.center,
				impactBlock.size * 0.5,
				localSphereCenter,
				sphereCenterWorld,
				sphereRadius,
				minSize,
				targetCFrame,
				terrainConfig,
				sourceInfo
			)
		for _, block in ipairs(impactRemaining) do
			table.insert(remainingBlocks, block)
		end
		for _, block in ipairs(impactRemoved) do
			table.insert(removedBlocks, block)
		end
	end

	local mergedBlocks = Mesh.greedyMergeBlocks(remainingBlocks)

	local originalInfo = {
		Size = target.Size,
		Color = target.Color,
		Material = target.Material,
		Transparency = target.Transparency,
		Reflectance = target.Reflectance,
	}

	target:Destroy()

	local debrisPayload = nil
	if debris then
		if debrisConfig and debrisConfig.ClientSimulated == true then
			debrisPayload = Debris.makePayload(removedBlocks, targetCFrame, sphereCenterWorld, originalInfo, debrisConfig)
		else
			Debris.makeDebris(removedBlocks, targetCFrame, sphereCenterWorld, originalInfo, debrisConfig)
		end
	end

	local meshedFolder = workspace:FindFirstChild("CurrentVoxels")
	if not meshedFolder then
		meshedFolder = Instance.new("Folder")
		meshedFolder.Name = "CurrentVoxels"
		meshedFolder.Parent = workspace
	end

	local finalVoxels = {}

	if finalVoxelSize and finalVoxelSize > minSize then
		for _, block in ipairs(mergedBlocks) do
			local subVoxels = Cleanup.subdivideBlockToUniformVoxels(block, finalVoxelSize)
			for _, voxel in ipairs(subVoxels) do
				table.insert(finalVoxels, voxel)
			end
		end
	else
		finalVoxels = mergedBlocks
	end

	finalVoxels = Cleanup.cleanupVoxels(finalVoxels, 0.5)

	for _, voxel in ipairs(finalVoxels) do
		local worldCFrame = targetCFrame * CFrame.new(voxel.center)

		local part = VoxDestruct.VoxelCache:GetPart()
		part.Size = voxel.size
		part.CFrame = worldCFrame
		part.Anchored = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Transparency = originalInfo.Transparency
		part.Reflectance = originalInfo.Reflectance

		if randomColor then
			part.BrickColor = BrickColor.Random()
		else
			part.Color = originalInfo.Color
		end

		part.Material = originalInfo.Material
		part.Name = "MeshedVoxel"
		part:SetAttribute(sourceInfo.HealthAttribute, sourceInfo.MaxHealth)
		part:SetAttribute(sourceInfo.DamageMultiplierAttribute, sourceInfo.DamageMultiplier)
		if generatedVoxelTag then
			CollectionService:AddTag(part, generatedVoxelTag)
		end
		part.Parent = meshedFolder
	end

	return finalVoxels, debrisPayload
end

function VoxDestruct.subtractHitbox(
	sphereHitbox: Part,
	minSize: number,
	finalVoxelSize: number,
	randomColor: boolean,
	debris: boolean,
	debrisAmount: number,
	ignore: { Instance },
	voxelCache,
	debrisSizeMultiplier: number,
	debrisConfig,
	generatedVoxelTag: string?,
	terrainConfig,
	include: { Instance }?
)
	VoxDestruct.VoxelCache = voxelCache

	local overlapParams = OverlapParams.new()
	if include and #include > 0 then
		overlapParams.FilterDescendantsInstances = include
		overlapParams.FilterType = Enum.RaycastFilterType.Include
	else
		overlapParams.FilterDescendantsInstances = { sphereHitbox, table.unpack(ignore) }
		overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	end

	local debrisPayloads = {}
	local targets = workspace:GetPartBoundsInRadius(sphereHitbox.Position, sphereHitbox.Size.X / 2, overlapParams)
	for _, object in ipairs(targets) do
		if not object:IsA("BasePart") or object == sphereHitbox or object.Locked then
			continue
		end

		local _, debrisPayload = VoxDestruct.octreeMeshSubtraction(
			object,
			sphereHitbox,
			minSize,
			finalVoxelSize,
			randomColor,
			debris,
			debrisAmount,
			debrisSizeMultiplier,
			debrisConfig,
			generatedVoxelTag,
			terrainConfig
		)
		if debrisPayload then
			table.insert(debrisPayloads, debrisPayload)
		end
	end

	sphereHitbox:Destroy()
	return debrisPayloads
end

return VoxDestruct
