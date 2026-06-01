local Mesh = {}

function Mesh.tryMergeBlocks(blockA, blockB, tolOverride: number?)
	local tol = tolOverride or 0.001
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

		local newMerged = {}
		local used = {}

		for i = 1, #merged do
			if used[i] then
				continue
			end

			local current = merged[i]
			local blockTolerance = if (current.size.X + current.size.Y + current.size.Z) / 3 < 2 then 0.01 else nil
			for j = i + 1, #merged do
				if used[j] then
					continue
				end

				local tryBlock = Mesh.tryMergeBlocks(current, merged[j], blockTolerance)
				if tryBlock then
					current = tryBlock
					used[j] = true
					changed = true
				end
			end

			table.insert(newMerged, current)
		end

		merged = newMerged
	end

	return merged
end

return Mesh
