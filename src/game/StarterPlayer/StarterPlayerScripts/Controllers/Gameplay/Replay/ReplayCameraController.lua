local workspace = game:GetService("Workspace")

local ReplayCameraController = {}
ReplayCameraController.__index = ReplayCameraController

local FOLLOW_BACK_DISTANCE = 11
local FOLLOW_HEIGHT = 4.5
local FOLLOW_SIDE_OFFSET = 1.35
local FOCUS_HEIGHT = 2.1

local function getHorizontalDirection(vector: Vector3?, fallback: Vector3?): Vector3
	local resolvedFallback = fallback or Vector3.new(0, 0, 1)
	if typeof(vector) ~= "Vector3" then
		return resolvedFallback
	end

	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude > 0.05 then
		return flat.Unit
	end

	return resolvedFallback
end

local function getOffsetSide(direction: Vector3): Vector3
	return Vector3.new(-direction.Z, 0, direction.X)
end

local function getSafeLookAt(cameraPosition: Vector3, focusPosition: Vector3): CFrame
	if (focusPosition - cameraPosition).Magnitude <= 0.05 then
		cameraPosition += Vector3.new(0, 2, 6)
	end
	return CFrame.lookAt(cameraPosition, focusPosition)
end

local function getFirstPlayerVisual(playerVisuals)
	for _, visual in pairs(playerVisuals) do
		return visual
	end
	return nil
end

function ReplayCameraController.new(state, deps)
	return setmetatable({
		state = state,
		deps = deps,
		currentCFrame = nil,
		currentFocus = nil,
		currentFieldOfView = nil,
	}, ReplayCameraController)
end

function ReplayCameraController:_getPlayerVisual(userId: any)
	local key = self.deps.getUserIdKey(userId)
	return if key then self.state.playerVisuals[key] else nil
end

function ReplayCameraController:_getFallbackVisual()
	return self:_getPlayerVisual(self.state.cameraUserId)
		or self:_getPlayerVisual(self.state.killerUserId)
		or self:_getPlayerVisual(self.state.playerUserId)
		or self:_getPlayerVisual(self.state.victimUserId)
		or getFirstPlayerVisual(self.state.playerVisuals)
end

function ReplayCameraController:_getTarget()
	local deps = self.deps
	local visual = self:_getFallbackVisual()
	local position = deps.getVisualPosition(visual)
	if not position then
		return getSafeLookAt(Vector3.new(0, 6, 12), Vector3.new(0, 2, 0)), Vector3.new(0, 2, 0), deps.cameraDefaultFov
	end

	local visualCFrame = deps.getVisualCFrame(visual)
	local facing = if visualCFrame then getHorizontalDirection(visualCFrame.LookVector, nil) else Vector3.new(0, 0, 1)
	local side = getOffsetSide(facing)
	local focus = position + Vector3.new(0, FOCUS_HEIGHT, 0)
	local cameraPosition = focus - facing * FOLLOW_BACK_DISTANCE + side * FOLLOW_SIDE_OFFSET + Vector3.new(0, FOLLOW_HEIGHT, 0)

	return getSafeLookAt(cameraPosition, focus), focus, deps.cameraDefaultFov
end

function ReplayCameraController:Step(deltaTime: number, _replayTime: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable

	local targetCFrame, targetFocus, targetFieldOfView = self:_getTarget()
	if not targetCFrame then
		return
	end

	local alpha = 1
	if self.currentCFrame and self.deps.isFiniteNumber(deltaTime) and deltaTime > 0 then
		alpha = math.clamp(
			1 - math.exp(-self.deps.cameraSmoothResponsiveness * math.min(deltaTime, 0.1)),
			0,
			1
		)
	end

	self.currentCFrame = if self.currentCFrame then self.currentCFrame:Lerp(targetCFrame, alpha) else targetCFrame
	self.currentFocus = if self.currentFocus then self.currentFocus:Lerp(targetFocus, alpha) else targetFocus

	local currentFieldOfView = if self.deps.isFiniteNumber(self.currentFieldOfView)
		then self.currentFieldOfView
		else camera.FieldOfView
	self.currentFieldOfView = currentFieldOfView + (targetFieldOfView - currentFieldOfView) * alpha

	camera.CFrame = self.currentCFrame
	camera.Focus = CFrame.new(self.currentFocus)
	camera.FieldOfView = self.currentFieldOfView
end

return table.freeze(ReplayCameraController)
