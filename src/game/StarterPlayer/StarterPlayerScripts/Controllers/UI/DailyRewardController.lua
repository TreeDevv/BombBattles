local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DailyRewardConfig = require(ReplicatedStorage.Shared.Config.DailyRewardConfig)

local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = DailyRewardConfig.FrameName
local RUNTIME_CARD_ATTRIBUTE = "DailyRewardRuntimeCard"
local FRAME_OPEN_RETRY_SECONDS = 0.1
local FRAME_OPEN_MAX_ATTEMPTS = 20

type DayPayload = {
	day: number,
	displayText: string,
	milestone: boolean?,
	iconImage: string?,
}

type StatePayload = {
	claimedDays: { [string]: boolean },
	nextDay: number,
	claimableDay: number,
	canClaim: boolean,
	completed: boolean,
	days: { DayPayload },
}

local DailyRewardController = {}

DailyRewardController._connections = {} :: { RBXScriptConnection }
DailyRewardController._frameConnections = {} :: { RBXScriptConnection }
DailyRewardController._cardConnections = {} :: { RBXScriptConnection }
DailyRewardController._screenGuiConnections = {} :: { RBXScriptConnection }
DailyRewardController._frame = nil :: GuiObject?
DailyRewardController._scroller = nil :: ScrollingFrame?
DailyRewardController._claimedTemplate = nil :: GuiObject?
DailyRewardController._canClaimTemplate = nil :: GuiObject?
DailyRewardController._lockedTemplate = nil :: GuiObject?
DailyRewardController._milestoneTemplate = nil :: GuiObject?
DailyRewardController._tweenScriptTemplate = nil :: LocalScript?
DailyRewardController._requestRemote = nil :: RemoteFunction?
DailyRewardController._stateRemote = nil :: RemoteEvent?
DailyRewardController._state = nil :: StatePayload?
DailyRewardController._localZone = nil
DailyRewardController._localZoneWatchConnection = nil :: RBXScriptConnection?
DailyRewardController._rebindQueued = false
DailyRewardController._warnedMissingFrame = false
DailyRewardController._claimPending = false

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

local function waitForRemoteFunction(remoteName: string): RemoteFunction?
	local remotes = ReplicatedStorage:WaitForChild(DailyRewardConfig.RemotesFolderName, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteFunction") then remote else nil
end

local function waitForRemoteEvent(remoteName: string): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(DailyRewardConfig.RemotesFolderName, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function findButton(parent: Instance?, name: string): GuiButton?
	local child = parent and parent:FindFirstChild(name, true)
	return if child and child:IsA("GuiButton") then child else nil
end

local function findImageLabel(parent: Instance?, name: string): ImageLabel?
	local child = parent and parent:FindFirstChild(name, true)
	return if child and child:IsA("ImageLabel") then child else nil
end

local function findTemplate(scroller: ScrollingFrame, name: string): GuiObject?
	local templatesFolder = scroller:FindFirstChild("Templates")
	local child = templatesFolder and templatesFolder:FindFirstChild(name) or scroller:FindFirstChild(name)
	return if child and child:IsA("GuiObject") then child else nil
end

local function getZonePart(): BasePart?
	for _, pathParts in ipairs(DailyRewardConfig.ZonePaths) do
		local current: Instance? = workspace
		for _, childName in ipairs(pathParts) do
			current = current and current:FindFirstChild(childName) or nil
			if not current then
				break
			end
		end
		if current and current:IsA("BasePart") then
			return current
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

	warn("[DailyRewardController] ZonePlus failed to load: " .. tostring(result))
	return nil
end

local function setButtonEnabled(button: GuiButton?, enabled: boolean)
	if not button then
		return
	end

	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
end

local function setNamedGuiVisible(root: Instance, name: string, visible: boolean)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name and descendant:IsA("GuiObject") then
			descendant.Visible = visible
		end
	end
end

local function getDirectTextLabels(root: Instance): { TextLabel }
	local labels = {}
	for _, child in ipairs(root:GetChildren()) do
		if child:IsA("TextLabel") then
			table.insert(labels, child)
		end
	end
	return labels
end

local function getNormalLabels(root: Instance): (TextLabel?, TextLabel?)
	local dayLabel = nil
	local rewardLabel = nil
	for _, label in ipairs(getDirectTextLabels(root)) do
		if string.match(label.Text, "^%s*Day%s+%d+") or label.Position.Y.Scale < 0.35 then
			dayLabel = label
		else
			rewardLabel = label
		end
	end
	return dayLabel, rewardLabel
end

local function getMilestoneLabels(root: Instance): (TextLabel?, TextLabel?, TextLabel?)
	local dayLabel = nil
	local descriptionLabel = nil
	local rewardLabel = nil
	for _, label in ipairs(getDirectTextLabels(root)) do
		if string.match(label.Text, "^%s*Day%s+%d+") or label.Position.Y.Scale < 0.4 and label.Position.X.Scale < 0.6 then
			dayLabel = label
		elseif label.Text == "???" or label.Position.X.Scale > 0.55 then
			rewardLabel = label
		else
			descriptionLabel = label
		end
	end
	return dayLabel, descriptionLabel, rewardLabel
end

local function getClaimStatus(state: StatePayload?, dayNumber: number): string
	if not state then
		return "locked"
	end

	if typeof(state.claimedDays) == "table" and state.claimedDays[tostring(dayNumber)] == true then
		return "claimed"
	end
	if state.canClaim == true and tonumber(state.claimableDay) == dayNumber then
		return "claimable"
	end
	return "locked"
end

function DailyRewardController:_invoke(request: any)
	local remote = self._requestRemote
	if not remote then
		return nil
	end

	local ok, response = pcall(function()
		return remote:InvokeServer(request)
	end)
	if not ok then
		warn("[DailyRewardController] Request failed: " .. tostring(response))
		return nil
	end
	return response
end

function DailyRewardController:_claim()
	if self._claimPending then
		return
	end

	self._claimPending = true
	task.spawn(function()
		local response = self:_invoke({
			action = DailyRewardConfig.Actions.Claim,
		})
		self._claimPending = false
		if typeof(response) == "table" and typeof(response.state) == "table" then
			self:_setState(response.state)
		end
	end)
end

function DailyRewardController:_requestState()
	local response = self:_invoke({
		action = DailyRewardConfig.Actions.GetState,
	})
	if typeof(response) == "table" and typeof(response.state) == "table" then
		self:_setState(response.state)
	end
end

function DailyRewardController:_clearCards()
	disconnectAll(self._cardConnections)

	local scroller = self._scroller
	if not scroller then
		return
	end

	for _, child in ipairs(scroller:GetChildren()) do
		if child:GetAttribute(RUNTIME_CARD_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
end

function DailyRewardController:_applyTweenScript(card: Instance)
	local template = self._tweenScriptTemplate
	if not template or card:FindFirstChild(template.Name) then
		return
	end

	local clone = template:Clone()
	clone.Enabled = true
	clone.Parent = card
end

function DailyRewardController:_configureCommonCard(card: GuiObject, day: DayPayload, status: string)
	card.Name = ("Day%d"):format(day.day)
	card.LayoutOrder = day.day
	card.Visible = true
	card:SetAttribute(RUNTIME_CARD_ATTRIBUTE, true)

	local icon = findImageLabel(card, "RewardIcon") or findImageLabel(card, "Icon")
	if icon and typeof(day.iconImage) == "string" and day.iconImage ~= "" then
		icon.Image = day.iconImage
	end

	setNamedGuiVisible(card, "ClaimedOverlay", status == "claimed")
	setNamedGuiVisible(card, "CanClaimOverlay", status == "claimable")

	local button = if card:IsA("GuiButton") then card else findButton(card, "ClaimButton")
	setButtonEnabled(button, status == "claimable")
	if button and status == "claimable" then
		track(self._cardConnections, button.Activated:Connect(function()
			self:_claim()
		end))
	end

	self:_applyTweenScript(card)
end

function DailyRewardController:_buildNormalCard(day: DayPayload, status: string)
	local template = if status == "claimed" then self._claimedTemplate elseif status == "claimable" then self._canClaimTemplate else self._lockedTemplate
	local scroller = self._scroller
	if not (template and scroller) then
		return
	end

	local card = template:Clone()
	local dayLabel, rewardLabel = getNormalLabels(card)
	if dayLabel then
		dayLabel.Text = ("Day %d"):format(day.day)
	end
	if rewardLabel then
		rewardLabel.Text = tostring(day.displayText or "")
	end

	self:_configureCommonCard(card, day, status)
	card.Parent = scroller
end

function DailyRewardController:_buildMilestoneCard(day: DayPayload, status: string)
	local template = self._milestoneTemplate
	local scroller = self._scroller
	if not (template and scroller) then
		self:_buildNormalCard(day, status)
		return
	end

	local card = template:Clone()
	local dayLabel, descriptionLabel, rewardLabel = getMilestoneLabels(card)
	if dayLabel then
		dayLabel.Text = ("Day %d"):format(day.day)
	end
	if descriptionLabel and string.find(string.lower(descriptionLabel.Text), "days in a row", 1, true) then
		descriptionLabel.Text = "Claim daily rewards to unlock this reward!"
	end
	if rewardLabel then
		rewardLabel.Text = tostring(day.displayText or "")
	end

	self:_configureCommonCard(card, day, status)
	card.Parent = scroller
end

function DailyRewardController:_render()
	local state = self._state
	if not (state and self._scroller) then
		return
	end

	self:_clearCards()
	self._scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y

	for _, day in ipairs(state.days or {}) do
		local dayNumber = math.floor(tonumber(day.day) or 0)
		if dayNumber > 0 then
			local status = getClaimStatus(state, dayNumber)
			if day.milestone == true then
				self:_buildMilestoneCard(day, status)
			else
				self:_buildNormalCard(day, status)
			end
		end
	end
end

function DailyRewardController:_setState(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local previous = self._state
	payload.claimedDays = if typeof(payload.claimedDays) == "table" then payload.claimedDays else (previous and previous.claimedDays) or {}
	payload.days = if typeof(payload.days) == "table" then payload.days else (previous and previous.days) or DailyRewardConfig.GetDaysPayload()
	payload.nextDay = math.max(1, math.floor(tonumber(payload.nextDay) or ((previous and previous.nextDay) or 1)))
	payload.claimableDay = math.max(0, math.floor(tonumber(payload.claimableDay) or 0))
	payload.canClaim = payload.canClaim == true
	payload.completed = payload.completed == true

	self._state = payload :: StatePayload
	self:_render()
end

function DailyRewardController:_ensureFrameRegistered(frame: GuiObject)
	if not CollectionService:HasTag(frame, FrameController.FrameTag) then
		CollectionService:AddTag(frame, FrameController.FrameTag)
	end

	if frame:GetAttribute(FrameController.ExclusiveAttribute) ~= true then
		frame:SetAttribute(FrameController.ExclusiveAttribute, true)
	end
end

function DailyRewardController:_bindFrame(frame: Instance?)
	disconnectAll(self._frameConnections)
	self:_clearCards()
	self._frame = nil
	self._scroller = nil
	self._claimedTemplate = nil
	self._canClaimTemplate = nil
	self._lockedTemplate = nil
	self._milestoneTemplate = nil
	self._tweenScriptTemplate = nil

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
		self._claimedTemplate = findTemplate(scroller, "ClaimedTemplate")
		self._canClaimTemplate = findTemplate(scroller, "CanClaimTemplate")
		self._lockedTemplate = findTemplate(scroller, "RareTemplate")
		self._milestoneTemplate = findTemplate(scroller, "MilestoneTemplate") or findTemplate(scroller, "Day7")

		for _, template in ipairs({
			self._claimedTemplate,
			self._canClaimTemplate,
			self._lockedTemplate,
			self._milestoneTemplate,
		}) do
			if template and template:IsA("GuiObject") then
				template.Visible = false
			end
		end

		local localScript = scroller:FindFirstChild("LocalScript")
		local tweens = localScript and localScript:FindFirstChild("Tweens")
		if tweens and tweens:IsA("LocalScript") then
			self._tweenScriptTemplate = tweens
		end
	end

	self:_render()
	self:_requestState()
end

function DailyRewardController:_scheduleRebind()
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

function DailyRewardController:_bindPlayerGui(root: Instance?)
	disconnectAll(self._screenGuiConnections)

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
		warn(("[DailyRewardController] Could not find %s under PlayerGui."):format(FRAME_NAME))
	end

	track(self._screenGuiConnections, root.DescendantAdded:Connect(function(descendant)
		if descendant.Name == FRAME_NAME
			or descendant.Name == "ClaimedTemplate"
			or descendant.Name == "CanClaimTemplate"
			or descendant.Name == "RareTemplate"
			or descendant.Name == "MilestoneTemplate"
		then
			self:_scheduleRebind()
		end
	end))
end

function DailyRewardController:_openFrameWithRetry(attempt: number?)
	local opened = FrameController:OpenWindow(FRAME_NAME, true)
	if opened or (attempt or 1) >= FRAME_OPEN_MAX_ATTEMPTS then
		return
	end

	task.delay(FRAME_OPEN_RETRY_SECONDS, function()
		self:_openFrameWithRetry((attempt or 1) + 1)
	end)
end

function DailyRewardController:_openMenu()
	self:_requestState()
	self:_openFrameWithRetry(1)
end

function DailyRewardController:_startLocalZone()
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
		warn("[DailyRewardController] ZonePlus failed to start: " .. tostring(result))
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

function DailyRewardController:_watchForLocalZone()
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

function DailyRewardController:_bindRemotes()
	self._requestRemote = waitForRemoteFunction(DailyRewardConfig.RequestRemoteName)
	self._stateRemote = waitForRemoteEvent(DailyRewardConfig.StateRemoteName)

	if self._stateRemote then
		track(self._connections, self._stateRemote.OnClientEvent:Connect(function(payload)
			self:_setState(payload)
		end))
	end
end

function DailyRewardController:OnStart()
	disconnectAll(self._connections)
	disconnectAll(self._frameConnections)
	disconnectAll(self._screenGuiConnections)
	if self._localZoneWatchConnection then
		self._localZoneWatchConnection:Disconnect()
		self._localZoneWatchConnection = nil
	end
	self:_clearCards()

	self:_bindPlayerGui(PlayerGui)
	self:_bindRemotes()
	self:_requestState()
	self:_watchForLocalZone()
end

return DailyRewardController
