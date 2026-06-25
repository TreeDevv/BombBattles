local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local VoxManager = require(ReplicatedStorage.Packages.VoxManager)

local ReplayMapSimulator = {}

local SCENE_NAME = "_LocalReplayScene"
local PREPARED_SCENE_PREFIX = "_LocalReplayPreparedScene"
local MAP_FOLDER_NAME = "ReplayMap"
local CURRENT_VOXELS_FOLDER_NAME = "ReplayCurrentVoxels"
local DEBRIS_FOLDER_NAME = "ReplayDebris"
local LOCAL_REPLAY_ATTR = "BombBattlesLocalReplay"
local REPLAY_ZONE_PIVOT = CFrame.new(30000, 8000, 30000)

local MAX_TARGETS_PER_DESTRUCTION_EVENT = 24
local MAX_DEBRIS_PARTS_PER_EVENT = 36
local MAX_DEBRIS_PARTS_PER_REPLAY = 180
local MAX_DESTRUCTION_EVENTS_PER_STEP = 1
local DESTRUCTION_LEAD_SECONDS = 0.75

local preparedTemplates: { [string]: Instance } = {}
local preparedScenes: { [string]: { scene: Folder, mapContext: any } } = {}
local activePrewarmMapId: string? = nil
local activePrewarmSerial = 0
local prewarmRequested = false
local prewarmWorkerRunning = false

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteCFrame(value: any): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end

	for _, component in ipairs({ value:GetComponents() }) do
		if not isFiniteNumber(component) then
			return false
		end
	end
	return true
end

local function getMapTemplate(mapId: string): Instance?
	local current: Instance = ReplicatedStorage
	for _, folderName in ipairs(RoundConfig.MapsFolderPath) do
		current = current:FindFirstChild(folderName)
		if not current then
			return nil
		end
	end

	local template = current:FindFirstChild(mapId)
	return if template and (template:IsA("Model") or template:IsA("BasePart")) then template else nil
end

local function getLocalSceneSuffix(): string
	local localPlayer = Players.LocalPlayer
	return tostring(if localPlayer then localPlayer.UserId else "client")
end

local function cleanName(value: string): string
	return string.gsub(value, "[^%w_%-]", "_")
end

local function setReplayIdentity(instance: Instance?, mapId: string?, roundId: number?)
	if instance then
		instance:SetAttribute("ReplayMapId", mapId)
		instance:SetAttribute("ReplayRoundId", roundId)
	end
end

local function createPreparedScene(mapId: string): Folder
	local scene = Instance.new("Folder")
	scene.Name = ("%s_%s_%s"):format(PREPARED_SCENE_PREFIX, cleanName(mapId), getLocalSceneSuffix())
	scene:SetAttribute(LOCAL_REPLAY_ATTR, true)
	setReplayIdentity(scene, mapId, nil)
	return scene
end

local function prepareReplayMapClone(clone: Instance)
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = true
		elseif descendant:IsA("Sound") then
			descendant.Looped = false
			descendant:Stop()
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = false
		end
	end
end

local function pivotInstance(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function getPayloadMapId(payload): string?
	return if typeof(payload) == "table" and typeof(payload.mapId) == "string" and payload.mapId ~= ""
		then payload.mapId
		else nil
end

local function getPayloadRoundId(payload): number?
	return if typeof(payload) == "table" and isFiniteNumber(payload.roundId) then math.floor(payload.roundId) else nil
end

function ReplayMapSimulator.ScheduleDestroyScene(root: Instance?, _reason: string?)
	if typeof(root) ~= "Instance" then
		return false
	end

	root.Parent = nil
	task.defer(function()
		local stack = { root }
		while #stack > 0 do
			local instance = table.remove(stack)
			if instance then
				for _, child in ipairs(instance:GetChildren()) do
					table.insert(stack, child)
				end
				instance:Destroy()
			end
			if #stack % 96 == 0 then
				task.wait()
			end
		end
	end)
	return true
end

local function clearPreparedState(exceptMapId: string?)
	for mapId, template in pairs(preparedTemplates) do
		if mapId ~= exceptMapId then
			preparedTemplates[mapId] = nil
			template:Destroy()
		end
	end

	for mapId, entry in pairs(preparedScenes) do
		if mapId ~= exceptMapId then
			preparedScenes[mapId] = nil
			ReplayMapSimulator.Destroy(entry.mapContext)
			ReplayMapSimulator.ScheduleDestroyScene(entry.scene, "Prepared")
		end
	end
end

function ReplayMapSimulator.SetActivePrewarmMap(mapId: string?): string?
	if activePrewarmMapId == mapId then
		clearPreparedState(mapId)
		return mapId
	end

	activePrewarmMapId = mapId
	activePrewarmSerial += 1
	prewarmRequested = mapId ~= nil and prewarmRequested or false
	clearPreparedState(mapId)
	return mapId
end

function ReplayMapSimulator.PrewarmTemplate(mapId: string): boolean
	if activePrewarmMapId ~= mapId then
		return false
	end
	if preparedTemplates[mapId] then
		return true
	end

	local template = getMapTemplate(mapId)
	if not template then
		return false
	end

	local clone = template:Clone()
	clone.Name = RoundConfig.ActiveMapName
	setReplayIdentity(clone, mapId, nil)
	prepareReplayMapClone(clone)
	clone.Parent = nil
	preparedTemplates[mapId] = clone
	return true
end

local function takePreparedTemplate(mapId: string): Instance?
	local clone = preparedTemplates[mapId]
	preparedTemplates[mapId] = nil
	if clone then
		clone.Name = RoundConfig.ActiveMapName
		setReplayIdentity(clone, mapId, nil)
	end
	return clone
end

local function cloneMapTemplate(mapId: string?): Instance?
	if not mapId then
		return nil
	end

	local clone = takePreparedTemplate(mapId)
	if clone then
		return clone
	end

	local template = getMapTemplate(mapId)
	if not template then
		return nil
	end

	clone = template:Clone()
	clone.Name = RoundConfig.ActiveMapName
	setReplayIdentity(clone, mapId, nil)
	prepareReplayMapClone(clone)
	return clone
end

local function hasTaggedAncestor(instance: Instance, stopAt: Instance, tags): boolean
	local current: Instance? = instance
	while current and current ~= stopAt.Parent do
		for _, tagName in ipairs(tags) do
			if CollectionService:HasTag(current, tagName) then
				return true
			end
		end
		if current == stopAt then
			break
		end
		current = current.Parent
	end
	return false
end

local function collectDestructibleTargets(context): ({ BasePart }, boolean)
	local mapRoot = context and context.staticMapRoot
	if not mapRoot then
		return {}, false
	end

	local destructibleTargets = {}
	local fallbackTargets = {}
	for _, descendant in ipairs(mapRoot:GetDescendants()) do
		if not descendant:IsA("BasePart") then
			continue
		end
		if hasTaggedAncestor(descendant, mapRoot, UNSAFE_TAGS) then
			continue
		end

		table.insert(fallbackTargets, descendant)
		if hasTaggedAncestor(descendant, mapRoot, { DestructionConfig.Tag }) then
			table.insert(destructibleTargets, descendant)
		end
	end

	if #destructibleTargets > 0 then
		return destructibleTargets, false
	end
	return fallbackTargets, true
end

local function capTargets(targets: { BasePart }, origin: Vector3): { BasePart }
	if #targets <= MAX_TARGETS_PER_DESTRUCTION_EVENT then
		return targets
	end

	table.sort(targets, function(left, right)
		return (left.Position - origin).Magnitude < (right.Position - origin).Magnitude
	end)

	local capped = {}
	for index = 1, MAX_TARGETS_PER_DESTRUCTION_EVENT do
		capped[index] = targets[index]
	end
	return capped
end

function ReplayMapSimulator.Create(scene: Instance, payload)
	if type(VoxManager.resetTerrainState) == "function" then
		VoxManager:resetTerrainState()
	end

	local mapId = getPayloadMapId(payload)
	local roundId = getPayloadRoundId(payload)
	local context = {
		scene = scene,
		livePivot = if isFiniteCFrame(payload.mapPivot) then payload.mapPivot else CFrame.new(),
		replayPivot = REPLAY_ZONE_PIVOT,
		replayType = if typeof(payload.type) == "string" then payload.type else nil,
		mapId = mapId,
		roundId = roundId,
		debrisPartCount = 0,
		appliedDestructionEvents = 0,
		targetFailures = 0,
		applyFailures = 0,
		fallbackTargetUses = 0,
	}
	setReplayIdentity(scene, mapId, roundId)

	local mapFolder = Instance.new("Folder")
	mapFolder.Name = MAP_FOLDER_NAME
	mapFolder.Parent = scene
	setReplayIdentity(mapFolder, mapId, roundId)
	context.mapFolder = mapFolder

	local clone = cloneMapTemplate(mapId)
	if not clone then
		warn(("[ReplayMapSimulator] Missing replay map template: %s"):format(tostring(mapId)))
		return context
	end

	VoxManager:setDebrisConfig(DestructionConfig)
	VoxManager:setGeneratedVoxelTag(DestructionConfig.Tag)
	VoxManager:setTerrainConfig(DestructionConfig)

	pivotInstance(clone, context.replayPivot)
	clone.Parent = mapFolder

	local outputFolder = Instance.new("Folder")
	outputFolder.Name = CURRENT_VOXELS_FOLDER_NAME
	outputFolder.Parent = mapFolder

	local debrisFolder = Instance.new("Folder")
	debrisFolder.Name = DEBRIS_FOLDER_NAME
	debrisFolder.Parent = mapFolder

	context.mapRoot = mapFolder
	context.staticMapRoot = clone
	context.outputFolder = outputFolder
	context.debrisFolder = debrisFolder
	return context
end

function ReplayMapSimulator.PrewarmReusableScene(mapId: string): boolean
	ReplayMapSimulator.SetActivePrewarmMap(mapId)
	if preparedScenes[mapId] then
		return true
	end

	prewarmRequested = true
	if prewarmWorkerRunning then
		return true
	end

	prewarmWorkerRunning = true
	task.spawn(function()
		while prewarmRequested do
			prewarmRequested = false
			task.wait()

			local targetMapId = activePrewarmMapId
			if not targetMapId or not getMapTemplate(targetMapId) then
				continue
			end

			local serial = activePrewarmSerial
			ReplayMapSimulator.PrewarmTemplate(targetMapId)
			task.wait()
			if activePrewarmMapId ~= targetMapId or activePrewarmSerial ~= serial then
				continue
			end

			local scene = createPreparedScene(targetMapId)
			local mapContext = ReplayMapSimulator.Create(scene, {
				mapId = targetMapId,
				mapPivot = CFrame.new(),
			})
			if activePrewarmMapId ~= targetMapId or activePrewarmSerial ~= serial then
				ReplayMapSimulator.ScheduleDestroyScene(scene, "CanceledPrewarm")
				continue
			end

			preparedScenes[targetMapId] = {
				scene = scene,
				mapContext = mapContext,
			}
		end
		prewarmWorkerRunning = false
	end)
	return true
end

function ReplayMapSimulator.PrewarmActiveScene(mapId: string?): boolean
	if not mapId then
		ReplayMapSimulator.SetActivePrewarmMap(nil)
		return false
	end
	return ReplayMapSimulator.PrewarmReusableScene(mapId)
end

function ReplayMapSimulator.TakePreparedScene(payload): (Folder?, any?)
	local mapId = getPayloadMapId(payload)
	if not mapId then
		return nil, nil
	end

	local entry = preparedScenes[mapId]
	if not entry then
		return nil, nil
	end

	preparedScenes[mapId] = nil
	local existingScene = Workspace:FindFirstChild(SCENE_NAME)
	if existingScene and existingScene ~= entry.scene then
		ReplayMapSimulator.ScheduleDestroyScene(existingScene, "ExistingActive")
	end

	entry.scene.Name = SCENE_NAME
	entry.scene:SetAttribute(LOCAL_REPLAY_ATTR, true)
	entry.scene.Parent = Workspace

	entry.mapContext.scene = entry.scene
	entry.mapContext.livePivot = if isFiniteCFrame(payload.mapPivot) then payload.mapPivot else CFrame.new()
	entry.mapContext.replayType = if typeof(payload.type) == "string" then payload.type else nil
	entry.mapContext.roundId = getPayloadRoundId(payload)
	return entry.scene, entry.mapContext
end

function ReplayMapSimulator.TransformPosition(context, position: Vector3): Vector3
	local localSpace = context.livePivot:PointToObjectSpace(position)
	return context.replayPivot:PointToWorldSpace(localSpace)
end

function ReplayMapSimulator.TransformCFrame(context, cframe: CFrame): CFrame
	return context.replayPivot * context.livePivot:ToObjectSpace(cframe)
end

function ReplayMapSimulator.TransformFrames(context, frames)
	local transformed = {}
	for _, frame in ipairs(frames or {}) do
		local copy = table.clone(frame)
		copy.players = {}
		copy.bombs = {}

		for _, snapshot in ipairs(frame.players or {}) do
			local snapshotCopy = table.clone(snapshot)
			if typeof(snapshotCopy.cframe) == "CFrame" then
				snapshotCopy.cframe = ReplayMapSimulator.TransformCFrame(context, snapshotCopy.cframe)
			end
			table.insert(copy.players, snapshotCopy)
		end

		for _, snapshot in ipairs(frame.bombs or {}) do
			local snapshotCopy = table.clone(snapshot)
			if typeof(snapshotCopy.cframe) == "CFrame" then
				snapshotCopy.cframe = ReplayMapSimulator.TransformCFrame(context, snapshotCopy.cframe)
			elseif typeof(snapshotCopy.position) == "Vector3" then
				snapshotCopy.position = ReplayMapSimulator.TransformPosition(context, snapshotCopy.position)
			end
			table.insert(copy.bombs, snapshotCopy)
		end

		table.insert(transformed, copy)
	end
	return transformed
end

function ReplayMapSimulator.NormalizeDestructionEvents(context, rawEvents, startTime: number?, endTime: number?)
	local events = {}
	local minTime = if isFiniteNumber(startTime) then startTime - DESTRUCTION_LEAD_SECONDS else nil

	for _, event in ipairs(rawEvents or {}) do
		if not isFiniteNumber(event.timestamp) then
			continue
		end
		if minTime and event.timestamp < minTime then
			continue
		end
		if isFiniteNumber(endTime) and event.timestamp > endTime then
			continue
		end

		local position = event.position
		if typeof(position) ~= "Vector3" and isFiniteCFrame(event.cframe) then
			position = event.cframe.Position
		end
		if typeof(position) ~= "Vector3" or not (isFiniteNumber(event.radius) and event.radius > 0) then
			continue
		end

		table.insert(events, {
			timestamp = event.timestamp,
			sequence = if isFiniteNumber(event.sequence) then math.floor(event.sequence) else #events + 1,
			position = ReplayMapSimulator.TransformPosition(context, position),
			radius = math.clamp(event.radius, 1, 80),
			sourceId = event.sourceId,
			sourceType = event.sourceType,
			debrisPayloads = event.debrisPayloads,
		})
	end

	table.sort(events, function(left, right)
		return left.timestamp == right.timestamp and left.sequence < right.sequence or left.timestamp < right.timestamp
	end)
	return events
end

function ReplayMapSimulator.ApplyDestructionEvent(context, event, options): boolean
	if not (context and context.outputFolder and typeof(event.position) == "Vector3") then
		return false
	end

	local targets, usedFallbackTargets = collectDestructibleTargets(context)
	if #targets == 0 then
		context.targetFailures += 1
		return false
	end
	if usedFallbackTargets then
		context.fallbackTargetUses += 1
	end

	local eventMaxDebris = math.min(MAX_DEBRIS_PARTS_PER_EVENT, MAX_DEBRIS_PARTS_PER_REPLAY - context.debrisPartCount)
	local voxelizeOptions = if options and options.spawnDebris and eventMaxDebris > 0
		then {
			forceSpawnDebris = true,
			debrisFolder = context.debrisFolder,
			maxDebrisParts = eventMaxDebris,
			useGraphicsQualitySampling = false,
			forceVisible = true,
		}
		else nil

	local result
	local ok, err = pcall(function()
		result = VoxManager:voxelizePosition(
			event.position,
			event.radius,
			DestructionConfig.MinVoxelSize,
			DestructionConfig.FinalVoxelSize,
			DestructionConfig.RandomColor,
			voxelizeOptions ~= nil,
			DestructionConfig.DebrisAmount,
			{},
			capTargets(targets, event.position),
			context.outputFolder,
			voxelizeOptions
		)
	end)
	if not ok then
		context.applyFailures += 1
		warn("[ReplayMapSimulator] Failed to apply replay destruction: " .. tostring(err))
		return false
	end

	if typeof(result) == "table" and isFiniteNumber(result.debrisPartsSpawned) then
		context.debrisPartCount += result.debrisPartsSpawned
	end
	context.appliedDestructionEvents += 1
	return true
end

function ReplayMapSimulator.ApplyEventsUpTo(context, events, replayTime: number, startIndex: number?, options): number
	local index = if isFiniteNumber(startIndex) then math.max(math.floor(startIndex), 1) else 1
	local processed = 0
	local maxEvents = if options and isFiniteNumber(options.maxEvents) then math.max(math.floor(options.maxEvents), 0) else math.huge

	while index <= #(events or {}) and processed < maxEvents do
		local event = events[index]
		if event.timestamp > replayTime then
			break
		end
		ReplayMapSimulator.ApplyDestructionEvent(context, event, options)
		index += 1
		processed += 1
	end
	return index
end

function ReplayMapSimulator.GetMaxDestructionEventsPerStep(): number
	return MAX_DESTRUCTION_EVENTS_PER_STEP
end

function ReplayMapSimulator.Destroy(_context)
	if type(VoxManager.resetTerrainState) == "function" then
		VoxManager:resetTerrainState()
	end
	if type(VoxManager.cleanupVoxelCache) == "function" then
		VoxManager:cleanupVoxelCache()
	end
end

function ReplayMapSimulator.GetDebugInfo(context)
	return {
		mapId = context and context.mapId,
		replayType = context and context.replayType,
		appliedDestructionEvents = context and context.appliedDestructionEvents or 0,
		targetFailures = context and context.targetFailures or 0,
		applyFailures = context and context.applyFailures or 0,
		fallbackTargetUses = context and context.fallbackTargetUses or 0,
		debrisPartCount = context and context.debrisPartCount or 0,
	}
end

return ReplayMapSimulator
