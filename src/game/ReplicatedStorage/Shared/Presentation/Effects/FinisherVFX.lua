local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FinisherConfig = require(ReplicatedStorage.Shared.Config.FinisherConfig)

local FinisherVFX = {}

local CLONE_LIFETIME_SECONDS = 8

local emitModule = nil
local emitModuleInitialized = false
local warnedMissingEmitModule = false

local function getEmitModule()
	if emitModule then
		return emitModule
	end

	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local moduleScript = packages and packages:FindFirstChild("EmitModule")
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		if not warnedMissingEmitModule then
			warn("[FinisherVFX] Missing ReplicatedStorage.Packages.EmitModule")
			warnedMissingEmitModule = true
		end
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	if not ok then
		if not warnedMissingEmitModule then
			warn("[FinisherVFX] Failed to require EmitModule: " .. tostring(result))
			warnedMissingEmitModule = true
		end
		return nil
	end

	emitModule = result
	return emitModule
end

local function ensureEmitModuleInitialized(module): boolean
	if emitModuleInitialized then
		return true
	end
	if not module then
		return false
	end

	local initFn = module.init or module.Init
	if type(initFn) == "function" then
		local ok, err = pcall(function()
			initFn()
		end)
		if not ok then
			warn("[FinisherVFX] Failed to initialize EmitModule: " .. tostring(err))
			return false
		end
	end

	emitModuleInitialized = true
	return true
end

local function prepBasePart(part: BasePart, hideAnchor: boolean)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	if hideAnchor then
		part.Transparency = 1
	end
end

local function placeClone(clone: Instance, cframe: CFrame)
	if clone:IsA("BasePart") then
		clone.CFrame = cframe
		prepBasePart(clone, true)
		return
	end

	if clone:IsA("Model") then
		clone:PivotTo(cframe)
		for _, descendant in ipairs(clone:GetDescendants()) do
			if descendant:IsA("BasePart") then
				prepBasePart(descendant, false)
			end
		end
		return
	end

	local part = clone:FindFirstChildWhichIsA("BasePart", true)
	if part then
		part.CFrame = cframe
	end
end

function FinisherVFX.PlayAt(finisherId: any, position: Vector3, options): boolean
	if typeof(position) ~= "Vector3" then
		return false
	end

	local source = FinisherConfig.GetAsset(finisherId)
	if not source then
		return false
	end

	local module = getEmitModule()
	if not (module and ensureEmitModuleInitialized(module) and type(module.emit) == "function") then
		return false
	end

	local parent = if typeof(options) == "table" and typeof(options.parent) == "Instance"
		then options.parent
		else workspace.Terrain
	local clone = source:Clone()
	clone.Name = "Finisher_" .. FinisherConfig.NormalizeFinisherId(finisherId)
	placeClone(clone, CFrame.new(position))
	clone.Parent = parent

	local ok, err = pcall(function()
		module.emit(clone)
	end)
	if not ok then
		warn("[FinisherVFX] EmitModule emit failed for " .. tostring(finisherId) .. ": " .. tostring(err))
		clone:Destroy()
		return false
	end

	Debris:AddItem(clone, CLONE_LIFETIME_SECONDS)
	return true
end

return table.freeze(FinisherVFX)
