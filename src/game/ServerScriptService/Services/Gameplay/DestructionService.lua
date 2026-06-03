local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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

local function isStudioBombTeamProtectionBypassEnabled(): boolean
	if not RunService:IsStudio() then
		return false
	end

	local studioTesting = RoundConfig.StudioTesting
	return studioTesting ~= nil and studioTesting.AllowBombTeamProtectionBypass == true
end

local function hasUnsafeTaggedAncestor(instance: Instance): boolean
	if isStudioBombTeamProtectionBypassEnabled() then
		return false
	end

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

local function getEligibleDestructiblePart(instance: Instance): BasePart?
	if not instance:IsA("BasePart") then
		return nil
	end
	if not instance:IsDescendantOf(workspace) or hasUnsafeTaggedAncestor(instance) then
		return nil
	end

	return instance
end

local function addTargetPart(targets: { BasePart }, seen: { [BasePart]: boolean }, part: BasePart)
	if seen[part] then
		return
	end

	seen[part] = true
	table.insert(targets, part)
end

local function addDestructibleRootTargets(targets: { BasePart }, seen: { [BasePart]: boolean }, root: Instance)
	if not root:IsDescendantOf(workspace) or hasUnsafeTaggedAncestor(root) then
		return
	end

	if root:IsA("BasePart") then
		addTargetPart(targets, seen, root)
		return
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		local part = getEligibleDestructiblePart(descendant)
		if part then
			addTargetPart(targets, seen, part)
		end
	end
end

local function getDestructibleTargets(): { BasePart }
	local targets = {}
	local seen = {}

	for _, instance in ipairs(CollectionService:GetTagged(DestructionConfig.Tag)) do
		addDestructibleRootTargets(targets, seen, instance)
	end

	return targets
end

function DestructionService:OnStart()
	VoxManager:setDebrisConfig(DestructionConfig)
	VoxManager:setGeneratedVoxelTag(DestructionConfig.Tag)
	VoxManager:setTerrainConfig(DestructionConfig)
	VoxManager:setTerrainDebugConfig(DestructionConfig)
end

function DestructionService:DestroySphere(position: Vector3, radius: number?)
	if typeof(position) ~= "Vector3" then
		return {}
	end

	local destructionRadius = if typeof(radius) == "number" and radius > 0
		then radius
		else BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius

	local targets = getDestructibleTargets()
	if #targets == 0 then
		return {}
	end

	local debrisPayloads = {}
	local ok, err = pcall(function()
		debrisPayloads = VoxManager:voxelizePosition(
			position,
			destructionRadius,
			DestructionConfig.MinVoxelSize,
			DestructionConfig.FinalVoxelSize,
			DestructionConfig.RandomColor,
			DestructionConfig.Debris,
			DestructionConfig.DebrisAmount,
			{},
			targets
		) or {}
	end)

	if not ok then
		warn("[DestructionService] Failed to voxelize explosion:", err)
		return {}
	end

	return debrisPayloads
end

function DestructionService:Cleanup()
	VoxManager:cleanup()
end

return DestructionService
