local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local ReplayConstants = require(ReplicatedStorage.Shared.Replay.ReplayConstants)
local BombProjectileService = require(ServerScriptService.Services.BombProjectileService)
local POTGService = require(ServerScriptService.Services.POTGService)
local ReplayBuffer = require(script.Parent.Replay.ReplayBuffer)

local ReplayService = {}
ReplayService.Buffer = nil

local DEBUG_KILL_REPLAY_SEND = RunService:IsStudio()
local DEBUG_POTG_EVENTS = false
local DEBUG_POTG_SEND = false
local REPLAY_ASSETS_FOLDER_NAME = "ReplayAssets"
local KILL_REPLAY_WINDOW_SECONDS = ReplayConstants.KILL_REPLAY_PRE_SECONDS + ReplayConstants.KILL_REPLAY_POST_SECONDS
local POTG_REPLAY_WINDOW_SECONDS = ReplayConstants.POTG_PRE_SECONDS + ReplayConstants.POTG_POST_SECONDS
local MIN_KILL_REPLAY_FRAMES = math.max(2, math.floor(KILL_REPLAY_WINDOW_SECONDS * ReplayConstants.SAMPLE_RATE * 0.25))
local MIN_KILL_REPLAY_SEND_FRAMES = 2
local MAX_KILL_REPLAY_FRAMES = math.ceil((KILL_REPLAY_WINDOW_SECONDS + 1) * ReplayConstants.SAMPLE_RATE)
local MAX_KILL_REPLAY_EVENTS = 160
local MIN_POTG_REPLAY_FRAMES = math.max(2, math.floor(POTG_REPLAY_WINDOW_SECONDS * ReplayConstants.SAMPLE_RATE * 0.25))
local MAX_POTG_REPLAY_FRAMES = math.ceil((POTG_REPLAY_WINDOW_SECONDS + 1) * ReplayConstants.SAMPLE_RATE)
local MAX_POTG_REPLAY_EVENTS = 220
local MAX_ROUND_DESTRUCTION_EVENTS = 260
local MAX_KILL_REPLAY_DESTRUCTION_EVENTS = MAX_ROUND_DESTRUCTION_EVENTS
local MAX_POTG_REPLAY_DESTRUCTION_EVENTS = MAX_ROUND_DESTRUCTION_EVENTS
local MAX_CLIP_PLAYERS_PER_FRAME = ReplayConstants.MAX_REPLAY_PLAYERS
local MAX_CLIP_BOMBS_PER_FRAME = math.min(24, ReplayConstants.MAX_REPLAY_BOMBS)
local MAX_CLIP_SANITIZE_DEPTH = 8
local CLIENT_ANIMATION_STATE_MAX_RATE = 20
local CLIENT_ANIMATION_STATE_STALE_SECONDS = 0.5
local MAX_REPLAY_ANIMATION_SPEED = 220
local CLIENT_REPLAY_SAMPLE_HISTORY_SECONDS = ReplayConstants.BUFFER_SECONDS + 1
local MAX_REPLAY_VISUAL_SAMPLE_AGE = 0.25
local MAX_CLIENT_REPLAY_SAMPLE_SKEW = 2
local MAX_REPLAY_POSE_JOINTS = 32
local MAX_REPLAY_JOINT_NAME_LENGTH = 48
local MIN_REPLAY_CAMERA_FOV = 20
local MAX_REPLAY_CAMERA_FOV = 120
local DEBUG_REPLAY_DESTRUCTION_LEAD_SECONDS = 0.5
local MAX_DEBRIS_PAYLOADS_PER_DESTRUCTION_EVENT = 8
local MAX_DEBRIS_BLOCKS_PER_DESTRUCTION_EVENT = 72
local MAX_RANDOM_SEED = 2147483647

local CRITICAL_REPLAY_EVENTS = table.freeze({
	PlayerKilled = true,
	BombExploded = true,
	PlayerDamaged = true,
})

local IMPORTANT_REPLAY_EVENTS = table.freeze({
	BaseDamaged = true,
	AbilityUsed = true,
	BombThrown = true,
	MapDestruction = true,
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
local latestAnimationStateByUserId = {}
local clientReplaySamplesByUserId = {}
local lastAnimationStateAtByUserId = {}
local lastKillReplayDebug = nil
local lastPOTGReplayDebug = nil
local lastClipOptimizationDebug = nil
local clipOptimizationTotals = {
	clips = 0,
	framesTrimmed = 0,
	playerSnapshotsTrimmed = 0,
	bombSnapshotsTrimmed = 0,
	eventsTrimmed = 0,
	destructionEventsTrimmed = 0,
	instanceValuesDropped = 0,
}
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

local function isFiniteVector3(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end

	return isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

local function isFiniteColor3(value: any): boolean
	if typeof(value) ~= "Color3" then
		return false
	end

	return isFiniteNumber(value.R) and isFiniteNumber(value.G) and isFiniteNumber(value.B)
end

local function getTrustedReplayTimestamp(payload): number
	local currentTime = workspace:GetServerTimeNow()
	if typeof(payload) == "table" and isFiniteNumber(payload.timestamp) then
		return math.min(payload.timestamp, currentTime)
	end
	return currentTime
end

local function countDictionaryEntries(dictionary): number
	local count = 0
	if typeof(dictionary) ~= "table" then
		return count
	end

	for _ in pairs(dictionary) do
		count += 1
	end
	return count
end

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

local function copyReplayValue(value: any, depth: number): any
	local valueType = typeof(value)
	if
		valueType == "number"
		or valueType == "string"
		or valueType == "boolean"
		or valueType == "Vector3"
		or valueType == "CFrame"
		or valueType == "Color3"
	then
		return value
	end

	if valueType ~= "table" or depth >= 3 then
		return nil
	end

	local copy = {}
	for key, child in pairs(value) do
		local keyType = typeof(key)
		if keyType ~= "string" and keyType ~= "number" then
			continue
		end

		local copiedChild = copyReplayValue(child, depth + 1)
		if copiedChild ~= nil then
			copy[key] = copiedChild
		end
	end
	return copy
end

local function copyReplayEvent(event)
	if typeof(event) ~= "table" then
		return nil
	end
	return copyReplayValue(event, 0)
end

local function getReplayIdKey(value: any): string?
	local valueType = typeof(value)
	if valueType == "string" and value ~= "" then
		return value
	end
	if valueType == "number" and value == value then
		return tostring(value)
	end
	return nil
end

local function getUserIdKey(value: any): string?
	if not (isFiniteNumber(value) and value > 0) then
		return nil
	end
	return tostring(math.floor(value))
end

local function getKillClipCaps()
	return {
		maxFrames = MAX_KILL_REPLAY_FRAMES,
		maxPlayersPerFrame = MAX_CLIP_PLAYERS_PER_FRAME,
		maxBombsPerFrame = MAX_CLIP_BOMBS_PER_FRAME,
		maxEvents = MAX_KILL_REPLAY_EVENTS,
		maxDestructionEvents = MAX_KILL_REPLAY_DESTRUCTION_EVENTS,
	}
end

local function getPOTGClipCaps()
	return {
		maxFrames = MAX_POTG_REPLAY_FRAMES,
		maxPlayersPerFrame = MAX_CLIP_PLAYERS_PER_FRAME,
		maxBombsPerFrame = MAX_CLIP_BOMBS_PER_FRAME,
		maxEvents = MAX_POTG_REPLAY_EVENTS,
		maxDestructionEvents = MAX_POTG_REPLAY_DESTRUCTION_EVENTS,
	}
end

local function sanitizeReplaySendValue(value: any, depth: number, seen, stats)
	local valueType = typeof(value)
	if valueType == "nil" then
		return nil
	end
	if valueType == "boolean" or valueType == "string" then
		return value
	end
	if valueType == "number" then
		return if isFiniteNumber(value) then value else nil
	end
	if valueType == "Vector3" or valueType == "CFrame" or valueType == "Color3" then
		return value
	end
	if valueType == "Instance" then
		if stats then
			stats.instanceValuesDropped += 1
		end
		return nil
	end
	if valueType ~= "table" or depth >= MAX_CLIP_SANITIZE_DEPTH then
		return nil
	end
	if seen[value] then
		return nil
	end

	seen[value] = true
	local copy = {}
	for key, child in pairs(value) do
		local keyType = typeof(key)
		if keyType == "Instance" then
			if stats then
				stats.instanceValuesDropped += 1
			end
			continue
		end
		if keyType ~= "string" and keyType ~= "number" then
			continue
		end

		local copiedChild = sanitizeReplaySendValue(child, depth + 1, seen, stats)
		if copiedChild ~= nil then
			copy[key] = copiedChild
		end
	end
	seen[value] = nil

	return copy
end

local function estimateClipPayloadSize(clip)
	local estimate = {
		frames = 0,
		playerSnapshots = 0,
		bombSnapshots = 0,
		cameraSnapshots = 0,
		poseJoints = 0,
		events = 0,
		destructionEvents = 0,
		maxPlayersPerFrame = 0,
		maxBombsPerFrame = 0,
	}
	if typeof(clip) ~= "table" then
		return estimate
	end

	local frames = clip.frames
	if typeof(frames) == "table" then
		estimate.frames = #frames
		for _, frame in ipairs(frames) do
			if typeof(frame) ~= "table" then
				continue
			end

			local playerCount = if typeof(frame.players) == "table" then #frame.players else 0
			local bombCount = if typeof(frame.bombs) == "table" then #frame.bombs else 0
			estimate.playerSnapshots += playerCount
			estimate.bombSnapshots += bombCount
			estimate.maxPlayersPerFrame = math.max(estimate.maxPlayersPerFrame, playerCount)
			estimate.maxBombsPerFrame = math.max(estimate.maxBombsPerFrame, bombCount)

			if typeof(frame.players) == "table" then
				for _, snapshot in ipairs(frame.players) do
					if typeof(snapshot) ~= "table" then
						continue
					end
					if typeof(snapshot.camera) == "table" then
						estimate.cameraSnapshots += 1
					end
					if typeof(snapshot.pose) == "table" and typeof(snapshot.pose.joints) == "table" then
						estimate.poseJoints += #snapshot.pose.joints
					end
				end
			end
		end
	end

	if typeof(clip.events) == "table" then
		estimate.events = #clip.events
	end
	if typeof(clip.destructionEvents) == "table" then
		estimate.destructionEvents = #clip.destructionEvents
	end

	return estimate
end

local function getFrameSampleIndices(frameCount: number, maxFrames: number): { number }
	local limit = math.max(math.floor(maxFrames), 0)
	local indices = {}
	if frameCount <= 0 or limit <= 0 then
		return indices
	end
	if frameCount <= limit then
		for index = 1, frameCount do
			table.insert(indices, index)
		end
		return indices
	end
	if limit == 1 then
		table.insert(indices, frameCount)
		return indices
	end

	local seen = {}
	for slot = 1, limit do
		local alpha = (slot - 1) / (limit - 1)
		local index = math.floor(alpha * (frameCount - 1) + 1.5)
		index = math.clamp(index, 1, frameCount)
		if not seen[index] then
			seen[index] = true
			table.insert(indices, index)
		end
	end

	local fallbackIndex = 1
	while #indices < limit and fallbackIndex <= frameCount do
		if not seen[fallbackIndex] then
			seen[fallbackIndex] = true
			table.insert(indices, fallbackIndex)
		end
		fallbackIndex += 1
	end

	table.sort(indices)
	return indices
end

local function markUserId(target, value: any)
	local key = getUserIdKey(value)
	if key then
		target[key] = true
	end
end

local function markBombId(target, value: any)
	local key = getReplayIdKey(value)
	if key then
		target[key] = true
	end
end

local function collectClipImportance(payload)
	local importance = {
		bombIds = {},
		userIds = {},
	}
	if typeof(payload) ~= "table" then
		return importance
	end

	markBombId(importance.bombIds, payload.sourceId)
	markUserId(importance.userIds, payload.killerUserId)
	markUserId(importance.userIds, payload.victimUserId)
	markUserId(importance.userIds, payload.playerUserId)

	if typeof(payload.events) == "table" then
		for _, event in ipairs(payload.events) do
			if typeof(event) ~= "table" then
				continue
			end
			markBombId(importance.bombIds, event.bombId)
			markBombId(importance.bombIds, event.sourceId)
			markUserId(importance.userIds, event.ownerUserId)
			markUserId(importance.userIds, event.attackerUserId)
			markUserId(importance.userIds, event.killerUserId)
			markUserId(importance.userIds, event.victimUserId)
			markUserId(importance.userIds, event.userId)
		end
	end

	return importance
end

local function getBombSnapshotPriority(snapshot, importance): number
	if typeof(snapshot) ~= "table" then
		return 99
	end

	local bombKey = getReplayIdKey(snapshot.bombId)
	if bombKey and importance.bombIds[bombKey] then
		return 1
	end

	local ownerKey = getUserIdKey(snapshot.ownerUserId)
	if ownerKey and importance.userIds[ownerKey] then
		return 2
	end

	if snapshot.settled == false then
		return 3
	end

	local velocity = snapshot.assemblyLinearVelocity
	if typeof(velocity) == "Vector3" and velocity.Magnitude > 1 then
		return 4
	end

	return 5
end

local function sanitizePlayerSnapshots(players, caps, stats)
	local results = {}
	if typeof(players) ~= "table" then
		return results
	end

	local maxPlayers = math.max(math.floor(caps.maxPlayersPerFrame or 0), 0)
	for index, snapshot in ipairs(players) do
		if index > maxPlayers then
			stats.playerSnapshotsTrimmed += 1
			continue
		end

		local sanitized = sanitizeReplaySendValue(snapshot, 0, {}, stats)
		if typeof(sanitized) == "table" then
			table.insert(results, sanitized)
		end
	end

	return results
end

local function sanitizeBombSnapshots(bombs, caps, importance, stats)
	local results = {}
	if typeof(bombs) ~= "table" then
		return results
	end

	local maxBombs = math.max(math.floor(caps.maxBombsPerFrame or 0), 0)
	if maxBombs <= 0 then
		stats.bombSnapshotsTrimmed += #bombs
		return results
	end

	local records = {}
	for index, snapshot in ipairs(bombs) do
		table.insert(records, {
			index = index,
			priority = getBombSnapshotPriority(snapshot, importance),
			snapshot = snapshot,
		})
	end

	if #records > maxBombs then
		table.sort(records, function(left, right)
			if left.priority == right.priority then
				return left.index < right.index
			end
			return left.priority < right.priority
		end)
		for index = maxBombs + 1, #records do
			records[index] = nil
		end
		stats.bombSnapshotsTrimmed += #bombs - #records
	end

	table.sort(records, function(left, right)
		return left.index < right.index
	end)

	for _, record in ipairs(records) do
		local sanitized = sanitizeReplaySendValue(record.snapshot, 0, {}, stats)
		if typeof(sanitized) == "table" then
			table.insert(results, sanitized)
		end
	end

	return results
end

local function sanitizeFrameForSend(frame, caps, importance, stats)
	if typeof(frame) ~= "table" then
		return nil
	end

	local sanitized = {}
	for key, value in pairs(frame) do
		if key == "players" or key == "bombs" then
			continue
		end
		if typeof(key) ~= "string" and typeof(key) ~= "number" then
			continue
		end

		local copiedValue = sanitizeReplaySendValue(value, 0, {}, stats)
		if copiedValue ~= nil then
			sanitized[key] = copiedValue
		end
	end

	sanitized.players = sanitizePlayerSnapshots(frame.players, caps, stats)
	sanitized.bombs = sanitizeBombSnapshots(frame.bombs, caps, importance, stats)
	return sanitized
end

local function getEventPriority(event): number
	local eventType = if typeof(event) == "table" then event.eventType else nil
	if CRITICAL_REPLAY_EVENTS[eventType] then
		return 1
	end
	if IMPORTANT_REPLAY_EVENTS[eventType] then
		return 2
	end
	return 3
end

local function getEventSortTime(event, fallbackIndex: number): number
	if typeof(event) == "table" and isFiniteNumber(event.timestamp) then
		return event.timestamp
	end
	return fallbackIndex
end

local function sanitizeEventsForSend(events, caps, stats)
	local results = {}
	if typeof(events) ~= "table" then
		return results
	end

	local maxEvents = math.max(math.floor(caps.maxEvents or 0), 0)
	if maxEvents <= 0 then
		stats.eventsTrimmed += #events
		return results
	end

	local records = {}
	for index, event in ipairs(events) do
		local sanitized = sanitizeReplaySendValue(event, 0, {}, stats)
		if typeof(sanitized) ~= "table" or typeof(sanitized.eventType) ~= "string" then
			continue
		end

		table.insert(records, {
			index = index,
			priority = getEventPriority(sanitized),
			sortTime = getEventSortTime(sanitized, index),
			event = sanitized,
		})
	end

	if #records > maxEvents then
		table.sort(records, function(left, right)
			if left.priority == right.priority then
				return left.index < right.index
			end
			return left.priority < right.priority
		end)
		for index = maxEvents + 1, #records do
			records[index] = nil
		end
		stats.eventsTrimmed += #events - #records
	end

	table.sort(records, function(left, right)
		if left.sortTime == right.sortTime then
			return left.index < right.index
		end
		return left.sortTime < right.sortTime
	end)

	for _, record in ipairs(records) do
		table.insert(results, record.event)
	end

	return results
end

local function sanitizeDestructionEventsForSend(events, caps, stats)
	local results = {}
	if typeof(events) ~= "table" then
		return results
	end

	local maxEvents = math.max(math.floor(caps.maxDestructionEvents or 0), 0)
	if maxEvents <= 0 then
		stats.destructionEventsTrimmed += #events
		return results
	end

	local records = {}
	for index, event in ipairs(events) do
		local sanitized = sanitizeReplaySendValue(event, 0, {}, stats)
		if
			typeof(sanitized) == "table"
			and isFiniteNumber(sanitized.timestamp)
			and typeof(sanitized.position) == "Vector3"
			and isFiniteNumber(sanitized.radius)
			and sanitized.radius > 0
		then
			table.insert(records, {
				index = index,
				sortTime = sanitized.timestamp,
				event = sanitized,
			})
		end
	end

	table.sort(records, function(left, right)
		if left.sortTime == right.sortTime then
			return left.index < right.index
		end
		return left.sortTime < right.sortTime
	end)

	local startIndex = 1
	if #records > maxEvents then
		local trimCount = #records - maxEvents
		startIndex = trimCount + 1
		stats.destructionEventsTrimmed += trimCount
	end

	for index = startIndex, #records do
		local record = records[index]
		table.insert(results, record.event)
	end

	return results
end

local function recordClipOptimization(mode: string, before, after, stats, caps)
	clipOptimizationTotals.clips += 1
	clipOptimizationTotals.framesTrimmed += stats.framesTrimmed
	clipOptimizationTotals.playerSnapshotsTrimmed += stats.playerSnapshotsTrimmed
	clipOptimizationTotals.bombSnapshotsTrimmed += stats.bombSnapshotsTrimmed
	clipOptimizationTotals.eventsTrimmed += stats.eventsTrimmed
	clipOptimizationTotals.destructionEventsTrimmed =
		(clipOptimizationTotals.destructionEventsTrimmed or 0) + stats.destructionEventsTrimmed
	clipOptimizationTotals.instanceValuesDropped += stats.instanceValuesDropped

	lastClipOptimizationDebug = {
		mode = mode,
		roundId = currentRoundId,
		before = before,
		after = after,
		caps = {
			maxFrames = caps.maxFrames,
			maxPlayersPerFrame = caps.maxPlayersPerFrame,
			maxBombsPerFrame = caps.maxBombsPerFrame,
			maxEvents = caps.maxEvents,
			maxDestructionEvents = caps.maxDestructionEvents,
		},
		trimmed = {
			frames = stats.framesTrimmed,
			playerSnapshots = stats.playerSnapshotsTrimmed,
			bombSnapshots = stats.bombSnapshotsTrimmed,
			events = stats.eventsTrimmed,
			destructionEvents = stats.destructionEventsTrimmed,
			instanceValuesDropped = stats.instanceValuesDropped,
		},
	}
end

local function optimizeClipPayloadForSend(payload, caps, mode: string)
	if typeof(payload) ~= "table" then
		return nil
	end

	local stats = {
		framesTrimmed = 0,
		playerSnapshotsTrimmed = 0,
		bombSnapshotsTrimmed = 0,
		eventsTrimmed = 0,
		destructionEventsTrimmed = 0,
		instanceValuesDropped = 0,
	}
	local before = estimateClipPayloadSize(payload)
	local importance = collectClipImportance(payload)
	local optimized = {}

	for key, value in pairs(payload) do
		if key == "frames" or key == "events" or key == "destructionEvents" then
			continue
		end
		if typeof(key) ~= "string" and typeof(key) ~= "number" then
			continue
		end

		local copiedValue = sanitizeReplaySendValue(value, 0, {}, stats)
		if copiedValue ~= nil then
			optimized[key] = copiedValue
		end
	end

	local frames = if typeof(payload.frames) == "table" then payload.frames else {}
	local frameIndices = getFrameSampleIndices(#frames, caps.maxFrames)
	stats.framesTrimmed = math.max(#frames - #frameIndices, 0)
	optimized.frames = {}
	for _, frameIndex in ipairs(frameIndices) do
		local sanitizedFrame = sanitizeFrameForSend(frames[frameIndex], caps, importance, stats)
		if sanitizedFrame then
			table.insert(optimized.frames, sanitizedFrame)
		end
	end

	optimized.events = sanitizeEventsForSend(payload.events, caps, stats)
	optimized.destructionEvents = sanitizeDestructionEventsForSend(payload.destructionEvents, caps, stats)

	local after = estimateClipPayloadSize(optimized)
	recordClipOptimization(mode, before, after, stats, caps)
	optimizedReplayPayloads[optimized] = true
	return optimized
end

local function isClipWithinCaps(clip, minFrames: number, caps): boolean
	if typeof(clip) ~= "table" then
		return false
	end

	local estimate = estimateClipPayloadSize(clip)
	if estimate.frames < minFrames or estimate.frames > caps.maxFrames then
		return false
	end
	if estimate.maxPlayersPerFrame > caps.maxPlayersPerFrame then
		return false
	end
	if estimate.maxBombsPerFrame > caps.maxBombsPerFrame then
		return false
	end
	if estimate.events > caps.maxEvents then
		return false
	end
	if estimate.destructionEvents > (caps.maxDestructionEvents or 0) then
		return false
	end

	return true
end

local function ensureRemotesFolder(): Folder
	local selected = nil
	for _, child in ipairs(ReplicatedStorage:GetChildren()) do
		if child.Name ~= ReplayConstants.REMOTES_FOLDER_NAME then
			continue
		end
		if child:IsA("Folder") and not selected then
			selected = child
		else
			child:Destroy()
		end
	end
	if selected then
		return selected
	end

	local folder = Instance.new("Folder")
	folder.Name = ReplayConstants.REMOTES_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureReplayAssetsFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(REPLAY_ASSETS_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = REPLAY_ASSETS_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureRemote(folder: Folder, name: string): RemoteEvent
	local selected = nil
	for _, child in ipairs(folder:GetChildren()) do
		if child.Name ~= name then
			continue
		end
		if child:IsA("RemoteEvent") and not selected then
			selected = child
		else
			child:Destroy()
		end
	end
	if selected then
		return selected
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

local function getReplayRemote(name: string): RemoteEvent?
	local folder = ReplicatedStorage:FindFirstChild(ReplayConstants.REMOTES_FOLDER_NAME)
	if not (folder and folder:IsA("Folder")) then
		return nil
	end

	local remote = folder:FindFirstChild(name)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
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

	return {
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
		bombCooking = player:GetAttribute(BombConfig.Attributes.Cooking) == true,
		bombCookStartedAt = getNumberAttribute(player, BombConfig.Attributes.CookStartedAt),
	}
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
	copyString("lastJumpKind", nil, 32)

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
	if typeof(state) ~= "table" or not isFiniteNumber(state.sampleTime) then
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

local function getPlayerSnapshot(player: Player, timestamp: number)
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and rootPart and rootPart:IsA("BasePart")) then
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

	return {
		userId = player.UserId,
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
	}
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
	local bombs = {}
	lastBombSource = "None"
	lastBombServiceSnapshotAvailable = type(BombProjectileService.GetReplaySnapshots) == "function"

	if lastBombServiceSnapshotAvailable then
		local ok, snapshots = pcall(function()
			return BombProjectileService:GetReplaySnapshots(ReplayConstants.MAX_REPLAY_BOMBS)
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
		return bombs
	end

	local bombFolder = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	if not bombFolder then
		lastBombContainerFound = false
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

	return bombs
end

local function buildFrame(timestamp: number)
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

	local bombs = getBombSnapshots()
	lastFramePlayerCount = #players
	lastFrameBombCount = #bombs

	return {
		timestamp = timestamp,
		players = players,
		bombs = bombs,
	}
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
end

local function unwrapOptionalSelf(first, second, third)
	if first == ReplayService then
		return second, third
	end
	return first, second
end

local function getUserIdPlayer(userId: any): Player?
	if not (isFiniteNumber(userId) and userId > 0) then
		return nil
	end

	return Players:GetPlayerByUserId(math.floor(userId))
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

local function debugKillReplaySend(status: string, payload)
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
		killerUserId = if typeof(payload) == "table" then payload.killerUserId else nil,
		victimUserId = if typeof(payload) == "table" then payload.victimUserId else nil,
		optimization = lastClipOptimizationDebug,
	}
	lastKillReplayDebug = summary

	if not DEBUG_KILL_REPLAY_SEND then
		return
	end

	warn(
		("[ReplayService] KillReplay %s start=%.3f end=%.3f frames=%d events=%d killer=%s victim=%s"):format(
			status,
			summary.startTime,
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
		sentPlayers = if typeof(extra) == "table" then extra.sentPlayers else nil,
		skippedPlayers = if typeof(extra) == "table" then extra.skippedPlayers else nil,
		optimization = lastClipOptimizationDebug,
	}
	lastPOTGReplayDebug = summary

	if not DEBUG_POTG_SEND then
		return
	end

	warn(
		("[ReplayService] POTG %s start=%.3f end=%.3f frames=%d events=%d player=%s score=%s sent=%s skipped=%s reason=%s"):format(
			status,
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
	if typeof(block) ~= "table" or not isFiniteVector3(block.center) or not isFiniteVector3(block.size) then
		return nil
	end
	if block.size.X <= 0 or block.size.Y <= 0 or block.size.Z <= 0 then
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
	if typeof(payloads) ~= "table" then
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

	return if #results > 0 then results else nil
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
	if includeDebrisPayloads == true then
		copy.debrisPayloads = copyDebrisPayloads(event.debrisPayloads)
	end
	return copy
end

local function getDestructionEventsForClip(endTime: number, debrisStartTime: number?)
	local events = {}
	if not isFiniteNumber(endTime) then
		return events
	end

	for _, event in ipairs(roundDestructionEvents) do
		if typeof(event) ~= "table" or not isFiniteNumber(event.timestamp) then
			continue
		end
		if event.timestamp > endTime then
			continue
		end

		local includeDebrisPayloads = isFiniteNumber(debrisStartTime) and event.timestamp >= debrisStartTime - 0.001
		local copy = copyDestructionEvent(event, includeDebrisPayloads)
		if copy then
			table.insert(events, copy)
		end
	end
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

local function addMapFieldsToPayload(payload, endTime: number)
	if typeof(payload) ~= "table" then
		return payload
	end

	if typeof(currentMapContext) == "table" then
		payload.mapId = currentMapContext.mapId
		payload.mapPivot = currentMapContext.mapPivot
	end
	local debrisStartTime = if isFiniteNumber(payload.startTime) then payload.startTime else nil
	payload.destructionEvents = getDestructionEventsForClip(endTime, debrisStartTime)
	return payload
end

local function buildKillReplayPayload(killEvent)
	if typeof(killEvent) ~= "table" or not isFiniteNumber(killEvent.timestamp) then
		return nil
	end
	if not isFiniteNumber(killEvent.victimUserId) then
		return nil
	end

	local deathTime = killEvent.timestamp
	local startTime = deathTime - ReplayConstants.KILL_REPLAY_PRE_SECONDS
	local endTime = deathTime
	local clip = ensureBuffer():GetClip(startTime, endTime)

	return optimizeClipPayloadForSend(addMapFieldsToPayload({
		type = "KillReplay",
		killerUserId = killEvent.killerUserId,
		victimUserId = killEvent.victimUserId,
		sourceType = killEvent.sourceType,
		sourceId = killEvent.sourceId,
		startTime = clip.startTime,
		endTime = clip.endTime,
		frames = clip.frames,
		events = clip.events,
	}, clip.endTime), getKillClipCaps(), "KillReplay")
end

local function sendKillReplayForEvent(killEvent)
	local payload = buildKillReplayPayload(killEvent)
	if not payload then
		debugKillReplaySend("skipped-invalid-payload", killEvent)
		return false
	end

	local victimPlayer = getUserIdPlayer(payload.victimUserId)
	if not victimPlayer then
		debugKillReplaySend("skipped-missing-victim", payload)
		return false
	end
	if estimateClipPayloadSize(payload).frames <= 0 then
		debugKillReplaySend("skipped-empty-clip", payload)
		return false
	end
	if not isKillReplayClipSendable(payload) then
		debugKillReplaySend("skipped-clip-guard", payload)
		return false
	end
	if not getReplayRemote(ReplayConstants.REMOTES.KillReplay) then
		debugKillReplaySend("skipped-missing-remote", payload)
		return false
	end

	local sent = ReplayService.PlayKillReplay(victimPlayer, payload)
	debugKillReplaySend(if sent then "sent" else "skipped-remote", payload)
	return sent
end

local function scheduleKillReplay(killEvent)
	if typeof(killEvent) ~= "table" then
		return
	end

	sendKillReplayForEvent(killEvent)
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
	if typeof(candidate) ~= "table" then
		return nil
	end
	if not (isFiniteNumber(candidate.startTime) and isFiniteNumber(candidate.endTime)) then
		return nil
	end
	if not (isFiniteNumber(candidate.playerUserId) and candidate.playerUserId > 0) then
		return nil
	end

	local clip = ensureBuffer():GetClip(candidate.startTime, candidate.endTime)
	return optimizeClipPayloadForSend(addMapFieldsToPayload({
		type = "POTGReplay",
		playerUserId = math.floor(candidate.playerUserId),
		sourceType = candidate.sourceType,
		sourceId = candidate.sourceId,
		reason = candidate.reason,
		score = candidate.score,
		primaryEventTime = candidate.primaryEventTime,
		startTime = clip.startTime,
		endTime = clip.endTime,
		frames = clip.frames,
		events = clip.events,
	}, clip.endTime), getPOTGClipCaps(), "POTGReplay")
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
	return players
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
		if not running then
			return
		end
		if not isFiniteNumber(deltaTime) or deltaTime <= 0 then
			return
		end

		accumulator = math.min(accumulator + deltaTime, ReplayConstants.SAMPLE_INTERVAL * 4)
		while accumulator >= ReplayConstants.SAMPLE_INTERVAL do
			accumulator -= ReplayConstants.SAMPLE_INTERVAL

			local timestamp = workspace:GetServerTimeNow()
			local frame = buildFrame(timestamp)
			ensureBuffer():AddFrame(frame)
			lastSampleTime = timestamp
			sampleCount += 1
		end
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
	end
end

function ReplayService.RecordFrame(first, second)
	local frame = unwrapOptionalSelf(first, second)
	return ensureBuffer():AddFrame(frame)
end

function ReplayService.RecordEvent(first, second, third)
	local eventType, payload = unwrapOptionalSelf(first, second, third)
	if typeof(eventType) ~= "string" or eventType == "" then
		return false
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

	local recorded = ensureBuffer():AddEvent(event)
	if recorded then
		local potgEvent = copyReplayEvent(event)
		if potgEvent then
			local ok, err = pcall(function()
				POTGService.ProcessReplayEvent(potgEvent)
			end)
			if DEBUG_POTG_EVENTS and not ok then
				warn("[ReplayService] POTG event failed:", eventType, err)
			end
		end

		if eventType == "PlayerKilled" then
			scheduleKillReplay(event)
		end
	end

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
	}
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
		debrisPayloads = copyDebrisPayloads(payload.debrisPayloads),
	}
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
		potgBestCandidate = POTGService.GetBestCandidate(),
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

local function formatCandidateSummary(candidate, index: number): string
	if typeof(candidate) ~= "table" then
		return ("#%d <invalid>"):format(index)
	end

	return ("#%d player=%s score=%s kills=%s base=%s reason=%s start=%.3f end=%.3f"):format(
		index,
		tostring(candidate.playerUserId),
		tostring(candidate.score),
		tostring(candidate.kills),
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
	}, clip.endTime), getKillClipCaps(), "DebugKillReplay")

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
	if not candidate then
		return false, "No POTG candidate is available"
	end

	local payload = buildPOTGReplayPayload(candidate)
	if not payload then
		return false, "Best POTG candidate could not produce a clip"
	end
	if typeof(payload.frames) ~= "table" or #payload.frames == 0 then
		return false, "Best POTG clip has no frames"
	end
	if not isPOTGClipReasonable(payload) then
		return false, "Best POTG clip failed replay caps"
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
	local player, clip = unwrapOptionalSelf(first, second, third)
	if not (typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players) then
		return false
	end
	if typeof(clip) ~= "table" then
		return false
	end

	if not optimizedReplayPayloads[clip] then
		clip = optimizeClipPayloadForSend(clip, getKillClipCaps(), "KillReplayDirect")
	end
	if estimateClipPayloadSize(clip).frames <= 0 then
		debugKillReplaySend("skipped-empty-clip", clip)
		return false
	end
	if not isKillReplayClipSendable(clip) then
		debugKillReplaySend("skipped-clip-guard", clip)
		return false
	end

	local remote = getReplayRemote(ReplayConstants.REMOTES.KillReplay)
	if not remote then
		debugKillReplaySend("skipped-missing-remote", clip)
		return false
	end

	local ok, err = pcall(function()
		remote:FireClient(player, clip)
	end)
	if DEBUG_KILL_REPLAY_SEND and not ok then
		warn("[ReplayService] ReplayKillReplay FireClient failed:", err)
	end

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

	local payload = buildPOTGReplayPayload(candidate)
	if not payload then
		debugPOTGReplaySend("skipped-invalid-candidate", nil, nil)
		clearPOTGSendInProgress(sendToken)
		return false
	end
	if typeof(payload.frames) ~= "table" or #payload.frames == 0 then
		debugPOTGReplaySend("skipped-empty-clip", payload, nil)
		clearPOTGSendInProgress(sendToken)
		return false
	end
	if not isPOTGClipReasonable(payload) then
		debugPOTGReplaySend("skipped-clip-guard", payload, nil)
		clearPOTGSendInProgress(sendToken)
		return false
	end
	if startedGeneration ~= roundStorageGeneration then
		debugPOTGReplaySend("skipped-stale-round", payload, nil)
		clearPOTGSendInProgress(sendToken)
		return false
	end

	local remote = getReplayRemote(ReplayConstants.REMOTES.PlayOfTheGame)
	if not remote then
		debugPOTGReplaySend("skipped-missing-remote", payload, nil)
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
			sentPlayers = sentPlayers,
			skippedPlayers = skippedPlayers,
		})
		clearPOTGSendInProgress(sendToken)
		return false
	end

	debugPOTGReplaySend("sent", payload, {
		sentPlayers = sentPlayers,
		skippedPlayers = skippedPlayers,
	})
	potgSentThisRound = true
	clearPOTGSendInProgress(sendToken)
	return true
end

return ReplayService
