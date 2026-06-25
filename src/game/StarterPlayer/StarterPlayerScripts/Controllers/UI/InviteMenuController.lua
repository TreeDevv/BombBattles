local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InviteRewardConfig = require(ReplicatedStorage.Shared.Config.InviteRewardConfig)
local GameInvitePrompt = require(ReplicatedStorage.Shared.UI.GameInvitePrompt)

local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = InviteRewardConfig.FrameName
local RUNTIME_ROW_ATTRIBUTE = "InviteMenuControllerRuntimeRow"
local BUTTON_DEBOUNCE_SECONDS = 0.5
local FRAME_OPEN_RETRY_SECONDS = 0.1
local FRAME_OPEN_MAX_ATTEMPTS = 20
local MAX_ONLINE_FRIENDS = 200
local ONLINE_STATUS_COLOR = Color3.fromRGB(38, 255, 0)
local OFFLINE_STATUS_COLOR = Color3.fromRGB(255, 112, 112)

type FriendRecord = {
	userId: number,
	username: string,
	displayName: string,
	isOnline: boolean,
}

type RowRecord = {
	root: GuiObject,
	friend: FriendRecord,
	inviteButton: GuiButton?,
	status: TextLabel?,
	connections: { RBXScriptConnection },
	canInvite: boolean?,
	invitePending: boolean,
	lastPromptAt: number,
}

type OnlineFriendIds = { [number]: boolean }
type FriendLookup = { [number]: FriendRecord }

local InviteMenuController = {}

InviteMenuController._connections = {} :: { RBXScriptConnection }
InviteMenuController._frameConnections = {} :: { RBXScriptConnection }
InviteMenuController._rowConnections = {} :: { RBXScriptConnection }
InviteMenuController._screenGuiConnections = {} :: { RBXScriptConnection }
InviteMenuController._frame = nil :: GuiObject?
InviteMenuController._scroller = nil :: ScrollingFrame?
InviteMenuController._template = nil :: GuiObject?
InviteMenuController._rows = {} :: { RowRecord }
InviteMenuController._remote = nil :: RemoteFunction?
InviteMenuController._stateRemote = nil :: RemoteEvent?
InviteMenuController._openRemote = nil :: RemoteEvent?
InviteMenuController._localZone = nil
InviteMenuController._localZoneWatchConnection = nil :: RBXScriptConnection?
InviteMenuController._state = {
	chickenClaimed = false,
	claimedAtUnix = 0,
	rewardSkinId = InviteRewardConfig.RewardSkinId,
}
InviteMenuController._loading = false
InviteMenuController._rebindQueued = false
InviteMenuController._warnedMissingFrame = false

local function track(list: { RBXScriptConnection }, connection: RBXScriptConnection?)
	if connection then
		table.insert(list, connection)
	end
end

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in ipairs(list) do
		connection:Disconnect()
	end
	table.clear(list)
end

local function findButton(parent: Instance?, name: string): GuiButton?
	local child = parent and parent:FindFirstChild(name, true)
	return if child and child:IsA("GuiButton") then child else nil
end

local function findTextLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name, true)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findImageLabel(parent: Instance?, name: string): ImageLabel?
	local child = parent and parent:FindFirstChild(name, true)
	return if child and child:IsA("ImageLabel") then child else nil
end

local function waitForRemoteFunction(remoteName: string): RemoteFunction?
	local remotes = ReplicatedStorage:WaitForChild(InviteRewardConfig.RemotesFolderName, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteFunction") then remote else nil
end

local function waitForRemoteEvent(remoteName: string): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(InviteRewardConfig.RemotesFolderName, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function findByPath(root: Instance, pathParts: { string }): Instance?
	local current: Instance? = root
	for _, childName in ipairs(pathParts) do
		current = current and current:FindFirstChild(childName) or nil
		if not current then
			return nil
		end
	end
	return current
end

local function getZonePart(): BasePart?
	for _, pathParts in ipairs(InviteRewardConfig.ZonePaths) do
		local instance = findByPath(workspace, pathParts)
		if instance and instance:IsA("BasePart") then
			return instance
		end
	end
	return nil
end

local function getZonePlus()
	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local module = packages and packages:FindFirstChild("ZonePlus")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end

	local ok, result = pcall(require, module)
	if ok then
		return result
	end

	warn("[InviteMenuController] ZonePlus failed to load: " .. tostring(result))
	return nil
end

local function normalizeFriend(value: any): FriendRecord?
	if typeof(value) ~= "table" then
		return nil
	end

	local userId = math.floor(tonumber(value.userId) or 0)
	if userId <= 0 then
		return nil
	end

	local username = if typeof(value.username) == "string" and value.username ~= "" then value.username else "User" .. userId
	local displayName = if typeof(value.displayName) == "string" and value.displayName ~= "" then value.displayName else username
	return {
		userId = userId,
		username = username,
		displayName = displayName,
		isOnline = value.isOnline == true,
	}
end

local function normalizeUserId(value: any): number
	local userId = math.floor(tonumber(value) or 0)
	return if userId > 0 then userId else 0
end

local function iterFriendPages(pages)
	return coroutine.wrap(function()
		while true do
			for _, item in ipairs(pages:GetCurrentPage()) do
				coroutine.yield(item)
			end
			if pages.IsFinished then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
	end)
end

local function getFriendSortName(friend: FriendRecord): string
	return string.lower(tostring(friend.displayName or friend.username or friend.userId or ""))
end

local function sortFriends(friends: { FriendRecord })
	table.sort(friends, function(left, right)
		if left.isOnline ~= right.isOnline then
			return left.isOnline
		end

		local leftName = getFriendSortName(left)
		local rightName = getFriendSortName(right)
		if leftName == rightName then
			return left.userId < right.userId
		end
		return leftName < rightName
	end)
end

local function getOnlineFriendUserId(value: any): number
	if typeof(value) ~= "table" then
		return 0
	end

	local userId = normalizeUserId(value.VisitorId)
	if userId <= 0 then
		userId = normalizeUserId(value.UserId)
	end
	if userId <= 0 then
		userId = normalizeUserId(value.Id)
	end
	return userId
end

local function loadOnlineFriends(): (OnlineFriendIds, FriendLookup)
	local onlineFriendIds = {}
	local onlineFriendsById = {}
	local ok, onlineFriends = pcall(function()
		return LocalPlayer:GetFriendsOnlineAsync(MAX_ONLINE_FRIENDS)
	end)
	if not ok then
		warn("[InviteMenuController] Failed to load online friends: " .. tostring(onlineFriends))
		return onlineFriendIds, onlineFriendsById
	end
	if typeof(onlineFriends) ~= "table" then
		return onlineFriendIds, onlineFriendsById
	end

	for _, onlineFriend in ipairs(onlineFriends) do
		if typeof(onlineFriend) == "table" and onlineFriend.IsOnline ~= false then
			local userId = getOnlineFriendUserId(onlineFriend)
			if userId > 0 then
				onlineFriendIds[userId] = true
				local username = if typeof(onlineFriend.UserName) == "string" and onlineFriend.UserName ~= ""
					then onlineFriend.UserName
					else "User" .. userId
				local displayName = if typeof(onlineFriend.DisplayName) == "string" and onlineFriend.DisplayName ~= ""
					then onlineFriend.DisplayName
					else username
				onlineFriendsById[userId] = {
					userId = userId,
					username = username,
					displayName = displayName,
					isOnline = true,
				}
			end
		end
	end

	return onlineFriendIds, onlineFriendsById
end

local function loadFriends(): { FriendRecord }
	local onlineFriendIds = {}
	local onlineFriendsById = {}
	local ok = false
	local pages = nil
	local onlineDone = false
	local friendsDone = false
	local loadedEvent = Instance.new("BindableEvent")

	task.spawn(function()
		onlineFriendIds, onlineFriendsById = loadOnlineFriends()
		onlineDone = true
		loadedEvent:Fire()
	end)
	task.spawn(function()
		ok, pages = pcall(function()
			return Players:GetFriendsAsync(LocalPlayer.UserId)
		end)
		friendsDone = true
		loadedEvent:Fire()
	end)
	while not (onlineDone and friendsDone) do
		loadedEvent.Event:Wait()
	end
	loadedEvent:Destroy()

	local friends = {}
	local seen = {}

	if not ok then
		warn("[InviteMenuController] Failed to load friends: " .. tostring(pages))
		for _, onlineFriend in pairs(onlineFriendsById) do
			table.insert(friends, onlineFriend)
		end
		sortFriends(friends)
		return friends
	end

	for item in iterFriendPages(pages) do
		local userId = normalizeUserId(item.Id)
		if userId > 0 and not seen[userId] then
			seen[userId] = true
			local username = if typeof(item.Username) == "string" and item.Username ~= "" then item.Username else "User" .. userId
			local displayName = if typeof(item.DisplayName) == "string" and item.DisplayName ~= "" then item.DisplayName else username
			table.insert(friends, {
				userId = userId,
				username = username,
				displayName = displayName,
				isOnline = onlineFriendIds[userId] == true,
			})
		end
	end

	for userId, onlineFriend in pairs(onlineFriendsById) do
		if not seen[userId] then
			table.insert(friends, onlineFriend)
		end
	end

	sortFriends(friends)
	return friends
end

local function setLabel(label: TextLabel?, text: string)
	if label then
		label.Text = text
	end
end

local function setOverlay(root: Instance, overlayName: string, visible: boolean)
	local overlay = root:FindFirstChild(overlayName, true)
	if overlay and overlay:IsA("GuiObject") then
		overlay.Visible = visible
	end
end

local function setButtonEnabled(button: GuiButton?, enabled: boolean)
	if not button then
		return
	end

	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
	if button:IsA("ImageButton") then
		button.ImageTransparency = if enabled then 0 else 0.35
	end
end

local function disconnectRow(row: RowRecord)
	for _, connection in ipairs(row.connections) do
		connection:Disconnect()
	end
	table.clear(row.connections)
end

function InviteMenuController:_destroyRows()
	for _, row in ipairs(self._rows) do
		disconnectRow(row)
		if row.root.Parent then
			row.root:Destroy()
		end
	end
	table.clear(self._rows)
	disconnectAll(self._rowConnections)
end

function InviteMenuController:_ensureFrameRegistered(frame: GuiObject)
	if not CollectionService:HasTag(frame, FrameController.FrameTag) then
		CollectionService:AddTag(frame, FrameController.FrameTag)
	end

	if frame:GetAttribute(FrameController.ExclusiveAttribute) ~= true then
		frame:SetAttribute(FrameController.ExclusiveAttribute, true)
	end

end

function InviteMenuController:_applyRewardStateToRow(row: RowRecord)
	local claimed = self._state and self._state.chickenClaimed == true
	setOverlay(row.root, "ClaimedOverlay", claimed)
	setOverlay(row.root, "CanClaimOverlay", false)
end

function InviteMenuController:_applyRewardState()
	for _, row in ipairs(self._rows) do
		self:_applyRewardStateToRow(row)
	end
end

function InviteMenuController:_setRowStatus(row: RowRecord)
	local status = row.status
	if not status then
		return
	end

	if row.friend.isOnline then
		status.Text = "Online"
		status.TextColor3 = ONLINE_STATUS_COLOR
	else
		status.Text = "Offline"
		status.TextColor3 = OFFLINE_STATUS_COLOR
	end
end

function InviteMenuController:_promptInvite(row: RowRecord)
	if row.invitePending then
		return
	end

	local now = os.clock()
	if now - row.lastPromptAt < BUTTON_DEBOUNCE_SECONDS then
		return
	end
	row.lastPromptAt = now
	row.invitePending = true
	setButtonEnabled(row.inviteButton, false)

	task.spawn(function()
		local launchData: string? = HttpService:JSONEncode({
			source = InviteRewardConfig.LaunchDataSource,
			inviterId = LocalPlayer.UserId,
			inviteeId = row.friend.userId,
		})
		launchData = if #launchData <= InviteRewardConfig.MaxLaunchDataLength then launchData else nil

		local ok, status, detail = GameInvitePrompt.Prompt({
			player = LocalPlayer,
			inviteUserId = row.friend.userId,
			promptMessage = InviteRewardConfig.InvitePromptMessage,
			launchData = launchData,
			shouldContinue = function()
				return row.root.Parent ~= nil
			end,
		})

		row.invitePending = false
		setButtonEnabled(row.inviteButton, true)
		self:_setRowStatus(row)
		if not ok then
			if status == "CanSendFailed" then
				warn(("[InviteMenuController] CanSendGameInviteAsync failed for %d: %s"):format(
					row.friend.userId,
					tostring(detail)
				))
			elseif status == "PromptFailed" then
				warn(("[InviteMenuController] PromptGameInvite failed for %d: %s"):format(
					row.friend.userId,
					tostring(detail)
				))
			end
		end
	end)
end

function InviteMenuController:_buildRow(friend: FriendRecord, layoutOrder: number): RowRecord?
	local scroller = self._scroller
	local template = self._template
	if not (scroller and template) then
		return nil
	end

	local root = template:Clone()
	root.Name = "Friend_" .. tostring(friend.userId)
	root.LayoutOrder = layoutOrder
	root.Visible = true
	root:SetAttribute(RUNTIME_ROW_ATTRIBUTE, true)
	root.Parent = scroller

	setLabel(findTextLabel(root, "Username"), friend.displayName)

	local icon = findImageLabel(root, "PlayerIcon")
	if icon then
		icon.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(friend.userId)
	end

	local row: RowRecord = {
		root = root,
		friend = friend,
		inviteButton = findButton(root, "InviteButton"),
		status = findTextLabel(root, "Status"),
		connections = {},
		canInvite = nil,
		invitePending = false,
		lastPromptAt = 0,
	}

	self:_applyRewardStateToRow(row)
	self:_setRowStatus(row)
	setButtonEnabled(row.inviteButton, true)
	track(row.connections, row.inviteButton and row.inviteButton.Activated:Connect(function()
		self:_promptInvite(row)
	end))

	table.insert(self._rows, row)
	return row
end

function InviteMenuController:_renderFriends(friends: { any }?)
	self:_destroyRows()

	if self._template then
		self._template.Visible = false
	end
	if self._scroller then
		self._scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	end

	if typeof(friends) ~= "table" then
		return
	end

	local layoutOrder = 0
	for _, rawFriend in ipairs(friends) do
		local friend = normalizeFriend(rawFriend)
		if friend then
			layoutOrder += 1
			self:_buildRow(friend, layoutOrder)
		end
	end
end

function InviteMenuController:_invoke(request: any)
	local remote = self._remote
	if not remote then
		return nil
	end

	local ok, result = pcall(function()
		return remote:InvokeServer(request)
	end)
	if not ok then
		warn("[InviteMenuController] Invite reward request failed: " .. tostring(result))
		return nil
	end
	return result
end

function InviteMenuController:_requestFriends()
	if self._loading then
		return
	end

	self._loading = true
	task.spawn(function()
		task.spawn(function()
			local result = self:_invoke({
				action = InviteRewardConfig.Actions.GetState,
			})
			if typeof(result) == "table" and typeof(result.state) == "table" then
				self._state = result.state
				self:_applyRewardState()
			end
		end)

		local friends = loadFriends()
		self._loading = false
		self:_renderFriends(friends)
	end)
end

function InviteMenuController:_requestState()
	local result = self:_invoke({
		action = InviteRewardConfig.Actions.GetState,
	})
	if typeof(result) == "table" and typeof(result.state) == "table" then
		self._state = result.state
		self:_applyRewardState()
	end
end

function InviteMenuController:_openFrameWithRetry(attempt: number?)
	local opened = FrameController:OpenWindow(FRAME_NAME, true)
	if opened or (attempt or 1) >= FRAME_OPEN_MAX_ATTEMPTS then
		return
	end

	task.delay(FRAME_OPEN_RETRY_SECONDS, function()
		self:_openFrameWithRetry((attempt or 1) + 1)
	end)
end

function InviteMenuController:_openMenu()
	self:_requestFriends()
	self:_openFrameWithRetry(1)
end

function InviteMenuController:_startLocalZone()
	if self._localZone then
		return true
	end

	local zonePart = getZonePart()
	if not zonePart then
		return false
	end

	local zonePlus = getZonePlus()
	if not zonePlus then
		return false
	end

	local ok, result = pcall(function()
		return zonePlus.new(zonePart)
	end)
	if not ok then
		warn("[InviteMenuController] ZonePlus failed to start: " .. tostring(result))
		return false
	end

	self._localZone = result
	result.localPlayerEntered:Connect(function()
		self:_openMenu()
	end)

	task.defer(function()
		if self._localZone and self._localZone:findLocalPlayer() then
			self:_openMenu()
		end
	end)

	return true
end

function InviteMenuController:_watchForLocalZone()
	if self:_startLocalZone() or self._localZoneWatchConnection then
		return
	end

	self._localZoneWatchConnection = workspace.DescendantAdded:Connect(function(descendant)
		if self._localZone or not descendant:IsA("BasePart") then
			return
		end

		task.defer(function()
			if self:_startLocalZone() and self._localZoneWatchConnection then
				self._localZoneWatchConnection:Disconnect()
				self._localZoneWatchConnection = nil
			end
		end)
	end)
end

function InviteMenuController:_bindFrame(frame: Instance?)
	disconnectAll(self._frameConnections)
	self:_destroyRows()
	self._frame = nil
	self._scroller = nil
	self._template = nil

	if not (frame and frame:IsA("GuiObject")) then
		return
	end

	self._frame = frame
	self:_ensureFrameRegistered(frame)

	local closeButton = findButton(frame, "CloseButton")
	track(self._frameConnections, closeButton and closeButton.Activated:Connect(function()
		FrameController:CloseFrame(FRAME_NAME)
	end))

	local daily = frame:FindFirstChild("Daily")
	local scroller = daily and daily:FindFirstChild("ScrollingFrame")
	if scroller and scroller:IsA("ScrollingFrame") then
		self._scroller = scroller
		scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y

		local template = scroller:FindFirstChild("Template")
		if template and template:IsA("GuiObject") then
			self._template = template
			template.Visible = false
		end
	end

	self:_requestState()
end

function InviteMenuController:_warnMissingFrame()
	if self._warnedMissingFrame then
		return
	end
	self._warnedMissingFrame = true
	warn(("[InviteMenuController] Could not find %s under PlayerGui."):format(FRAME_NAME))
end

function InviteMenuController:_scheduleRebind()
	if self._rebindQueued then
		return
	end

	self._rebindQueued = true
	task.defer(function()
		self._rebindQueued = false
		if PlayerGui.Parent then
			self:_bindPlayerGui(PlayerGui)
		end
	end)
end

function InviteMenuController:_bindPlayerGui(root: Instance?)
	disconnectAll(self._screenGuiConnections)

	if not root then
		self:_bindFrame(nil)
		return
	end

	local frame = root:FindFirstChild(FRAME_NAME, true)
	self:_bindFrame(frame)
	if frame then
		self._warnedMissingFrame = false
	else
		self:_warnMissingFrame()
	end

	track(self._screenGuiConnections, root.DescendantAdded:Connect(function(descendant)
		if descendant.Name == FRAME_NAME or descendant.Name == "Template" or descendant.Name == "CloseButton" then
			self:_scheduleRebind()
		end
	end))
end

function InviteMenuController:_bindRemotes()
	self._remote = waitForRemoteFunction(InviteRewardConfig.RequestRemoteName)
	self._stateRemote = waitForRemoteEvent(InviteRewardConfig.StateRemoteName)
	self._openRemote = waitForRemoteEvent(InviteRewardConfig.OpenRemoteName)

	if self._stateRemote then
		track(self._connections, self._stateRemote.OnClientEvent:Connect(function(state)
			if typeof(state) == "table" then
				self._state = state
				self:_applyRewardState()
			end
		end))
	end

	if self._openRemote then
		track(self._connections, self._openRemote.OnClientEvent:Connect(function()
			self:_openMenu()
		end))
	end
end

function InviteMenuController:OnStart()
	disconnectAll(self._connections)
	disconnectAll(self._frameConnections)
	disconnectAll(self._screenGuiConnections)
	if self._localZoneWatchConnection then
		self._localZoneWatchConnection:Disconnect()
		self._localZoneWatchConnection = nil
	end
	self:_destroyRows()

	self:_bindPlayerGui(PlayerGui)
	self:_bindRemotes()
	self:_requestState()
	self:_watchForLocalZone()
end

return InviteMenuController
