local GroupService = game:GetService("GroupService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GroupRewardConfig = require(ReplicatedStorage.Shared.Config.GroupRewardConfig)

local GroupRewardController = {}

local activeRequestId: string? = nil

local function waitForRemoteEvent(remoteName: string): RemoteEvent?
	local remotesFolder = ReplicatedStorage:WaitForChild(GroupRewardConfig.RemotesFolderName, 10)
	if not remotesFolder then
		return nil
	end

	local remote = remotesFolder:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function enumName(value: any): string
	if typeof(value) == "EnumItem" then
		return value.Name
	end
	return tostring(value or "")
end

function GroupRewardController:OnStart()
	local promptRemote = waitForRemoteEvent(GroupRewardConfig.PromptRemoteName)
	local resultRemote = waitForRemoteEvent(GroupRewardConfig.PromptResultRemoteName)
	if not (promptRemote and resultRemote) then
		return
	end

	promptRemote.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end

		local requestId = payload.requestId
		local groupId = tonumber(payload.groupId)
		if typeof(requestId) ~= "string" or requestId == "" or not groupId or groupId <= 0 then
			return
		end

		if activeRequestId then
			resultRemote:FireServer({
				requestId = requestId,
				ok = false,
				status = "Busy",
			})
			return
		end

		activeRequestId = requestId
		local ok, result = pcall(function()
			return GroupService:PromptJoinAsync(groupId)
		end)
		activeRequestId = nil

		resultRemote:FireServer({
			requestId = requestId,
			ok = ok,
			status = if ok then enumName(result) else "PromptFailed",
			error = if ok then nil else tostring(result),
		})
	end)
end

return GroupRewardController
