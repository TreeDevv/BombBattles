local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Loader = require(ReplicatedStorage.Loader)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local ReplicaController = require(ReplicatedStorage.Packages.ReplicaController)
local SoundUtil = require(ReplicatedStorage.Shared.Audio.SoundUtil)

local StarterPlayerScripts = script.Parent
local ControllersFolder = StarterPlayerScripts.Controllers
local DISABLED_CLIENT_MODULES = {}
local notifyConnection: RBXScriptConnection? = nil
local playClientSoundConnection: RBXScriptConnection? = nil
local loadedControllerInstances = {}

local function shouldLoadController(moduleScript: ModuleScript): boolean
	if not moduleScript.Name:match("Controller$") then
		return false
	end

	return not DISABLED_CLIENT_MODULES[moduleScript.Name]
end

local function markLoadedControllerInstances()
	for _, descendant in ipairs(ControllersFolder:GetDescendants()) do
		if descendant:IsA("ModuleScript") and shouldLoadController(descendant) then
			loadedControllerInstances[descendant] = true
		end
	end
end

local function loadAddedController(moduleScript: ModuleScript, loadedModules: { [string]: any })
	if loadedControllerInstances[moduleScript] or not shouldLoadController(moduleScript) then
		return
	end

	loadedControllerInstances[moduleScript] = true
	local ok, loadedModule = pcall(require, moduleScript)
	if not ok then
		loadedControllerInstances[moduleScript] = nil
		warn(("[Start] Failed to load controller %s: %s"):format(moduleScript:GetFullName(), tostring(loadedModule)))
		return
	end

	loadedModules[moduleScript.Name] = loadedModule
	Loader.SpawnAll({ [moduleScript.Name] = loadedModule }, "OnStart")
end

local function bindControllerHotLoad(loadedModules: { [string]: any })
	ControllersFolder.DescendantAdded:Connect(function(descendant)
		if not descendant:IsA("ModuleScript") then
			return
		end

		task.defer(function()
			loadAddedController(descendant, loadedModules)
		end)
	end)
end

local function bindNotifyRemote()
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotesFolder then
		return
	end

	local remote = remotesFolder:WaitForChild("Notify", 10)
	if not (remote and remote:IsA("RemoteEvent")) then
		return
	end

	if notifyConnection then
		notifyConnection:Disconnect()
	end

	notifyConnection = remote.OnClientEvent:Connect(function(payload)
		Notify.Show(payload)
	end)
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

local function requestReplicaDataAfterControllersStart()
	task.defer(function()
		task.wait()
		ReplicaController.RequestData()
	end)
end

local function disableCharacterReset()
	for _ = 1, 5 do
		local success = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", false)
		end)
		if success then
			return
		end
		task.wait(0.25)
	end
end

local loadedModules = Loader.LoadDescendants(ControllersFolder, shouldLoadController)

markLoadedControllerInstances()
task.spawn(disableCharacterReset)
Loader.SpawnAll(loadedModules, "OnStart")
requestReplicaDataAfterControllersStart()
bindControllerHotLoad(loadedModules)
task.spawn(bindNotifyRemote)
task.spawn(bindPlayClientSoundRemote)

return Notify
