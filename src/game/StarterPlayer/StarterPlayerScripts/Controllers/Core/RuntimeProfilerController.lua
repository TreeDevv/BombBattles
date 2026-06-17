local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local REMOTES_FOLDER_NAME = "RuntimeProfiler"
local CONTROL_REMOTE_NAME = "ProfilerControl"
local CLIENT_SNAPSHOT_REMOTE_NAME = "ProfilerClientSnapshot"
local MODE_ATTRIBUTE = "RuntimeProfilerMode"
local MICRO_ATTRIBUTE = "RuntimeProfilerMicroProfiler"
local SLOW_THRESHOLD_ATTRIBUTE = "RuntimeProfilerSlowThresholdMs"

local RuntimeProfilerController = {}

local controlConnection: RBXScriptConnection? = nil
local renderConnection: RBXScriptConnection? = nil
local flushThreadRunning = false
local snapshotRemote: RemoteEvent? = nil
local flushInterval = 2
local frameMaxMs = 0
local frameTotalMs = 0
local frameCount = 0

local function getProfilerFolder(): Folder?
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
	if not remotes then
		return nil
	end
	local folder = remotes:WaitForChild(REMOTES_FOLDER_NAME, 15)
	return if folder and folder:IsA("Folder") then folder else nil
end

local function getSnapshotRemote(): RemoteEvent?
	if snapshotRemote and snapshotRemote.Parent then
		return snapshotRemote
	end

	local folder = getProfilerFolder()
	local remote = folder and folder:WaitForChild(CLIENT_SNAPSHOT_REMOTE_NAME, 5)
	snapshotRemote = if remote and remote:IsA("RemoteEvent") then remote else nil
	return snapshotRemote
end

local function setRenderSamplerEnabled(nextEnabled: boolean)
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end

	frameMaxMs = 0
	frameTotalMs = 0
	frameCount = 0

	if not nextEnabled then
		return
	end

	renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
		local frameMs = deltaTime * 1000
		frameCount += 1
		frameTotalMs += frameMs
		if frameMs > frameMaxMs then
			frameMaxMs = frameMs
		end
		RuntimeProfiler.Count("Client/Frames")
	end)
end

local function applyControlMessage(message)
	if typeof(message) ~= "table" or message.type ~= "SetMode" then
		return
	end

	flushInterval = if typeof(message.flushInterval) == "number" and message.flushInterval > 0
		then math.clamp(message.flushInterval, 1, 30)
		else 2

	RuntimeProfiler.SetEnabled(message.enabled == true, {
		mode = message.mode,
		microProfilerMarkers = message.microProfilerMarkers == true,
		slowThresholdMs = if typeof(message.slowThresholdMs) == "number" then message.slowThresholdMs else 2,
	})

	setRenderSamplerEnabled(RuntimeProfiler.IsEnabled())
	print(("[Profiler][Client] mode=%s"):format(RuntimeProfiler.GetMode()))
end

local function applyModeAttributes()
	local mode = ReplicatedStorage:GetAttribute(MODE_ATTRIBUTE)
	local enabled = typeof(mode) == "string" and string.lower(mode) ~= "off" and mode ~= ""
	applyControlMessage({
		type = "SetMode",
		enabled = enabled,
		mode = mode,
		microProfilerMarkers = ReplicatedStorage:GetAttribute(MICRO_ATTRIBUTE) == true,
		slowThresholdMs = ReplicatedStorage:GetAttribute(SLOW_THRESHOLD_ATTRIBUTE),
		flushInterval = 2,
	})
end

local function updateClientGauges()
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	RuntimeProfiler.Gauge("Client/FrameMaxMs", frameMaxMs)
	RuntimeProfiler.Gauge("Client/FrameAvgMs", if frameCount > 0 then frameTotalMs / frameCount else 0)
	RuntimeProfiler.Gauge("Client/PlayerGuiDescendants", if playerGui then #playerGui:GetDescendants() else 0)
	RuntimeProfiler.Gauge("Client/WorkspaceDescendants", #workspace:GetDescendants())
end

local function flushLoop()
	if flushThreadRunning then
		return
	end

	flushThreadRunning = true
	task.spawn(function()
		while flushThreadRunning do
			task.wait(flushInterval)
			if not RuntimeProfiler.IsEnabled() then
				continue
			end

			updateClientGauges()
			local snapshot = RuntimeProfiler.Flush("Client", 16, true)
			snapshot.playerUserId = Players.LocalPlayer.UserId
			local remote = getSnapshotRemote()
			if remote then
				remote:FireServer(snapshot)
			end

			frameMaxMs = 0
			frameTotalMs = 0
			frameCount = 0
		end
	end)
end

local function bindControlRemote()
	local folder = getProfilerFolder()
	if not folder then
		return
	end

	local remote = folder:WaitForChild(CONTROL_REMOTE_NAME, 5)
	if not (remote and remote:IsA("RemoteEvent")) then
		return
	end

	if controlConnection then
		controlConnection:Disconnect()
	end

	controlConnection = remote.OnClientEvent:Connect(applyControlMessage)
end

function RuntimeProfilerController:OnStart()
	task.spawn(bindControlRemote)
	ReplicatedStorage:GetAttributeChangedSignal(MODE_ATTRIBUTE):Connect(applyModeAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(MICRO_ATTRIBUTE):Connect(applyModeAttributes)
	ReplicatedStorage:GetAttributeChangedSignal(SLOW_THRESHOLD_ATTRIBUTE):Connect(applyModeAttributes)
	applyModeAttributes()
	flushLoop()
end

return RuntimeProfilerController
