local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local ReplicaController = require(ReplicatedStorage.Packages.ReplicaController)

local REMOTES_FOLDER_NAME = "Remotes"
local SUBMIT_MAP_VOTE_REMOTE_NAME = "SubmitMapVote"
local SET_AFK_REMOTE_NAME = "SetAFK"

local RoundController = {}

RoundController.StateReceived = Signal.new()
RoundController.StateUpdated = Signal.new()
RoundController.AFKResult = Signal.new()
RoundController.Loaded = false

local data = nil
local submitMapVoteRemote: RemoteEvent? = nil
local setAFKRemote: RemoteEvent? = nil
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

function RoundController:OnStart()
	ReplicaController.ReplicaOfClassCreated(RoundConfig.Scope, bindReplica)
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
