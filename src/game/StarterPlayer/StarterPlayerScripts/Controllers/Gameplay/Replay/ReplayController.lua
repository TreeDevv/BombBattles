local ReplayController = {}

local replayClientModule = script.Parent:WaitForChild("ReplayClient", 10)
local ReplayClient = nil

if replayClientModule and replayClientModule:IsA("ModuleScript") then
	local ok, loadedReplayClient = pcall(require, replayClientModule)
	if ok then
		ReplayClient = loadedReplayClient
	else
		warn("[ReplayController] Failed to require ReplayClient: " .. tostring(loadedReplayClient))
	end
else
	warn("[ReplayController] Missing ReplayClient")
end

function ReplayController:OnStart()
	if ReplayClient and type(ReplayClient.OnStart) == "function" then
		ReplayClient:OnStart()
	end
end

return ReplayController
