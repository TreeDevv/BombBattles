local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local DataService = require(script.Parent.DataService)

local DIAGNOSTICS_FIELD = Schema.Diagnostics.key
local PLAY_TIME_UPDATE_INTERVAL = 10

local function updatePlayTime(player: Player)
	DataService:Set(player, DIAGNOSTICS_FIELD, function(diagnostics)
		diagnostics = diagnostics or {}
		diagnostics.playTime = (diagnostics.playTime or 0) + PLAY_TIME_UPDATE_INTERVAL
		diagnostics.leaveTime = os.time()
		return diagnostics
	end)
end

local DiagnosticsService = {}

function DiagnosticsService:OnStart()
	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				updatePlayTime(player)
			end
			task.wait(PLAY_TIME_UPDATE_INTERVAL)
		end
	end)
end

function DiagnosticsService:OnPlayerAdded(player: Player)
	DataService:Set(player, DIAGNOSTICS_FIELD, function(diagnostics)
		diagnostics = diagnostics or {}
		local now = os.time()
		diagnostics.joins = (diagnostics.joins or 0) + 1
		diagnostics.joinTime = now
		diagnostics.leaveTime = now
		return diagnostics
	end)
end

return DiagnosticsService
