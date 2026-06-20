local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FinisherConfig = require(ReplicatedStorage.Shared.Config.FinisherConfig)
local FinisherVFX = require(ReplicatedStorage.Shared.Effects.FinisherVFX)

local FinisherController = {}

FinisherController._connection = nil :: RBXScriptConnection?
FinisherController._bindSerial = 0

local function isValidPayload(payload): boolean
	if typeof(payload) ~= "table" then
		return false
	end
	if FinisherConfig.NormalizeFinisherId(payload.finisherId) == "" then
		return false
	end
	return typeof(payload.position) == "Vector3"
end

function FinisherController:_disconnect()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	self._bindSerial += 1
end

function FinisherController:_bindRemote()
	self:_disconnect()
	local serial = self._bindSerial

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild(FinisherConfig.RemotesFolderName, 10)
		if serial ~= self._bindSerial or not remotes then
			return
		end

		local remote = remotes:WaitForChild(FinisherConfig.PlayedRemoteName, 10)
		if serial ~= self._bindSerial or not (remote and remote:IsA("RemoteEvent")) then
			return
		end

		self._connection = remote.OnClientEvent:Connect(function(payload)
			if isValidPayload(payload) then
				FinisherVFX.PlayAt(payload.finisherId, payload.position)
			end
		end)
	end)
end

function FinisherController:OnStart()
	self:_bindRemote()
end

return FinisherController
