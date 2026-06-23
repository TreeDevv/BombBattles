local Mesh = {}

local DEFAULT_TOLERANCE = 0.001
local KEY_TOLERANCE = 0.001
local SMALL_BLOCK_TOLERANCE = 0.01
local SMALL_BLOCK_SIZE = 2

local function getBlockTolerance(block): number
	return if (block.size.X + block.size.Y + block.size.Z) / 3 < SMALL_BLOCK_SIZE
		then SMALL_BLOCK_TOLERANCE
		else DEFAULT_TOLERANCE
end

local function keyNumber(value: number): string
	return tostring(math.floor((value / KEY_TOLERANCE) + 0.5))
end

local function makeKey(a: number, b: number, c: number, d: number): string
	return keyNumber(a) .. "|" .. keyNumber(b) .. "|" .. keyNumber(c) .. "|" .. keyNumber(d)
end

local function getBounds(block)
	local halfSize = block.size * 0.5
	local min = block.center - halfSize
	local max = block.center + halfSize
	return min.X, min.Y, min.Z, max.X, max.Y, max.Z
end

local function makeBlock(minX: number, minY: number, minZ: number, maxX: number, maxY: number, maxZ: number)
	local min = Vector3.new(minX, minY, minZ)
	local max = Vector3.new(maxX, maxY, maxZ)
	return {
		center = (min + max) * 0.5,
		size = max - min,
	}
end

local function getAxisEntry(block, axis: string)
	local minX, minY, minZ, maxX, maxY, maxZ = getBounds(block)
	if axis == "X" then
		return {
			min = minX,
			max = maxX,
			minX = minX,
			minY = minY,
			minZ = minZ,
			maxX = maxX,
			maxY = maxY,
			maxZ = maxZ,
			tolerance = getBlockTolerance(block),
			key = makeKey(minY, maxY, minZ, maxZ),
		}
	elseif axis == "Y" then
		return {
			min = minY,
			max = maxY,
			minX = minX,
			minY = minY,
			minZ = minZ,
			maxX = maxX,
			maxY = maxY,
			maxZ = maxZ,
			tolerance = getBlockTolerance(block),
			key = makeKey(minX, maxX, minZ, maxZ),
		}
	end

	return {
		min = minZ,
		max = maxZ,
		minX = minX,
		minY = minY,
		minZ = minZ,
		maxX = maxX,
		maxY = maxY,
		maxZ = maxZ,
		tolerance = getBlockTolerance(block),
		key = makeKey(minX, maxX, minY, maxY),
	}
end

local function entryToBlock(entry, axis: string)
	if axis == "X" then
		return makeBlock(entry.min, entry.minY, entry.minZ, entry.max, entry.maxY, entry.maxZ)
	elseif axis == "Y" then
		return makeBlock(entry.minX, entry.min, entry.minZ, entry.maxX, entry.max, entry.maxZ)
	end

	return makeBlock(entry.minX, entry.minY, entry.min, entry.maxX, entry.maxY, entry.max)
end

local function mergeAlongAxis(blocks, axis: string)
	local groups = {}
	local groupList = {}

	for _, block in ipairs(blocks) do
		local entry = getAxisEntry(block, axis)
		local group = groups[entry.key]
		if not group then
			group = {}
			groups[entry.key] = group
			table.insert(groupList, group)
		end
		table.insert(group, entry)
	end

	local merged = table.create(#blocks)
	local changed = false

	for _, group in ipairs(groupList) do
		table.sort(group, function(a, b)
			return a.min < b.min
		end)

		local current = nil
		local emittedCount = 0
		for _, entry in ipairs(group) do
			if not current then
				current = entry
				continue
			end

			local tolerance = math.max(current.tolerance, entry.tolerance)
			if entry.min <= current.max + tolerance then
				if entry.max > current.max then
					current.max = entry.max
				end
				current.tolerance = tolerance
				changed = true
			else
				table.insert(merged, entryToBlock(current, axis))
				emittedCount += 1
				current = entry
			end
		end

		if current then
			table.insert(merged, entryToBlock(current, axis))
			emittedCount += 1
		end
		if emittedCount < #group then
			changed = true
		end
	end

	return merged, changed
end

function Mesh.tryMergeBlocks(blockA, blockB, tolOverride: number?)
	local tol = tolOverride or DEFAULT_TOLERANCE
	local aMin = blockA.center - blockA.size * 0.5
	local aMax = blockA.center + blockA.size * 0.5
	local bMin = blockB.center - blockB.size * 0.5
	local bMax = blockB.center + blockB.size * 0.5

	local function checkTol(a, b)
		return math.abs(a - b) < tol
	end

	if checkTol(aMin.Y, bMin.Y) and checkTol(aMax.Y, bMax.Y) and checkTol(aMin.Z, bMin.Z) and checkTol(aMax.Z, bMax.Z) then
		if math.abs(aMax.X - bMin.X) < tol or math.abs(bMax.X - aMin.X) < tol then
			local newMinX = math.min(aMin.X, bMin.X)
			local newMaxX = math.max(aMax.X, bMax.X)
			local newMin = Vector3.new(newMinX, aMin.Y, aMin.Z)
			local newMax = Vector3.new(newMaxX, aMax.Y, aMax.Z)
			return { center = (newMin + newMax) * 0.5, size = newMax - newMin }
		end
	end

	if checkTol(aMin.X, bMin.X) and checkTol(aMax.X, bMax.X) and checkTol(aMin.Z, bMin.Z) and checkTol(aMax.Z, bMax.Z) then
		if math.abs(aMax.Y - bMin.Y) < tol or math.abs(bMax.Y - aMin.Y) < tol then
			local newMinY = math.min(aMin.Y, bMin.Y)
			local newMaxY = math.max(aMax.Y, bMax.Y)
			local newMin = Vector3.new(aMin.X, newMinY, aMin.Z)
			local newMax = Vector3.new(aMax.X, newMaxY, aMax.Z)
			return { center = (newMin + newMax) * 0.5, size = newMax - newMin }
		end
	end

	if checkTol(aMin.X, bMin.X) and checkTol(aMax.X, bMax.X) and checkTol(aMin.Y, bMin.Y) and checkTol(aMax.Y, bMax.Y) then
		if math.abs(aMax.Z - bMin.Z) < tol or math.abs(bMax.Z - aMin.Z) < tol then
			local newMinZ = math.min(aMin.Z, bMin.Z)
			local newMaxZ = math.max(aMax.Z, bMax.Z)
			local newMin = Vector3.new(aMin.X, aMin.Y, newMinZ)
			local newMax = Vector3.new(aMax.X, aMax.Y, newMaxZ)
			return { center = (newMin + newMax) * 0.5, size = newMax - newMin }
		end
	end

	return nil
end

function Mesh.greedyMergeBlocks(blocks)
	local merged = blocks
	local changed = true

	while changed do
		changed = false
		local nextMerged, axisChanged = mergeAlongAxis(merged, "X")
		merged = nextMerged
		changed = changed or axisChanged

		nextMerged, axisChanged = mergeAlongAxis(merged, "Y")
		merged = nextMerged
		changed = changed or axisChanged

		nextMerged, axisChanged = mergeAlongAxis(merged, "Z")
		merged = nextMerged
		changed = changed or axisChanged
	end

	return merged
end

return Mesh
