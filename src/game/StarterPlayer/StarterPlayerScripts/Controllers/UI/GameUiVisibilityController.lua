local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local EDGE_MARGIN_PX = 48
local HIDE_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local SHOW_TWEEN = TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local TOPBAR_PREFIX = "Topbar"
local FRAME_BACKDROP_NAME = "FrameControllerBackdrop"

local EXCLUDED_SCREEN_GUIS = {
	Freecam = true,
	["Mobile/ConsoleShiftLock"] = true,
	ScreenEffects = true,
}

local TOUCH_CONTROL_EXCLUSIONS = {
	Buttons = true,
	MobileButtons = true,
}

type UiRecord = {
	guiObject: GuiObject,
	position: UDim2,
	visible: boolean,
	hiddenPosition: UDim2,
	tween: Tween?,
	restoring: boolean,
}

type HiddenScope = {
	exclusions: { Instance },
	includeTopbar: boolean,
	includeScreenEffects: boolean,
	hideByVisibility: boolean,
	includeFrameBackdrop: boolean,
}

local GameUiVisibilityController = {}

GameUiVisibilityController._hidden = false
GameUiVisibilityController._manualHidden = false
GameUiVisibilityController._hiddenScopes = {} :: { [string]: HiddenScope }
GameUiVisibilityController._started = false
GameUiVisibilityController._connections = {} :: { RBXScriptConnection }
GameUiVisibilityController._objectConnections = {} :: { [Instance]: { RBXScriptConnection } }
GameUiVisibilityController._records = {} :: { [GuiObject]: UiRecord }
GameUiVisibilityController._enforceQueued = false
GameUiVisibilityController._restoring = false
GameUiVisibilityController._activeExclusions = {} :: { Instance }
GameUiVisibilityController._includeTopbar = false
GameUiVisibilityController._includeScreenEffects = false
GameUiVisibilityController._hideByVisibility = false
GameUiVisibilityController._includeFrameBackdrop = false

local function addPositionOffset(position: UDim2, xOffset: number, yOffset: number): UDim2
	return UDim2.new(
		position.X.Scale,
		position.X.Offset + xOffset,
		position.Y.Scale,
		position.Y.Offset + yOffset
	)
end

local function getViewportSize(): Vector2
	local camera = workspace.CurrentCamera
	if camera then
		return camera.ViewportSize
	end

	return Vector2.new(1920, 1080)
end

local function getClosestOffscreenPosition(guiObject: GuiObject, originalPosition: UDim2): UDim2
	local viewportSize = getViewportSize()
	local absolutePosition = guiObject.AbsolutePosition
	local absoluteSize = guiObject.AbsoluteSize
	local center = absolutePosition + (absoluteSize / 2)

	local distances = {
		left = center.X,
		right = viewportSize.X - center.X,
		top = center.Y,
		bottom = viewportSize.Y - center.Y,
	}

	local closestSide = "left"
	local closestDistance = distances.left
	for side, distance in pairs(distances) do
		if distance < closestDistance then
			closestSide = side
			closestDistance = distance
		end
	end

	if closestSide == "left" then
		return addPositionOffset(originalPosition, -absolutePosition.X - absoluteSize.X - EDGE_MARGIN_PX, 0)
	elseif closestSide == "right" then
		return addPositionOffset(originalPosition, viewportSize.X - absolutePosition.X + EDGE_MARGIN_PX, 0)
	elseif closestSide == "top" then
		return addPositionOffset(originalPosition, 0, -absolutePosition.Y - absoluteSize.Y - EDGE_MARGIN_PX)
	end

	return addPositionOffset(originalPosition, 0, viewportSize.Y - absolutePosition.Y + EDGE_MARGIN_PX)
end

local function isSameUDim2(left: UDim2, right: UDim2): boolean
	return left.X.Scale == right.X.Scale
		and left.X.Offset == right.X.Offset
		and left.Y.Scale == right.Y.Scale
		and left.Y.Offset == right.Y.Offset
end

local function startsWith(value: string, prefix: string): boolean
	return string.sub(value, 1, #prefix) == prefix
end

function GameUiVisibilityController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function GameUiVisibilityController:_trackObjectConnection(instance: Instance, connection: RBXScriptConnection)
	local connections = self._objectConnections[instance]
	if not connections then
		connections = {}
		self._objectConnections[instance] = connections
	end

	table.insert(connections, connection)
end

function GameUiVisibilityController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}

	for _, connections in pairs(self._objectConnections) do
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end
	self._objectConnections = {}
end

function GameUiVisibilityController:_cancelTween(record: UiRecord)
	if record.tween then
		record.tween:Cancel()
		record.tween = nil
	end
end

function GameUiVisibilityController:_isExcludedScreenGui(screenGui: ScreenGui): boolean
	return (EXCLUDED_SCREEN_GUIS[screenGui.Name] == true and not (self._includeScreenEffects and screenGui.Name == "ScreenEffects"))
		or (not self._includeTopbar and startsWith(screenGui.Name, TOPBAR_PREFIX))
end

function GameUiVisibilityController:_isExcludedGuiObject(guiObject: GuiObject): boolean
	for _, excludedRoot in ipairs(self._activeExclusions) do
		if guiObject == excludedRoot or guiObject:IsDescendantOf(excludedRoot) then
			return true
		end
	end
	return false
end

function GameUiVisibilityController:_isTouchControlException(guiObject: GuiObject): boolean
	local screenGui = guiObject:FindFirstAncestorWhichIsA("ScreenGui")
	return UserInputService.TouchEnabled
		and screenGui ~= nil
		and screenGui.Name == "HUD"
		and TOUCH_CONTROL_EXCLUSIONS[guiObject.Name] == true
end

function GameUiVisibilityController:_isHideCandidate(guiObject: GuiObject): boolean
	if guiObject.Name == FRAME_BACKDROP_NAME and not self._includeFrameBackdrop then
		return false
	end
	if self:_isExcludedGuiObject(guiObject) then
		return false
	end
	if self:_isTouchControlException(guiObject) then
		return false
	end

	local screenGui = guiObject:FindFirstAncestorWhichIsA("ScreenGui")
	if not screenGui or not screenGui.Enabled or self:_isExcludedScreenGui(screenGui) then
		return false
	end

	return guiObject.Parent == screenGui
end

function GameUiVisibilityController:_bindScreenGui(screenGui: ScreenGui)
	if self._objectConnections[screenGui] then
		return
	end

	self:_trackObjectConnection(screenGui, screenGui.ChildAdded:Connect(function(child)
		if child:IsA("GuiObject") then
			self:_bindGuiObject(child)
		end
		self:_scheduleHiddenEnforce()
	end))
	self:_trackObjectConnection(screenGui, screenGui:GetPropertyChangedSignal("Enabled"):Connect(function()
		self:_scheduleHiddenEnforce()
	end))

	for _, child in ipairs(screenGui:GetChildren()) do
		if child:IsA("GuiObject") then
			self:_bindGuiObject(child)
		end
	end
end

function GameUiVisibilityController:_bindGuiObject(guiObject: GuiObject)
	if self._objectConnections[guiObject] then
		return
	end

	self:_trackObjectConnection(guiObject, guiObject:GetPropertyChangedSignal("Visible"):Connect(function()
		local record = self._records[guiObject]
		if record and not self._hidden and not self._restoring and not record.restoring then
			record.visible = guiObject.Visible
		end
		if record and not guiObject.Visible then
			self:_cancelTween(record)
		end
		self:_scheduleHiddenEnforce()
	end))
	self:_trackObjectConnection(guiObject, guiObject:GetPropertyChangedSignal("Position"):Connect(function()
		if self._hidden and not self._restoring then
			self:_scheduleHiddenEnforce()
		end
	end))
	self:_trackObjectConnection(guiObject, guiObject.AncestryChanged:Connect(function()
		if not guiObject:IsDescendantOf(PlayerGui) then
			local record = self._records[guiObject]
			if record then
				self:_cancelTween(record)
				self._records[guiObject] = nil
			end
		end
	end))
end

function GameUiVisibilityController:_bindPlayerGui()
	for _, child in ipairs(PlayerGui:GetChildren()) do
		if child:IsA("ScreenGui") then
			self:_bindScreenGui(child)
		end
	end
end

function GameUiVisibilityController:_restoreRecord(guiObject: GuiObject, record: UiRecord, instant: boolean?)
	self:_cancelTween(record)
	record.restoring = true

	if not guiObject.Parent then
		record.restoring = false
		self._records[guiObject] = nil
		return
	end

	if record.visible then
		guiObject.Visible = true
	end

	if instant then
		guiObject.Position = record.position
		guiObject.Visible = record.visible
		record.restoring = false
		self._records[guiObject] = nil
		return
	end

	local tween = TweenService:Create(guiObject, SHOW_TWEEN, {
		Position = record.position,
	})
	record.tween = tween
	tween:Play()
	tween.Completed:Once(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed or record.tween ~= tween then
			return
		end

		guiObject.Position = record.position
		guiObject.Visible = record.visible
		record.tween = nil
		record.restoring = false
		if not self._hidden or not self:_isHideCandidate(guiObject) then
			self._records[guiObject] = nil
		end
	end)
end

function GameUiVisibilityController:_restoreRecordsNoLongerHidden(instant: boolean?)
	for guiObject, record in pairs(self._records) do
		if not self:_isHideCandidate(guiObject) then
			self:_restoreRecord(guiObject, record, instant)
		end
	end
end

function GameUiVisibilityController:_hideObject(guiObject: GuiObject, instant: boolean?)
	if not self:_isHideCandidate(guiObject) or not guiObject.Visible then
		return
	end

	local record = self._records[guiObject]
	if not record then
		local originalPosition = guiObject.Position
		record = {
			guiObject = guiObject,
			position = originalPosition,
			visible = guiObject.Visible,
			hiddenPosition = getClosestOffscreenPosition(guiObject, originalPosition),
			tween = nil,
			restoring = false,
		}
		self._records[guiObject] = record
	end

	if isSameUDim2(guiObject.Position, record.hiddenPosition) then
		if self._hideByVisibility then
			guiObject.Visible = false
		end
		return
	end
	record.restoring = false
	self:_cancelTween(record)

	if self._hideByVisibility then
		guiObject.Position = record.hiddenPosition
		guiObject.Visible = false
		return
	end

	if instant then
		guiObject.Position = record.hiddenPosition
		return
	end

	local tween = TweenService:Create(guiObject, HIDE_TWEEN, {
		Position = record.hiddenPosition,
	})
	record.tween = tween
	tween:Play()
	tween.Completed:Once(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed or record.tween ~= tween then
			return
		end

		record.tween = nil
	end)
end

function GameUiVisibilityController:_enforceHidden(instant: boolean?)
	self:_bindPlayerGui()
	self:_restoreRecordsNoLongerHidden(instant)

	for _, child in ipairs(PlayerGui:GetChildren()) do
		if not child:IsA("ScreenGui") or self:_isExcludedScreenGui(child) then
			continue
		end

		for _, guiChild in ipairs(child:GetChildren()) do
			if guiChild:IsA("GuiObject") then
				self:_hideObject(guiChild, instant)
			end
		end
	end
end

function GameUiVisibilityController:_scheduleHiddenEnforce()
	if not self._hidden or self._enforceQueued or self._restoring then
		return
	end

	self._enforceQueued = true
	task.defer(function()
		self._enforceQueued = false
		if self._hidden and not self._restoring then
			self:_enforceHidden(false)
		end
	end)
end

function GameUiVisibilityController:_restoreAll(instant: boolean?)
	self._restoring = true

	for guiObject, record in pairs(self._records) do
		self:_restoreRecord(guiObject, record, instant)
	end

	self._restoring = false
end

function GameUiVisibilityController:_syncHiddenOptions()
	local exclusions = {}
	local includeTopbar = false
	local includeScreenEffects = false
	local hideByVisibility = false
	local includeFrameBackdrop = false

	for _, scope in pairs(self._hiddenScopes) do
		for _, excludedRoot in ipairs(scope.exclusions) do
			if excludedRoot.Parent then
				table.insert(exclusions, excludedRoot)
			end
		end
		includeTopbar = includeTopbar or scope.includeTopbar == true
		includeScreenEffects = includeScreenEffects or scope.includeScreenEffects == true
		hideByVisibility = hideByVisibility or scope.hideByVisibility == true
		includeFrameBackdrop = includeFrameBackdrop or scope.includeFrameBackdrop == true
	end

	self._activeExclusions = exclusions
	self._includeTopbar = includeTopbar
	self._includeScreenEffects = includeScreenEffects
	self._hideByVisibility = hideByVisibility
	self._includeFrameBackdrop = includeFrameBackdrop
end

function GameUiVisibilityController:_hasHiddenScope(): boolean
	for _ in pairs(self._hiddenScopes) do
		return true
	end
	return false
end

function GameUiVisibilityController:_applyHiddenState(instant: boolean?)
	local nextHidden = self._manualHidden or self:_hasHiddenScope()
	local changed = self._hidden ~= nextHidden

	self._hidden = nextHidden
	self:_syncHiddenOptions()
	self:_bindPlayerGui()

	if self._hidden then
		if changed then
			FrameController:CloseCurrentFrame(true)
		end
		self:_enforceHidden(instant)
	elseif changed then
		self:_restoreAll(instant)
	end
end

function GameUiVisibilityController:IsHidden(): boolean
	return self._hidden
end

function GameUiVisibilityController:SetHidden(hidden: boolean, instant: boolean?)
	self._manualHidden = hidden
	self:_applyHiddenState(instant)
end

function GameUiVisibilityController:ToggleHidden()
	self:SetHidden(not self._manualHidden)
	return self._manualHidden
end

function GameUiVisibilityController:PushHiddenScope(scopeId: string, options: { [string]: any }?, instant: boolean?)
	if typeof(scopeId) ~= "string" or scopeId == "" then
		return
	end

	local exclusions = {}
	for _, excludedRoot in ipairs(options and options.Exclusions or {}) do
		if typeof(excludedRoot) == "Instance" then
			table.insert(exclusions, excludedRoot)
		end
	end

	self._hiddenScopes[scopeId] = {
		exclusions = exclusions,
		includeTopbar = options and options.IncludeTopbar == true or false,
		includeScreenEffects = options and options.IncludeScreenEffects == true or false,
		hideByVisibility = options and options.HideByVisibility == true or false,
		includeFrameBackdrop = options and options.IncludeFrameBackdrop == true or false,
	}
	self:_applyHiddenState(instant)
end

function GameUiVisibilityController:PopHiddenScope(scopeId: string, instant: boolean?)
	if typeof(scopeId) ~= "string" or scopeId == "" or not self._hiddenScopes[scopeId] then
		return
	end

	self._hiddenScopes[scopeId] = nil
	self:_applyHiddenState(instant)
end

function GameUiVisibilityController:OnStart()
	if self._started then
		return
	end
	self._started = true

	self:_disconnectAll()
	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child:IsA("ScreenGui") then
			self:_bindScreenGui(child)
			self:_scheduleHiddenEnforce()
		end
	end))
	self:_trackConnection(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		self:_scheduleHiddenEnforce()
	end))

	self:_bindPlayerGui()
end

return GameUiVisibilityController
