local ReplaySyntheticBombs = {}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteVector3(value: any): boolean
	return typeof(value) == "Vector3"
		and isFiniteNumber(value.X)
		and isFiniteNumber(value.Y)
		and isFiniteNumber(value.Z)
end

local function getEventTimestamp(event): number?
	if typeof(event) ~= "table" then
		return nil
	end
	if isFiniteNumber(event.startedAt) then
		return event.startedAt
	end
	if isFiniteNumber(event.timestamp) then
		return event.timestamp
	end
	if isFiniteNumber(event.serverTime) then
		return event.serverTime
	end
	return nil
end

function ReplaySyntheticBombs.GetCFrame(event, replayTime: number): (CFrame?, any)
	if typeof(event) ~= "table" or not isFiniteNumber(replayTime) then
		return nil, nil
	end

	local startTime = getEventTimestamp(event)
	if not isFiniteNumber(startTime) then
		return nil, nil
	end
	if replayTime < startTime - 0.01 then
		return nil, nil
	end

	local fuseEndsAt = if isFiniteNumber(event.fuseEndsAt)
		then event.fuseEndsAt
		elseif isFiniteNumber(event.fuseDuration)
		then startTime + event.fuseDuration
		else nil
	if fuseEndsAt and replayTime > fuseEndsAt + 0.15 then
		return nil, nil
	end

	local origin = if isFiniteVector3(event.origin)
		then event.origin
		elseif isFiniteVector3(event.position)
		then event.position
		else nil
	if not origin then
		return nil, nil
	end

	local velocity = if isFiniteVector3(event.velocity) then event.velocity else Vector3.zero
	local acceleration = if isFiniteVector3(event.acceleration) then event.acceleration else Vector3.zero
	local elapsed = math.max(replayTime - startTime, 0)
	local position = origin + velocity * elapsed + acceleration * (0.5 * elapsed * elapsed)
	local direction = velocity + acceleration * elapsed
	local cframe = if direction.Magnitude > 0.05
		then CFrame.lookAt(position, position + direction.Unit)
		else CFrame.new(position)

	return cframe, {
		bombId = event.bombId or event.projectileId or event.sourceId,
		ownerUserId = event.ownerUserId,
		bombType = event.bombType,
		bombSkinId = event.bombSkinId,
		fuseStartedAt = event.fuseStartedAt or startTime,
		fuseEndsAt = fuseEndsAt,
		sizeScale = event.sizeScale or event.visualScale,
		assemblyLinearVelocity = direction,
	}
end

return table.freeze(ReplaySyntheticBombs)
