local GroupService = game:GetService("GroupService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GroupRewardConfig = require(ReplicatedStorage.Shared.Config.GroupRewardConfig)

local GroupRewardController = {}

local activeRequestId: string? = nil
local rewardClaimed = false
local visualRoot: Instance? = nil
local groupChest: Instance? = nil
local friendChest: Instance? = nil
local warnedMissingVisuals = false
local transparencyTweens: { [BasePart]: Tween } = {}
local originalTransparency: { [BasePart]: number } = {}

local visualConfig = GroupRewardConfig.Visuals or {}
local visualTweenInfo = TweenInfo.new(
	math.max(0.05, tonumber(visualConfig.TweenSeconds) or 0.18),
	Enum.EasingStyle.Quint,
	Enum.EasingDirection.Out
)

local function waitForRemoteEvent(remoteName: string): RemoteEvent?
	local remotesFolder = ReplicatedStorage:WaitForChild(GroupRewardConfig.RemotesFolderName, 10)
	if not remotesFolder then
		return nil
	end

	local remote = remotesFolder:WaitForChild(remoteName, 10)
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end
	return nil
end

local function waitForRemoteFunction(remoteName: string): RemoteFunction?
	local remotesFolder = ReplicatedStorage:WaitForChild(GroupRewardConfig.RemotesFolderName, 10)
	if not remotesFolder then
		return nil
	end

	local remote = remotesFolder:WaitForChild(remoteName, 10)
	if remote and remote:IsA("RemoteFunction") then
		return remote
	end
	return nil
end

local function waitForPath(root: Instance, pathParts: { string }, timeoutSeconds: number): Instance?
	local deadline = os.clock() + timeoutSeconds
	local current: Instance? = root

	for _, childName in ipairs(pathParts) do
		if not current then
			return nil
		end

		local remaining = math.max(0.05, deadline - os.clock())
		current = current:WaitForChild(childName, remaining)
		if not current then
			return nil
		end
	end

	return current
end

local function getVisualRoot(): Instance?
	local rootPath = visualConfig.RootPath
	if typeof(rootPath) ~= "table" then
		rootPath = { "Lobby", "GroupRewards" }
	end

	if visualRoot and visualRoot.Parent then
		return visualRoot
	end

	visualRoot = waitForPath(Workspace, rootPath, 10)
	return visualRoot
end

local function resolveVisuals(): (Instance?, Instance?)
	local root = getVisualRoot()
	if not root then
		return nil, nil
	end

	if groupChest and groupChest.Parent == root and friendChest and friendChest.Parent == root then
		return groupChest, friendChest
	end

	local groupChestName = tostring(visualConfig.GroupChestName or "GroupRewards")
	local friendChestName = tostring(visualConfig.FriendChestName or "FriendRewards")
	groupChest = root:WaitForChild(groupChestName, 10)
	friendChest = root:WaitForChild(friendChestName, 10)

	return groupChest, friendChest
end

local function rememberTransparency(part: BasePart): number
	local existing = originalTransparency[part]
	if existing ~= nil then
		return existing
	end

	originalTransparency[part] = part.Transparency
	return part.Transparency
end

local function getVisibleTransparency(part: BasePart, chestRoot: Instance): number
	local authoredTransparency = rememberTransparency(part)
	if part == chestRoot and authoredTransparency >= 0.99 then
		return math.clamp(tonumber(visualConfig.VisibleTransparency) or 0, 0, 1)
	end

	return authoredTransparency
end

local function tweenPartTransparency(part: BasePart, targetTransparency: number)
	local existingTween = transparencyTweens[part]
	if existingTween then
		existingTween:Cancel()
	end

	local tween = TweenService:Create(part, visualTweenInfo, {
		Transparency = targetTransparency,
	})
	transparencyTweens[part] = tween
	tween.Completed:Once(function()
		if transparencyTweens[part] == tween then
			transparencyTweens[part] = nil
		end
	end)
	tween:Play()
end

local function applyDescendantVisibility(instance: Instance, chestRoot: Instance, visible: boolean)
	if instance:IsA("BasePart") then
		local targetTransparency = math.clamp(tonumber(visualConfig.HiddenTransparency) or 1, 0, 1)
		if visible then
			targetTransparency = getVisibleTransparency(instance, chestRoot)
		end
		tweenPartTransparency(instance, targetTransparency)
	elseif instance:IsA("LayerCollector") then
		instance.Enabled = visible
	elseif instance:IsA("Light") then
		instance.Enabled = visible
	end
end

local function setChestVisible(chest: Instance?, visible: boolean)
	if not chest then
		return
	end

	applyDescendantVisibility(chest, chest, visible)
	for _, descendant in ipairs(chest:GetDescendants()) do
		applyDescendantVisibility(descendant, chest, visible)
	end
end

local function applyRewardStage()
	local groupVisual, friendVisual = resolveVisuals()
	if not (groupVisual and friendVisual) then
		if not warnedMissingVisuals then
			warn("[GroupRewardController] Missing Workspace.Lobby.GroupRewards chest visuals.")
			warnedMissingVisuals = true
		end
		return
	end

	warnedMissingVisuals = false
	setChestVisible(groupVisual, not rewardClaimed)
	setChestVisible(friendVisual, rewardClaimed)
end

local function applyStatePayload(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	rewardClaimed = payload.rewardClaimed == true
	applyRewardStage()
end

local function enumName(value: any): string
	if typeof(value) == "EnumItem" then
		return value.Name
	end
	return tostring(value or "")
end

local function firePromptResult(resultRemote: RemoteEvent, requestId: string, ok: boolean, status: string, errorMessage: string?)
	local payload = {}
	payload.requestId = requestId
	payload.ok = ok
	payload.status = status
	if errorMessage then
		payload.error = errorMessage
	end
	resultRemote:FireServer(payload)
end

local function handlePrompt(payload: any, resultRemote: RemoteEvent)
	if typeof(payload) ~= "table" then
		return
	end

	local requestId = payload.requestId
	local groupId = tonumber(payload.groupId)
	if typeof(requestId) ~= "string" or requestId == "" or not groupId or groupId <= 0 then
		return
	end

	if activeRequestId then
		firePromptResult(resultRemote, requestId, false, "Busy", nil)
		return
	end

	activeRequestId = requestId
	local ok, result = pcall(function()
		return GroupService:PromptJoinAsync(groupId)
	end)
	activeRequestId = nil

	if ok then
		firePromptResult(resultRemote, requestId, true, enumName(result), nil)
	else
		firePromptResult(resultRemote, requestId, false, "PromptFailed", tostring(result))
	end
end

local function requestState(stateRequestRemote: RemoteFunction)
	local ok, payload = pcall(function()
		return stateRequestRemote:InvokeServer()
	end)
	if ok then
		applyStatePayload(payload)
	else
		warn("[GroupRewardController] Failed to request group reward state: " .. tostring(payload))
	end
end

function GroupRewardController:OnStart()
	local promptRemote = waitForRemoteEvent(GroupRewardConfig.PromptRemoteName)
	local resultRemote = waitForRemoteEvent(GroupRewardConfig.PromptResultRemoteName)
	local stateRemote = waitForRemoteEvent(GroupRewardConfig.StateRemoteName)
	local stateRequestRemote = waitForRemoteFunction(GroupRewardConfig.StateRequestRemoteName)

	task.spawn(applyRewardStage)

	if promptRemote and resultRemote then
		promptRemote.OnClientEvent:Connect(function(payload)
			handlePrompt(payload, resultRemote)
		end)
	end

	if stateRemote then
		stateRemote.OnClientEvent:Connect(function(payload)
			applyStatePayload(payload)
		end)
	end

	if stateRequestRemote then
		task.spawn(function()
			requestState(stateRequestRemote)
		end)
	end
end

return GroupRewardController
