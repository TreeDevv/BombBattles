local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local ReplayRemoteBinder = {}

local function debug(deps, ...)
	local fn = deps and deps.debugReplayClient
	if fn then
		fn(...)
	end
end

function ReplayRemoteBinder.RequestKillReplay(client, reason: string?, deps): boolean
	local token = RuntimeProfiler.Begin("Client/Replay/Death/RequestKillReplay")
	local constants = deps.getReplayConstants()
	local remotes = constants and constants.REMOTES
	local remoteName = remotes and remotes.KillReplayRequest
	if typeof(remoteName) ~= "string" or remoteName == "" then
		debug(deps, "KillReplay request remote missing from constants")
		RuntimeProfiler.End("Client/Replay/Death/RequestKillReplay", token)
		return false
	end

	local remote = client._boundRemotes[remoteName]
	if not (remote and remote:IsA("RemoteEvent")) then
		local remotesFolder = ReplicatedStorage:FindFirstChild(constants.REMOTES_FOLDER_NAME)
		remote = remotesFolder and remotesFolder:FindFirstChild(remoteName)
	end
	if not (remote and remote:IsA("RemoteEvent")) then
		debug(deps, "KillReplay request remote unavailable", remoteName)
		RuntimeProfiler.End("Client/Replay/Death/RequestKillReplay", token)
		return false
	end

	local requestReason = if typeof(reason) == "string" and reason ~= "" then reason else "DeadNoReplay"
	debug(deps, "Requesting KillReplay", requestReason)
	local fireToken = RuntimeProfiler.Begin("Client/Replay/Death/RequestKillReplay/FireServer")
	local ok, err = pcall(function()
		remote:FireServer({
			reason = requestReason,
		})
	end)
	RuntimeProfiler.End("Client/Replay/Death/RequestKillReplay/FireServer", fireToken)
	if not ok then
		warn("[ReplayClient] KillReplay request failed: " .. tostring(err))
		RuntimeProfiler.End("Client/Replay/Death/RequestKillReplay", token)
		return false
	end
	RuntimeProfiler.Count("Client/Replay/Death/KillReplayRequests")
	RuntimeProfiler.End("Client/Replay/Death/RequestKillReplay", token)
	return true
end

function ReplayRemoteBinder.BindRemoteInstance(client, remoteName: string, remote: Instance, deps): boolean
	if not (remote and remote:IsA("RemoteEvent")) then
		debug(deps, "Remote not ready", remoteName, if remote then remote.ClassName else "nil")
		return false
	end
	if client._boundRemotes[remoteName] == remote then
		return true
	end
	client._boundRemotes[remoteName] = remote
	debug(deps, "Bound remote", remoteName, remote:GetFullName())

	table.insert(client._connections, remote.OnClientEvent:Connect(function(payload)
		if remoteName == "ReplayCancel" or payload == "CancelReplay" or (typeof(payload) == "table" and payload.type == "CancelReplay") then
			client:CancelReplay()
			return
		end

		if typeof(payload) == "table" and payload.type == "KillReplay" then
			local token = RuntimeProfiler.Begin("Client/Replay/Death/RemoteKillReplayReceived")
			local frameCount = if typeof(payload.frames) == "table" then #payload.frames else 0
			local eventCount = if typeof(payload.events) == "table" then #payload.events else 0
			local destructionEventCount = if typeof(payload.destructionEvents) == "table" then #payload.destructionEvents else 0
			RuntimeProfiler.Count("Client/Replay/Death/RemoteFrames", frameCount)
			RuntimeProfiler.Count("Client/Replay/Death/RemoteEvents", eventCount)
			RuntimeProfiler.Count("Client/Replay/Death/RemoteDestructionEvents", destructionEventCount)
			print(
				("[ReplayClient] Received KillReplay start=%.3f end=%.3f frames=%d events=%d destruction=%d killer=%s victim=%s"):format(
					if typeof(payload.startTime) == "number" then payload.startTime else 0,
					if typeof(payload.endTime) == "number" then payload.endTime else 0,
					frameCount,
					eventCount,
					destructionEventCount,
					tostring(payload.killerUserId),
					tostring(payload.victimUserId)
				)
			)
			if type(client.ReceiveKillReplay) == "function" then
				client:ReceiveKillReplay(payload)
			else
				client:PlayKillReplay(payload)
			end
			RuntimeProfiler.End("Client/Replay/Death/RemoteKillReplayReceived", token)
			return
		end

		if typeof(payload) == "table" and payload.type == "POTGReplay" then
			local frameCount = if typeof(payload.frames) == "table" then #payload.frames else 0
			local eventCount = if typeof(payload.events) == "table" then #payload.events else 0
			local destructionEventCount = if typeof(payload.destructionEvents) == "table" then #payload.destructionEvents else 0
			print(
				("[ReplayClient] Received POTGReplay start=%.3f end=%.3f frames=%d events=%d destruction=%d player=%s score=%s reason=%s"):format(
					if typeof(payload.startTime) == "number" then payload.startTime else 0,
					if typeof(payload.endTime) == "number" then payload.endTime else 0,
					frameCount,
					eventCount,
					destructionEventCount,
					tostring(payload.playerUserId),
					tostring(payload.score),
					tostring(payload.reason)
				)
			)
			client:PlayPOTGReplay(payload)
			return
		end

		print("[ReplayClient] Received " .. remoteName, payload)
	end))

	return true
end

function ReplayRemoteBinder.BindRemote(client, remotesFolder: Instance, remoteName: string, deps)
	local remote = remotesFolder:FindFirstChild(remoteName)
	if ReplayRemoteBinder.BindRemoteInstance(client, remoteName, remote, deps) then
		return
	end

	warn("[ReplayClient] Waiting for remote: " .. remoteName)
	table.insert(client._connections, remotesFolder.ChildAdded:Connect(function(child)
		if child.Name == remoteName then
			ReplayRemoteBinder.BindRemoteInstance(client, remoteName, child, deps)
		end
	end))
end

function ReplayRemoteBinder.StartAnimationStatePublisher(client, remotesFolder: Instance, constants, deps)
	local remotes = constants and constants.REMOTES
	local remoteName = remotes and remotes.AnimationState
	if typeof(remoteName) ~= "string" or remoteName == "" then
		return
	end

	local remote = remotesFolder:FindFirstChild(remoteName)
	if not (remote and remote:IsA("RemoteEvent")) then
		warn("[ReplayClient] Waiting for animation-state remote: " .. tostring(remoteName))
		table.insert(client._connections, remotesFolder.ChildAdded:Connect(function(child)
			if child.Name == remoteName then
				ReplayRemoteBinder.StartAnimationStatePublisher(client, remotesFolder, constants, deps)
			end
		end))
		return
	end
	if client._boundRemotes[remoteName] == remote then
		return
	end
	client._boundRemotes[remoteName] = remote

	local accumulator = 0
	table.insert(client._connections, RunService.RenderStepped:Connect(function(deltaTime)
		if client._activeReplay then
			return
		end
		if not deps.isFiniteNumber(deltaTime) or deltaTime <= 0 then
			return
		end

		accumulator += deltaTime
		if accumulator < deps.animationStateSendInterval then
			return
		end
		accumulator = math.min(accumulator - deps.animationStateSendInterval, deps.animationStateSendInterval)

		local payload = deps.buildLocalAnimationStatePayload()
		if payload then
			pcall(function()
				remote:FireServer(payload)
			end)
		end
	end))
end

return ReplayRemoteBinder
