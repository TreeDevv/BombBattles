local Utils = require(script.Utils)
local Mesh = require(script.Mesh)
local Cleanup = require(script.Cleanup)
local Debris = require(script.Debris)

local VoxDestruct = {
	VoxelCache = nil,
}

local function subdivideAABB(aabbCenter: Vector3, halfSize: Vector3, sphereCenter: Vector3, sphereRadius: number, minSize: number)
	local blocks = {}

	if Utils.isAABBInsideSphere(aabbCenter, halfSize, sphereCenter, sphereRadius) then
		return {}
	elseif Utils.isAABBOutsideSphere(aabbCenter, halfSize, sphereCenter, sphereRadius) then
		table.insert(blocks, { center = aabbCenter, size = halfSize * 2 })
		return blocks
	else
		local fullSize = halfSize * 2

		if fullSize.X <= minSize and fullSize.Y <= minSize and fullSize.Z <= minSize then
			if (aabbCenter - sphereCenter).Magnitude >= sphereRadius then
				table.insert(blocks, { center = aabbCenter, size = fullSize })
			end
			return blocks
		else
			local newHalf = halfSize * 0.5
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local offset = Vector3.new(newHalf.X * x, newHalf.Y * y, newHalf.Z * z)
						local newCenter = aabbCenter + offset
						local subBlocks = subdivideAABB(newCenter, newHalf, sphereCenter, sphereRadius, minSize)

						for _, block in ipairs(subBlocks) do
							table.insert(blocks, block)
						end
					end
				end
			end
			return blocks
		end
	end
end

function VoxDestruct.octreeMeshSubtraction(
	target: Part,
	sphereHitbox: Part,
	minSize: number,
	finalVoxelSize: number,
	randomColor: boolean,
	debris: boolean,
	debrisAmount: number,
	debrisSizeMultiplier: number
)
	local sphereCenterWorld = sphereHitbox.Position
	local sphereRadius = sphereHitbox.Size.X / 2

	local targetCFrame = target.CFrame
	local targetSize = target.Size
	local targetHalf = targetSize * 0.5

	local localSphereCenter = targetCFrame:PointToObjectSpace(sphereCenterWorld)
	local remainingBlocks = subdivideAABB(Vector3.new(0, 0, 0), targetHalf, localSphereCenter, sphereRadius, minSize)
	local mergedBlocks = Mesh.greedyMergeBlocks(remainingBlocks)

	local originalInfo = {
		Size = target.Size,
		Color = target.Color,
		Material = target.Material,
		Transparency = target.Transparency,
		Reflectance = target.Reflectance,
	}

	target:Destroy()

	if debris then
		Debris.makeDebris(debrisAmount, sphereHitbox, originalInfo, debrisSizeMultiplier)
	end

	local meshedFolder = workspace:FindFirstChild("CurrentVoxels")
	if not meshedFolder then
		meshedFolder = Instance.new("Folder")
		meshedFolder.Name = "CurrentVoxels"
		meshedFolder.Parent = workspace
	end

	local finalVoxels = {}

	if finalVoxelSize and finalVoxelSize > minSize then
		for _, block in ipairs(mergedBlocks) do
			local subVoxels = Cleanup.subdivideBlockToUniformVoxels(block, finalVoxelSize)
			for _, voxel in ipairs(subVoxels) do
				table.insert(finalVoxels, voxel)
			end
		end
	else
		finalVoxels = mergedBlocks
	end

	finalVoxels = Cleanup.cleanupVoxels(finalVoxels, 0.5)

	for _, voxel in ipairs(finalVoxels) do
		local worldCFrame = targetCFrame * CFrame.new(voxel.center)

		local part = VoxDestruct.VoxelCache:GetPart()
		part.Size = voxel.size
		part.CFrame = worldCFrame
		part.Anchored = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Transparency = originalInfo.Transparency
		part.Reflectance = originalInfo.Reflectance

		if randomColor then
			part.BrickColor = BrickColor.Random()
		else
			part.Color = originalInfo.Color
		end

		part.Material = originalInfo.Material
		part.Name = "MeshedVoxel"
		part.Parent = meshedFolder
	end

	return finalVoxels
end

function VoxDestruct.subtractHitbox(
	sphereHitbox: Part,
	minSize: number,
	finalVoxelSize: number,
	randomColor: boolean,
	debris: boolean,
	debrisAmount: number,
	ignore: { Instance },
	voxelCache,
	debrisSizeMultiplier: number,
	include: { Instance }?
)
	VoxDestruct.VoxelCache = voxelCache

	local overlapParams = OverlapParams.new()
	if include and #include > 0 then
		overlapParams.FilterDescendantsInstances = include
		overlapParams.FilterType = Enum.RaycastFilterType.Include
	else
		overlapParams.FilterDescendantsInstances = { sphereHitbox, table.unpack(ignore) }
		overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	end

	local totalDebris = 0
	local targets = workspace:GetPartBoundsInRadius(sphereHitbox.Position, sphereHitbox.Size.X / 2, overlapParams)
	for _, object in ipairs(targets) do
		if not object:IsA("BasePart") or object == sphereHitbox or object.Locked then
			continue
		end

		totalDebris += debrisAmount

		local targetDebrisAmount = debrisAmount
		if totalDebris > debrisAmount * 4 then
			targetDebrisAmount = 0
		end

		VoxDestruct.octreeMeshSubtraction(
			object,
			sphereHitbox,
			minSize,
			finalVoxelSize,
			randomColor,
			debris,
			targetDebrisAmount,
			debrisSizeMultiplier
		)
	end

	sphereHitbox:Destroy()
end

return VoxDestruct
