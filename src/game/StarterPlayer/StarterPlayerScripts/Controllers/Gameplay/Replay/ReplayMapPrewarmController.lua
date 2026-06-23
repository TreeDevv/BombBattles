local RuntimeProfiler = require(game:GetService("ReplicatedStorage").Shared.Common.RuntimeProfiler)

local RoundStates = require(game:GetService("ReplicatedStorage").Shared.Config.RoundStates)
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

local ACTIVE_MAP_STATES = {
	[RoundStates.RoundStarting] = true,
	[RoundStates.Active] = true,
	[RoundStates.PlayOfTheGame] = true,
	[RoundStates.RoundEnding] = true,
}

local function getActiveReplayMapId(state): string?
	if typeof(state) ~= "table" or ACTIVE_MAP_STATES[state.state] ~= true then
		return nil
	end

	return normalizeMapId(state.selectedMapId)
end

function ReplayMapPrewarmController:_queueActiveMapPrewarm(mapId: any, _reason: string)
	local resolvedMapId = normalizeMapId(mapId)
	if not resolvedMapId then
		self._activeMapId = nil
		self._prewarmSerial += 1
		ReplayMapSimulator.SetActivePrewarmMap(nil)
		RuntimeProfiler.Count("Client/Replay/MapPrewarmController/ActiveMapPrewarmCleared")
		return
	end

	self._activeMapId = resolvedMapId
	self._prewarmSerial += 1
	local serial = self._prewarmSerial
	ReplayMapSimulator.SetActivePrewarmMap(resolvedMapId)

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
	self:_queueActiveMapPrewarm(getActiveReplayMapId(state), "StateReceived")
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

	self:_connect(RoundController.StateUpdated, function(key, _value)
		if key == "selectedMapId" or key == "state" then
			self:_handleRoundState(RoundController:GetState())
		end
	end)

	self:_connect(ReplayClient.ReplayEnded, function(payload)
		if typeof(payload) == "table" and (payload.type == "KillReplay" or payload.type == "POTGReplay") then
			self:_handleRoundState(RoundController:GetState())
		end
	end)
end

return ReplayMapPrewarmController
