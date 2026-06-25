local ReplayConstants = require(script.Parent.ReplayConstants)
local ReplayUtil = require(script.Parent.ReplayUtil)

local ReplayClipPolicy = {}

local KILL_REPLAY_SECONDS = ReplayConstants.KILL_REPLAY_PRE_SECONDS + ReplayConstants.KILL_REPLAY_POST_SECONDS
local POTG_REPLAY_SECONDS = ReplayConstants.POTG_PRE_SECONDS + ReplayConstants.POTG_POST_SECONDS
local MAX_CLIP_SANITIZE_DEPTH = 8

ReplayClipPolicy.MinKillReplayFrames = math.max(2, math.floor(KILL_REPLAY_SECONDS * ReplayConstants.SAMPLE_RATE * 0.25))
ReplayClipPolicy.MinKillReplaySendFrames = 2
ReplayClipPolicy.MinPOTGReplayFrames = math.max(2, math.floor(POTG_REPLAY_SECONDS * ReplayConstants.SAMPLE_RATE * 0.25))

local CRITICAL_EVENTS = table.freeze({
	PlayerKilled = true,
	BombExploded = true,
	PlayerDamaged = true,
})

local IMPORTANT_EVENTS = table.freeze({
	BaseDamaged = true,
	AbilityUsed = true,
	BombThrown = true,
	MapDestruction = true,
})

function ReplayClipPolicy.GetKillClipCaps()
	return {
		maxFrames = math.ceil((KILL_REPLAY_SECONDS + 1) * ReplayConstants.SAMPLE_RATE),
		maxPlayersPerFrame = ReplayConstants.MAX_REPLAY_PLAYERS,
		maxBombsPerFrame = math.min(24, ReplayConstants.MAX_REPLAY_BOMBS),
		maxEvents = 160,
		maxDestructionEvents = 0,
	}
end

function ReplayClipPolicy.GetPOTGClipCaps()
	return {
		maxFrames = math.ceil((POTG_REPLAY_SECONDS + 1) * ReplayConstants.SAMPLE_RATE),
		maxPlayersPerFrame = ReplayConstants.MAX_REPLAY_PLAYERS,
		maxBombsPerFrame = math.min(24, ReplayConstants.MAX_REPLAY_BOMBS),
		maxEvents = 220,
		maxDestructionEvents = 32,
	}
end

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

local function sanitizeValue(value: any, depth: number, seen, stats)
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
		stats.instanceValuesDropped += 1
		return nil
	end
	if valueType ~= "table" or depth >= MAX_CLIP_SANITIZE_DEPTH or seen[value] then
		return nil
	end

	seen[value] = true
	local copy = {}
	for key, childValue in pairs(value) do
		local keyType = typeof(key)
		if keyType == "string" or keyType == "number" then
			local sanitizedChild = sanitizeValue(childValue, depth + 1, seen, stats)
			if sanitizedChild ~= nil then
				copy[key] = sanitizedChild
			end
		elseif keyType == "Instance" then
			stats.instanceValuesDropped += 1
		end
	end
	seen[value] = nil
	return copy
end

function ReplayClipPolicy.SanitizeReplaySendValue(value: any, stats)
	stats = stats or { instanceValuesDropped = 0 }
	return sanitizeValue(value, 0, {}, stats)
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

	for _, frame in ipairs(clip.frames or {}) do
		local playerCount = if typeof(frame.players) == "table" then #frame.players else 0
		local bombCount = if typeof(frame.bombs) == "table" then #frame.bombs else 0

		estimate.frames += 1
		estimate.playerSnapshots += playerCount
		estimate.bombSnapshots += bombCount
		estimate.maxPlayersPerFrame = math.max(estimate.maxPlayersPerFrame, playerCount)
		estimate.maxBombsPerFrame = math.max(estimate.maxBombsPerFrame, bombCount)

		for _, snapshot in ipairs(frame.players or {}) do
			if typeof(snapshot.camera) == "table" then
				estimate.cameraSnapshots += 1
			end
			if typeof(snapshot.pose) == "table" and typeof(snapshot.pose.joints) == "table" then
				estimate.poseJoints += #snapshot.pose.joints
			end
		end
	end

	estimate.events = if typeof(clip.events) == "table" then #clip.events else 0
	estimate.destructionEvents = if typeof(clip.destructionEvents) == "table" then #clip.destructionEvents else 0
	return estimate
end

function ReplayClipPolicy.GetFrameSampleIndices(frameCount: number, maxFrames: number): { number }
	local limit = math.max(math.floor(maxFrames), 0)
	if frameCount <= 0 or limit <= 0 then
		return {}
	end
	if frameCount <= limit then
		local allIndices = {}
		for index = 1, frameCount do
			table.insert(allIndices, index)
		end
		return allIndices
	end

	local sampled = {}
	local seen = {}
	for slot = 1, limit do
		local alpha = if limit == 1 then 1 else (slot - 1) / (limit - 1)
		local index = math.clamp(math.floor(alpha * (frameCount - 1) + 1.5), 1, frameCount)
		if not seen[index] then
			seen[index] = true
			table.insert(sampled, index)
		end
	end

	local fillIndex = 1
	while #sampled < limit do
		if not seen[fillIndex] then
			seen[fillIndex] = true
			table.insert(sampled, fillIndex)
		end
		fillIndex += 1
	end

	table.sort(sampled)
	return sampled
end

local function addKey(set, key: string?)
	if key then
		set[key] = true
	end
end

local function collectImportance(payload)
	local importantBombs = {}
	local importantUsers = {}

	addKey(importantBombs, ReplayUtil.GetReplayIdKey(payload.sourceId))
	addKey(importantUsers, ReplayUtil.GetUserIdKey(payload.killerUserId))
	addKey(importantUsers, ReplayUtil.GetUserIdKey(payload.victimUserId))
	addKey(importantUsers, ReplayUtil.GetUserIdKey(payload.playerUserId))

	for _, event in ipairs(payload.events or {}) do
		addKey(importantBombs, ReplayUtil.GetReplayIdKey(event.bombId))
		addKey(importantBombs, ReplayUtil.GetReplayIdKey(event.sourceId))
		addKey(importantUsers, ReplayUtil.GetUserIdKey(event.ownerUserId))
		addKey(importantUsers, ReplayUtil.GetUserIdKey(event.attackerUserId))
		addKey(importantUsers, ReplayUtil.GetUserIdKey(event.killerUserId))
		addKey(importantUsers, ReplayUtil.GetUserIdKey(event.victimUserId))
		addKey(importantUsers, ReplayUtil.GetUserIdKey(event.userId))
	end

	return importantBombs, importantUsers
end

local function getBombPriority(snapshot, importantBombs, importantUsers): number
	if importantBombs[ReplayUtil.GetReplayIdKey(snapshot.bombId)] then
		return 1
	end
	if importantUsers[ReplayUtil.GetUserIdKey(snapshot.ownerUserId)] then
		return 2
	end
	if snapshot.settled == false then
		return 3
	end

	local velocity = snapshot.assemblyLinearVelocity
	return if typeof(velocity) == "Vector3" and velocity.Magnitude > 1 then 4 else 5
end

local function sanitizePlayerSnapshots(players, caps, stats)
	local results = {}
	local maxPlayers = math.max(math.floor(caps.maxPlayersPerFrame or 0), 0)

	for index, snapshot in ipairs(players or {}) do
		if index > maxPlayers then
			stats.playerSnapshotsTrimmed += 1
			continue
		end

		local sanitized = sanitizeValue(snapshot, 0, {}, stats)
		if sanitized then
			table.insert(results, sanitized)
		end
	end
	return results
end

local function sanitizeBombSnapshots(bombs, caps, importantBombs, importantUsers, stats)
	local maxBombs = math.max(math.floor(caps.maxBombsPerFrame or 0), 0)
	local records = {}

	for index, snapshot in ipairs(bombs or {}) do
		table.insert(records, {
			index = index,
			priority = getBombPriority(snapshot, importantBombs, importantUsers),
			snapshot = snapshot,
		})
	end

	if #records > maxBombs then
		table.sort(records, function(left, right)
			return left.priority == right.priority and left.index < right.index or left.priority < right.priority
		end)
		stats.bombSnapshotsTrimmed += #records - maxBombs
		for index = maxBombs + 1, #records do
			records[index] = nil
		end
	end

	table.sort(records, function(left, right)
		return left.index < right.index
	end)

	local results = {}
	for _, record in ipairs(records) do
		local sanitized = sanitizeValue(record.snapshot, 0, {}, stats)
		if sanitized then
			table.insert(results, sanitized)
		end
	end
	return results
end

local function sanitizeFrame(frame, caps, importantBombs, importantUsers, stats)
	local sanitized = sanitizeValue(frame, 0, {}, stats)
	if not sanitized then
		return nil
	end

	sanitized.players = sanitizePlayerSnapshots(frame.players, caps, stats)
	sanitized.bombs = sanitizeBombSnapshots(frame.bombs, caps, importantBombs, importantUsers, stats)
	return sanitized
end

function ReplayClipPolicy.GetEventPriority(event): number
	local eventType = if typeof(event) == "table" then event.eventType else nil
	if CRITICAL_EVENTS[eventType] then
		return 1
	end
	if IMPORTANT_EVENTS[eventType] then
		return 2
	end
	return 3
end

local function sanitizeEvents(events, caps, stats)
	local maxEvents = math.max(math.floor(caps.maxEvents or 0), 0)
	local records = {}

	for index, event in ipairs(events or {}) do
		local sanitized = sanitizeValue(event, 0, {}, stats)
		if sanitized and typeof(sanitized.eventType) == "string" then
			table.insert(records, {
				index = index,
				event = sanitized,
				priority = ReplayClipPolicy.GetEventPriority(sanitized),
				sortTime = if ReplayUtil.IsFiniteNumber(sanitized.timestamp) then sanitized.timestamp else index,
			})
		end
	end

	if #records > maxEvents then
		table.sort(records, function(left, right)
			return left.priority == right.priority and left.index < right.index or left.priority < right.priority
		end)
		stats.eventsTrimmed += #records - maxEvents
		for index = maxEvents + 1, #records do
			records[index] = nil
		end
	end

	table.sort(records, function(left, right)
		return left.sortTime == right.sortTime and left.index < right.index or left.sortTime < right.sortTime
	end)

	local results = {}
	for _, record in ipairs(records) do
		table.insert(results, record.event)
	end
	return results
end

local function sanitizeDestructionEvents(events, caps, stats)
	local maxEvents = math.max(math.floor(caps.maxDestructionEvents or 0), 0)
	local records = {}

	for index, event in ipairs(events or {}) do
		local sanitized = sanitizeValue(event, 0, {}, stats)
		if
			sanitized
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
		return left.sortTime == right.sortTime and left.index < right.index or left.sortTime < right.sortTime
	end)

	local startIndex = math.max(#records - maxEvents + 1, 1)
	stats.destructionEventsTrimmed += startIndex - 1

	local results = {}
	for index = startIndex, #records do
		table.insert(results, records[index].event)
	end
	return results
end

function ReplayClipPolicy.AccumulateOptimizationTotals(totals, stats)
	for key, value in pairs(stats) do
		if typeof(totals[key]) == "number" and typeof(value) == "number" then
			totals[key] += value
		end
	end
	totals.clips += 1
end

function ReplayClipPolicy.OptimizeClipPayloadForSend(payload, caps, mode: string)
	if typeof(payload) ~= "table" then
		return nil
	end

	local stats = ReplayClipPolicy.CreateOptimizationTotals()
	stats.clips = 0

	local before = ReplayClipPolicy.EstimateClipPayloadSize(payload)
	local importantBombs, importantUsers = collectImportance(payload)
	local optimized = {}

	for key, value in pairs(payload) do
		if key ~= "frames" and key ~= "events" and key ~= "destructionEvents" then
			local copiedValue = sanitizeValue(value, 0, {}, stats)
			if copiedValue ~= nil then
				optimized[key] = copiedValue
			end
		end
	end

	local frames = if typeof(payload.frames) == "table" then payload.frames else {}
	local frameIndices = ReplayClipPolicy.GetFrameSampleIndices(#frames, caps.maxFrames)
	stats.framesTrimmed = math.max(#frames - #frameIndices, 0)

	optimized.frames = {}
	for _, frameIndex in ipairs(frameIndices) do
		local frame = sanitizeFrame(frames[frameIndex], caps, importantBombs, importantUsers, stats)
		if frame then
			table.insert(optimized.frames, frame)
		end
	end

	optimized.events = sanitizeEvents(payload.events, caps, stats)
	optimized.destructionEvents = sanitizeDestructionEvents(payload.destructionEvents, caps, stats)

	return optimized, {
		mode = mode,
		before = before,
		after = ReplayClipPolicy.EstimateClipPayloadSize(optimized),
		stats = stats,
		caps = caps,
	}
end

function ReplayClipPolicy.IsClipWithinCaps(clip, minFrames: number, caps): boolean
	local estimate = ReplayClipPolicy.EstimateClipPayloadSize(clip)
	return estimate.frames >= minFrames
		and estimate.frames <= caps.maxFrames
		and estimate.maxPlayersPerFrame <= caps.maxPlayersPerFrame
		and estimate.maxBombsPerFrame <= caps.maxBombsPerFrame
		and estimate.events <= caps.maxEvents
		and estimate.destructionEvents <= (caps.maxDestructionEvents or 0)
end

return table.freeze(ReplayClipPolicy)
