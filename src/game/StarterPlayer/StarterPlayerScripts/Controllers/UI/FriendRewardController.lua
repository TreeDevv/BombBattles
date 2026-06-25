local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local FriendRewardConfig = require(ReplicatedStorage.Shared.Config.FriendRewardConfig)
local GameInvitePrompt = require(ReplicatedStorage.Shared.UI.GameInvitePrompt)

local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = FriendRewardConfig.FrameName
local RUNTIME_FRIEND_ROW_ATTRIBUTE = "FriendRewardRuntimeRow"
local PROGRESS_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local MAX_ONLINE_FRIENDS = 200

type FriendPayload = {
	userId: number,
	username: string,
	displayName: string,
	eligible: boolean,
	isOnline: boolean,
}

type TierPayload = {
	id: string,
	targetSeconds: number,
	displayName: string,
}

type StatePayload = {
	totalFriendSeconds: number,
	eligibleFriendCount: number,
	friendsLoaded: boolean,
	friends: { FriendPayload },
	claimedTiers: { [string]: boolean },
	tiers: { TierPayload },
	maxTargetSeconds: number,
}

type RewardCard = {
	button: ImageButton,
	tierId: string,
	targetSeconds: number,
	canClaimOverlay: GuiObject?,
	claimedOverlay: GuiObject?,
	connection: RBXScriptConnection?,
}

local FriendRewardController = {}

FriendRewardController._connections = {} :: { RBXScriptConnection }
FriendRewardController._frameConnections = {} :: { RBXScriptConnection }
FriendRewardController._rowConnections = {} :: { RBXScriptConnection }
FriendRewardController._frame = nil :: GuiObject?
FriendRewardController._scroller = nil :: ScrollingFrame?
FriendRewardController._friendTemplate = nil :: ImageButton?
FriendRewardController._progressSlider = nil :: UIGradient?
FriendRewardController._progressValue = nil :: NumberValue?
FriendRewardController._progressTween = nil :: Tween?
FriendRewardController._subtext = nil :: TextLabel?
FriendRewardController._rewardCards = {} :: { RewardCard }
FriendRewardController._state = nil :: StatePayload?
FriendRewardController._renderedFriendSignature = ""
FriendRewardController._requestRemote = nil :: RemoteFunction?
FriendRewardController._stateRemote = nil :: RemoteEvent?
FriendRewardController._openRemote = nil :: RemoteEvent?
FriendRewardController._rebindQueued = false
FriendRewardController._warnedMissingFrame = false
FriendRewardController._friends = {} :: { FriendPayload }
FriendRewardController._friendsLoaded = false
FriendRewardController._nextFriendLoadAt = 0
FriendRewardController._invitePendingByUserId = {} :: { [number]: boolean }

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

local function findTextLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findImageButton(parent: Instance?, name: string): ImageButton?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("ImageButton") then child else nil
end

local function findImageLabel(parent: Instance?, name: string): ImageLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("ImageLabel") then child else nil
end

local function findFrame(parent: Instance?, name: string): Frame?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("Frame") then child else nil
end

local function waitForRemoteEvent(remoteName: string): RemoteEvent?
	local remotesFolder = ReplicatedStorage:WaitForChild(FriendRewardConfig.RemotesFolderName, 10)
	if not remotesFolder then
		return nil
	end

	local remote = remotesFolder:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function waitForRemoteFunction(remoteName: string): RemoteFunction?
	local remotesFolder = ReplicatedStorage:WaitForChild(FriendRewardConfig.RemotesFolderName, 10)
	if not remotesFolder then
		return nil
	end

	local remote = remotesFolder:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteFunction") then remote else nil
end

local function formatTimer(seconds: number): string
	local wholeSeconds = math.max(0, math.floor(seconds + 0.5))
	local minutes = math.floor(wholeSeconds / 60)
	local remainingSeconds = wholeSeconds % 60
	return string.format("%02d:%02d", minutes, remainingSeconds)
end

local function setSliderProgress(slider: UIGradient?, ratio: number)
	if not slider then
		return
	end

	local clamped = math.clamp(ratio, 0, 1)
	if clamped <= 0 then
		slider.Transparency = NumberSequence.new(1)
		return
	end
	if clamped >= 1 then
		slider.Transparency = NumberSequence.new(0)
		return
	end

	local edge = math.clamp(clamped, 0.001, 0.999)
	local fadeEdge = math.clamp(edge + 0.002, 0.001, 1)
	slider.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(edge, 0),
		NumberSequenceKeypoint.new(fadeEdge, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function parseDurationSeconds(text: string): number?
	local numberText = string.match(string.lower(text), "(%d+)")
	local value = tonumber(numberText)
	if not value then
		return nil
	end

	if string.find(string.lower(text), "hour") then
		return value * 3600
	end
	return value * 60
end

local function getTierByTarget(state: StatePayload?, targetSeconds: number?): TierPayload?
	if not (state and targetSeconds) then
		return nil
	end

	for _, tier in ipairs(state.tiers or {}) do
		if math.abs((tonumber(tier.targetSeconds) or 0) - targetSeconds) <= 1 then
			return tier
		end
	end
	return nil
end

local function getTierByIndex(state: StatePayload?, index: number): TierPayload?
	if not state then
		return nil
	end
	return (state.tiers or {})[index]
end

local function setButtonEnabled(button: GuiButton?, enabled: boolean)
	if not button then
		return
	end

	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
end

local function cloneOverlay(template: GuiObject?, parent: Instance): GuiObject?
	if not template then
		return nil
	end

	local clone = template:Clone()
	clone.Visible = false
	clone.Parent = parent
	return clone
end

local function getFriendSortName(friend: FriendPayload): string
	return string.lower(tostring(friend.username or friend.displayName or friend.userId or ""))
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

local function loadOnlineFriends(): ({ [number]: boolean }, { [number]: FriendPayload })
	local onlineFriendIds = {}
	local onlineFriendsById = {}
	local ok, onlineFriends = pcall(function()
		return LocalPlayer:GetFriendsOnlineAsync(MAX_ONLINE_FRIENDS)
	end)
	if not ok then
		warn("[FriendRewardController] Failed to load online friends: " .. tostring(onlineFriends))
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
					eligible = false,
					isOnline = true,
				}
			end
		end
	end

	return onlineFriendIds, onlineFriendsById
end

local function getSortedFriends(friends: { FriendPayload }): { FriendPayload }
	local sortedFriends = table.clone(friends)
	table.sort(sortedFriends, function(left, right)
		local leftEligible = left.eligible == true
		local rightEligible = right.eligible == true
		if leftEligible ~= rightEligible then
			return leftEligible
		end

		local leftOnline = left.isOnline == true
		local rightOnline = right.isOnline == true
		if leftOnline ~= rightOnline then
			return leftOnline
		end

		local leftName = getFriendSortName(left)
		local rightName = getFriendSortName(right)
		if leftName == rightName then
			return (tonumber(left.userId) or 0) < (tonumber(right.userId) or 0)
		end
		return leftName < rightName
	end)
	return sortedFriends
end

function FriendRewardController:_loadFriends(): { FriendPayload }
	local now = os.clock()
	if self._friendsLoaded and now < self._nextFriendLoadAt then
		return self._friends
	end

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

	self._nextFriendLoadAt = now + math.max(5, tonumber(FriendRewardConfig.FriendListRetrySeconds) or 30)
	if not ok then
		warn("[FriendRewardController] Failed to load friends: " .. tostring(pages))
		local friends = {}
		for _, onlineFriend in pairs(onlineFriendsById) do
			table.insert(friends, onlineFriend)
		end
		table.sort(friends, function(left, right)
			local leftName = getFriendSortName(left)
			local rightName = getFriendSortName(right)
			if leftName == rightName then
				return left.userId < right.userId
			end
			return leftName < rightName
		end)
		self._friends = friends
		self._friendsLoaded = #friends > 0
		return self._friends
	end

	local friends = {}
	local seen = {}
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
				eligible = false,
				isOnline = onlineFriendIds[userId] == true,
			})
		end
	end

	for userId, onlineFriend in pairs(onlineFriendsById) do
		if not seen[userId] then
			table.insert(friends, onlineFriend)
		end
	end

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

	self._friends = friends
	self._friendsLoaded = true
	return self._friends
end

function FriendRewardController:_claimTier(tierId: string)
	local remote = self._requestRemote
	if not remote then
		return
	end

	task.spawn(function()
		local ok, response = pcall(function()
			return remote:InvokeServer({
				action = FriendRewardConfig.Actions.Claim,
				tierId = tierId,
			})
		end)
		if ok and typeof(response) == "table" and typeof(response.state) == "table" then
			self:_setState(response.state)
		elseif not ok then
			warn("[FriendRewardController] Claim request failed: " .. tostring(response))
		end
	end)
end

function FriendRewardController:_promptInvite(friend: FriendPayload)
	local userId = tonumber(friend.userId)
	if not userId or userId <= 0 then
		return
	end
	if self._invitePendingByUserId[userId] then
		return
	end
	self._invitePendingByUserId[userId] = true

	task.spawn(function()
		local okPrompt, status, detail = GameInvitePrompt.Prompt({
			player = LocalPlayer,
			inviteUserId = userId,
			promptMessage = FriendRewardConfig.InvitePromptMessage,
			shouldContinue = function()
				return self._invitePendingByUserId[userId] == true
			end,
		})
		self._invitePendingByUserId[userId] = nil

		if not okPrompt then
			if status == "CanSendFailed" then
				warn("[FriendRewardController] CanSendGameInviteAsync failed: " .. tostring(detail))
			elseif status == "PromptFailed" then
				warn("[FriendRewardController] Invite prompt failed: " .. tostring(detail))
			end
		end
	end)
end

function FriendRewardController:_clearFriendRows()
	disconnectAll(self._rowConnections)
	self._renderedFriendSignature = ""

	local scroller = self._scroller
	if not scroller then
		return
	end

	for _, child in ipairs(scroller:GetChildren()) do
		if child:GetAttribute(RUNTIME_FRIEND_ROW_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
end

function FriendRewardController:_buildFriendRows()
	local state = self._state
	local scroller = self._scroller
	local template = self._friendTemplate
	if not (state and scroller and template) then
		return
	end

	local sortedFriends = getSortedFriends(state.friends or {})
	local signatureParts = {}
	for index, friend in ipairs(sortedFriends) do
		table.insert(signatureParts, ("%d:%s:%s:%s:%d"):format(
			friend.userId,
			tostring(friend.eligible),
			tostring(friend.isOnline),
			getFriendSortName(friend),
			index
		))
	end
	local signature = table.concat(signatureParts, "|")
	if signature == self._renderedFriendSignature then
		return
	end

	self:_clearFriendRows()
	self._renderedFriendSignature = signature

	for index, friend in ipairs(sortedFriends) do
		local row = template:Clone()
		row.Name = ("Friend_%d"):format(friend.userId)
		row.LayoutOrder = index
		row.Visible = true
		row:SetAttribute(RUNTIME_FRIEND_ROW_ATTRIBUTE, true)
		row.Parent = scroller

		local usernameLabel = findTextLabel(row, "Username")
		if usernameLabel then
			usernameLabel.Text = "@" .. tostring(friend.username or friend.displayName or friend.userId)
		end

		local statusLabel = findTextLabel(row, "Status")
		if statusLabel then
			if friend.eligible then
				statusLabel.Text = "In-game"
				statusLabel.TextColor3 = Color3.fromRGB(38, 255, 0)
			elseif friend.isOnline then
				statusLabel.Text = "Online"
				statusLabel.TextColor3 = Color3.fromRGB(38, 255, 0)
			else
				statusLabel.Text = "Offline"
				statusLabel.TextColor3 = Color3.fromRGB(255, 112, 112)
			end
		end

		local icon = findImageLabel(row, "PlayerIcon")
		if icon then
			icon.Image = ("rbxthumb://type=AvatarHeadShot&id=%d&w=420&h=420"):format(friend.userId)
		end

		local inviteButton = findImageButton(row, "InviteButton")
		if inviteButton then
			inviteButton.Visible = not friend.eligible
			setButtonEnabled(inviteButton, not friend.eligible)
			if not friend.eligible then
				track(self._rowConnections, inviteButton.Activated:Connect(function()
					self:_promptInvite(friend)
				end))
			end
		end
	end
end

function FriendRewardController:_buildRewardCards()
	for _, card in ipairs(self._rewardCards) do
		if card.connection then
			card.connection:Disconnect()
		end
	end
	self._rewardCards = {}

	local frame = self._frame
	if not frame then
		return
	end

	local rewards = findImageLabel(frame, "Rewards")
	local holder = rewards and findFrame(rewards, "Holder")
	if not holder then
		return
	end

	local cards = {}
	local canClaimTemplate: GuiObject? = nil
	local claimedTemplate: GuiObject? = nil
	for childIndex, child in ipairs(holder:GetChildren()) do
		if child:IsA("ImageButton") and child.Name == "DivineTemplate" then
			table.insert(cards, {
				button = child,
				index = childIndex,
			})
			local canClaimOverlay = child:FindFirstChild("CanClaimOverlay")
			if canClaimOverlay and canClaimOverlay:IsA("GuiObject") then
				canClaimTemplate = canClaimOverlay
			end
			local claimedOverlay = child:FindFirstChild("ClaimedOverlay")
			if claimedOverlay and claimedOverlay:IsA("GuiObject") then
				claimedTemplate = claimedOverlay
			end
		end
	end

	table.sort(cards, function(left, right)
		local leftTime = findTextLabel(left.button, "Time")
		local rightTime = findTextLabel(right.button, "Time")
		local leftSeconds = parseDurationSeconds(leftTime and leftTime.Text or "") or math.huge
		local rightSeconds = parseDurationSeconds(rightTime and rightTime.Text or "") or math.huge
		if leftSeconds == rightSeconds then
			return left.index < right.index
		end
		return leftSeconds < rightSeconds
	end)

	for index, entry in ipairs(cards) do
		local button = entry.button
		local timeLabel = findTextLabel(button, "Time")
		local parsedSeconds = parseDurationSeconds(timeLabel and timeLabel.Text or "")
		local tier = getTierByTarget(self._state, parsedSeconds) or getTierByIndex(self._state, index)
		if tier then
			local canClaimOverlay = button:FindFirstChild("CanClaimOverlay")
			local claimedOverlay = button:FindFirstChild("ClaimedOverlay")
			local record: RewardCard = {
				button = button,
				tierId = tier.id,
				targetSeconds = tier.targetSeconds,
				canClaimOverlay = if canClaimOverlay and canClaimOverlay:IsA("GuiObject")
					then canClaimOverlay
					else cloneOverlay(canClaimTemplate, button),
				claimedOverlay = if claimedOverlay and claimedOverlay:IsA("GuiObject")
					then claimedOverlay
					else cloneOverlay(claimedTemplate, button),
				connection = nil,
			}
			record.connection = button.Activated:Connect(function()
				local state = self._state
				if not state then
					return
				end
				local claimed = typeof(state.claimedTiers) == "table" and state.claimedTiers[record.tierId] == true
				if not claimed and (tonumber(state.totalFriendSeconds) or 0) >= record.targetSeconds then
					self:_claimTier(record.tierId)
				end
			end)
			table.insert(self._rewardCards, record)
		end
	end
end

function FriendRewardController:_updateRewardCards()
	local state = self._state
	if not state then
		return
	end

	local totalSeconds = tonumber(state.totalFriendSeconds) or 0
	for _, card in ipairs(self._rewardCards) do
		local claimed = typeof(state.claimedTiers) == "table" and state.claimedTiers[card.tierId] == true
		local canClaim = not claimed and totalSeconds >= card.targetSeconds

		if card.canClaimOverlay then
			card.canClaimOverlay.Visible = canClaim
		end
		if card.claimedOverlay then
			card.claimedOverlay.Visible = claimed
		end
		setButtonEnabled(card.button, canClaim)
	end
end

function FriendRewardController:_updateProgress()
	local state = self._state
	if not state then
		return
	end

	local totalSeconds = tonumber(state.totalFriendSeconds) or 0
	local maxTargetSeconds = math.max(1, tonumber(state.maxTargetSeconds) or FriendRewardConfig.GetMaxTargetSeconds())
	local ratio = math.clamp(totalSeconds / maxTargetSeconds, 0, 1)

	if self._subtext then
		local eligibleCount = math.max(0, math.floor(tonumber(state.eligibleFriendCount) or 0))
		local friendText = if eligibleCount == 1 then "Eligible friend in-game" else "Eligible friends in-game"
		self._subtext.Text = ("%s - %d %s"):format(formatTimer(totalSeconds), eligibleCount, friendText)
	end

	if not self._progressValue then
		self._progressValue = Instance.new("NumberValue")
		self._progressValue.Value = 0
		track(self._frameConnections, self._progressValue.Changed:Connect(function(value)
			setSliderProgress(self._progressSlider, value)
		end))
	end

	if self._progressTween then
		self._progressTween:Cancel()
	end
	self._progressTween = TweenService:Create(self._progressValue, PROGRESS_TWEEN, { Value = ratio })
	self._progressTween:Play()
end

function FriendRewardController:_render()
	self:_buildFriendRows()
	self:_updateRewardCards()
	self:_updateProgress()
end

function FriendRewardController:_setState(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local previous = self._state
	if previous then
		if payload.friends == nil then
			payload.friends = previous.friends
		end
		if payload.tiers == nil then
			payload.tiers = previous.tiers
		end
		if payload.claimedTiers == nil then
			payload.claimedTiers = previous.claimedTiers
		end
		if payload.maxTargetSeconds == nil then
			payload.maxTargetSeconds = previous.maxTargetSeconds
		end
	end
	payload.friends = if typeof(payload.friends) == "table" then payload.friends else {}
	payload.tiers = if typeof(payload.tiers) == "table" then payload.tiers else FriendRewardConfig.Tiers
	payload.claimedTiers = if typeof(payload.claimedTiers) == "table" then payload.claimedTiers else {}

	self._state = payload :: StatePayload
	if #self._rewardCards == 0 then
		self:_buildRewardCards()
	end
	self:_render()
end

function FriendRewardController:_requestState()
	local remote = self._requestRemote
	if not remote then
		return
	end

	task.spawn(function()
		local friends = self:_loadFriends()
		local currentState = self._state
		self:_setState({
			totalFriendSeconds = currentState and currentState.totalFriendSeconds or 0,
			eligibleFriendCount = currentState and currentState.eligibleFriendCount or 0,
			friendsLoaded = true,
			friends = friends,
			claimedTiers = currentState and currentState.claimedTiers or {},
			tiers = currentState and currentState.tiers or FriendRewardConfig.Tiers,
			maxTargetSeconds = currentState and currentState.maxTargetSeconds or FriendRewardConfig.GetMaxTargetSeconds(),
		})

		local ok, response = pcall(function()
			return remote:InvokeServer({
				action = FriendRewardConfig.Actions.UpdateFriends,
				friends = friends,
			})
		end)
		if ok and typeof(response) == "table" and typeof(response.state) == "table" then
			self:_setState(response.state)
		elseif not ok then
			warn("[FriendRewardController] State request failed: " .. tostring(response))
		end
	end)
end

function FriendRewardController:_ensureFrameRegistered(frame: GuiObject)
	if not CollectionService:HasTag(frame, FrameController.FrameTag) then
		CollectionService:AddTag(frame, FrameController.FrameTag)
	end

	if frame:GetAttribute(FrameController.ExclusiveAttribute) ~= true then
		frame:SetAttribute(FrameController.ExclusiveAttribute, true)
	end
end

function FriendRewardController:_bindFrame(frame: Instance?)
	disconnectAll(self._frameConnections)
	self:_clearFriendRows()
	for _, card in ipairs(self._rewardCards) do
		if card.connection then
			card.connection:Disconnect()
		end
	end
	self._rewardCards = {}
	self._frame = nil
	self._scroller = nil
	self._friendTemplate = nil
	self._progressSlider = nil
	self._subtext = nil
	self._progressValue = nil
	self._progressTween = nil

	if not (frame and frame:IsA("GuiObject")) then
		return
	end

	self._frame = frame
	self:_ensureFrameRegistered(frame)

	local closeButton = findImageButton(frame, "CloseButton")
	track(self._frameConnections, closeButton and closeButton.Activated:Connect(function()
		FrameController:CloseFrame(FRAME_NAME)
	end))

	local daily = findImageLabel(frame, "Daily")
	local scroller = daily and daily:FindFirstChild("ScrollingFrame")
	if scroller and scroller:IsA("ScrollingFrame") then
		self._scroller = scroller
		scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
		local template = scroller:FindFirstChild("FriendTemplate")
		if template and template:IsA("ImageButton") then
			self._friendTemplate = template
			template.Visible = false
		end
	end

	local rewards = findImageLabel(frame, "Rewards")
	self._subtext = findTextLabel(rewards, "Subtext")
	local progressBar = findFrame(rewards, "ProgressBar")
	local slider = progressBar and progressBar:FindFirstChild("Slider")
	if slider and slider:IsA("UIGradient") then
		self._progressSlider = slider
		setSliderProgress(slider, 0)
	end

	self:_buildRewardCards()
	self:_render()
end

function FriendRewardController:_scheduleRebind()
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

function FriendRewardController:_bindPlayerGui(root: Instance?)
	if not root then
		self:_bindFrame(nil)
		return
	end

	local frame = root:FindFirstChild(FRAME_NAME, true)
	self:_bindFrame(frame)
	if frame then
		self._warnedMissingFrame = false
	elseif not self._warnedMissingFrame then
		self._warnedMissingFrame = true
		warn(("[FriendRewardController] Could not find %s under PlayerGui."):format(FRAME_NAME))
	end
end

function FriendRewardController:OnStart()
	self._requestRemote = waitForRemoteFunction(FriendRewardConfig.RequestRemoteName)
	self._stateRemote = waitForRemoteEvent(FriendRewardConfig.StateRemoteName)
	self._openRemote = waitForRemoteEvent(FriendRewardConfig.OpenRemoteName)

	self:_bindPlayerGui(PlayerGui)
	track(self._connections, PlayerGui.DescendantAdded:Connect(function(descendant)
		if descendant.Name == FRAME_NAME or descendant.Name == "FriendTemplate" then
			self:_scheduleRebind()
		end
	end))

	if self._stateRemote then
		track(self._connections, self._stateRemote.OnClientEvent:Connect(function(payload)
			self:_setState(payload)
		end))
	end

	if self._openRemote then
		track(self._connections, self._openRemote.OnClientEvent:Connect(function()
			self:_requestState()
			FrameController:OpenFrame(FRAME_NAME)
		end))
	end

	self:_requestState()
end

return FriendRewardController
