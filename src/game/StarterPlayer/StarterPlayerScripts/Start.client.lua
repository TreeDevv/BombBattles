local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Loader)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local SoundUtil = require(ReplicatedStorage.Shared.Audio.SoundUtil)

local StarterPlayerScripts = script.Parent
local DISABLED_CLIENT_MODULES = {}
local playClientSoundConnection: RBXScriptConnection? = nil

local function shouldLoadController(moduleScript: ModuleScript): boolean
	if not moduleScript.Name:match("Controller$") then
		return false
	end

	return not DISABLED_CLIENT_MODULES[moduleScript.Name]
end

local function bindPlayClientSoundRemote()
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotesFolder then
		return
	end

	local remote = remotesFolder:WaitForChild("PlayClientSound", 10)
	if not (remote and remote:IsA("RemoteEvent")) then
		return
	end

	if playClientSoundConnection then
		playClientSoundConnection:Disconnect()
	end

	playClientSoundConnection = remote.OnClientEvent:Connect(function(soundName: string)
		SoundUtil.Play(soundName)
	end)
end

local loadedModules = Loader.LoadDescendants(StarterPlayerScripts.Controllers, shouldLoadController)

Loader.SpawnAll(loadedModules, "OnStart")
task.spawn(bindPlayClientSoundRemote)

return Notify
