local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local VoxManager = require(ReplicatedStorage.Packages.VoxManager)
local VoxelDebris = require(ReplicatedStorage.Packages.VoxManager.Voxelizer.Debris)

local ReplayMapSimulator = {}

local MAP_FOLDER_NAME = "ReplayMap"
local CURRENT_VOXELS_FOLDER_NAME = "ReplayCurrentVoxels"
local DEBRIS_FOLDER_NAME = "ReplayDebris"
local SCENE_NAME = "_LocalReplayScene"
local PREPARED_SCENE_NAME_PREFIX = "_LocalReplayPreparedScene"
local LOCAL_REPLAY_ATTR = "BombBattlesLocalReplay"
local REPLAY_ZONE_PIVOT = CFrame.new(30000, 8000, 30000)
local MAX_DESTRUCTION_EVENTS = 260
local MAX_DESTRUCTION_EVENTS_PER_STEP = 3
local MAX_DEBRIS_PARTS_PER_EVENT = 36
local MAX_DEBRIS_PARTS_PER_REPLAY = 180
local MAX_PREPARED_MAP_TEMPLATES = 4
local MAX_PREPARED_REUSABLE_SCENES = 1
local DEBRIS_LIFETIME_SCALE = 0.85

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local preparedTemplateCache = {}
local preparedTemplateOrder = {}
local preparedSceneCache = {}
local preparedSceneOrder = {}
local preparedSceneInProgress = {}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteCFrame(value: any): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end

	local components = { value:GetComponents() }
	for _, component in ipairs(components) do
		if not isFiniteNumber(component) then
			return false
		end
	end
	return true
end

local function getMapFolder(): Instance?
	local current: Instance = ReplicatedStorage
	for _, name in ipairs(RoundConfig.MapsFolderPath) do
		if typeof(name) ~= "string" or name == "" then
			return nil
		end

		local nextInstance = current:FindFirstChild(name)
		if not nextInstance then
			return nil
		end
		current = nextInstance
	end
	return current
end

local function getMapTemplate(mapId: any): Instance?
	if typeof(mapId) ~= "string" or mapId == "" then
		return nil
	end

	local folder = getMapFolder()
	local template = folder and folder:FindFirstChild(mapId)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

local function getLocalSceneSuffix(): string
	local localPlayer = Players.LocalPlayer
	return tostring(if localPlayer then localPlayer.UserId else "client")
end

local function sanitizeMapIdForName(mapId: any): string
	local raw = if typeof(mapId) == "string" and mapId ~= "" then mapId else "Unknown"
	return string.gsub(raw, "[^%w_%-]", "_")
end

local function createPreparedScene(mapId: string): Folder
	local scene = Instance.new("Folder")
	scene.Name = ("%s_%s_%s"):format(PREPARED_SCENE_NAME_PREFIX, sanitizeMapIdForName(mapId), getLocalSceneSuffix())
	scene:SetAttribute(LOCAL_REPLAY_ATTR, true)
	scene:SetAttribute("ReplayMapId", mapId)
	scene.Parent = Workspace
	return scene
end

local function destroyPreparedSceneEntry(entry)
	if not entry then
		return
	end
	if entry.mapContext then
		pcall(function()
			ReplayMapSimulator.Destroy(entry.mapContext)
		end)
	end
	if entry.scene then
		entry.scene:Destroy()
	end
end

local function getPreferredMapIds(limit: number?): { string }
	local ids = {}
	local seen = {}
	local maxIds = math.max(math.floor(limit or MAX_PREPARED_REUSABLE_SCENES), 1)

	for _, mapConfig in ipairs(RoundConfig.Maps or {}) do
		local mapId = if typeof(mapConfig) == "table" then mapConfig.id else nil
		if typeof(mapId) == "string" and mapId ~= "" and not seen[mapId] then
			seen[mapId] = true
			table.insert(ids, mapId)
			if #ids >= maxIds then
				return ids
			end
		end
	end

	local folder = getMapFolder()
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if (child:IsA("Model") or child:IsA("BasePart")) and not seen[child.Name] then
				seen[child.Name] = true
				table.insert(ids, child.Name)
				if #ids >= maxIds then
					return ids
				end
			end
		end
	end

	return ids
end

local function pivotInstance(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function prepareMapClone(instance: Instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
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

	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = true
	end
end

local function rememberPreparedTemplate(mapId: string, clone: Instance)
	local existing = preparedTemplateCache[mapId]
	if existing == clone then
		return clone
	end
	if existing then
		existing:Destroy()
	end
	if not preparedTemplateCache[mapId] then
		table.insert(preparedTemplateOrder, mapId)
	end
	preparedTemplateCache[mapId] = clone
	clone.Parent = nil

	while #preparedTemplateOrder > MAX_PREPARED_MAP_TEMPLATES do
		local oldMapId = table.remove(preparedTemplateOrder, 1)
		local oldTemplate = oldMapId and preparedTemplateCache[oldMapId]
		preparedTemplateCache[oldMapId] = nil
		if oldTemplate then
			oldTemplate:Destroy()
		end
	end
	return clone
end

function ReplayMapSimulator.PrewarmTemplate(mapId: any): boolean
	if typeof(mapId) ~= "string" or mapId == "" then
		return false
	end
	local existing = preparedTemplateCache[mapId]
	if existing and existing.Parent == nil then
		return true
	end

	local template = getMapTemplate(mapId)
	if not template then
		return false
	end

	local token = RuntimeProfiler.Begin("Client/Replay/MapSimulator/PrewarmTemplate")
	local clone = template:Clone()
	clone.Name = RoundConfig.ActiveMapName
	prepareMapClone(clone)
	rememberPreparedTemplate(mapId, clone)
	RuntimeProfiler.Count("Client/Replay/MapSimulator/PrewarmedTemplates")
	RuntimeProfiler.End("Client/Replay/MapSimulator/PrewarmTemplate", token)
	return true
end

function ReplayMapSimulator.PrewarmTemplates()
	local folder = getMapFolder()
	if not folder then
		return
	end

	task.spawn(function()
		task.wait(1)
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") or child:IsA("BasePart") then
				ReplayMapSimulator.PrewarmTemplate(child.Name)
				task.wait()
			end
		end
	end)
end

local function clonePreparedMapTemplate(mapId: any): Instance?
	if typeof(mapId) ~= "string" or mapId == "" then
		return nil
	end

	local preparedTemplate = preparedTemplateCache[mapId]
	if preparedTemplate and preparedTemplate.Parent == nil then
		local ok, clone = pcall(function()
			return preparedTemplate:Clone()
		end)
		if ok and clone then
			RuntimeProfiler.Count("Client/Replay/MapSimulator/PreparedTemplateClones")
			return clone
		end
		preparedTemplateCache[mapId] = nil
	end

	local template = getMapTemplate(mapId)
	if not template then
		return nil
	end
	local clone = template:Clone()
	clone.Name = RoundConfig.ActiveMapName
	prepareMapClone(clone)
	RuntimeProfiler.Count("Client/Replay/MapSimulator/ColdTemplateClones")
	return clone
end

local function sanitizeGeneratedVoxels(root: Instance?)
	if not root then
		return
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = true
		end
	end
end

local function hasUnsafeTaggedAncestor(instance: Instance, stopAt: Instance): boolean
	local current: Instance? = instance
	while current and current ~= stopAt.Parent do
		for _, tagName in ipairs(UNSAFE_TAGS) do
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

local function hasDestructibleTag(instance: Instance, stopAt: Instance): boolean
	local current: Instance? = instance
	while current and current ~= stopAt.Parent do
		if CollectionService:HasTag(current, DestructionConfig.Tag) then
			return true
		end
		if current == stopAt then
			break
		end
		current = current.Parent
	end
	return false
end

local function addTarget(targets: { BasePart }, seen: { [BasePart]: boolean }, part: BasePart)
	if seen[part] then
		return
	end
	seen[part] = true
	table.insert(targets, part)
end

local function isReplayMapPart(part: BasePart, mapRoot: Instance): boolean
	if part.Name == "VoxManagerHitbox" then
		return false
	end
	if part:IsDescendantOf(mapRoot) ~= true then
		return false
	end
	if hasUnsafeTaggedAncestor(part, mapRoot) then
		return false
	end
	return true
end

local function buildStaticDestructibleTargets(context): ({ BasePart }, boolean)
	local staticRoot = context and context.staticMapRoot
	if not staticRoot then
		return {}, false
	end

	local targets = {}
	local seen = {}
	for _, descendant in ipairs(staticRoot:GetDescendants()) do
		if not descendant:IsA("BasePart") then
			continue
		end
		if not isReplayMapPart(descendant, staticRoot) then
			continue
		end
		if hasDestructibleTag(descendant, staticRoot) then
			addTarget(targets, seen, descendant)
		end
	end

	if #targets > 0 then
		return targets, false
	end

	for _, descendant in ipairs(staticRoot:GetDescendants()) do
		if descendant:IsA("BasePart") and isReplayMapPart(descendant, staticRoot) then
			addTarget(targets, seen, descendant)
		end
	end

	return targets, true
end

local function addLiveCachedTargets(targets: { BasePart }, seen: { [BasePart]: boolean }, source)
	for _, part in ipairs(source or {}) do
		if part and part.Parent then
			addTarget(targets, seen, part)
		end
	end
end

local function collectGeneratedVoxelTargets(context, targets: { BasePart }, seen: { [BasePart]: boolean })
	local outputFolder = context and context.outputFolder
	if not outputFolder then
		return
	end

	for _, descendant in ipairs(outputFolder:GetDescendants()) do
		if descendant:IsA("BasePart") then
			addTarget(targets, seen, descendant)
		end
	end
end

local function collectDestructibleTargets(context): ({ BasePart }, boolean)
	if not (context and context.mapRoot) then
		return {}, false
	end

	if not context.staticTargets then
		local staticTargets, usedFallbackTargets = buildStaticDestructibleTargets(context)
		context.staticTargets = staticTargets
		context.staticUsedFallbackTargets = usedFallbackTargets
		context.staticTargetCount = #staticTargets
	end

	local targets = {}
	local seen = {}
	addLiveCachedTargets(targets, seen, context.staticTargets)
	collectGeneratedVoxelTargets(context, targets, seen)
	return targets, context.staticUsedFallbackTargets == true
end

function ReplayMapSimulator.TransformPoint(context, point: Vector3): Vector3
	return context.replayPivot:PointToWorldSpace(context.livePivot:PointToObjectSpace(point))
end

function ReplayMapSimulator.TransformVector(context, vector: Vector3): Vector3
	return context.replayPivot:VectorToWorldSpace(context.livePivot:VectorToObjectSpace(vector))
end

function ReplayMapSimulator.TransformCFrame(context, cframe: CFrame): CFrame
	return context.replayPivot * context.livePivot:ToObjectSpace(cframe)
end

local function copyDebrisPayloadBlock(context, block)
	if typeof(block) ~= "table" or typeof(block.size) ~= "Vector3" then
		return nil
	end
	if typeof(block.cframe) == "CFrame" then
		return {
			cframe = ReplayMapSimulator.TransformCFrame(context, block.cframe),
			size = block.size,
		}
	end
	if typeof(block.center) ~= "Vector3" then
		return nil
	end

	return {
		center = block.center,
		size = block.size,
	}
end

local function transformDebrisPayload(context, payload)
	if typeof(payload) ~= "table" then
		return nil
	end
	if not (isFiniteCFrame(payload.sourceCFrame) and typeof(payload.explosionPosition) == "Vector3") then
		return nil
	end
	if typeof(payload.blocks) ~= "table" or #payload.blocks == 0 then
		return nil
	end

	local blocks = {}
	for _, block in ipairs(payload.blocks) do
		local copiedBlock = copyDebrisPayloadBlock(context, block)
		if copiedBlock then
			table.insert(blocks, copiedBlock)
		end
	end
	if #blocks == 0 then
		return nil
	end

	local transformed = {
		sourceCFrame = ReplayMapSimulator.TransformCFrame(context, payload.sourceCFrame),
		explosionPosition = ReplayMapSimulator.TransformPoint(context, payload.explosionPosition),
		blocks = blocks,
	}
	for _, fieldName in ipairs({
		"materialName",
		"color",
		"transparency",
		"reflectance",
		"speedMin",
		"speedMax",
		"lifetime",
		"useGraphicsQualitySampling",
		"automaticQualityLevel",
		"maxSamplingDivisor",
		"seed",
	}) do
		transformed[fieldName] = payload[fieldName]
	end
	return transformed
end

local function transformDebrisPayloads(context, payloads)
	if typeof(payloads) ~= "table" then
		return nil
	end

	local results = {}
	for _, payload in ipairs(payloads) do
		local transformed = transformDebrisPayload(context, payload)
		if transformed then
			table.insert(results, transformed)
		end
	end
	return if #results > 0 then results else nil
end

local function transformSnapshot(context, snapshot)
	if typeof(snapshot) ~= "table" then
		return
	end

	if isFiniteCFrame(snapshot.cframe) then
		snapshot.cframe = ReplayMapSimulator.TransformCFrame(context, snapshot.cframe)
	end
	if isFiniteCFrame(snapshot.serverCFrame) then
		snapshot.serverCFrame = ReplayMapSimulator.TransformCFrame(context, snapshot.serverCFrame)
	end
	if typeof(snapshot.position) == "Vector3" then
		snapshot.position = ReplayMapSimulator.TransformPoint(context, snapshot.position)
	end

	for _, fieldName in ipairs({ "velocity", "assemblyLinearVelocity", "linearVelocity" }) do
		if typeof(snapshot[fieldName]) == "Vector3" then
			snapshot[fieldName] = ReplayMapSimulator.TransformVector(context, snapshot[fieldName])
		end
	end

	local animationState = snapshot.animationState
	if typeof(animationState) == "table" and typeof(animationState.linearVelocity) == "Vector3" then
		animationState.linearVelocity = ReplayMapSimulator.TransformVector(context, animationState.linearVelocity)
	end

	local camera = snapshot.camera
	if typeof(camera) == "table" then
		if isFiniteCFrame(camera.cframe) then
			camera.cframe = ReplayMapSimulator.TransformCFrame(context, camera.cframe)
		end
		if isFiniteCFrame(camera.focus) then
			camera.focus = ReplayMapSimulator.TransformCFrame(context, camera.focus)
		end
	end

end

function ReplayMapSimulator.TransformFrames(context, frames)
	if typeof(frames) ~= "table" then
		return frames
	end

	for _, frame in ipairs(frames) do
		if typeof(frame.players) == "table" then
			for _, snapshot in pairs(frame.players) do
				transformSnapshot(context, snapshot)
			end
		end
		if typeof(frame.bombs) == "table" then
			for _, snapshot in pairs(frame.bombs) do
				transformSnapshot(context, snapshot)
			end
		end
	end
	return frames
end

local function transformEvent(context, event)
	if typeof(event) ~= "table" then
		return
	end

	if typeof(event.position) == "Vector3" then
		event.position = ReplayMapSimulator.TransformPoint(context, event.position)
	end
	if isFiniteCFrame(event.cframe) then
		event.cframe = ReplayMapSimulator.TransformCFrame(context, event.cframe)
	end

	for _, fieldName in ipairs({ "origin", "targetPosition", "startPosition", "endPosition" }) do
		if typeof(event[fieldName]) == "Vector3" then
			event[fieldName] = ReplayMapSimulator.TransformPoint(context, event[fieldName])
		end
	end
	for _, fieldName in ipairs({ "velocity", "initialVelocity", "acceleration" }) do
		if typeof(event[fieldName]) == "Vector3" then
			event[fieldName] = ReplayMapSimulator.TransformVector(context, event[fieldName])
		end
	end
end

function ReplayMapSimulator.TransformEvents(context, events)
	if typeof(events) ~= "table" then
		return events
	end

	for _, event in ipairs(events) do
		transformEvent(context, event)
	end
	return events
end

function ReplayMapSimulator.NormalizeDestructionEvents(context, rawEvents, endTime: number)
	local events = {}
	if typeof(rawEvents) ~= "table" then
		if context then
			context.normalizedDestructionEvents = 0
		end
		return events
	end

	for _, event in ipairs(rawEvents) do
		if #events >= MAX_DESTRUCTION_EVENTS then
			break
		end
		if typeof(event) ~= "table" or not isFiniteNumber(event.timestamp) then
			continue
		end
		if isFiniteNumber(endTime) and event.timestamp > endTime then
			continue
		end

		local position = if typeof(event.position) == "Vector3"
			then event.position
			elseif isFiniteCFrame(event.cframe)
			then event.cframe.Position
			else nil
		local radius = event.radius
		if typeof(position) ~= "Vector3" or not (isFiniteNumber(radius) and radius > 0) then
			continue
		end

		table.insert(events, {
			timestamp = event.timestamp,
			sequence = if isFiniteNumber(event.sequence) then math.floor(event.sequence) else #events + 1,
			position = ReplayMapSimulator.TransformPoint(context, position),
			radius = math.clamp(radius, 1, 80),
			sourceId = event.sourceId,
			debrisPayloads = transformDebrisPayloads(context, event.debrisPayloads),
		})
	end

	table.sort(events, function(left, right)
		if left.timestamp == right.timestamp then
			return (left.sequence or 0) < (right.sequence or 0)
		end
		return left.timestamp < right.timestamp
	end)
	if context then
		context.normalizedDestructionEvents = #events
	end
	return events
end

local function spawnRecordedDebrisPayloads(context, payloads, maxParts: number): (number, number, number)
	if not (context and context.debrisFolder and typeof(payloads) == "table") then
		return 0, 0, 0
	end

	local remainingParts = math.max(math.floor(maxParts), 0)
	local spawnedParts = 0
	local spawnAttempts = 0
	local payloadBlocks = 0
	for _, payload in ipairs(payloads) do
		if remainingParts <= 0 then
			break
		end
		if typeof(payload) ~= "table" or typeof(payload.blocks) ~= "table" then
			continue
		end

		payloadBlocks += #payload.blocks
		local spawned, attempts = VoxelDebris.spawnPayload(payload, {
			parentFolder = context.debrisFolder,
			maxParts = remainingParts,
			lifetimeScale = DEBRIS_LIFETIME_SCALE,
			useGraphicsQualitySampling = false,
			forceVisible = true,
			minimumParts = math.min(6, remainingParts),
		})
		if typeof(attempts) == "number" then
			spawnAttempts += attempts
		end
		if typeof(spawned) == "number" and spawned > 0 then
			spawnedParts += spawned
			remainingParts -= spawned
		end
	end

	return spawnedParts, spawnAttempts, payloadBlocks
end

local function addDebrisDebugCounts(context, spawnedParts: number, spawnAttempts: number, payloadBlocks: number)
	context.debrisPartCount = (context.debrisPartCount or 0) + math.max(spawnedParts, 0)
	context.debrisSpawnAttempts = (context.debrisSpawnAttempts or 0) + math.max(spawnAttempts, 0)
	context.debrisPayloadBlocks = (context.debrisPayloadBlocks or 0) + math.max(payloadBlocks, 0)
end

function ReplayMapSimulator.ApplyDestructionEvent(context, event, options): boolean
	if not (context and context.mapRoot and context.outputFolder) then
		return false
	end
	if typeof(event) ~= "table" or typeof(event.position) ~= "Vector3" then
		return false
	end
	if not (isFiniteNumber(event.radius) and event.radius > 0) then
		return false
	end

	local replayDebrisOptions = nil
	local recordedDebrisPayloads = nil
	local recordedDebrisMaxParts = 0
	local spawnDebris = false
	if typeof(options) == "table" and options.spawnDebris == true and context.debrisFolder then
		local replayRemaining = math.max(MAX_DEBRIS_PARTS_PER_REPLAY - (context.debrisPartCount or 0), 0)
		local eventMaxParts = math.min(MAX_DEBRIS_PARTS_PER_EVENT, replayRemaining)
		if eventMaxParts > 0 then
			if typeof(event.debrisPayloads) == "table" and #event.debrisPayloads > 0 then
				recordedDebrisPayloads = event.debrisPayloads
				recordedDebrisMaxParts = eventMaxParts
			else
				spawnDebris = true
				replayDebrisOptions = {
					forceSpawnDebris = true,
					debrisFolder = context.debrisFolder,
					maxDebrisParts = eventMaxParts,
					debrisLifetimeScale = DEBRIS_LIFETIME_SCALE,
					useGraphicsQualitySampling = false,
					forceVisible = true,
					minimumParts = math.min(6, eventMaxParts),
					spawnedDebrisParts = 0,
					debrisPayloadBlocks = 0,
					debrisSpawnAttempts = 0,
				}
			end
		end
	end

	local targets, usedFallbackTargets = collectDestructibleTargets(context)
	context.lastTargetCount = #targets
	if #targets == 0 then
		context.targetFailures = (context.targetFailures or 0) + 1
		if recordedDebrisPayloads and recordedDebrisMaxParts > 0 then
			local spawned, attempts, blocks = spawnRecordedDebrisPayloads(context, recordedDebrisPayloads, recordedDebrisMaxParts)
			addDebrisDebugCounts(context, spawned, attempts, blocks)
			return spawned > 0 or attempts > 0
		end
		return false
	end
	if usedFallbackTargets then
		context.fallbackTargetUses = (context.fallbackTargetUses or 0) + 1
	end

	local voxelizeResult = nil
	local ok, err = pcall(function()
		voxelizeResult = VoxManager:voxelizePosition(
			event.position,
			event.radius,
			DestructionConfig.MinVoxelSize,
			DestructionConfig.FinalVoxelSize,
			DestructionConfig.RandomColor,
			spawnDebris,
			DestructionConfig.DebrisAmount,
			{},
			targets,
			context.outputFolder,
			replayDebrisOptions
		) or {}
	end)
	if not ok then
		context.applyFailures = (context.applyFailures or 0) + 1
		warn("[ReplayMapSimulator] Failed to apply replay map destruction: " .. tostring(err))
		return false
	end

	if typeof(voxelizeResult) == "table" and typeof(voxelizeResult.targetsHit) == "number" then
		context.targetsHit = (context.targetsHit or 0) + voxelizeResult.targetsHit
	end
	if typeof(voxelizeResult) == "table" and typeof(voxelizeResult.debrisPayloadBlocks) == "number" then
		context.debrisPayloadBlocks = (context.debrisPayloadBlocks or 0) + voxelizeResult.debrisPayloadBlocks
	elseif replayDebrisOptions and typeof(replayDebrisOptions.debrisPayloadBlocks) == "number" then
		context.debrisPayloadBlocks = (context.debrisPayloadBlocks or 0) + replayDebrisOptions.debrisPayloadBlocks
	end
	if typeof(voxelizeResult) == "table" and typeof(voxelizeResult.debrisSpawnAttempts) == "number" then
		context.debrisSpawnAttempts = (context.debrisSpawnAttempts or 0) + voxelizeResult.debrisSpawnAttempts
	elseif replayDebrisOptions and typeof(replayDebrisOptions.debrisSpawnAttempts) == "number" then
		context.debrisSpawnAttempts = (context.debrisSpawnAttempts or 0) + replayDebrisOptions.debrisSpawnAttempts
	end
	if typeof(voxelizeResult) == "table" and typeof(voxelizeResult.debrisPartsSpawned) == "number" then
		context.debrisPartCount = (context.debrisPartCount or 0) + voxelizeResult.debrisPartsSpawned
	elseif replayDebrisOptions and typeof(replayDebrisOptions.spawnedDebrisParts) == "number" then
		context.debrisPartCount = (context.debrisPartCount or 0) + replayDebrisOptions.spawnedDebrisParts
	end
	if recordedDebrisPayloads and recordedDebrisMaxParts > 0 then
		local spawned, attempts, blocks = spawnRecordedDebrisPayloads(context, recordedDebrisPayloads, recordedDebrisMaxParts)
		addDebrisDebugCounts(context, spawned, attempts, blocks)
	end
	context.appliedDestructionEvents = (context.appliedDestructionEvents or 0) + 1
	sanitizeGeneratedVoxels(context.outputFolder)
	return true
end

function ReplayMapSimulator.ApplyEventsUpTo(context, events, replayTime: number, startIndex: number?, options): number
	local index = if isFiniteNumber(startIndex) then math.max(math.floor(startIndex), 1) else 1
	if typeof(events) ~= "table" or not isFiniteNumber(replayTime) then
		return index
	end

	local maxEvents = if typeof(options) == "table" and isFiniteNumber(options.maxEvents)
		then math.max(math.floor(options.maxEvents), 0)
		else math.huge
	local processedEvents = 0

	while index <= #events do
		local event = events[index]
		if not (typeof(event) == "table" and isFiniteNumber(event.timestamp)) then
			index += 1
			continue
		end
		if event.timestamp > replayTime then
			break
		end
		if processedEvents >= maxEvents then
			break
		end

		ReplayMapSimulator.ApplyDestructionEvent(context, event, options)
		processedEvents += 1
		index += 1
	end

	return index
end

function ReplayMapSimulator.Create(scene: Instance, payload)
	if type(VoxManager.resetTerrainState) == "function" then
		VoxManager:resetTerrainState()
	end

	local livePivot = if typeof(payload) == "table" and isFiniteCFrame(payload.mapPivot) then payload.mapPivot else CFrame.new()
	local context = {
		scene = scene,
		livePivot = livePivot,
		replayPivot = REPLAY_ZONE_PIVOT,
		mapId = if typeof(payload) == "table" then payload.mapId else nil,
		mapRoot = nil,
		outputFolder = nil,
		debrisFolder = nil,
		debrisPartCount = 0,
		debrisPayloadBlocks = 0,
		debrisSpawnAttempts = 0,
		normalizedDestructionEvents = 0,
		appliedDestructionEvents = 0,
		targetFailures = 0,
		applyFailures = 0,
		fallbackTargetUses = 0,
		targetsHit = 0,
		lastTargetCount = 0,
	}

	local mapFolder = Instance.new("Folder")
	mapFolder.Name = MAP_FOLDER_NAME
	mapFolder.Parent = scene
	context.mapFolder = mapFolder

	local clone = clonePreparedMapTemplate(context.mapId)
	if not clone then
		return context
	end

	VoxManager:setDebrisConfig(DestructionConfig)
	VoxManager:setGeneratedVoxelTag(DestructionConfig.Tag)
	VoxManager:setTerrainConfig(DestructionConfig)

	clone.Name = RoundConfig.ActiveMapName
	pivotInstance(clone, context.replayPivot)
	clone.Parent = mapFolder
	context.staticMapRoot = clone

	local outputFolder = Instance.new("Folder")
	outputFolder.Name = CURRENT_VOXELS_FOLDER_NAME
	outputFolder.Parent = mapFolder

	local debrisFolder = Instance.new("Folder")
	debrisFolder.Name = DEBRIS_FOLDER_NAME
	debrisFolder.Parent = mapFolder

	context.mapRoot = mapFolder
	context.outputFolder = outputFolder
	context.debrisFolder = debrisFolder
	return context
end

local function rememberPreparedScene(mapId: string, scene: Folder, mapContext)
	local existing = preparedSceneCache[mapId]
	if existing then
		destroyPreparedSceneEntry(existing)
	end
	if not preparedSceneCache[mapId] then
		table.insert(preparedSceneOrder, mapId)
	end

	preparedSceneCache[mapId] = {
		mapId = mapId,
		scene = scene,
		mapContext = mapContext,
	}

	while #preparedSceneOrder > MAX_PREPARED_REUSABLE_SCENES do
		local oldMapId = table.remove(preparedSceneOrder, 1)
		if oldMapId ~= mapId then
			local oldEntry = preparedSceneCache[oldMapId]
			preparedSceneCache[oldMapId] = nil
			destroyPreparedSceneEntry(oldEntry)
		end
	end
end

function ReplayMapSimulator.PrewarmReusableScene(mapId: any): boolean
	if typeof(mapId) ~= "string" or mapId == "" then
		return false
	end
	if preparedSceneCache[mapId] or preparedSceneInProgress[mapId] then
		return true
	end
	if not getMapTemplate(mapId) then
		return false
	end

	preparedSceneInProgress[mapId] = true
	task.spawn(function()
		task.wait()
		local token = RuntimeProfiler.Begin("Client/Replay/MapSimulator/PrewarmReusableScene")
		local ok, err = pcall(function()
			ReplayMapSimulator.PrewarmTemplate(mapId)
			local scene = createPreparedScene(mapId)
			local mapContext = ReplayMapSimulator.Create(scene, {
				mapId = mapId,
				mapPivot = CFrame.new(),
			})
			if not (mapContext and mapContext.mapRoot) then
				scene:Destroy()
				return
			end
			collectDestructibleTargets(mapContext)
			rememberPreparedScene(mapId, scene, mapContext)
			RuntimeProfiler.Count("Client/Replay/MapSimulator/PrewarmedReusableScenes")
		end)
		preparedSceneInProgress[mapId] = nil
		RuntimeProfiler.End("Client/Replay/MapSimulator/PrewarmReusableScene", token)
		if not ok then
			warn("[ReplayMapSimulator] Failed to prewarm reusable replay scene: " .. tostring(err))
		end
	end)
	return true
end

function ReplayMapSimulator.PrewarmReusableScenes(limit: number?): number
	local queued = 0
	for _, mapId in ipairs(getPreferredMapIds(limit)) do
		if ReplayMapSimulator.PrewarmReusableScene(mapId) then
			queued += 1
		end
	end
	if queued > 0 then
		RuntimeProfiler.Count("Client/Replay/MapSimulator/ReusableScenePrewarmQueued", queued)
	end
	return queued
end

function ReplayMapSimulator.TakePreparedScene(payload): (Folder?, any?)
	local mapId = if typeof(payload) == "table" then payload.mapId else nil
	if typeof(mapId) ~= "string" or mapId == "" then
		RuntimeProfiler.Count("Client/Replay/MapSimulator/PreparedSceneMisses")
		return nil, nil
	end

	local entry = preparedSceneCache[mapId]
	if not (entry and entry.scene and entry.scene.Parent and entry.mapContext) then
		preparedSceneCache[mapId] = nil
		RuntimeProfiler.Count("Client/Replay/MapSimulator/PreparedSceneMisses")
		return nil, nil
	end

	preparedSceneCache[mapId] = nil
	for index, queuedMapId in ipairs(preparedSceneOrder) do
		if queuedMapId == mapId then
			table.remove(preparedSceneOrder, index)
			break
		end
	end

	local existing = Workspace:FindFirstChild(SCENE_NAME)
	if existing and existing ~= entry.scene then
		existing:Destroy()
	end

	entry.scene.Name = SCENE_NAME
	entry.scene:SetAttribute(LOCAL_REPLAY_ATTR, true)
	entry.mapContext.livePivot = if typeof(payload) == "table" and isFiniteCFrame(payload.mapPivot)
		then payload.mapPivot
		else CFrame.new()
	entry.mapContext.scene = entry.scene
	RuntimeProfiler.Count("Client/Replay/MapSimulator/PreparedSceneHits")
	return entry.scene, entry.mapContext
end

function ReplayMapSimulator.Destroy(_context)
	if type(VoxManager.resetTerrainState) == "function" then
		VoxManager:resetTerrainState()
	end
	if type(VoxManager.cleanupVoxelCache) == "function" then
		VoxManager:cleanupVoxelCache()
	end
end

function ReplayMapSimulator.GetMaxDestructionEventsPerStep(): number
	return MAX_DESTRUCTION_EVENTS_PER_STEP
end

function ReplayMapSimulator.GetDebugInfo(context)
	if typeof(context) ~= "table" then
		return {}
	end

	return {
		mapId = context.mapId,
		normalizedDestructionEvents = context.normalizedDestructionEvents or 0,
		appliedDestructionEvents = context.appliedDestructionEvents or 0,
		targetFailures = context.targetFailures or 0,
		applyFailures = context.applyFailures or 0,
		fallbackTargetUses = context.fallbackTargetUses or 0,
		targetsHit = context.targetsHit or 0,
		lastTargetCount = context.lastTargetCount or 0,
		debrisPartCount = context.debrisPartCount or 0,
		debrisPayloadBlocks = context.debrisPayloadBlocks or 0,
		debrisSpawnAttempts = context.debrisSpawnAttempts or 0,
	}
end

return ReplayMapSimulator
