local ServerScriptService = game:GetService("ServerScriptService")

local RoundWorldTextRuntime = {}

local worldTextService = nil

local function getService()
	if worldTextService then
		return worldTextService
	end

	local services = ServerScriptService:FindFirstChild("Services")
	local worldTextModule = services and services:FindFirstChild("WorldTextService")
	if not (worldTextModule and worldTextModule:IsA("ModuleScript")) then
		return nil
	end

	local ok, service = pcall(require, worldTextModule)
	if ok and typeof(service) == "table" then
		worldTextService = service
		return worldTextService
	end

	return nil
end

function RoundWorldTextRuntime.Send(methodName: string, ...)
	local service = getService()
	if not service then
		return
	end

	local method = service[methodName]
	if type(method) ~= "function" then
		return
	end

	pcall(function(...)
		method(...)
	end, ...)
end

return table.freeze(RoundWorldTextRuntime)
