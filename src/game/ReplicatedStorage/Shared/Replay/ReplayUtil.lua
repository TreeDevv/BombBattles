local ReplayUtil = {}

function ReplayUtil.IsFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

function ReplayUtil.IsFiniteCFrame(value: any): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end

	local components = { value:GetComponents() }
	for _, component in ipairs(components) do
		if not ReplayUtil.IsFiniteNumber(component) then
			return false
		end
	end
	return true
end

function ReplayUtil.IsFiniteVector3(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end

	return ReplayUtil.IsFiniteNumber(value.X)
		and ReplayUtil.IsFiniteNumber(value.Y)
		and ReplayUtil.IsFiniteNumber(value.Z)
end

function ReplayUtil.IsFiniteColor3(value: any): boolean
	if typeof(value) ~= "Color3" then
		return false
	end

	return ReplayUtil.IsFiniteNumber(value.R)
		and ReplayUtil.IsFiniteNumber(value.G)
		and ReplayUtil.IsFiniteNumber(value.B)
end

function ReplayUtil.GetTrustedReplayTimestamp(payload, currentTime: number): number
	if typeof(payload) == "table" and ReplayUtil.IsFiniteNumber(payload.timestamp) then
		return math.min(payload.timestamp, currentTime)
	end
	return currentTime
end

function ReplayUtil.GetTimestamp(event): number?
	if typeof(event) ~= "table" then
		return nil
	end
	if ReplayUtil.IsFiniteNumber(event.timestamp) then
		return event.timestamp
	end
	if ReplayUtil.IsFiniteNumber(event.t) then
		return event.t
	end
	return nil
end

function ReplayUtil.CountDictionaryEntries(dictionary): number
	local count = 0
	if typeof(dictionary) ~= "table" then
		return count
	end

	for _ in pairs(dictionary) do
		count += 1
	end
	return count
end

function ReplayUtil.CopyReplayValue(value: any, depth: number?, maxDepth: number?): any
	local resolvedDepth = depth or 0
	local resolvedMaxDepth = maxDepth or 3
	local valueType = typeof(value)
	if
		valueType == "number"
		or valueType == "string"
		or valueType == "boolean"
		or valueType == "Vector3"
		or valueType == "CFrame"
		or valueType == "Color3"
	then
		return value
	end

	if valueType ~= "table" or resolvedDepth >= resolvedMaxDepth then
		return nil
	end

	local copy = {}
	for key, child in pairs(value) do
		local keyType = typeof(key)
		if keyType ~= "string" and keyType ~= "number" then
			continue
		end

		local copiedChild = ReplayUtil.CopyReplayValue(child, resolvedDepth + 1, resolvedMaxDepth)
		if copiedChild ~= nil then
			copy[key] = copiedChild
		end
	end
	return copy
end

function ReplayUtil.CopyReplayEvent(event)
	if typeof(event) ~= "table" then
		return nil
	end
	return ReplayUtil.CopyReplayValue(event, 0, 3)
end

function ReplayUtil.GetReplayIdKey(value: any): string?
	local valueType = typeof(value)
	if valueType == "string" and value ~= "" then
		return value
	end
	if valueType == "number" and value == value then
		return tostring(value)
	end
	return nil
end

function ReplayUtil.GetUserId(value: any): number?
	if not (ReplayUtil.IsFiniteNumber(value) and value > 0) then
		return nil
	end
	return math.floor(value)
end

function ReplayUtil.GetUserIdKey(value: any): string?
	local userId = ReplayUtil.GetUserId(value)
	return if userId then tostring(userId) else nil
end

function ReplayUtil.GetSourceId(value: any): string?
	if typeof(value) == "string" and value ~= "" then
		return value
	end
	if ReplayUtil.IsFiniteNumber(value) then
		return tostring(value)
	end
	return nil
end

function ReplayUtil.GetString(value: any): string?
	return if typeof(value) == "string" and value ~= "" then value else nil
end

function ReplayUtil.GetPositionFromEvent(event): Vector3?
	if typeof(event) ~= "table" then
		return nil
	end
	if typeof(event.position) == "Vector3" then
		return event.position
	end
	if typeof(event.cframe) == "CFrame" then
		return event.cframe.Position
	end
	return nil
end

function ReplayUtil.ClampVectorMagnitude(value: any, maxMagnitude: number): Vector3?
	if not ReplayUtil.IsFiniteVector3(value) then
		return nil
	end
	if value.Magnitude <= maxMagnitude then
		return value
	end
	if value.Magnitude <= 0 then
		return Vector3.zero
	end
	return value.Unit * maxMagnitude
end

return table.freeze(ReplayUtil)
