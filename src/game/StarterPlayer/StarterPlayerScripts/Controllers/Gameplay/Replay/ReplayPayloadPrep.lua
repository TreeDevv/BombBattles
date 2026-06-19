local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local ReplayAvatarFactory = require(script.Parent:WaitForChild("ReplayAvatarFactory"))

local ReplayPayloadPrep = {}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function getSnapshotCFrame(snapshot): CFrame?
	if typeof(snapshot) ~= "table" then
		return nil
	end
	if typeof(snapshot.cframe) == "CFrame" then
		return snapshot.cframe
	end
	if typeof(snapshot.position) == "Vector3" then
		return CFrame.new(snapshot.position)
	end
	return nil
end

local function getUserIdKey(value: any): string?
	if not isFiniteNumber(value) then
		return nil
	end
	return tostring(math.floor(value))
end

local function getBombKey(value: any): string?
	local valueType = typeof(value)
	if valueType == "string" and value ~= "" then
		return value
	end
	if valueType == "number" and value == value then
		return tostring(value)
	end
	return nil
end

local function getSnapshotPose(snapshot)
	if typeof(snapshot) ~= "table" then
		return nil
	end

	local pose = snapshot.pose
	if typeof(pose) ~= "table" or typeof(pose.joints) ~= "table" then
		return nil
	end
	return pose
end

function ReplayPayloadPrep.PreprocessFrames(rawFrames)
	local frames = {}
	if typeof(rawFrames) ~= "table" then
		return frames
	end

	for _, frame in ipairs(rawFrames) do
		if typeof(frame) ~= "table" or not isFiniteNumber(frame.timestamp) then
			continue
		end

		local processed = {
			timestamp = frame.timestamp,
			players = {},
			bombs = {},
		}

		if typeof(frame.players) == "table" then
			for _, playerSnapshot in ipairs(frame.players) do
				local key = getUserIdKey(playerSnapshot.userId)
				if key and getSnapshotCFrame(playerSnapshot) then
					processed.players[key] = playerSnapshot
				end
			end
		end

		if typeof(frame.bombs) == "table" then
			for index, bombSnapshot in ipairs(frame.bombs) do
				local key = getBombKey(bombSnapshot.bombId) or tostring(index)
				if getSnapshotCFrame(bombSnapshot) then
					processed.bombs[key] = bombSnapshot
				end
			end
		end

		table.insert(frames, processed)
	end

	table.sort(frames, function(left, right)
		return left.timestamp < right.timestamp
	end)

	return frames
end

function ReplayPayloadPrep.GetEventTimestamp(event): number?
	if typeof(event) ~= "table" then
		return nil
	end
	if isFiniteNumber(event.timestamp) then
		return event.timestamp
	end
	if isFiniteNumber(event.t) then
		return event.t
	end
	return nil
end

function ReplayPayloadPrep.PreprocessEvents(rawEvents, startTime: number, endTime: number, maxEvents: number?)
	local events = {}
	if typeof(rawEvents) ~= "table" then
		return events
	end
	local resolvedMaxEvents = if isFiniteNumber(maxEvents) and maxEvents > 0 then math.floor(maxEvents) else 160

	for _, event in ipairs(rawEvents) do
		if #events >= resolvedMaxEvents then
			break
		end

		local timestamp = ReplayPayloadPrep.GetEventTimestamp(event)
		if not timestamp or timestamp < startTime or timestamp > endTime then
			continue
		end
		if typeof(event.eventType) ~= "string" or event.eventType == "" then
			continue
		end

		event.__replayOrder = #events + 1
		table.insert(events, event)
	end

	table.sort(events, function(left, right)
		local leftTimestamp = ReplayPayloadPrep.GetEventTimestamp(left) or 0
		local rightTimestamp = ReplayPayloadPrep.GetEventTimestamp(right) or 0
		if leftTimestamp == rightTimestamp then
			return (left.__replayOrder or 0) < (right.__replayOrder or 0)
		end
		return leftTimestamp < rightTimestamp
	end)

	return events
end

function ReplayPayloadPrep.FindKillTimestamp(events, victimUserId: any, startTime: number, endTime: number): number
	local victimKey = getUserIdKey(victimUserId)
	local firstKillTimestamp = nil

	for _, event in ipairs(events) do
		if event.eventType ~= "PlayerKilled" then
			continue
		end

		local timestamp = ReplayPayloadPrep.GetEventTimestamp(event)
		if not timestamp then
			continue
		end

		firstKillTimestamp = firstKillTimestamp or timestamp
		local eventVictimKey = getUserIdKey(event.victimUserId)
		if victimKey and eventVictimKey == victimKey then
			return timestamp
		end
	end

	if firstKillTimestamp then
		return firstKillTimestamp
	end

	local duration = math.max(endTime - startTime, 0.1)
	return math.clamp(startTime + math.max(duration - 2, duration * 0.72), startTime, endTime)
end

function ReplayPayloadPrep.CollectExplosionPositions(events)
	local positionsBySourceId = {}
	for _, event in ipairs(events) do
		if event.eventType ~= "BombExploded" then
			continue
		end

		local position = nil
		if typeof(event.position) == "Vector3" then
			position = event.position
		elseif typeof(event.cframe) == "CFrame" then
			position = event.cframe.Position
		end
		local key = getBombKey(event.bombId) or getBombKey(event.sourceId)
		if position and key then
			positionsBySourceId[key] = position
		end
	end
	return positionsBySourceId
end

function ReplayPayloadPrep.CollectPlayerMeta(frames)
	local meta = {}
	for _, frame in ipairs(frames) do
		for key, snapshot in pairs(frame.players) do
			if not meta[key] then
				meta[key] = {
					userId = snapshot.userId,
					name = snapshot.name,
					displayName = snapshot.displayName or snapshot.name,
					isNPC = snapshot.isNPC == true,
					teamName = snapshot.teamName,
					hasPose = getSnapshotPose(snapshot) ~= nil,
					bombSkinId = snapshot.bombSkinId
						or (snapshot.animationState and snapshot.animationState.bombSkinId)
						or BombSkinConfig.DefaultSkinId,
				}
			elseif not meta[key].hasPose and getSnapshotPose(snapshot) ~= nil then
				meta[key].hasPose = true
			elseif meta[key].displayName == nil then
				meta[key].displayName = snapshot.displayName or snapshot.name
			elseif meta[key].bombSkinId == nil then
				meta[key].bombSkinId = snapshot.bombSkinId
					or (snapshot.animationState and snapshot.animationState.bombSkinId)
					or BombSkinConfig.DefaultSkinId
			end
		end
	end
	return meta
end

function ReplayPayloadPrep.PrewarmAvatarTemplates(playerMeta)
	local userIds = {}
	local seen = {}
	for _, meta in pairs(playerMeta or {}) do
		local userId = meta and meta.userId
		local key = getUserIdKey(userId)
		if key and not seen[key] and isFiniteNumber(userId) and userId > 0 then
			seen[key] = true
			local resolvedUserId = math.floor(userId)
			table.insert(userIds, resolvedUserId)
		end
	end

	ReplayAvatarFactory.PreloadCachedUserIds(userIds)
end

function ReplayPayloadPrep.CollectBombMeta(frames)
	local meta = {}
	for _, frame in ipairs(frames) do
		for key, snapshot in pairs(frame.bombs) do
			local record = meta[key]
			if not record then
				record = {
					bombId = snapshot.bombId,
					bombType = snapshot.bombType,
					bombSkinId = snapshot.bombSkinId,
					ownerUserId = snapshot.ownerUserId,
				}
				meta[key] = record
			else
				if record.bombType == nil and typeof(snapshot.bombType) == "string" and snapshot.bombType ~= "" then
					record.bombType = snapshot.bombType
				end
				if record.bombSkinId == nil and typeof(snapshot.bombSkinId) == "string" and snapshot.bombSkinId ~= "" then
					record.bombSkinId = snapshot.bombSkinId
				end
				if record.ownerUserId == nil and isFiniteNumber(snapshot.ownerUserId) then
					record.ownerUserId = snapshot.ownerUserId
				end
			end
		end
	end
	return meta
end

function ReplayPayloadPrep.FindFramePair(frames, replayTime: number, startIndex: number)
	local count = #frames
	if count == 0 then
		return nil, nil, 1, 0
	end
	if count == 1 then
		return frames[1], frames[1], 1, 0
	end

	local index = math.clamp(startIndex or 1, 1, count - 1)
	while index < count - 1 and frames[index + 1].timestamp <= replayTime do
		index += 1
	end
	while index > 1 and frames[index].timestamp > replayTime do
		index -= 1
	end

	local left = frames[index]
	local right = frames[index + 1] or left
	local span = math.max(right.timestamp - left.timestamp, 0.001)
	local alpha = math.clamp((replayTime - left.timestamp) / span, 0, 1)
	return left, right, index, alpha
end

function ReplayPayloadPrep.InterpolateSnapshot(leftSnapshot, rightSnapshot, alpha: number): (CFrame?, any)
	local leftCFrame = getSnapshotCFrame(leftSnapshot)
	local rightCFrame = getSnapshotCFrame(rightSnapshot)

	if leftCFrame and rightCFrame then
		return leftCFrame:Lerp(rightCFrame, alpha), rightSnapshot or leftSnapshot
	end
	if leftCFrame then
		return leftCFrame, leftSnapshot
	end
	if rightCFrame then
		return rightCFrame, rightSnapshot
	end
	return nil, nil
end

return ReplayPayloadPrep
