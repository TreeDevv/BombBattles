local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlaytimeRewardConfig = require(ReplicatedStorage.Shared.Config.PlaytimeRewardConfig)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)

local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = PlaytimeRewardConfig.FrameName
local LOCKED_CIRCLE_COLOR = Color3.fromRGB(0, 0, 0)
local DEFAULT_COMPLETE_CIRCLE_COLOR = Color3.fromRGB(255, 236, 128)

type RewardPayload = {
	type: string,
	amount: number?,
	crateId: string?,
}

type TierPayload = {
	id: string,
	targetSeconds: number,
	displayName: string,
	reward: RewardPayload?,
}

type StatePayload = {
	sessionSeconds: number,
	claimedTiers: { [string]: boolean },
	tiers: { TierPayload },
	maxTargetSeconds: number,
}

type RewardCard = {
	button: ImageButton,
	claimButton: ImageButton?,
	label: TextLabel?,
	timeLabel: TextLabel?,
	icon: ImageLabel?,
	tierId: string,
	targetSeconds: number,
	connection: RBXScriptConnection?,
}

local PlaytimeRewardController = {}

PlaytimeRewardController.ClaimableCountChanged = Signal.new()
PlaytimeRewardController._connections = {} :: { RBXScriptConnection }
PlaytimeRewardController._frameConnections = {} :: { RBXScriptConnection }
PlaytimeRewardController._frame = nil :: GuiObject?
PlaytimeRewardController._timer = nil :: TextLabel?
PlaytimeRewardController._progressSlider = nil :: UIGradient?
PlaytimeRewardController._rewardCards = {} :: { RewardCard }
PlaytimeRewardController._circles = {} :: { Frame }
PlaytimeRewardController._circleCompleteColor = nil :: Color3?
PlaytimeRewardController._state = nil :: StatePayload?
PlaytimeRewardController._requestRemote = nil :: RemoteFunction?
PlaytimeRewardController._stateRemote = nil :: RemoteEvent?
PlaytimeRewardController._claimableCount = 0
PlaytimeRewardController._rebindQueued = false
PlaytimeRewardController._warnedMissingFrame = false

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
	local remotesFolder = ReplicatedStorage:WaitForChild(PlaytimeRewardConfig.RemotesFolderName, 10)
	if not remotesFolder then
		return nil
	end

	local remote = remotesFolder:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function waitForRemoteFunction(remoteName: string): RemoteFunction?
	local remotesFolder = ReplicatedStorage:WaitForChild(PlaytimeRewardConfig.RemotesFolderName, 10)
	if not remotesFolder then
		return nil
	end

	local remote = remotesFolder:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteFunction") then remote else nil
end

local function formatDuration(seconds: number): string
	local wholeSeconds = math.max(0, math.floor(seconds + 0.5))
	local minutes = math.floor(wholeSeconds / 60)
	local remainingSeconds = wholeSeconds % 60
	if minutes >= 60 then
		local hours = math.floor(minutes / 60)
		minutes = minutes % 60
		return string.format("%dh %02dm", hours, minutes)
	end
	return string.format("%02d:%02d", minutes, remainingSeconds)
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

local function setButtonEnabled(button: GuiButton?, enabled: boolean)
	if not button then
		return
	end

	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
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

local function sortByPosition(left: GuiObject, right: GuiObject): boolean
	local leftOrder = left.LayoutOrder
	local rightOrder = right.LayoutOrder
	if leftOrder ~= rightOrder then
		return leftOrder < rightOrder
	end
	if math.abs(left.Position.X.Scale - right.Position.X.Scale) > 0.0001 then
		return left.Position.X.Scale < right.Position.X.Scale
	end
	return left.Position.X.Offset < right.Position.X.Offset
end

local function getCircleIndex(circle: GuiObject): number?
	local indexText = string.match(circle.Name, "^Circle(%d+)$")
	local index = tonumber(indexText)
	if index and index >= 1 then
		return index
	end
	return nil
end

local function sortCircles(left: Frame, right: Frame): boolean
	local leftIndex = getCircleIndex(left)
	local rightIndex = getCircleIndex(right)
	if leftIndex and rightIndex and leftIndex ~= rightIndex then
		return leftIndex < rightIndex
	elseif leftIndex then
		return true
	elseif rightIndex then
		return false
	end
	return sortByPosition(left, right)
end

local function getClaimableCount(state: StatePayload?): number
	if not state then
		return 0
	end

	local elapsed = tonumber(state.sessionSeconds) or 0
	local claimedTiers = if typeof(state.claimedTiers) == "table" then state.claimedTiers else {}
	local count = 0
	for _, tier in ipairs(state.tiers or {}) do
		local targetSeconds = tonumber(tier.targetSeconds) or math.huge
		if claimedTiers[tier.id] ~= true and elapsed >= targetSeconds then
			count += 1
		end
	end
	return count
end

local function getHighestClaimedTierIndex(state: StatePayload?): number
	if not state then
		return 0
	end

	local claimedTiers = if typeof(state.claimedTiers) == "table" then state.claimedTiers else {}
	local highestIndex = 0
	for index, tier in ipairs(state.tiers or {}) do
		if claimedTiers[tier.id] == true then
			highestIndex = math.max(highestIndex, index)
		end
	end
	return highestIndex
end

function PlaytimeRewardController:_claimTier(tierId: string)
	local remote = self._requestRemote
	if not remote then
		return
	end

	task.spawn(function()
		local ok, response = pcall(function()
			return remote:InvokeServer({
				action = PlaytimeRewardConfig.Actions.Claim,
				tierId = tierId,
			})
		end)
		if ok and typeof(response) == "table" and typeof(response.state) == "table" then
			self:_setState(response.state)
		elseif not ok then
			warn("[PlaytimeRewardController] Claim request failed: " .. tostring(response))
		end
	end)
end

function PlaytimeRewardController:_buildRewardCards()
	for _, card in ipairs(self._rewardCards) do
		if card.connection then
			card.connection:Disconnect()
		end
	end
	self._rewardCards = {}

	local frame = self._frame
	local holder = frame and findFrame(frame, "Holder")
	if not holder then
		return
	end

	local buttons = {}
	for _, child in ipairs(holder:GetChildren()) do
		if child:IsA("ImageButton") and child.Name == "DivineTemplate" then
			table.insert(buttons, child)
		end
	end

	table.sort(buttons, sortByPosition)

	for index, button in ipairs(buttons) do
		local timeFrame = findFrame(button, "Time")
		local timeLabel = findTextLabel(timeFrame, "Label")
		local parsedSeconds = parseDurationSeconds(timeLabel and timeLabel.Text or "")
		local tier = getTierByTarget(self._state, parsedSeconds) or getTierByIndex(self._state, index)
		if tier then
			local claimButton = findImageButton(button, "ClaimButton")
			local record: RewardCard = {
				button = button,
				claimButton = claimButton,
				label = findTextLabel(button, "Label"),
				timeLabel = timeLabel,
				icon = findImageLabel(button, "Icon"),
				tierId = tier.id,
				targetSeconds = tier.targetSeconds,
				connection = nil,
			}

			if record.label then
				record.label.Text = tostring(tier.displayName or "")
			end

			local clickable = claimButton or button
			record.connection = clickable.Activated:Connect(function()
				local state = self._state
				if not state then
					return
				end
				local claimed = typeof(state.claimedTiers) == "table" and state.claimedTiers[record.tierId] == true
				local elapsed = tonumber(state.sessionSeconds) or 0
				if not claimed and elapsed >= record.targetSeconds then
					self:_claimTier(record.tierId)
				end
			end)
			table.insert(self._rewardCards, record)
		end
	end
end

function PlaytimeRewardController:_buildCircles()
	table.clear(self._circles)

	local frame = self._frame
	local progressBar = frame and findFrame(frame, "ProgressBar")
	if not progressBar then
		return
	end

	for _, child in ipairs(progressBar:GetChildren()) do
		if child:IsA("Frame") and (child.Name == "Circle" or getCircleIndex(child) ~= nil) then
			table.insert(self._circles, child)
		end
	end

	table.sort(self._circles, sortCircles)
	local firstCircle = self._circles[1]
	if firstCircle and firstCircle.BackgroundColor3 ~= LOCKED_CIRCLE_COLOR then
		self._circleCompleteColor = firstCircle.BackgroundColor3
	end
	self._circleCompleteColor = self._circleCompleteColor or DEFAULT_COMPLETE_CIRCLE_COLOR
end

function PlaytimeRewardController:_updateRewardCards()
	local state = self._state
	if not state then
		return
	end

	local elapsed = tonumber(state.sessionSeconds) or 0
	for _, card in ipairs(self._rewardCards) do
		local claimed = typeof(state.claimedTiers) == "table" and state.claimedTiers[card.tierId] == true
		local canClaim = not claimed and elapsed >= card.targetSeconds

		if card.claimButton then
			card.claimButton.Visible = canClaim
		end

		setButtonEnabled(card.claimButton, canClaim)
		setButtonEnabled(card.button, canClaim)
	end
end

function PlaytimeRewardController:_updateTimer()
	local state = self._state
	local timer = self._timer
	if not (state and timer) then
		return
	end

	local elapsed = tonumber(state.sessionSeconds) or 0
	local nextTier = nil
	local hasUnclaimedReady = false
	for _, tier in ipairs(state.tiers or {}) do
		local claimed = typeof(state.claimedTiers) == "table" and state.claimedTiers[tier.id] == true
		if not claimed then
			if elapsed >= tier.targetSeconds then
				hasUnclaimedReady = true
			elseif not nextTier or tier.targetSeconds < nextTier.targetSeconds then
				nextTier = tier
			end
		end
	end

	if hasUnclaimedReady then
		timer.Text = "Reward ready to claim"
	elseif nextTier then
		timer.Text = "Next reward in " .. formatDuration(nextTier.targetSeconds - elapsed)
	else
		timer.Text = "All rewards claimed"
	end
end

function PlaytimeRewardController:_updateProgress()
	local state = self._state

	local claimedIndex = getHighestClaimedTierIndex(state)
	local tierCount = math.max(1, if state then #(state.tiers or {}) else 0, #self._circles)
	local ratio = math.clamp(claimedIndex / tierCount, 0, 1)
	setSliderProgress(self._progressSlider, ratio)

	local completeColor = self._circleCompleteColor or DEFAULT_COMPLETE_CIRCLE_COLOR
	for index, circle in ipairs(self._circles) do
		circle.BackgroundColor3 = if index <= claimedIndex then completeColor else LOCKED_CIRCLE_COLOR
	end
end

function PlaytimeRewardController:_render()
	self:_updateRewardCards()
	self:_updateTimer()
	self:_updateProgress()
end

function PlaytimeRewardController:_syncClaimableCount()
	local nextCount = getClaimableCount(self._state)
	if nextCount == self._claimableCount then
		return
	end

	self._claimableCount = nextCount
	self.ClaimableCountChanged:Fire(nextCount)
end

function PlaytimeRewardController:_setState(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local previous = self._state
	if previous then
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

	payload.tiers = if typeof(payload.tiers) == "table" then payload.tiers else PlaytimeRewardConfig.Tiers
	payload.claimedTiers = if typeof(payload.claimedTiers) == "table" then payload.claimedTiers else {}
	payload.sessionSeconds = math.max(0, tonumber(payload.sessionSeconds) or 0)
	payload.maxTargetSeconds = math.max(1, tonumber(payload.maxTargetSeconds) or PlaytimeRewardConfig.GetMaxTargetSeconds())

	self._state = payload :: StatePayload
	self:_syncClaimableCount()
	if #self._rewardCards == 0 then
		self:_buildRewardCards()
	end
	self:_render()
end

function PlaytimeRewardController:GetClaimableCount(): number
	return self._claimableCount
end

function PlaytimeRewardController:_requestState()
	local remote = self._requestRemote
	if not remote then
		return
	end

	task.spawn(function()
		local ok, response = pcall(function()
			return remote:InvokeServer({
				action = PlaytimeRewardConfig.Actions.GetState,
			})
		end)
		if ok and typeof(response) == "table" and typeof(response.state) == "table" then
			self:_setState(response.state)
		elseif not ok then
			warn("[PlaytimeRewardController] State request failed: " .. tostring(response))
		end
	end)
end

function PlaytimeRewardController:_ensureFrameRegistered(frame: GuiObject)
	if not CollectionService:HasTag(frame, FrameController.FrameTag) then
		CollectionService:AddTag(frame, FrameController.FrameTag)
	end

	if frame:GetAttribute(FrameController.ExclusiveAttribute) ~= true then
		frame:SetAttribute(FrameController.ExclusiveAttribute, true)
	end
end

function PlaytimeRewardController:_bindFrame(frame: Instance?)
	disconnectAll(self._frameConnections)
	for _, card in ipairs(self._rewardCards) do
		if card.connection then
			card.connection:Disconnect()
		end
	end
	self._rewardCards = {}
	table.clear(self._circles)
	self._frame = nil
	self._timer = nil
	self._progressSlider = nil
	self._circleCompleteColor = nil

	if not (frame and frame:IsA("GuiObject")) then
		return
	end

	self._frame = frame
	self:_ensureFrameRegistered(frame)

	local closeButton = findImageButton(frame, "CloseButton")
	track(self._frameConnections, closeButton and closeButton.Activated:Connect(function()
		FrameController:CloseFrame(FRAME_NAME)
	end))

	self._timer = findTextLabel(frame, "Timer")

	local progressBar = findFrame(frame, "ProgressBar")
	local slider = progressBar and progressBar:FindFirstChild("Slider")
	if slider and slider:IsA("UIGradient") then
		self._progressSlider = slider
		setSliderProgress(slider, 0)
	end

	self:_buildCircles()
	self:_buildRewardCards()
	self:_render()
end

function PlaytimeRewardController:_scheduleRebind()
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

function PlaytimeRewardController:_bindPlayerGui(root: Instance?)
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
		warn(("[PlaytimeRewardController] Could not find %s under PlayerGui."):format(FRAME_NAME))
	end
end

function PlaytimeRewardController:OnStart()
	self._requestRemote = waitForRemoteFunction(PlaytimeRewardConfig.RequestRemoteName)
	self._stateRemote = waitForRemoteEvent(PlaytimeRewardConfig.StateRemoteName)

	self:_bindPlayerGui(PlayerGui)
	track(self._connections, PlayerGui.DescendantAdded:Connect(function(descendant)
		if
			descendant.Name == FRAME_NAME
			or descendant.Name == "DivineTemplate"
			or descendant.Name == "Circle"
			or string.match(descendant.Name, "^Circle%d+$") ~= nil
		then
			self:_scheduleRebind()
		end
	end))

	if self._stateRemote then
		track(self._connections, self._stateRemote.OnClientEvent:Connect(function(payload)
			self:_setState(payload)
		end))
	end

	self:_requestState()
end

return PlaytimeRewardController
