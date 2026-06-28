local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local ReplicaController = require(ReplicatedStorage.Packages.ReplicaController)

local REMOTES_FOLDER_NAME = "Remotes"
local SUBMIT_MAP_VOTE_REMOTE_NAME = "SubmitMapVote"
local SET_AFK_REMOTE_NAME = "SetAFK"
local ROUND_REPLICA_WARNING_DELAY_SECONDS = 2

local RoundController = {}

RoundController.StateReceived = Signal.new()
RoundController.StateUpdated = Signal.new()
RoundController.AFKResult = Signal.new()
RoundController.Loaded = false

local data = nil
local submitMapVoteRemote: RemoteEvent? = nil
local setAFKRemote: RemoteEvent? = nil
local boundReplica = nil
local warnedMissingRoundReplica = false
local warnedMissingSetAFKRemote = false

local function getSubmitMapVoteRemote(): RemoteEvent?
	if submitMapVoteRemote and submitMapVoteRemote.Parent then
		return submitMapVoteRemote
	end

	local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(SUBMIT_MAP_VOTE_REMOTE_NAME, 10)
	if remote and remote:IsA("RemoteEvent") then
		submitMapVoteRemote = remote
		return remote
	end

	return nil
end

local function getSetAFKRemote(): RemoteEvent?
	if setAFKRemote and setAFKRemote.Parent then
		return setAFKRemote
	end

	local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(SET_AFK_REMOTE_NAME, 10)
	if remote and remote:IsA("RemoteEvent") then
		setAFKRemote = remote
		return remote
	end

	return nil
end

local function bindSetAFKRemote()
	local remote = getSetAFKRemote()
	if not remote then
		return
	end

	remote.OnClientEvent:Connect(function(payload)
		RoundController.AFKResult:Fire(payload)
	end)
end

local function bindReplica(replica)
	if boundReplica == replica then
		return
	end

	boundReplica = replica
	data = replica.Data
	RoundController.Loaded = true
	RoundController.StateReceived:Fire(data)

	replica:ListenToRaw(function(action, path, ...)
		if action == "SetValue" then
			local key = path[#path]
			if key ~= nil then
				RoundController.StateUpdated:Fire(key, ...)
			end
		elseif action == "SetValues" then
			local values = ...
			if typeof(values) == "table" then
				for key, value in pairs(values) do
					RoundController.StateUpdated:Fire(key, value)
				end
			end
		end
	end)
end

local function bindExistingReplica()
	for _, replica in pairs(ReplicaController._replicas) do
		if replica.Class == RoundConfig.Scope then
			bindReplica(replica)
			return true
		end
	end

	return false
end

local function warnIfRoundReplicaMissing()
	if warnedMissingRoundReplica then
		return
	end

	warnedMissingRoundReplica = true
	warn(
		("[RoundController] Round replica %q was not received; round-state HUD will remain unavailable."):format(
			RoundConfig.Scope
		)
	)
end

function RoundController:OnStart()
	ReplicaController.ReplicaOfClassCreated(RoundConfig.Scope, bindReplica)
	bindExistingReplica()
	if ReplicaController.InitialDataReceived then
		task.delay(ROUND_REPLICA_WARNING_DELAY_SECONDS, function()
			if not RoundController.Loaded then
				warnIfRoundReplicaMissing()
			end
		end)
	else
		ReplicaController.InitialDataReceivedSignal:Connect(function()
			task.delay(ROUND_REPLICA_WARNING_DELAY_SECONDS, function()
				if not RoundController.Loaded then
					bindExistingReplica()
				end
				if not RoundController.Loaded then
					warnIfRoundReplicaMissing()
				end
			end)
		end)
	end

	task.spawn(getSubmitMapVoteRemote)
	task.spawn(bindSetAFKRemote)
end

function RoundController:GetState()
	return data
end

function RoundController:Get(key: string?)
	if key and data then
		return data[key]
	end

	return data
end

function RoundController:SubmitMapVote(mapId: string)
	if typeof(mapId) ~= "string" or mapId == "" then
		return
	end

	local remote = getSubmitMapVoteRemote()
	if remote then
		remote:FireServer(mapId)
	end
end

function RoundController:SetAFK(afk: boolean, source: string?)
	if typeof(afk) ~= "boolean" then
		return
	end

	local remote = getSetAFKRemote()
	if remote then
		remote:FireServer({
			afk = afk,
			source = if source == "Auto" then "Auto" else "Manual",
		})
	elseif not warnedMissingSetAFKRemote then
		warn("[RoundController] SetAFK remote unavailable; AFK request was not sent.")
		warnedMissingSetAFKRemote = true
	end
end

return RoundController
