local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EmitService = {}

local emitModule = nil
local initialized = false
local warned = {}

local DEFAULT_WARN_PREFIX = "[EmitService]"

local function getWarnPrefix(warnPrefix: string?): string
	return if typeof(warnPrefix) == "string" and warnPrefix ~= "" then warnPrefix else DEFAULT_WARN_PREFIX
end

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end

	warned[key] = true
	warn(message)
end

function EmitService.GetModule(warnPrefix: string?, waitSeconds: number?): any?
	if emitModule then
		return emitModule
	end

	local prefix = getWarnPrefix(warnPrefix)
	local packages = ReplicatedStorage:FindFirstChild("Packages")
	if not packages and typeof(waitSeconds) == "number" and waitSeconds > 0 then
		packages = ReplicatedStorage:WaitForChild("Packages", waitSeconds)
	end

	local moduleScript = packages and packages:FindFirstChild("EmitModule")
	if not moduleScript and typeof(waitSeconds) == "number" and waitSeconds > 0 then
		moduleScript = packages and packages:WaitForChild("EmitModule", waitSeconds)
	end

	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		warnOnce("missing", prefix .. " Missing ReplicatedStorage.Packages.EmitModule")
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	if not ok then
		warnOnce("require", prefix .. " Failed to require EmitModule: " .. tostring(result))
		return nil
	end

	emitModule = result
	return emitModule
end

function EmitService.EnsureInitialized(warnPrefix: string?, waitSeconds: number?): boolean
	if initialized then
		return true
	end

	local module = EmitService.GetModule(warnPrefix, waitSeconds)
	if not module then
		return false
	end

	local initFn = module.init or module.Init
	if type(initFn) == "function" then
		local ok, err = pcall(function()
			initFn()
		end)
		if not ok then
			warn(getWarnPrefix(warnPrefix) .. " Failed to initialize EmitModule: " .. tostring(err))
			return false
		end
	end

	initialized = true
	return true
end

function EmitService.EmitWithResult(instance: Instance, warnPrefix: string?, waitSeconds: number?): (boolean, any?)
	local module = EmitService.GetModule(warnPrefix, waitSeconds)
	if not (module and EmitService.EnsureInitialized(warnPrefix, waitSeconds) and type(module.emit) == "function") then
		return false, nil
	end

	local ok, result = pcall(function()
		return module.emit(instance)
	end)
	if not ok then
		warn(getWarnPrefix(warnPrefix) .. " EmitModule emit failed for " .. instance:GetFullName() .. ": " .. tostring(result))
		return false, result
	end

	return true, result
end

function EmitService.Emit(instance: Instance, warnPrefix: string?, waitSeconds: number?): boolean
	local ok = EmitService.EmitWithResult(instance, warnPrefix, waitSeconds)
	return ok
end

return table.freeze(EmitService)
