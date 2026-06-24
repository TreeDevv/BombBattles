local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local EmoteConfig = require(ReplicatedStorage.Shared.Emotes.EmoteConfig)
local EmoteVFX = require(ReplicatedStorage.Shared.Emotes.EmoteVFX)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local DataController = require(script.Parent:WaitForChild("DataController"))
local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ACTION_NAME = "BombBattlesEmoteWheel"
local FRAME_NAME = "Emotes"
local FRAMES_GUI_NAME = "Frames"
local HUD_GUI_NAME = "HUD"
local SIDE_BUTTONS_NAME = "SideButtons"
local EMOTES_BUTTON_NAME = "Emotes"
local TEMPLATE_SUFFIX = "Template"
local RUNTIME_LIST_TILE_ATTRIBUTE = "RuntimeEmoteTile"
local RUNTIME_SCALE_NAME = "EmoteRuntimeScale"
local RUNTIME_CAMERA_NAME = "EmoteRuntimeCamera"
local REMOTE_RETRY_SECONDS = 1
local TOGGLE_DEBOUNCE_SECONDS = 0.08

local ORDER_KEY = Schema.EmoteOrder and Schema.EmoteOrder.key or "emoteOrder"
local FAVORITES_KEY = Schema.FavoriteEmotes and Schema.FavoriteEmotes.key or "favoriteEmotes"

local SELECTOR_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local PAGE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LIST_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local LIST_CLOSE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local BUTTON_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SELECTOR_VISUAL_SLOT_OFFSET = -1

type RenderState = {
	track: AnimationTrack?,
	animation: Animation?,
	vfx: any?,
}

type PreviewState = {
	track: AnimationTrack?,
	animation: Animation?,
	pausedTimeSeconds: number,
	playing: boolean,
}

type ListTileRecord = {
	button: ImageButton,
	emoteId: string,
	preview: PreviewState?,
}

local EmoteController = {}

EmoteController._requestRemote = nil :: RemoteEvent?
EmoteController._stateRemote = nil :: RemoteEvent?
EmoteController._stateConnection = nil :: RBXScriptConnection?
EmoteController._inventoryConnection = nil :: RBXScriptConnection?
EmoteController._connections = {} :: { RBXScriptConnection }
EmoteController._hudConnections = {} :: { RBXScriptConnection }
EmoteController._frameConnections = {} :: { RBXScriptConnection }
EmoteController._slotConnections = {} :: { RBXScriptConnection }
EmoteController._listConnections = {} :: { RBXScriptConnection }
EmoteController._renderByPlayer = {} :: { [Player]: RenderState }
EmoteController._slotPreviewStates = {} :: { [number]: PreviewState }
EmoteController._listTilesByEmoteId = {} :: { [string]: ListTileRecord }
EmoteController._scaleTweens = {} :: { [GuiObject]: Tween }
EmoteController._selectorTweens = {} :: { [GuiObject]: Tween }
EmoteController._frame = nil :: GuiObject?
EmoteController._base = nil :: GuiObject?
EmoteController._cursor = nil :: GuiObject?
EmoteController._selected = nil :: GuiObject?
EmoteController._emoteName = nil :: TextLabel?
EmoteController._slotsFrame = nil :: Frame?
EmoteController._pageButtons = nil :: Frame?
EmoteController._pageNumber = nil :: TextLabel?
EmoteController._leftPageButton = nil :: ImageButton?
EmoteController._rightPageButton = nil :: ImageButton?
EmoteController._editButton = nil :: ImageButton?
EmoteController._closeButton = nil :: ImageButton?
EmoteController._emotesList = nil :: GuiObject?
EmoteController._listScroller = nil :: ScrollingFrame?
EmoteController._listSearchBox = nil :: TextBox?
EmoteController._listCloseButton = nil :: ImageButton?
EmoteController._listOpenPosition = nil :: UDim2?
EmoteController._listHiddenPosition = nil :: UDim2?
EmoteController._listTween = nil :: Tween?
EmoteController._page = 1
EmoteController._selectedSlot = 1
EmoteController._editTargetSlot = nil :: number?
EmoteController._editing = false
EmoteController._listOpen = false
EmoteController._selectorRotation = 22.5
EmoteController._activeLocalEmoteId = ""
EmoteController._lastToggleAt = 0
EmoteController._remoteBindSerial = 0
EmoteController._warnedMissingRequestRemote = false
EmoteController._warnedMissingStateRemote = false

local function track(list: { RBXScriptConnection }, connection: RBXScriptConnection?)
	if connection then
		table.insert(list, connection)
	end
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function findButton(parent: Instance?, name: string): ImageButton?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("ImageButton") then child else nil
end

local function findTextLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findHudEmotesButton(hud: Instance?): ImageButton?
	local sideButtons = hud and hud:FindFirstChild(SIDE_BUTTONS_NAME)
	if not sideButtons then
		return nil
	end

	local button = sideButtons:FindFirstChild(EMOTES_BUTTON_NAME)
	return if button and button:IsA("ImageButton") then button else nil
end

local function getRemote(name: string): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild(EmoteConfig.RemotesFolderName)
	if not remotes then
		return nil
	end

	local remote = remotes:FindFirstChild(name)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getAnimationId(animation: Animation?): string
	return if animation and typeof(animation.AnimationId) == "string" then animation.AnimationId else ""
end

local function getDefaultOrder(): { string }
	local order = {}
	for _, definition in ipairs(EmoteConfig.GetCatalog()) do
		table.insert(order, definition.id)
	end
	return order
end

local function getEmoteOrder(): { string }
	local catalogOrder = getDefaultOrder()
	local known: { [string]: boolean } = {}
	for _, emoteId in ipairs(catalogOrder) do
		known[emoteId] = true
	end

	local rawOrder = DataController:Get(ORDER_KEY)
	local order = {}
	local seen: { [string]: boolean } = {}

	if typeof(rawOrder) == "table" then
		for _, rawEmoteId in ipairs(rawOrder) do
			local emoteId = EmoteConfig.NormalizeEmoteId(rawEmoteId)
			if emoteId ~= "" and known[emoteId] and not seen[emoteId] then
				table.insert(order, emoteId)
				seen[emoteId] = true
			end
		end
	end

	for _, emoteId in ipairs(catalogOrder) do
		if not seen[emoteId] then
			table.insert(order, emoteId)
			seen[emoteId] = true
		end
	end

	return order
end

local function getFavoriteEmotes(): { [string]: boolean }
	local rawFavorites = DataController:Get(FAVORITES_KEY)
	local favorites = {}
	if typeof(rawFavorites) ~= "table" then
		return favorites
	end

	for rawEmoteId, value in pairs(rawFavorites) do
		local emoteId = EmoteConfig.NormalizeEmoteId(rawEmoteId)
		if emoteId ~= "" and value == true then
			favorites[emoteId] = true
		end
	end
	return favorites
end

local function getPageCount(order: { string }): number
	return math.max(math.ceil(#order / EmoteConfig.PageSize), 1)
end

local function getPageDefinition(order: { string }, pageIndex: number, slotIndex: number): any?
	local absoluteIndex = ((pageIndex - 1) * EmoteConfig.PageSize) + slotIndex
	local emoteId = order[absoluteIndex]
	return if emoteId then EmoteConfig.GetDefinition(emoteId) else nil
end

local function getSortedOwnedDefinitions(): { any }
	local favorites = getFavoriteEmotes()
	local favoriteDefinitions = {}
	local otherDefinitions = {}

	for _, definition in ipairs(EmoteConfig.GetCatalog()) do
		if favorites[definition.id] == true then
			table.insert(favoriteDefinitions, definition)
		else
			table.insert(otherDefinitions, definition)
		end
	end

	for _, definition in ipairs(otherDefinitions) do
		table.insert(favoriteDefinitions, definition)
	end
	return favoriteDefinitions
end

local function findEmoteListTemplate(scroller: Instance, rarity: string?, fallbackTemplate: ImageButton?): ImageButton?
	local rarityName = if typeof(rarity) == "string" and rarity ~= "" then rarity else EmoteConfig.DefaultRarity
	local template = scroller:FindFirstChild(rarityName .. TEMPLATE_SUFFIX)
	if template and template:IsA("ImageButton") then
		return template
	end

	return fallbackTemplate
end

local function slotRotation(slotIndex: number): number
	return 22.5 + ((slotIndex - 1 + SELECTOR_VISUAL_SLOT_OFFSET) * 45)
end

local function shortestRotationTarget(current: number, target: number): number
	local delta = ((target - current + 180) % 360) - 180
	return current + delta
end

local function scaleUDim2(size: UDim2, factor: number): UDim2
	return UDim2.new(
		size.X.Scale * factor,
		math.floor(size.X.Offset * factor),
		size.Y.Scale * factor,
		math.floor(size.Y.Offset * factor)
	)
end

local function getOrCreateScale(guiObject: GuiObject): UIScale
	local existing = guiObject:FindFirstChild(RUNTIME_SCALE_NAME)
	if existing and existing:IsA("UIScale") then
		return existing
	end

	local scale = Instance.new("UIScale")
	scale.Name = RUNTIME_SCALE_NAME
	scale.Scale = 1
	scale.Parent = guiObject
	return scale
end

local function stopRenderState(state: RenderState?)
	if not state then
		return
	end
	if state.track then
		state.track:Stop(0.15)
		state.track:Destroy()
	end
	if state.animation then
		state.animation:Destroy()
	end
	if state.vfx and type(state.vfx.Destroy) == "function" then
		state.vfx.Destroy()
	end
end

local function stopPreviewState(state: PreviewState?)
	if not state then
		return
	end
	if state.track then
		state.track:Stop(0)
		state.track:Destroy()
	end
	if state.animation then
		state.animation:Destroy()
	end
end

local function findAnimator(model: Model): Animator?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

local function findViewportRig(viewport: ViewportFrame?): Model?
	if not viewport then
		return nil
	end

	local worldModel = viewport:FindFirstChildOfClass("WorldModel")
	if not worldModel then
		return nil
	end

	local rig = worldModel:FindFirstChild("Rig")
	return if rig and rig:IsA("Model") then rig else nil
end

local function ensureViewportCamera(viewport: ViewportFrame, rig: Model?)
	if viewport.CurrentCamera and viewport.CurrentCamera.Parent then
		return
	end

	local camera = Instance.new("Camera")
	camera.Name = RUNTIME_CAMERA_NAME
	camera.FieldOfView = 35
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local center = Vector3.new(0, 2.3, 0)
	if rig then
		local ok, cframe, size = pcall(function()
			return rig:GetBoundingBox()
		end)
		if ok then
			center = cframe.Position + Vector3.new(0, math.max(size.Y * 0.08, 0.2), 0)
		end
	end

	camera.CFrame = CFrame.new(center + Vector3.new(0, 0.8, 7.5), center)
end

local function getPreviewPauseTimeSeconds(emoteId: string): number
	local definition = EmoteConfig.GetDefinition(emoteId)
	local pauseTime = definition and definition.previewPauseTimeSeconds
	return if typeof(pauseTime) == "number" then math.max(pauseTime, 0) else 0
end

local function setTrackTimePosition(track: AnimationTrack, timePosition: number)
	pcall(function()
		track.TimePosition = timePosition
	end)
end

local function setPreviewPlaying(state: PreviewState?, playing: boolean)
	if not (state and state.track) then
		return
	end
	local track = state.track

	if not track.IsPlaying then
		track:Play(0, 1, if playing then 1 else 0)
	end
	if playing and not state.playing then
		setTrackTimePosition(track, 0)
	end
	track:AdjustSpeed(if playing then 1 else 0)
	if not playing then
		setTrackTimePosition(track, state.pausedTimeSeconds)
	end
	state.playing = playing
end

local function loadPreview(viewport: ViewportFrame?, emoteId: string, playing: boolean): PreviewState?
	if not viewport then
		return nil
	end

	local rig = findViewportRig(viewport)
	if not rig then
		return nil
	end

	ensureViewportCamera(viewport, rig)
	local animator = findAnimator(rig)
	local sourceAnimation = EmoteConfig.GetAnimation(emoteId)
	if not (animator and sourceAnimation) then
		return nil
	end

	local animation = sourceAnimation:Clone()
	animation.Name = "Preview_" .. emoteId
	animation.Parent = viewport

	local ok, result = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not (ok and result) then
		warn(("[EmoteController] Failed to load preview emote %s animation %s: %s"):format(
			emoteId,
			getAnimationId(animation),
			tostring(result)
		))
		animation:Destroy()
		return nil
	end

	local track = result :: AnimationTrack
	local pausedTimeSeconds = getPreviewPauseTimeSeconds(emoteId)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0, 1, if playing then 1 else 0)
	if not playing then
		track:AdjustSpeed(0)
		task.defer(function()
			if track.IsPlaying then
				setTrackTimePosition(track, pausedTimeSeconds)
			end
		end)
	end

	return {
		track = track,
		animation = animation,
		pausedTimeSeconds = pausedTimeSeconds,
		playing = playing,
	}
end

local function disableAuthoredLocalScripts(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("LocalScript") then
			descendant.Enabled = false
		end
	end
end

local function ensureFrameRegistered(frame: GuiObject)
	local frameTag = FrameController.FrameTag or "Frame"
	if not CollectionService:HasTag(frame, frameTag) then
		CollectionService:AddTag(frame, frameTag)
	end

	local exclusiveAttribute = FrameController.ExclusiveAttribute or "Exclusive"
	if frame:GetAttribute(exclusiveAttribute) ~= true then
		frame:SetAttribute(exclusiveAttribute, true)
	end
end

local function getMouseGuiPosition(): Vector2
	local mousePosition = UserInputService:GetMouseLocation()
	local inset = GuiService:GetGuiInset()
	return mousePosition - inset
end

local function toGuiPosition(position: Vector2): Vector2
	local inset = GuiService:GetGuiInset()
	return position - inset
end

function EmoteController:_cancelScaleTween(guiObject: GuiObject)
	local tween = self._scaleTweens[guiObject]
	if tween then
		tween:Cancel()
		self._scaleTweens[guiObject] = nil
	end
end

function EmoteController:_tweenScale(guiObject: GuiObject, scaleValue: number)
	self:_cancelScaleTween(guiObject)

	local scale = getOrCreateScale(guiObject)
	local tween = TweenService:Create(scale, BUTTON_TWEEN, { Scale = scaleValue })
	self._scaleTweens[guiObject] = tween
	tween.Completed:Once(function()
		if self._scaleTweens[guiObject] == tween then
			self._scaleTweens[guiObject] = nil
		end
	end)
	tween:Play()
end

function EmoteController:_bindButtonFeedback(button: ImageButton?, connections: { RBXScriptConnection })
	if not button then
		return
	end

	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true

	track(connections, button.MouseEnter:Connect(function()
		self:_tweenScale(button, 1.035)
	end))
	track(connections, button.MouseLeave:Connect(function()
		self:_tweenScale(button, 1)
	end))
	track(connections, button.MouseButton1Down:Connect(function()
		self:_tweenScale(button, 0.92)
	end))
	track(connections, button.MouseButton1Up:Connect(function()
		self:_tweenScale(button, 1.035)
	end))
end

function EmoteController:_tweenSelectorToSlot(slotIndex: number, instant: boolean?)
	local target = shortestRotationTarget(self._selectorRotation, slotRotation(slotIndex))
	self._selectorRotation = target

	for _, guiObject in ipairs({ self._cursor, self._selected }) do
		if not guiObject then
			continue
		end

		local existing = self._selectorTweens[guiObject]
		if existing then
			existing:Cancel()
			self._selectorTweens[guiObject] = nil
		end

		if instant then
			guiObject.Rotation = target
		else
			local tween = TweenService:Create(guiObject, SELECTOR_TWEEN, { Rotation = target })
			self._selectorTweens[guiObject] = tween
			tween.Completed:Once(function()
				if self._selectorTweens[guiObject] == tween then
					self._selectorTweens[guiObject] = nil
				end
			end)
			tween:Play()
		end
	end
end

function EmoteController:_updateEmoteName()
	local label = self._emoteName
	if not label then
		return
	end

	local order = getEmoteOrder()
	local slotIndex = self._editTargetSlot or self._selectedSlot
	local definition = getPageDefinition(order, self._page, slotIndex)
	label.Text = if definition then definition.displayName or definition.id else ""
end

function EmoteController:_setSlotPreviewSelection()
	for slotIndex, state in pairs(self._slotPreviewStates) do
		setPreviewPlaying(state, slotIndex == self._selectedSlot)
	end
end

function EmoteController:_getNearestAuthoredSlotFromPosition(position: Vector2): number
	local nearestSlot = self._editTargetSlot or self._selectedSlot
	local nearestDistance = math.huge

	for slotIndex = 1, EmoteConfig.PageSize do
		local slotFrame = self:_findSlotFrame(slotIndex)
		if not (slotFrame and slotFrame.Visible) then
			continue
		end

		local center = slotFrame.AbsolutePosition + (slotFrame.AbsoluteSize / 2)
		local distance = (position - center).Magnitude
		if distance < nearestDistance then
			nearestDistance = distance
			nearestSlot = slotIndex
		end
	end

	return nearestSlot
end

function EmoteController:_setSelectedSlot(slotIndex: number, options: any?): boolean
	local definition = getPageDefinition(getEmoteOrder(), self._page, slotIndex)
	if not definition then
		return false
	end

	local isEditTarget = options and options.editTarget == true
	local instant = options and options.instant == true

	if isEditTarget then
		self._editTargetSlot = slotIndex
	else
		self._selectedSlot = slotIndex
		if not self._editing then
			self._editTargetSlot = nil
		end
	end

	self:_tweenSelectorToSlot(slotIndex, instant)
	self:_updateEmoteName()
	self:_setSlotPreviewSelection()
	return true
end

function EmoteController:_previewSlot(slotIndex: number)
	if self._editing then
		return
	end

	self:_setSelectedSlot(slotIndex, nil)
end

function EmoteController:_clearSlotPreviews()
	for _, state in pairs(self._slotPreviewStates) do
		stopPreviewState(state)
	end
	table.clear(self._slotPreviewStates)
end

function EmoteController:_clearListTiles()
	for _, record in pairs(self._listTilesByEmoteId) do
		stopPreviewState(record.preview)
	end
	table.clear(self._listTilesByEmoteId)

	local scroller = self._listScroller
	if not scroller then
		return
	end

	for _, child in ipairs(scroller:GetChildren()) do
		if child:IsA("ImageButton") then
			if child:GetAttribute(RUNTIME_LIST_TILE_ATTRIBUTE) == true then
				child:Destroy()
			elseif string.sub(child.Name, -#TEMPLATE_SUFFIX) == TEMPLATE_SUFFIX then
				child.Visible = false
				child.Active = false
				child.Selectable = false
			end
		end
	end
end

function EmoteController:_findSlotButton(slotIndex: number): ImageButton?
	local slotsFrame = self._slotsFrame
	local slotFrame = slotsFrame and slotsFrame:FindFirstChild(tostring(slotIndex))
	local button = slotFrame and slotFrame:FindFirstChild("ImageButton")
	return if button and button:IsA("ImageButton") then button else nil
end

function EmoteController:_findSlotFrame(slotIndex: number): GuiObject?
	local slotsFrame = self._slotsFrame
	local slotFrame = slotsFrame and slotsFrame:FindFirstChild(tostring(slotIndex))
	return if slotFrame and slotFrame:IsA("GuiObject") then slotFrame else nil
end

function EmoteController:_refreshWheel()
	local frame = self._frame
	local slotsFrame = self._slotsFrame
	if not (frame and slotsFrame) then
		return
	end

	local order = getEmoteOrder()
	local pageCount = getPageCount(order)
	self._page = math.clamp(self._page, 1, pageCount)

	if not getPageDefinition(order, self._page, self._selectedSlot) then
		self._selectedSlot = 1
	end
	if self._editTargetSlot and not getPageDefinition(order, self._page, self._editTargetSlot) then
		self._editTargetSlot = self._selectedSlot
	end

	self:_clearSlotPreviews()
	local shouldLoadPreviews = frame.Visible

	for slotIndex = 1, EmoteConfig.PageSize do
		local definition = getPageDefinition(order, self._page, slotIndex)
		local slotFrame = self:_findSlotFrame(slotIndex)
		local button = self:_findSlotButton(slotIndex)

		if slotFrame then
			slotFrame.Visible = definition ~= nil
		end
		if button then
			button.Visible = definition ~= nil
			button.Active = definition ~= nil
			button.Selectable = definition ~= nil
			button:SetAttribute("EmoteId", if definition then definition.id else "")
		end

		if shouldLoadPreviews and definition and button then
			local viewport = button:FindFirstChild("ViewportFrame")
			if viewport and viewport:IsA("ViewportFrame") then
				self._slotPreviewStates[slotIndex] = loadPreview(viewport, definition.id, slotIndex == self._selectedSlot)
			end
		end
	end

	if self._pageNumber then
		self._pageNumber.Text = string.format("%d/%d", self._page, pageCount)
	end

	self:_updateEmoteName()
	self:_tweenSelectorToSlot(self._editTargetSlot or self._selectedSlot, true)
end

function EmoteController:_setPage(pageIndex: number)
	local order = getEmoteOrder()
	local pageCount = getPageCount(order)
	local nextPage = math.clamp(math.floor(pageIndex), 1, pageCount)
	if nextPage == self._page then
		return
	end

	self._page = nextPage
	self._editTargetSlot = if self._editing then self._selectedSlot else nil

	local slotsFrame = self._slotsFrame
	if slotsFrame then
		local originalSize = slotsFrame.Size
		local shrink = scaleUDim2(originalSize, 0.965)
		local outTween = TweenService:Create(slotsFrame, PAGE_TWEEN, { Size = shrink })
		outTween.Completed:Once(function()
			if slotsFrame.Parent then
				self:_refreshWheel()
				TweenService:Create(slotsFrame, PAGE_TWEEN, { Size = originalSize }):Play()
			end
		end)
		outTween:Play()
	else
		self:_refreshWheel()
	end
end

function EmoteController:StartEmote(emoteId: string)
	local remote = self._requestRemote
	if not remote then
		if not self._warnedMissingRequestRemote then
			warn("[EmoteController] EmoteRequest remote is unavailable; emote start was not sent.")
			self._warnedMissingRequestRemote = true
		end
		return
	end

	remote:FireServer({
		action = EmoteConfig.Actions.Start,
		emoteId = emoteId,
	})
end

function EmoteController:StopLocalEmote()
	local remote = self._requestRemote
	if remote then
		remote:FireServer({
			action = EmoteConfig.Actions.Stop,
		})
	end
end

function EmoteController:_commitSlot(slotIndex: number)
	local definition = getPageDefinition(getEmoteOrder(), self._page, slotIndex)
	if not definition then
		return
	end

	if self._editing then
		self:_setSelectedSlot(slotIndex, {
			editTarget = true,
		})
		return
	end

	if not self:_setSelectedSlot(slotIndex, nil) then
		return
	end

	self:StartEmote(definition.id)
	FrameController:CloseFrame(FRAME_NAME)
end

function EmoteController:_sendSwap(emoteId: string)
	local remote = self._requestRemote
	local targetSlot = self._editTargetSlot or self._selectedSlot
	if not (remote and targetSlot) then
		return
	end

	remote:FireServer({
		action = EmoteConfig.Actions.SwapSlots,
		pageIndex = self._page,
		slotIndex = targetSlot,
		emoteId = emoteId,
	})
end

function EmoteController:_sendToggleFavorite(emoteId: string)
	local remote = self._requestRemote
	if not remote then
		return
	end

	remote:FireServer({
		action = EmoteConfig.Actions.ToggleFavorite,
		emoteId = emoteId,
	})
end

function EmoteController:_setFavoriteVisual(button: ImageButton, isFavorite: boolean)
	button:SetAttribute("Favorite", isFavorite)
	local back = button:FindFirstChild("Back")
	if not back then
		return
	end

	local favorited = back:FindFirstChild("Favorited")
	local unfavorited = back:FindFirstChild("Unfavorited")
	if favorited and favorited:IsA("UIGradient") then
		favorited.Enabled = isFavorite
	end
	if unfavorited and unfavorited:IsA("UIGradient") then
		unfavorited.Enabled = not isFavorite
	end
end

function EmoteController:_bindListTile(button: ImageButton, emoteId: string, preview: PreviewState?)
	local favoriteButton = findButton(button, "FavoriteButton")

	self:_bindButtonFeedback(button, self._listConnections)
	track(self._listConnections, button.MouseEnter:Connect(function()
		setPreviewPlaying(preview, true)
	end))
	track(self._listConnections, button.MouseLeave:Connect(function()
		setPreviewPlaying(preview, false)
	end))
	track(self._listConnections, button.Activated:Connect(function()
		self:_sendSwap(emoteId)
	end))

	if favoriteButton then
		self:_bindButtonFeedback(favoriteButton, self._listConnections)
		track(self._listConnections, favoriteButton.Activated:Connect(function()
			self:_sendToggleFavorite(emoteId)
		end))
	end
end

function EmoteController:_applySearchFilter()
	local scroller = self._listScroller
	local searchBox = self._listSearchBox
	if not scroller then
		return
	end

	local query = string.lower(searchBox and searchBox.Text or "")
	for _, record in pairs(self._listTilesByEmoteId) do
		local visible = query == "" or string.find(string.lower(record.emoteId), query, 1, true) ~= nil
		record.button.Visible = visible
	end
end

function EmoteController:_populateEmotesList()
	local scroller = self._listScroller
	if not scroller then
		return
	end

	disconnectAll(self._listConnections)
	self:_clearListTiles()

	local fallbackTemplate = scroller:FindFirstChild(EmoteConfig.DefaultRarity .. TEMPLATE_SUFFIX)
	if not (fallbackTemplate and fallbackTemplate:IsA("ImageButton")) then
		fallbackTemplate = scroller:FindFirstChild("RareTemplate")
	end
	if not (fallbackTemplate and fallbackTemplate:IsA("ImageButton")) then
		warn("[EmoteController] Missing RareTemplate in EmotesList.ScrollingFrame")
		return
	end

	local favorites = getFavoriteEmotes()
	for index, definition in ipairs(getSortedOwnedDefinitions()) do
		local template = findEmoteListTemplate(scroller, definition.rarity, fallbackTemplate)
		if not template then
			continue
		end

		local tile = template:Clone()
		tile.Name = "Emote_" .. string.gsub(definition.id, "%W", "_")
		tile.LayoutOrder = index
		tile.Visible = true
		tile.Active = true
		tile.Selectable = true
		tile:SetAttribute(RUNTIME_LIST_TILE_ATTRIBUTE, true)
		tile:SetAttribute("EmoteId", definition.id)
		tile:SetAttribute("Rarity", definition.rarity or EmoteConfig.DefaultRarity)

		local label = findTextLabel(tile, "Label")
		if label then
			label.Text = definition.displayName or definition.id
		end

		local favoriteButton = findButton(tile, "FavoriteButton")
		if favoriteButton then
			self:_setFavoriteVisual(favoriteButton, favorites[definition.id] == true)
		end

		local viewport = tile:FindFirstChild("ViewportFrame")
		local preview = nil :: PreviewState?
		if viewport and viewport:IsA("ViewportFrame") then
			preview = loadPreview(viewport, definition.id, false)
		end

		tile.Parent = scroller
		self._listTilesByEmoteId[definition.id] = {
			button = tile,
			emoteId = definition.id,
			preview = preview,
		}
		self:_bindListTile(tile, definition.id, preview)
	end

	if self._listSearchBox then
		track(self._listConnections, self._listSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
			self:_applySearchFilter()
		end))
	end

	self:_applySearchFilter()
end

function EmoteController:_openList()
	local list = self._emotesList
	local openPosition = self._listOpenPosition
	local hiddenPosition = self._listHiddenPosition
	if not (list and openPosition and hiddenPosition) then
		return
	end

	self._editing = true
	self._listOpen = true
	self._editTargetSlot = self._selectedSlot
	self:_populateEmotesList()
	self:_updateEmoteName()

	if self._listTween then
		self._listTween:Cancel()
		self._listTween = nil
	end

	list.Position = hiddenPosition
	list.Visible = true
	local tween = TweenService:Create(list, LIST_TWEEN, { Position = openPosition })
	self._listTween = tween
	tween.Completed:Once(function()
		if self._listTween == tween then
			self._listTween = nil
		end
	end)
	tween:Play()
end

function EmoteController:_closeList(instant: boolean?)
	local list = self._emotesList
	local openPosition = self._listOpenPosition
	local hiddenPosition = self._listHiddenPosition
	if not (list and openPosition and hiddenPosition) then
		self._editing = false
		self._listOpen = false
		self._editTargetSlot = nil
		return
	end

	self._editing = false
	self._listOpen = false
	self._editTargetSlot = nil

	if self._listTween then
		self._listTween:Cancel()
		self._listTween = nil
	end

	if instant then
		list.Position = hiddenPosition
		list.Visible = false
		disconnectAll(self._listConnections)
		self:_clearListTiles()
		return
	end

	local tween = TweenService:Create(list, LIST_CLOSE_TWEEN, { Position = hiddenPosition })
	self._listTween = tween
	tween.Completed:Once(function()
		if self._listTween ~= tween then
			return
		end
		self._listTween = nil
		list.Visible = false
		disconnectAll(self._listConnections)
		self:_clearListTiles()
	end)
	tween:Play()
end

function EmoteController:_toggleList()
	if self._listOpen then
		self:_closeList(false)
	else
		self:_openList()
	end
end

function EmoteController:_bindSlots()
	disconnectAll(self._slotConnections)

	local base = self._base
	if base then
		base.Active = true
		track(self._slotConnections, base.MouseMoved:Connect(function()
			if self._editing then
				return
			end
			self:_previewSlot(self:_getNearestAuthoredSlotFromPosition(getMouseGuiPosition()))
		end))
		track(self._slotConnections, base.InputBegan:Connect(function(inputObject: InputObject)
			if inputObject.UserInputType == Enum.UserInputType.MouseButton1 then
				local position = toGuiPosition(Vector2.new(inputObject.Position.X, inputObject.Position.Y))
				self:_commitSlot(self:_getNearestAuthoredSlotFromPosition(position))
			end
		end))
	end

	for slotIndex = 1, EmoteConfig.PageSize do
		local button = self:_findSlotButton(slotIndex)
		if not button then
			continue
		end

		self:_bindButtonFeedback(button, self._slotConnections)
		track(self._slotConnections, button.MouseMoved:Connect(function()
			self:_previewSlot(slotIndex)
		end))
		track(self._slotConnections, button.MouseEnter:Connect(function()
			self:_previewSlot(slotIndex)
		end))
		track(self._slotConnections, button.Activated:Connect(function()
			self:_commitSlot(slotIndex)
		end))
	end
end

function EmoteController:_bindFrame(frame: GuiObject?)
	disconnectAll(self._frameConnections)
	disconnectAll(self._slotConnections)
	disconnectAll(self._listConnections)
	self:_clearSlotPreviews()
	self:_clearListTiles()

	self._frame = frame
	self._base = nil
	self._cursor = nil
	self._selected = nil
	self._emoteName = nil
	self._slotsFrame = nil
	self._pageButtons = nil
	self._pageNumber = nil
	self._leftPageButton = nil
	self._rightPageButton = nil
	self._editButton = nil
	self._closeButton = nil
	self._emotesList = nil
	self._listScroller = nil
	self._listSearchBox = nil
	self._listCloseButton = nil

	if not frame then
		return
	end

	ensureFrameRegistered(frame)
	disableAuthoredLocalScripts(frame)

	self._base = frame:FindFirstChild("Base") :: GuiObject?
	self._cursor = frame:FindFirstChild("Cursor") :: GuiObject?
	self._selected = frame:FindFirstChild("Selected") :: GuiObject?
	self._emoteName = findTextLabel(frame, "EmoteName")
	self._slotsFrame = frame:FindFirstChild("EmoteSlots") :: Frame?
	self._editButton = findButton(frame, "EditSlot")
	self._closeButton = findButton(frame, "CloseMenu")
	self._pageButtons = frame:FindFirstChild("PageButtons") :: Frame?
	self._leftPageButton = findButton(self._pageButtons, "LeftButton")
	self._rightPageButton = findButton(self._pageButtons, "RightButton")
	self._pageNumber = findTextLabel(self._pageButtons, "PageNumber")
	self._emotesList = frame:FindFirstChild("EmotesList") :: GuiObject?

	if self._emotesList then
		self._listOpenPosition = self._emotesList.Position
		self._listHiddenPosition = UDim2.new(
			self._emotesList.Position.X.Scale + 1.1,
			self._emotesList.Position.X.Offset,
			self._emotesList.Position.Y.Scale,
			self._emotesList.Position.Y.Offset
		)
		self._listScroller = self._emotesList:FindFirstChild("ScrollingFrame") :: ScrollingFrame?
		self._listCloseButton = findButton(self._emotesList, "CloseButton")
		local searchbox = self._emotesList:FindFirstChild("Searchbox")
		local textBox = searchbox and searchbox:FindFirstChild("TextBox")
		self._listSearchBox = if textBox and textBox:IsA("TextBox") then textBox else nil
		self:_closeList(true)
	end

	self:_bindSlots()
	self:_bindButtonFeedback(self._editButton, self._frameConnections)
	self:_bindButtonFeedback(self._closeButton, self._frameConnections)
	self:_bindButtonFeedback(self._leftPageButton, self._frameConnections)
	self:_bindButtonFeedback(self._rightPageButton, self._frameConnections)
	self:_bindButtonFeedback(self._listCloseButton, self._frameConnections)

	track(self._frameConnections, self._editButton and self._editButton.Activated:Connect(function()
		self:_toggleList()
	end))
	track(self._frameConnections, self._closeButton and self._closeButton.Activated:Connect(function()
		FrameController:CloseFrame(FRAME_NAME)
	end))
	track(self._frameConnections, self._listCloseButton and self._listCloseButton.Activated:Connect(function()
		self:_closeList(false)
	end))
	track(self._frameConnections, self._leftPageButton and self._leftPageButton.Activated:Connect(function()
		self:_setPage(self._page - 1)
	end))
	track(self._frameConnections, self._rightPageButton and self._rightPageButton.Activated:Connect(function()
		self:_setPage(self._page + 1)
	end))
	track(self._frameConnections, frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if frame.Visible then
			self:_refreshWheel()
		else
			self:_closeList(true)
		end
	end))

	self:_refreshWheel()
end

function EmoteController:_bindCurrentFrame()
	local framesGui = PlayerGui:FindFirstChild(FRAMES_GUI_NAME)
	local frame = framesGui and framesGui:FindFirstChild(FRAME_NAME)
	self:_bindFrame(if frame and frame:IsA("GuiObject") then frame else nil)
end

function EmoteController:_toggleFrameFromHud()
	local currentTime = os.clock()
	if currentTime - self._lastToggleAt < TOGGLE_DEBOUNCE_SECONDS then
		return
	end

	self._lastToggleAt = currentTime
	FrameController:ToggleFrame(FRAME_NAME)
end

function EmoteController:_bindHud(hud: Instance?)
	disconnectAll(self._hudConnections)
	if not hud then
		return
	end

	local button = findHudEmotesButton(hud)
	if not button then
		track(self._hudConnections, hud.DescendantAdded:Connect(function(descendant)
			if descendant.Name == EMOTES_BUTTON_NAME then
				task.defer(function()
					if hud.Parent then
						self:_bindHud(hud)
					end
				end)
			end
		end))
		return
	end

	button.Active = true
	button.Selectable = true
	self:_bindButtonFeedback(button, self._hudConnections)
	track(self._hudConnections, button.Activated:Connect(function()
		self:_toggleFrameFromHud()
	end))
	track(self._hudConnections, button.MouseButton1Click:Connect(function()
		self:_toggleFrameFromHud()
	end))
end

function EmoteController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild(HUD_GUI_NAME))
end

function EmoteController:_startRender(player: Player, emoteId: string)
	self:_stopRender(player)

	local character = player.Character
	if not character then
		return
	end

	local sourceAnimation = EmoteConfig.GetAnimation(emoteId)
	local animator = findAnimator(character)
	if not sourceAnimation then
		warn("[EmoteController] Missing animation for emote " .. emoteId)
	end
	if not animator then
		warn("[EmoteController] Missing animator for emote " .. emoteId)
	end

	local animation = nil :: Animation?
	local track = nil :: AnimationTrack?
	if sourceAnimation and animator then
		animation = sourceAnimation:Clone()
		animation.Name = "Emote_" .. emoteId
		animation.Parent = script

		local ok, result = pcall(function()
			return animator:LoadAnimation(animation :: Animation)
		end)
		if ok and result then
			track = result
			track.Priority = Enum.AnimationPriority.Action
			track.Looped = true

			local playOk, playErr = pcall(function()
				(track :: AnimationTrack):Play(0.15, 1, 1)
			end)
			if not playOk then
				warn(("[EmoteController] Failed to play emote %s animation %s: %s"):format(
					emoteId,
					getAnimationId(animation),
					tostring(playErr)
				))
				track:Destroy()
				track = nil
			end
		else
			warn(("[EmoteController] Failed to load emote %s animation %s: %s"):format(
				emoteId,
				getAnimationId(animation),
				tostring(result)
			))
			animation:Destroy()
			animation = nil
		end
	end

	local vfx = EmoteVFX.Start(character, emoteId)
	if not (track or vfx) then
		return
	end

	self._renderByPlayer[player] = {
		track = track,
		animation = animation,
		vfx = vfx,
	}

	if player == LocalPlayer then
		self._activeLocalEmoteId = emoteId
	end
end

function EmoteController:_stopRender(player: Player)
	local state = self._renderByPlayer[player]
	if not state then
		return
	end

	stopRenderState(state)
	self._renderByPlayer[player] = nil
	if player == LocalPlayer then
		self._activeLocalEmoteId = ""
	end
end

function EmoteController:_bindStateRemote()
	if self._stateConnection then
		self._stateConnection:Disconnect()
		self._stateConnection = nil
	end
	if not self._stateRemote then
		return
	end

	self._stateConnection = self._stateRemote.OnClientEvent:Connect(function(eventName: string, payload: any)
		if typeof(payload) ~= "table" then
			return
		end

		local player = payload.player
		if not (typeof(player) == "Instance" and player:IsA("Player")) then
			return
		end

		if eventName == "Start" and typeof(payload.emoteId) == "string" then
			self:_startRender(player, payload.emoteId)
		elseif eventName == "Stop" then
			self:_stopRender(player)
		elseif eventName == "Rejected" then
			warn(("[EmoteController] Server rejected emote %s: %s"):format(
				tostring(payload.emoteId),
				tostring(payload.reason)
			))
		end
	end)
end

function EmoteController:_bindInventoryRemote()
	if self._inventoryConnection then
		self._inventoryConnection:Disconnect()
		self._inventoryConnection = nil
	end
	if not self._requestRemote then
		return
	end

	self._inventoryConnection = self._requestRemote.OnClientEvent:Connect(function(response)
		if typeof(response) ~= "table" or response.ok == true then
			return
		end

		warn(("[EmoteController] Emote inventory action %s failed: %s"):format(
			tostring(response.action),
			tostring(response.message or response.code)
		))
	end)
end

function EmoteController:_bindRemotes(): boolean
	self._requestRemote = getRemote(EmoteConfig.RequestRemoteName)
	self._stateRemote = getRemote(EmoteConfig.StateRemoteName)
	self:_bindStateRemote()
	self:_bindInventoryRemote()

	if not self._requestRemote and not self._warnedMissingRequestRemote then
		warn("[EmoteController] Waiting for ReplicatedStorage.Remotes.EmoteRequest")
		self._warnedMissingRequestRemote = true
	end
	if not self._stateRemote and not self._warnedMissingStateRemote then
		warn("[EmoteController] Waiting for ReplicatedStorage.Remotes.EmoteState")
		self._warnedMissingStateRemote = true
	end

	return self._requestRemote ~= nil and self._stateRemote ~= nil
end

function EmoteController:_startRemoteBindingLoop()
	self._remoteBindSerial += 1
	local serial = self._remoteBindSerial

	task.spawn(function()
		while serial == self._remoteBindSerial do
			if self:_bindRemotes() then
				self._requestRemote:FireServer({
					action = EmoteConfig.Actions.Snapshot,
				})
				return
			end

			task.wait(REMOTE_RETRY_SECONDS)
		end
	end)
end

function EmoteController:_bindInputs()
	ContextActionService:UnbindAction(ACTION_NAME)
	ContextActionService:BindAction(ACTION_NAME, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self:_toggleFrameFromHud()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Sink
	end, false, EmoteConfig.OpenKeyCode)

	track(self._connections, UserInputService.InputBegan:Connect(function(inputObject: InputObject, gameProcessed: boolean)
		if gameProcessed or self._activeLocalEmoteId == "" or (self._frame and self._frame.Visible) then
			return
		end
		if
			inputObject.KeyCode == Enum.KeyCode.W
			or inputObject.KeyCode == Enum.KeyCode.A
			or inputObject.KeyCode == Enum.KeyCode.S
			or inputObject.KeyCode == Enum.KeyCode.D
			or inputObject.KeyCode == Enum.KeyCode.Space
		then
			self:StopLocalEmote()
		end
	end))

	track(self._connections, UserInputService.InputChanged:Connect(function(inputObject: InputObject)
		local frame = self._frame
		if not (frame and frame.Visible) then
			return
		end

		if inputObject.UserInputType == Enum.UserInputType.MouseMovement then
			if not self._editing then
				self:_previewSlot(self:_getNearestAuthoredSlotFromPosition(getMouseGuiPosition()))
			end
		elseif inputObject.UserInputType == Enum.UserInputType.MouseWheel then
			local wheelDelta = inputObject.Position.Z
			if wheelDelta < 0 then
				self:_setPage(self._page + 1)
			elseif wheelDelta > 0 then
				self:_setPage(self._page - 1)
			end
		end
	end))
end

function EmoteController:OnStart()
	disconnectAll(self._connections)
	disconnectAll(self._hudConnections)
	disconnectAll(self._frameConnections)
	disconnectAll(self._slotConnections)
	disconnectAll(self._listConnections)
	self:_startRemoteBindingLoop()
	self:_bindInputs()
	self:_bindCurrentFrame()
	self:_bindCurrentHud()

	track(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == FRAMES_GUI_NAME then
			task.defer(function()
				self:_bindCurrentFrame()
			end)
		elseif child.Name == HUD_GUI_NAME then
			task.defer(function()
				self:_bindCurrentHud()
			end)
		end
	end))

	track(self._connections, DataController.DataReceived:Connect(function()
		self:_refreshWheel()
		if self._listOpen then
			self:_populateEmotesList()
		end
	end))

	track(self._connections, DataController.DataUpdated:Connect(function(key)
		if key == ORDER_KEY then
			self:_refreshWheel()
			if self._listOpen then
				self:_populateEmotesList()
			end
		elseif key == FAVORITES_KEY and self._listOpen then
			self:_populateEmotesList()
		end
	end))

	track(self._connections, Players.PlayerRemoving:Connect(function(player)
		self:_stopRender(player)
	end))
end

return EmoteController
