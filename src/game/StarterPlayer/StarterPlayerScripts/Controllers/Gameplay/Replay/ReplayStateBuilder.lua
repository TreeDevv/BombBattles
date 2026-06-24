local workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local ReplayStateBuilder = {}

local function getUserIdKey(deps, value: any): string?
	if not deps.isFiniteNumber(value) then
		return nil
	end
	return tostring(math.floor(value))
end

local function getPlayerVisualLimit(payload, deps): number
	local defaultLimit = if payload.type == "POTGReplay" then 10 else 6
	local configuredLimit = if payload.type == "POTGReplay"
		then deps.maxPOTGReplayPlayerVisuals
		else deps.maxKillReplayPlayerVisuals
	if deps.isFiniteNumber(configuredLimit) then
		return math.max(math.floor(configuredLimit), 1)
	end
	return defaultLimit
end

local function getBombVisualLimit(payload, deps): number
	local defaultLimit = if payload.type == "POTGReplay" then 32 else 12
	local configuredLimit = if payload.type == "POTGReplay"
		then deps.maxPOTGReplayBombVisuals
		else deps.maxKillReplayBombVisuals
	if deps.isFiniteNumber(configuredLimit) then
		return math.max(math.floor(configuredLimit), 1)
	end
	return defaultLimit
end

local function addPriorityKey(priorityKeys: { string }, prioritySet: { [string]: number }, key: string?)
	if not key or prioritySet[key] then
		return
	end
	prioritySet[key] = #priorityKeys + 1
	table.insert(priorityKeys, key)
end

local function buildPlayerVisualEntries(playerMeta, payload, deps)
	local priorityKeys = {}
	local prioritySet = {}

	addPriorityKey(priorityKeys, prioritySet, getUserIdKey(deps, payload.killerUserId))
	addPriorityKey(priorityKeys, prioritySet, getUserIdKey(deps, payload.victimUserId))
	addPriorityKey(priorityKeys, prioritySet, getUserIdKey(deps, payload.playerUserId))

	local entries = {}
	for key, meta in pairs(playerMeta) do
		table.insert(entries, {
			key = key,
			meta = meta,
			priority = prioritySet[key] or math.huge,
			name = tostring((meta and (meta.displayName or meta.name)) or key),
		})
	end

	table.sort(entries, function(left, right)
		if left.priority ~= right.priority then
			return left.priority < right.priority
		end
		if left.name ~= right.name then
			return left.name < right.name
		end
		return tostring(left.key) < tostring(right.key)
	end)

	local limit = math.min(getPlayerVisualLimit(payload, deps), #entries)
	local selectedEntries = {}
	local selectedMeta = {}
	for index = 1, limit do
		local entry = entries[index]
		table.insert(selectedEntries, entry)
		selectedMeta[entry.key] = entry.meta
	end

	RuntimeProfiler.Count("Client/Replay/Death/StateBuilder/PlayerMetaCount", #entries)
	RuntimeProfiler.Count("Client/Replay/Death/StateBuilder/PlayerVisualCount", #selectedEntries)
	return selectedEntries, selectedMeta
end

local function buildBombVisualEntries(bombMeta, payload, eventPositionsBySourceId, deps)
	local priorityKeys = {}
	local prioritySet = {}

	addPriorityKey(priorityKeys, prioritySet, deps.getBombKey(payload.sourceId))
	addPriorityKey(priorityKeys, prioritySet, deps.getBombKey(payload.bombId))
	for key in pairs(eventPositionsBySourceId or {}) do
		addPriorityKey(priorityKeys, prioritySet, key)
	end

	local entries = {}
	for key, meta in pairs(bombMeta or {}) do
		table.insert(entries, {
			key = key,
			meta = meta,
			priority = prioritySet[key] or math.huge,
		})
	end

	table.sort(entries, function(left, right)
		if left.priority ~= right.priority then
			return left.priority < right.priority
		end
		return tostring(left.key) < tostring(right.key)
	end)

	local limit = math.min(getBombVisualLimit(payload, deps), #entries)
	local selectedEntries = {}
	for index = 1, limit do
		table.insert(selectedEntries, entries[index])
	end

	RuntimeProfiler.Count("Client/Replay/Death/StateBuilder/BombMetaCount", #entries)
	RuntimeProfiler.Count("Client/Replay/Death/StateBuilder/BombVisualCount", #selectedEntries)
	if #entries > #selectedEntries then
		RuntimeProfiler.Count("Client/Replay/Death/StateBuilder/BombVisualsSkipped", #entries - #selectedEntries)
	end
	return selectedEntries
end

local function skipInitialDestructionEvents(events, replayTime: number, deps): number
	local index = 1
	local skipped = 0
	if typeof(events) ~= "table" or not deps.isFiniteNumber(replayTime) then
		return index
	end

	while index <= #events do
		local event = events[index]
		if not (typeof(event) == "table" and deps.isFiniteNumber(event.timestamp)) then
			index += 1
			continue
		end
		if event.timestamp > replayTime then
			break
		end
		index += 1
		skipped += 1
	end
	if skipped > 0 then
		RuntimeProfiler.Count("Client/Replay/Death/StateBuilder/InitialDestructionSkipped", skipped)
	end
	return index
end

function ReplayStateBuilder.Build(client, payload, deps)
	local totalToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/Total")
	local function finish(result)
		RuntimeProfiler.End("Client/Replay/Death/StateBuilder/Total", totalToken)
		return result
	end

	if not deps.areReplayVisualsEnabled() then
		deps.warnReplayBuildSkipped("VisualsDisabled", payload)
		return finish(nil)
	end
	if typeof(payload) ~= "table" or (payload.type ~= "KillReplay" and payload.type ~= "POTGReplay") then
		deps.warnReplayBuildSkipped("InvalidPayloadType", payload)
		return finish(nil)
	end
	if not (deps.isFiniteNumber(payload.startTime) and deps.isFiniteNumber(payload.endTime)) then
		deps.warnReplayBuildSkipped("InvalidReplayTime", payload)
		return finish(nil)
	end
	if payload.endTime <= payload.startTime then
		deps.warnReplayBuildSkipped("InvalidReplayWindow", payload)
		return finish(nil)
	end

	local startTime = payload.startTime
	local endTime = math.min(payload.endTime, payload.startTime + deps.maxReplayDurationSeconds)
	local duration = math.max(endTime - startTime, 0.1)
	local sceneToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/CreateScene")
	local scene = nil
	local mapContext = nil
	if deps.takePreparedSceneContext then
		scene, mapContext = deps.takePreparedSceneContext(payload)
	end
	if not scene then
		scene = deps.createScene()
	end
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CreateScene", sceneToken)
	local mapToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/CreateMap")
	if not mapContext then
		RuntimeProfiler.Count("Client/Replay/Death/StateBuilder/ColdMapBuilds")
		mapContext = deps.ReplayMapSimulator.Create(scene, payload)
	end
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CreateMap", mapToken)
	local frameToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/TransformFrames")
	local frames = deps.ReplayMapSimulator.TransformFrames(mapContext, deps.preprocessFrames(payload.frames))
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/TransformFrames", frameToken)
	if #frames == 0 then
		deps.ReplayMapSimulator.ScheduleDestroyScene(scene, "EmptyFrames")
		deps.warnReplayBuildSkipped("EmptyFrames", payload)
		return finish(nil)
	end

	local effectsFolder = Instance.new("Folder")
	effectsFolder.Name = "ReplayEventVisuals"
	effectsFolder.Parent = scene
	local overlayToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/CreateOverlay")
	local overlay = deps.createOverlay(payload)
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CreateOverlay", overlayToken)
	local cameraState = deps.captureCameraState()
	local eventsToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/TransformEvents")
	local events = deps.ReplayMapSimulator.TransformEvents(
		mapContext,
		deps.preprocessEvents(payload.events, startTime, endTime)
	)
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/TransformEvents", eventsToken)
	local eventQueues, eventCount = deps.buildReplayEventQueues(events)
	local normalizeToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/NormalizeDestructionEvents")
	local destructionEvents = deps.ReplayMapSimulator.NormalizeDestructionEvents(
		mapContext,
		payload.destructionEvents,
		startTime,
		endTime
	)
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/NormalizeDestructionEvents", normalizeToken)
	local initialDestructionToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/ApplyInitialDestruction")
	local initialDestructionTime = startTime - 0.001
	local nextDestructionIndex = if payload.type == "POTGReplay"
		then skipInitialDestructionEvents(destructionEvents, initialDestructionTime, deps)
		else deps.ReplayMapSimulator.ApplyEventsUpTo(
			mapContext,
			destructionEvents,
			initialDestructionTime,
			1
		)
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/ApplyInitialDestruction", initialDestructionToken)
	local eventPositionsBySourceId = deps.collectExplosionPositions(events)
	local featuredUserId = if deps.isFiniteNumber(payload.playerUserId) then math.floor(payload.playerUserId) else nil
	local killerUserId = if deps.isFiniteNumber(payload.killerUserId)
		then math.floor(payload.killerUserId)
		elseif payload.type == "POTGReplay"
		then featuredUserId
		else nil
	local victimUserId = if deps.isFiniteNumber(payload.victimUserId) then math.floor(payload.victimUserId) else nil
	local cameraUserId = if payload.type == "POTGReplay"
		then featuredUserId or killerUserId or victimUserId
		else killerUserId or featuredUserId or victimUserId
	local sourceId = deps.getBombKey(payload.sourceId)
	local killTimestamp = if deps.isFiniteNumber(payload.primaryEventTime)
		then math.clamp(payload.primaryEventTime, startTime, endTime)
		else deps.findKillTimestamp(events, victimUserId, startTime, endTime)
	local impactPosition = deps.findImpactPosition(events, eventPositionsBySourceId, sourceId, victimUserId)

	local state = {
		scene = scene,
		effectsFolder = effectsFolder,
		overlay = overlay,
		cameraState = cameraState,
		mapContext = mapContext,
		frames = frames,
		events = events,
		eventQueues = eventQueues,
		pendingEventCount = eventCount,
		destructionEvents = destructionEvents,
		eventPositionsBySourceId = eventPositionsBySourceId,
		frameIndex = 1,
		nextEventIndicesByPhase = {},
		nextDestructionIndex = nextDestructionIndex,
		startTime = startTime,
		endTime = endTime,
		duration = duration,
		playhead = startTime,
		wallClockElapsed = 0,
		killTimestamp = killTimestamp,
		impactPosition = impactPosition,
		sourceId = sourceId,
		sourceType = payload.sourceType,
		replayType = payload.type,
		playerUserId = featuredUserId,
		killerUserId = killerUserId,
		victimUserId = victimUserId,
		cameraUserId = cameraUserId,
		hasRecordedCamera = false,
		playerVisuals = {},
		bombVisuals = {},
		explodedBombs = {},
		cameraController = nil,
		renderConnection = nil,
		renderBindingName = nil,
		objectCount = 0,
		maxObjects = deps.maxReplayObjects,
	}

	local metaToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/CollectMeta")
	local playerMeta = nil
	local bombMeta = nil
	if deps.collectReplayMeta then
		playerMeta, bombMeta = deps.collectReplayMeta(frames)
	else
		playerMeta = deps.collectPlayerMeta(frames)
	end
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CollectMeta", metaToken)
	local visualEntriesToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/SelectPlayerVisuals")
	local playerVisualEntries, selectedPlayerMeta = buildPlayerVisualEntries(playerMeta, payload, deps)
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/SelectPlayerVisuals", visualEntriesToken)
	if #playerVisualEntries == 0 then
		if overlay then
			overlay:Destroy()
		end
		deps.ReplayMapSimulator.Destroy(mapContext)
		deps.ReplayMapSimulator.ScheduleDestroyScene(scene, "NoPlayerVisuals")
		deps.warnReplayBuildSkipped("NoPlayerVisuals", payload)
		return finish(nil)
	end

	local cameraUserKey = getUserIdKey(deps, state.cameraUserId)
	if not (cameraUserKey and selectedPlayerMeta[cameraUserKey]) then
		local fallbackMeta = playerVisualEntries[1] and playerVisualEntries[1].meta
		if fallbackMeta and deps.isFiniteNumber(fallbackMeta.userId) then
			state.cameraUserId = math.floor(fallbackMeta.userId)
			if payload.type == "POTGReplay" then
				state.playerUserId = state.cameraUserId
			end
			if not deps.isFiniteNumber(state.killerUserId) then
				state.killerUserId = state.cameraUserId
			end
		end
	end
	state.hasRecordedCamera = deps.hasRecordedCameraForUser(frames, state.cameraUserId)
	client._activeReplay = state

	if deps.preloadAvatarTemplates then
		local preloadToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/PreloadAvatars")
		deps.preloadAvatarTemplates(selectedPlayerMeta)
		RuntimeProfiler.End("Client/Replay/Death/StateBuilder/PreloadAvatars", preloadToken)
	end

	local playerVisualsToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/CreatePlayerVisuals")
	local createdPlayerVisuals = 0
	for _, entry in ipairs(playerVisualEntries) do
		local key = entry.key
		local meta = entry.meta
		if not deps.reserveReplayObjects(24) then
			break
		end
		local visual = deps.makeCharacterVisual(scene, meta.userId, meta.teamName, meta.hasPose, meta.bombSkinId, meta.displayName)
		if visual then
			state.playerVisuals[key] = visual
			createdPlayerVisuals += 1
		end
	end
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CreatePlayerVisuals", playerVisualsToken)
	if createdPlayerVisuals == 0 then
		client._activeReplay = nil
		if overlay then
			overlay:Destroy()
		end
		deps.ReplayMapSimulator.Destroy(mapContext)
		deps.ReplayMapSimulator.ScheduleDestroyScene(scene, "NoPlayerVisuals")
		deps.warnReplayBuildSkipped("NoPlayerVisuals", payload)
		return finish(nil)
	end

	local bombVisualsToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/CreateBombVisuals")
	bombMeta = bombMeta or deps.collectBombMeta(frames)
	local bombVisualEntries = buildBombVisualEntries(bombMeta, payload, eventPositionsBySourceId, deps)
	for _, entry in ipairs(bombVisualEntries) do
		local key = entry.key
		local meta = entry.meta
		if not deps.reserveReplayObjects(6) then
			break
		end
		state.bombVisuals[key] = deps.makeBombVisual(scene, key, meta.bombType, meta.bombSkinId)
	end
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CreateBombVisuals", bombVisualsToken)

	if not state.hasRecordedCamera then
		local cameraControllerToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/CreateCameraController")
		state.cameraController = deps.ReplayCameraController.new(state, deps.cameraControllerDeps)
		RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CreateCameraController", cameraControllerToken)
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	return finish(state)
end

return table.freeze(ReplayStateBuilder)
