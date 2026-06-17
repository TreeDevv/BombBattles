local workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local ReplayStateBuilder = {}

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
		mapContext = deps.ReplayMapSimulator.Create(scene, payload)
	end
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CreateMap", mapToken)
	local frameToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/TransformFrames")
	local frames = deps.ReplayMapSimulator.TransformFrames(mapContext, deps.preprocessFrames(payload.frames))
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/TransformFrames", frameToken)
	if #frames == 0 then
		scene:Destroy()
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
	local normalizeToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/NormalizeDestructionEvents")
	local destructionEvents = deps.ReplayMapSimulator.NormalizeDestructionEvents(
		mapContext,
		payload.destructionEvents,
		endTime
	)
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/NormalizeDestructionEvents", normalizeToken)
	local initialDestructionToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/ApplyInitialDestruction")
	local nextDestructionIndex = deps.ReplayMapSimulator.ApplyEventsUpTo(
		mapContext,
		destructionEvents,
		startTime - 0.001,
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
	local hasRecordedCamera = deps.hasRecordedCameraForUser(frames, cameraUserId)

	local state = {
		scene = scene,
		effectsFolder = effectsFolder,
		overlay = overlay,
		cameraState = cameraState,
		mapContext = mapContext,
		frames = frames,
		events = events,
		destructionEvents = destructionEvents,
		eventPositionsBySourceId = eventPositionsBySourceId,
		frameIndex = 1,
		nextEventIndex = 1,
		firedEventIndices = {},
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
		hasRecordedCamera = hasRecordedCamera,
		playerVisuals = {},
		bombVisuals = {},
		explodedBombs = {},
		cameraController = nil,
		renderConnection = nil,
		renderBindingName = nil,
		objectCount = 0,
		maxObjects = deps.maxReplayObjects,
	}
	client._activeReplay = state

	local metaToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/CollectMeta")
	local playerMeta = deps.collectPlayerMeta(frames)
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CollectMeta", metaToken)
	if deps.preloadAvatarTemplates then
		local preloadToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/PreloadAvatars")
		deps.preloadAvatarTemplates(playerMeta)
		RuntimeProfiler.End("Client/Replay/Death/StateBuilder/PreloadAvatars", preloadToken)
	end

	local playerVisualsToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/CreatePlayerVisuals")
	for key, meta in pairs(playerMeta) do
		if not deps.reserveReplayObjects(24) then
			break
		end
		state.playerVisuals[key] =
			deps.makeCharacterVisual(scene, meta.userId, meta.teamName, meta.hasPose, meta.bombSkinId, meta.displayName)
	end
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CreatePlayerVisuals", playerVisualsToken)

	local bombVisualsToken = RuntimeProfiler.Begin("Client/Replay/Death/StateBuilder/CreateBombVisuals")
	for key, meta in pairs(deps.collectBombMeta(frames)) do
		if not deps.reserveReplayObjects(6) then
			break
		end
		state.bombVisuals[key] = deps.makeBombVisual(scene, key, meta.bombType, meta.bombSkinId)
	end
	RuntimeProfiler.End("Client/Replay/Death/StateBuilder/CreateBombVisuals", bombVisualsToken)

	if not hasRecordedCamera then
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
