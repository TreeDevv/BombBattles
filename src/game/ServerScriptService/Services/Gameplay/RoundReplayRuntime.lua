local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local RoundReplayRuntime = {}

local replayService = nil

function RoundReplayRuntime.GetService(debugEnabled: boolean?)
	if replayService then
		return replayService
	end

	local services = ServerScriptService:FindFirstChild("Services")
	local replayModule = services and services:FindFirstChild("ReplayService")
	if not (replayModule and replayModule:IsA("ModuleScript")) then
		return nil
	end

	local ok, service = pcall(require, replayModule)
	if ok and typeof(service) == "table" then
		replayService = service
		return replayService
	end

	if debugEnabled then
		warn("[RoundReplayRuntime] ReplayService require failed:", service)
	end
	return nil
end

function RoundReplayRuntime.RecordEvent(eventType: string, payload, options)
	local service = RoundReplayRuntime.GetService(options and options.debugEnabled)
	if not (service and type(service.RecordEvent) == "function") then
		if options and options.debugDeathFlow and eventType == "PlayerKilled" then
			options.debugDeathFlow("Replay event skipped; ReplayService.RecordEvent unavailable", payload)
		end
		return
	end

	if options and options.debugDeathFlow and eventType == "PlayerKilled" then
		options.debugDeathFlow("Recording PlayerKilled replay event", payload)
	end

	local recorded = nil
	local ok, err = pcall(function()
		recorded = service.RecordEvent(eventType, payload)
	end)
	if options and options.debugEnabled and not ok then
		warn("[RoundReplayRuntime] Replay event failed:", eventType, err)
	elseif options and options.debugDeathFlow and eventType == "PlayerKilled" then
		options.debugDeathFlow("ReplayService.RecordEvent returned", "pcall", ok, "recorded", recorded, "err", err)
	end
end

function RoundReplayRuntime.SetPerformanceCritical(isCritical: boolean, debugEnabled: boolean?)
	local service = RoundReplayRuntime.GetService(debugEnabled)
	if not (service and type(service.SetPerformanceCritical) == "function") then
		return
	end

	local ok, err = pcall(function()
		service.SetPerformanceCritical(isCritical)
	end)
	if debugEnabled and not ok then
		warn("[RoundReplayRuntime] Replay performance state failed:", err)
	end
end

function RoundReplayRuntime.ResetRound(roundId: number, debugEnabled: boolean?)
	local service = RoundReplayRuntime.GetService(debugEnabled)
	if not service then
		return
	end

	local ok, err = pcall(function()
		if type(service.ResetRound) == "function" then
			service.ResetRound(roundId)
		elseif type(service.ResetPOTGRound) == "function" then
			service.ResetPOTGRound(roundId)
		end
	end)
	if debugEnabled and not ok then
		warn("[RoundReplayRuntime] Replay round reset failed:", err)
	end
end

function RoundReplayRuntime.SetRoundMap(mapId: string, map: Model, debugEnabled: boolean?)
	local service = RoundReplayRuntime.GetService(debugEnabled)
	if not (service and type(service.SetRoundMap) == "function") then
		return
	end

	local ok, err = pcall(function()
		service.SetRoundMap(mapId, map:GetPivot())
	end)
	if debugEnabled and not ok then
		warn("[RoundReplayRuntime] Replay map state failed:", err)
	end
end

function RoundReplayRuntime.GetRecipients(roundPlayers): { Player }
	local recipients = {}
	for player in pairs(roundPlayers) do
		if player.Parent == Players then
			table.insert(recipients, player)
		end
	end
	return recipients
end

function RoundReplayRuntime.GetConfiguredDuration(value: any, fallback: number): number
	if typeof(value) == "number" and value == value then
		return math.max(value, 0)
	end
	return fallback
end

function RoundReplayRuntime.PlayPOTG(roundPlayers, maxWaitSeconds: number, debugEnabled: boolean?): boolean
	local service = RoundReplayRuntime.GetService(debugEnabled)
	if not (service and type(service.PlayPOTG) == "function") then
		return false
	end

	local sent = false
	local ok, err = pcall(function()
		sent = service.PlayPOTG(RoundReplayRuntime.GetRecipients(roundPlayers), {
			maxWaitSeconds = maxWaitSeconds,
		})
	end)
	if debugEnabled and not ok then
		warn("[RoundReplayRuntime] POTG playback failed:", err)
	end

	return ok and sent == true
end

return table.freeze(RoundReplayRuntime)
