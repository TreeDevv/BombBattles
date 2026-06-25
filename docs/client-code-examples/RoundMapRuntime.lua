local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local InstanceUtil = require(ReplicatedStorage.Shared.Common.InstanceUtil)
local MapScriptRuntime = require(ReplicatedStorage.Shared.Maps.MapScriptRuntime)

local DestructionService = require(script.Parent.DestructionService)

local RoundMapRuntime = {}

local PREPARED_MAPS_FOLDER_NAME = "_PreparedRoundMaps"
local ACTIVE_MAP_WORLD_OFFSET_ATTR = "RoundMapWorldOffset"

RoundMapRuntime.MapPrepFrameBudgetSeconds = 0.003
RoundMapRuntime.MapPrepSelectedWaitSeconds = 0.4

local preparedMapClones: { [string]: Model } = {}
local preparingMapClones: { [string]: boolean } = {}
local queuedMapClones: { [string]: number } = {}
local preparationGeneration = 0
local activeMapScriptCleanup: (() -> ())? = nil

local function getMapFolder(): Instance?
	return InstanceUtil.GetByPath(ReplicatedStorage, RoundConfig.MapsFolderPath)
end

local function getStoredMapTemplate(mapId: string, shouldWarn: boolean): Model?
	local folder = getMapFolder()
	local template = folder and folder:FindFirstChild(mapId)
	if template and template:IsA("Model") then
		return template
	end

	if shouldWarn then
		warn(("[RoundMapRuntime] Missing map template: %s"):format(mapId))
	end
	return nil
end

local function getWorkspaceAuthoredMap(mapId: string): Model?
	local map = workspace:FindFirstChild(mapId)
	return if map and map:IsA("Model") then map else nil
end

local function getPreparedMapsFolder(): Folder
	local folder = ServerStorage:FindFirstChild(PREPARED_MAPS_FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end
	if folder then
		folder:Destroy()
	end

	folder = Instance.new("Folder")
	folder.Name = PREPARED_MAPS_FOLDER_NAME
	folder.Parent = ServerStorage
	return folder
end

local function getActiveMapWorldOffset(): Vector3
	local offset = RoundConfig.ActiveMapWorldOffset
	return if typeof(offset) == "Vector3" then offset else Vector3.zero
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
		cleanup()
	end
end

local function bindActiveMapScripts(mapId: string, map: Model)
	clearActiveMapScripts()
	activeMapScriptCleanup = MapScriptRuntime.Bind(mapId, map)
end

local function destroyPreparedMapClone(mapId: string)
	local clone = preparedMapClones[mapId]
	preparedMapClones[mapId] = nil
	preparingMapClones[mapId] = nil
	queuedMapClones[mapId] = nil

	if clone and clone.Parent then
		clone:Destroy()
	end
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
	local activeMap = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	if activeMap and activeMap:IsA("Model") then
		return activeMap
	end

	for _, mapConfig in ipairs(RoundConfig.Maps) do
		local authoredMap = getWorkspaceAuthoredMap(mapConfig.id)
		if authoredMap then
			return authoredMap
		end
	end
	return nil
end

function RoundMapRuntime.ClearActiveMap()
	clearActiveMapScripts()

	local activeMap = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	if activeMap then
		activeMap:Destroy()
		DestructionService:InvalidateTargetCache("MapCleared")
	end
end

function RoundMapRuntime.ClearPreparedMapClones(exceptMapId: string?)
	if not exceptMapId then
		preparationGeneration += 1
	end

	for mapId in pairs(preparedMapClones) do
		if mapId ~= exceptMapId then
			destroyPreparedMapClone(mapId)
		end
	end

	for mapId in pairs(queuedMapClones) do
		if mapId ~= exceptMapId then
			queuedMapClones[mapId] = nil
		end
	end
end

local function prepareMapClone(mapId: string, generation: number): boolean
	if generation ~= preparationGeneration then
		return false
	end

	local existingClone = preparedMapClones[mapId]
	if existingClone and existingClone.Parent then
		queuedMapClones[mapId] = nil
		return true
	end
	if preparingMapClones[mapId] then
		return false
	end

	local template = getStoredMapTemplate(mapId, false)
	if not template then
		queuedMapClones[mapId] = nil
		return false
	end

	queuedMapClones[mapId] = nil
	preparingMapClones[mapId] = true

	local clone = template:Clone()
	if generation ~= preparationGeneration then
		clone:Destroy()
		preparingMapClones[mapId] = nil
		return false
	end

	clone.Name = mapId
	clone.Parent = getPreparedMapsFolder()
	preparedMapClones[mapId] = clone
	preparingMapClones[mapId] = nil
	return true
end

function RoundMapRuntime.PrepareVoteMapClones(choices: { { mapId: string } })
	preparationGeneration += 1
	local generation = preparationGeneration
	table.clear(queuedMapClones)

	local mapIds = {}
	local seenMapIds = {}
	for _, choice in ipairs(choices) do
		if not seenMapIds[choice.mapId] then
			seenMapIds[choice.mapId] = true
			queuedMapClones[choice.mapId] = generation
			table.insert(mapIds, choice.mapId)
		end
	end

	task.spawn(function()
		local frameStartedAt = os.clock()
		for _, mapId in ipairs(mapIds) do
			if generation ~= preparationGeneration then
				return
			end
			if queuedMapClones[mapId] ~= generation then
				continue
			end
			if os.clock() - frameStartedAt >= RoundMapRuntime.MapPrepFrameBudgetSeconds then
				RunService.Heartbeat:Wait()
				frameStartedAt = os.clock()
			end

			prepareMapClone(mapId, generation)
			RunService.Heartbeat:Wait()
			frameStartedAt = os.clock()
		end
	end)
end

function RoundMapRuntime.WaitForPreparedMapClone(mapId: string, timeoutSeconds: number): boolean
	local deadline = os.clock() + math.max(timeoutSeconds, 0)
	while os.clock() < deadline do
		local clone = preparedMapClones[mapId]
		if clone and clone.Parent then
			return true
		end
		if not preparingMapClones[mapId] and queuedMapClones[mapId] ~= preparationGeneration then
			return false
		end
		RunService.Heartbeat:Wait()
	end
	return false
end

local function takePreparedMapClone(mapId: string): Model?
	local clone = preparedMapClones[mapId]
	preparedMapClones[mapId] = nil
	preparingMapClones[mapId] = nil
	queuedMapClones[mapId] = nil

	preparationGeneration += 1
	RoundMapRuntime.ClearPreparedMapClones(mapId)

	return if clone and clone.Parent then clone else nil
end

function RoundMapRuntime.SpawnActiveMap(mapId: string): Model?
	local template = getStoredMapTemplate(mapId, false)
	RoundMapRuntime.ClearActiveMap()

	if not template then
		local authoredMap = getWorkspaceAuthoredMap(mapId)
		if not authoredMap then
			warn(("[RoundMapRuntime] Missing map source: %s"):format(mapId))
			return nil
		end

		placeActiveMap(authoredMap)
		DestructionService:RebuildTargetCache("WorkspaceMapSelected")
		bindActiveMapScripts(mapId, authoredMap)
		return authoredMap
	end

	local clone = takePreparedMapClone(mapId) or template:Clone()
	clone.Name = RoundConfig.ActiveMapName
	placeActiveMap(clone)
	clone.Parent = workspace

	DestructionService:RebuildTargetCache("MapSpawned")
	bindActiveMapScripts(mapId, clone)
	return clone
end

return RoundMapRuntime
