local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local VoxManager = require(ReplicatedStorage.Packages.VoxManager)

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local CURRENT_VOXELS_FOLDER_NAME = "CurrentVoxels"

local DestructionService = {}
local replayService = nil
local scoreRecorder = nil
local targetCacheStarted = false
local destructibleAddedConnection: RBXScriptConnection? = nil
local destructibleRemovedConnection: RBXScriptConnection? = nil
local unsafeTagConnections: { RBXScriptConnection } = {}
local taggedRootRecords: { [Instance]: any } = {}
local targetPartRefCounts: { [BasePart]: number } = {}
local targetPartIndices: { [BasePart]: number } = {}
local targetParts: { BasePart } = {}
local spatialGrid: { [string]: { [BasePart]: boolean } } = {}
local targetPartGridCells: { [BasePart]: { string } } = {}
local spatialGridCellCount = 0
local cachedRootCount = 0
local destructionListeners: { (any) -> () } = {}

local function getReplayService()
	if replayService then
		return replayService
	end

	local services = ServerScriptService:FindFirstChild("Services")
	local replayModule = services and services:FindFirstChild("ReplayService")
	if not (replayModule and replayModule:IsA("ModuleScript")) then
		return nil
	end

	local ok, service = pcall(require, replayModule)
	if ok and typeof(service) == "table" then
		replayService = service
		return replayService
	end
	return nil
end

local function recordMapDestruction(position: Vector3, radius: number, sourceContext, debrisPayloads)
	local service = getReplayService()
	if not (service and type(service.RecordMapDestruction) == "function") then
		return
	end

	local payload = {
		position = position,
		radius = radius,
	}
	if typeof(sourceContext) == "table" then
		payload.timestamp = sourceContext.timestamp
		payload.sourceType = sourceContext.sourceType
		payload.sourceId = sourceContext.sourceId
		payload.bombId = sourceContext.bombId
		payload.ownerUserId = sourceContext.ownerUserId
	end
	if typeof(debrisPayloads) == "table" then
		payload.debrisPayloads = debrisPayloads
	end

	pcall(function()
		service.RecordMapDestruction(payload)
	end)
end

local function hasUnsafeTaggedAncestor(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		for _, tagName in ipairs(UNSAFE_TAGS) do
			if CollectionService:HasTag(current, tagName) then
				return true
			end
		end
		current = current.Parent
	end

	return false
end

local function getActiveMap(): Model?
	local activeMap = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if activeMap and activeMap:IsA("Model") then activeMap else nil
end

local function getCurrentVoxelsFolder(): Folder
	local parent: Instance = getActiveMap() or workspace
	local existing = parent:FindFirstChild(CURRENT_VOXELS_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = CURRENT_VOXELS_FOLDER_NAME
	folder.Parent = parent
	return folder
end

local function clearCurrentVoxelsFolder()
	local activeMap = getActiveMap()
	local mapFolder = activeMap and activeMap:FindFirstChild(CURRENT_VOXELS_FOLDER_NAME)
	if mapFolder then
		mapFolder:Destroy()
	end

	local legacyFolder = workspace:FindFirstChild(CURRENT_VOXELS_FOLDER_NAME)
	if legacyFolder then
		legacyFolder:Destroy()
	end
end

local function recordDestructionScore(sourceContext, targetsHit: number, position: Vector3?)
	if not scoreRecorder then
		return
	end

	local ok, err = pcall(scoreRecorder, sourceContext, targetsHit, position)
	if not ok then
		warn("[DestructionService] Failed to record destruction score:", err)
	end
end

local function notifyDestruction(payload)
	for _, listener in ipairs(destructionListeners) do
		task.spawn(listener, payload)
	end
end

local function disconnectConnections(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function getSpatialGridCellSize(): number
	local configured = DestructionConfig.SpatialGridCellSize
	if typeof(configured) == "number" and configured > 0 then
		return math.max(configured, DestructionConfig.FinalVoxelSize, 1)
	end

	return math.max(BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius or 16, DestructionConfig.FinalVoxelSize, 1)
end

local function getGridCellCoord(value: number, cellSize: number): number
	return math.floor(value / cellSize)
end

local function getGridCellKey(x: number, y: number, z: number): string
	return `{x}:{y}:{z}`
end

local function getPartWorldAabb(part: BasePart): (Vector3, Vector3)
	local cframe = part.CFrame
	local halfSize = part.Size * 0.5
	local right = cframe.RightVector
	local up = cframe.UpVector
	local look = cframe.LookVector
	local extents = Vector3.new(
		math.abs(right.X) * halfSize.X + math.abs(up.X) * halfSize.Y + math.abs(look.X) * halfSize.Z,
		math.abs(right.Y) * halfSize.X + math.abs(up.Y) * halfSize.Y + math.abs(look.Y) * halfSize.Z,
		math.abs(right.Z) * halfSize.X + math.abs(up.Z) * halfSize.Y + math.abs(look.Z) * halfSize.Z
	)

	return cframe.Position - extents, cframe.Position + extents
end

local function removeTargetPartFromSpatialGrid(part: BasePart)
	local cellKeys = targetPartGridCells[part]
	if not cellKeys then
		return
	end

	for _, cellKey in ipairs(cellKeys) do
		local cell = spatialGrid[cellKey]
		if cell then
			cell[part] = nil
			if next(cell) == nil then
				spatialGrid[cellKey] = nil
				spatialGridCellCount = math.max(spatialGridCellCount - 1, 0)
			end
		end
	end
	targetPartGridCells[part] = nil
end

local function addTargetPartToSpatialGrid(part: BasePart)
	removeTargetPartFromSpatialGrid(part)
	if not part.CanQuery or not part:IsDescendantOf(workspace) then
		return
	end

	local cellSize = getSpatialGridCellSize()
	local minPoint, maxPoint = getPartWorldAabb(part)
	local minX = getGridCellCoord(minPoint.X, cellSize)
	local minY = getGridCellCoord(minPoint.Y, cellSize)
	local minZ = getGridCellCoord(minPoint.Z, cellSize)
	local maxX = getGridCellCoord(maxPoint.X, cellSize)
	local maxY = getGridCellCoord(maxPoint.Y, cellSize)
	local maxZ = getGridCellCoord(maxPoint.Z, cellSize)
	local cellKeys = {}

	for x = minX, maxX do
		for y = minY, maxY do
			for z = minZ, maxZ do
				local cellKey = getGridCellKey(x, y, z)
				local cell = spatialGrid[cellKey]
				if not cell then
					cell = {}
					spatialGrid[cellKey] = cell
					spatialGridCellCount += 1
				end
				cell[part] = true
				table.insert(cellKeys, cellKey)
			end
		end
	end

	targetPartGridCells[part] = cellKeys
end

local function clearSpatialGrid()
	table.clear(spatialGrid)
	table.clear(targetPartGridCells)
	spatialGridCellCount = 0
end

local function addCachedTargetPart(part: BasePart)
	if not part:IsDescendantOf(workspace) then
		return
	end

	local refCount = targetPartRefCounts[part]
	if refCount then
		targetPartRefCounts[part] = refCount + 1
		return
	end

	targetPartRefCounts[part] = 1
	targetPartIndices[part] = #targetParts + 1
	table.insert(targetParts, part)
	addTargetPartToSpatialGrid(part)
end

local function removeCachedTargetPart(part: BasePart)
	local refCount = targetPartRefCounts[part]
	if not refCount then
		return
	end
	if refCount > 1 then
		targetPartRefCounts[part] = refCount - 1
		return
	end

	local index = targetPartIndices[part]
	local lastPart = targetParts[#targetParts]
	if index and lastPart and lastPart ~= part then
		targetParts[index] = lastPart
		targetPartIndices[lastPart] = index
	end

	targetParts[#targetParts] = nil
	targetPartRefCounts[part] = nil
	targetPartIndices[part] = nil
	removeTargetPartFromSpatialGrid(part)
end

local function removeRecordPart(record, part: BasePart)
	if not record.parts[part] then
		return
	end

	record.parts[part] = nil
	removeCachedTargetPart(part)
end

local function clearRecordParts(record)
	for part in pairs(record.parts) do
		removeCachedTargetPart(part)
	end
	table.clear(record.parts)
end

local function addRecordPart(record, part: BasePart)
	if record.parts[part] then
		return
	end
	if not part:IsDescendantOf(workspace) or hasUnsafeTaggedAncestor(part) then
		return
	end

	record.parts[part] = true
	addCachedTargetPart(part)
end

local function addRecordInstance(record, instance: Instance)
	if record.unsafe or not record.root:IsDescendantOf(workspace) then
		return
	end

	if instance:IsA("BasePart") then
		addRecordPart(record, instance)
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			addRecordPart(record, descendant)
		end
	end
end

local function removeRecordInstance(record, instance: Instance)
	if instance:IsA("BasePart") then
		removeRecordPart(record, instance)
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			removeRecordPart(record, descendant)
		end
	end
end

local function refreshRootRecord(record)
	clearRecordParts(record)

	local root = record.root
	record.unsafe = false
	if not root:IsDescendantOf(workspace) then
		return
	end

	record.unsafe = hasUnsafeTaggedAncestor(root)
	if record.unsafe then
		return
	end

	addRecordInstance(record, root)
end

local unregisterTaggedRoot

local function registerTaggedRoot(root: Instance)
	local existing = taggedRootRecords[root]
	if existing then
		refreshRootRecord(existing)
		return
	end

	local record = {
		root = root,
		unsafe = false,
		parts = {},
		connections = {},
	}
	taggedRootRecords[root] = record
	cachedRootCount += 1

	table.insert(record.connections, root.AncestryChanged:Connect(function()
		refreshRootRecord(record)
	end))
	table.insert(record.connections, root.Destroying:Connect(function()
		unregisterTaggedRoot(root)
	end))

	if not root:IsA("BasePart") then
		table.insert(record.connections, root.DescendantAdded:Connect(function(descendant)
			addRecordInstance(record, descendant)
		end))
		table.insert(record.connections, root.DescendantRemoving:Connect(function(descendant)
			removeRecordInstance(record, descendant)
		end))
	end

	refreshRootRecord(record)
end

unregisterTaggedRoot = function(root: Instance)
	local record = taggedRootRecords[root]
	if not record then
		return
	end

	clearRecordParts(record)
	disconnectConnections(record.connections)
	taggedRootRecords[root] = nil
	cachedRootCount = math.max(cachedRootCount - 1, 0)
end

local function refreshUnsafeState()
	local token = RuntimeProfiler.Begin("Server/Destruction/RefreshUnsafeState")
	for _, record in pairs(taggedRootRecords) do
		refreshRootRecord(record)
	end
	RuntimeProfiler.Count("Server/Destruction/UnsafeRefreshes")
	RuntimeProfiler.End("Server/Destruction/RefreshUnsafeState", token)
end

local function rebuildTargetCache(reason: string?)
	local token = RuntimeProfiler.Begin("Server/Destruction/RebuildTargetCache")

	local roots = {}
	for root in pairs(taggedRootRecords) do
		table.insert(roots, root)
	end
	for _, root in ipairs(roots) do
		unregisterTaggedRoot(root)
	end
	table.clear(targetPartRefCounts)
	table.clear(targetPartIndices)
	table.clear(targetParts)
	clearSpatialGrid()
	cachedRootCount = 0

	for _, instance in ipairs(CollectionService:GetTagged(DestructionConfig.Tag)) do
		registerTaggedRoot(instance)
	end

	RuntimeProfiler.Count("Server/Destruction/TargetCacheRebuilds")
	if typeof(reason) == "string" and reason ~= "" then
		RuntimeProfiler.Count("Server/Destruction/TargetCacheRebuild/" .. reason)
	end
	RuntimeProfiler.Gauge("Server/Destruction/DestructibleRoots", cachedRootCount)
	RuntimeProfiler.Gauge("Server/Destruction/TargetParts", #targetParts)
	RuntimeProfiler.Gauge("Server/Destruction/SpatialGridCells", spatialGridCellCount)
	RuntimeProfiler.End("Server/Destruction/RebuildTargetCache", token)
end

local function startTargetCache()
	if targetCacheStarted then
		return
	end
	targetCacheStarted = true

	destructibleAddedConnection = CollectionService:GetInstanceAddedSignal(DestructionConfig.Tag):Connect(registerTaggedRoot)
	destructibleRemovedConnection = CollectionService:GetInstanceRemovedSignal(DestructionConfig.Tag):Connect(unregisterTaggedRoot)

	for _, tagName in ipairs(UNSAFE_TAGS) do
		table.insert(unsafeTagConnections, CollectionService:GetInstanceAddedSignal(tagName):Connect(refreshUnsafeState))
		table.insert(unsafeTagConnections, CollectionService:GetInstanceRemovedSignal(tagName):Connect(refreshUnsafeState))
	end

	rebuildTargetCache("Start")
end

local function getDestructibleTargets(): { BasePart }
	local token = RuntimeProfiler.Begin("Server/Destruction/GetTargets")
	if not targetCacheStarted then
		startTargetCache()
	end

	RuntimeProfiler.Gauge("Server/Destruction/DestructibleRoots", cachedRootCount)
	RuntimeProfiler.Gauge("Server/Destruction/TargetParts", #targetParts)
	RuntimeProfiler.Gauge("Server/Destruction/SpatialGridCells", spatialGridCellCount)
	RuntimeProfiler.End("Server/Destruction/GetTargets", token)
	return targetParts
end

local function buildVoxelOptions(options)
	local voxelOptions = {}
	if typeof(options) == "table" then
		for key, value in pairs(options) do
			voxelOptions[key] = value
		end
	end

	if voxelOptions.exactCullTargets == nil then
		voxelOptions.exactCullTargets = DestructionConfig.ExactCullTargets == true
	end
	if voxelOptions.skipTerminalNoop == nil then
		voxelOptions.skipTerminalNoop = DestructionConfig.SkipTerminalNoop == true
	end
	if voxelOptions.reuseTargetPart == nil then
		voxelOptions.reuseTargetPart = DestructionConfig.ReuseTargetPart == true
	end
	if voxelOptions.prefilterTargets == nil then
		voxelOptions.prefilterTargets = DestructionConfig.PrefilterTargets == true
	end
	if voxelOptions.batchDebrisPayloads == nil then
		voxelOptions.batchDebrisPayloads = DestructionConfig.BatchDebrisPayloads == true
	end

	return voxelOptions
end

local function getEffectiveQueryRadius(radius: number, options): number
	if typeof(options) ~= "table" or options.forceSubtract ~= true then
		return radius
	end

	local transparentCollisionClearance = options.transparentCollisionClearance
	if typeof(transparentCollisionClearance) ~= "number" or transparentCollisionClearance <= 0 then
		return radius
	end

	return radius + transparentCollisionClearance
end

local function isPartCandidate(part: BasePart, position: Vector3, radius: number): boolean
	local localPosition = part.CFrame:PointToObjectSpace(position)
	local halfSize = part.Size * 0.5
	local dx = math.max(math.abs(localPosition.X) - halfSize.X, 0)
	local dy = math.max(math.abs(localPosition.Y) - halfSize.Y, 0)
	local dz = math.max(math.abs(localPosition.Z) - halfSize.Z, 0)
	return dx * dx + dy * dy + dz * dz < radius * radius
end

local function getCandidateTargets(position: Vector3, radius: number, targets: { BasePart }, options): { BasePart }
	if typeof(options) == "table" and options.prefilterTargets == false then
		return targets
	end
	if spatialGridCellCount == 0 then
		return targets
	end

	local token = RuntimeProfiler.Begin("Server/Destruction/PrefilterTargets")
	local queryRadius = getEffectiveQueryRadius(radius, options)
	local cellSize = getSpatialGridCellSize()
	local minX = getGridCellCoord(position.X - queryRadius, cellSize)
	local minY = getGridCellCoord(position.Y - queryRadius, cellSize)
	local minZ = getGridCellCoord(position.Z - queryRadius, cellSize)
	local maxX = getGridCellCoord(position.X + queryRadius, cellSize)
	local maxY = getGridCellCoord(position.Y + queryRadius, cellSize)
	local maxZ = getGridCellCoord(position.Z + queryRadius, cellSize)
	local candidates = {}
	local seen = {}
	local visitedCells = 0
	local occupiedCells = 0
	local duplicateCandidates = 0

	for x = minX, maxX do
		for y = minY, maxY do
			for z = minZ, maxZ do
				visitedCells += 1
				local cell = spatialGrid[getGridCellKey(x, y, z)]
				if not cell then
					continue
				end

				occupiedCells += 1
				for part in pairs(cell) do
					if seen[part] then
						duplicateCandidates += 1
						continue
					end
					seen[part] = true

					if part.CanQuery and part:IsDescendantOf(workspace) and isPartCandidate(part, position, queryRadius) then
						table.insert(candidates, part)
					end
				end
			end
		end
	end

	RuntimeProfiler.Count("Server/Destruction/PrefilterCandidateTargets", #candidates)
	RuntimeProfiler.Count("Server/Destruction/PrefilterSkippedTargets", math.max(#targets - #candidates, 0))
	RuntimeProfiler.Count("Server/Destruction/PrefilterCellsVisited", visitedCells)
	RuntimeProfiler.Count("Server/Destruction/PrefilterOccupiedCells", occupiedCells)
	RuntimeProfiler.Count("Server/Destruction/PrefilterDuplicateCandidates", duplicateCandidates)
	RuntimeProfiler.Gauge("Server/Destruction/LastCandidateTargets", #candidates)
	RuntimeProfiler.End("Server/Destruction/PrefilterTargets", token)
	return candidates
end

local function getPayloadColorKey(color): string
	if typeof(color) ~= "Color3" then
		return "nil"
	end

	return ("%d:%d:%d"):format(
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

local function getPayloadNumberKey(value): string
	if typeof(value) ~= "number" then
		return "nil"
	end

	return ("%.4f"):format(value)
end

local function getDebrisBatchKey(payload): string
	return table.concat({
		tostring(payload.materialName),
		getPayloadColorKey(payload.color),
		getPayloadNumberKey(payload.transparency),
		getPayloadNumberKey(payload.reflectance),
		getPayloadNumberKey(payload.speedMin),
		getPayloadNumberKey(payload.speedMax),
		getPayloadNumberKey(payload.lifetime),
		tostring(payload.useGraphicsQualitySampling),
		getPayloadNumberKey(payload.automaticQualityLevel),
		getPayloadNumberKey(payload.maxSamplingDivisor),
	}, "|")
end

local function copyDebrisBatchFields(target, source)
	target.sourceCFrame = CFrame.new()
	target.explosionPosition = source.explosionPosition
	target.materialName = source.materialName
	target.color = source.color
	target.transparency = source.transparency
	target.reflectance = source.reflectance
	target.speedMin = source.speedMin
	target.speedMax = source.speedMax
	target.lifetime = source.lifetime
	target.useGraphicsQualitySampling = source.useGraphicsQualitySampling
	target.automaticQualityLevel = source.automaticQualityLevel
	target.maxSamplingDivisor = source.maxSamplingDivisor
	target.seed = if typeof(source.seed) == "number" then source.seed else Random.new():NextInteger(1, 2147483647)
	target.blocks = {}
end

local function batchDebrisPayloads(payloads, options)
	if typeof(payloads) ~= "table" or #payloads <= 1 then
		return payloads
	end
	if typeof(options) == "table" and options.batchDebrisPayloads == false then
		return payloads
	end

	local token = RuntimeProfiler.Begin("Server/Destruction/BatchDebrisPayloads")
	local batchesByKey = {}
	local batches = {}
	local blockCount = 0

	for _, payload in ipairs(payloads) do
		if
			typeof(payload) ~= "table"
			or typeof(payload.sourceCFrame) ~= "CFrame"
			or typeof(payload.explosionPosition) ~= "Vector3"
			or typeof(payload.blocks) ~= "table"
		then
			continue
		end

		local key = getDebrisBatchKey(payload)
		local batch = batchesByKey[key]
		if not batch then
			batch = {}
			copyDebrisBatchFields(batch, payload)
			batchesByKey[key] = batch
			table.insert(batches, batch)
		end

		for _, block in ipairs(payload.blocks) do
			if typeof(block) ~= "table" or typeof(block.size) ~= "Vector3" then
				continue
			end

			local worldCFrame = nil
			if typeof(block.cframe) == "CFrame" then
				worldCFrame = block.cframe
			elseif typeof(block.center) == "Vector3" then
				worldCFrame = payload.sourceCFrame * CFrame.new(block.center)
			end

			if worldCFrame then
				table.insert(batch.blocks, {
					cframe = worldCFrame,
					size = block.size,
				})
				blockCount += 1
			end
		end
	end

	if #batches == 0 then
		RuntimeProfiler.End("Server/Destruction/BatchDebrisPayloads", token)
		return payloads
	end

	batches.targetsHit = payloads.targetsHit
	batches.debrisPartsSpawned = payloads.debrisPartsSpawned
	batches.debrisPayloadBlocks = payloads.debrisPayloadBlocks
	batches.debrisSpawnAttempts = payloads.debrisSpawnAttempts

	RuntimeProfiler.Count("Server/Destruction/DebrisPayloadsBeforeBatch", #payloads)
	RuntimeProfiler.Count("Server/Destruction/DebrisPayloadsAfterBatch", #batches)
	RuntimeProfiler.Count("Server/Destruction/DebrisBlocksBatched", blockCount)
	RuntimeProfiler.End("Server/Destruction/BatchDebrisPayloads", token)
	return batches
end

function DestructionService:OnStart()
	VoxManager:setDebrisConfig(DestructionConfig)
	VoxManager:setGeneratedVoxelTag(DestructionConfig.Tag)
	VoxManager:setTerrainConfig(DestructionConfig)
	VoxManager:setTerrainDebugConfig(DestructionConfig)
	startTargetCache()
end

function DestructionService:SetScoreRecorder(recorder)
	scoreRecorder = if type(recorder) == "function" then recorder else nil
end

function DestructionService:RebuildTargetCache(reason: string?)
	if not targetCacheStarted then
		startTargetCache()
		return
	end

	rebuildTargetCache(reason or "Manual")
end

function DestructionService:InvalidateTargetCache(reason: string?)
	self:RebuildTargetCache(reason or "Invalidated")
end

function DestructionService:ObserveDestruction(listener)
	if type(listener) ~= "function" then
		return nil
	end

	table.insert(destructionListeners, listener)
	local connected = true
	return {
		Disconnect = function()
			if not connected then
				return
			end
			connected = false
			local index = table.find(destructionListeners, listener)
			if index then
				table.remove(destructionListeners, index)
			end
		end,
	}
end

function DestructionService:DestroySphere(position: Vector3, radius: number?, sourceContext, options)
	local token = RuntimeProfiler.Begin("Server/Destruction/DestroySphere")
	if typeof(position) ~= "Vector3" then
		RuntimeProfiler.End("Server/Destruction/DestroySphere", token)
		return {}
	end

	local destructionRadius = if typeof(radius) == "number" and radius > 0
		then radius
		else BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius

	local targets = getDestructibleTargets()
	if #targets == 0 then
		RuntimeProfiler.End("Server/Destruction/DestroySphere", token)
		return {}
	end

	local debrisPayloads = {}
	local voxelToken = RuntimeProfiler.Begin("Server/Destruction/VoxelizePosition")
	local ok, err = pcall(function()
		local voxelOptions = buildVoxelOptions(options)
		local candidateTargets = getCandidateTargets(position, destructionRadius, targets, voxelOptions)
		if candidateTargets ~= targets then
			voxelOptions.prefilteredTargets = true
		end
		if #candidateTargets == 0 then
			debrisPayloads = {}
			return
		end

		local outputFolder = getCurrentVoxelsFolder()
		debrisPayloads = VoxManager:voxelizePosition(
			position,
			destructionRadius,
			DestructionConfig.MinVoxelSize,
			DestructionConfig.FinalVoxelSize,
			DestructionConfig.RandomColor,
			DestructionConfig.Debris,
			DestructionConfig.DebrisAmount,
			{},
			candidateTargets,
			outputFolder,
			voxelOptions
		) or {}
	end)
	RuntimeProfiler.End("Server/Destruction/VoxelizePosition", voxelToken)

	if not ok then
		RuntimeProfiler.Count("Server/Destruction/VoxelizeErrors")
		warn("[DestructionService] Failed to voxelize explosion:", err)
		RuntimeProfiler.End("Server/Destruction/DestroySphere", token)
		return {}
	end

	local voxelOptions = buildVoxelOptions(options)
	debrisPayloads = batchDebrisPayloads(debrisPayloads, voxelOptions)

	local targetsHit = if typeof(debrisPayloads) == "table" and typeof(debrisPayloads.targetsHit) == "number"
		then debrisPayloads.targetsHit
		else #debrisPayloads
	if targetsHit > 0 then
		recordDestructionScore(sourceContext, targetsHit, position)
		recordMapDestruction(position, destructionRadius, sourceContext, debrisPayloads)
		notifyDestruction({
			position = position,
			radius = destructionRadius,
			sourceContext = sourceContext,
			targetsHit = targetsHit,
			debrisPayloads = debrisPayloads,
		})
	end

	RuntimeProfiler.Count("Server/Destruction/DestroySphereCalls")
	RuntimeProfiler.Count("Server/Destruction/TargetsHit", targetsHit)
	RuntimeProfiler.Count("Server/Destruction/DebrisPayloads", #debrisPayloads)
	RuntimeProfiler.End("Server/Destruction/DestroySphere", token)
	return debrisPayloads
end

local function appendDebrisPayloads(combined, payloads)
	if typeof(payloads) ~= "table" then
		return
	end

	for _, payload in ipairs(payloads) do
		table.insert(combined, payload)
	end

	local targetsHit = if typeof(payloads.targetsHit) == "number" then payloads.targetsHit else #payloads
	combined.targetsHit = (combined.targetsHit or 0) + targetsHit
end

function DestructionService:DestroyCylinderDown(position: Vector3, radius: number?, depth: number?, step: number?, sourceContext)
	local token = RuntimeProfiler.Begin("Server/Destruction/DestroyCylinderDown")
	if typeof(position) ~= "Vector3" then
		RuntimeProfiler.End("Server/Destruction/DestroyCylinderDown", token)
		return {}
	end

	local destructionRadius = if typeof(radius) == "number" and radius > 0
		then radius
		else BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius
	local destructionDepth = if typeof(depth) == "number" and depth > 0 then depth else destructionRadius
	local stepDistance = if typeof(step) == "number" and step > 0 then step else destructionRadius * 0.75
	stepDistance = math.max(stepDistance, DestructionConfig.FinalVoxelSize, 0.5)

	local combined = { targetsHit = 0 }
	local offset = 0
	while offset <= destructionDepth do
		appendDebrisPayloads(combined, self:DestroySphere(position - Vector3.yAxis * offset, destructionRadius, sourceContext))
		offset += stepDistance
	end

	if offset - stepDistance < destructionDepth then
		appendDebrisPayloads(combined, self:DestroySphere(position - Vector3.yAxis * destructionDepth, destructionRadius, sourceContext))
	end

	RuntimeProfiler.Count("Server/Destruction/DestroyCylinderDownCalls")
	RuntimeProfiler.Count("Server/Destruction/CylinderTargetsHit", combined.targetsHit or 0)
	RuntimeProfiler.End("Server/Destruction/DestroyCylinderDown", token)
	return combined
end
function DestructionService:Cleanup()
	VoxManager:cleanup()
	clearCurrentVoxelsFolder()
	self:RebuildTargetCache("Cleanup")
end

return DestructionService
