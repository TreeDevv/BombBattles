local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local SoundUtil = require(ReplicatedStorage.Shared.Audio.SoundUtil)

local ReplayAssets = {}

local replayEmitModule = nil
local replayEmitModuleInitialized = false
local warnedMissingReplayEmitModule = false
local prewarmInProgress = false
local prewarmComplete = false

function ReplayAssets.GetReplayConstants()
	local sharedFolder = ReplicatedStorage:WaitForChild("Shared", 10)
	if not sharedFolder then
		warn("[ReplayClient] Missing ReplicatedStorage.Shared")
		return nil
	end

	local replayFolder = sharedFolder:WaitForChild("Replay", 10)
	if not replayFolder then
		warn("[ReplayClient] Missing ReplicatedStorage.Shared.Replay")
		return nil
	end

	local constantsModule = replayFolder:WaitForChild("ReplayConstants", 10)
	if not (constantsModule and constantsModule:IsA("ModuleScript")) then
		warn("[ReplayClient] Missing ReplayConstants")
		return nil
	end

	local ok, constants = pcall(require, constantsModule)
	if not ok then
		warn("[ReplayClient] Failed to require ReplayConstants: " .. tostring(constants))
		return nil
	end

	return constants
end

function ReplayAssets.GetReplayAssetsFolder(folderName: string?): Folder?
	local folder = ReplicatedStorage:FindFirstChild(folderName or "ReplayAssets")
	return if folder and folder:IsA("Folder") then folder else nil
end

function ReplayAssets.GetAssetsFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild("Assets")
	return if folder and folder:IsA("Folder") then folder else nil
end

local function appendPreloadRoot(list: { Instance }, root: Instance?)
	if root then
		table.insert(list, root)
	end
end

function ReplayAssets.PrewarmContent(folderName: string?)
	if prewarmComplete or prewarmInProgress then
		return
	end

	prewarmInProgress = true
	task.spawn(function()
		local token = RuntimeProfiler.Begin("Client/Replay/Assets/PrewarmContent")
		local preloadRoots = {}
		appendPreloadRoot(preloadRoots, ReplayAssets.GetReplayAssetsFolder(folderName))

		local assetsFolder = ReplayAssets.GetAssetsFolder()
		appendPreloadRoot(preloadRoots, assetsFolder and assetsFolder:FindFirstChild("Bombs"))
		appendPreloadRoot(preloadRoots, assetsFolder and assetsFolder:FindFirstChild("Finishers"))
		appendPreloadRoot(preloadRoots, assetsFolder and assetsFolder:FindFirstChild("Replay"))

		local ok, err = true, nil
		if #preloadRoots > 0 then
			ok, err = pcall(function()
				ContentProvider:PreloadAsync(preloadRoots)
			end)
		end

		prewarmInProgress = false
		prewarmComplete = ok
		if ok then
			RuntimeProfiler.Count("Client/Replay/Assets/PrewarmedContentRoots", #preloadRoots)
		else
			warn("[ReplayClient] Failed to preload replay content: " .. tostring(err))
			RuntimeProfiler.Count("Client/Replay/Assets/PrewarmContentFailed")
		end
		RuntimeProfiler.End("Client/Replay/Assets/PrewarmContent", token)
	end)
end

function ReplayAssets.GetEmitModule()
	if replayEmitModule then
		return replayEmitModule
	end

	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local moduleScript = packages and packages:FindFirstChild("EmitModule")
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		if not warnedMissingReplayEmitModule then
			warn("[ReplayClient] Missing ReplicatedStorage.Packages.EmitModule")
			warnedMissingReplayEmitModule = true
		end
		return nil
	end

	local ok, emitModule = pcall(require, moduleScript)
	if not ok then
		if not warnedMissingReplayEmitModule then
			warn("[ReplayClient] Failed to require EmitModule: " .. tostring(emitModule))
			warnedMissingReplayEmitModule = true
		end
		return nil
	end

	replayEmitModule = emitModule
	return replayEmitModule
end

function ReplayAssets.EnsureEmitModuleInitialized(emitModule): boolean
	if replayEmitModuleInitialized then
		return true
	end
	if not emitModule then
		return false
	end

	local initFn = emitModule.init or emitModule.Init
	if type(initFn) == "function" then
		local ok, err = pcall(function()
			initFn()
		end)
		if not ok then
			warn("[ReplayClient] Failed to initialize EmitModule: " .. tostring(err))
			return false
		end
	end

	replayEmitModuleInitialized = true
	return true
end

function ReplayAssets.GetByPath(root: Instance, path): Instance?
	if typeof(path) ~= "table" then
		return nil
	end

	local current: Instance? = root
	for _, name in ipairs(path) do
		if typeof(name) ~= "string" or name == "" or not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

function ReplayAssets.NormalizeLookupName(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end
	return string.lower((string.gsub(value, "[^%w]", "")))
end

function ReplayAssets.BuildLookupNames(...): { string }
	local names = {}
	for _, value in ipairs({ ... }) do
		if typeof(value) == "string" and value ~= "" then
			table.insert(names, value)
		end
	end
	return names
end

function ReplayAssets.FindChildLoose(parent: Instance?, name: any): Instance?
	if not (parent and typeof(name) == "string" and name ~= "") then
		return nil
	end

	local exact = parent:FindFirstChild(name)
	if exact then
		return exact
	end

	local normalized = ReplayAssets.NormalizeLookupName(name)
	if normalized == "" then
		return nil
	end
	for _, child in ipairs(parent:GetChildren()) do
		if ReplayAssets.NormalizeLookupName(child.Name) == normalized then
			return child
		end
	end
	return nil
end

function ReplayAssets.IsReplayTemplate(instance: Instance?): boolean
	return instance ~= nil and (instance:IsA("Model") or instance:IsA("BasePart"))
end

function ReplayAssets.FindReplayTemplateInFolder(folder: Instance?, names): Instance?
	if not folder then
		return nil
	end

	for _, name in ipairs(names or {}) do
		local child = ReplayAssets.FindChildLoose(folder, name)
		if ReplayAssets.IsReplayTemplate(child) then
			return child
		end
		if child then
			local defaultChild = ReplayAssets.FindChildLoose(child, "Default")
			if ReplayAssets.IsReplayTemplate(defaultChild) then
				return defaultChild
			end
			for _, nestedName in ipairs(names or {}) do
				local nestedChild = ReplayAssets.FindChildLoose(child, nestedName)
				if ReplayAssets.IsReplayTemplate(nestedChild) then
					return nestedChild
				end
			end
		end
	end

	return nil
end

function ReplayAssets.GetTemplateFromCategory(root: Instance?, categoryName: string, names): Instance?
	local category = root and root:FindFirstChild(categoryName)
	return ReplayAssets.FindReplayTemplateInFolder(category, names)
end

function ReplayAssets.PlayOptionalEventSound(soundName: string, parent: Instance?)
	if typeof(soundName) ~= "string" or soundName == "" then
		return
	end

	SoundUtil.Play(soundName, parent)
end

return ReplayAssets
