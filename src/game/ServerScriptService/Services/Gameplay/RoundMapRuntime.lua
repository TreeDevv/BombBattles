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

RoundMapRuntime.MapPrepFrameBudgetSeconds = 0.003
RoundMapRuntime.MapPrepSelectedWaitSeconds = 0.4
RoundMapRuntime.QueuedMapClones = {}

local preparedMapClones: { [string]: Model } = {}
local preparingMapClones: { [string]: boolean } = {}
local mapPreparationGeneration = 0
local activeMapScriptCleanup: (() -> ())? = nil

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
		active:Destroy()
		DestructionService:InvalidateTargetCache("MapCleared")
		RuntimeProfiler.End("Server/Round/Map/ClearActiveMap", token)
	end
end

local function destroyPreparedMapClone(mapId: string)
	local clone = preparedMapClones[mapId]
	preparedMapClones[mapId] = nil
	preparingMapClones[mapId] = nil
	RoundMapRuntime.QueuedMapClones[mapId] = nil
	if clone and clone.Parent then
		clone:Destroy()
	end
end

function RoundMapRuntime.ClearPreparedMapClones(exceptMapId: string?)
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
	local cloneToken = RuntimeProfiler.Begin("Server/Round/Map/PrepareClone")
	local clone = template:Clone()
	RuntimeProfiler.End("Server/Round/Map/PrepareClone", cloneToken)
	if generation ~= mapPreparationGeneration then
		clone:Destroy()
		preparingMapClones[mapId] = nil
		return false
	end
	clone.Name = mapId
	clone.Parent = getPreparedMapsFolder()
	preparedMapClones[mapId] = clone
	preparingMapClones[mapId] = nil
	RuntimeProfiler.Count("Server/Round/Map/PreparedCloneReady")
	return true
end

function RoundMapRuntime.PrepareVoteMapClones(choices: { { mapId: string } })
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
	local deadline = os.clock() + math.max(timeoutSeconds, 0)
	while os.clock() < deadline do
		local clone = preparedMapClones[mapId]
		if clone and clone.Parent then
			RuntimeProfiler.Count("Server/Round/Map/SelectedPrepWaitHits")
			return true
		end
		if not preparingMapClones[mapId] and RoundMapRuntime.QueuedMapClones[mapId] ~= mapPreparationGeneration then
			return false
		end
		RuntimeProfiler.Count("Server/Round/Map/SelectedPrepWaitFrames")
		RunService.Heartbeat:Wait()
	end
	RuntimeProfiler.Count("Server/Round/Map/SelectedPrepWaitTimeouts")
	return false
end

local function takePreparedMapClone(mapId: string): Model?
	local clone = preparedMapClones[mapId]
	preparedMapClones[mapId] = nil
	preparingMapClones[mapId] = nil
	RoundMapRuntime.QueuedMapClones[mapId] = nil
	mapPreparationGeneration += 1
	RoundMapRuntime.ClearPreparedMapClones(mapId)
	if clone and clone.Parent then
		return clone
	end
	return nil
end

function RoundMapRuntime.SpawnActiveMap(mapId: string): Model?
	local template = getStoredMapTemplate(mapId, false)

	RoundMapRuntime.ClearActiveMap()

	if not template then
		local workspaceMap = getWorkspaceAuthoredMap(mapId)
		if not workspaceMap then
			warn("[RoundMapRuntime] Missing map source:", mapId)
			return nil
		end

		RuntimeProfiler.Count("Server/Round/Map/WorkspaceAuthoredMap")
		local cacheToken = RuntimeProfiler.Begin("Server/Round/Map/RebuildDestructionCache")
		DestructionService:RebuildTargetCache("WorkspaceMapSelected")
		RuntimeProfiler.End("Server/Round/Map/RebuildDestructionCache", cacheToken)
		bindActiveMapScripts(mapId, workspaceMap)
		return workspaceMap
	end

	local clone = takePreparedMapClone(mapId)
	if clone then
		RuntimeProfiler.Count("Server/Round/Map/PreparedCloneHits")
	else
		RuntimeProfiler.Count("Server/Round/Map/PreparedCloneMisses")
		local cloneToken = RuntimeProfiler.Begin("Server/Round/Map/CloneTemplate")
		clone = template:Clone()
		RuntimeProfiler.End("Server/Round/Map/CloneTemplate", cloneToken)
	end

	clone.Name = RoundConfig.ActiveMapName
	local parentToken = RuntimeProfiler.Begin("Server/Round/Map/ParentActiveMap")
	clone.Parent = workspace
	RuntimeProfiler.End("Server/Round/Map/ParentActiveMap", parentToken)

	local cacheToken = RuntimeProfiler.Begin("Server/Round/Map/RebuildDestructionCache")
	DestructionService:RebuildTargetCache("MapSpawned")
	RuntimeProfiler.End("Server/Round/Map/RebuildDestructionCache", cacheToken)
	bindActiveMapScripts(mapId, clone)
	return clone
end

return RoundMapRuntime
