local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local VoxManager = require(ReplicatedStorage.Packages.VoxManager)

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local DestructionService = {}

local function hasUnsafeTaggedAncestor(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		for _, tagName in ipairs(UNSAFE_TAGS) do
			if CollectionService:HasTag(current, tagName) then
				return true
			end
		end
		current = current.Parent
	end

	return false
end

local function addBasePart(targets: { BasePart }, seen: { [BasePart]: boolean }, instance: Instance)
	if not instance:IsDescendantOf(workspace) or hasUnsafeTaggedAncestor(instance) then
		return
	end

	if instance:IsA("BasePart") then
		if not seen[instance] then
			seen[instance] = true
			table.insert(targets, instance)
		end
		return
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant:IsDescendantOf(workspace) and not hasUnsafeTaggedAncestor(descendant) then
			if not seen[descendant] then
				seen[descendant] = true
				table.insert(targets, descendant)
			end
		end
	end
end

local function getDestructibleTargets(): { BasePart }
	local targets = {}
	local seen = {}

	for _, instance in ipairs(CollectionService:GetTagged(DestructionConfig.Tag)) do
		addBasePart(targets, seen, instance)
	end

	return targets
end

function DestructionService:OnStart()
	VoxManager:setDebrisSize(DestructionConfig.DebrisSizeMultiplier)
end

function DestructionService:DestroySphere(position: Vector3, radius: number?)
	if typeof(position) ~= "Vector3" then
		return
	end

	local destructionRadius = if typeof(radius) == "number" and radius > 0
		then radius
		else BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius

	local targets = getDestructibleTargets()
	if #targets == 0 then
		return
	end

	local ok, err = pcall(function()
		VoxManager:voxelizePosition(
			position,
			destructionRadius,
			DestructionConfig.MinVoxelSize,
			DestructionConfig.FinalVoxelSize,
			DestructionConfig.RandomColor,
			DestructionConfig.Debris,
			DestructionConfig.DebrisAmount,
			{},
			targets
		)
	end)

	if not ok then
		warn("[DestructionService] Failed to voxelize explosion:", err)
	end
end

function DestructionService:Cleanup()
	VoxManager:cleanup()
end

return DestructionService
