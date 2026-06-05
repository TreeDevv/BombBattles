local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local REMOTES_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "Notify"
local HUD_NAME = "HUD"
local HOLDER_NAME = "Messages"
local TEMPLATE_NAME = "Message"
local TEXT_LABEL_NAME = "Message"
local FADE_LAYER_NAME = "MessageFadeLayer"
local MAX_VISIBLE = 5
local TEMPLATE_WAIT_SECONDS = 6
local ENTER_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FADE_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MIN_SLIDE_PIXELS = 18

type Payload = {
	title: string?,
	text: string?,
	duration: number?,
	color: Color3?,
}

type Fader = {
	instance: Instance,
	property: string,
	value: number,
}

type Entry = {
	slot: Frame,
	visual: Frame,
	faders: { Fader },
	tweens: { Tween },
	fading: boolean,
}

local NotificationController = {}

NotificationController._connections = {} :: { RBXScriptConnection }
NotificationController._hudConnections = {} :: { RBXScriptConnection }
NotificationController._entries = {} :: { Entry }
NotificationController._fadingEntries = {} :: { [Frame]: Entry }
NotificationController._holder = nil :: Frame?
NotificationController._template = nil :: Frame?
NotificationController._fadeLayer = nil :: Frame?
NotificationController._nextLayoutOrder = 0
NotificationController._pendingPayloads = {} :: { Payload }
NotificationController._renderer = nil :: ((Payload) -> boolean)?
NotificationController._remoteBindSerial = 0

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

local function createFadeLayer(hud: ScreenGui): Frame
	local existing = hud:FindFirstChild(FADE_LAYER_NAME)
	if existing then
		existing:Destroy()
	end

	local fadeLayer = Instance.new("Frame")
	fadeLayer.Name = FADE_LAYER_NAME
	fadeLayer.BackgroundTransparency = 1
	fadeLayer.BorderSizePixel = 0
	fadeLayer.Size = UDim2.fromScale(1, 1)
	fadeLayer.Position = UDim2.fromScale(0, 0)
	fadeLayer.Parent = hud
	return fadeLayer
end

local function getCollapsedSlotSize(nativeSize: UDim2): UDim2
	return UDim2.new(1, 0, 0, 0)
end

local function getExpandedSlotSize(nativeSize: UDim2): UDim2
	return UDim2.new(1, 0, nativeSize.Y.Scale, nativeSize.Y.Offset)
end

local function getExpandedVisualSize(nativeSize: UDim2): UDim2
	return UDim2.new(nativeSize.X.Scale, nativeSize.X.Offset, 1, 0)
end

local function normalizePayload(payload: Payload): Payload
	return {
		title = if typeof(payload.title) == "string" then payload.title else "Notice",
		text = if typeof(payload.text) == "string" then payload.text else "",
		duration = if typeof(payload.duration) == "number" then payload.duration else Notify.Defaults.duration,
		color = if typeof(payload.color) == "Color3" then payload.color else nil,
	}
end

local function brighten(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), math.clamp(amount, 0, 1))
end

local function applyMessageColor(root: Frame, color: Color3?)
	if not color then
		return
	end

	root.BackgroundColor3 = color
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("UIStroke") then
			descendant.Color = color
		elseif descendant:IsA("UIGradient") then
			local parent = descendant.Parent
			descendant.Color = if parent and parent:IsA("UIStroke")
				then ColorSequence.new(color)
				else ColorSequence.new(brighten(color, 0.35), color)
		end
	end
end

local function findMessageLabel(root: Frame): TextLabel?
	local label = root:FindFirstChild(TEXT_LABEL_NAME)
	if label and label:IsA("TextLabel") then
		return label
	end

	return root:FindFirstChildWhichIsA("TextLabel", true)
end

local function findStarterTemplate(): Frame?
	local hud = StarterGui:FindFirstChild(HUD_NAME)
	local holder = if hud then hud:FindFirstChild(HOLDER_NAME) else nil
	local template = if holder then holder:FindFirstChild(TEMPLATE_NAME) else nil
	return if template and template:IsA("Frame") then template else nil
end

function NotificationController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function NotificationController:_trackHudConnection(connection: RBXScriptConnection)
	table.insert(self._hudConnections, connection)
end

function NotificationController:_disconnectHudConnections()
	for _, connection in ipairs(self._hudConnections) do
		connection:Disconnect()
	end
	self._hudConnections = {}
end

function NotificationController:_trackEntryTween(entry: Entry, tween: Tween)
	table.insert(entry.tweens, tween)
	tween:Play()
	return tween
end

function NotificationController:_cancelEntryTweens(entry: Entry)
	local tweens = entry.tweens
	entry.tweens = {}
	for _, tween in ipairs(tweens) do
		tween:Cancel()
	end
end

function NotificationController:_setEntryTransparency(entry: Entry, alpha: number)
	for _, fader in ipairs(entry.faders) do
		if fader.instance.Parent then
			(fader.instance :: any)[fader.property] = getFaderTransparency(fader, alpha)
		end
	end
end

function NotificationController:_tweenEntryTransparency(entry: Entry, alpha: number, tweenInfo: TweenInfo)
	for _, fader in ipairs(entry.faders) do
		if fader.instance.Parent then
			local goal = {}
			goal[fader.property] = getFaderTransparency(fader, alpha)
			self:_trackEntryTween(entry, TweenService:Create(fader.instance, tweenInfo, goal))
		end
	end
end

function NotificationController:_destroyEntry(entry: Entry)
	self:_cancelEntryTweens(entry)
	self._fadingEntries[entry.slot] = nil

	local activeIndex = table.find(self._entries, entry)
	if activeIndex then
		table.remove(self._entries, activeIndex)
	end

	if entry.slot.Parent then
		entry.slot:Destroy()
	end
end

function NotificationController:_clearEntries()
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

function NotificationController:_clearHudBinding()
	self:_disconnectHudConnections()
	self:_clearEntries()
	if self._fadeLayer then
		self._fadeLayer:Destroy()
	end

	self._holder = nil
	self._fadeLayer = nil
end

function NotificationController:_watchHudForMessages(hud: ScreenGui)
	self:_disconnectHudConnections()
	self:_trackHudConnection(hud.DescendantAdded:Connect(function(descendant)
		if descendant.Name == HOLDER_NAME or descendant.Name == TEMPLATE_NAME then
			task.defer(function()
				self:_bindHud(hud)
			end)
		end
	end))
end

function NotificationController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self._remoteBindSerial += 1
	self:_clearHudBinding()
	if self._renderer then
		Notify.ClearRenderer(self._renderer)
		self._renderer = nil
	end
end

function NotificationController:_configureMessage(visual: Frame, payload: Payload)
	local label = findMessageLabel(visual)
	if label then
		label.Text = tostring(payload.text or "")
	end
	applyMessageColor(visual, payload.color)
end

function NotificationController:_startFade(entry: Entry)
	if entry.fading then
		return
	end

	entry.fading = true
	self:_cancelEntryTweens(entry)

	local activeIndex = table.find(self._entries, entry)
	if activeIndex then
		table.remove(self._entries, activeIndex)
	end
	self._fadingEntries[entry.slot] = entry

	local slot = entry.slot
	if not slot.Parent then
		self:_destroyEntry(entry)
		return
	end

	local fadeLayer = self._fadeLayer
	local absolutePosition = slot.AbsolutePosition
	local absoluteSize = slot.AbsoluteSize
	if fadeLayer and absoluteSize.X > 0 and absoluteSize.Y > 0 then
		slot.Parent = fadeLayer
		slot.AnchorPoint = Vector2.new(0, 0)
		slot.Size = UDim2.fromOffset(absoluteSize.X, absoluteSize.Y)
		slot.Position = UDim2.fromOffset(absolutePosition.X, absolutePosition.Y)
	end

	self:_tweenEntryTransparency(entry, 1, FADE_TWEEN)

	local slidePixels = math.max(absoluteSize.Y * 0.85, MIN_SLIDE_PIXELS)
	local slideTween = TweenService:Create(slot, FADE_TWEEN, {
		Position = UDim2.fromOffset(absolutePosition.X, absolutePosition.Y - slidePixels),
	})
	self:_trackEntryTween(entry, slideTween)
	slideTween.Completed:Once(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed then
			self:_destroyEntry(entry)
		end
	end)
end

function NotificationController:_showPayload(payload: Payload): boolean
	local holder = self._holder
	local template = self._template
	if not (holder and holder.Parent and template) then
		return false
	end

	while #self._entries >= MAX_VISIBLE do
		self:_startFade(self._entries[1])
	end

	local normalizedPayload = normalizePayload(payload)
	self._nextLayoutOrder += 1

	local nativeSize = template.Size
	local slotSize = getExpandedSlotSize(nativeSize)
	local visualSize = getExpandedVisualSize(nativeSize)
	local slot = Instance.new("Frame")
	slot.Name = string.format("MessageSlot_%06d", self._nextLayoutOrder)
	slot.BackgroundTransparency = 1
	slot.BorderSizePixel = 0
	slot.ClipsDescendants = false
	slot.LayoutOrder = self._nextLayoutOrder
	slot.Size = getCollapsedSlotSize(nativeSize)
	slot.Parent = holder

	local visual = template:Clone()
	visual.Name = string.format("Message_%06d", self._nextLayoutOrder)
	visual.AnchorPoint = Vector2.new(0.5, 0.5)
	visual.Position = UDim2.fromScale(0.5, 0.5)
	visual.Size = UDim2.fromScale(0, 0)
	visual.LayoutOrder = 0
	visual.Visible = true
	visual.Parent = slot
	self:_configureMessage(visual, normalizedPayload)

	local entry = {
		slot = slot,
		visual = visual,
		faders = collectFaders(visual),
		tweens = {},
		fading = false,
	}
	table.insert(self._entries, entry)

	self:_trackEntryTween(entry, TweenService:Create(slot, ENTER_TWEEN, { Size = slotSize }))
	self:_trackEntryTween(entry, TweenService:Create(visual, ENTER_TWEEN, { Size = visualSize }))

	task.delay(normalizedPayload.duration or Notify.Defaults.duration, function()
		if table.find(self._entries, entry) then
			self:_startFade(entry)
		end
	end)

	return true
end

function NotificationController:_flushPending()
	if not (self._holder and self._template) then
		return
	end

	local pending = self._pendingPayloads
	self._pendingPayloads = {}
	for _, payload in ipairs(pending) do
		self:_showPayload(payload)
	end
end

function NotificationController:_enqueue(payload: Payload): boolean
	local normalizedPayload = normalizePayload(payload)
	if self:_showPayload(normalizedPayload) then
		return true
	end

	table.insert(self._pendingPayloads, normalizedPayload)
	task.delay(TEMPLATE_WAIT_SECONDS, function()
		local index = table.find(self._pendingPayloads, normalizedPayload)
		if not index then
			return
		end

		table.remove(self._pendingPayloads, index)
		Notify.ShowCore(normalizedPayload)
	end)
	return true
end

function NotificationController:_bindHud(hud: Instance?)
	if not (hud and hud:IsA("ScreenGui")) then
		self:_clearHudBinding()
		return
	end

	local holder = hud:FindFirstChild(HOLDER_NAME)
	if not (holder and holder:IsA("Frame")) then
		self:_watchHudForMessages(hud)
		return
	end
	if self._holder == holder and self._template then
		return
	end

	self:_clearHudBinding()

	local listLayout = holder:FindFirstChildWhichIsA("UIListLayout")
	if listLayout then
		listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	end

	local template = holder:FindFirstChild(TEMPLATE_NAME)
	if template and not template:IsA("Frame") then
		return
	end

	local prototype = self._template
	if template then
		if prototype then
			prototype:Destroy()
		end
		prototype = template:Clone()
		prototype.Visible = false
		prototype.Parent = nil
		template.Visible = false
		template:Destroy()
	elseif not prototype then
		local starterTemplate = findStarterTemplate()
		if not starterTemplate then
			self:_watchHudForMessages(hud)
			return
		end
		prototype = starterTemplate:Clone()
		prototype.Visible = false
		prototype.Parent = nil
	end

	self:_disconnectHudConnections()
	self._holder = holder
	self._template = prototype
	self._fadeLayer = createFadeLayer(hud)
	self:_flushPending()
end

function NotificationController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild(HUD_NAME))
end

function NotificationController:_bindRemote()
	self._remoteBindSerial += 1
	local serial = self._remoteBindSerial

	task.spawn(function()
		local remotes = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
		while serial == self._remoteBindSerial and not (remotes and remotes:IsA("Folder")) do
			local child = ReplicatedStorage.ChildAdded:Wait()
			if child.Name == REMOTES_FOLDER_NAME then
				remotes = child
			end
		end
		if serial ~= self._remoteBindSerial or not remotes then
			return
		end

		local remote = remotes:FindFirstChild(REMOTE_NAME)
		while serial == self._remoteBindSerial and not (remote and remote:IsA("RemoteEvent")) do
			local child = remotes.ChildAdded:Wait()
			if child.Name == REMOTE_NAME then
				remote = child
			end
		end
		if serial ~= self._remoteBindSerial or not (remote and remote:IsA("RemoteEvent")) then
			return
		end

		self:_trackConnection(remote.OnClientEvent:Connect(function(payload)
			if typeof(payload) == "table" then
				self:_enqueue(payload)
			else
				self:_enqueue({
					text = tostring(payload),
				})
			end
		end))
	end)
end

function NotificationController:OnStart()
	self:_disconnectAll()

	self._renderer = function(payload: Payload)
		return self:_enqueue(payload)
	end
	Notify.SetRenderer(self._renderer)

	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == HUD_NAME then
			task.defer(function()
				self:_bindHud(child)
			end)
		end
	end))

	self:_trackConnection(PlayerGui.ChildRemoved:Connect(function(child)
		if child:IsA("ScreenGui") and child.Name == HUD_NAME then
			self:_clearHudBinding()
		end
	end))

	self:_bindCurrentHud()
	self:_bindRemote()
end

return NotificationController
