local RunService = game:GetService("RunService")

local RuntimeProfiler = {}

RuntimeProfiler.Mode = {
	Off = "Off",
	Counters = "Counters",
	Aggregate = "Aggregate",
	TraceWindow = "TraceWindow",
}

local DEFAULT_SLOW_THRESHOLD_MS = 8
local DEFAULT_TRACE_LIMIT = 256
local DEFAULT_TOP_LIMIT = 24
local DEFAULT_COUNTER_LIMIT = 12
local DEFAULT_GAUGE_LIMIT = 8

local enabled = false
local mode = RuntimeProfiler.Mode.Off
local microProfilerMarkers = false
local allowMicroProfilerMarkers = not RunService:IsClient()
local slowThresholdMs = DEFAULT_SLOW_THRESHOLD_MS
local traceLimit = DEFAULT_TRACE_LIMIT
local startedAt = os.clock()

local spans = {}
local counters = {}
local gauges = {}
local traces = {}

local function isTraceMode(): boolean
	return mode == RuntimeProfiler.Mode.TraceWindow
end

local function isTimingMode(): boolean
	return mode == RuntimeProfiler.Mode.Aggregate or mode == RuntimeProfiler.Mode.TraceWindow
end

local function normalizeMode(nextMode: any): string
	if typeof(nextMode) ~= "string" or nextMode == "" then
		return RuntimeProfiler.Mode.Off
	end

	for _, value in pairs(RuntimeProfiler.Mode) do
		if string.lower(nextMode) == string.lower(value) then
			return value
		end
	end

	return RuntimeProfiler.Mode.Off
end

local function getSpan(label: string)
	local aggregate = spans[label]
	if aggregate then
		return aggregate
	end

	aggregate = {
		label = label,
		calls = 0,
		totalMs = 0,
		maxMs = 0,
		lastMs = 0,
		slowCalls = 0,
	}
	spans[label] = aggregate
	return aggregate
end

local function copyDictionary(source)
	local copy = {}
	for key, value in pairs(source) do
		copy[key] = value
	end
	return copy
end

local function sortedSpanList(limit: number?)
	local list = {}
	for _, aggregate in pairs(spans) do
		table.insert(list, {
			label = aggregate.label,
			calls = aggregate.calls,
			totalMs = aggregate.totalMs,
			maxMs = aggregate.maxMs,
			lastMs = aggregate.lastMs,
			slowCalls = aggregate.slowCalls,
			avgMs = if aggregate.calls > 0 then aggregate.totalMs / aggregate.calls else 0,
		})
	end

	table.sort(list, function(left, right)
		if left.totalMs == right.totalMs then
			return left.maxMs > right.maxMs
		end
		return left.totalMs > right.totalMs
	end)

	local resolvedLimit = if typeof(limit) == "number" then math.max(math.floor(limit), 0) else nil
	if resolvedLimit and #list > resolvedLimit then
		for index = #list, resolvedLimit + 1, -1 do
			list[index] = nil
		end
	end

	return list
end

local function copyTraces()
	local copy = {}
	for index, trace in ipairs(traces) do
		copy[index] = {
			label = trace.label,
			startedAt = trace.startedAt,
			durationMs = trace.durationMs,
		}
	end
	return copy
end

local function sortedNumberList(source, limit: number?)
	local list = {}
	for label, value in pairs(source or {}) do
		if typeof(value) == "number" then
			table.insert(list, {
				label = label,
				value = value,
			})
		end
	end

	table.sort(list, function(left, right)
		if left.value == right.value then
			return left.label < right.label
		end
		return left.value > right.value
	end)

	local resolvedLimit = if typeof(limit) == "number" then math.max(math.floor(limit), 0) else nil
	if resolvedLimit and #list > resolvedLimit then
		for index = #list, resolvedLimit + 1, -1 do
			list[index] = nil
		end
	end

	return list
end

local function formatNumber(value: number): string
	if value % 1 == 0 then
		return ("%d"):format(value)
	end
	return ("%.2f"):format(value)
end

function RuntimeProfiler.IsEnabled(): boolean
	return enabled
end

function RuntimeProfiler.IsTimingEnabled(): boolean
	return enabled and isTimingMode()
end

function RuntimeProfiler.GetMode(): string
	return mode
end

function RuntimeProfiler.SetEnabled(nextEnabled: boolean, options)
	enabled = nextEnabled == true
	mode = if enabled then normalizeMode(options and options.mode) else RuntimeProfiler.Mode.Off
	if enabled and mode == RuntimeProfiler.Mode.Off then
		mode = RuntimeProfiler.Mode.Aggregate
	end

	microProfilerMarkers = allowMicroProfilerMarkers and options and options.microProfilerMarkers == true or false
	slowThresholdMs = if options and typeof(options.slowThresholdMs) == "number"
		then math.max(options.slowThresholdMs, 0)
		else DEFAULT_SLOW_THRESHOLD_MS
	traceLimit = if options and typeof(options.traceLimit) == "number"
		then math.max(math.floor(options.traceLimit), 0)
		else DEFAULT_TRACE_LIMIT

	startedAt = os.clock()
	table.clear(spans)
	table.clear(counters)
	table.clear(gauges)
	table.clear(traces)
end

function RuntimeProfiler.Configure(options)
	if typeof(options) ~= "table" then
		return
	end

	if options.mode ~= nil then
		mode = normalizeMode(options.mode)
		enabled = mode ~= RuntimeProfiler.Mode.Off
	end
	if options.microProfilerMarkers ~= nil then
		microProfilerMarkers = allowMicroProfilerMarkers and options.microProfilerMarkers == true
	end
	if typeof(options.slowThresholdMs) == "number" then
		slowThresholdMs = math.max(options.slowThresholdMs, 0)
	end
	if typeof(options.traceLimit) == "number" then
		traceLimit = math.max(math.floor(options.traceLimit), 0)
	end
end

function RuntimeProfiler.WithMicroProfilerMarkers(nextEnabled: boolean)
	microProfilerMarkers = allowMicroProfilerMarkers and nextEnabled == true
end

function RuntimeProfiler.Begin(label: string): number?
	if not enabled or not isTimingMode() then
		return nil
	end
	if typeof(label) ~= "string" or label == "" then
		return nil
	end

	if microProfilerMarkers then
		debug.profilebegin(label)
	end

	return os.clock()
end

local function recordSpanDuration(label: string, durationMs: number, startedAtSeconds: number?)
	local aggregate = getSpan(label)
	aggregate.calls += 1
	aggregate.totalMs += durationMs
	aggregate.lastMs = durationMs
	if durationMs > aggregate.maxMs then
		aggregate.maxMs = durationMs
	end
	if durationMs >= slowThresholdMs then
		aggregate.slowCalls += 1
	end

	if isTraceMode() and traceLimit > 0 then
		table.insert(traces, {
			label = label,
			startedAt = startedAtSeconds or os.clock(),
			durationMs = durationMs,
		})
		if #traces > traceLimit then
			table.remove(traces, 1)
		end
	end
end

function RuntimeProfiler.End(label: string, token: number?)
	if not token then
		return
	end

	local endedAt = os.clock()
	local durationMs = (endedAt - token) * 1000
	recordSpanDuration(label, durationMs, token)

	if microProfilerMarkers then
		debug.profileend()
	end
end

function RuntimeProfiler.RecordDurationMs(label: string, durationMs: number)
	if not enabled or not isTimingMode() then
		return
	end
	if typeof(label) ~= "string" or label == "" or typeof(durationMs) ~= "number" or durationMs < 0 then
		return
	end

	recordSpanDuration(label, durationMs, os.clock() - durationMs / 1000)
end

function RuntimeProfiler.Profile(label: string, callback, ...)
	local token = RuntimeProfiler.Begin(label)
	local packed = table.pack(pcall(callback, ...))
	RuntimeProfiler.End(label, token)

	if not packed[1] then
		error(packed[2], 2)
	end

	return table.unpack(packed, 2, packed.n)
end

function RuntimeProfiler.Count(label: string, amount: number?)
	if not enabled or mode == RuntimeProfiler.Mode.Off then
		return
	end
	if typeof(label) ~= "string" or label == "" then
		return
	end

	local delta = if typeof(amount) == "number" then amount else 1
	counters[label] = (counters[label] or 0) + delta
end

function RuntimeProfiler.Gauge(label: string, value: number)
	if not enabled or mode == RuntimeProfiler.Mode.Off then
		return
	end
	if typeof(label) ~= "string" or label == "" or typeof(value) ~= "number" then
		return
	end

	gauges[label] = value
end

function RuntimeProfiler.EstimatePayloadWeight(value: any, maxNodes: number?): number
	local limit = if typeof(maxNodes) == "number" then math.max(math.floor(maxNodes), 1) else 256
	local visited = {}
	local nodes = 0

	local function visit(nextValue): number
		nodes += 1
		if nodes > limit then
			return 1
		end

		local valueType = typeof(nextValue)
		if valueType == "nil" then
			return 0
		elseif valueType == "boolean" or valueType == "number" then
			return 1
		elseif valueType == "string" then
			return math.max(1, math.ceil(#nextValue / 8))
		elseif valueType == "Vector3" or valueType == "CFrame" or valueType == "Color3" or valueType == "UDim2" then
			return 4
		elseif valueType == "Instance" then
			return 2
		elseif valueType ~= "table" then
			return 1
		end

		if visited[nextValue] then
			return 0
		end
		visited[nextValue] = true

		local total = 1
		for key, childValue in pairs(nextValue) do
			total += visit(key)
			total += visit(childValue)
			if nodes > limit then
				break
			end
		end
		return total
	end

	return visit(value)
end

function RuntimeProfiler.Reset()
	startedAt = os.clock()
	table.clear(spans)
	table.clear(counters)
	table.clear(gauges)
	table.clear(traces)
end

function RuntimeProfiler.Flush(source: string?, limit: number?, resetAfter: boolean?)
	local endedAt = os.clock()
	local resolvedSource = source or (if RunService:IsServer() then "Server" else "Client")
	local snapshot = {
		source = resolvedSource,
		startedAt = startedAt,
		endedAt = endedAt,
		durationSeconds = endedAt - startedAt,
		mode = mode,
		spans = sortedSpanList(limit or DEFAULT_TOP_LIMIT),
		counters = copyDictionary(counters),
		gauges = copyDictionary(gauges),
		traces = if isTraceMode() then copyTraces() else nil,
	}

	if resetAfter == true then
		RuntimeProfiler.Reset()
	end

	return snapshot
end

function RuntimeProfiler.FormatSummary(snapshot, title: string?, limit: number?, counterLimit: number?, gaugeLimit: number?): string
	local lines = {}
	local resolvedTitle = title or ("[Profiler][" .. tostring(snapshot and snapshot.source or "Unknown") .. "]")
	table.insert(lines, resolvedTitle)

	local spansList = snapshot and snapshot.spans or {}
	local resolvedLimit = if typeof(limit) == "number" then math.max(math.floor(limit), 0) else math.min(#spansList, 10)
	for index = 1, math.min(#spansList, resolvedLimit) do
		local span = spansList[index]
		local avgMs = span.avgMs or (if span.calls > 0 then span.totalMs / span.calls else 0)
		table.insert(
			lines,
			("%d. %s calls=%d total=%.2fms avg=%.3fms max=%.2fms slow=%d"):format(
				index,
				span.label,
				span.calls,
				span.totalMs,
				avgMs,
				span.maxMs,
				span.slowCalls
			)
		)
	end

	local countersList = sortedNumberList(
		snapshot and snapshot.counters,
		if typeof(counterLimit) == "number" then counterLimit else DEFAULT_COUNTER_LIMIT
	)
	if #countersList > 0 then
		table.insert(lines, "[Counters]")
		for index, counter in ipairs(countersList) do
			table.insert(lines, ("%d. %s=%s"):format(index, counter.label, formatNumber(counter.value)))
		end
	end

	local gaugesList = sortedNumberList(
		snapshot and snapshot.gauges,
		if typeof(gaugeLimit) == "number" then gaugeLimit else DEFAULT_GAUGE_LIMIT
	)
	if #gaugesList > 0 then
		table.insert(lines, "[Gauges]")
		for index, gauge in ipairs(gaugesList) do
			table.insert(lines, ("%d. %s=%s"):format(index, gauge.label, formatNumber(gauge.value)))
		end
	end

	return table.concat(lines, "\n")
end

return RuntimeProfiler
