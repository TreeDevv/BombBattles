local ReplayConstants = require(script.Parent.ReplayConstants)
local ReplayUtil = require(script.Parent.ReplayUtil)

local ReplayClipPolicy = {}

local KILL_REPLAY_WINDOW_SECONDS = ReplayConstants.KILL_REPLAY_PRE_SECONDS + ReplayConstants.KILL_REPLAY_POST_SECONDS
local POTG_REPLAY_WINDOW_SECONDS = ReplayConstants.POTG_PRE_SECONDS + ReplayConstants.POTG_POST_SECONDS
local MAX_KILL_REPLAY_DESTRUCTION_EVENTS = 32
local MAX_POTG_REPLAY_DESTRUCTION_EVENTS = 32
local MAX_CLIP_SANITIZE_DEPTH = 8

ReplayClipPolicy.MinKillReplayFrames =
	math.max(2, math.floor(KILL_REPLAY_WINDOW_SECONDS * ReplayConstants.SAMPLE_RATE * 0.25))
ReplayClipPolicy.MinKillReplaySendFrames = 2
ReplayClipPolicy.MinPOTGReplayFrames =
	math.max(2, math.floor(POTG_REPLAY_WINDOW_SECONDS * ReplayConstants.SAMPLE_RATE * 0.25))

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

function ReplayClipPolicy.CreateOptimizationTotals()
	return {
		clips = 0,
		framesTrimmed = 0,
		playerSnapshotsTrimmed = 0,
		bombSnapshotsTrimmed = 0,
		eventsTrimmed = 0,
		destructionEventsTrimmed = 0,
		instanceValuesDropped = 0,
	}
end

function ReplayClipPolicy.GetKillClipCaps()
	return {
		maxFrames = math.ceil((KILL_REPLAY_WINDOW_SECONDS + 1) * ReplayConstants.SAMPLE_RATE),
		maxPlayersPerFrame = ReplayConstants.MAX_REPLAY_PLAYERS,
		maxBombsPerFrame = math.min(24, ReplayConstants.MAX_REPLAY_BOMBS),
		maxEvents = 160,
		maxDestructionEvents = MAX_KILL_REPLAY_DESTRUCTION_EVENTS,
	}
end

function ReplayClipPolicy.GetPOTGClipCaps()
	return {
		maxFrames = math.ceil((POTG_REPLAY_WINDOW_SECONDS + 1) * ReplayConstants.SAMPLE_RATE),
		maxPlayersPerFrame = ReplayConstants.MAX_REPLAY_PLAYERS,
		maxBombsPerFrame = math.min(24, ReplayConstants.MAX_REPLAY_BOMBS),
		maxEvents = 220,
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
		return if ReplayUtil.IsFiniteNumber(value) then value else nil
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

function ReplayClipPolicy.SanitizeReplaySendValue(value: any, stats)
	return sanitizeReplaySendValue(value, 0, {}, stats)
end

function ReplayClipPolicy.EstimateClipPayloadSize(clip)
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

function ReplayClipPolicy.GetFrameSampleIndices(frameCount: number, maxFrames: number): { number }
	return getFrameSampleIndices(frameCount, maxFrames)
end

local function markUserId(target, value: any)
	local key = ReplayUtil.GetUserIdKey(value)
	if key then
		target[key] = true
	end
end

local function markBombId(target, value: any)
	local key = ReplayUtil.GetReplayIdKey(value)
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

	local bombKey = ReplayUtil.GetReplayIdKey(snapshot.bombId)
	if bombKey and importance.bombIds[bombKey] then
		return 1
	end

	local ownerKey = ReplayUtil.GetUserIdKey(snapshot.ownerUserId)
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

function ReplayClipPolicy.GetEventPriority(event): number
	local eventType = if typeof(event) == "table" then event.eventType else nil
	if CRITICAL_REPLAY_EVENTS[eventType] then
		return 1
	end
	if IMPORTANT_REPLAY_EVENTS[eventType] then
		return 2
	end
	return 3
end

function ReplayClipPolicy.GetEventSortTime(event, fallbackIndex: number): number
	if typeof(event) == "table" and ReplayUtil.IsFiniteNumber(event.timestamp) then
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
			priority = ReplayClipPolicy.GetEventPriority(sanitized),
			sortTime = ReplayClipPolicy.GetEventSortTime(sanitized, index),
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
			and ReplayUtil.IsFiniteNumber(sanitized.timestamp)
			and typeof(sanitized.position) == "Vector3"
			and ReplayUtil.IsFiniteNumber(sanitized.radius)
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

function ReplayClipPolicy.AccumulateOptimizationTotals(totals, stats)
	if typeof(totals) ~= "table" or typeof(stats) ~= "table" then
		return
	end

	totals.clips += 1
	totals.framesTrimmed += stats.framesTrimmed
	totals.playerSnapshotsTrimmed += stats.playerSnapshotsTrimmed
	totals.bombSnapshotsTrimmed += stats.bombSnapshotsTrimmed
	totals.eventsTrimmed += stats.eventsTrimmed
	totals.destructionEventsTrimmed = (totals.destructionEventsTrimmed or 0) + stats.destructionEventsTrimmed
	totals.instanceValuesDropped += stats.instanceValuesDropped
end

function ReplayClipPolicy.BuildOptimizationDebug(mode: string, roundId, before, after, stats, caps)
	return {
		mode = mode,
		roundId = roundId,
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

function ReplayClipPolicy.OptimizeClipPayloadForSend(payload, caps, mode: string)
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
	local before = ReplayClipPolicy.EstimateClipPayloadSize(payload)
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

	local after = ReplayClipPolicy.EstimateClipPayloadSize(optimized)
	local debug = {
		mode = mode,
		before = before,
		after = after,
		stats = stats,
		caps = caps,
	}
	return optimized, debug
end

function ReplayClipPolicy.IsClipWithinCaps(clip, minFrames: number, caps): boolean
	if typeof(clip) ~= "table" then
		return false
	end

	local estimate = ReplayClipPolicy.EstimateClipPayloadSize(clip)
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

return table.freeze(ReplayClipPolicy)
