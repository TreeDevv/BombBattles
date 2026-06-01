--[[
	Octree Meshing & Greedy Merging Module / Voxelizer by @LxckyDev

	This module subtracts a spherical part from target parts using octree
	subdivision, then uses greedy merging to combine adjacent remaining blocks.
]]

local Voxelizer = require(script.Voxelizer)
local ObjectCache = require(script.ObjectCache)

local VoxManager = {
	VoxelCache = nil,
	VoxelFolder = nil,
	DebrisSizeMultiplier = 0.3,
}

function VoxManager:_createVoxelCache()
	local template = Instance.new("Part")
	template.Anchored = true

	VoxManager.VoxelFolder = Instance.new("Folder")
	VoxManager.VoxelFolder.Name = "VoxelCache"
	VoxManager.VoxelFolder.Parent = workspace

	VoxManager.VoxelCache = ObjectCache.new(template, 10000, VoxManager.VoxelFolder)
	VoxManager.VoxelCache:SetExpandAmount(100)

	template:Destroy()
end

function VoxManager:voxelize(
	sphereHitbox: Part,
	minimumVoxelSize: number,
	finalVoxelSize: number,
	randomColor: boolean,
	debris: boolean,
	debrisAmount: number,
	ignore: { Instance }?,
	include: { Instance }?
)
	assert(sphereHitbox, "Hitbox provided was nil.")
	if sphereHitbox.Shape ~= Enum.PartType.Ball then
		error('Hitbox provided was not of shape "Ball"')
	end

	if not VoxManager.VoxelCache then
		VoxManager:_createVoxelCache()
	end

	minimumVoxelSize = minimumVoxelSize or 2
	finalVoxelSize = finalVoxelSize or minimumVoxelSize
	debrisAmount = debrisAmount or 1
	ignore = ignore or {}

	if randomColor == nil then
		randomColor = false
	end
	if debris == nil then
		debris = true
	end

	Voxelizer.subtractHitbox(
		sphereHitbox,
		minimumVoxelSize,
		finalVoxelSize,
		randomColor,
		debris,
		debrisAmount,
		ignore,
		VoxManager.VoxelCache,
		VoxManager.DebrisSizeMultiplier,
		include
	)
end

function VoxManager:voxelizePosition(
	position: Vector3,
	radius: number,
	minimumVoxelSize: number,
	finalVoxelSize: number,
	randomColor: boolean,
	debris: boolean,
	debrisAmount: number,
	ignore: { Instance }?,
	include: { Instance }?
)
	assert(position, "Please enter a valid position.")
	if typeof(position) ~= "Vector3" then
		error("Position must be a Vector3")
	end

	if not VoxManager.VoxelCache then
		VoxManager:_createVoxelCache()
	end

	minimumVoxelSize = minimumVoxelSize or 2
	finalVoxelSize = finalVoxelSize or minimumVoxelSize
	debrisAmount = debrisAmount or 1
	ignore = ignore or {}

	if randomColor == nil then
		randomColor = false
	end
	if debris == nil then
		debris = true
	end

	local hitbox = Instance.new("Part")
	hitbox.Name = "VoxManagerHitbox"
	hitbox.Shape = Enum.PartType.Ball
	hitbox.Position = position
	hitbox.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanQuery = false
	hitbox.Transparency = 1
	hitbox.Parent = workspace

	Voxelizer.subtractHitbox(
		hitbox,
		minimumVoxelSize,
		finalVoxelSize,
		randomColor,
		debris,
		debrisAmount,
		ignore,
		VoxManager.VoxelCache,
		VoxManager.DebrisSizeMultiplier,
		include
	)
end

function VoxManager:setDebrisSize(multiplier: number)
	assert(multiplier, "Debris multiplier needs to be a valid number.")
	if multiplier <= 0 then
		error("Debris multiplier needs to be greater than 0.")
	end

	VoxManager.DebrisSizeMultiplier = multiplier
end

function VoxManager:cleanup()
	if VoxManager.VoxelCache then
		VoxManager.VoxelCache:Destroy()
		VoxManager.VoxelCache = nil
	end
	if VoxManager.VoxelFolder then
		VoxManager.VoxelFolder:Destroy()
		VoxManager.VoxelFolder = nil
	end

	local currentVoxels = workspace:FindFirstChild("CurrentVoxels")
	if currentVoxels then
		currentVoxels:Destroy()
	end

	local voxelDebris = workspace:FindFirstChild("VoxelDebris")
	if voxelDebris then
		voxelDebris:Destroy()
	end
end

return VoxManager
