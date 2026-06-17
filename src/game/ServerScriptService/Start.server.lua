local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Loader)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local DISABLED_SERVER_MODULES = {}

local function shouldLoadService(moduleScript: ModuleScript): boolean
	if not moduleScript.Name:match("Service$") then
		return false
	end

	return not DISABLED_SERVER_MODULES[moduleScript.Name]
end

local function callServiceMethod(service, methodName: string)
	if typeof(service) ~= "table" then
		return
	end

	local method = service[methodName]
	if type(method) ~= "function" then
		return
	end

	local label = "Lifecycle/ReplayService/" .. methodName
	local token = RuntimeProfiler.Begin(label)
	local ok, err = pcall(function()
		method(service)
	end)
	RuntimeProfiler.End(label, token)
	if not ok then
		warn(("[Start] %s.%s failed: %s"):format("ReplayService", methodName, tostring(err)))
	end
end

local loadedModules = Loader.LoadDescendants(ServerScriptService.Services, shouldLoadService)

callServiceMethod(loadedModules.ReplayService, "Init")
callServiceMethod(loadedModules.ReplayService, "Start")

Loader.SpawnAll(loadedModules, "OnStart")
Loader.ConnectFunctions(loadedModules, Players.PlayerAdded, "OnPlayerAdded")
Loader.ConnectFunctions(loadedModules, Players.PlayerRemoving, "OnPlayerRemoving")

for _, player in Players:GetPlayers() do
	Loader.SpawnAll(loadedModules, "OnPlayerAdded", player)
end
