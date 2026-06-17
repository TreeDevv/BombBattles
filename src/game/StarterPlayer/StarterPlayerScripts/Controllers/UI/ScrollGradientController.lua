local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local SCROLL_TAG = "Scroll"
local ROTATE_TAG = "Rotate"
local SCROLL_DURATION_ATTRIBUTE = "ScrollDuration"
local SCROLL_START_X_ATTRIBUTE = "ScrollStartX"
local SCROLL_END_X_ATTRIBUTE = "ScrollEndX"
local SCROLL_VERTICAL_ATTRIBUTE = "ScrollVertical"

local DEFAULT_DURATION = 2
local DEFAULT_SCROLL_START_X = -1
local DEFAULT_SCROLL_END_X = 1
local MIN_DURATION = 0.05
local DEFAULT_SCROLL_DISTANCE = DEFAULT_SCROLL_END_X - DEFAULT_SCROLL_START_X
local KEYPOINT_EPSILON = 1e-4

type ScrollRecord = {
	gradient: UIGradient,
	originalOffset: Vector2,
	originalColor: ColorSequence,
	phase: number,
	connections: { RBXScriptConnection },
}

local ScrollGradientController = {}

ScrollGradientController._records = {} :: { [UIGradient]: ScrollRecord }
ScrollGradientController._connections = {} :: { RBXScriptConnection }
ScrollGradientController._renderConnection = nil :: RBXScriptConnection?
ScrollGradientController._started = false

local SCROLL_TAG_ALIASES = { SCROLL_TAG, ROTATE_TAG }
local SCROLL_ATTRIBUTES =
	{ SCROLL_DURATION_ATTRIBUTE, SCROLL_START_X_ATTRIBUTE, SCROLL_END_X_ATTRIBUTE, SCROLL_VERTICAL_ATTRIBUTE }

local function getNumberAttribute(instance: Instance, attributeName: string, fallback: number): number
	local value = instance:GetAttribute(attributeName)
	return if typeof(value) == "number" then value else fallback
end

local function getScrollDuration(gradient: UIGradient): number
	return math.max(getNumberAttribute(gradient, SCROLL_DURATION_ATTRIBUTE, DEFAULT_DURATION), MIN_DURATION)
end

local function getStartX(gradient: UIGradient): number
	return getNumberAttribute(gradient, SCROLL_START_X_ATTRIBUTE, DEFAULT_SCROLL_START_X)
end

local function getEndX(gradient: UIGradient): number
	return getNumberAttribute(gradient, SCROLL_END_X_ATTRIBUTE, DEFAULT_SCROLL_END_X)
end

local function hasScrollTagAlias(instance: Instance): boolean
	for _, tagName in ipairs(SCROLL_TAG_ALIASES) do
		if CollectionService:HasTag(instance, tagName) then
			return true
		end
	end

	return false
end

local function getWrappedTime(time: number): number
	local wrapped = time % 1
	if wrapped < 0 then
		wrapped += 1
	end

	return wrapped
end

local function getPhaseAtScrollPosition(position: number): number
	return getWrappedTime((position - DEFAULT_SCROLL_START_X) / DEFAULT_SCROLL_DISTANCE)
end

local function appendInteriorKeypoint(keypoints: { ColorSequenceKeypoint }, time: number, value: Color3)
	if time <= KEYPOINT_EPSILON or time >= 1 - KEYPOINT_EPSILON then
		return
	end

	for index, keypoint in ipairs(keypoints) do
		if math.abs(keypoint.Time - time) <= KEYPOINT_EPSILON then
			keypoints[index] = ColorSequenceKeypoint.new(time, value)
			return
		end
	end

	table.insert(keypoints, ColorSequenceKeypoint.new(time, value))
end

local function evaluateCircularColorSequence(sequence: ColorSequence, time: number): Color3
	local sourceKeypoints = sequence.Keypoints
	local keypointCount = #sourceKeypoints
	if keypointCount == 0 then
		return Color3.new(1, 1, 1)
	end
	if keypointCount == 1 then
		return sourceKeypoints[1].Value
	end

	local wrappedTime = getWrappedTime(time)
	for index = 1, keypointCount - 1 do
		local left = sourceKeypoints[index]
		local right = sourceKeypoints[index + 1]
		if wrappedTime >= left.Time and wrappedTime <= right.Time then
			local span = right.Time - left.Time
			if span <= KEYPOINT_EPSILON then
				return right.Value
			end

			return left.Value:Lerp(right.Value, (wrappedTime - left.Time) / span)
		end
	end

	local firstKeypoint = sourceKeypoints[1]
	local lastKeypoint = sourceKeypoints[keypointCount]
	local wrapSpan = (1 - lastKeypoint.Time) + firstKeypoint.Time
	if wrapSpan <= KEYPOINT_EPSILON then
		return firstKeypoint.Value
	end

	local wrapProgress = if wrappedTime >= lastKeypoint.Time
		then (wrappedTime - lastKeypoint.Time) / wrapSpan
		else ((1 - lastKeypoint.Time) + wrappedTime) / wrapSpan

	return lastKeypoint.Value:Lerp(firstKeypoint.Value, wrapProgress)
end

local function offsetColorSequence(originalColorSequence: ColorSequence, offset: number): ColorSequence
	local sourceKeypoints = originalColorSequence.Keypoints
	if #sourceKeypoints <= 1 then
		return originalColorSequence
	end

	local boundaryColor = evaluateCircularColorSequence(originalColorSequence, -offset)
	local shiftedKeypoints = {
		ColorSequenceKeypoint.new(0, boundaryColor),
	}

	for _, keypoint in ipairs(sourceKeypoints) do
		appendInteriorKeypoint(shiftedKeypoints, getWrappedTime(keypoint.Time + offset), keypoint.Value)
	end

	table.sort(shiftedKeypoints, function(left, right)
		return left.Time < right.Time
	end)

	table.insert(shiftedKeypoints, ColorSequenceKeypoint.new(1, boundaryColor))
	return ColorSequence.new(shiftedKeypoints)
end

local function getPhaseDelta(gradient: UIGradient, deltaTime: number): number
	local duration = getScrollDuration(gradient)
	local scrollDistance = getEndX(gradient) - getStartX(gradient)
	if math.abs(scrollDistance) <= KEYPOINT_EPSILON then
		return 0
	end

	return (deltaTime / duration) * (scrollDistance / DEFAULT_SCROLL_DISTANCE)
end

function ScrollGradientController:_ensureRenderConnection()
	if self._renderConnection then
		return
	end

	self._renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
		self:_updateGradients(deltaTime)
	end)
end

function ScrollGradientController:_stopRenderConnectionIfIdle()
	if next(self._records) ~= nil or not self._renderConnection then
		return
	end

	self._renderConnection:Disconnect()
	self._renderConnection = nil
end

function ScrollGradientController:_updateGradient(record: ScrollRecord, deltaTime: number)
	local gradient = record.gradient
	if not gradient:IsDescendantOf(game) or self._records[gradient] ~= record then
		return
	end

	record.phase = getWrappedTime(record.phase + getPhaseDelta(gradient, deltaTime))
	gradient.Offset = record.originalOffset
	gradient.Color = offsetColorSequence(record.originalColor, record.phase)
end

function ScrollGradientController:_updateGradients(deltaTime: number)
	for _, record in pairs(self._records) do
		self:_updateGradient(record, deltaTime)
	end
end

function ScrollGradientController:_restartGradient(gradient: UIGradient)
	local record = self._records[gradient]
	if record then
		record.phase = getPhaseAtScrollPosition(getStartX(gradient))
		gradient.Offset = record.originalOffset
		gradient.Color = offsetColorSequence(record.originalColor, record.phase)
	end
end

function ScrollGradientController:_unregisterGradient(instance: Instance)
	if not instance:IsA("UIGradient") then
		return
	end

	local gradient = instance :: UIGradient
	local record = self._records[gradient]
	if not record then
		return
	end

	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end

	gradient.Offset = record.originalOffset
	gradient.Color = record.originalColor
	self._records[gradient] = nil
	self:_stopRenderConnectionIfIdle()
end

function ScrollGradientController:_unregisterGradientIfInactive(instance: Instance)
	if not instance:IsA("UIGradient") or hasScrollTagAlias(instance) then
		return
	end

	self:_unregisterGradient(instance)
end

function ScrollGradientController:_registerGradient(instance: Instance)
	if not instance:IsA("UIGradient") then
		return
	end

	local gradient = instance :: UIGradient
	if self._records[gradient] then
		return
	end

	local record: ScrollRecord = {
		gradient = gradient,
		originalOffset = gradient.Offset,
		originalColor = gradient.Color,
		phase = 0,
		connections = {},
	}

	table.insert(record.connections, gradient.AncestryChanged:Connect(function()
		if not gradient:IsDescendantOf(game) then
			self:_unregisterGradient(gradient)
		end
	end))

	for _, attributeName in ipairs(SCROLL_ATTRIBUTES) do
		table.insert(record.connections, gradient:GetAttributeChangedSignal(attributeName):Connect(function()
			self:_restartGradient(gradient)
		end))
	end

	self._records[gradient] = record
	self:_restartGradient(gradient)
	self:_ensureRenderConnection()
end

function ScrollGradientController:OnStart()
	if self._started then
		return
	end
	self._started = true

	for _, tagName in ipairs(SCROLL_TAG_ALIASES) do
		table.insert(self._connections, CollectionService:GetInstanceAddedSignal(tagName):Connect(function(instance)
			self:_registerGradient(instance)
		end))

		table.insert(self._connections, CollectionService:GetInstanceRemovedSignal(tagName):Connect(function(instance)
			self:_unregisterGradientIfInactive(instance)
		end))

		for _, instance in ipairs(CollectionService:GetTagged(tagName)) do
			self:_registerGradient(instance)
		end
	end
end

return ScrollGradientController
