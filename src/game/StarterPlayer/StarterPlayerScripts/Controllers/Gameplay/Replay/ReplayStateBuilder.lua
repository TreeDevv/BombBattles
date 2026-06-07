local workspace = game:GetService("Workspace")

local ReplayStateBuilder = {}

function ReplayStateBuilder.Build(client, payload, deps)
	if not deps.areReplayVisualsEnabled() then
		deps.warnReplayBuildSkipped("VisualsDisabled", payload)
		return nil
	end
	if typeof(payload) ~= "table" or (payload.type ~= "KillReplay" and payload.type ~= "POTGReplay") then
		deps.warnReplayBuildSkipped("InvalidPayloadType", payload)
		return nil
	end
	if not (deps.isFiniteNumber(payload.startTime) and deps.isFiniteNumber(payload.endTime)) then
		deps.warnReplayBuildSkipped("InvalidReplayTime", payload)
		return nil
	end
	if payload.endTime <= payload.startTime then
		deps.warnReplayBuildSkipped("InvalidReplayWindow", payload)
		return nil
	end

	local startTime = payload.startTime
	local endTime = math.min(payload.endTime, payload.startTime + deps.maxReplayDurationSeconds)
	local duration = math.max(endTime - startTime, 0.1)
	local scene = deps.createScene()
	local mapContext = deps.ReplayMapSimulator.Create(scene, payload)
	local frames = deps.ReplayMapSimulator.TransformFrames(mapContext, deps.preprocessFrames(payload.frames))
	if #frames == 0 then
		scene:Destroy()
		deps.warnReplayBuildSkipped("EmptyFrames", payload)
		return nil
	end

	local effectsFolder = Instance.new("Folder")
	effectsFolder.Name = "ReplayEventVisuals"
	effectsFolder.Parent = scene
	local overlay = deps.createOverlay(payload)
	local cameraState = deps.captureCameraState()
	local events = deps.ReplayMapSimulator.TransformEvents(
		mapContext,
		deps.preprocessEvents(payload.events, startTime, endTime)
	)
	local destructionEvents = deps.ReplayMapSimulator.NormalizeDestructionEvents(
		mapContext,
		payload.destructionEvents,
		endTime
	)
	local nextDestructionIndex = deps.ReplayMapSimulator.ApplyEventsUpTo(
		mapContext,
		destructionEvents,
		startTime - 0.001,
		1
	)
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

	local playerMeta = deps.collectPlayerMeta(frames)
	if deps.preloadAvatarTemplates then
		deps.preloadAvatarTemplates(playerMeta)
	end

	for key, meta in pairs(playerMeta) do
		if not deps.reserveReplayObjects(24) then
			break
		end
		state.playerVisuals[key] = deps.makeCharacterVisual(scene, meta.userId, meta.teamName, meta.hasPose, meta.bombSkinId)
	end

	for key, meta in pairs(deps.collectBombMeta(frames)) do
		if not deps.reserveReplayObjects(6) then
			break
		end
		state.bombVisuals[key] = deps.makeBombVisual(scene, key, meta.bombType, meta.bombSkinId)
	end

	if not hasRecordedCamera then
		state.cameraController = deps.ReplayCameraController.new(state, deps.cameraControllerDeps)
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	return state
end

return table.freeze(ReplayStateBuilder)
