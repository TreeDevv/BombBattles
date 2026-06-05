local workspace = game:GetService("Workspace")

local ReplayCameraController = {}
ReplayCameraController.__index = ReplayCameraController

local function getFirstVisiblePlayerPosition(state, deps): Vector3?
	for _, visual in pairs(state.playerVisuals) do
		local position = deps.getVisualPosition(visual)
		if position then
			return position
		end
	end
	return nil
end

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

function ReplayCameraController:_getSourceBombVisual()
	local sourceKey = self.deps.getBombKey(self.state.sourceId)
	if sourceKey then
		return self.state.bombVisuals[sourceKey], sourceKey
	end
	return nil, nil
end

function ReplayCameraController:_getPhase(replayTime: number): string
	local deps = self.deps
	local killTimestamp = if deps.isFiniteNumber(self.state.killTimestamp) then self.state.killTimestamp else self.state.endTime
	if replayTime <= self.state.startTime + deps.killcamKillerIntroSeconds then
		return "KillerFollow"
	end

	if replayTime >= killTimestamp - deps.killcamImpactFocusSeconds then
		return "ImpactFocus"
	end

	local bombVisual = self:_getSourceBombVisual()
	if
		bombVisual
		and deps.getVisualPosition(bombVisual)
		and replayTime <= killTimestamp - deps.killcamBombFollowEndLead
	then
		return "BombFollow"
	end

	return "KillerFollow"
end

function ReplayCameraController:_getFallbackTarget()
	local deps = self.deps
	local victimPosition = deps.getVisualPosition(self:_getPlayerVisual(self.state.victimUserId))
	local killerPosition = deps.getVisualPosition(self:_getPlayerVisual(self.state.killerUserId))
	local focus = victimPosition or killerPosition or getFirstVisiblePlayerPosition(self.state, deps) or Vector3.zero
	if victimPosition and killerPosition then
		focus = victimPosition:Lerp(killerPosition, 0.42)
	end

	local direction = Vector3.new(0.65, 0, 1).Unit
	if victimPosition and killerPosition then
		direction = getHorizontalDirection(victimPosition - killerPosition, direction)
	end

	local lookAt = focus + Vector3.new(0, 1.8, 0)
	local cameraPosition = lookAt - direction * 18 + Vector3.new(0, 8, 0)
	return getSafeLookAt(cameraPosition, lookAt), lookAt, deps.cameraDefaultFov
end

function ReplayCameraController:_getKillerFollowTarget()
	local deps = self.deps
	local killerVisual = self:_getPlayerVisual(self.state.killerUserId)
	local victimVisual = self:_getPlayerVisual(self.state.victimUserId)
	local killerPosition = deps.getVisualPosition(killerVisual)
	local victimPosition = deps.getVisualPosition(victimVisual)

	if not (killerPosition or victimPosition) then
		return self:_getFallbackTarget()
	end

	local fallbackDirection = if victimPosition and killerPosition
		then getHorizontalDirection(victimPosition - killerPosition, Vector3.new(0, 0, 1))
		else Vector3.new(0, 0, 1)
	local killerCFrame = deps.getVisualCFrame(killerVisual)
	local facing = if killerCFrame then getHorizontalDirection(killerCFrame.LookVector, fallbackDirection) else fallbackDirection
	local focusBase = killerPosition or victimPosition or Vector3.zero
	local focus = if victimPosition and killerPosition then killerPosition:Lerp(victimPosition, 0.28) else focusBase
	local side = getOffsetSide(facing)
	local lookAt = focus + Vector3.new(0, 2.1, 0)
	local cameraPosition = focusBase - facing * 13 + side * 2 + Vector3.new(0, 6.4, 0)

	return getSafeLookAt(cameraPosition, lookAt), lookAt, deps.cameraDefaultFov
end

function ReplayCameraController:_getBombFollowTarget()
	local deps = self.deps
	local bombVisual = self:_getSourceBombVisual()
	local bombPosition = deps.getVisualPosition(bombVisual)
	if not bombPosition then
		return self:_getKillerFollowTarget()
	end

	local killerPosition = deps.getVisualPosition(self:_getPlayerVisual(self.state.killerUserId))
	local victimPosition = deps.getVisualPosition(self:_getPlayerVisual(self.state.victimUserId))
	local impactPosition = self.state.impactPosition
	local bombCFrame = deps.getVisualCFrame(bombVisual)
	local direction = if impactPosition
		then getHorizontalDirection(impactPosition - bombPosition, nil)
		elseif killerPosition
		then getHorizontalDirection(bombPosition - killerPosition, nil)
		elseif bombCFrame
		then getHorizontalDirection(bombCFrame.LookVector, nil)
		else Vector3.new(0, 0, 1)

	local side = getOffsetSide(direction)
	local focus = bombPosition:Lerp(impactPosition or victimPosition or bombPosition, 0.18) + Vector3.new(0, 0.7, 0)
	local cameraPosition = bombPosition - direction * 8 + side * 1.8 + Vector3.new(0, 3.4, 0)

	return getSafeLookAt(cameraPosition, focus), focus, deps.cameraBombFov
end

function ReplayCameraController:_getImpactTarget()
	local deps = self.deps
	local victimPosition = deps.getVisualPosition(self:_getPlayerVisual(self.state.victimUserId))
	local killerPosition = deps.getVisualPosition(self:_getPlayerVisual(self.state.killerUserId))
	local impactPosition = self.state.impactPosition
	local focus = impactPosition or victimPosition or killerPosition or getFirstVisiblePlayerPosition(self.state, deps) or Vector3.zero
	if impactPosition and victimPosition then
		focus = impactPosition:Lerp(victimPosition, 0.35)
	end

	local direction = Vector3.new(0.65, 0, 1).Unit
	if killerPosition and focus then
		direction = getHorizontalDirection(focus - killerPosition, direction)
	elseif victimPosition and impactPosition then
		direction = getHorizontalDirection(victimPosition - impactPosition, direction)
	end

	local side = getOffsetSide(direction)
	local lookAt = focus + Vector3.new(0, 2.0, 0)
	local cameraPosition = focus - direction * 19 + side * 2.4 + Vector3.new(0, 8.8, 0)

	return getSafeLookAt(cameraPosition, lookAt), lookAt, deps.cameraImpactFov
end

function ReplayCameraController:_getTarget(replayTime: number)
	local phase = self:_getPhase(replayTime)
	if phase == "BombFollow" then
		return self:_getBombFollowTarget()
	elseif phase == "ImpactFocus" then
		return self:_getImpactTarget()
	end

	return self:_getKillerFollowTarget()
end

function ReplayCameraController:Step(deltaTime: number, replayTime: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable

	local targetCFrame, targetFocus, targetFieldOfView = self:_getTarget(replayTime)
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
