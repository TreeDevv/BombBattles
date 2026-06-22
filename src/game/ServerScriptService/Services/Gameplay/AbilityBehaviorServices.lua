local ServerScriptService = game:GetService("ServerScriptService")

local AbilityBehaviorServices = {}

local cache = {}

local function getServiceModule(name: string): ModuleScript?
	local services = ServerScriptService:FindFirstChild("Services")
	local serviceModule = services and services:FindFirstChild(name)
	return if serviceModule and serviceModule:IsA("ModuleScript") then serviceModule else nil
end

function AbilityBehaviorServices.GetService(name: string): any?
	local cached = cache[name]
	if cached then
		return cached
	end

	local serviceModule = getServiceModule(name)
	if not serviceModule then
		return nil
	end

	local ok, service = pcall(require, serviceModule)
	if not (ok and typeof(service) == "table") then
		return nil
	end

	cache[name] = service
	return service
end

function AbilityBehaviorServices.GetBombProjectileService(): any?
	return AbilityBehaviorServices.GetService("BombProjectileService")
end

function AbilityBehaviorServices.GetBombService(): any?
	return AbilityBehaviorServices.GetService("BombService")
end

return table.freeze(AbilityBehaviorServices)
