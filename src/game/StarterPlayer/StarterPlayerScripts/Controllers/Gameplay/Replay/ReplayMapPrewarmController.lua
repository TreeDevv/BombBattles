local RuntimeProfiler = require(game:GetService("ReplicatedStorage").Shared.Common.RuntimeProfiler)

local ReplayClient = require(script.Parent:WaitForChild("ReplayClient"))
local ReplayMapSimulator = require(script.Parent:WaitForChild("ReplayMapSimulator"))
local RoundController = require(script.Parent.Parent:WaitForChild("RoundController"))

local ReplayMapPrewarmController = {}

ReplayMapPrewarmController._connections = {} :: { RBXScriptConnection }
ReplayMapPrewarmController._activeMapId = nil :: string?
ReplayMapPrewarmController._prewarmSerial = 0

local function normalizeMapId(mapId: any): string?
	return if typeof(mapId) == "string" and mapId ~= "" then mapId else nil
end

function ReplayMapPrewarmController:_queueActiveMapPrewarm(mapId: any, _reason: string)
	local resolvedMapId = normalizeMapId(mapId)
	if not resolvedMapId then
		return
	end

	self._activeMapId = resolvedMapId
	self._prewarmSerial += 1
	local serial = self._prewarmSerial

	task.defer(function()
		if serial ~= self._prewarmSerial then
			return
		end

		local token = RuntimeProfiler.Begin("Client/Replay/MapPrewarmController/ActiveMapPrewarm")
		local queued = ReplayMapSimulator.PrewarmActiveScene(resolvedMapId)
		RuntimeProfiler.Count(
			if queued
				then "Client/Replay/MapPrewarmController/ActiveMapPrewarmQueued"
				else "Client/Replay/MapPrewarmController/ActiveMapPrewarmSkipped"
		)
		RuntimeProfiler.End("Client/Replay/MapPrewarmController/ActiveMapPrewarm", token)
	end)
end

function ReplayMapPrewarmController:_handleRoundState(state)
	if typeof(state) ~= "table" then
		return
	end

	self:_queueActiveMapPrewarm(state.selectedMapId, "StateReceived")
end

function ReplayMapPrewarmController:_connect(signal, callback)
	if not (signal and type(signal.Connect) == "function") then
		return
	end

	table.insert(self._connections, signal:Connect(callback))
end

function ReplayMapPrewarmController:OnStart()
	self:_handleRoundState(RoundController:GetState())

	self:_connect(RoundController.StateReceived, function(state)
		self:_handleRoundState(state)
	end)

	self:_connect(RoundController.StateUpdated, function(key, value)
		if key == "selectedMapId" then
			self:_queueActiveMapPrewarm(value, "StateUpdated")
		end
	end)

	self:_connect(ReplayClient.ReplayEnded, function(payload)
		if typeof(payload) == "table" and (payload.type == "KillReplay" or payload.type == "POTGReplay") then
			self:_queueActiveMapPrewarm(self._activeMapId or RoundController:Get("selectedMapId"), "ReplayEnded")
		end
	end)
end

return ReplayMapPrewarmController
