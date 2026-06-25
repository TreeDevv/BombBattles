local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local REMOTES_FOLDER_NAME = "Remotes"
local KILL_FEED_REMOTE_NAME = "KillFeed"
local HUD_NAME = "HUD"
local FEED_NAME = "Kills"
local TEMPLATE_NAME = "Template"
local MAX_ENTRIES = 4
local HOLD_SECONDS = 3.2
local ENTER_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SETTLE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EXIT_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local ENTER_OFFSET = UDim2.fromOffset(0, 18)
local EXIT_OFFSET = UDim2.fromOffset(72, -6)
local POP_SCALE = 1.1
local HIDDEN_SCALE = 0.82

type Fader = {
	instance: Instance,
	property: string,
	value: number,
}

type Entry = {
	root: GuiObject,
	faders: { Fader },
	tweens: { Tween },
	fading: boolean,
	motionRoot: GuiObject?,
	motionPosition: UDim2?,
	scale: UIScale?,
	baseScale: number,
}

local LocalKillFeedController = {}

LocalKillFeedController._connections = {} :: { RBXScriptConnection }
LocalKillFeedController._entries = {} :: { Entry }
LocalKillFeedController._fadingEntries = {} :: { [GuiObject]: Entry }
LocalKillFeedController._feed = nil :: GuiObject?
LocalKillFeedController._template = nil :: GuiObject?
LocalKillFeedController._fadeLayer = nil :: Frame?
LocalKillFeedController._nextLayoutOrder = 0
LocalKillFeedController._remoteBindSerial = 0
LocalKillFeedController._bindQueued = false

local KILLER_LABEL_NAMES = table.freeze({
	LeftPlayer = true,
	Killer = true,
	KillerName = true,
	KillerPlayer = true,
})

local VICTIM_LABEL_NAMES = table.freeze({
	RightPlayer = true,
	Victim = true,
	VictimName = true,
	VictimPlayer = true,
})

local SUMMARY_LABEL_NAMES = table.freeze({
	Label = true,
	Text = true,
	Title = true,
	Message = true,
	Kill = true,
})

local KILLER_IMAGE_NAMES = table.freeze({
	KillerIcon = true,
	KillerAvatar = true,
	KillerHeadshot = true,
})

local VICTIM_IMAGE_NAMES = table.freeze({
	VictimIcon = true,
	VictimAvatar = true,
	VictimHeadshot = true,
})

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function getPayloadString(payload, primaryKey: string, fallbackKey: string): string
	local primary = payload[primaryKey]
	if typeof(primary) == "string" and primary ~= "" then
		return primary
	end

	local fallback = payload[fallbackKey]
	if typeof(fallback) == "string" and fallback ~= "" then
		return fallback
	end

	return "Player"
end

local function getSummaryText(payload): string
	local killerName = getPayloadString(payload, "killerDisplayName", "killerName")
	local victimName = getPayloadString(payload, "victimDisplayName", "victimName")
	return string.format("%s eliminated %s", killerName, victimName)
end

local function addFader(faders: { Fader }, instance: Instance, property: string)
	table.insert(faders, {
		instance = instance,
		property = property,
		value = (instance :: any)[property],
	})
end

local function getFaderTransparency(fader: Fader, alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	return fader.value + (1 - fader.value) * alpha
end

local function collectFaders(root: GuiObject): { Fader }
	local faders = {}

	local function visit(instance: Instance)
		if instance:IsA("GuiObject") then
			addFader(faders, instance, "BackgroundTransparency")
		end
		if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
			addFader(faders, instance, "TextTransparency")
			addFader(faders, instance, "TextStrokeTransparency")
		end
		if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
			addFader(faders, instance, "ImageTransparency")
		end
		if instance:IsA("UIStroke") then
			addFader(faders, instance, "Transparency")
		end
	end

	visit(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		visit(descendant)
	end

	return faders
end

local function offsetUDim2(value: UDim2, offset: UDim2): UDim2
	return UDim2.new(
		value.X.Scale + offset.X.Scale,
		value.X.Offset + offset.X.Offset,
		value.Y.Scale + offset.Y.Scale,
		value.Y.Offset + offset.Y.Offset
	)
end

local function getMotionRoot(root: GuiObject): GuiObject
	local inner = root:FindFirstChild("Inner")
	if inner and inner:IsA("GuiObject") then
		return inner
	end

	return root
end

local function getOrCreateScale(root: GuiObject): (UIScale, number)
	local scale = root:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "LocalKillFeedScale"
		scale.Parent = root
	end

	return scale, scale.Scale
end

local function disableEmbeddedScripts(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BaseScript") then
			descendant.Disabled = true
		end
	end
end

local function createFadeLayer(hud: ScreenGui): Frame
	local existing = hud:FindFirstChild("LocalKillFeedFadeLayer")
	if existing then
		existing:Destroy()
	end

	local fadeLayer = Instance.new("Frame")
	fadeLayer.Name = "LocalKillFeedFadeLayer"
	fadeLayer.BackgroundTransparency = 1
	fadeLayer.BorderSizePixel = 0
	fadeLayer.ClipsDescendants = false
	fadeLayer.Size = UDim2.fromScale(1, 1)
	fadeLayer.Position = UDim2.fromScale(0, 0)
	fadeLayer.ZIndex = 100
	fadeLayer.Parent = hud
	return fadeLayer
end

local function setAvatarImage(image: ImageLabel | ImageButton, userId: any)
	if typeof(userId) ~= "number" or userId <= 0 then
		return
	end

	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and typeof(content) == "string" and image.Parent then
			image.Image = content
		end
	end)
end

local function configureEntryText(root: GuiObject, payload)
	local killerName = getPayloadString(payload, "killerDisplayName", "killerName")
	local victimName = getPayloadString(payload, "victimDisplayName", "victimName")
	local wroteSpecificLabel = false
	local wroteSummaryLabel = false

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
			if KILLER_LABEL_NAMES[descendant.Name] then
				descendant.Text = killerName
				wroteSpecificLabel = true
			elseif VICTIM_LABEL_NAMES[descendant.Name] then
				descendant.Text = victimName
				wroteSpecificLabel = true
			elseif not wroteSummaryLabel and SUMMARY_LABEL_NAMES[descendant.Name] then
				descendant.Text = getSummaryText(payload)
				wroteSummaryLabel = true
			end
		elseif descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			if KILLER_IMAGE_NAMES[descendant.Name] then
				setAvatarImage(descendant, payload.killerUserId)
			elseif VICTIM_IMAGE_NAMES[descendant.Name] then
				setAvatarImage(descendant, payload.victimUserId)
			end
		end
	end

	if wroteSpecificLabel or wroteSummaryLabel then
		return
	end

	local firstLabel = root:FindFirstChildWhichIsA("TextLabel", true)
	if firstLabel then
		firstLabel.Text = getSummaryText(payload)
	end
end

function LocalKillFeedController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function LocalKillFeedController:_trackEntryTween(entry: Entry, tween: Tween)
	table.insert(entry.tweens, tween)
	tween:Play()
	return tween
end

function LocalKillFeedController:_cancelEntryTweens(entry: Entry)
	local tweens = entry.tweens
	entry.tweens = {}
	for _, tween in ipairs(tweens) do
		tween:Cancel()
	end
end

function LocalKillFeedController:_setEntryTransparency(entry: Entry, alpha: number)
	for _, fader in ipairs(entry.faders) do
		(fader.instance :: any)[fader.property] = getFaderTransparency(fader, alpha)
	end
end

function LocalKillFeedController:_tweenEntryTransparency(entry: Entry, alpha: number, tweenInfo: TweenInfo)
	for _, fader in ipairs(entry.faders) do
		if fader.instance.Parent then
			local goal = {}
			goal[fader.property] = getFaderTransparency(fader, alpha)
			self:_trackEntryTween(entry, TweenService:Create(fader.instance, tweenInfo, goal))
		end
	end
end

function LocalKillFeedController:_destroyEntry(entry: Entry)
	self:_cancelEntryTweens(entry)
	self._fadingEntries[entry.root] = nil

	local activeIndex = table.find(self._entries, entry)
	if activeIndex then
		table.remove(self._entries, activeIndex)
	end

	if entry.root.Parent then
		entry.root:Destroy()
	end
end

function LocalKillFeedController:_clearEntries(animate: boolean?)
	if animate then
		for _, entry in ipairs(table.clone(self._entries)) do
			self:_startExit(entry)
		end
		return
	end

	for _, entry in ipairs(table.clone(self._entries)) do
		self:_destroyEntry(entry)
	end
	table.clear(self._entries)

	local fadingEntries = {}
	for _, entry in pairs(self._fadingEntries) do
		table.insert(fadingEntries, entry)
	end
	for _, entry in ipairs(fadingEntries) do
		self:_destroyEntry(entry)
	end
	table.clear(self._fadingEntries)
end

function LocalKillFeedController:_startExit(entry: Entry)
	if entry.fading then
		return
	end

	entry.fading = true
	self:_cancelEntryTweens(entry)

	local activeIndex = table.find(self._entries, entry)
	if activeIndex then
		table.remove(self._entries, activeIndex)
	end
	self._fadingEntries[entry.root] = entry

	local root = entry.root
	if not root.Parent then
		self:_destroyEntry(entry)
		return
	end

	if entry.motionRoot and entry.motionPosition and entry.motionRoot.Parent then
		entry.motionRoot.Position = entry.motionPosition
	end
	if entry.scale and entry.scale.Parent then
		entry.scale.Scale = entry.baseScale
	end

	local fadeLayer = self._fadeLayer
	local absolutePosition = root.AbsolutePosition
	local absoluteSize = root.AbsoluteSize
	if fadeLayer and absoluteSize.X > 0 and absoluteSize.Y > 0 then
		root.Parent = fadeLayer
		root.AnchorPoint = Vector2.new(0, 0)
		root.Size = UDim2.fromOffset(absoluteSize.X, absoluteSize.Y)
		root.Position = UDim2.fromOffset(absolutePosition.X - fadeLayer.AbsolutePosition.X, absolutePosition.Y - fadeLayer.AbsolutePosition.Y)
	end

	self:_tweenEntryTransparency(entry, 1, EXIT_TWEEN)

	local exitTarget = offsetUDim2(root.Position, EXIT_OFFSET)
	local exitTween = TweenService:Create(root, EXIT_TWEEN, {
		Position = exitTarget,
	})
	self:_trackEntryTween(entry, exitTween)
	exitTween.Completed:Once(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed then
			self:_destroyEntry(entry)
		end
	end)
end

function LocalKillFeedController:_shouldAcceptPayload(payload): boolean
	if typeof(payload) ~= "table" then
		return false
	end

	if payload.killerUserId ~= LocalPlayer.UserId then
		return false
	end

	local killerTeam = payload.killerTeam
	local victimTeam = payload.victimTeam
	if typeof(killerTeam) ~= "string" or typeof(victimTeam) ~= "string" or killerTeam == victimTeam then
		return false
	end

	local payloadRoundId = payload.roundId
	local currentRoundId = RoundController:Get("roundId")
	if typeof(payloadRoundId) == "number" and typeof(currentRoundId) == "number" and payloadRoundId ~= currentRoundId then
		return false
	end

	return true
end

function LocalKillFeedController:_addEntry(payload)
	if not self:_shouldAcceptPayload(payload) then
		return
	end

	local feed = self._feed
	local template = self._template
	if not (feed and feed.Parent and template) then
		self:_bindCurrentHud()
		feed = self._feed
		template = self._template
	end
	if not (feed and feed.Parent and template) then
		return
	end

	while #self._entries >= MAX_ENTRIES do
		self:_startExit(self._entries[1])
	end

	self._nextLayoutOrder += 1
	local root = template:Clone()
	root.Name = string.format("LocalKill_%06d", self._nextLayoutOrder)
	root.LayoutOrder = self._nextLayoutOrder
	root.Visible = true
	disableEmbeddedScripts(root)
	configureEntryText(root, payload)

	local motionRoot = getMotionRoot(root)
	local motionPosition = motionRoot.Position
	local scale, baseScale = getOrCreateScale(root)
	local entry = {
		root = root,
		faders = collectFaders(root),
		tweens = {},
		fading = false,
		motionRoot = motionRoot,
		motionPosition = motionPosition,
		scale = scale,
		baseScale = baseScale,
	}

	self:_setEntryTransparency(entry, 1)
	motionRoot.Position = offsetUDim2(motionPosition, ENTER_OFFSET)
	scale.Scale = baseScale * HIDDEN_SCALE

	table.insert(self._entries, entry)
	feed.Visible = true
	root.Parent = feed

	self:_tweenEntryTransparency(entry, 0, ENTER_TWEEN)
	self:_trackEntryTween(entry, TweenService:Create(motionRoot, ENTER_TWEEN, {
		Position = motionPosition,
	}))
	local popTween = self:_trackEntryTween(entry, TweenService:Create(scale, ENTER_TWEEN, {
		Scale = baseScale * POP_SCALE,
	}))
	popTween.Completed:Once(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed and root.Parent and not entry.fading then
			self:_trackEntryTween(entry, TweenService:Create(scale, SETTLE_TWEEN, {
				Scale = baseScale,
			}))
		end
	end)

	task.delay(HOLD_SECONDS, function()
		if table.find(self._entries, entry) then
			self:_startExit(entry)
		end
	end)
end

function LocalKillFeedController:_clearHudBinding()
	self:_clearEntries()
	if self._fadeLayer then
		self._fadeLayer:Destroy()
	end
	if self._template then
		self._template:Destroy()
	end

	self._feed = nil
	self._template = nil
	self._fadeLayer = nil
end

function LocalKillFeedController:_bindHud(hud: Instance?)
	if not (hud and hud:IsA("ScreenGui")) then
		self:_clearHudBinding()
		return
	end

	local feed = hud:FindFirstChild(FEED_NAME)
	if not (feed and feed:IsA("GuiObject")) then
		self:_clearHudBinding()
		return
	end
	if self._feed == feed and self._template then
		return
	end

	self:_clearHudBinding()

	local listLayout = feed:FindFirstChildWhichIsA("UIListLayout")
	if listLayout then
		listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	end

	local template = feed:FindFirstChild(TEMPLATE_NAME)
	if not (template and template:IsA("GuiObject")) then
		return
	end

	local prototype = template:Clone()
	prototype.Visible = false
	prototype.Parent = nil
	disableEmbeddedScripts(prototype)
	template:Destroy()

	self._feed = feed
	self._template = prototype
	self._fadeLayer = createFadeLayer(hud)
end

function LocalKillFeedController:_scheduleBindCurrentHud()
	if self._bindQueued then
		return
	end

	self._bindQueued = true
	task.defer(function()
		self._bindQueued = false
		self:_bindCurrentHud()
	end)
end

function LocalKillFeedController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild(HUD_NAME))
end

function LocalKillFeedController:_disconnectAll()
	disconnectAll(self._connections)
	self._remoteBindSerial += 1
	self._bindQueued = false
	self:_clearHudBinding()
end

function LocalKillFeedController:_bindRemote()
	self._remoteBindSerial += 1
	local serial = self._remoteBindSerial

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
		if serial ~= self._remoteBindSerial or not remotes then
			return
		end

		local remote = remotes:WaitForChild(KILL_FEED_REMOTE_NAME, 10)
		if serial ~= self._remoteBindSerial or not (remote and remote:IsA("RemoteEvent")) then
			return
		end

		self:_trackConnection(remote.OnClientEvent:Connect(function(payload)
			self:_addEntry(payload)
		end))
	end)
end

function LocalKillFeedController:OnStart()
	self:_disconnectAll()

	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == HUD_NAME then
			self:_scheduleBindCurrentHud()
		end
	end))
	self:_trackConnection(PlayerGui.ChildRemoved:Connect(function(child)
		if child == self._feed or child == self._fadeLayer or child.Name == HUD_NAME then
			self:_scheduleBindCurrentHud()
		end
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "roundId" then
			self:_clearEntries(true)
		end
	end))

	self:_bindCurrentHud()
	self:_bindRemote()
end

return LocalKillFeedController
