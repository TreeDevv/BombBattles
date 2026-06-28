local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local ReplayConstants = require(ReplicatedStorage.Shared.Replay.ReplayConstants)
local ReplayUtil = require(ReplicatedStorage.Shared.Replay.ReplayUtil)
local ReplayClipPolicy = require(ReplicatedStorage.Shared.Replay.ReplayClipPolicy)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local HighlightIntroService = require(ServerScriptService.Services.HighlightIntroService)
local POTGService = require(ServerScriptService.Services.POTGService)
local StudioAICombatants = require(ServerScriptService.Services.StudioAICombatants)
local ReplayBuffer = require(script.Parent.Replay.ReplayBuffer)
local ReplayClipUtil = require(script.Parent.Replay.ReplayClipUtil)

local ReplayService = {}
ReplayService.Buffer = nil

local DEBUG_KILL_REPLAY_SEND = RunService:IsStudio()
local DEBUG_POTG_EVENTS = false
local DEBUG_POTG_SEND = false
local REPLAY_ASSETS_FOLDER_NAME = "ReplayAssets"
local KILL_REPLAY_WINDOW_SECONDS = ReplayConstants.KILL_REPLAY_PRE_SECONDS + ReplayConstants.KILL_REPLAY_POST_SECONDS
local KILL_REPLAY_SEND_DELAY_SECONDS = ReplayConstants.KILL_REPLAY_POST_SECONDS + ReplayConstants.SAMPLE_INTERVAL
local RECENT_KILL_REPLAY_TTL_SECONDS = 10
local KILL_REPLAY_REQUEST_COOLDOWN_SECONDS = 0.75
local MIN_KILL_REPLAY_FRAMES = ReplayClipPolicy.MinKillReplayFrames
local MIN_KILL_REPLAY_SEND_FRAMES = ReplayClipPolicy.MinKillReplaySendFrames
local MIN_POTG_REPLAY_FRAMES = ReplayClipPolicy.MinPOTGReplayFrames
local MIN_POTG_FALLBACK_SEND_FRAMES = 1
local MAX_ROUND_DESTRUCTION_EVENTS = math.max(ReplayClipPolicy.GetPOTGClipCaps().maxDestructionEvents * 4, 512)
local CLIENT_ANIMATION_STATE_MAX_RATE = 30
local CLIENT_ANIMATION_STATE_STALE_SECONDS = 0.5
local MAX_REPLAY_ANIMATION_SPEED = 220
local CLIENT_REPLAY_SAMPLE_HISTORY_SECONDS = ReplayConstants.BUFFER_SECONDS + 1
local MAX_REPLAY_VISUAL_SAMPLE_AGE = 0.12
local MAX_CLIENT_REPLAY_SAMPLE_SKEW = 2
local MAX_REPLAY_POSE_JOINTS = 32
local MAX_REPLAY_JOINT_NAME_LENGTH = 48
local MIN_REPLAY_CAMERA_FOV = 20
local MAX_REPLAY_CAMERA_FOV = 120
local DEBUG_REPLAY_DESTRUCTION_LEAD_SECONDS = 0.5
local MAX_DEBRIS_PAYLOADS_PER_DESTRUCTION_EVENT = 16
local MAX_DEBRIS_BLOCKS_PER_DESTRUCTION_EVENT = 160
local MAX_REPLAY_DESTRUCTION_TARGETS_PER_EVENT = 128
local MAX_RANDOM_SEED = 2147483647
local STORE_RECORDED_DEBRIS_PAYLOADS_BY_DEFAULT = true
local MAX_ARCHIVED_POTG_CLIPS = 16
local REPLAY_DESTRUCTION_BOOLEAN_OPTION_FIELDS = table.freeze({
	"forceSubtract",
	"exactCullTargets",
	"skipTerminalNoop",
	"reuseTargetPart",
	"prefilterTargets",
	"prefilteredTargets",
})

local initialized = false
local running = false
local heartbeatConnection: RBXScriptConnection? = nil
local accumulator = 0
local sampleCount = 0
local lastSampleTime = 0
local lastFramePlayerCount = 0
local lastFrameBombCount = 0
local lastBombContainerFound = false
local lastBombServiceSnapshotAvailable = false
local lastBombSource = "None"
local animationStateConnection: RBXScriptConnection? = nil
local killReplayRequestConnection: RBXScriptConnection? = nil
local latestAnimationStateByUserId = {}
local clientReplaySamplesByUserId = {}
local lastAnimationStateAtByUserId = {}
local recentKillReplayEventsByVictimUserId = {}
local lastKillReplayRequestAtByUserId = {}
local lastKillReplayDebug = nil
local lastPOTGReplayDebug = nil
local lastClipOptimizationDebug = nil
local clipOptimizationTotals = ReplayClipPolicy.CreateOptimizationTotals()
local currentRoundId = nil
local currentMapContext = nil
local roundDestructionEvents = {}
local nextDestructionSequence = 0
local roundStorageGeneration = 0
local roundPerformanceCritical = false
local potgSentThisRound = false
local potgSendInProgress = false
local potgSendToken = 0
local optimizedReplayPayloads = setmetatable({}, { __mode = "k" })
local debugKillReplaySend = nil
local sendKillReplayForEvent = nil
local bombProjectileService = nil
local archivedPOTGClipsByKey = {}
local archivedPOTGClipOrder = {}
local scheduledPOTGArchivesByKey = {}

local isFiniteNumber = ReplayUtil.IsFiniteNumber
local isFiniteCFrame = ReplayUtil.IsFiniteCFrame
local isFiniteVector3 = ReplayUtil.IsFiniteVector3
local isFiniteColor3 = ReplayUtil.IsFiniteColor3

local function getTrustedReplayTimestamp(payload): number
	return ReplayUtil.GetTrustedReplayTimestamp(payload, workspace:GetServerTimeNow())
end

local countDictionaryEntries = ReplayUtil.CountDictionaryEntries

local function countLatestClientReplayField(fieldName: string): number
	local count = 0
	for _, record in pairs(latestAnimationStateByUserId) do
		if typeof(record) == "table" and typeof(record.state) == "table" and record.state[fieldName] ~= nil then
			count += 1
		end
	end
	return count
end

local function countClientReplaySampleRecords(): number
	local count = 0
	for _, samples in pairs(clientReplaySamplesByUserId) do
		if typeof(samples) == "table" then
			count += #samples
		end
	end
	return count
end

local copyReplayEvent = ReplayUtil.CopyReplayEvent
local getReplayIdKey = ReplayUtil.GetReplayIdKey
local getUserIdKey = ReplayUtil.GetUserIdKey

local function getRoundId(value: any): number?
	if not isFiniteNumber(value) then
		return nil
	end
	return math.floor(value)
end

local function getCurrentMapContextForRound(roundId: number?)
	if typeof(currentMapContext) ~= "table" then
		return nil
	end
	local currentRound = getRoundId(currentMapContext.roundId)
	if roundId and currentRound and roundId ~= currentRound then
		return nil
	end
	return currentMapContext
end

local function applyCurrentMapContextToEvent(event)
	if typeof(event) ~= "table" then
		return
	end
	if event.roundId == nil then
		event.roundId = currentRoundId
	end

	local eventRoundId = getRoundId(event.roundId)
	local mapContext = getCurrentMapContextForRound(eventRoundId)
	if not mapContext then
		return
	end
	if typeof(event.mapId) ~= "string" or event.mapId == "" then
		event.mapId = mapContext.mapId
	end
	if not isFiniteCFrame(event.mapPivot) and event.mapId == mapContext.mapId then
		event.mapPivot = mapContext.mapPivot
	end
end

local function resolvePayloadMapContext(payload)
	if typeof(payload) ~= "table" then
		return nil
	end

	local payloadRoundId = getRoundId(payload.roundId)
	local payloadMapId = if typeof(payload.mapId) == "string" and payload.mapId ~= "" then payload.mapId else nil
	local payloadMapPivot = if isFiniteCFrame(payload.mapPivot) then payload.mapPivot else nil
	local currentContext = getCurrentMapContextForRound(payloadRoundId)
	if payloadMapId then
		local mapPivot = payloadMapPivot
		if not mapPivot and currentContext and currentContext.mapId == payloadMapId then
			mapPivot = currentContext.mapPivot
		end
		return {
			mapId = payloadMapId,
			mapPivot = mapPivot,
			roundId = payloadRoundId,
		}
	end
	return currentContext
end

local function pruneRecentKillReplayEvents(currentTime: number)
	for userId, record in pairs(recentKillReplayEventsByVictimUserId) do
		if typeof(record) ~= "table" or not isFiniteNumber(record.expiresAt) or record.expiresAt <= currentTime then
			recentKillReplayEventsByVictimUserId[userId] = nil
		end
	end
end

local function storeRecentKillReplayEvent(killEvent)
	if typeof(killEvent) ~= "table" or not isFiniteNumber(killEvent.victimUserId) then
		return nil
	end

	local eventCopy = copyReplayEvent(killEvent)
	if typeof(eventCopy) ~= "table" then
		return nil
	end

	local currentTime = workspace:GetServerTimeNow()
	local victimUserId = math.floor(killEvent.victimUserId)
	recentKillReplayEventsByVictimUserId[victimUserId] = {
		event = eventCopy,
		expiresAt = currentTime + RECENT_KILL_REPLAY_TTL_SECONDS,
	}
	pruneRecentKillReplayEvents(currentTime)
	return eventCopy
end

local function getRecentKillReplayEventForUserId(userId: any)
	if not isFiniteNumber(userId) then
		return nil
	end

	local resolvedUserId = math.floor(userId)
	local currentTime = workspace:GetServerTimeNow()
	pruneRecentKillReplayEvents(currentTime)

	local record = recentKillReplayEventsByVictimUserId[resolvedUserId]
	if typeof(record) ~= "table" or typeof(record.event) ~= "table" then
		return nil
	end
	if isFiniteNumber(currentRoundId) and record.event.roundId ~= currentRoundId then
		recentKillReplayEventsByVictimUserId[resolvedUserId] = nil
		return nil
	end
	return record.event
end

local function getRecentKillReplayEventForPlayer(player: Player)
	if not (typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players) then
		return nil
	end
	return getRecentKillReplayEventForUserId(player.UserId)
end

local function getKillClipCaps()
	return ReplayClipUtil.GetKillClipCaps()
end

local function getPOTGClipCaps()
	return ReplayClipUtil.GetPOTGClipCaps()
end

local function estimateClipPayloadSize(clip)
	return ReplayClipUtil.EstimateClipPayloadSize(clip)
end

local function recordClipOptimization(mode: string, before, after, stats, caps)
	ReplayClipPolicy.AccumulateOptimizationTotals(clipOptimizationTotals, stats)
	lastClipOptimizationDebug =
		ReplayClipPolicy.BuildOptimizationDebug(mode, currentRoundId, before, after, stats, caps)
end

local function optimizeClipPayloadForSend(payload, caps, mode: string)
	local token = RuntimeProfiler.Begin("Server/Replay/OptimizePayload")
	local optimized, debug = ReplayClipPolicy.OptimizeClipPayloadForSend(payload, caps, mode)
	if not optimized then
		RuntimeProfiler.End("Server/Replay/OptimizePayload", token)
		return nil
	end
	recordClipOptimization(mode, debug.before, debug.after, debug.stats, debug.caps)
	optimizedReplayPayloads[optimized] = true
	if debug and debug.before and debug.after then
		RuntimeProfiler.Count("Server/Replay/OptimizedPayloadWeightBefore", debug.before.total or 0)
		RuntimeProfiler.Count("Server/Replay/OptimizedPayloadWeightAfter", debug.after.total or 0)
	end
	RuntimeProfiler.End("Server/Replay/OptimizePayload", token)
	return optimized
end

local function isClipWithinCaps(clip, minFrames: number, caps): boolean
	return ReplayClipUtil.IsClipWithinCaps(clip, minFrames, caps)
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, ReplayConstants.REMOTES_FOLDER_NAME, {
		dedupe = true,
	})
end

local function ensureReplayAssetsFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, REPLAY_ASSETS_FOLDER_NAME)
end

local function ensureRemote(folder: Folder, name: string): RemoteEvent
	return RemoteUtil.EnsureRemoteEvent(folder, name, true)
end

local function getReplayRemote(name: string): RemoteEvent?
	return RemoteUtil.GetRemoteEvent(ReplicatedStorage, ReplayConstants.REMOTES_FOLDER_NAME, name)
end

local function getTeamName(player: Player): string?
	local team = player.Team
	return if team then team.Name else nil
end

local function getBooleanAttribute(instance: Instance, attributeName: string): boolean?
	local value = instance:GetAttribute(attributeName)
	return if typeof(value) == "boolean" then value else nil
end

local function getNumberAttribute(instance: Instance, attributeName: string): number?
	local value = instance:GetAttribute(attributeName)
	return if isFiniteNumber(value) then value else nil
end

local function getStringAttribute(instance: Instance, attributeName: string): string?
	local value = instance:GetAttribute(attributeName)
	return if typeof(value) == "string" and value ~= "" then value else nil
end

local function clampVectorMagnitude(value: any, maxMagnitude: number): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	if value.X ~= value.X or value.Y ~= value.Y or value.Z ~= value.Z then
		return nil
	end

	local magnitude = value.Magnitude
	if magnitude <= maxMagnitude then
		return value
	end
	if magnitude <= 0 then
		return Vector3.zero
	end
	return value.Unit * maxMagnitude
end

local function inferGrounded(humanoid: Humanoid): boolean
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		return true
	end

	local state = humanoid:GetState()
	return state ~= Enum.HumanoidStateType.Freefall
		and state ~= Enum.HumanoidStateType.FallingDown
		and state ~= Enum.HumanoidStateType.Jumping
end

local function getInferredAnimationState(player: Player, character: Model, humanoid: Humanoid, rootPart: BasePart)
	local linearVelocity = rootPart.AssemblyLinearVelocity
	local horizontalVelocity = Vector3.new(linearVelocity.X, 0, linearVelocity.Z)
	local effectiveSpeed = getNumberAttribute(character, "Movement_EffectiveSpeed") or horizontalVelocity.Magnitude
	local moveMagnitude = getNumberAttribute(character, "Movement_MoveMagnitude")
	if not moveMagnitude then
		moveMagnitude = if effectiveSpeed > 0.5 then math.clamp(effectiveSpeed / 24, 0, 1) else 0
	end

	local bombCooking = player:GetAttribute(BombConfig.Attributes.Cooking) == true
	local bombCookStartedAt = getNumberAttribute(player, BombConfig.Attributes.CookStartedAt)
	local bombSkinId = BombSkinConfig.NormalizeSkinId(player:GetAttribute(BombSkinConfig.AttributeName))
	local state = {
		grounded = getBooleanAttribute(character, "Movement_Grounded") or inferGrounded(humanoid),
		sprinting = getBooleanAttribute(character, "Movement_Sprinting") or effectiveSpeed >= 21,
		crouching = getBooleanAttribute(character, "Movement_Crouching") or false,
		sliding = getBooleanAttribute(character, "Movement_Sliding") or false,
		effectiveSpeed = effectiveSpeed,
		moveMagnitude = moveMagnitude,
		jumpSerial = getNumberAttribute(character, "Movement_JumpSerial"),
		lastJumpKind = getStringAttribute(character, "Movement_LastJumpKind"),
		shiftLocked = getBooleanAttribute(character, "Camera_ShiftLocked") or false,
		linearVelocity = clampVectorMagnitude(linearVelocity, MAX_REPLAY_ANIMATION_SPEED) or Vector3.zero,
		bombCooking = bombCooking,
		bombCookStartedAt = bombCookStartedAt,
		bombSkinId = bombSkinId,
	}

	if bombCooking then
		state.heldBomb = {
			bombType = BombConfig.RuntimeBombName,
			bombSkinId = if bombSkinId ~= "" then bombSkinId else BombSkinConfig.DefaultSkinId,
			fuseStartedAt = bombCookStartedAt,
			fuseEndsAt = if isFiniteNumber(bombCookStartedAt) then bombCookStartedAt + BombConfig.FuseSeconds else nil,
			visualScale = BombConfig.HeldVisualScale,
			sizeScale = BombConfig.HeldVisualScale,
		}
	end

	return state
end

local function mergeClientAnimationState(inferredState, clientState)
	if typeof(clientState) ~= "table" then
		return inferredState
	end

	local merged = table.clone(inferredState)
	for key, value in pairs(clientState) do
		if key == "sampleTime" or key == "camera" or key == "pose" then
			continue
		end
		merged[key] = value
	end

	merged.linearVelocity = inferredState.linearVelocity
	merged.bombCooking = inferredState.bombCooking
	merged.bombCookStartedAt = inferredState.bombCookStartedAt
	merged.bombSkinId = inferredState.bombSkinId
	merged.heldBomb = inferredState.heldBomb or merged.heldBomb
	return merged
end

local function sanitizeReplayString(value: any, maxLength: number): string?
	if typeof(value) ~= "string" or value == "" then
		return nil
	end
	return string.sub(value, 1, maxLength)
end

local function sanitizeReplayCamera(payload, sampleTime: number)
	if typeof(payload) ~= "table" then
		return nil
	end
	if not isFiniteCFrame(payload.cframe) then
		return nil
	end

	return {
		sampleTime = sampleTime,
		cframe = payload.cframe,
		focus = if isFiniteCFrame(payload.focus) then payload.focus else nil,
		fieldOfView = if isFiniteNumber(payload.fieldOfView)
			then math.clamp(payload.fieldOfView, MIN_REPLAY_CAMERA_FOV, MAX_REPLAY_CAMERA_FOV)
			else nil,
	}
end

local function sanitizeReplayPose(payload, sampleTime: number)
	if typeof(payload) ~= "table" or typeof(payload.joints) ~= "table" then
		return nil
	end

	local joints = {}
	for _, joint in ipairs(payload.joints) do
		if #joints >= MAX_REPLAY_POSE_JOINTS then
			break
		end
		if typeof(joint) ~= "table" then
			continue
		end

		local transform = joint.transform
		if not isFiniteCFrame(transform) then
			continue
		end

		local name = sanitizeReplayString(joint.name, MAX_REPLAY_JOINT_NAME_LENGTH)
		local key = sanitizeReplayString(joint.key, MAX_REPLAY_JOINT_NAME_LENGTH * 3)
		if not name and not key then
			continue
		end

		table.insert(joints, {
			name = name,
			part0 = sanitizeReplayString(joint.part0, MAX_REPLAY_JOINT_NAME_LENGTH),
			part1 = sanitizeReplayString(joint.part1, MAX_REPLAY_JOINT_NAME_LENGTH),
			key = key,
			transform = transform,
		})
	end

	if #joints == 0 then
		return nil
	end
	return {
		sampleTime = sampleTime,
		joints = joints,
	}
end

local function sanitizeReplayHeldBomb(payload)
	if typeof(payload) ~= "table" then
		return nil
	end

	local heldBomb = {}
	local bombSkinId = BombSkinConfig.NormalizeSkinId(payload.bombSkinId)
	if bombSkinId ~= "" then
		heldBomb.bombSkinId = bombSkinId
	end
	local bombType = sanitizeReplayString(payload.bombType, 48)
	if bombType then
		heldBomb.bombType = bombType
	end
	if isFiniteNumber(payload.fuseStartedAt) then
		heldBomb.fuseStartedAt = payload.fuseStartedAt
	end
	if isFiniteNumber(payload.fuseEndsAt) then
		heldBomb.fuseEndsAt = payload.fuseEndsAt
	end
	if isFiniteNumber(payload.visualScale) then
		heldBomb.visualScale = math.clamp(payload.visualScale, 0.25, 5)
	end
	if isFiniteNumber(payload.sizeScale) then
		heldBomb.sizeScale = math.clamp(payload.sizeScale, 0.25, 5)
	end

	return if next(heldBomb) then heldBomb else nil
end

local function sanitizeClientAnimationState(payload, currentTime: number)
	if typeof(payload) ~= "table" then
		return nil
	end

	local sampleTime = if isFiniteNumber(payload.sampleTime) then payload.sampleTime else currentTime
	if math.abs(sampleTime - currentTime) > MAX_CLIENT_REPLAY_SAMPLE_SKEW then
		return nil
	end

	local state = {}
	state.sampleTime = sampleTime

	local function copyBoolean(sourceName: string, targetName: string?)
		local value = payload[sourceName]
		if typeof(value) == "boolean" then
			state[targetName or sourceName] = value
		end
	end

	local function copyNumber(sourceName: string, targetName: string?, minValue: number?, maxValue: number?)
		local value = payload[sourceName]
		if not isFiniteNumber(value) then
			return
		end

		if minValue then
			value = math.max(value, minValue)
		end
		if maxValue then
			value = math.min(value, maxValue)
		end
		state[targetName or sourceName] = value
	end

	local function copyString(sourceName: string, targetName: string?, maxLength: number?)
		local value = payload[sourceName]
		if typeof(value) ~= "string" or value == "" then
			return
		end

		state[targetName or sourceName] = string.sub(value, 1, maxLength or 32)
	end

	copyBoolean("grounded")
	copyBoolean("sprinting")
	copyBoolean("crouching")
	copyBoolean("sliding")
	copyBoolean("shiftLocked")
	copyBoolean("bombCooking")
	copyNumber("effectiveSpeed", nil, 0, MAX_REPLAY_ANIMATION_SPEED)
	copyNumber("moveMagnitude", nil, 0, 1)
	copyNumber("jumpSerial", nil, 0, 1000000)
	copyNumber("bombCookStartedAt", nil, 0, math.huge)
	copyString("bombSkinId", nil, BombSkinConfig.MaxSkinIdLength)
	copyString("lastJumpKind", nil, 32)

	local heldBomb = sanitizeReplayHeldBomb(payload.heldBomb)
	if heldBomb then
		state.heldBomb = heldBomb
	end

	local linearVelocity = clampVectorMagnitude(payload.linearVelocity, MAX_REPLAY_ANIMATION_SPEED)
	if linearVelocity then
		state.linearVelocity = linearVelocity
	end
	if isFiniteCFrame(payload.rootCFrame) then
		state.rootCFrame = payload.rootCFrame
	end

	local camera = sanitizeReplayCamera(payload.camera, sampleTime)
	if camera then
		state.camera = camera
	end

	local pose = sanitizeReplayPose(payload.pose, sampleTime)
	if pose then
		state.pose = pose
	end

	return state
end

local function pruneClientReplaySamples(userId: number, cutoffTime: number)
	local samples = clientReplaySamplesByUserId[userId]
	if typeof(samples) ~= "table" then
		return
	end

	local writeIndex = 1
	for readIndex = 1, #samples do
		local sample = samples[readIndex]
		if typeof(sample) == "table" and isFiniteNumber(sample.sampleTime) and sample.sampleTime >= cutoffTime then
			samples[writeIndex] = sample
			writeIndex += 1
		end
	end
	for index = writeIndex, #samples do
		samples[index] = nil
	end
end

local function storeClientReplaySample(player: Player, state, receivedAt: number)
	local token = RuntimeProfiler.Begin("Server/Replay/StoreClientSample")
	if typeof(state) ~= "table" or not isFiniteNumber(state.sampleTime) then
		RuntimeProfiler.End("Server/Replay/StoreClientSample", token)
		return
	end

	local userId = player.UserId
	local samples = clientReplaySamplesByUserId[userId]
	if typeof(samples) ~= "table" then
		samples = {}
		clientReplaySamplesByUserId[userId] = samples
	end

	table.insert(samples, {
		receivedAt = receivedAt,
		sampleTime = state.sampleTime,
		state = state,
	})
	pruneClientReplaySamples(userId, receivedAt - CLIENT_REPLAY_SAMPLE_HISTORY_SECONDS)
	RuntimeProfiler.Count("Server/Replay/ClientSamplesStored")
	RuntimeProfiler.Gauge("Server/Replay/ClientSampleRecords", countClientReplaySampleRecords())
	RuntimeProfiler.End("Server/Replay/StoreClientSample", token)
end

local function getClientReplaySample(player: Player, timestamp: number)
	local samples = clientReplaySamplesByUserId[player.UserId]
	if typeof(samples) ~= "table" or #samples == 0 or not isFiniteNumber(timestamp) then
		return nil
	end

	local bestState = nil
	local bestDelta = math.huge
	for _, sample in ipairs(samples) do
		if typeof(sample) ~= "table" or typeof(sample.state) ~= "table" or not isFiniteNumber(sample.sampleTime) then
			continue
		end

		local delta = math.abs(sample.sampleTime - timestamp)
		if delta < bestDelta then
			bestDelta = delta
			bestState = sample.state
		end
	end

	if bestDelta > MAX_REPLAY_VISUAL_SAMPLE_AGE then
		return nil
	end
	return bestState
end

local function receiveClientAnimationState(player: Player, payload)
	if not (typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players) then
		return
	end

	local currentTime = workspace:GetServerTimeNow()
	local lastReceivedAt = lastAnimationStateAtByUserId[player.UserId]
	if isFiniteNumber(lastReceivedAt) and currentTime - lastReceivedAt < 1 / CLIENT_ANIMATION_STATE_MAX_RATE then
		return
	end
	lastAnimationStateAtByUserId[player.UserId] = currentTime

	local state = sanitizeClientAnimationState(payload, currentTime)
	if not state then
		return
	end

	latestAnimationStateByUserId[player.UserId] = {
		receivedAt = currentTime,
		state = state,
	}
	storeClientReplaySample(player, state, currentTime)
end

local function bindAnimationStateRemote(remote: RemoteEvent)
	if animationStateConnection then
		animationStateConnection:Disconnect()
		animationStateConnection = nil
	end

	animationStateConnection = remote.OnServerEvent:Connect(receiveClientAnimationState)
end

local function handleKillReplayRequest(player: Player, payload)
	if not (typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players) then
		return
	end

	local currentTime = workspace:GetServerTimeNow()
	local lastRequestAt = lastKillReplayRequestAtByUserId[player.UserId]
	if isFiniteNumber(lastRequestAt) and currentTime - lastRequestAt < KILL_REPLAY_REQUEST_COOLDOWN_SECONDS then
		RuntimeProfiler.Count("Server/Replay/Death/RequestThrottled")
		if DEBUG_KILL_REPLAY_SEND then
			warn("[ReplayService] KillReplay request throttled", player.Name)
		end
		return
	end

	local reason = if typeof(payload) == "table" and typeof(payload.reason) == "string" then payload.reason else "ClientRequest"
	local killEvent = getRecentKillReplayEventForPlayer(player)
	if not killEvent then
		RuntimeProfiler.Count("Server/Replay/Death/RequestNoRecentKillEvent")
		debugKillReplaySend("request-no-recent-kill-event", {
			victimUserId = player.UserId,
		})
		if DEBUG_KILL_REPLAY_SEND then
			warn(("[ReplayService] KillReplay request no recent event player=%s reason=%s"):format(player.Name, reason))
		end
		return
	end

	lastKillReplayRequestAtByUserId[player.UserId] = currentTime
	RuntimeProfiler.Count("Server/Replay/Death/RequestResend")
	if DEBUG_KILL_REPLAY_SEND then
		warn(
			("[ReplayService] KillReplay request resend player=%s reason=%s timestamp=%s"):format(
				player.Name,
				reason,
				tostring(killEvent.timestamp)
			)
		)
	end

	if type(sendKillReplayForEvent) ~= "function" then
		debugKillReplaySend("request-send-unavailable", killEvent)
		return
	end
	sendKillReplayForEvent(killEvent)
end

local function bindKillReplayRequestRemote(remote: RemoteEvent)
	if killReplayRequestConnection then
		killReplayRequestConnection:Disconnect()
		killReplayRequestConnection = nil
	end

	killReplayRequestConnection = remote.OnServerEvent:Connect(handleKillReplayRequest)
end

local function getBombProjectileService()
	if bombProjectileService then
		return bombProjectileService
	end

	local services = ServerScriptService:FindFirstChild("Services")
	local module = services and services:FindFirstChild("BombProjectileService")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end

	local ok, service = pcall(require, module)
	if ok and typeof(service) == "table" then
		bombProjectileService = service
		return bombProjectileService
	end
	return nil
end

local function getPlayerSnapshot(player: Player, timestamp: number)
	local token = RuntimeProfiler.Begin("Server/Replay/GetPlayerSnapshot")
	local character = player.Character
	if not character then
		RuntimeProfiler.End("Server/Replay/GetPlayerSnapshot", token)
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and rootPart and rootPart:IsA("BasePart")) then
		RuntimeProfiler.End("Server/Replay/GetPlayerSnapshot", token)
		return nil
	end

	local inferredAnimationState = getInferredAnimationState(player, character, humanoid, rootPart)
	local clientReplayState = getClientReplaySample(player, timestamp)
	local animationState = mergeClientAnimationState(inferredAnimationState, clientReplayState)
	local cameraState = if typeof(clientReplayState) == "table" then clientReplayState.camera else nil
	local poseState = if typeof(clientReplayState) == "table" then clientReplayState.pose else nil
	local serverCFrame = rootPart.CFrame
	local clientRootCFrame = if typeof(clientReplayState) == "table" and isFiniteCFrame(clientReplayState.rootCFrame)
		then clientReplayState.rootCFrame
		else nil
	local replayCFrame = clientRootCFrame or serverCFrame

	local snapshot = {
		userId = player.UserId,
		name = player.Name,
		displayName = if player.DisplayName ~= "" then player.DisplayName else player.Name,
		isNPC = false,
		cframe = replayCFrame,
		serverCFrame = serverCFrame,
		rootSource = if clientRootCFrame then "client" else "server",
		health = humanoid.Health,
		maxHealth = humanoid.MaxHealth,
		alive = humanoid.Health > 0,
		teamName = getTeamName(player),
		animationState = animationState,
		camera = cameraState,
		pose = poseState,
		bombSkinId = animationState.bombSkinId,
	}
	RuntimeProfiler.End("Server/Replay/GetPlayerSnapshot", token)
	return snapshot
end

local function getFirstBasePart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end

	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function readStringAttribute(instance: Instance, attributeNames: { string }): string?
	for _, attributeName in ipairs(attributeNames) do
		local value = instance:GetAttribute(attributeName)
		if typeof(value) == "string" and value ~= "" then
			return value
		end
	end
	return nil
end

local function readNumberAttribute(instance: Instance, attributeNames: { string }): number?
	for _, attributeName in ipairs(attributeNames) do
		local value = instance:GetAttribute(attributeName)
		if isFiniteNumber(value) then
			return value
		end
	end
	return nil
end

local function getBombSnapshot(instance: Instance)
	local rootPart = getFirstBasePart(instance)
	if not rootPart then
		return nil
	end

	local bombId = readStringAttribute(instance, { "ProjectileId", "BombId", "BombID" })
		or readStringAttribute(rootPart, { "ProjectileId", "BombId", "BombID" })
		or instance.Name
	local ownerUserId = readNumberAttribute(instance, { "OwnerUserId", "OwnerUserID", "OwnerId", "OwnerID" })
		or readNumberAttribute(rootPart, { "OwnerUserId", "OwnerUserID", "OwnerId", "OwnerID" })
	local bombType = readStringAttribute(instance, { "BombType", "Type" })
		or readStringAttribute(rootPart, { "BombType", "Type" })
	local bombSkinId = BombSkinConfig.NormalizeSkinId(
		readStringAttribute(instance, { "BombSkinId", "SkinId", "SkinID" })
			or readStringAttribute(rootPart, { "BombSkinId", "SkinId", "SkinID" })
	)
	local sizeScale = readNumberAttribute(instance, { "SizeScale", "Scale" })
		or readNumberAttribute(rootPart, { "SizeScale", "Scale" })
	local fuseStartedAt = readNumberAttribute(instance, { "FuseStartedAt", "FuseStartTime" })
		or readNumberAttribute(rootPart, { "FuseStartedAt", "FuseStartTime" })
	local fuseEndsAt = readNumberAttribute(instance, { "FuseEndsAt", "ExplodeAt", "FuseEndTime" })
		or readNumberAttribute(rootPart, { "FuseEndsAt", "ExplodeAt", "FuseEndTime" })

	return {
		bombId = bombId,
		ownerUserId = ownerUserId,
		bombType = bombType,
		bombSkinId = if bombSkinId ~= "" then bombSkinId else BombSkinConfig.DefaultSkinId,
		cframe = rootPart.CFrame,
		assemblyLinearVelocity = rootPart.AssemblyLinearVelocity,
		sizeScale = sizeScale,
		fuseStartedAt = fuseStartedAt,
		fuseEndsAt = fuseEndsAt,
	}
end

local function appendBombSnapshots(target, snapshots)
	if typeof(snapshots) ~= "table" then
		return
	end

	for _, snapshot in ipairs(snapshots) do
		if #target >= ReplayConstants.MAX_REPLAY_BOMBS then
			break
		end
		if typeof(snapshot) == "table" then
			table.insert(target, snapshot)
		end
	end
end

local function getBombSnapshots()
	local token = RuntimeProfiler.Begin("Server/Replay/GetBombSnapshots")
	local bombs = {}
	lastBombSource = "None"
	local projectileService = getBombProjectileService()
	lastBombServiceSnapshotAvailable = type(projectileService and projectileService.GetReplaySnapshots) == "function"

	if lastBombServiceSnapshotAvailable then
		local ok, snapshots = pcall(function()
			return projectileService:GetReplaySnapshots(ReplayConstants.MAX_REPLAY_BOMBS)
		end)
		lastBombServiceSnapshotAvailable = ok
		if ok then
			appendBombSnapshots(bombs, snapshots)
			if #bombs > 0 then
				lastBombSource = "BombProjectileService"
			end
		end
	end

	if #bombs >= ReplayConstants.MAX_REPLAY_BOMBS then
		lastBombContainerFound = workspace:FindFirstChild(BombConfig.ProjectileFolderName) ~= nil
		RuntimeProfiler.Gauge("Server/Replay/BombSnapshots", #bombs)
		RuntimeProfiler.End("Server/Replay/GetBombSnapshots", token)
		return bombs
	end

	local bombFolder = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	if not bombFolder then
		lastBombContainerFound = false
		RuntimeProfiler.Gauge("Server/Replay/BombSnapshots", #bombs)
		RuntimeProfiler.End("Server/Replay/GetBombSnapshots", token)
		return bombs
	end

	lastBombContainerFound = true
	for _, child in ipairs(bombFolder:GetChildren()) do
		if #bombs >= ReplayConstants.MAX_REPLAY_BOMBS then
			break
		end

		local snapshot = getBombSnapshot(child)
		if snapshot then
			table.insert(bombs, snapshot)
			if lastBombSource == "None" then
				lastBombSource = "WorkspaceFolder"
			elseif lastBombSource ~= "WorkspaceFolder" then
				lastBombSource = "Mixed"
			end
		end
	end

	RuntimeProfiler.Gauge("Server/Replay/BombSnapshots", #bombs)
	RuntimeProfiler.End("Server/Replay/GetBombSnapshots", token)
	return bombs
end

local function buildFrame(timestamp: number)
	local token = RuntimeProfiler.Begin("Server/Replay/CaptureFrame")
	local players = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if #players >= ReplayConstants.MAX_REPLAY_PLAYERS then
			break
		end

		local snapshot = getPlayerSnapshot(player, timestamp)
		if snapshot then
			table.insert(players, snapshot)
		end
	end
	if #players < ReplayConstants.MAX_REPLAY_PLAYERS then
		for _, snapshot in ipairs(StudioAICombatants.GetReplaySnapshots(ReplayConstants.MAX_REPLAY_PLAYERS - #players, timestamp)) do
			table.insert(players, snapshot)
		end
	end

	local bombs = getBombSnapshots()
	lastFramePlayerCount = #players
	lastFrameBombCount = #bombs
	RuntimeProfiler.Gauge("Server/Replay/FramePlayers", #players)
	RuntimeProfiler.Gauge("Server/Replay/FrameBombs", #bombs)
	RuntimeProfiler.Count("Server/Replay/FramesCaptured")

	local frame = {
		timestamp = timestamp,
		players = players,
		bombs = bombs,
	}
	RuntimeProfiler.End("Server/Replay/CaptureFrame", token)
	return frame
end

local function ensureBuffer()
	if not ReplayService.Buffer then
		ReplayService.Buffer = ReplayBuffer.new(ReplayConstants.BUFFER_SECONDS)
	end
	return ReplayService.Buffer
end

local function ensureRemotes()
	local remotesFolder = ensureRemotesFolder()
	for _, remoteName in pairs(ReplayConstants.REMOTES) do
		ensureRemote(remotesFolder, remoteName)
	end

	local animationStateRemoteName = ReplayConstants.REMOTES.AnimationState
	if typeof(animationStateRemoteName) == "string" and animationStateRemoteName ~= "" then
		local remote = ensureRemote(remotesFolder, animationStateRemoteName)
		bindAnimationStateRemote(remote)
	end

	local killReplayRequestRemoteName = ReplayConstants.REMOTES.KillReplayRequest
	if typeof(killReplayRequestRemoteName) == "string" and killReplayRequestRemoteName ~= "" then
		local remote = ensureRemote(remotesFolder, killReplayRequestRemoteName)
		bindKillReplayRequestRemote(remote)
	end
end

local function unwrapOptionalSelf(first, second, third)
	if first == ReplayService then
		return second, third
	end
	return first, second
end

local function getUserIdPlayer(userId: any): Player?
	if not isFiniteNumber(userId) then
		return nil
	end

	local resolvedUserId = math.floor(userId)
	local ok, player = pcall(function()
		return Players:GetPlayerByUserId(resolvedUserId)
	end)
	if ok and player then
		return player
	end

	for _, candidate in ipairs(Players:GetPlayers()) do
		if candidate.UserId == resolvedUserId then
			return candidate
		end
	end

	return nil
end

local function getKillReplayRecipients(payload): { Player }
	local recipients = {}
	local victimPlayer = getUserIdPlayer(payload.victimUserId)
	if victimPlayer then
		table.insert(recipients, victimPlayer)
	end

	return recipients
end

local function isClipReasonable(clip): boolean
	return isClipWithinCaps(clip, MIN_KILL_REPLAY_FRAMES, getKillClipCaps())
end

local function isKillReplayClipSendable(clip): boolean
	return isClipWithinCaps(clip, MIN_KILL_REPLAY_SEND_FRAMES, getKillClipCaps())
end

local function isPOTGClipReasonable(clip): boolean
	return isClipWithinCaps(clip, MIN_POTG_REPLAY_FRAMES, getPOTGClipCaps())
end

local function isFallbackPOTGClipSendable(clip): boolean
	return isClipWithinCaps(clip, MIN_POTG_FALLBACK_SEND_FRAMES, getPOTGClipCaps())
end

debugKillReplaySend = function(status: string, payload)
	local token = RuntimeProfiler.Begin("Server/Replay/Death/DebugKillReplaySummary")
	local estimate = estimateClipPayloadSize(payload)
	local summary = {
		status = status,
		startTime = if typeof(payload) == "table" and isFiniteNumber(payload.startTime) then payload.startTime else 0,
		endTime = if typeof(payload) == "table" and isFiniteNumber(payload.endTime) then payload.endTime else 0,
		frames = estimate.frames,
		playerSnapshots = estimate.playerSnapshots,
		bombSnapshots = estimate.bombSnapshots,
		events = estimate.events,
		destructionEvents = estimate.destructionEvents,
		primaryEventTime = if typeof(payload) == "table" and isFiniteNumber(payload.primaryEventTime)
			then payload.primaryEventTime
			else nil,
		killerUserId = if typeof(payload) == "table" then payload.killerUserId else nil,
		victimUserId = if typeof(payload) == "table" then payload.victimUserId else nil,
		roundId = if typeof(payload) == "table" then payload.roundId else nil,
		mapId = if typeof(payload) == "table" then payload.mapId else nil,
		optimization = lastClipOptimizationDebug,
	}
	lastKillReplayDebug = summary
	RuntimeProfiler.Count("Server/Replay/Death/DebugSummaryFrames", estimate.frames)
	RuntimeProfiler.Count("Server/Replay/Death/DebugSummaryEvents", estimate.events)
	RuntimeProfiler.Count("Server/Replay/Death/DebugSummaryDestructionEvents", estimate.destructionEvents)
	RuntimeProfiler.End("Server/Replay/Death/DebugKillReplaySummary", token)

	if not DEBUG_KILL_REPLAY_SEND then
		return
	end

	warn(
		("[ReplayService] KillReplay %s round=%s map=%s start=%.3f kill=%s end=%.3f frames=%d events=%d killer=%s victim=%s"):format(
			status,
			tostring(summary.roundId),
			tostring(summary.mapId),
			summary.startTime,
			if summary.primaryEventTime then ("%.3f"):format(summary.primaryEventTime) else "nil",
			summary.endTime,
			estimate.frames,
			estimate.events,
			tostring(summary.killerUserId),
			tostring(summary.victimUserId)
		)
	)
end

local function debugPOTGReplaySend(status: string, payload, extra)
	local estimate = estimateClipPayloadSize(payload)
	local summary = {
		status = status,
		startTime = if typeof(payload) == "table" and isFiniteNumber(payload.startTime) then payload.startTime else 0,
		endTime = if typeof(payload) == "table" and isFiniteNumber(payload.endTime) then payload.endTime else 0,
		frames = estimate.frames,
		playerSnapshots = estimate.playerSnapshots,
		bombSnapshots = estimate.bombSnapshots,
		events = estimate.events,
		destructionEvents = estimate.destructionEvents,
		playerUserId = if typeof(payload) == "table" then payload.playerUserId else nil,
		score = if typeof(payload) == "table" then payload.score else nil,
		reason = if typeof(payload) == "table" then payload.reason else nil,
		roundId = if typeof(payload) == "table" then payload.roundId else nil,
		mapId = if typeof(payload) == "table" then payload.mapId else nil,
		clipSource = if typeof(extra) == "table" and typeof(extra.clipSource) == "string"
			then extra.clipSource
			elseif typeof(payload) == "table" then payload.potgClipSource
			else nil,
		candidateStartTime = if typeof(extra) == "table" then extra.candidateStartTime else nil,
		candidateEndTime = if typeof(extra) == "table" then extra.candidateEndTime else nil,
		candidatePrimaryEventTime = if typeof(extra) == "table" then extra.candidatePrimaryEventTime else nil,
		candidatePlayerUserId = if typeof(extra) == "table" then extra.candidatePlayerUserId else nil,
		candidateScore = if typeof(extra) == "table" then extra.candidateScore else nil,
		candidateReason = if typeof(extra) == "table" then extra.candidateReason else nil,
		sentPlayers = if typeof(extra) == "table" then extra.sentPlayers else nil,
		skippedPlayers = if typeof(extra) == "table" then extra.skippedPlayers else nil,
		optimization = lastClipOptimizationDebug,
	}
	lastPOTGReplayDebug = summary

	if not DEBUG_POTG_SEND then
		return
	end

	warn(
		("[ReplayService] POTG %s source=%s round=%s map=%s start=%.3f end=%.3f frames=%d events=%d player=%s score=%s sent=%s skipped=%s reason=%s"):format(
			status,
			tostring(summary.clipSource),
			tostring(summary.roundId),
			tostring(summary.mapId),
			summary.startTime,
			summary.endTime,
			estimate.frames,
			estimate.events,
			tostring(summary.playerUserId),
			tostring(summary.score),
			tostring(summary.sentPlayers),
			tostring(summary.skippedPlayers),
			tostring(summary.reason)
		)
	)
end

local function copyDebrisPayloadBlock(block)
	if typeof(block) ~= "table" or not isFiniteVector3(block.size) then
		return nil
	end
	if block.size.X <= 0 or block.size.Y <= 0 or block.size.Z <= 0 then
		return nil
	end
	if isFiniteCFrame(block.cframe) then
		return {
			cframe = block.cframe,
			size = block.size,
		}
	end
	if not isFiniteVector3(block.center) then
		return nil
	end

	return {
		center = block.center,
		size = block.size,
	}
end

local function copyDebrisPayload(payload, remainingBlocks: number)
	if typeof(payload) ~= "table" or remainingBlocks <= 0 then
		return nil, 0
	end
	if payload.compact == true then
		if not isFiniteVector3(payload.explosionPosition) then
			return nil, 0
		end
		local sampleCount = math.clamp(
			math.floor(if isFiniteNumber(payload.sampleCount) then payload.sampleCount else 0),
			0,
			remainingBlocks
		)
		if sampleCount <= 0 then
			return nil, 0
		end

		local copy = {
			compact = true,
			explosionPosition = payload.explosionPosition,
			sourceBlockCount = if isFiniteNumber(payload.sourceBlockCount)
				then math.max(math.floor(payload.sourceBlockCount), 0)
				else sampleCount,
			sampleCount = sampleCount,
			averageSize = if isFiniteVector3(payload.averageSize) then payload.averageSize else Vector3.new(1.25, 1.25, 1.25),
			radius = if isFiniteNumber(payload.radius) then math.clamp(payload.radius, 1, 80) else 8,
		}
		if typeof(payload.materialName) == "string" and payload.materialName ~= "" then
			copy.materialName = payload.materialName
		end
		if isFiniteColor3(payload.color) then
			copy.color = payload.color
		end
		if isFiniteNumber(payload.transparency) then
			copy.transparency = math.clamp(payload.transparency, 0, 1)
		end
		if isFiniteNumber(payload.reflectance) then
			copy.reflectance = math.clamp(payload.reflectance, 0, 1)
		end
		if isFiniteNumber(payload.speedMin) then
			copy.speedMin = math.max(payload.speedMin, 0)
		end
		if isFiniteNumber(payload.speedMax) then
			copy.speedMax = math.max(payload.speedMax, 0)
		end
		if isFiniteNumber(payload.lifetime) then
			copy.lifetime = math.clamp(payload.lifetime, 0.1, 10)
		end
		if typeof(payload.useGraphicsQualitySampling) == "boolean" then
			copy.useGraphicsQualitySampling = payload.useGraphicsQualitySampling
		end
		if isFiniteNumber(payload.automaticQualityLevel) then
			copy.automaticQualityLevel = math.clamp(math.floor(payload.automaticQualityLevel), 1, 10)
		end
		if isFiniteNumber(payload.maxSamplingDivisor) then
			copy.maxSamplingDivisor = math.clamp(math.floor(payload.maxSamplingDivisor), 1, 20)
		end
		if isFiniteNumber(payload.seed) then
			copy.seed = math.clamp(math.floor(payload.seed), 1, MAX_RANDOM_SEED)
		end
		return copy, sampleCount
	end
	if not (isFiniteCFrame(payload.sourceCFrame) and isFiniteVector3(payload.explosionPosition)) then
		return nil, 0
	end
	if typeof(payload.blocks) ~= "table" then
		return nil, 0
	end

	local blocks = {}
	for _, block in ipairs(payload.blocks) do
		if #blocks >= remainingBlocks then
			break
		end

		local copiedBlock = copyDebrisPayloadBlock(block)
		if copiedBlock then
			table.insert(blocks, copiedBlock)
		end
	end
	if #blocks == 0 then
		return nil, 0
	end

	local copy = {
		sourceCFrame = payload.sourceCFrame,
		explosionPosition = payload.explosionPosition,
		blocks = blocks,
	}
	if typeof(payload.materialName) == "string" and payload.materialName ~= "" then
		copy.materialName = payload.materialName
	end
	if isFiniteColor3(payload.color) then
		copy.color = payload.color
	end
	if isFiniteNumber(payload.transparency) then
		copy.transparency = math.clamp(payload.transparency, 0, 1)
	end
	if isFiniteNumber(payload.reflectance) then
		copy.reflectance = math.clamp(payload.reflectance, 0, 1)
	end
	if isFiniteNumber(payload.speedMin) then
		copy.speedMin = math.max(payload.speedMin, 0)
	end
	if isFiniteNumber(payload.speedMax) then
		copy.speedMax = math.max(payload.speedMax, 0)
	end
	if isFiniteNumber(payload.lifetime) then
		copy.lifetime = math.clamp(payload.lifetime, 0.1, 10)
	end
	if typeof(payload.useGraphicsQualitySampling) == "boolean" then
		copy.useGraphicsQualitySampling = payload.useGraphicsQualitySampling
	end
	if isFiniteNumber(payload.automaticQualityLevel) then
		copy.automaticQualityLevel = math.clamp(math.floor(payload.automaticQualityLevel), 1, 10)
	end
	if isFiniteNumber(payload.maxSamplingDivisor) then
		copy.maxSamplingDivisor = math.clamp(math.floor(payload.maxSamplingDivisor), 1, 20)
	end
	if isFiniteNumber(payload.seed) then
		copy.seed = math.clamp(math.floor(payload.seed), 1, MAX_RANDOM_SEED)
	end

	return copy, #blocks
end

local function copyDebrisPayloads(payloads)
	local token = RuntimeProfiler.Begin("Server/Replay/Death/CopyDebrisPayloads")
	if typeof(payloads) ~= "table" then
		RuntimeProfiler.End("Server/Replay/Death/CopyDebrisPayloads", token)
		return nil
	end

	local results = {}
	local remainingBlocks = MAX_DEBRIS_BLOCKS_PER_DESTRUCTION_EVENT
	for _, payload in ipairs(payloads) do
		if #results >= MAX_DEBRIS_PAYLOADS_PER_DESTRUCTION_EVENT or remainingBlocks <= 0 then
			break
		end

		local copiedPayload, copiedBlocks = copyDebrisPayload(payload, remainingBlocks)
		if copiedPayload and copiedBlocks > 0 then
			table.insert(results, copiedPayload)
			remainingBlocks -= copiedBlocks
		end
	end

	RuntimeProfiler.Count("Server/Replay/Death/DebrisPayloadsCopied", #results)
	RuntimeProfiler.End("Server/Replay/Death/CopyDebrisPayloads", token)
	return if #results > 0 then results else nil
end

local function copyDestructionReplayOptions(source, target)
	if typeof(source) ~= "table" or typeof(target) ~= "table" then
		return
	end

	if source.terrainShape == "Ellipsoid" or source.terrainShape == "Sphere" then
		target.terrainShape = source.terrainShape
	end
	if isFiniteNumber(source.terrainVerticalScale) then
		target.terrainVerticalScale = math.clamp(source.terrainVerticalScale, 0.05, 1)
	end
	if isFiniteNumber(source.maxTargetsPerExplosion) then
		target.maxTargetsPerExplosion = math.clamp(
			math.floor(source.maxTargetsPerExplosion),
			1,
			MAX_REPLAY_DESTRUCTION_TARGETS_PER_EVENT
		)
	end
	if isFiniteNumber(source.transparentCollisionClearance) then
		target.transparentCollisionClearance = math.clamp(source.transparentCollisionClearance, 0, 80)
	end
	for _, fieldName in ipairs(REPLAY_DESTRUCTION_BOOLEAN_OPTION_FIELDS) do
		if typeof(source[fieldName]) == "boolean" then
			target[fieldName] = source[fieldName]
		end
	end
end

local function copyDestructionEvent(event, includeDebrisPayloads: boolean?)
	if typeof(event) ~= "table" then
		return nil
	end
	if not (isFiniteNumber(event.timestamp) and typeof(event.position) == "Vector3") then
		return nil
	end
	if not (isFiniteNumber(event.radius) and event.radius > 0) then
		return nil
	end

	local copy = {
		timestamp = event.timestamp,
		sequence = event.sequence,
		position = event.position,
		radius = event.radius,
		sourceType = event.sourceType,
		sourceId = event.sourceId,
		bombId = event.bombId,
		ownerUserId = event.ownerUserId,
	}
	copyDestructionReplayOptions(event, copy)
	if includeDebrisPayloads == true then
		copy.debrisPayloads = copyDebrisPayloads(event.debrisPayloads)
	end
	return copy
end

local function getDestructionEventsForClip(endTime: number, debrisStartTime: number?, caps)
	local token = RuntimeProfiler.Begin("Server/Replay/Death/GetDestructionEventsForClip")
	local events = {}
	if not isFiniteNumber(endTime) then
		RuntimeProfiler.End("Server/Replay/Death/GetDestructionEventsForClip", token)
		return events
	end

	local maxEvents = if typeof(caps) == "table" and isFiniteNumber(caps.maxDestructionEvents)
		then math.max(math.floor(caps.maxDestructionEvents), 0)
		else math.huge
	if maxEvents <= 0 then
		RuntimeProfiler.Count("Server/Replay/Death/DestructionEventsSkippedByCap", #roundDestructionEvents)
		RuntimeProfiler.End("Server/Replay/Death/GetDestructionEventsForClip", token)
		return events
	end

	local copied = 0
	for index = #roundDestructionEvents, 1, -1 do
		if copied >= maxEvents then
			break
		end
		local event = roundDestructionEvents[index]
		if typeof(event) ~= "table" or not isFiniteNumber(event.timestamp) then
			continue
		end
		if event.timestamp > endTime then
			continue
		end

		local includeDebrisPayloads = isFiniteNumber(debrisStartTime) and event.timestamp >= debrisStartTime - 0.001
		local copy = copyDestructionEvent(event, includeDebrisPayloads)
		if copy then
			table.insert(events, 1, copy)
			copied += 1
		end
	end
	RuntimeProfiler.Count("Server/Replay/Death/DestructionEventsScanned", #roundDestructionEvents)
	RuntimeProfiler.Count("Server/Replay/Death/DestructionEventsCopied", #events)
	RuntimeProfiler.End("Server/Replay/Death/GetDestructionEventsForClip", token)
	return events
end

local function getLatestDestructionEventInWindow(startTime: number, endTime: number)
	if not (isFiniteNumber(startTime) and isFiniteNumber(endTime)) then
		return nil
	end
	if startTime > endTime then
		startTime, endTime = endTime, startTime
	end

	local latestEvent = nil
	for _, event in ipairs(roundDestructionEvents) do
		if typeof(event) ~= "table" or not isFiniteNumber(event.timestamp) then
			continue
		end
		if event.timestamp < startTime or event.timestamp > endTime then
			continue
		end
		if
			not latestEvent
			or event.timestamp > latestEvent.timestamp
			or (
				event.timestamp == latestEvent.timestamp
				and isFiniteNumber(event.sequence)
				and (not isFiniteNumber(latestEvent.sequence) or event.sequence > latestEvent.sequence)
			)
		then
			latestEvent = event
		end
	end

	return latestEvent
end

local function getDebugRecentKillReplayWindow(currentTime: number, windowSeconds: number): (number, number, any)
	local endTime = currentTime
	local startTime = currentTime - windowSeconds
	local recentStartTime = currentTime - ReplayConstants.BUFFER_SECONDS
	local latestDestructionEvent = getLatestDestructionEventInWindow(recentStartTime, currentTime)
	if not latestDestructionEvent then
		return startTime, endTime, nil
	end

	local destructionTime = latestDestructionEvent.timestamp
	if destructionTime < startTime then
		startTime = math.max(recentStartTime, destructionTime - DEBUG_REPLAY_DESTRUCTION_LEAD_SECONDS)
		endTime = startTime + windowSeconds
	end

	return startTime, endTime, latestDestructionEvent
end

local function addMapFieldsToPayload(payload, endTime: number, caps)
	local token = RuntimeProfiler.Begin("Server/Replay/Death/AddMapFields")
	if typeof(payload) ~= "table" then
		RuntimeProfiler.End("Server/Replay/Death/AddMapFields", token)
		return payload
	end

	local mapContext = resolvePayloadMapContext(payload)
	if typeof(mapContext) == "table" then
		payload.mapId = mapContext.mapId
		if isFiniteCFrame(mapContext.mapPivot) then
			payload.mapPivot = mapContext.mapPivot
		end
	end
	if payload.roundId == nil then
		if typeof(mapContext) == "table" and mapContext.roundId ~= nil then
			payload.roundId = mapContext.roundId
		else
			payload.roundId = currentRoundId
		end
	end
	local debrisStartTime = if isFiniteNumber(payload.startTime) then payload.startTime else nil
	payload.destructionEvents = getDestructionEventsForClip(endTime, debrisStartTime, caps)
	RuntimeProfiler.End("Server/Replay/Death/AddMapFields", token)
	return payload
end

local function buildKillReplayPayload(killEvent)
	local token = RuntimeProfiler.Begin("Server/Replay/BuildKillPayload")
	if typeof(killEvent) ~= "table" or not isFiniteNumber(killEvent.timestamp) then
		RuntimeProfiler.End("Server/Replay/BuildKillPayload", token)
		return nil
	end
	if not isFiniteNumber(killEvent.victimUserId) then
		RuntimeProfiler.End("Server/Replay/BuildKillPayload", token)
		return nil
	end

	local deathTime = killEvent.timestamp
	local startTime = deathTime - ReplayConstants.KILL_REPLAY_PRE_SECONDS
	local endTime = deathTime + ReplayConstants.KILL_REPLAY_POST_SECONDS
	local clipToken = RuntimeProfiler.Begin("Server/Replay/Death/BuildKill/GetClip")
	local clip = ensureBuffer():GetClip(startTime, endTime)
	RuntimeProfiler.End("Server/Replay/Death/BuildKill/GetClip", clipToken)

	local mapToken = RuntimeProfiler.Begin("Server/Replay/Death/BuildKill/AddMapFields")
	local caps = getKillClipCaps()
	local payloadWithMap = addMapFieldsToPayload({
		type = "KillReplay",
		killerUserId = killEvent.killerUserId,
		killerName = killEvent.killerName,
		killerDisplayName = killEvent.killerDisplayName,
		killerTeam = killEvent.killerTeam,
		killerIsNPC = killEvent.killerIsNPC,
		roundId = killEvent.roundId,
		mapId = killEvent.mapId,
		mapPivot = killEvent.mapPivot,
		victimUserId = killEvent.victimUserId,
		victimName = killEvent.victimName,
		victimDisplayName = killEvent.victimDisplayName,
		victimTeam = killEvent.victimTeam,
		victimIsNPC = killEvent.victimIsNPC,
		sourceType = killEvent.sourceType,
		sourceId = killEvent.sourceId,
		primaryEventTime = deathTime,
		startTime = clip.startTime,
		endTime = clip.endTime,
		frames = clip.frames,
		events = clip.events,
	}, clip.endTime, caps)
	RuntimeProfiler.End("Server/Replay/Death/BuildKill/AddMapFields", mapToken)

	local optimizeToken = RuntimeProfiler.Begin("Server/Replay/Death/BuildKill/Optimize")
	local payload = optimizeClipPayloadForSend(payloadWithMap, caps, "KillReplay")
	RuntimeProfiler.End("Server/Replay/Death/BuildKill/Optimize", optimizeToken)
	RuntimeProfiler.End("Server/Replay/BuildKillPayload", token)
	return payload
end

sendKillReplayForEvent = function(killEvent)
	local totalToken = RuntimeProfiler.Begin("Server/Replay/Death/SendKillReplay")
	if DEBUG_KILL_REPLAY_SEND then
		warn(
			("[ReplayService] KillReplay send requested victim=%s killer=%s timestamp=%s pre=%.2f post=%.2f delay=%.3f"):format(
				tostring(if typeof(killEvent) == "table" then killEvent.victimUserId else nil),
				tostring(if typeof(killEvent) == "table" then killEvent.killerUserId else nil),
				tostring(if typeof(killEvent) == "table" then killEvent.timestamp else nil),
				ReplayConstants.KILL_REPLAY_PRE_SECONDS,
				ReplayConstants.KILL_REPLAY_POST_SECONDS,
				KILL_REPLAY_SEND_DELAY_SECONDS
			)
		)
	end

	local recipientsToken = RuntimeProfiler.Begin("Server/Replay/Death/Send/GetRecipients")
	local recipients = getKillReplayRecipients(killEvent)
	RuntimeProfiler.End("Server/Replay/Death/Send/GetRecipients", recipientsToken)
	if #recipients <= 0 then
		RuntimeProfiler.Count("Server/Replay/Death/SkippedBuildMissingRecipient")
		debugKillReplaySend("skipped-missing-recipient", killEvent)
		RuntimeProfiler.End("Server/Replay/Death/SendKillReplay", totalToken)
		return false
	end

	local buildToken = RuntimeProfiler.Begin("Server/Replay/Death/Send/BuildPayload")
	local payload = buildKillReplayPayload(killEvent)
	RuntimeProfiler.End("Server/Replay/Death/Send/BuildPayload", buildToken)
	if not payload then
		debugKillReplaySend("skipped-invalid-payload", killEvent)
		RuntimeProfiler.End("Server/Replay/Death/SendKillReplay", totalToken)
		return false
	end

	local guardsToken = RuntimeProfiler.Begin("Server/Replay/Death/Send/Guards")
	if estimateClipPayloadSize(payload).frames <= 0 then
		debugKillReplaySend("skipped-empty-clip", payload)
		RuntimeProfiler.End("Server/Replay/Death/Send/Guards", guardsToken)
		RuntimeProfiler.End("Server/Replay/Death/SendKillReplay", totalToken)
		return false
	end
	if not isKillReplayClipSendable(payload) then
		debugKillReplaySend("skipped-clip-guard", payload)
		RuntimeProfiler.End("Server/Replay/Death/Send/Guards", guardsToken)
		RuntimeProfiler.End("Server/Replay/Death/SendKillReplay", totalToken)
		return false
	end
	if not getReplayRemote(ReplayConstants.REMOTES.KillReplay) then
		debugKillReplaySend("skipped-missing-remote", payload)
		RuntimeProfiler.End("Server/Replay/Death/Send/Guards", guardsToken)
		RuntimeProfiler.End("Server/Replay/Death/SendKillReplay", totalToken)
		return false
	end
	RuntimeProfiler.End("Server/Replay/Death/Send/Guards", guardsToken)

	if DEBUG_KILL_REPLAY_SEND then
		warn(
			("[ReplayService] KillReplay FireClient attempt recipients=%d frames=%d events=%d"):format(
				#recipients,
				estimateClipPayloadSize(payload).frames,
				estimateClipPayloadSize(payload).events
			)
		)
	end
	local sentAny = false
	local dispatchToken = RuntimeProfiler.Begin("Server/Replay/Death/Send/Dispatch")
	for _, player in ipairs(recipients) do
		sentAny = ReplayService.PlayKillReplay(player, payload) or sentAny
	end
	RuntimeProfiler.End("Server/Replay/Death/Send/Dispatch", dispatchToken)
	RuntimeProfiler.Count("Server/Replay/Death/SendRecipients", #recipients)
	debugKillReplaySend(if sentAny then "sent" else "skipped-remote", payload)
	RuntimeProfiler.End("Server/Replay/Death/SendKillReplay", totalToken)
	return sentAny
end

local function scheduleKillReplay(killEvent)
	local token = RuntimeProfiler.Begin("Server/Replay/Death/ScheduleKillReplay")
	if typeof(killEvent) ~= "table" then
		debugKillReplaySend("skipped-invalid-event", killEvent)
		RuntimeProfiler.End("Server/Replay/Death/ScheduleKillReplay", token)
		return
	end

	if DEBUG_KILL_REPLAY_SEND then
		warn(
			("[ReplayService] Scheduling delayed KillReplay delay=%.3f victim=%s killer=%s timestamp=%s"):format(
				KILL_REPLAY_SEND_DELAY_SECONDS,
				tostring(killEvent.victimUserId),
				tostring(killEvent.killerUserId),
				tostring(killEvent.timestamp)
			)
		)
	end
	local victimUserId = killEvent.victimUserId
	local killTimestamp = killEvent.timestamp
	task.delay(KILL_REPLAY_SEND_DELAY_SECONDS, function()
		local delayedToken = RuntimeProfiler.Begin("Server/Replay/Death/DelayedSendCallback")
		local eventToSend = getRecentKillReplayEventForUserId(victimUserId) or killEvent
		if
			typeof(eventToSend) == "table"
			and isFiniteNumber(killTimestamp)
			and isFiniteNumber(eventToSend.timestamp)
			and math.abs(eventToSend.timestamp - killTimestamp) > 0.001
		then
			debugKillReplaySend("skipped-stale-stored-event", killEvent)
			RuntimeProfiler.End("Server/Replay/Death/DelayedSendCallback", delayedToken)
			return
		end

		sendKillReplayForEvent(eventToSend)
		RuntimeProfiler.End("Server/Replay/Death/DelayedSendCallback", delayedToken)
	end)
	RuntimeProfiler.End("Server/Replay/Death/ScheduleKillReplay", token)
end

local function waitForPOTGPostWindow(candidate, maxWaitSeconds: number?)
	if typeof(candidate) ~= "table" or not isFiniteNumber(candidate.endTime) then
		return
	end

	local currentTime = workspace:GetServerTimeNow()
	local waitSeconds = candidate.endTime - currentTime
	if waitSeconds <= 0 then
		return
	end

	local cap = if isFiniteNumber(maxWaitSeconds) then math.max(maxWaitSeconds, 0) else ReplayConstants.POTG_POST_SECONDS
	waitSeconds = math.min(waitSeconds, cap)
	if waitSeconds > 0 then
		task.wait(waitSeconds)
	end
end

local function buildPOTGReplayPayload(candidate)
	local token = RuntimeProfiler.Begin("Server/Replay/BuildPOTGPayload")
	if typeof(candidate) ~= "table" then
		RuntimeProfiler.End("Server/Replay/BuildPOTGPayload", token)
		return nil
	end
	if not (isFiniteNumber(candidate.startTime) and isFiniteNumber(candidate.endTime)) then
		RuntimeProfiler.End("Server/Replay/BuildPOTGPayload", token)
		return nil
	end
	if not isFiniteNumber(candidate.playerUserId) then
		RuntimeProfiler.End("Server/Replay/BuildPOTGPayload", token)
		return nil
	end

	local clip = ensureBuffer():GetClip(candidate.startTime, candidate.endTime)
	local caps = getPOTGClipCaps()
	local payload = optimizeClipPayloadForSend(addMapFieldsToPayload({
		type = "POTGReplay",
		playerUserId = math.floor(candidate.playerUserId),
		playerName = candidate.playerName,
		playerDisplayName = candidate.playerDisplayName,
		playerTeam = candidate.playerTeam,
		playerIsNPC = candidate.playerIsNPC,
		roundId = candidate.roundId,
		mapId = candidate.mapId,
		mapPivot = candidate.mapPivot,
		sourceType = candidate.sourceType,
		sourceId = candidate.sourceId,
		reason = candidate.reason,
		score = candidate.score,
		primaryEventTime = candidate.primaryEventTime,
		startTime = clip.startTime,
		endTime = clip.endTime,
		frames = clip.frames,
		events = clip.events,
	}, clip.endTime, caps), caps, "POTGReplay")
	RuntimeProfiler.End("Server/Replay/BuildPOTGPayload", token)
	return payload
end

local function buildSendablePOTGReplayPayload(candidate, allowFallbackClip: boolean?)
	local payload = buildPOTGReplayPayload(candidate)
	if not payload then
		return nil, "invalid-candidate"
	end
	if typeof(payload.frames) ~= "table" or #payload.frames == 0 then
		return nil, "empty-clip"
	end
	local isSendable = if allowFallbackClip == true then isFallbackPOTGClipSendable(payload) else isPOTGClipReasonable(payload)
	if not isSendable then
		return nil, "clip-guard"
	end
	return payload, nil
end

local function getPOTGArchiveKey(candidate): string?
	if typeof(candidate) ~= "table" then
		return nil
	end
	if not (isFiniteNumber(candidate.playerUserId) and isFiniteNumber(candidate.primaryEventTime)) then
		return nil
	end

	local roundKey = if isFiniteNumber(candidate.roundId) then math.floor(candidate.roundId) else currentRoundId
	local eventMillis = math.floor(candidate.primaryEventTime * 1000 + 0.5)
	local startMillis = if isFiniteNumber(candidate.startTime) then math.floor(candidate.startTime * 1000 + 0.5) else 0
	local endMillis = if isFiniteNumber(candidate.endTime) then math.floor(candidate.endTime * 1000 + 0.5) else 0
	return table.concat({
		tostring(roundKey),
		tostring(math.floor(candidate.playerUserId)),
		tostring(eventMillis),
		tostring(startMillis),
		tostring(endMillis),
		tostring(candidate.score),
		tostring(candidate.reason),
	}, "|")
end

local function copyPOTGCandidate(candidate)
	if typeof(candidate) ~= "table" then
		return nil
	end

	local copy = table.clone(candidate)
	if typeof(candidate.eventTypes) == "table" then
		copy.eventTypes = table.clone(candidate.eventTypes)
	end
	return copy
end

local function trimArchivedPOTGClips()
	while #archivedPOTGClipOrder > MAX_ARCHIVED_POTG_CLIPS do
		local oldKey = table.remove(archivedPOTGClipOrder, 1)
		if oldKey then
			archivedPOTGClipsByKey[oldKey] = nil
			scheduledPOTGArchivesByKey[oldKey] = nil
		end
	end
end

local function archivePOTGCandidatePayload(candidate, key: string, generation: number)
	if generation ~= roundStorageGeneration then
		scheduledPOTGArchivesByKey[key] = nil
		return
	end
	if archivedPOTGClipsByKey[key] then
		scheduledPOTGArchivesByKey[key] = nil
		return
	end

	local candidateCopy = copyPOTGCandidate(candidate)
	local payload, failure = buildSendablePOTGReplayPayload(candidateCopy, false)
	scheduledPOTGArchivesByKey[key] = nil
	if not payload then
		RuntimeProfiler.Count("Server/Replay/POTGArchiveBuildFailed")
		debugPOTGReplaySend("archive-" .. (failure or "failed"), nil, {
			clipSource = "archive",
			candidateStartTime = if candidateCopy then candidateCopy.startTime else nil,
			candidateEndTime = if candidateCopy then candidateCopy.endTime else nil,
			candidatePrimaryEventTime = if candidateCopy then candidateCopy.primaryEventTime else nil,
			candidatePlayerUserId = if candidateCopy then candidateCopy.playerUserId else nil,
			candidateScore = if candidateCopy then candidateCopy.score else nil,
			candidateReason = if candidateCopy then candidateCopy.reason else nil,
		})
		return
	end

	payload.potgClipSource = "archived"
	archivedPOTGClipsByKey[key] = {
		payload = payload,
		candidate = candidateCopy,
		archivedAt = workspace:GetServerTimeNow(),
	}
	table.insert(archivedPOTGClipOrder, key)
	trimArchivedPOTGClips()
	RuntimeProfiler.Count("Server/Replay/POTGArchivedClips")
end

local function schedulePOTGCandidateArchive(candidate)
	local key = getPOTGArchiveKey(candidate)
	if not key or archivedPOTGClipsByKey[key] or scheduledPOTGArchivesByKey[key] then
		return false
	end
	if not (typeof(candidate) == "table" and isFiniteNumber(candidate.endTime)) then
		return false
	end

	local candidateCopy = copyPOTGCandidate(candidate)
	local generation = roundStorageGeneration
	scheduledPOTGArchivesByKey[key] = true
	local waitSeconds = math.max(candidateCopy.endTime - workspace:GetServerTimeNow(), 0)
	task.delay(waitSeconds + ReplayConstants.SAMPLE_INTERVAL, function()
		archivePOTGCandidatePayload(candidateCopy, key, generation)
	end)
	RuntimeProfiler.Count("Server/Replay/POTGArchiveScheduled")
	return true
end

local function schedulePOTGCandidateArchives(candidates)
	if typeof(candidates) ~= "table" then
		return
	end

	for _, candidate in ipairs(candidates) do
		schedulePOTGCandidateArchive(candidate)
	end
end

local function getArchivedPOTGPayload(candidate)
	local key = getPOTGArchiveKey(candidate)
	local archived = key and archivedPOTGClipsByKey[key]
	local payload = if typeof(archived) == "table" then archived.payload else nil
	if typeof(payload) ~= "table" then
		return nil
	end
	payload.potgClipSource = "archived"
	return payload
end

local function getPOTGRecipients(recipients)
	if typeof(recipients) ~= "table" then
		return Players:GetPlayers()
	end

	local players = {}
	for _, player in pairs(recipients) do
		if typeof(player) == "Instance" and player:IsA("Player") then
			table.insert(players, player)
		end
	end
	return if #players > 0 then players else Players:GetPlayers()
end

local function getReplaySnapshotUserId(snapshot): number?
	if typeof(snapshot) ~= "table" or not isFiniteNumber(snapshot.userId) or snapshot.userId == 0 then
		return nil
	end
	return math.floor(snapshot.userId)
end

local function findReplayPlayerSnapshot(frames, userId: any)
	if not isFiniteNumber(userId) or typeof(frames) ~= "table" then
		return nil
	end

	local resolvedUserId = math.floor(userId)
	for _, frame in ipairs(frames) do
		local players = if typeof(frame) == "table" then frame.players else nil
		if typeof(players) ~= "table" then
			continue
		end
		for _, snapshot in ipairs(players) do
			if getReplaySnapshotUserId(snapshot) == resolvedUserId then
				return snapshot
			end
		end
	end
	return nil
end

local function findAnyReplayPlayerSnapshot(frames, requirePositiveUserId: boolean)
	if typeof(frames) ~= "table" then
		return nil
	end

	for _, frame in ipairs(frames) do
		local players = if typeof(frame) == "table" then frame.players else nil
		if typeof(players) ~= "table" then
			continue
		end
		for _, snapshot in ipairs(players) do
			local userId = getReplaySnapshotUserId(snapshot)
			if userId and (not requirePositiveUserId or userId > 0) then
				return snapshot
			end
		end
	end
	return nil
end

local function getReplaySnapshotString(snapshot, fieldName: string): string?
	local value = if typeof(snapshot) == "table" then snapshot[fieldName] else nil
	return if typeof(value) == "string" and value ~= "" then value else nil
end

local function captureFallbackReplayFrame(): boolean
	local timestamp = workspace:GetServerTimeNow()
	local frame = buildFrame(timestamp)
	if typeof(frame.players) ~= "table" or #frame.players == 0 then
		return false
	end
	local recorded = ensureBuffer():AddFrame(frame)
	if recorded then
		lastSampleTime = timestamp
		sampleCount += 1
	end
	return recorded
end

local function buildFallbackPOTGCandidate(recipients)
	local buffer = ensureBuffer()
	local bufferCounts = buffer:GetDebugCounts()
	if not (isFiniteNumber(bufferCounts.frames) and bufferCounts.frames > 0 and isFiniteNumber(bufferCounts.newestTimestamp)) then
		captureFallbackReplayFrame()
		bufferCounts = buffer:GetDebugCounts()
	end
	if not (isFiniteNumber(bufferCounts.frames) and bufferCounts.frames > 0 and isFiniteNumber(bufferCounts.newestTimestamp)) then
		return nil
	end

	local endTime = bufferCounts.newestTimestamp
	local bufferSeconds = if isFiniteNumber(bufferCounts.bufferSeconds) and bufferCounts.bufferSeconds > 0
		then bufferCounts.bufferSeconds
		else ReplayConstants.BUFFER_SECONDS
	local windowSeconds = math.min(ReplayConstants.POTG_PRE_SECONDS + ReplayConstants.POTG_POST_SECONDS, bufferSeconds)
	local startTime = endTime - windowSeconds
	local clip = buffer:GetClip(startTime, endTime)
	if typeof(clip.frames) ~= "table" or #clip.frames == 0 then
		return nil
	end

	local player = nil
	local snapshot = nil
	for _, recipient in ipairs(getPOTGRecipients(recipients)) do
		if recipient.Parent ~= Players then
			continue
		end

		snapshot = findReplayPlayerSnapshot(clip.frames, recipient.UserId)
		if snapshot then
			player = recipient
			break
		end
	end

	snapshot = snapshot or findAnyReplayPlayerSnapshot(clip.frames, true) or findAnyReplayPlayerSnapshot(clip.frames, false)
	if not snapshot and captureFallbackReplayFrame() then
		bufferCounts = buffer:GetDebugCounts()
		endTime = bufferCounts.newestTimestamp
		bufferSeconds = if isFiniteNumber(bufferCounts.bufferSeconds) and bufferCounts.bufferSeconds > 0
			then bufferCounts.bufferSeconds
			else ReplayConstants.BUFFER_SECONDS
		windowSeconds = math.min(ReplayConstants.POTG_PRE_SECONDS + ReplayConstants.POTG_POST_SECONDS, bufferSeconds)
		startTime = endTime - windowSeconds
		clip = buffer:GetClip(startTime, endTime)
		for _, recipient in ipairs(getPOTGRecipients(recipients)) do
			if recipient.Parent ~= Players then
				continue
			end

			snapshot = findReplayPlayerSnapshot(clip.frames, recipient.UserId)
			if snapshot then
				player = recipient
				break
			end
		end
		snapshot = snapshot or findAnyReplayPlayerSnapshot(clip.frames, true) or findAnyReplayPlayerSnapshot(clip.frames, false)
	end
	if not snapshot then
		return nil
	end

	local playerUserId = getReplaySnapshotUserId(snapshot)
	if not playerUserId then
		return nil
	end
	if not player and playerUserId > 0 then
		player = getUserIdPlayer(playerUserId)
	end

	return {
		roundId = currentRoundId,
		playerUserId = playerUserId,
		playerName = if player then player.Name else getReplaySnapshotString(snapshot, "name") or tostring(playerUserId),
		playerDisplayName = if player
			then player.DisplayName
			else getReplaySnapshotString(snapshot, "displayName") or getReplaySnapshotString(snapshot, "name") or tostring(playerUserId),
		playerTeam = if player then getTeamName(player) else getReplaySnapshotString(snapshot, "teamName"),
		playerIsNPC = if typeof(snapshot.isNPC) == "boolean" then snapshot.isNPC else player == nil,
		sourceType = "RoundReplay",
		sourceId = "Fallback",
		startTime = startTime,
		endTime = endTime,
		score = 1,
		reason = "Round Recap",
		eventTypes = { "RoundFallback" },
		primaryEventTime = endTime,
		kills = 0,
		baseDamage = 0,
		rareRank = 0,
		sourceConfidence = 0,
	}
end

local function buildPOTGIntroCandidatePayload(candidate)
	if typeof(candidate) ~= "table" or not isFiniteNumber(candidate.playerUserId) then
		return nil
	end

	local playerUserId = math.floor(candidate.playerUserId)
	local player = Players:GetPlayerByUserId(playerUserId)
	local cutsceneId = if player then HighlightIntroService:GetEquippedHighlightIntroId(player) else nil
	return {
		potgPlayerUserId = playerUserId,
		potgPlayerName = candidate.playerName,
		potgPlayerDisplayName = candidate.playerDisplayName or candidate.playerName or tostring(playerUserId),
		potgPlayerTeam = candidate.playerTeam,
		potgPlayerIsNPC = candidate.playerIsNPC == true,
		potgReason = candidate.reason,
		potgScore = candidate.score,
		cutsceneId = cutsceneId,
	}
end

local function clearPOTGSendInProgress(token: number)
	if token == potgSendToken then
		potgSendInProgress = false
	end
end

local function resetClipOptimizationDebug()
	lastClipOptimizationDebug = nil
	clipOptimizationTotals.clips = 0
	clipOptimizationTotals.framesTrimmed = 0
	clipOptimizationTotals.playerSnapshotsTrimmed = 0
	clipOptimizationTotals.bombSnapshotsTrimmed = 0
	clipOptimizationTotals.eventsTrimmed = 0
	clipOptimizationTotals.destructionEventsTrimmed = 0
	clipOptimizationTotals.instanceValuesDropped = 0
end

local function resetReplayRoundStorage(roundId: any)
	ensureBuffer():Clear()
	POTGService.ResetRound(roundId)
	currentRoundId = roundId
	currentMapContext = nil
	table.clear(roundDestructionEvents)
	nextDestructionSequence = 0
	roundStorageGeneration += 1
	roundPerformanceCritical = false
	potgSentThisRound = false
	potgSendToken += 1
	potgSendInProgress = false
	optimizedReplayPayloads = setmetatable({}, { __mode = "k" })
	table.clear(latestAnimationStateByUserId)
	table.clear(clientReplaySamplesByUserId)
	table.clear(lastAnimationStateAtByUserId)
	table.clear(recentKillReplayEventsByVictimUserId)
	table.clear(lastKillReplayRequestAtByUserId)
	table.clear(archivedPOTGClipsByKey)
	table.clear(archivedPOTGClipOrder)
	table.clear(scheduledPOTGArchivesByKey)
	accumulator = 0
	sampleCount = 0
	lastSampleTime = 0
	lastFramePlayerCount = 0
	lastFrameBombCount = 0
	lastKillReplayDebug = nil
	lastPOTGReplayDebug = nil
	resetClipOptimizationDebug()
	return true
end

function ReplayService.Init(_self)
	ensureBuffer()
	ensureRemotes()
	ensureReplayAssetsFolder()
	POTGService.Init(ReplayService)
	initialized = true
	return true
end

function ReplayService.Start(_self)
	ReplayService.Init()
	if running then
		return false
	end

	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end

	running = true
	accumulator = 0
	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		local heartbeatToken = RuntimeProfiler.Begin("Server/Replay/Heartbeat")
		if not running then
			RuntimeProfiler.End("Server/Replay/Heartbeat", heartbeatToken)
			return
		end
		if not isFiniteNumber(deltaTime) or deltaTime <= 0 then
			RuntimeProfiler.End("Server/Replay/Heartbeat", heartbeatToken)
			return
		end

		accumulator = math.min(accumulator + deltaTime, ReplayConstants.SAMPLE_INTERVAL * 4)
		local framesThisHeartbeat = 0
		while accumulator >= ReplayConstants.SAMPLE_INTERVAL do
			accumulator -= ReplayConstants.SAMPLE_INTERVAL
			framesThisHeartbeat += 1

			local timestamp = workspace:GetServerTimeNow()
			local frame = buildFrame(timestamp)
			ensureBuffer():AddFrame(frame)
			lastSampleTime = timestamp
			sampleCount += 1
		end
		RuntimeProfiler.Gauge("Server/Replay/FramesLastHeartbeat", framesThisHeartbeat)
		RuntimeProfiler.End("Server/Replay/Heartbeat", heartbeatToken)
	end)

	return true
end

function ReplayService.Stop(_self)
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	running = false
	accumulator = 0
	return true
end

function ReplayService.Clear(_self)
	return resetReplayRoundStorage(nil)
end

function ReplayService.OnStart(_self)
	ReplayService.Init()
	ReplayService.Start()
end

function ReplayService.OnPlayerRemoving(_self, player: Player)
	if typeof(player) == "Instance" and player:IsA("Player") then
		latestAnimationStateByUserId[player.UserId] = nil
		clientReplaySamplesByUserId[player.UserId] = nil
		lastAnimationStateAtByUserId[player.UserId] = nil
		recentKillReplayEventsByVictimUserId[player.UserId] = nil
		lastKillReplayRequestAtByUserId[player.UserId] = nil
	end
end

function ReplayService.RecordFrame(first, second)
	local frame = unwrapOptionalSelf(first, second)
	return ensureBuffer():AddFrame(frame)
end

function ReplayService.RecordEvent(first, second, third)
	local totalToken = RuntimeProfiler.Begin("Server/Replay/RecordEvent")
	local eventType, payload = unwrapOptionalSelf(first, second, third)
	if typeof(eventType) ~= "string" or eventType == "" then
		RuntimeProfiler.End("Server/Replay/RecordEvent", totalToken)
		return false
	end
	local deathToken = nil
	if eventType == "PlayerKilled" then
		deathToken = RuntimeProfiler.Begin("Server/Replay/Death/RecordPlayerKilled")
	end

	local event = {
		timestamp = getTrustedReplayTimestamp(payload),
		eventType = eventType,
	}

	if typeof(payload) == "table" then
		for key, value in pairs(payload) do
			if key ~= "timestamp" and key ~= "eventType" and (typeof(key) == "string" or typeof(key) == "number") then
				event[key] = value
			end
		end
	end
	applyCurrentMapContextToEvent(event)

	local buffer = ensureBuffer()
	local addEventToken = RuntimeProfiler.Begin("Server/Replay/RecordEvent/AddEvent")
	local recorded = buffer:AddEvent(event)
	RuntimeProfiler.End("Server/Replay/RecordEvent/AddEvent", addEventToken)
	if eventType == "PlayerKilled" and DEBUG_KILL_REPLAY_SEND then
		local counts = buffer:GetDebugCounts()
		warn(
			("[ReplayService] RecordEvent PlayerKilled recorded=%s victim=%s killer=%s timestamp=%s bufferFrames=%d bufferEvents=%d newest=%s"):format(
				tostring(recorded),
				tostring(event.victimUserId),
				tostring(event.killerUserId),
				tostring(event.timestamp),
				counts.frames,
				counts.events,
				tostring(counts.newestTimestamp)
			)
		)
	end
	if recorded then
		local potgToken = RuntimeProfiler.Begin("Server/Replay/RecordEvent/POTG")
		local potgEvent = copyReplayEvent(event)
		if potgEvent then
			local ok, err = pcall(function()
				POTGService.ProcessReplayEvent(potgEvent)
			end)
			if DEBUG_POTG_EVENTS and not ok then
				warn("[ReplayService] POTG event failed:", eventType, err)
			elseif ok then
				schedulePOTGCandidateArchives(POTGService.GetDebugCandidates())
			end
		end
		RuntimeProfiler.End("Server/Replay/RecordEvent/POTG", potgToken)

		if eventType == "PlayerKilled" then
			local storeToken = RuntimeProfiler.Begin("Server/Replay/Death/StoreRecentKill")
			local storedKillEvent = storeRecentKillReplayEvent(event)
			RuntimeProfiler.End("Server/Replay/Death/StoreRecentKill", storeToken)
			if not storedKillEvent then
				debugKillReplaySend("skipped-store-recent-kill", event)
			end
			scheduleKillReplay(storedKillEvent or event)
		end
	end

	if deathToken then
		RuntimeProfiler.End("Server/Replay/Death/RecordPlayerKilled", deathToken)
	end
	RuntimeProfiler.Count("Server/Replay/EventsRecorded")
	if eventType == "PlayerKilled" then
		RuntimeProfiler.Count("Server/Replay/Death/PlayerKilledEvents")
	end
	RuntimeProfiler.End("Server/Replay/RecordEvent", totalToken)
	return recorded
end

function ReplayService.GetClip(first, second, third)
	local startTime, endTime = unwrapOptionalSelf(first, second, third)
	return ensureBuffer():GetClip(startTime, endTime)
end

function ReplayService.EstimateClipPayloadSize(first, second)
	local clip = unwrapOptionalSelf(first, second)
	return estimateClipPayloadSize(clip)
end

function ReplayService.SetPerformanceCritical(first, second)
	local value = unwrapOptionalSelf(first, second)
	roundPerformanceCritical = value == true
	return roundPerformanceCritical
end

function ReplayService.SetRoundMap(first, second, third)
	local mapId, mapPivot = unwrapOptionalSelf(first, second, third)
	if typeof(mapId) ~= "string" or mapId == "" or not isFiniteCFrame(mapPivot) then
		currentMapContext = nil
		return false
	end

	currentMapContext = {
		mapId = mapId,
		mapPivot = mapPivot,
		roundId = currentRoundId,
	}
	RuntimeProfiler.Count("Server/Replay/SetRoundMap")
	if DEBUG_KILL_REPLAY_SEND then
		warn(("[ReplayService] SetRoundMap round=%s map=%s"):format(tostring(currentRoundId), mapId))
	end
	return true
end

function ReplayService.RecordMapDestruction(first, second)
	local payload = unwrapOptionalSelf(first, second)
	if typeof(payload) ~= "table" then
		return false
	end
	if typeof(payload.position) ~= "Vector3" then
		return false
	end
	if not (isFiniteNumber(payload.radius) and payload.radius > 0) then
		return false
	end

	nextDestructionSequence += 1
	local event = {
		timestamp = getTrustedReplayTimestamp(payload),
		roundId = currentRoundId,
		sequence = nextDestructionSequence,
		position = payload.position,
		radius = math.clamp(payload.radius, 1, 80),
		sourceType = payload.sourceType,
		sourceId = payload.sourceId,
		bombId = payload.bombId,
		ownerUserId = payload.ownerUserId,
	}
	copyDestructionReplayOptions(payload, event)
	if payload.storeReplayDebrisPayloads == true or STORE_RECORDED_DEBRIS_PAYLOADS_BY_DEFAULT then
		event.debrisPayloads = copyDebrisPayloads(payload.debrisPayloads)
		if event.debrisPayloads then
			RuntimeProfiler.Count("Server/Replay/MapDestructionDebrisPayloadsStored", #event.debrisPayloads)
		end
	elseif typeof(payload.debrisPayloads) == "table" then
		RuntimeProfiler.Count("Server/Replay/MapDestructionDebrisPayloadCopySkipped")
	end
	table.insert(roundDestructionEvents, event)
	while #roundDestructionEvents > MAX_ROUND_DESTRUCTION_EVENTS do
		table.remove(roundDestructionEvents, 1)
	end
	return true
end

function ReplayService.GetRecentDebugInfo(_self)
	local bufferCounts = ensureBuffer():GetDebugCounts()
	return {
		initialized = initialized,
		running = running,
		roundId = currentRoundId,
		mapId = if typeof(currentMapContext) == "table" then currentMapContext.mapId else nil,
		roundDestructionEvents = #roundDestructionEvents,
		roundPerformanceCritical = roundPerformanceCritical,
		potgSentThisRound = potgSentThisRound,
		potgSendInProgress = potgSendInProgress,
		sampleRate = ReplayConstants.SAMPLE_RATE,
		sampleInterval = ReplayConstants.SAMPLE_INTERVAL,
		sampleCount = sampleCount,
		lastSampleTime = lastSampleTime,
		lastFramePlayerCount = lastFramePlayerCount,
		lastFrameBombCount = lastFrameBombCount,
		bombContainerName = BombConfig.ProjectileFolderName,
		bombContainerFound = lastBombContainerFound,
		bombServiceSnapshotAvailable = lastBombServiceSnapshotAvailable,
		bombSource = lastBombSource,
		lastKillReplay = lastKillReplayDebug,
		lastPOTGReplay = lastPOTGReplayDebug,
		lastClipOptimization = lastClipOptimizationDebug,
		archivedPOTGClips = countDictionaryEntries(archivedPOTGClipsByKey),
		scheduledPOTGArchives = countDictionaryEntries(scheduledPOTGArchivesByKey),
		animationStatePlayers = countDictionaryEntries(latestAnimationStateByUserId),
		visualSamplePlayers = countDictionaryEntries(clientReplaySamplesByUserId),
		visualSampleRecords = countClientReplaySampleRecords(),
		cameraStatePlayers = countLatestClientReplayField("camera"),
		poseStatePlayers = countLatestClientReplayField("pose"),
		clipOptimizationTotals = table.clone(clipOptimizationTotals),
		clipCaps = {
			killReplay = getKillClipCaps(),
			potgReplay = getPOTGClipCaps(),
		},
		potgBestCandidate = POTGService.GetBestCandidate() or buildFallbackPOTGCandidate(nil),
		buffer = bufferCounts,
	}
end

function ReplayService.ResetPOTGRound(first, second)
	local roundId = unwrapOptionalSelf(first, second)
	return POTGService.ResetRound(roundId)
end

function ReplayService.ResetRound(first, second)
	local roundId = unwrapOptionalSelf(first, second)
	return resetReplayRoundStorage(roundId)
end

function ReplayService.GetPOTGDebugCandidates(_self)
	return POTGService.GetDebugCandidates()
end

function ReplayService.GetScoredPOTGWinnerUserId(_self)
	local candidate = POTGService.GetBestCandidate()
	if typeof(candidate) ~= "table" or not isFiniteNumber(candidate.playerUserId) then
		return nil
	end

	return math.floor(candidate.playerUserId)
end

function ReplayService.GetPOTGIntroCandidate(first, second)
	local recipients = unwrapOptionalSelf(first, second)
	local candidate = POTGService.GetBestCandidate() or buildFallbackPOTGCandidate(recipients)
	return buildPOTGIntroCandidatePayload(candidate)
end

local function formatCandidateSummary(candidate, index: number): string
	if typeof(candidate) ~= "table" then
		return ("#%d <invalid>"):format(index)
	end

	return ("#%d player=%s score=%s combat=%s kills=%s damage=%s base=%s reason=%s start=%.3f end=%.3f"):format(
		index,
		tostring(candidate.playerUserId),
		tostring(candidate.score),
		tostring(candidate.combatRank),
		tostring(candidate.kills),
		tostring(candidate.playerDamage),
		tostring(candidate.baseDamage),
		tostring(candidate.reason),
		if isFiniteNumber(candidate.startTime) then candidate.startTime else 0,
		if isFiniteNumber(candidate.endTime) then candidate.endTime else 0
	)
end

function ReplayService.DebugPrintBufferCounts(first, second)
	local requester = unwrapOptionalSelf(first, second)
	local info = ReplayService.GetRecentDebugInfo()
	local buffer = info.buffer or {}
	local message = (
		"Replay buffer: frames=%s events=%s destruction=%s samples=%s lastPlayers=%s lastBombs=%s running=%s round=%s"
	):format(
		tostring(buffer.frames),
		tostring(buffer.events),
		tostring(info.roundDestructionEvents),
		tostring(info.sampleCount),
		tostring(info.lastFramePlayerCount),
		tostring(info.lastFrameBombCount),
		tostring(info.running),
		tostring(info.roundId)
	)
	print("[ReplayDebug]", if requester and requester.Name then requester.Name else "Server", message)
	return true, message, info
end

function ReplayService.DebugPrintPOTGCandidates(first, second)
	local requester = unwrapOptionalSelf(first, second)
	local candidates = POTGService.GetDebugCandidates()
	if #candidates == 0 then
		local fallback = buildFallbackPOTGCandidate(if requester then { requester } else nil)
		if fallback then
			print(
				"[ReplayDebug]",
				if requester and requester.Name then requester.Name else "Server",
				"POTG candidates: fallback",
				formatCandidateSummary(fallback, 1)
			)
			return true, "POTG candidates: fallback available", { fallback }
		end

		print("[ReplayDebug]", if requester and requester.Name then requester.Name else "Server", "POTG candidates: none")
		return true, "POTG candidates: none", candidates
	end

	print("[ReplayDebug]", if requester and requester.Name then requester.Name else "Server", "POTG candidates:", #candidates)
	for index, candidate in ipairs(candidates) do
		print("[ReplayDebug]", formatCandidateSummary(candidate, index))
	end

	return true, ("POTG candidates printed: %d"):format(#candidates), candidates
end

function ReplayService.DebugSendRecentKillReplay(first, second, third)
	local player, seconds = unwrapOptionalSelf(first, second, third)
	if not (typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players) then
		return false, "Calling developer is not available"
	end

	local windowSeconds = if isFiniteNumber(seconds) and seconds > 0 then math.clamp(seconds, 1, ReplayConstants.BUFFER_SECONDS) else 7
	local currentTime = workspace:GetServerTimeNow()
	local startTime, endTime, destructionEvent = getDebugRecentKillReplayWindow(currentTime, windowSeconds)
	local sourceId = if destructionEvent then destructionEvent.sourceId or destructionEvent.bombId else "RecentWindow"
	local sourceType = if destructionEvent and typeof(destructionEvent.sourceType) == "string" and destructionEvent.sourceType ~= ""
		then destructionEvent.sourceType
		else "ReplayDebug"
	local clip = ensureBuffer():GetClip(startTime, endTime)
	local caps = getKillClipCaps()
	local payload = optimizeClipPayloadForSend(addMapFieldsToPayload({
		type = "KillReplay",
		killerUserId = player.UserId,
		victimUserId = player.UserId,
		sourceType = sourceType,
		sourceId = sourceId,
		startTime = clip.startTime,
		endTime = clip.endTime,
		frames = clip.frames,
		events = clip.events,
	}, clip.endTime, caps), caps, "DebugKillReplay")

	if typeof(payload.frames) ~= "table" or #payload.frames == 0 then
		return false, "No replay frames available for debug kill replay"
	end

	local sent = ReplayService.PlayKillReplay(player, payload)
	return sent, if sent then ("Sent debug kill replay: %.1fs"):format(windowSeconds) else "Debug kill replay send failed"
end

function ReplayService.DebugPlayBestPOTG(first, second)
	local player = unwrapOptionalSelf(first, second)
	if not (typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players) then
		return false, "Calling developer is not available"
	end

	local candidate = POTGService.GetBestCandidate()
	local usedFallbackCandidate = false
	if not candidate then
		candidate = buildFallbackPOTGCandidate({ player })
		usedFallbackCandidate = candidate ~= nil
	end
	if not candidate then
		return false, "No POTG candidate is available"
	end

	local payload = if not usedFallbackCandidate then getArchivedPOTGPayload(candidate) else nil
	local payloadFailure = nil
	if not payload then
		payload, payloadFailure = buildSendablePOTGReplayPayload(candidate, usedFallbackCandidate)
		if payload then
			payload.potgClipSource = if usedFallbackCandidate then "fallback" else "live-buffer"
		end
	end
	if not payload then
		return false, "Best POTG candidate could not produce a clip: " .. tostring(payloadFailure or "invalid-candidate")
	end
	if typeof(payload.frames) ~= "table" or #payload.frames == 0 then
		return false, "Best POTG clip has no frames"
	end
	if not usedFallbackCandidate and not isPOTGClipReasonable(payload) then
		return false, "Best POTG clip failed replay caps"
	elseif usedFallbackCandidate and not isFallbackPOTGClipSendable(payload) then
		return false, "Best POTG fallback clip failed replay caps"
	end

	local remote = getReplayRemote(ReplayConstants.REMOTES.PlayOfTheGame)
	if not remote then
		return false, "POTG replay remote is missing"
	end

	local ok = pcall(function()
		remote:FireClient(player, payload)
	end)
	return ok, if ok then "Sent debug POTG replay to caller" else "Debug POTG send failed"
end

function ReplayService.PlayKillReplay(first, second, third)
	local totalToken = RuntimeProfiler.Begin("Server/Replay/Death/PlayKillReplay")
	local player, clip = unwrapOptionalSelf(first, second, third)
	if not (typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players) then
		debugKillReplaySend("skipped-invalid-player", clip)
		RuntimeProfiler.End("Server/Replay/Death/PlayKillReplay", totalToken)
		return false
	end
	if typeof(clip) ~= "table" then
		debugKillReplaySend("skipped-invalid-clip", clip)
		RuntimeProfiler.End("Server/Replay/Death/PlayKillReplay", totalToken)
		return false
	end

	if not optimizedReplayPayloads[clip] then
		local optimizeToken = RuntimeProfiler.Begin("Server/Replay/Death/Play/OptimizeDirect")
		clip = optimizeClipPayloadForSend(clip, getKillClipCaps(), "KillReplayDirect")
		RuntimeProfiler.End("Server/Replay/Death/Play/OptimizeDirect", optimizeToken)
	end
	local guardToken = RuntimeProfiler.Begin("Server/Replay/Death/Play/Guards")
	if estimateClipPayloadSize(clip).frames <= 0 then
		debugKillReplaySend("skipped-empty-clip", clip)
		RuntimeProfiler.End("Server/Replay/Death/Play/Guards", guardToken)
		RuntimeProfiler.End("Server/Replay/Death/PlayKillReplay", totalToken)
		return false
	end
	if not isKillReplayClipSendable(clip) then
		debugKillReplaySend("skipped-clip-guard", clip)
		RuntimeProfiler.End("Server/Replay/Death/Play/Guards", guardToken)
		RuntimeProfiler.End("Server/Replay/Death/PlayKillReplay", totalToken)
		return false
	end

	local remote = getReplayRemote(ReplayConstants.REMOTES.KillReplay)
	if not remote then
		debugKillReplaySend("skipped-missing-remote", clip)
		RuntimeProfiler.End("Server/Replay/Death/Play/Guards", guardToken)
		RuntimeProfiler.End("Server/Replay/Death/PlayKillReplay", totalToken)
		return false
	end
	RuntimeProfiler.End("Server/Replay/Death/Play/Guards", guardToken)

	debugKillReplaySend("fireclient", clip)
	local fireToken = RuntimeProfiler.Begin("Server/Replay/Death/Play/FireClient")
	local ok, err = pcall(function()
		remote:FireClient(player, clip)
	end)
	RuntimeProfiler.End("Server/Replay/Death/Play/FireClient", fireToken)
	if DEBUG_KILL_REPLAY_SEND and not ok then
		warn("[ReplayService] ReplayKillReplay FireClient failed:", err)
	end

	RuntimeProfiler.Count("Server/Replay/Death/PlayKillReplayCalls")
	RuntimeProfiler.End("Server/Replay/Death/PlayKillReplay", totalToken)
	return ok
end

function ReplayService.CancelReplay(first, second, third)
	local player, reason = unwrapOptionalSelf(first, second, third)
	if not (typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players) then
		return false
	end

	local remote = getReplayRemote(ReplayConstants.REMOTES.Cancel)
	if not remote then
		return false
	end

	local payload = {
		type = "CancelReplay",
		reason = if typeof(reason) == "string" then reason else nil,
	}
	local ok = pcall(function()
		remote:FireClient(player, payload)
	end)
	return ok
end

function ReplayService.PlayPOTG(first, second, third)
	local recipients, options = unwrapOptionalSelf(first, second, third)
	if typeof(options) ~= "table" then
		options = {}
	end
	if roundPerformanceCritical and options.allowDuringPerformanceCritical ~= true then
		debugPOTGReplaySend("skipped-performance-critical", nil, nil)
		return false
	end
	if potgSentThisRound then
		debugPOTGReplaySend("skipped-already-sent", nil, nil)
		return false
	end
	if potgSendInProgress then
		debugPOTGReplaySend("skipped-in-progress", nil, nil)
		return false
	end

	potgSendToken += 1
	local sendToken = potgSendToken
	potgSendInProgress = true
	local startedGeneration = roundStorageGeneration
	local candidate = POTGService.GetBestCandidate()
	local usedFallbackCandidate = false
	if not candidate then
		candidate = buildFallbackPOTGCandidate(recipients)
		usedFallbackCandidate = candidate ~= nil
	end
	if not candidate then
		debugPOTGReplaySend("skipped-no-candidate", nil, nil)
		clearPOTGSendInProgress(sendToken)
		return false
	end

	waitForPOTGPostWindow(candidate, options.maxWaitSeconds)
	if startedGeneration ~= roundStorageGeneration then
		debugPOTGReplaySend("skipped-stale-round", nil, nil)
		clearPOTGSendInProgress(sendToken)
		return false
	end

	local payload = nil
	local payloadFailure = nil
	local clipSource = if usedFallbackCandidate then "fallback" else "live-buffer"
	if not usedFallbackCandidate then
		payload = getArchivedPOTGPayload(candidate)
		if payload then
			clipSource = "archived"
			RuntimeProfiler.Count("Server/Replay/POTGArchiveHits")
		else
			RuntimeProfiler.Count("Server/Replay/POTGArchiveMisses")
			payload, payloadFailure = buildSendablePOTGReplayPayload(candidate, false)
			if payload then
				payload.potgClipSource = "live-buffer"
				clipSource = "live-buffer"
			end
		end
	else
		payload, payloadFailure = buildSendablePOTGReplayPayload(candidate, true)
		if payload then
			payload.potgClipSource = "fallback"
		end
	end
	if not payload then
		debugPOTGReplaySend("skipped-" .. (payloadFailure or "invalid-candidate"), nil, {
			clipSource = if usedFallbackCandidate then "fallback" else "scored-candidate",
			candidateStartTime = candidate.startTime,
			candidateEndTime = candidate.endTime,
			candidatePrimaryEventTime = candidate.primaryEventTime,
			candidatePlayerUserId = candidate.playerUserId,
			candidateScore = candidate.score,
			candidateReason = candidate.reason,
		})
		clearPOTGSendInProgress(sendToken)
		return false
	end
	if startedGeneration ~= roundStorageGeneration then
		debugPOTGReplaySend("skipped-stale-round", payload, {
			clipSource = clipSource,
			candidateStartTime = candidate.startTime,
			candidateEndTime = candidate.endTime,
			candidatePrimaryEventTime = candidate.primaryEventTime,
			candidatePlayerUserId = candidate.playerUserId,
			candidateScore = candidate.score,
			candidateReason = candidate.reason,
		})
		clearPOTGSendInProgress(sendToken)
		return false
	end

	local remote = getReplayRemote(ReplayConstants.REMOTES.PlayOfTheGame)
	if not remote then
		debugPOTGReplaySend("skipped-missing-remote", payload, {
			clipSource = clipSource,
			candidateStartTime = candidate.startTime,
			candidateEndTime = candidate.endTime,
			candidatePrimaryEventTime = candidate.primaryEventTime,
			candidatePlayerUserId = candidate.playerUserId,
			candidateScore = candidate.score,
			candidateReason = candidate.reason,
		})
		clearPOTGSendInProgress(sendToken)
		return false
	end

	local sentPlayers = 0
	local skippedPlayers = 0
	for _, player in ipairs(getPOTGRecipients(recipients)) do
		if not (player.Parent == Players) then
			skippedPlayers += 1
			if DEBUG_POTG_SEND then
				warn("[ReplayService] POTG skipped player that left:", player)
			end
			continue
		end

		local ok, err = pcall(function()
			remote:FireClient(player, payload)
		end)
		if ok then
			sentPlayers += 1
		else
			skippedPlayers += 1
			if DEBUG_POTG_SEND then
				warn("[ReplayService] ReplayPlayOfTheGame FireClient failed:", player, err)
			end
		end
	end

	if sentPlayers == 0 then
		debugPOTGReplaySend("skipped-player-left", payload, {
			clipSource = clipSource,
			candidateStartTime = candidate.startTime,
			candidateEndTime = candidate.endTime,
			candidatePrimaryEventTime = candidate.primaryEventTime,
			candidatePlayerUserId = candidate.playerUserId,
			candidateScore = candidate.score,
			candidateReason = candidate.reason,
			sentPlayers = sentPlayers,
			skippedPlayers = skippedPlayers,
		})
		clearPOTGSendInProgress(sendToken)
		return false
	end

	debugPOTGReplaySend("sent", payload, {
		clipSource = clipSource,
		candidateStartTime = candidate.startTime,
		candidateEndTime = candidate.endTime,
		candidatePrimaryEventTime = candidate.primaryEventTime,
		candidatePlayerUserId = candidate.playerUserId,
		candidateScore = candidate.score,
		candidateReason = candidate.reason,
		sentPlayers = sentPlayers,
		skippedPlayers = skippedPlayers,
	})
	potgSentThisRound = true
	clearPOTGSendInProgress(sendToken)
	return true
end

return ReplayService
