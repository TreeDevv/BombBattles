local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

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
local replayService = nil
local scoreRecorder = nil

local function getReplayService()
	if replayService then
		return replayService
	end

	local services = ServerScriptService:FindFirstChild("Services")
	local replayModule = services and services:FindFirstChild("ReplayService")
	if not (replayModule and replayModule:IsA("ModuleScript")) then
		return nil
	end

	local ok, service = pcall(require, replayModule)
	if ok and typeof(service) == "table" then
		replayService = service
		return replayService
	end
	return nil
end

local function recordMapDestruction(position: Vector3, radius: number, sourceContext, debrisPayloads)
	local service = getReplayService()
	if not (service and type(service.RecordMapDestruction) == "function") then
		return
	end

	local payload = {
		position = position,
		radius = radius,
	}
	if typeof(sourceContext) == "table" then
		payload.timestamp = sourceContext.timestamp
		payload.sourceType = sourceContext.sourceType
		payload.sourceId = sourceContext.sourceId
		payload.bombId = sourceContext.bombId
		payload.ownerUserId = sourceContext.ownerUserId
	end
	if typeof(debrisPayloads) == "table" then
		payload.debrisPayloads = debrisPayloads
	end

	pcall(function()
		service.RecordMapDestruction(payload)
	end)
end

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

function DestructionService:SetScoreRecorder(recorder)
	scoreRecorder = if type(recorder) == "function" then recorder else nil
end

local function recordDestructionScore(sourceContext, targetsHit: number)
	if not scoreRecorder then
		return
	end

	local ok, err = pcall(scoreRecorder, sourceContext, targetsHit)
	if not ok then
		warn("[DestructionService] Failed to record destruction score:", err)
	end
end

function DestructionService:DestroySphere(position: Vector3, radius: number?, sourceContext)
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

	local targetsHit = if typeof(debrisPayloads) == "table" and typeof(debrisPayloads.targetsHit) == "number"
		then debrisPayloads.targetsHit
		else #debrisPayloads
	if targetsHit > 0 then
		recordDestructionScore(sourceContext, targetsHit)
		recordMapDestruction(position, destructionRadius, sourceContext, debrisPayloads)
	end

	return debrisPayloads
end

function DestructionService:Cleanup()
	VoxManager:cleanup()
end

return DestructionService
