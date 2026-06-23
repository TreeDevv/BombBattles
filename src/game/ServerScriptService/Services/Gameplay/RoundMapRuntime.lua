local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local InstanceUtil = require(ReplicatedStorage.Shared.Common.InstanceUtil)
local MapScriptRuntime = require(ReplicatedStorage.Shared.Maps.MapScriptRuntime)

local DestructionService = require(script.Parent.DestructionService)

local RoundMapRuntime = {}

local PREPARED_MAPS_FOLDER_NAME = "_PreparedRoundMaps"
local ACTIVE_MAP_WORLD_OFFSET_ATTR = "RoundMapWorldOffset"

RoundMapRuntime.MapPrepFrameBudgetSeconds = 0.003
RoundMapRuntime.MapPrepSelectedWaitSeconds = 0.4
RoundMapRuntime.QueuedMapClones = {}

local preparedMapClones: { [string]: Model } = {}
local preparingMapClones: { [string]: boolean } = {}
local mapPreparationGeneration = 0
local activeMapScriptCleanup: (() -> ())? = nil

local function recordInstanceStats(prefix: string, root: Instance?)
	if not RuntimeProfiler.IsEnabled() or not root then
		return
	end

	local descendants = root:GetDescendants()
	local baseParts = 0
	local unanchoredBaseParts = 0
	local meshParts = 0
	local particleEmitters = 0
	local scripts = 0
	for _, descendant in ipairs(descendants) do
		if descendant:IsA("BasePart") then
			baseParts += 1
			if not descendant.Anchored then
				unanchoredBaseParts += 1
			end
			if descendant:IsA("MeshPart") then
				meshParts += 1
			end
		elseif descendant:IsA("ParticleEmitter") then
			particleEmitters += 1
		elseif descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
			scripts += 1
		end
	end

	RuntimeProfiler.Gauge(prefix .. "/Descendants", #descendants)
	RuntimeProfiler.Gauge(prefix .. "/BaseParts", baseParts)
	RuntimeProfiler.Gauge(prefix .. "/UnanchoredBaseParts", unanchoredBaseParts)
	RuntimeProfiler.Gauge(prefix .. "/MeshParts", meshParts)
	RuntimeProfiler.Gauge(prefix .. "/ParticleEmitters", particleEmitters)
	RuntimeProfiler.Gauge(prefix .. "/Scripts", scripts)
end

local function recordPreparationGauges()
	if not RuntimeProfiler.IsEnabled() then
		return
	end

	local preparedCount = 0
	for _, clone in pairs(preparedMapClones) do
		if clone and clone.Parent then
			preparedCount += 1
		end
	end
	local preparingCount = 0
	for _ in pairs(preparingMapClones) do
		preparingCount += 1
	end
	local queuedCount = 0
	for _ in pairs(RoundMapRuntime.QueuedMapClones) do
		queuedCount += 1
	end

	RuntimeProfiler.Gauge("Server/Round/Map/PreparedCloneCount", preparedCount)
	RuntimeProfiler.Gauge("Server/Round/Map/PreparingCloneCount", preparingCount)
	RuntimeProfiler.Gauge("Server/Round/Map/QueuedCloneCount", queuedCount)
end

local function recordWallDuration(label: string, startedAt: number)
	RuntimeProfiler.RecordDurationMs(label, (os.clock() - startedAt) * 1000)
end

local function getActiveMapWorldOffset(): Vector3
	local offset = RoundConfig.ActiveMapWorldOffset
	if typeof(offset) == "Vector3" then
		return offset
	end
	return Vector3.zero
end

local function placeActiveMap(map: Model)
	local targetOffset = getActiveMapWorldOffset()
	local appliedOffset = map:GetAttribute(ACTIVE_MAP_WORLD_OFFSET_ATTR)
	local currentOffset = if typeof(appliedOffset) == "Vector3" then appliedOffset else Vector3.zero
	local delta = targetOffset - currentOffset
	if delta.Magnitude <= 0.001 then
		return
	end

	map:PivotTo(map:GetPivot() + delta)
	map:SetAttribute(ACTIVE_MAP_WORLD_OFFSET_ATTR, targetOffset)
	pcall(function()
		map.ModelStreamingMode = Enum.ModelStreamingMode.Default
	end)
end

local function clearActiveMapScripts()
	local cleanup = activeMapScriptCleanup
	activeMapScriptCleanup = nil
	if cleanup then
		local token = RuntimeProfiler.Begin("Server/Round/Map/ClearActiveMapScripts")
		cleanup()
		RuntimeProfiler.End("Server/Round/Map/ClearActiveMapScripts", token)
	end
end

local function bindActiveMapScripts(mapId: string, map: Model)
	clearActiveMapScripts()
	local token = RuntimeProfiler.Begin("Server/Round/Map/BindMapScripts")
	activeMapScriptCleanup = MapScriptRuntime.Bind(mapId, map)
	RuntimeProfiler.End("Server/Round/Map/BindMapScripts", token)
	RuntimeProfiler.Count("Server/Round/Map/BindMapScriptsCalls")
end

local function getStoredMapTemplate(mapId: string, shouldWarn: boolean): Model?
	local folder = InstanceUtil.GetByPath(ReplicatedStorage, RoundConfig.MapsFolderPath)
	if not folder then
		if shouldWarn then
			warn("[RoundMapRuntime] Missing ReplicatedStorage." .. table.concat(RoundConfig.MapsFolderPath, "."))
		end
		return nil
	end

	local template = folder:FindFirstChild(mapId)
	if not template then
		if shouldWarn then
			warn("[RoundMapRuntime] Missing map template:", mapId)
		end
		return nil
	end
	if not template:IsA("Model") then
		if shouldWarn then
			warn("[RoundMapRuntime] Map template must be a Model:", template:GetFullName())
		end
		return nil
	end

	return template
end

local function getWorkspaceAuthoredMap(mapId: string): Model?
	local existing = workspace:FindFirstChild(mapId)
	if existing and existing:IsA("Model") then
		return existing
	end
	return nil
end

local function getPreparedMapsFolder(): Folder
	local existing = ServerStorage:FindFirstChild(PREPARED_MAPS_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = PREPARED_MAPS_FOLDER_NAME
	folder.Parent = ServerStorage
	return folder
end

function RoundMapRuntime.GetTemplate(mapId: string): Model?
	return getStoredMapTemplate(mapId, true)
end

function RoundMapRuntime.GetMapSource(mapId: string): Model?
	return getStoredMapTemplate(mapId, false) or getWorkspaceAuthoredMap(mapId)
end

function RoundMapRuntime.GetFirstConfiguredMapId(): string?
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		if RoundMapRuntime.GetMapSource(mapConfig.id) then
			return mapConfig.id
		end
	end

	return nil
end

function RoundMapRuntime.GetActiveMap(): Model?
	local active = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	if active and active:IsA("Model") then
		return active
	end
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		local map = getWorkspaceAuthoredMap(mapConfig.id)
		if map then
			return map
		end
	end
	return nil
end

function RoundMapRuntime.ClearActiveMap()
	clearActiveMapScripts()
	local active = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	if active then
		local token = RuntimeProfiler.Begin("Server/Round/Map/ClearActiveMap")
		recordInstanceStats("Server/Round/Map/ClearedActiveMap", active)
		active:Destroy()
		RuntimeProfiler.End("Server/Round/Map/ClearActiveMap", token)

		local cacheToken = RuntimeProfiler.Begin("Server/Round/Map/ClearActiveMapInvalidateCache")
		DestructionService:InvalidateTargetCache("MapCleared")
		RuntimeProfiler.End("Server/Round/Map/ClearActiveMapInvalidateCache", cacheToken)
	end
end

local function destroyPreparedMapClone(mapId: string)
	local clone = preparedMapClones[mapId]
	preparedMapClones[mapId] = nil
	preparingMapClones[mapId] = nil
	RoundMapRuntime.QueuedMapClones[mapId] = nil
	if clone and clone.Parent then
		recordInstanceStats("Server/Round/Map/DestroyedPreparedClone", clone)
		local token = RuntimeProfiler.Begin("Server/Round/Map/DestroyPreparedClone")
		clone:Destroy()
		RuntimeProfiler.End("Server/Round/Map/DestroyPreparedClone", token)
		RuntimeProfiler.Count("Server/Round/Map/PreparedCloneDestroyed")
	end
end

function RoundMapRuntime.ClearPreparedMapClones(exceptMapId: string?)
	local token = RuntimeProfiler.Begin("Server/Round/Map/ClearPreparedClones")
	if not exceptMapId then
		mapPreparationGeneration += 1
	end
	for mapId in pairs(preparedMapClones) do
		if mapId ~= exceptMapId then
			destroyPreparedMapClone(mapId)
		end
	end
	for mapId in pairs(RoundMapRuntime.QueuedMapClones) do
		if mapId ~= exceptMapId then
			RoundMapRuntime.QueuedMapClones[mapId] = nil
		end
	end
	recordPreparationGauges()
	RuntimeProfiler.End("Server/Round/Map/ClearPreparedClones", token)
end

local function prepareMapClone(mapId: string, generation: number): boolean
	if generation ~= mapPreparationGeneration then
		return false
	end
	if preparedMapClones[mapId] and preparedMapClones[mapId].Parent then
		RoundMapRuntime.QueuedMapClones[mapId] = nil
		return true
	end
	if preparingMapClones[mapId] then
		return false
	end

	local template = getStoredMapTemplate(mapId, false)
	if not template then
		RoundMapRuntime.QueuedMapClones[mapId] = nil
		return false
	end

	RoundMapRuntime.QueuedMapClones[mapId] = nil
	preparingMapClones[mapId] = true
	recordInstanceStats("Server/Round/Map/PrepareTemplate", template)
	local cloneToken = RuntimeProfiler.Begin("Server/Round/Map/PrepareClone")
	local clone = template:Clone()
	RuntimeProfiler.End("Server/Round/Map/PrepareClone", cloneToken)
	if generation ~= mapPreparationGeneration then
		clone:Destroy()
		preparingMapClones[mapId] = nil
		return false
	end
	clone.Name = mapId
	recordInstanceStats("Server/Round/Map/PreparedClone", clone)
	local parentToken = RuntimeProfiler.Begin("Server/Round/Map/ParentPreparedClone")
	clone.Parent = getPreparedMapsFolder()
	RuntimeProfiler.End("Server/Round/Map/ParentPreparedClone", parentToken)
	preparedMapClones[mapId] = clone
	preparingMapClones[mapId] = nil
	RuntimeProfiler.Count("Server/Round/Map/PreparedCloneReady")
	RuntimeProfiler.Count("Server/Round/Map/PreparedCloneReady/" .. mapId)
	recordPreparationGauges()
	return true
end

function RoundMapRuntime.PrepareVoteMapClones(choices: { { mapId: string } })
	local token = RuntimeProfiler.Begin("Server/Round/Map/PrepareVoteMapClones")
	mapPreparationGeneration += 1
	local generation = mapPreparationGeneration
	for mapId in pairs(RoundMapRuntime.QueuedMapClones) do
		RoundMapRuntime.QueuedMapClones[mapId] = nil
	end
	local mapIds = {}
	local seenMapIds = {}
	for _, choice in ipairs(choices) do
		if not seenMapIds[choice.mapId] then
			seenMapIds[choice.mapId] = true
			table.insert(mapIds, choice.mapId)
			RoundMapRuntime.QueuedMapClones[choice.mapId] = generation
		end
	end
	RuntimeProfiler.Gauge("Server/Round/Map/VoteChoiceCloneQueueSize", #mapIds)
	recordPreparationGauges()
	RuntimeProfiler.End("Server/Round/Map/PrepareVoteMapClones", token)

	task.spawn(function()
		local frameStartedAt = os.clock()
		for _, mapId in ipairs(mapIds) do
			if generation ~= mapPreparationGeneration then
				return
			end
			if RoundMapRuntime.QueuedMapClones[mapId] ~= generation then
				continue
			end
			if os.clock() - frameStartedAt >= RoundMapRuntime.MapPrepFrameBudgetSeconds then
				RuntimeProfiler.Count("Server/Round/Map/PrepBudgetYields")
				RunService.Heartbeat:Wait()
				frameStartedAt = os.clock()
			end
			prepareMapClone(mapId, generation)
			RuntimeProfiler.Count("Server/Round/Map/PrepBudgetYields")
			RunService.Heartbeat:Wait()
			frameStartedAt = os.clock()
		end
	end)
end

function RoundMapRuntime.WaitForPreparedMapClone(mapId: string, timeoutSeconds: number): boolean
	local waitStartedAt = os.clock()
	local deadline = os.clock() + math.max(timeoutSeconds, 0)
	while os.clock() < deadline do
		local clone = preparedMapClones[mapId]
		if clone and clone.Parent then
			RuntimeProfiler.Count("Server/Round/Map/SelectedPrepWaitHits")
			recordWallDuration("Server/Round/Map/WaitForPreparedCloneWall", waitStartedAt)
			RuntimeProfiler.Gauge("Server/Round/Map/LastSelectedPrepWaitMs", (os.clock() - waitStartedAt) * 1000)
			return true
		end
		if not preparingMapClones[mapId] and RoundMapRuntime.QueuedMapClones[mapId] ~= mapPreparationGeneration then
			recordWallDuration("Server/Round/Map/WaitForPreparedCloneWall", waitStartedAt)
			RuntimeProfiler.Gauge("Server/Round/Map/LastSelectedPrepWaitMs", (os.clock() - waitStartedAt) * 1000)
			return false
		end
		RuntimeProfiler.Count("Server/Round/Map/SelectedPrepWaitFrames")
		RunService.Heartbeat:Wait()
	end
	RuntimeProfiler.Count("Server/Round/Map/SelectedPrepWaitTimeouts")
	recordWallDuration("Server/Round/Map/WaitForPreparedCloneWall", waitStartedAt)
	RuntimeProfiler.Gauge("Server/Round/Map/LastSelectedPrepWaitMs", (os.clock() - waitStartedAt) * 1000)
	return false
end

local function takePreparedMapClone(mapId: string): Model?
	local token = RuntimeProfiler.Begin("Server/Round/Map/TakePreparedClone")
	local clone = preparedMapClones[mapId]
	preparedMapClones[mapId] = nil
	preparingMapClones[mapId] = nil
	RoundMapRuntime.QueuedMapClones[mapId] = nil
	mapPreparationGeneration += 1
	RoundMapRuntime.ClearPreparedMapClones(mapId)
	if clone and clone.Parent then
		RuntimeProfiler.End("Server/Round/Map/TakePreparedClone", token)
		recordPreparationGauges()
		return clone
	end
	RuntimeProfiler.End("Server/Round/Map/TakePreparedClone", token)
	recordPreparationGauges()
	return nil
end

function RoundMapRuntime.SpawnActiveMap(mapId: string): Model?
	local spawnStartedAt = os.clock()
	RuntimeProfiler.Count("Server/Round/Map/Selected/" .. mapId)
	local template = getStoredMapTemplate(mapId, false)

	RoundMapRuntime.ClearActiveMap()

	if not template then
		local workspaceMap = getWorkspaceAuthoredMap(mapId)
		if not workspaceMap then
			warn("[RoundMapRuntime] Missing map source:", mapId)
			recordWallDuration("Server/Round/Map/SpawnActiveMapWall", spawnStartedAt)
			return nil
		end

		RuntimeProfiler.Count("Server/Round/Map/WorkspaceAuthoredMap")
		recordInstanceStats("Server/Round/Map/WorkspaceAuthoredMap", workspaceMap)
		placeActiveMap(workspaceMap)
		local cacheToken = RuntimeProfiler.Begin("Server/Round/Map/RebuildDestructionCache")
		DestructionService:RebuildTargetCache("WorkspaceMapSelected")
		RuntimeProfiler.End("Server/Round/Map/RebuildDestructionCache", cacheToken)
		bindActiveMapScripts(mapId, workspaceMap)
		recordWallDuration("Server/Round/Map/SpawnActiveMapWall", spawnStartedAt)
		return workspaceMap
	end

	local clone = takePreparedMapClone(mapId)
	if clone then
		RuntimeProfiler.Count("Server/Round/Map/PreparedCloneHits")
	else
		RuntimeProfiler.Count("Server/Round/Map/PreparedCloneMisses")
		recordInstanceStats("Server/Round/Map/CloneTemplate", template)
		local cloneToken = RuntimeProfiler.Begin("Server/Round/Map/CloneTemplate")
		clone = template:Clone()
		RuntimeProfiler.End("Server/Round/Map/CloneTemplate", cloneToken)
	end

	clone.Name = RoundConfig.ActiveMapName
	placeActiveMap(clone)
	recordInstanceStats("Server/Round/Map/ActiveMapBeforeParent", clone)
	local parentToken = RuntimeProfiler.Begin("Server/Round/Map/ParentActiveMap")
	clone.Parent = workspace
	RuntimeProfiler.End("Server/Round/Map/ParentActiveMap", parentToken)
	recordInstanceStats("Server/Round/Map/ActiveMap", clone)

	local cacheToken = RuntimeProfiler.Begin("Server/Round/Map/RebuildDestructionCache")
	DestructionService:RebuildTargetCache("MapSpawned")
	RuntimeProfiler.End("Server/Round/Map/RebuildDestructionCache", cacheToken)
	bindActiveMapScripts(mapId, clone)
	recordWallDuration("Server/Round/Map/SpawnActiveMapWall", spawnStartedAt)
	return clone
end

return RoundMapRuntime
