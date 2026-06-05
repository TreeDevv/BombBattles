local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ROUND_TEAM_ATTR = "RoundTeam"
local REMOTES_FOLDER_NAME = "Remotes"
local KILL_FEED_REMOTE_NAME = "KillFeed"
local MAX_ENTRIES = 5
local HOLD_SECONDS = 4
local ENTER_TWEEN = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local FADE_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESPAWNS_DISABLED_ENTER_TWEEN = TweenInfo.new(0.36, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local RESPAWNS_DISABLED_EXIT_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local ENTER_OFFSET = UDim2.fromOffset(16, 6)
local MIN_SLIDE_PIXELS = 18
local RESPAWNS_DISABLED_HIDE_PADDING = 24

local RED_TEAM_NAME = RoundConfig.Teams.Red.name
local BLUE_TEAM_NAME = RoundConfig.Teams.Blue.name

type Fader = {
	instance: Instance,
	property: string,
	value: number,
}

type Entry = {
	root: Frame,
	faders: { Fader },
	tweens: { Tween },
	fading: boolean,
	motionRoot: GuiObject?,
	motionPosition: UDim2?,
}

local KillFeedController = {}

KillFeedController._connections = {} :: { RBXScriptConnection }
KillFeedController._entries = {} :: { Entry }
KillFeedController._fadingEntries = {} :: { [Frame]: Entry }
KillFeedController._feed = nil :: Frame?
KillFeedController._template = nil :: Frame?
KillFeedController._fadeLayer = nil :: Frame?
KillFeedController._templateGradientRotation = 0
KillFeedController._nextLayoutOrder = 0
KillFeedController._remoteBindSerial = 0
KillFeedController._respawnsDisabledBanner = nil :: Frame?
KillFeedController._respawnsDisabledNativePosition = nil :: UDim2?
KillFeedController._respawnsDisabledHiddenPosition = nil :: UDim2?
KillFeedController._respawnsDisabledShown = false
KillFeedController._respawnsDisabledTween = nil :: Tween?

local function findTextLabel(parent: Instance?, childName: string): TextLabel?
	local child = if parent then parent:FindFirstChild(childName) else nil
	return if child and child:IsA("TextLabel") then child else nil
end

local function getLocalTeamName(): string?
	local attributeTeam = LocalPlayer:GetAttribute(ROUND_TEAM_ATTR)
	if typeof(attributeTeam) == "string" and attributeTeam ~= "" then
		return attributeTeam
	end

	local team = LocalPlayer.Team
	return if team then team.Name else nil
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

local function offsetUDim2(value: UDim2, offset: UDim2): UDim2
	return UDim2.new(
		value.X.Scale + offset.X.Scale,
		value.X.Offset + offset.X.Offset,
		value.Y.Scale + offset.Y.Scale,
		value.Y.Offset + offset.Y.Offset
	)
end

local function collectFaders(root: Frame): { Fader }
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

local function createFadeLayer(hud: ScreenGui): Frame
	local existing = hud:FindFirstChild("KillFeedFadeLayer")
	if existing then
		existing:Destroy()
	end

	local fadeLayer = Instance.new("Frame")
	fadeLayer.Name = "KillFeedFadeLayer"
	fadeLayer.BackgroundTransparency = 1
	fadeLayer.BorderSizePixel = 0
	fadeLayer.Size = UDim2.fromScale(1, 1)
	fadeLayer.Position = UDim2.fromScale(0, 0)
	fadeLayer.Parent = hud
	return fadeLayer
end

function KillFeedController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function KillFeedController:_trackEntryTween(entry: Entry, tween: Tween)
	table.insert(entry.tweens, tween)
	tween:Play()
	return tween
end

function KillFeedController:_cancelEntryTweens(entry: Entry)
	local tweens = entry.tweens
	entry.tweens = {}
	for _, tween in ipairs(tweens) do
		tween:Cancel()
	end
end

function KillFeedController:_setEntryTransparency(entry: Entry, alpha: number)
	for _, fader in ipairs(entry.faders) do
		(fader.instance :: any)[fader.property] = getFaderTransparency(fader, alpha)
	end
end

function KillFeedController:_tweenEntryTransparency(entry: Entry, alpha: number, tweenInfo: TweenInfo)
	for _, fader in ipairs(entry.faders) do
		if fader.instance.Parent then
			local goal = {}
			goal[fader.property] = getFaderTransparency(fader, alpha)
			self:_trackEntryTween(entry, TweenService:Create(fader.instance, tweenInfo, goal))
		end
	end
end

function KillFeedController:_destroyEntry(entry: Entry)
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

function KillFeedController:_clearEntries(animate: boolean?)
	if animate then
		for _, entry in ipairs(table.clone(self._entries)) do
			self:_startFade(entry)
		end
		return
	end

	for _, entry in ipairs(table.clone(self._entries)) do
		self:_destroyEntry(entry)
	end
	self._entries = {}

	local fadingEntries = {}
	for _, entry in pairs(self._fadingEntries) do
		table.insert(fadingEntries, entry)
	end
	for _, entry in ipairs(fadingEntries) do
		self:_destroyEntry(entry)
	end
	self._fadingEntries = {}
end

function KillFeedController:_clearRespawnsDisabledBannerBinding()
	if self._respawnsDisabledTween then
		self._respawnsDisabledTween:Cancel()
		self._respawnsDisabledTween = nil
	end

	self._respawnsDisabledBanner = nil
	self._respawnsDisabledNativePosition = nil
	self._respawnsDisabledHiddenPosition = nil
	self._respawnsDisabledShown = false
end

function KillFeedController:_setRespawnsDisabledBannerVisible(visible: boolean, instant: boolean?)
	local banner = self._respawnsDisabledBanner
	if not (banner and self._respawnsDisabledNativePosition and self._respawnsDisabledHiddenPosition) then
		return
	end
	if self._respawnsDisabledShown == visible and banner.Visible == visible and not instant then
		return
	end

	self._respawnsDisabledShown = visible
	if self._respawnsDisabledTween then
		self._respawnsDisabledTween:Cancel()
		self._respawnsDisabledTween = nil
	end

	local targetPosition = if visible then self._respawnsDisabledNativePosition else self._respawnsDisabledHiddenPosition
	if visible then
		banner.Visible = true
	end

	if instant then
		banner.Position = targetPosition
		banner.Visible = visible
		return
	end

	local tweenInfo = if visible then RESPAWNS_DISABLED_ENTER_TWEEN else RESPAWNS_DISABLED_EXIT_TWEEN
	self._respawnsDisabledTween = TweenService:Create(banner, tweenInfo, {
		Position = targetPosition,
	})
	self._respawnsDisabledTween:Play()
	self._respawnsDisabledTween.Completed:Once(function()
		if self._respawnsDisabledBanner == banner and not self._respawnsDisabledShown then
			banner.Visible = false
		end
	end)
end

function KillFeedController:_updateRespawnsDisabledBanner(instant: boolean?)
	local state = RoundController:GetState()
	local shouldShow = false

	if state and state.state == RoundStates.Active then
		local teamName = getLocalTeamName()
		local respawnsEnabled = state.respawnsEnabled
		if teamName and typeof(respawnsEnabled) == "table" and respawnsEnabled[teamName] == false then
			shouldShow = true
		end
	end

	self:_setRespawnsDisabledBannerVisible(shouldShow, instant)
end

function KillFeedController:_captureRespawnsDisabledBanner(banner: Frame?, layer: Frame?)
	self:_clearRespawnsDisabledBannerBinding()
	if not (banner and layer) then
		return
	end

	banner.Visible = false
	task.defer(function()
		if not (banner.Parent and layer.Parent) then
			return
		end

		local absolutePosition = banner.AbsolutePosition
		local absoluteSize = banner.AbsoluteSize
		if absoluteSize.X <= 0 or absoluteSize.Y <= 0 then
			return
		end

		local layerPosition = layer.AbsolutePosition
		local nativePosition = UDim2.fromOffset(absolutePosition.X - layerPosition.X, absolutePosition.Y - layerPosition.Y)
		local hiddenPosition = UDim2.fromOffset(
			absolutePosition.X - layerPosition.X + absoluteSize.X + RESPAWNS_DISABLED_HIDE_PADDING,
			absolutePosition.Y - layerPosition.Y
		)

		banner.Parent = layer
		banner.AnchorPoint = Vector2.new(0, 0)
		banner.Size = UDim2.fromOffset(absoluteSize.X, absoluteSize.Y)
		banner.Position = hiddenPosition
		banner.Visible = false

		self._respawnsDisabledBanner = banner
		self._respawnsDisabledNativePosition = nativePosition
		self._respawnsDisabledHiddenPosition = hiddenPosition
		self._respawnsDisabledShown = false
		self:_updateRespawnsDisabledBanner(false)
	end)
end

function KillFeedController:_clearHudBinding()
	self:_clearEntries()
	self:_clearRespawnsDisabledBannerBinding()
	if self._fadeLayer then
		self._fadeLayer:Destroy()
	end
	if self._template then
		self._template:Destroy()
	end
	self._feed = nil
	self._template = nil
	self._fadeLayer = nil
	self._templateGradientRotation = 0
end

function KillFeedController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self._remoteBindSerial += 1
	self:_clearHudBinding()
end

function KillFeedController:_configureEntry(root: Frame, payload)
	local inner = root:FindFirstChild("Inner")
	local leftPlayer = findTextLabel(inner, "LeftPlayer")
	local rightPlayer = findTextLabel(inner, "RightPlayer")

	if leftPlayer then
		leftPlayer.Text = getPayloadString(payload, "killerDisplayName", "killerName")
	end
	if rightPlayer then
		rightPlayer.Text = getPayloadString(payload, "victimDisplayName", "victimName")
	end

	local gradient = if inner then inner:FindFirstChildWhichIsA("UIGradient") else nil
	if gradient then
		local killerTeam = payload.killerTeam
		local victimTeam = payload.victimTeam
		if killerTeam == RED_TEAM_NAME and victimTeam == BLUE_TEAM_NAME then
			gradient.Rotation = (self._templateGradientRotation + 180) % 360
		else
			gradient.Rotation = self._templateGradientRotation
		end
	end
end

function KillFeedController:_startFade(entry: Entry)
	if entry.fading then
		return
	end

	entry.fading = true
	local root = entry.root
	self:_cancelEntryTweens(entry)
	if entry.motionRoot and entry.motionPosition and entry.motionRoot.Parent then
		entry.motionRoot.Position = entry.motionPosition
	end

	local activeIndex = table.find(self._entries, entry)
	if activeIndex then
		table.remove(self._entries, activeIndex)
	end
	self._fadingEntries[root] = entry

	if not root.Parent then
		self:_destroyEntry(entry)
		return
	end

	local fadeLayer = self._fadeLayer
	local absolutePosition = root.AbsolutePosition
	local absoluteSize = root.AbsoluteSize
	if fadeLayer and absoluteSize.X > 0 and absoluteSize.Y > 0 then
		root.Parent = fadeLayer
		root.AnchorPoint = Vector2.new(0, 0)
		root.Size = UDim2.fromOffset(absoluteSize.X, absoluteSize.Y)
		root.Position = UDim2.fromOffset(absolutePosition.X, absolutePosition.Y)
	end

	self:_tweenEntryTransparency(entry, 1, FADE_TWEEN)

	local slidePixels = math.max(absoluteSize.Y * 0.85, MIN_SLIDE_PIXELS)
	local slideTween = TweenService:Create(root, FADE_TWEEN, {
		Position = UDim2.fromOffset(absolutePosition.X, absolutePosition.Y - slidePixels),
	})
	self:_trackEntryTween(entry, slideTween)
	slideTween.Completed:Once(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed then
			self:_destroyEntry(entry)
		end
	end)
end

function KillFeedController:_shouldAcceptPayload(payload): boolean
	if typeof(payload) ~= "table" then
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

function KillFeedController:_addEntry(payload)
	local feed = self._feed
	local template = self._template
	if not (feed and template) then
		return
	end
	if not self:_shouldAcceptPayload(payload) then
		return
	end

	while #self._entries >= MAX_ENTRIES do
		self:_startFade(self._entries[1])
	end

	self._nextLayoutOrder += 1
	local root = template:Clone()
	root.Name = string.format("KillFeed_%06d", self._nextLayoutOrder)
	root.LayoutOrder = self._nextLayoutOrder
	root.Visible = true
	self:_configureEntry(root, payload)

	local motionRoot = root:FindFirstChild("Inner")
	local motionGui = if motionRoot and motionRoot:IsA("GuiObject") then motionRoot else nil
	local entry = {
		root = root,
		faders = collectFaders(root),
		tweens = {},
		fading = false,
		motionRoot = motionGui,
		motionPosition = if motionGui then motionGui.Position else nil,
	}
	self:_setEntryTransparency(entry, 1)
	if entry.motionRoot and entry.motionPosition then
		entry.motionRoot.Position = offsetUDim2(entry.motionPosition, ENTER_OFFSET)
	end

	table.insert(self._entries, entry)
	root.Parent = feed
	self:_tweenEntryTransparency(entry, 0, ENTER_TWEEN)
	if entry.motionRoot and entry.motionPosition then
		self:_trackEntryTween(
			entry,
			TweenService:Create(entry.motionRoot, ENTER_TWEEN, {
				Position = entry.motionPosition,
			})
		)
	end

	task.delay(HOLD_SECONDS, function()
		if table.find(self._entries, entry) then
			self:_startFade(entry)
		end
	end)
end

function KillFeedController:_bindHud(hud: Instance?)
	if not (hud and hud:IsA("ScreenGui")) then
		self:_clearHudBinding()
		return
	end

	local feed = hud:FindFirstChild("KillFeed")
	if not (feed and feed:IsA("Frame")) then
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

	local template = feed:FindFirstChild("Template")
	if not (template and template:IsA("Frame")) then
		return
	end
	local respawnsDisabled = feed:FindFirstChild("RespawnsDisabled")

	local prototype = template:Clone()
	prototype.Visible = false
	prototype.Parent = nil
	template.Visible = false
	template:Destroy()

	local inner = prototype:FindFirstChild("Inner")
	local gradient = if inner then inner:FindFirstChildWhichIsA("UIGradient") else nil

	self._feed = feed
	self._template = prototype
	self._fadeLayer = createFadeLayer(hud)
	self._templateGradientRotation = if gradient then gradient.Rotation else 0
	self:_captureRespawnsDisabledBanner(
		if respawnsDisabled and respawnsDisabled:IsA("Frame") then respawnsDisabled else nil,
		self._fadeLayer
	)
end

function KillFeedController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild("HUD"))
end

function KillFeedController:_bindRemote()
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

function KillFeedController:OnStart()
	self:_disconnectAll()

	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" then
			task.defer(function()
				self:_bindHud(child)
			end)
		end
	end))
	self:_trackConnection(LocalPlayer:GetAttributeChangedSignal(ROUND_TEAM_ATTR):Connect(function()
		self:_updateRespawnsDisabledBanner(false)
	end))
	self:_trackConnection(LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
		self:_updateRespawnsDisabledBanner(false)
	end))
	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self:_updateRespawnsDisabledBanner(false)
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "roundId" then
			self:_clearEntries(true)
		end
		if key == "respawnsEnabled" or key == "state" or key == "roundId" then
			self:_updateRespawnsDisabledBanner(key == "roundId")
		end
	end))

	self:_bindCurrentHud()
	self:_bindRemote()
end

return KillFeedController
