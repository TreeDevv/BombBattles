local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local REMOTES_FOLDER_NAME = "RuntimeProfiler"
local CONTROL_REMOTE_NAME = "ProfilerControl"
local CLIENT_SNAPSHOT_REMOTE_NAME = "ProfilerClientSnapshot"

local MODE_ATTRIBUTE = "RuntimeProfilerMode"
local PRINT_INTERVAL_ATTRIBUTE = "RuntimeProfilerPrintInterval"
local MICRO_ATTRIBUTE = "RuntimeProfilerMicroProfiler"
local SLOW_THRESHOLD_ATTRIBUTE = "RuntimeProfilerSlowThresholdMs"

local DEFAULT_PRINT_INTERVAL = 10
local DEFAULT_CLIENT_FLUSH_INTERVAL = 2
local DEFAULT_TOP_LIMIT = 24
local DEFAULT_CLIENT_TOP_LIMIT = 12
local DEFAULT_COUNTER_LIMIT = 16
local DEFAULT_GAUGE_LIMIT = 10

local RuntimeProfilerService = {}

local controlRemote: RemoteEvent? = nil
local clientSnapshotRemote: RemoteEvent? = nil
local clientSnapshotsByUserId = {}
local running = false

local function ensureRemotesRoot(): Folder
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if remotes and remotes:IsA("Folder") then
		return remotes
	end
	if remotes then
		remotes:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "Remotes"
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureProfilerFolder(): Folder
	local remotes = ensureRemotesRoot()
	local existing = remotes:FindFirstChild(REMOTES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = REMOTES_FOLDER_NAME
	folder.Parent = remotes
	return folder
end

local function ensureRemote(name: string): RemoteEvent
	local folder = ensureProfilerFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

local function normalizeMode(value: any): string
	if typeof(value) ~= "string" or value == "" then
		return RuntimeProfiler.Mode.Off
	end

	for _, modeValue in pairs(RuntimeProfiler.Mode) do
		if string.lower(value) == string.lower(modeValue) then
			return modeValue
		end
	end

	return RuntimeProfiler.Mode.Off
end

local function getPrintInterval(): number
	local value = ReplicatedStorage:GetAttribute(PRINT_INTERVAL_ATTRIBUTE)
	return if typeof(value) == "number" and value > 0 then math.clamp(value, 2, 120) else DEFAULT_PRINT_INTERVAL
end

local function getSlowThresholdMs(): number
	local value = ReplicatedStorage:GetAttribute(SLOW_THRESHOLD_ATTRIBUTE)
	return if typeof(value) == "number" and value >= 0 then value else 8
end

local function getBasePartCounts()
	local baseParts = 0
	local unanchored = 0
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("BasePart") then
			baseParts += 1
			if not descendant.Anchored then
				unanchored += 1
			end
		end
	end
	return baseParts, unanchored
end

local function updateServerGauges()
	RuntimeProfiler.Gauge("Server/Players", #Players:GetPlayers())
	RuntimeProfiler.Gauge("Server/WorkspaceDescendants", #workspace:GetDescendants())

	local baseParts, unanchored = getBasePartCounts()
	RuntimeProfiler.Gauge("Server/BaseParts", baseParts)
	RuntimeProfiler.Gauge("Server/UnanchoredBaseParts", unanchored)
end

local function applyModeFromAttributes()
	local nextMode = normalizeMode(ReplicatedStorage:GetAttribute(MODE_ATTRIBUTE))
	local nextEnabled = nextMode ~= RuntimeProfiler.Mode.Off
	RuntimeProfiler.SetEnabled(nextEnabled, {
		mode = nextMode,
		microProfilerMarkers = ReplicatedStorage:GetAttribute(MICRO_ATTRIBUTE) == true,
		slowThresholdMs = getSlowThresholdMs(),
	})

	if controlRemote then
		controlRemote:FireAllClients({
			type = "SetMode",
			enabled = nextEnabled,
			mode = nextMode,
			microProfilerMarkers = ReplicatedStorage:GetAttribute(MICRO_ATTRIBUTE) == true,
			slowThresholdMs = getSlowThresholdMs(),
			flushInterval = DEFAULT_CLIENT_FLUSH_INTERVAL,
		})
	end

	print(("[Profiler][Server] mode=%s"):format(nextMode))
end

local function acceptClientSnapshot(player: Player, snapshot)
	if not RuntimeProfiler.IsEnabled() or typeof(snapshot) ~= "table" then
		return
	end

	clientSnapshotsByUserId[player.UserId] = {
		playerName = player.Name,
		receivedAt = os.clock(),
		snapshot = snapshot,
	}
	RuntimeProfiler.Count("Server/Profiler/ClientSnapshots")
end

local function printClientSummaries()
	for userId, record in pairs(clientSnapshotsByUserId) do
		if os.clock() - record.receivedAt > 30 then
			clientSnapshotsByUserId[userId] = nil
			continue
		end

		local snapshot = record.snapshot
		local title = ("[Profiler][Client:%s][%.1fs]"):format(record.playerName, snapshot.durationSeconds or 0)
		print(RuntimeProfiler.FormatSummary(snapshot, title, DEFAULT_CLIENT_TOP_LIMIT, DEFAULT_COUNTER_LIMIT, DEFAULT_GAUGE_LIMIT))
	end
end

local function summaryLoop()
	while running do
		task.wait(getPrintInterval())
		if not RuntimeProfiler.IsEnabled() then
			continue
		end

		updateServerGauges()
		local snapshot = RuntimeProfiler.Flush("Server", DEFAULT_TOP_LIMIT, true)
		local title = ("[Profiler][Server][%.1fs]"):format(snapshot.durationSeconds)
		print(RuntimeProfiler.FormatSummary(snapshot, title, DEFAULT_TOP_LIMIT, DEFAULT_COUNTER_LIMIT, DEFAULT_GAUGE_LIMIT))
		printClientSummaries()
	end
end

function RuntimeProfilerService:OnStart()
	controlRemote = ensureRemote(CONTROL_REMOTE_NAME)
	clientSnapshotRemote = ensureRemote(CLIENT_SNAPSHOT_REMOTE_NAME)
	clientSnapshotRemote.OnServerEvent:Connect(acceptClientSnapshot)

	ReplicatedStorage:GetAttributeChangedSignal(MODE_ATTRIBUTE):Connect(applyModeFromAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(MICRO_ATTRIBUTE):Connect(applyModeFromAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(SLOW_THRESHOLD_ATTRIBUTE):Connect(applyModeFromAttributes)

	applyModeFromAttributes()

	if not running then
		running = true
		task.spawn(summaryLoop)
	end
end

function RuntimeProfilerService:OnPlayerAdded(player: Player)
	if controlRemote and RuntimeProfiler.IsEnabled() then
		controlRemote:FireClient(player, {
			type = "SetMode",
			enabled = true,
			mode = RuntimeProfiler.GetMode(),
			microProfilerMarkers = ReplicatedStorage:GetAttribute(MICRO_ATTRIBUTE) == true,
			slowThresholdMs = getSlowThresholdMs(),
			flushInterval = DEFAULT_CLIENT_FLUSH_INTERVAL,
		})
	end
end

function RuntimeProfilerService:OnPlayerRemoving(player: Player)
	clientSnapshotsByUserId[player.UserId] = nil
end

return RuntimeProfilerService
