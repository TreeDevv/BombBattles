local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Loader)

local DISABLED_SERVER_MODULES = {}

local function shouldLoadService(moduleScript: ModuleScript): boolean
	if not moduleScript.Name:match("Service$") then
		return false
	end

	return not DISABLED_SERVER_MODULES[moduleScript.Name]
end

local loadedModules = Loader.LoadDescendants(ServerScriptService.Services, shouldLoadService)

Loader.SpawnAll(loadedModules, "OnStart")
Loader.ConnectFunctions(loadedModules, Players.PlayerAdded, "OnPlayerAdded")
Loader.ConnectFunctions(loadedModules, Players.PlayerRemoving, "OnPlayerRemoving")

for _, player in Players:GetPlayers() do
	Loader.SpawnAll(loadedModules, "OnPlayerAdded", player)
end
