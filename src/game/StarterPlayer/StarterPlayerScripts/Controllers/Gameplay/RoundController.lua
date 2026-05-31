local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local ReplicaController = require(ReplicatedStorage.Packages.ReplicaController)

local REMOTES_FOLDER_NAME = "Remotes"
local SUBMIT_MAP_VOTE_REMOTE_NAME = "SubmitMapVote"

local RoundController = {}

RoundController.StateReceived = Signal.new()
RoundController.StateUpdated = Signal.new()
RoundController.Loaded = false

local data = nil
local submitMapVoteRemote: RemoteEvent? = nil

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
	ReplicaController.RequestData()
	task.spawn(getSubmitMapVoteRemote)
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

return RoundController
