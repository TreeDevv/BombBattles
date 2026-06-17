local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ExpressivePromptsController = {}

ExpressivePromptsController._initialized = false

local function getExpressivePrompts()
	local packages = ReplicatedStorage:WaitForChild("Packages", 10)
	if not packages then
		warn("[ExpressivePromptsController] Missing ReplicatedStorage.Packages")
		return nil
	end

	local packageModule = packages:WaitForChild("expressive-prompts", 10)
	if not (packageModule and packageModule:IsA("ModuleScript")) then
		warn("[ExpressivePromptsController] Missing expressive-prompts package")
		return nil
	end

	local ok, expressivePrompts = pcall(require, packageModule)
	if not ok then
		warn("[ExpressivePromptsController] Failed to require expressive-prompts: " .. tostring(expressivePrompts))
		return nil
	end

	return expressivePrompts
end

function ExpressivePromptsController:OnStart()
	if self._initialized then
		return
	end

	local expressivePrompts = getExpressivePrompts()
	if not expressivePrompts then
		return
	end

	local init = expressivePrompts.Init
	if type(init) ~= "function" then
		warn("[ExpressivePromptsController] expressive-prompts does not expose Init")
		return
	end

	self._initialized = true
	local ok, err = pcall(init)
	if not ok then
		self._initialized = false
		warn("[ExpressivePromptsController] Init failed: " .. tostring(err))
	end
end

return ExpressivePromptsController
