local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local ReplayBuffer = {}
ReplayBuffer.__index = ReplayBuffer

local DEFAULT_BUFFER_SECONDS = 12
local MAX_SANITIZE_DEPTH = 8

local ALLOWED_KEY_TYPES = {
	number = true,
	string = true,
}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function getRecordTimestamp(record): number?
	if typeof(record) ~= "table" then
		return nil
	end

	local timestamp = record.timestamp
	return if isFiniteNumber(timestamp) then timestamp else nil
end

local function sanitizeValue(value: any, depth: number, seen: { [any]: boolean })
	local valueType = typeof(value)
	if valueType == "nil" or valueType == "boolean" or valueType == "string" then
		return value
	end
	if valueType == "number" then
		return if isFiniteNumber(value) then value else nil
	end
	if valueType == "Vector3" or valueType == "CFrame" then
		return value
	end
	if valueType ~= "table" or depth >= MAX_SANITIZE_DEPTH then
		return nil
	end
	if seen[value] then
		return nil
	end

	seen[value] = true
	local copy = {}
	for key, childValue in pairs(value) do
		if ALLOWED_KEY_TYPES[typeof(key)] then
			local sanitizedChild = sanitizeValue(childValue, depth + 1, seen)
			if sanitizedChild ~= nil then
				copy[key] = sanitizedChild
			end
		end
	end
	seen[value] = nil

	return copy
end

local function sanitizeRecord(record)
	return sanitizeValue(record, 0, {})
end

local function findFirstRecordAtOrAfter(source, startTime: number): number
	local low = 1
	local high = #source + 1
	while low < high do
		local mid = math.floor((low + high) / 2)
		local timestamp = getRecordTimestamp(source[mid])
		if timestamp and timestamp < startTime then
			low = mid + 1
		else
			high = mid
		end
	end
	return low
end

local function normalizeWindow(startTime: any, endTime: any): (number?, number?)
	if not (isFiniteNumber(startTime) and isFiniteNumber(endTime)) then
		return nil, nil
	end
	if startTime > endTime then
		startTime, endTime = endTime, startTime
	end
	return startTime, endTime
end

local function appendRecordsInWindow(source, startTime: number, endTime: number)
	local token = RuntimeProfiler.Begin("Server/Replay/Death/BufferAppendRecords")
	local results = {}
	local scanned = 0
	local startIndex = findFirstRecordAtOrAfter(source, startTime)
	for index = startIndex, #source do
		local record = source[index]
		local timestamp = getRecordTimestamp(record)
		if timestamp and timestamp > endTime then
			break
		end
		scanned += 1
		if timestamp and timestamp >= startTime then
			table.insert(results, sanitizeRecord(record))
		end
	end
	RuntimeProfiler.Count("Server/Replay/Death/BufferRecordsScanned", scanned)
	RuntimeProfiler.Count("Server/Replay/Death/BufferRecordsCopied", #results)
	RuntimeProfiler.End("Server/Replay/Death/BufferAppendRecords", token)
	return results
end

local function pruneListBefore(list, cutoffTime: number)
	local writeIndex = 1
	for readIndex = 1, #list do
		local record = list[readIndex]
		local timestamp = getRecordTimestamp(record)
		if timestamp and timestamp >= cutoffTime then
			list[writeIndex] = record
			writeIndex += 1
		end
	end

	for index = writeIndex, #list do
		list[index] = nil
	end
end

function ReplayBuffer.new(bufferSeconds: number?)
	local resolvedBufferSeconds = if isFiniteNumber(bufferSeconds) and bufferSeconds > 0
		then bufferSeconds
		else DEFAULT_BUFFER_SECONDS

	return setmetatable({
		_bufferSeconds = resolvedBufferSeconds,
		_frames = {},
		_events = {},
		_newestTimestamp = nil,
	}, ReplayBuffer)
end

function ReplayBuffer:Clear()
	table.clear(self._frames)
	table.clear(self._events)
	self._newestTimestamp = nil
end

function ReplayBuffer:PruneBefore(cutoffTime: number)
	if not isFiniteNumber(cutoffTime) then
		return false
	end

	pruneListBefore(self._frames, cutoffTime)
	pruneListBefore(self._events, cutoffTime)
	return true
end

function ReplayBuffer:_updateRetention(timestamp: number): boolean
	local newestTimestamp = self._newestTimestamp
	if not newestTimestamp or timestamp > newestTimestamp then
		newestTimestamp = timestamp
		self._newestTimestamp = timestamp
	end

	local cutoffTime = newestTimestamp - self._bufferSeconds
	if timestamp < cutoffTime then
		return false
	end

	self:PruneBefore(cutoffTime)
	return true
end

function ReplayBuffer:AddFrame(frame)
	local timestamp = getRecordTimestamp(frame)
	if not timestamp or not self:_updateRetention(timestamp) then
		return false
	end

	local sanitizedFrame = sanitizeRecord(frame)
	if typeof(sanitizedFrame) ~= "table" then
		return false
	end

	table.insert(self._frames, sanitizedFrame)
	return true
end

function ReplayBuffer:AddEvent(event)
	local timestamp = getRecordTimestamp(event)
	if not timestamp or not self:_updateRetention(timestamp) then
		return false
	end

	local sanitizedEvent = sanitizeRecord(event)
	if typeof(sanitizedEvent) ~= "table" then
		return false
	end

	table.insert(self._events, sanitizedEvent)
	return true
end

function ReplayBuffer:GetFramesInWindow(startTime, endTime)
	local token = RuntimeProfiler.Begin("Server/Replay/Death/GetFramesInWindow")
	local normalizedStart, normalizedEnd = normalizeWindow(startTime, endTime)
	if not normalizedStart then
		RuntimeProfiler.End("Server/Replay/Death/GetFramesInWindow", token)
		return {}
	end

	local frames = appendRecordsInWindow(self._frames, normalizedStart, normalizedEnd)
	RuntimeProfiler.Count("Server/Replay/Death/ClipFrames", #frames)
	RuntimeProfiler.End("Server/Replay/Death/GetFramesInWindow", token)
	return frames
end

function ReplayBuffer:GetEventsInWindow(startTime, endTime)
	local token = RuntimeProfiler.Begin("Server/Replay/Death/GetEventsInWindow")
	local normalizedStart, normalizedEnd = normalizeWindow(startTime, endTime)
	if not normalizedStart then
		RuntimeProfiler.End("Server/Replay/Death/GetEventsInWindow", token)
		return {}
	end

	local events = appendRecordsInWindow(self._events, normalizedStart, normalizedEnd)
	RuntimeProfiler.Count("Server/Replay/Death/ClipEvents", #events)
	RuntimeProfiler.End("Server/Replay/Death/GetEventsInWindow", token)
	return events
end

function ReplayBuffer:GetClip(startTime, endTime)
	local token = RuntimeProfiler.Begin("Server/Replay/Death/GetClip")
	local normalizedStart, normalizedEnd = normalizeWindow(startTime, endTime)
	if not normalizedStart then
		RuntimeProfiler.End("Server/Replay/Death/GetClip", token)
		return {
			startTime = startTime,
			endTime = endTime,
			frames = {},
			events = {},
		}
	end

	local clip = {
		startTime = normalizedStart,
		endTime = normalizedEnd,
		frames = self:GetFramesInWindow(normalizedStart, normalizedEnd),
		events = self:GetEventsInWindow(normalizedStart, normalizedEnd),
	}
	RuntimeProfiler.End("Server/Replay/Death/GetClip", token)
	return clip
end

function ReplayBuffer:GetDebugCounts()
	return {
		frames = #self._frames,
		events = #self._events,
		bufferSeconds = self._bufferSeconds,
		newestTimestamp = self._newestTimestamp,
	}
end

function ReplayBuffer:PushFrame(frame)
	return self:AddFrame(frame)
end

function ReplayBuffer:PushEvent(event)
	return self:AddEvent(event)
end

function ReplayBuffer:GetFrames()
	local frames = {}
	for _, frame in ipairs(self._frames) do
		table.insert(frames, sanitizeRecord(frame))
	end
	return frames
end

function ReplayBuffer:GetEvents()
	local events = {}
	for _, event in ipairs(self._events) do
		table.insert(events, sanitizeRecord(event))
	end
	return events
end

return ReplayBuffer
