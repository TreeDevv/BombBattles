local Loader = {}

type PredicateFn = (module: ModuleScript) -> boolean

function Loader.LoadChildren(parent: Instance, predicate: PredicateFn?): { [string]: any }
	local modules = {}
	for _, child in parent:GetChildren() do
		if child:IsA("ModuleScript") then
			if predicate and not predicate(child) then
				continue
			end

			modules[child.Name] = require(child)
		end
	end

	return modules
end

function Loader.LoadDescendants(parent: Instance, predicate: PredicateFn?): { [string]: any }
	local modules = {}
	for _, descendant in parent:GetDescendants() do
		if descendant:IsA("ModuleScript") then
			if predicate and not predicate(descendant) then
				continue
			end

			modules[descendant.Name] = require(descendant)
		end
	end

	return modules
end

function Loader.MatchesName(matchName: string): (module: ModuleScript) -> boolean
	return function(moduleScript: ModuleScript): boolean
		return moduleScript.Name:match(matchName) ~= nil
	end
end

function Loader.SpawnAll(loadedModules: { [string]: any }, methodName: string, ...)
	local args = { ... }
	for name, mod in pairs(loadedModules) do
		if typeof(mod) ~= "table" then
			continue
		end

		local method = mod[methodName]
		if type(method) == "function" then
			task.spawn(function()
				debug.setmemorycategory(name)
				method(mod, table.unpack(args))
			end)
		end
	end
end

function Loader.ConnectFunctions(loadedModules: { [string]: any }, event: RBXScriptSignal, methodName: string)
	event:Connect(function(...)
		Loader.SpawnAll(loadedModules, methodName, ...)
	end)
end

return Loader
