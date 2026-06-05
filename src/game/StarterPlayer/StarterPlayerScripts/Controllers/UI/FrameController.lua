local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_TAG = "Frame"
local EXCLUSIVE_ATTRIBUTE = "Exclusive"
local BACKDROP_NAME = "FrameControllerBackdrop"

local TOP_MARGIN_PX = 32
local EDGE_MARGIN_PX = 48
local BACKDROP_TRANSPARENCY = 0.18

local OPEN_TWEEN = TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HUD_HIDE_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local HUD_SHOW_TWEEN = TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local BACKDROP_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

type FrameRecord = {
	frame: GuiObject,
	originalPosition: UDim2,
	originalVisible: boolean,
	originalZIndex: number,
	promotedZIndex: boolean,
	tween: Tween?,
	connections: { RBXScriptConnection },
}

type HudRecord = {
	guiObject: GuiObject,
	position: UDim2,
	visible: boolean,
	tween: Tween?,
}

local FrameController = {}

FrameController.FrameTag = FRAME_TAG
FrameController.ExclusiveAttribute = EXCLUSIVE_ATTRIBUTE

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

local function getScreenGui(guiObject: GuiObject): ScreenGui?
	local screenGui = guiObject:FindFirstAncestorWhichIsA("ScreenGui")
	if screenGui and screenGui:IsA("ScreenGui") then
		return screenGui
	end

	return nil
end

local function configureFullscreenScreenGui(screenGui: ScreenGui)
	screenGui.IgnoreGuiInset = true
	screenGui.ScreenInsets = Enum.ScreenInsets.None
	screenGui.ClipToDeviceSafeArea = false
	screenGui.SafeAreaCompatibility = Enum.SafeAreaCompatibility.FullscreenExtension
end

local function getAboveScreenPosition(guiObject: GuiObject, originalPosition: UDim2): UDim2
	local bottom = guiObject.AbsolutePosition.Y + guiObject.AbsoluteSize.Y
	return addPositionOffset(originalPosition, 0, -bottom - TOP_MARGIN_PX)
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

local function getBackdropZIndex(screenGui: ScreenGui, frame: GuiObject, backdrop: GuiObject): number
	local highestZIndex = frame.ZIndex

	for _, child in ipairs(screenGui:GetChildren()) do
		if child:IsA("GuiObject") and child ~= frame and child ~= backdrop then
			highestZIndex = math.max(highestZIndex, child.ZIndex)
		end
	end

	return math.max(1, highestZIndex + 1)
end

function FrameController:_ensureState()
	if self._stateReady then
		return
	end

	self._frames = {} :: { [string]: FrameRecord }
	self._records = {} :: { [GuiObject]: FrameRecord }
	self._connections = {} :: { RBXScriptConnection }
	self._exclusiveHudRecords = {} :: { [GuiObject]: HudRecord }
	self._hudTweens = {} :: { [GuiObject]: Tween }
	self._currentFrameName = nil :: string?
	self._backdrop = nil :: TextButton?
	self._backdropTween = nil :: Tween?
	self._backdropConnection = nil :: RBXScriptConnection?
	self._started = false
	self._stateReady = true
end

function FrameController:_cancelFrameTween(record: FrameRecord)
	if record.tween then
		record.tween:Cancel()
		record.tween = nil
	end
end

function FrameController:_cancelHudTween(guiObject: GuiObject)
	local tween = self._hudTweens[guiObject]
	if tween then
		tween:Cancel()
		self._hudTweens[guiObject] = nil
	end
end

function FrameController:_cancelBackdropTween()
	if self._backdropTween then
		self._backdropTween:Cancel()
		self._backdropTween = nil
	end
end

function FrameController:_restoreFrameZIndex(record: FrameRecord)
	if record.promotedZIndex and record.frame.Parent then
		record.frame.ZIndex = record.originalZIndex
	end

	record.promotedZIndex = false
end

function FrameController:_promoteFrameAboveBackdrop(record: FrameRecord, backdrop: TextButton)
	if record.frame.ZIndex <= backdrop.ZIndex then
		record.frame.ZIndex = backdrop.ZIndex + 1
		record.promotedZIndex = true
	end
end

function FrameController:_showBackdrop(screenGui: ScreenGui, record: FrameRecord)
	self:_cancelBackdropTween()
	configureFullscreenScreenGui(screenGui)

	local backdrop = self._backdrop
	if not (backdrop and backdrop.Parent) then
		backdrop = Instance.new("TextButton")
		backdrop.Name = BACKDROP_NAME
		backdrop.Active = true
		backdrop.AutoButtonColor = false
		backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
		backdrop.BorderSizePixel = 0
		backdrop.Position = UDim2.fromScale(0, 0)
		backdrop.Selectable = false
		backdrop.Size = UDim2.fromScale(1, 1)
		backdrop.Text = ""
		backdrop.Visible = false
		self._backdrop = backdrop

		self._backdropConnection = backdrop.Activated:Connect(function()
			self:CloseCurrentFrame()
		end)
	end

	backdrop.Parent = screenGui
	backdrop.ZIndex = getBackdropZIndex(screenGui, record.frame, backdrop)
	backdrop.BackgroundTransparency = 1
	backdrop.Visible = true

	self:_promoteFrameAboveBackdrop(record, backdrop)

	local tween = TweenService:Create(backdrop, BACKDROP_TWEEN, {
		BackgroundTransparency = BACKDROP_TRANSPARENCY,
	})
	self._backdropTween = tween
	tween:Play()
end

function FrameController:_hideBackdrop(instant: boolean?)
	local backdrop = self._backdrop
	if not backdrop then
		return
	end

	self:_cancelBackdropTween()

	if instant then
		backdrop.BackgroundTransparency = 1
		backdrop.Visible = false
		return
	end

	local tween = TweenService:Create(backdrop, BACKDROP_TWEEN, {
		BackgroundTransparency = 1,
	})
	self._backdropTween = tween
	tween:Play()
	tween.Completed:Once(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed or self._backdropTween ~= tween then
			return
		end

		backdrop.Visible = false
		self._backdropTween = nil
	end)
end

function FrameController:_restoreExclusiveHud(instant: boolean?)
	for guiObject, hudRecord in pairs(self._exclusiveHudRecords) do
		self:_cancelHudTween(guiObject)

		if guiObject.Parent then
			guiObject.Visible = true

			if instant then
				guiObject.Position = hudRecord.position
				guiObject.Visible = hudRecord.visible
			else
				local tween = TweenService:Create(guiObject, HUD_SHOW_TWEEN, {
					Position = hudRecord.position,
				})
				hudRecord.tween = tween
				self._hudTweens[guiObject] = tween
				tween:Play()
				tween.Completed:Once(function(playbackState)
					if playbackState ~= Enum.PlaybackState.Completed or self._hudTweens[guiObject] ~= tween then
						return
					end

					guiObject.Position = hudRecord.position
					guiObject.Visible = hudRecord.visible
					self._hudTweens[guiObject] = nil
				end)
			end
		end
	end

	self._exclusiveHudRecords = {}
end

function FrameController:_moveExclusiveHudOffscreen(screenGui: ScreenGui, frame: GuiObject)
	self:_restoreExclusiveHud(true)

	for _, child in ipairs(screenGui:GetChildren()) do
		if child:IsA("GuiObject") and child ~= frame and child ~= self._backdrop and child.Visible then
			local guiObject = child :: GuiObject
			local record: HudRecord = {
				guiObject = guiObject,
				position = guiObject.Position,
				visible = guiObject.Visible,
				tween = nil,
			}

			self._exclusiveHudRecords[guiObject] = record
			self:_cancelHudTween(guiObject)

			local targetPosition = getClosestOffscreenPosition(guiObject, record.position)
			local tween = TweenService:Create(guiObject, HUD_HIDE_TWEEN, {
				Position = targetPosition,
			})
			record.tween = tween
			self._hudTweens[guiObject] = tween
			tween:Play()
			tween.Completed:Once(function(playbackState)
				if playbackState ~= Enum.PlaybackState.Completed or self._hudTweens[guiObject] ~= tween then
					return
				end

				self._hudTweens[guiObject] = nil
			end)
		end
	end
end

function FrameController:_activateExclusive(record: FrameRecord)
	local screenGui = getScreenGui(record.frame)
	if not screenGui then
		return
	end

	self:_showBackdrop(screenGui, record)
	self:_moveExclusiveHudOffscreen(screenGui, record.frame)
end

function FrameController:_deactivateExclusive(record: FrameRecord, instant: boolean?)
	self:_restoreFrameZIndex(record)
	self:_restoreExclusiveHud(instant)
	self:_hideBackdrop(instant)
end

function FrameController:_findRegisteredName(record: FrameRecord): string?
	for name, registeredRecord in pairs(self._frames) do
		if registeredRecord == record then
			return name
		end
	end

	return nil
end

function FrameController:_registerNextAvailableFrame(name: string)
	for _, taggedInstance in ipairs(CollectionService:GetTagged(FRAME_TAG)) do
		if taggedInstance.Name == name then
			self:_registerFrame(taggedInstance)
			if self._frames[name] then
				return
			end
		end
	end
end

function FrameController:_getFrameRecord(frameName: string): FrameRecord?
	self:_ensureState()

	local record = self._frames[frameName]
	if not record then
		self:_registerNextAvailableFrame(frameName)
		record = self._frames[frameName]
	end

	return record
end

function FrameController:_unregisterFrame(instance: Instance)
	local frame = instance :: GuiObject
	local record = self._records[frame]
	if not record then
		return
	end

	local registeredName = self:_findRegisteredName(record)

	if registeredName and self._currentFrameName == registeredName then
		self:CloseFrame(registeredName, true)
	end

	self:_cancelFrameTween(record)

	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end

	if frame.Parent then
		frame.Position = record.originalPosition
		frame.Visible = record.originalVisible
		self:_restoreFrameZIndex(record)
	end

	if registeredName then
		self._frames[registeredName] = nil
	end
	self._records[frame] = nil

	if registeredName then
		self:_registerNextAvailableFrame(registeredName)
	end
end

function FrameController:_handleFrameRenamed(frame: GuiObject)
	local record = self._records[frame]
	if not record then
		return
	end

	local oldName = self:_findRegisteredName(record)
	if oldName == frame.Name then
		return
	end

	local existingRecord = self._frames[frame.Name]
	if existingRecord and existingRecord ~= record then
		warn(("[FrameController] Duplicate frame name %q ignored for %s"):format(frame.Name, frame:GetFullName()))
		self:_unregisterFrame(frame)
		return
	end

	if oldName then
		self._frames[oldName] = nil
	end
	self._frames[frame.Name] = record

	if oldName and self._currentFrameName == oldName then
		self._currentFrameName = frame.Name
	end
end

function FrameController:_registerFrame(instance: Instance)
	self:_ensureState()

	if not instance:IsA("GuiObject") or not instance:IsDescendantOf(PlayerGui) then
		return
	end

	local frame = instance :: GuiObject
	if self._records[frame] then
		return
	end

	local existingRecord = self._frames[frame.Name]
	if existingRecord and existingRecord.frame ~= frame then
		warn(("[FrameController] Duplicate frame name %q ignored for %s"):format(frame.Name, frame:GetFullName()))
		return
	end

	local record: FrameRecord = {
		frame = frame,
		originalPosition = frame.Position,
		originalVisible = frame.Visible,
		originalZIndex = frame.ZIndex,
		promotedZIndex = false,
		tween = nil,
		connections = {},
	}

	table.insert(record.connections, frame:GetPropertyChangedSignal("Name"):Connect(function()
		self:_handleFrameRenamed(frame)
	end))

	table.insert(record.connections, frame.AncestryChanged:Connect(function()
		if not frame:IsDescendantOf(PlayerGui) then
			self:_unregisterFrame(frame)
		end
	end))

	frame.Visible = false
	self._records[frame] = record
	self._frames[frame.Name] = record
end

function FrameController:OpenFrame(frameName: string): GuiObject?
	local record = self:_getFrameRecord(frameName)
	if not record then
		warn(("[FrameController] No tagged frame named %q"):format(frameName))
		return nil
	end

	local frame = record.frame
	if not frame.Parent then
		self:_unregisterFrame(frame)
		warn(("[FrameController] Tagged frame %q is no longer parented"):format(frameName))
		return nil
	end

	if self._currentFrameName == frameName and frame.Visible then
		return frame
	end

	if self._currentFrameName and self._currentFrameName ~= frameName then
		self:CloseFrame(self._currentFrameName, true)
	end

	self:_cancelFrameTween(record)
	self:_restoreFrameZIndex(record)

	frame.Position = record.originalPosition
	local hiddenPosition = getAboveScreenPosition(frame, record.originalPosition)
	local isExclusive = frame:GetAttribute(EXCLUSIVE_ATTRIBUTE) == true

	if isExclusive then
		self:_activateExclusive(record)
	else
		self:_restoreExclusiveHud(true)
		self:_hideBackdrop(true)
	end

	frame.Visible = true
	frame.Position = hiddenPosition
	self._currentFrameName = frameName

	local tween = TweenService:Create(frame, OPEN_TWEEN, {
		Position = record.originalPosition,
	})
	record.tween = tween
	tween:Play()
	tween.Completed:Once(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed or record.tween ~= tween then
			return
		end

		frame.Position = record.originalPosition
		record.tween = nil
	end)

	return frame
end

function FrameController:CloseFrame(frameName: string, instant: boolean?)
	local record = self:_getFrameRecord(frameName)
	if not record then
		return
	end

	local frame = record.frame
	local wasCurrent = self._currentFrameName == frameName
	if not frame.Visible and not instant then
		return
	end

	self:_cancelFrameTween(record)

	if wasCurrent then
		self._currentFrameName = nil
		self:_deactivateExclusive(record, instant)
	end

	if instant then
		frame.Position = record.originalPosition
		frame.Visible = false
		self:_restoreFrameZIndex(record)
		return
	end

	local hiddenPosition = getAboveScreenPosition(frame, record.originalPosition)
	local tween = TweenService:Create(frame, CLOSE_TWEEN, {
		Position = hiddenPosition,
	})
	record.tween = tween
	tween:Play()
	tween.Completed:Once(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed or record.tween ~= tween then
			return
		end

		frame.Visible = false
		frame.Position = record.originalPosition
		record.tween = nil
		self:_restoreFrameZIndex(record)
	end)
end

function FrameController:ToggleFrame(frameName: string)
	local record = self:_getFrameRecord(frameName)
	if not record then
		warn(("[FrameController] No tagged frame named %q"):format(frameName))
		return
	end

	if self._currentFrameName == frameName and record.frame.Visible then
		self:CloseFrame(frameName)
	else
		self:OpenFrame(frameName)
	end
end

function FrameController:CloseCurrentFrame(instant: boolean?)
	self:_ensureState()

	if self._currentFrameName then
		self:CloseFrame(self._currentFrameName, instant)
	end
end

function FrameController:OpenWindow(name: string, forceOpen: boolean?)
	if self._currentFrameName == name and forceOpen then
		return self._frames[name] and self._frames[name].frame or nil
	end

	return self:OpenFrame(name)
end

function FrameController:CloseWindow(name: string, instant: boolean?)
	self:CloseFrame(name, instant)
end

function FrameController:ToggleWindow(name: string)
	self:ToggleFrame(name)
end

function FrameController:CloseCurrentWindow(instant: boolean?)
	self:CloseCurrentFrame(instant)
end

function FrameController:OnStart()
	self:_ensureState()

	if self._started then
		return
	end
	self._started = true

	table.insert(self._connections, CollectionService:GetInstanceAddedSignal(FRAME_TAG):Connect(function(instance)
		self:_registerFrame(instance)
	end))

	table.insert(self._connections, CollectionService:GetInstanceRemovedSignal(FRAME_TAG):Connect(function(instance)
		self:_unregisterFrame(instance)
	end))

	for _, taggedInstance in ipairs(CollectionService:GetTagged(FRAME_TAG)) do
		self:_registerFrame(taggedInstance)
	end

	print("FrameController client initialized!")
end

return FrameController
