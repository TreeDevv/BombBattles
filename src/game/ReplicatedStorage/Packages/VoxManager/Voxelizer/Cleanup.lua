local Mesh = require(script.Parent.Mesh)

local Cleanup = {}

function Cleanup.cleanupVoxels(voxels, minVolume: number, shouldMerge: boolean?)
	local cleaned = table.create(#voxels)
	local removedAny = false

	for _, voxel in ipairs(voxels) do
		local volume = voxel.size.X * voxel.size.Y * voxel.size.Z
		if volume >= minVolume then
			table.insert(cleaned, voxel)
		else
			removedAny = true
		end
	end

	if shouldMerge == false then
		return if removedAny then cleaned else voxels
	end

	return Mesh.greedyMergeBlocks(cleaned)
end

function Cleanup.subdivideBlockToUniformVoxels(block, voxelSize: number)
	local voxels = {}
	local blockSize = block.size

	local snappedSizeX = math.floor(blockSize.X / voxelSize) * voxelSize
	local snappedSizeY = math.floor(blockSize.Y / voxelSize) * voxelSize
	local snappedSizeZ = math.floor(blockSize.Z / voxelSize) * voxelSize
	local snappedSize = Vector3.new(snappedSizeX, snappedSizeY, snappedSizeZ)
	local lowerCorner = block.center - snappedSize * 0.5

	local numX = math.floor(snappedSizeX / voxelSize)
	local numY = math.floor(snappedSizeY / voxelSize)
	local numZ = math.floor(snappedSizeZ / voxelSize)

	for x = 0, numX - 1 do
		for y = 0, numY - 1 do
			for z = 0, numZ - 1 do
				local center = lowerCorner
					+ Vector3.new(
						(x + 0.5) * voxelSize,
						(y + 0.5) * voxelSize,
						(z + 0.5) * voxelSize
					)
				table.insert(voxels, { center = center, size = Vector3.new(voxelSize, voxelSize, voxelSize) })
			end
		end
	end

	return voxels
end

return Cleanup
