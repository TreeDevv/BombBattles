local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local VoxManager = require(ReplicatedStorage.Packages.VoxManager)
local VoxelDebris = require(ReplicatedStorage.Packages.VoxManager.Voxelizer.Debris)

local ReplayMapSimulator = {}

local MAP_FOLDER_NAME = "ReplayMap"
local CURRENT_VOXELS_FOLDER_NAME = "ReplayCurrentVoxels"
local DEBRIS_FOLDER_NAME = "ReplayDebris"
local BEDROCK_PART_NAME = "Bedrock"
local SCENE_NAME = "_LocalReplayScene"
local PREPARED_SCENE_NAME_PREFIX = "_LocalReplayPreparedScene"
local LOCAL_REPLAY_ATTR = "BombBattlesLocalReplay"
local REPLAY_ZONE_PIVOT = CFrame.new(30000, 8000, 30000)
local MAX_KILL_REPLAY_DESTRUCTION_EVENTS = 128
local MAX_POTG_REPLAY_DESTRUCTION_EVENTS = 192
local MAX_DESTRUCTION_EVENTS = MAX_POTG_REPLAY_DESTRUCTION_EVENTS
local MAX_DESTRUCTION_EVENTS_PER_STEP = 3
local DEFAULT_TARGETS_PER_DESTRUCTION_EVENT = 72
local HARD_MAX_TARGETS_PER_DESTRUCTION_EVENT = 128
local MAX_DEBRIS_PARTS_PER_EVENT = 72
local MAX_DEBRIS_PARTS_PER_REPLAY = 360
local MAX_PREPARED_MAP_TEMPLATES = 1
local MAX_PREPARED_REUSABLE_SCENES = 1
local PREWARM_TARGET_COLLECTION_BUDGET_SECONDS = 0.002
local DESTROY_INSTANCES_PER_STEP = 96
local DESTROY_BUDGET_SECONDS = 0.0025
local DEBRIS_LIFETIME_SCALE = 0.85

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local preparedTemplateCache = {}
local preparedTemplateOrder = {}
local preparedSceneCache = {}
local preparedSceneOrder = {}
local activePrewarmMapId: string? = nil
local activePrewarmSerial = 0
local prewarmWorkerRunning = false
local prewarmRequested = false

local PRIORITY_ACTIVE = "Active"
local PRIORITY_BACKGROUND = "Background"
local REPLAY_DESTRUCTION_BOOLEAN_OPTION_FIELDS = table.freeze({
	"forceSubtract",
	"exactCullTargets",
	"skipTerminalNoop",
	"reuseTargetPart",
	"prefilterTargets",
	"prefilteredTargets",
})

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteCFrame(value: any): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end

	local components = { value:GetComponents() }
	for _, component in ipairs(components) do
		if not isFiniteNumber(component) then
			return false
		end
	end
	return true
end

local function getMapFolder(): Instance?
	local current: Instance = ReplicatedStorage
	for _, name in ipairs(RoundConfig.MapsFolderPath) do
		if typeof(name) ~= "string" or name == "" then
			return nil
		end

		local nextInstance = current:FindFirstChild(name)
		if not nextInstance then
			return nil
		end
		current = nextInstance
	end
	return current
end

local function getMapTemplate(mapId: any): Instance?
	if typeof(mapId) ~= "string" or mapId == "" then
		return nil
	end

	local folder = getMapFolder()
	local template = folder and folder:FindFirstChild(mapId)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

local function getLocalSceneSuffix(): string
	local localPlayer = Players.LocalPlayer
	return tostring(if localPlayer then localPlayer.UserId else "client")
end

local function sanitizeMapIdForName(mapId: any): string
	local raw = if typeof(mapId) == "string" and mapId ~= "" then mapId else "Unknown"
	return string.gsub(raw, "[^%w_%-]", "_")
end

local function normalizeMapId(mapId: any): string?
	return if typeof(mapId) == "string" and mapId ~= "" then mapId else nil
end

local function getReplayDestructionEventLimit(context): number
	if typeof(context) == "table" and context.replayType == "KillReplay" then
		return MAX_KILL_REPLAY_DESTRUCTION_EVENTS
	end
	if typeof(context) == "table" and context.replayType == "POTGReplay" then
		return MAX_POTG_REPLAY_DESTRUCTION_EVENTS
	end
	return MAX_DESTRUCTION_EVENTS
end

local function getReplayDestructionTargetLimit(event): number
	local maxTargets = DEFAULT_TARGETS_PER_DESTRUCTION_EVENT
	if typeof(event) == "table" and isFiniteNumber(event.maxTargetsPerExplosion) then
		maxTargets = event.maxTargetsPerExplosion
	end
	return math.clamp(math.floor(maxTargets), 1, HARD_MAX_TARGETS_PER_DESTRUCTION_EVENT)
end

local function getBedrockTopY(mapRoot: Instance?): number?
	if not mapRoot then
		return nil
	end

	local bedrock = mapRoot:FindFirstChild(BEDROCK_PART_NAME)
	if bedrock and bedrock:IsA("BasePart") then
		return bedrock.Position.Y + bedrock.Size.Y * 0.5
	end
	return nil
end

local function copyReplayDestructionOptions(source, target)
	if typeof(source) ~= "table" or typeof(target) ~= "table" then
		return
	end

	if source.terrainShape == "Ellipsoid" or source.terrainShape == "Sphere" then
		target.terrainShape = source.terrainShape
	end
	if isFiniteNumber(source.terrainVerticalScale) then
		target.terrainVerticalScale = math.clamp(source.terrainVerticalScale, 0.05, 1)
	end
	if isFiniteNumber(source.maxTargetsPerExplosion) then
		target.maxTargetsPerExplosion = getReplayDestructionTargetLimit(source)
	end
	if isFiniteNumber(source.transparentCollisionClearance) then
		target.transparentCollisionClearance = math.clamp(source.transparentCollisionClearance, 0, 80)
	end
	for _, fieldName in ipairs(REPLAY_DESTRUCTION_BOOLEAN_OPTION_FIELDS) do
		if typeof(source[fieldName]) == "boolean" then
			target[fieldName] = source[fieldName]
		end
	end
end

local function getPayloadMapId(payload: any): string?
	if typeof(payload) ~= "table" then
		return nil
	end
	return if typeof(payload.mapId) == "string" and payload.mapId ~= "" then payload.mapId else nil
end

local function getPayloadRoundId(payload: any): number?
	if typeof(payload) ~= "table" or not isFiniteNumber(payload.roundId) then
		return nil
	end
	return math.floor(payload.roundId)
end

local function setReplayIdentityAttributes(instance: Instance?, mapId: string?, roundId: number?)
	if not instance then
		return
	end
	instance:SetAttribute("ReplayMapId", mapId)
	instance:SetAttribute("ReplayRoundId", roundId)
end

local function warnPreparedSceneMismatch(reason: string, expectedMapId: string, actualMapId: any)
	warn(
		("[ReplayMapSimulator] Ignoring prepared replay scene: %s expectedMap=%s actualMap=%s"):format(
			reason,
			expectedMapId,
			tostring(actualMapId)
		)
	)
end

local function createPreparedScene(mapId: string): Folder
	local scene = Instance.new("Folder")
	scene.Name = ("%s_%s_%s"):format(PREPARED_SCENE_NAME_PREFIX, sanitizeMapIdForName(mapId), getLocalSceneSuffix())
	scene:SetAttribute(LOCAL_REPLAY_ATTR, true)
	setReplayIdentityAttributes(scene, mapId, nil)
	return scene
end

function ReplayMapSimulator.ScheduleDestroyScene(root: Instance?, reason: string?)
	if typeof(root) ~= "Instance" then
		return false
	end

	pcall(function()
		root.Parent = nil
	end)
	task.defer(function()
		local token = RuntimeProfiler.Begin("Client/Replay/MapSimulator/DestroySceneIncremental")
		local destroyed = 0
		local batchDestroyed = 0
		local batchStartedAt = os.clock()
		local stack = {
			{
				instance = root,
				visited = false,
			},
		}
		local ok, err = pcall(function()
			while #stack > 0 do
				local entry = table.remove(stack)
				local instance = entry and entry.instance
				if typeof(instance) == "Instance" then
					if entry.visited == true then
						local destroyedOk = pcall(function()
							instance:Destroy()
						end)
						if destroyedOk then
							destroyed += 1
							batchDestroyed += 1
						end
					else
						table.insert(stack, {
							instance = instance,
							visited = true,
						})
						local childrenOk, children = pcall(function()
							return instance:GetChildren()
						end)
						if childrenOk and typeof(children) == "table" then
							for _, child in ipairs(children) do
								table.insert(stack, {
									instance = child,
									visited = false,
								})
							end
						end
					end
				end

				if
					batchDestroyed >= DESTROY_INSTANCES_PER_STEP
					or os.clock() - batchStartedAt >= DESTROY_BUDGET_SECONDS
				then
					RuntimeProfiler.Count("Client/Replay/MapSimulator/DestroySceneYields")
					task.wait()
					batchDestroyed = 0
					batchStartedAt = os.clock()
				end
			end
		end)
		if not ok then
			RuntimeProfiler.Count("Client/Replay/MapSimulator/DestroySceneErrors")
			warn(("[ReplayMapSimulator] Incremental scene destroy failed: %s"):format(tostring(err)))
		end
		RuntimeProfiler.Count("Client/Replay/MapSimulator/DestroyedSceneInstances", destroyed)
		if typeof(reason) == "string" and reason ~= "" then
			RuntimeProfiler.Count("Client/Replay/MapSimulator/DestroyedScene/" .. reason)
		end
		RuntimeProfiler.End("Client/Replay/MapSimulator/DestroySceneIncremental", token)
	end)
	return true
end

local function destroyPreparedSceneEntry(entry)
	if not entry then
		return
	end
	if entry.mapContext then
		pcall(function()
			ReplayMapSimulator.Destroy(entry.mapContext)
		end)
	end
	if entry.scene then
		ReplayMapSimulator.ScheduleDestroyScene(entry.scene, "Prepared")
	end
end

local function destroyDuplicatePreparedScenes(mapId: string, keepScene: Instance?)
	for _, child in ipairs(Workspace:GetChildren()) do
		if child == keepScene then
			continue
		end
		if string.sub(child.Name, 1, #PREPARED_SCENE_NAME_PREFIX) ~= PREPARED_SCENE_NAME_PREFIX then
			continue
		end
		if child:GetAttribute("ReplayMapId") == mapId then
			ReplayMapSimulator.ScheduleDestroyScene(child, "DuplicatePrepared")
		end
	end
end

local function isPreparedSceneName(name: string): boolean
	return string.sub(name, 1, #PREPARED_SCENE_NAME_PREFIX) == PREPARED_SCENE_NAME_PREFIX
end

local function clearPreparedTemplatesExcept(keepMapId: string?)
	for index = #preparedTemplateOrder, 1, -1 do
		local mapId = preparedTemplateOrder[index]
		if mapId ~= keepMapId then
			table.remove(preparedTemplateOrder, index)
			local template = preparedTemplateCache[mapId]
			preparedTemplateCache[mapId] = nil
			if template then
				template:Destroy()
			end
		end
	end
end

local function clearPreparedScenesExcept(keepMapId: string?)
	for index = #preparedSceneOrder, 1, -1 do
		local mapId = preparedSceneOrder[index]
		if mapId ~= keepMapId then
			table.remove(preparedSceneOrder, index)
			local entry = preparedSceneCache[mapId]
			preparedSceneCache[mapId] = nil
			destroyPreparedSceneEntry(entry)
		end
	end

	for _, child in ipairs(Workspace:GetChildren()) do
		if isPreparedSceneName(child.Name) and child:GetAttribute("ReplayMapId") ~= keepMapId then
			ReplayMapSimulator.ScheduleDestroyScene(child, "StalePrepared")
		end
	end
end

local function isActivePrewarmRequest(mapId: string, serial: number): boolean
	return activePrewarmMapId == mapId and activePrewarmSerial == serial
end

local function pivotInstance(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function prepareMapClone(instance: Instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = true
		elseif descendant:IsA("Sound") then
			descendant.Looped = false
			descendant:Stop()
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = false
		end
	end

	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = true
	end
end

local function rememberPreparedTemplate(mapId: string, clone: Instance)
	local existing = preparedTemplateCache[mapId]
	if existing == clone then
		return clone
	end
	if existing then
		existing:Destroy()
	end
	if not preparedTemplateCache[mapId] then
		table.insert(preparedTemplateOrder, mapId)
	end
	preparedTemplateCache[mapId] = clone
	clone.Parent = nil

	while #preparedTemplateOrder > MAX_PREPARED_MAP_TEMPLATES do
		local oldMapId = table.remove(preparedTemplateOrder, 1)
		local oldTemplate = oldMapId and preparedTemplateCache[oldMapId]
		preparedTemplateCache[oldMapId] = nil
		if oldTemplate then
			oldTemplate:Destroy()
		end
	end
	return clone
end

local function takePreparedTemplate(mapId: string): Instance?
	local preparedTemplate = preparedTemplateCache[mapId]
	if not (preparedTemplate and preparedTemplate.Parent == nil) then
		if preparedTemplate then
			preparedTemplateCache[mapId] = nil
		end
		return nil
	end

	preparedTemplateCache[mapId] = nil
	local orderIndex = table.find(preparedTemplateOrder, mapId)
	if orderIndex then
		table.remove(preparedTemplateOrder, orderIndex)
	end
	RuntimeProfiler.Count("Client/Replay/MapSimulator/PreparedTemplatesConsumed")
	return preparedTemplate
end

function ReplayMapSimulator.PrewarmTemplate(mapId: any): boolean
	mapId = normalizeMapId(mapId)
	if not mapId then
		return false
	end
	if activePrewarmMapId ~= mapId then
		RuntimeProfiler.Count("Client/Replay/MapSimulator/TemplatePrewarmSkippedInactiveMap")
		return false
	end
	local existing = preparedTemplateCache[mapId]
	if existing and existing.Parent == nil then
		return true
	end

	local template = getMapTemplate(mapId)
	if not template then
		return false
	end

	local token = RuntimeProfiler.Begin("Client/Replay/MapSimulator/PrewarmTemplate")
	local cloneToken = RuntimeProfiler.Begin("Client/Replay/MapSimulator/PrewarmTemplateClone")
	local clone = template:Clone()
	RuntimeProfiler.End("Client/Replay/MapSimulator/PrewarmTemplateClone", cloneToken)
	clone.Name = RoundConfig.ActiveMapName
	setReplayIdentityAttributes(clone, mapId, nil)
	local prepareToken = RuntimeProfiler.Begin("Client/Replay/MapSimulator/PrewarmTemplatePrepare")
	prepareMapClone(clone)
	RuntimeProfiler.End("Client/Replay/MapSimulator/PrewarmTemplatePrepare", prepareToken)
	rememberPreparedTemplate(mapId, clone)
	RuntimeProfiler.Count("Client/Replay/MapSimulator/PrewarmedTemplates")
	RuntimeProfiler.End("Client/Replay/MapSimulator/PrewarmTemplate", token)
	return true
end

function ReplayMapSimulator.PrewarmTemplates()
	if not activePrewarmMapId then
		RuntimeProfiler.Count("Client/Replay/MapSimulator/TemplatePrewarmSkippedNoActiveMap")
		return 0
	end

	return if ReplayMapSimulator.PrewarmTemplate(activePrewarmMapId) then 1 else 0
end

local function clonePreparedMapTemplate(mapId: any): Instance?
	mapId = normalizeMapId(mapId)
	if not mapId then
		return nil
	end

	local preparedTemplate = takePreparedTemplate(mapId)
	if preparedTemplate then
		preparedTemplate.Name = RoundConfig.ActiveMapName
		setReplayIdentityAttributes(preparedTemplate, mapId, nil)
		return preparedTemplate
	end

	local template = getMapTemplate(mapId)
	if not template then
		return nil
	end
	local cloneToken = RuntimeProfiler.Begin("Client/Replay/MapSimulator/ColdTemplateClone")
	local clone = template:Clone()
	RuntimeProfiler.End("Client/Replay/MapSimulator/ColdTemplateClone", cloneToken)
	clone.Name = RoundConfig.ActiveMapName
	setReplayIdentityAttributes(clone, mapId, nil)
	local prepareToken = RuntimeProfiler.Begin("Client/Replay/MapSimulator/ColdTemplatePrepare")
	prepareMapClone(clone)
	RuntimeProfiler.End("Client/Replay/MapSimulator/ColdTemplatePrepare", prepareToken)
	RuntimeProfiler.Count("Client/Replay/MapSimulator/ColdTemplateClones")
	return clone
end

local function sanitizeGeneratedVoxels(root: Instance?)
	if not root then
		return
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = true
		end
	end
end

local function hasUnsafeTaggedAncestor(instance: Instance, stopAt: Instance): boolean
	local current: Instance? = instance
	while current and current ~= stopAt.Parent do
		for _, tagName in ipairs(UNSAFE_TAGS) do
			if CollectionService:HasTag(current, tagName) then
				return true
			end
		end
		if current == stopAt then
			break
		end
		current = current.Parent
	end
	return false
end

local function hasDestructibleTag(instance: Instance, stopAt: Instance): boolean
	local current: Instance? = instance
	while current and current ~= stopAt.Parent do
		if CollectionService:HasTag(current, DestructionConfig.Tag) then
			return true
		end
		if current == stopAt then
			break
		end
		current = current.Parent
	end
	return false
end

local function addTarget(targets: { BasePart }, seen: { [BasePart]: boolean }, part: BasePart)
	if seen[part] then
		return
	end
	seen[part] = true
	table.insert(targets, part)
end

local function isReplayMapPart(part: BasePart, mapRoot: Instance): boolean
	if part.Name == "VoxManagerHitbox" then
		return false
	end
	if part.Name == BEDROCK_PART_NAME then
		return false
	end
	if part ~= mapRoot and part:IsDescendantOf(mapRoot) ~= true then
		return false
	end
	if hasUnsafeTaggedAncestor(part, mapRoot) then
		return false
	end
	return true
end

local function shouldYieldForBudget(startedAt: number, budgetSeconds: number): boolean
	return os.clock() - startedAt >= budgetSeconds
end

local function scanStaticDestructibleTargets(context, budgetSeconds: number?): ({ BasePart }, boolean, number, number)
	local staticRoot = context and context.staticMapRoot
	if not staticRoot then
		return {}, false, 0, 0
	end

	local destructibleTargets = {}
	local destructibleSeen = {}
	local fallbackTargets = {}
	local fallbackSeen = {}
	local stack = { staticRoot }
	local frames = 1
	local startedAt = os.clock()
	local maxSliceSeconds = 0
	local shouldBudget = typeof(budgetSeconds) == "number" and budgetSeconds > 0

	while #stack > 0 do
		local instance = table.remove(stack)
		if instance:IsA("BasePart") and isReplayMapPart(instance, staticRoot) then
			addTarget(fallbackTargets, fallbackSeen, instance)
			if hasDestructibleTag(instance, staticRoot) then
				addTarget(destructibleTargets, destructibleSeen, instance)
			end
		end

		for _, child in ipairs(instance:GetChildren()) do
			table.insert(stack, child)
		end

		local sliceSeconds = os.clock() - startedAt
		if sliceSeconds > maxSliceSeconds then
			maxSliceSeconds = sliceSeconds
		end
		if shouldBudget and shouldYieldForBudget(startedAt, budgetSeconds) then
			frames += 1
			task.wait()
			startedAt = os.clock()
		end
	end

	if #destructibleTargets > 0 then
		return destructibleTargets, false, frames, maxSliceSeconds * 1000
	end
	return fallbackTargets, true, frames, maxSliceSeconds * 1000
end

local function buildStaticDestructibleTargets(context): ({ BasePart }, boolean)
	local targets, usedFallbackTargets = scanStaticDestructibleTargets(context, nil)
	return targets, usedFallbackTargets
end

local function buildStaticDestructibleTargetsBudgeted(
	context,
	budgetSeconds: number
): ({ BasePart }, boolean, number, number)
	return scanStaticDestructibleTargets(context, budgetSeconds)
end

local function prewarmStaticDestructibleTargets(context): boolean
	if not (context and context.mapRoot) then
		return false
	end
	if context.staticTargets then
		return true
	end

	local token = RuntimeProfiler.Begin("Client/Replay/MapSimulator/PrewarmStaticTargets")
	local startedAt = os.clock()
	local staticTargets, usedFallbackTargets, frames, maxSliceMs =
		buildStaticDestructibleTargetsBudgeted(context, PREWARM_TARGET_COLLECTION_BUDGET_SECONDS)
	context.staticTargets = staticTargets
	context.staticUsedFallbackTargets = usedFallbackTargets
	context.staticTargetCount = #staticTargets
	RuntimeProfiler.Count("Client/Replay/MapSimulator/PrewarmStaticTargetFrames", frames)
	RuntimeProfiler.Count("Client/Replay/MapSimulator/PrewarmStaticTargetCount", #staticTargets)
	RuntimeProfiler.Gauge("Client/Replay/MapSimulator/PrewarmStaticTargetMs", (os.clock() - startedAt) * 1000)
	RuntimeProfiler.Gauge("Client/Replay/MapSimulator/PrewarmStaticTargetMaxSliceMs", maxSliceMs or 0)
	RuntimeProfiler.End("Client/Replay/MapSimulator/PrewarmStaticTargets", token)
	return true
end

local function addLiveCachedTargets(targets: { BasePart }, seen: { [BasePart]: boolean }, source)
	for _, part in ipairs(source or {}) do
		if part and part.Parent then
			addTarget(targets, seen, part)
		end
	end
end

local function collectGeneratedVoxelTargets(context, targets: { BasePart }, seen: { [BasePart]: boolean })
	local outputFolder = context and context.outputFolder
	if not outputFolder then
		return
	end

	for _, descendant in ipairs(outputFolder:GetDescendants()) do
		if descendant:IsA("BasePart") then
			addTarget(targets, seen, descendant)
		end
	end
end

local function collectDestructibleTargets(context): ({ BasePart }, boolean)
	if not (context and context.mapRoot) then
		return {}, false
	end

	if not context.staticTargets then
		local staticTargets, usedFallbackTargets = buildStaticDestructibleTargets(context)
		context.staticTargets = staticTargets
		context.staticUsedFallbackTargets = usedFallbackTargets
		context.staticTargetCount = #staticTargets
	end

	local targets = {}
	local seen = {}
	addLiveCachedTargets(targets, seen, context.staticTargets)
	collectGeneratedVoxelTargets(context, targets, seen)
	return targets, context.staticUsedFallbackTargets == true
end

local function getDistanceSquared(part: BasePart, position: Vector3): number
	local localPosition = part.CFrame:PointToObjectSpace(position)
	local halfSize = part.Size * 0.5
	local dx = math.max(math.abs(localPosition.X) - halfSize.X, 0)
	local dy = math.max(math.abs(localPosition.Y) - halfSize.Y, 0)
	local dz = math.max(math.abs(localPosition.Z) - halfSize.Z, 0)
	return dx * dx + dy * dy + dz * dz
end

local function getReplayQueryRadius(event): number?
	if typeof(event) ~= "table" or not (isFiniteNumber(event.radius) and event.radius > 0) then
		return nil
	end

	local radius = event.radius
	if event.forceSubtract == true and isFiniteNumber(event.transparentCollisionClearance) then
		radius += math.max(event.transparentCollisionClearance, 0)
	end
	return radius
end

local function prefilterReplayDestructionTargets(context, targets: { BasePart }, event): { BasePart }
	if typeof(event) ~= "table" or event.prefilterTargets == false or typeof(event.position) ~= "Vector3" then
		return targets
	end

	local queryRadius = getReplayQueryRadius(event)
	if not queryRadius then
		return targets
	end

	local radiusSquared = queryRadius * queryRadius
	local candidates = {}
	for _, part in ipairs(targets) do
		if getDistanceSquared(part, event.position) < radiusSquared then
			table.insert(candidates, part)
		end
	end

	local skipped = #targets - #candidates
	if skipped > 0 then
		context.replayTargetsSkippedByPrefilter = (context.replayTargetsSkippedByPrefilter or 0) + skipped
		RuntimeProfiler.Count("Client/Replay/MapSimulator/TargetsSkippedByPrefilter", skipped)
	end
	RuntimeProfiler.Gauge("Client/Replay/MapSimulator/LastPrefilteredTargets", #candidates)
	return candidates
end

local function selectNearestReplayTargets(targets: { BasePart }, position: Vector3, maxTargets: number): { BasePart }
	local selected = {}
	local distances = {}
	local selectedCount = 0
	local worstIndex = 0
	local worstDistance = -math.huge

	for _, part in ipairs(targets) do
		local distance = getDistanceSquared(part, position)
		if selectedCount < maxTargets then
			selectedCount += 1
			selected[selectedCount] = part
			distances[selectedCount] = distance
			if distance > worstDistance then
				worstDistance = distance
				worstIndex = selectedCount
			end
		elseif distance < worstDistance then
			selected[worstIndex] = part
			distances[worstIndex] = distance
			worstIndex = 1
			worstDistance = distances[1] or -math.huge
			for index = 2, selectedCount do
				local selectedDistance = distances[index]
				if selectedDistance and selectedDistance > worstDistance then
					worstDistance = selectedDistance
					worstIndex = index
				end
			end
		end
	end

	return selected
end

local function capReplayDestructionTargets(context, targets: { BasePart }, position: Vector3, event): { BasePart }
	local maxTargets = getReplayDestructionTargetLimit(event)
	if #targets <= maxTargets then
		return targets
	end

	local capped = selectNearestReplayTargets(targets, position, maxTargets)

	local skipped = #targets - #capped
	context.replayTargetsSkippedByCap = (context.replayTargetsSkippedByCap or 0) + skipped
	RuntimeProfiler.Count("Client/Replay/MapSimulator/TargetsCapped")
	RuntimeProfiler.Count("Client/Replay/MapSimulator/TargetsSkippedByCap", skipped)
	RuntimeProfiler.Gauge("Client/Replay/MapSimulator/LastCappedTargets", #capped)
	return capped
end

function ReplayMapSimulator.TransformPoint(context, point: Vector3): Vector3
	return context.replayPivot:PointToWorldSpace(context.livePivot:PointToObjectSpace(point))
end

function ReplayMapSimulator.TransformVector(context, vector: Vector3): Vector3
	return context.replayPivot:VectorToWorldSpace(context.livePivot:VectorToObjectSpace(vector))
end

function ReplayMapSimulator.TransformCFrame(context, cframe: CFrame): CFrame
	return context.replayPivot * context.livePivot:ToObjectSpace(cframe)
end

local function copyDebrisPayloadBlock(context, block)
	if typeof(block) ~= "table" or typeof(block.size) ~= "Vector3" then
		return nil
	end
	if typeof(block.cframe) == "CFrame" then
		return {
			cframe = ReplayMapSimulator.TransformCFrame(context, block.cframe),
			size = block.size,
		}
	end
	if typeof(block.center) ~= "Vector3" then
		return nil
	end

	return {
		center = block.center,
		size = block.size,
	}
end

local function transformDebrisPayload(context, payload)
	if typeof(payload) ~= "table" then
		return nil
	end
	if payload.compact == true then
		if typeof(payload.explosionPosition) ~= "Vector3" then
			return nil
		end
		local transformed = {
			compact = true,
			explosionPosition = ReplayMapSimulator.TransformPoint(context, payload.explosionPosition),
			sourceBlockCount = payload.sourceBlockCount,
			sampleCount = payload.sampleCount,
			averageSize = payload.averageSize,
			radius = payload.radius,
		}
		for _, fieldName in ipairs({
			"materialName",
			"color",
			"transparency",
			"reflectance",
			"speedMin",
			"speedMax",
			"lifetime",
			"useGraphicsQualitySampling",
			"automaticQualityLevel",
			"maxSamplingDivisor",
			"seed",
		}) do
			transformed[fieldName] = payload[fieldName]
		end
		return transformed
	end
	if not (isFiniteCFrame(payload.sourceCFrame) and typeof(payload.explosionPosition) == "Vector3") then
		return nil
	end
	if typeof(payload.blocks) ~= "table" or #payload.blocks == 0 then
		return nil
	end

	local blocks = {}
	for _, block in ipairs(payload.blocks) do
		local copiedBlock = copyDebrisPayloadBlock(context, block)
		if copiedBlock then
			table.insert(blocks, copiedBlock)
		end
	end
	if #blocks == 0 then
		return nil
	end

	local transformed = {
		sourceCFrame = ReplayMapSimulator.TransformCFrame(context, payload.sourceCFrame),
		explosionPosition = ReplayMapSimulator.TransformPoint(context, payload.explosionPosition),
		blocks = blocks,
	}
	for _, fieldName in ipairs({
		"materialName",
		"color",
		"transparency",
		"reflectance",
		"speedMin",
		"speedMax",
		"lifetime",
		"useGraphicsQualitySampling",
		"automaticQualityLevel",
		"maxSamplingDivisor",
		"seed",
	}) do
		transformed[fieldName] = payload[fieldName]
	end
	return transformed
end

local function transformDebrisPayloads(context, payloads)
	if typeof(payloads) ~= "table" then
		return nil
	end

	local results = {}
	for _, payload in ipairs(payloads) do
		local transformed = transformDebrisPayload(context, payload)
		if transformed then
			table.insert(results, transformed)
		end
	end
	return if #results > 0 then results else nil
end

local function transformSnapshot(context, snapshot)
	if typeof(snapshot) ~= "table" then
		return
	end

	if isFiniteCFrame(snapshot.cframe) then
		snapshot.cframe = ReplayMapSimulator.TransformCFrame(context, snapshot.cframe)
	end
	if isFiniteCFrame(snapshot.serverCFrame) then
		snapshot.serverCFrame = ReplayMapSimulator.TransformCFrame(context, snapshot.serverCFrame)
	end
	if typeof(snapshot.position) == "Vector3" then
		snapshot.position = ReplayMapSimulator.TransformPoint(context, snapshot.position)
	end

	for _, fieldName in ipairs({ "velocity", "assemblyLinearVelocity", "linearVelocity" }) do
		if typeof(snapshot[fieldName]) == "Vector3" then
			snapshot[fieldName] = ReplayMapSimulator.TransformVector(context, snapshot[fieldName])
		end
	end

	local animationState = snapshot.animationState
	if typeof(animationState) == "table" and typeof(animationState.linearVelocity) == "Vector3" then
		animationState.linearVelocity = ReplayMapSimulator.TransformVector(context, animationState.linearVelocity)
	end

	local camera = snapshot.camera
	if typeof(camera) == "table" then
		if isFiniteCFrame(camera.cframe) then
			camera.cframe = ReplayMapSimulator.TransformCFrame(context, camera.cframe)
		end
		if isFiniteCFrame(camera.focus) then
			camera.focus = ReplayMapSimulator.TransformCFrame(context, camera.focus)
		end
	end
end

function ReplayMapSimulator.TransformFrames(context, frames)
	if typeof(frames) ~= "table" then
		return frames
	end

	for _, frame in ipairs(frames) do
		if typeof(frame.players) == "table" then
			for _, snapshot in pairs(frame.players) do
				transformSnapshot(context, snapshot)
			end
		end
		if typeof(frame.bombs) == "table" then
			for _, snapshot in pairs(frame.bombs) do
				transformSnapshot(context, snapshot)
			end
		end
	end
	return frames
end

local function transformEvent(context, event)
	if typeof(event) ~= "table" then
		return
	end

	if typeof(event.position) == "Vector3" then
		event.position = ReplayMapSimulator.TransformPoint(context, event.position)
	end
	if isFiniteCFrame(event.cframe) then
		event.cframe = ReplayMapSimulator.TransformCFrame(context, event.cframe)
	end

	for _, fieldName in ipairs({ "origin", "targetPosition", "startPosition", "endPosition" }) do
		if typeof(event[fieldName]) == "Vector3" then
			event[fieldName] = ReplayMapSimulator.TransformPoint(context, event[fieldName])
		end
	end
	for _, fieldName in ipairs({ "velocity", "initialVelocity", "acceleration" }) do
		if typeof(event[fieldName]) == "Vector3" then
			event[fieldName] = ReplayMapSimulator.TransformVector(context, event[fieldName])
		end
	end
end

function ReplayMapSimulator.TransformEvents(context, events)
	if typeof(events) ~= "table" then
		return events
	end

	for _, event in ipairs(events) do
		transformEvent(context, event)
	end
	return events
end

function ReplayMapSimulator.NormalizeDestructionEvents(
	context,
	rawEvents,
	startTimeOrEndTime: number,
	maybeEndTime: number?
)
	local events = {}
	if typeof(rawEvents) ~= "table" then
		if context then
			context.normalizedDestructionEvents = 0
		end
		return events
	end
	local startTime = if isFiniteNumber(maybeEndTime) then startTimeOrEndTime else nil
	local endTime = if isFiniteNumber(maybeEndTime) then maybeEndTime else startTimeOrEndTime
	local skippedBeforeWindow = 0
	local skippedAfterWindow = 0

	for _, event in ipairs(rawEvents) do
		if typeof(event) ~= "table" or not isFiniteNumber(event.timestamp) then
			continue
		end
		if isFiniteNumber(endTime) and event.timestamp > endTime then
			skippedAfterWindow += 1
			continue
		end

		local position = if typeof(event.position) == "Vector3"
			then event.position
			elseif isFiniteCFrame(event.cframe) then event.cframe.Position
			else nil
		local radius = event.radius
		if typeof(position) ~= "Vector3" or not (isFiniteNumber(radius) and radius > 0) then
			continue
		end

		local normalizedEvent = {
			timestamp = event.timestamp,
			sequence = if isFiniteNumber(event.sequence) then math.floor(event.sequence) else #events + 1,
			position = ReplayMapSimulator.TransformPoint(context, position),
			radius = math.clamp(radius, 1, 80),
			sourceId = event.sourceId,
			debrisPayloads = transformDebrisPayloads(context, event.debrisPayloads),
		}
		copyReplayDestructionOptions(event, normalizedEvent)
		table.insert(events, normalizedEvent)
	end

	table.sort(events, function(left, right)
		if left.timestamp == right.timestamp then
			return (left.sequence or 0) < (right.sequence or 0)
		end
		return left.timestamp < right.timestamp
	end)
	local maxDestructionEvents = getReplayDestructionEventLimit(context)
	while #events > maxDestructionEvents do
		local removed = table.remove(events, 1)
		if
			typeof(removed) == "table"
			and isFiniteNumber(startTime)
			and isFiniteNumber(removed.timestamp)
			and removed.timestamp < startTime
		then
			skippedBeforeWindow += 1
		end
	end
	local baselineEvents = 0
	if isFiniteNumber(startTime) then
		for _, event in ipairs(events) do
			if typeof(event) == "table" and isFiniteNumber(event.timestamp) and event.timestamp < startTime then
				baselineEvents += 1
			end
		end
	end
	if context then
		context.normalizedDestructionEvents = #events
		context.baselineDestructionEvents = baselineEvents
		context.skippedDestructionEventsBeforeWindow = skippedBeforeWindow
		context.skippedDestructionEventsAfterWindow = skippedAfterWindow
	end
	RuntimeProfiler.Count("Client/Replay/MapSimulator/NormalizedDestructionEvents", #events)
	RuntimeProfiler.Count("Client/Replay/MapSimulator/BaselineDestructionEvents", baselineEvents)
	RuntimeProfiler.Count("Client/Replay/MapSimulator/SkippedDestructionEventsBeforeWindow", skippedBeforeWindow)
	RuntimeProfiler.Count("Client/Replay/MapSimulator/SkippedDestructionEventsAfterWindow", skippedAfterWindow)
	return events
end

local function spawnRecordedDebrisPayloads(context, payloads, maxParts: number): (number, number, number)
	if not (context and context.debrisFolder and typeof(payloads) == "table") then
		return 0, 0, 0
	end

	local remainingParts = math.max(math.floor(maxParts), 0)
	local spawnedParts = 0
	local spawnAttempts = 0
	local payloadBlocks = 0
	for _, payload in ipairs(payloads) do
		if remainingParts <= 0 then
			break
		end
		if typeof(payload) ~= "table" then
			continue
		end

		payloadBlocks += if typeof(payload.blocks) == "table"
			then #payload.blocks
			elseif typeof(payload.sourceBlockCount) == "number" then payload.sourceBlockCount
			else 0
		local spawned, attempts = VoxelDebris.spawnPayload(payload, {
			parentFolder = context.debrisFolder,
			maxParts = remainingParts,
			lifetimeScale = DEBRIS_LIFETIME_SCALE,
			useGraphicsQualitySampling = false,
			forceVisible = true,
			minimumParts = math.min(6, remainingParts),
		})
		if typeof(attempts) == "number" then
			spawnAttempts += attempts
		end
		if typeof(spawned) == "number" and spawned > 0 then
			spawnedParts += spawned
			remainingParts -= spawned
		end
	end

	return spawnedParts, spawnAttempts, payloadBlocks
end

local function addDebrisDebugCounts(context, spawnedParts: number, spawnAttempts: number, payloadBlocks: number)
	context.debrisPartCount = (context.debrisPartCount or 0) + math.max(spawnedParts, 0)
	context.debrisSpawnAttempts = (context.debrisSpawnAttempts or 0) + math.max(spawnAttempts, 0)
	context.debrisPayloadBlocks = (context.debrisPayloadBlocks or 0) + math.max(payloadBlocks, 0)
end

function ReplayMapSimulator.ApplyDestructionEvent(context, event, options): boolean
	if not (context and context.mapRoot and context.outputFolder) then
		return false
	end
	if typeof(event) ~= "table" or typeof(event.position) ~= "Vector3" then
		return false
	end
	if not (isFiniteNumber(event.radius) and event.radius > 0) then
		return false
	end

	local replayVoxelOptions = {
		maxTargetsPerExplosion = getReplayDestructionTargetLimit(event),
	}
	if isFiniteNumber(context.bedrockTopY) then
		replayVoxelOptions.bedrockTopY = context.bedrockTopY
	end
	copyReplayDestructionOptions(event, replayVoxelOptions)
	local recordedDebrisPayloads = nil
	local recordedDebrisMaxParts = 0
	local spawnDebris = false
	if typeof(options) == "table" and options.spawnDebris == true and context.debrisFolder then
		local replayRemaining = math.max(MAX_DEBRIS_PARTS_PER_REPLAY - (context.debrisPartCount or 0), 0)
		local eventMaxParts = math.min(MAX_DEBRIS_PARTS_PER_EVENT, replayRemaining)
		if eventMaxParts > 0 then
			if typeof(event.debrisPayloads) == "table" and #event.debrisPayloads > 0 then
				recordedDebrisPayloads = event.debrisPayloads
				recordedDebrisMaxParts = eventMaxParts
			else
				spawnDebris = true
				replayVoxelOptions.forceSpawnDebris = true
				replayVoxelOptions.debrisFolder = context.debrisFolder
				replayVoxelOptions.maxDebrisParts = eventMaxParts
				replayVoxelOptions.debrisLifetimeScale = DEBRIS_LIFETIME_SCALE
				replayVoxelOptions.useGraphicsQualitySampling = false
				replayVoxelOptions.forceVisible = true
				replayVoxelOptions.minimumParts = math.min(6, eventMaxParts)
				replayVoxelOptions.spawnedDebrisParts = 0
				replayVoxelOptions.debrisPayloadBlocks = 0
				replayVoxelOptions.debrisSpawnAttempts = 0
			end
		end
	end

	local targets, usedFallbackTargets = collectDestructibleTargets(context)
	context.lastTargetCount = #targets
	if #targets == 0 then
		context.targetFailures = (context.targetFailures or 0) + 1
		if recordedDebrisPayloads and recordedDebrisMaxParts > 0 then
			local spawned, attempts, blocks =
				spawnRecordedDebrisPayloads(context, recordedDebrisPayloads, recordedDebrisMaxParts)
			addDebrisDebugCounts(context, spawned, attempts, blocks)
			return spawned > 0 or attempts > 0
		end
		return false
	end
	if usedFallbackTargets then
		context.fallbackTargetUses = (context.fallbackTargetUses or 0) + 1
	end
	targets = prefilterReplayDestructionTargets(context, targets, event)
	context.lastPrefilteredTargetCount = #targets
	targets = capReplayDestructionTargets(context, targets, event.position, event)
	context.lastCappedTargetCount = #targets

	local voxelizeResult = nil
	local ok, err = pcall(function()
		voxelizeResult = VoxManager:voxelizePosition(
			event.position,
			event.radius,
			DestructionConfig.MinVoxelSize,
			DestructionConfig.FinalVoxelSize,
			DestructionConfig.RandomColor,
			spawnDebris,
			DestructionConfig.DebrisAmount,
			{},
			targets,
			context.outputFolder,
			replayVoxelOptions
		) or {}
	end)
	if not ok then
		context.applyFailures = (context.applyFailures or 0) + 1
		warn("[ReplayMapSimulator] Failed to apply replay map destruction: " .. tostring(err))
		return false
	end

	if typeof(voxelizeResult) == "table" and typeof(voxelizeResult.targetsHit) == "number" then
		context.targetsHit = (context.targetsHit or 0) + voxelizeResult.targetsHit
	end
	if typeof(voxelizeResult) == "table" and typeof(voxelizeResult.debrisPayloadBlocks) == "number" then
		context.debrisPayloadBlocks = (context.debrisPayloadBlocks or 0) + voxelizeResult.debrisPayloadBlocks
	elseif typeof(replayVoxelOptions.debrisPayloadBlocks) == "number" then
		context.debrisPayloadBlocks = (context.debrisPayloadBlocks or 0) + replayVoxelOptions.debrisPayloadBlocks
	end
	if typeof(voxelizeResult) == "table" and typeof(voxelizeResult.debrisSpawnAttempts) == "number" then
		context.debrisSpawnAttempts = (context.debrisSpawnAttempts or 0) + voxelizeResult.debrisSpawnAttempts
	elseif typeof(replayVoxelOptions.debrisSpawnAttempts) == "number" then
		context.debrisSpawnAttempts = (context.debrisSpawnAttempts or 0) + replayVoxelOptions.debrisSpawnAttempts
	end
	if typeof(voxelizeResult) == "table" and typeof(voxelizeResult.debrisPartsSpawned) == "number" then
		context.debrisPartCount = (context.debrisPartCount or 0) + voxelizeResult.debrisPartsSpawned
	elseif typeof(replayVoxelOptions.spawnedDebrisParts) == "number" then
		context.debrisPartCount = (context.debrisPartCount or 0) + replayVoxelOptions.spawnedDebrisParts
	end
	if recordedDebrisPayloads and recordedDebrisMaxParts > 0 then
		local spawned, attempts, blocks =
			spawnRecordedDebrisPayloads(context, recordedDebrisPayloads, recordedDebrisMaxParts)
		addDebrisDebugCounts(context, spawned, attempts, blocks)
	end
	context.appliedDestructionEvents = (context.appliedDestructionEvents or 0) + 1
	sanitizeGeneratedVoxels(context.outputFolder)
	return true
end

function ReplayMapSimulator.ApplyEventsUpTo(context, events, replayTime: number, startIndex: number?, options): number
	local index = if isFiniteNumber(startIndex) then math.max(math.floor(startIndex), 1) else 1
	if typeof(events) ~= "table" or not isFiniteNumber(replayTime) then
		return index
	end

	local maxEvents = if typeof(options) == "table" and isFiniteNumber(options.maxEvents)
		then math.max(math.floor(options.maxEvents), 0)
		else math.huge
	local processedEvents = 0

	while index <= #events do
		local event = events[index]
		if not (typeof(event) == "table" and isFiniteNumber(event.timestamp)) then
			index += 1
			continue
		end
		if event.timestamp > replayTime then
			break
		end
		if processedEvents >= maxEvents then
			break
		end

		ReplayMapSimulator.ApplyDestructionEvent(context, event, options)
		processedEvents += 1
		index += 1
	end

	return index
end

function ReplayMapSimulator.Create(scene: Instance, payload)
	if type(VoxManager.resetTerrainState) == "function" then
		VoxManager:resetTerrainState()
	end

	local payloadMapId = getPayloadMapId(payload)
	local payloadRoundId = getPayloadRoundId(payload)
	local livePivot = if typeof(payload) == "table" and isFiniteCFrame(payload.mapPivot)
		then payload.mapPivot
		else CFrame.new()
	local context = {
		scene = scene,
		livePivot = livePivot,
		replayPivot = REPLAY_ZONE_PIVOT,
		replayType = if typeof(payload) == "table" and typeof(payload.type) == "string" then payload.type else nil,
		mapId = payloadMapId,
		roundId = payloadRoundId,
		mapRoot = nil,
		outputFolder = nil,
		debrisFolder = nil,
		debrisPartCount = 0,
		debrisPayloadBlocks = 0,
		debrisSpawnAttempts = 0,
		normalizedDestructionEvents = 0,
		baselineDestructionEvents = 0,
		appliedDestructionEvents = 0,
		targetFailures = 0,
		applyFailures = 0,
		fallbackTargetUses = 0,
		targetsHit = 0,
		lastTargetCount = 0,
		lastPrefilteredTargetCount = 0,
		replayTargetsSkippedByPrefilter = 0,
		bedrockTopY = nil,
	}
	setReplayIdentityAttributes(scene, payloadMapId, payloadRoundId)

	local mapFolder = Instance.new("Folder")
	mapFolder.Name = MAP_FOLDER_NAME
	setReplayIdentityAttributes(mapFolder, payloadMapId, payloadRoundId)
	mapFolder.Parent = scene
	context.mapFolder = mapFolder

	local clone = clonePreparedMapTemplate(context.mapId)
	if not clone then
		if payloadMapId then
			warn(("[ReplayMapSimulator] Missing replay map template for payload map %s"):format(payloadMapId))
		else
			warn("[ReplayMapSimulator] Replay payload is missing mapId; replay will build without a map")
		end
		RuntimeProfiler.Count("Client/Replay/MapSimulator/MissingMapTemplates")
		return context
	end

	VoxManager:setDebrisConfig(DestructionConfig)
	VoxManager:setGeneratedVoxelTag(DestructionConfig.Tag)
	VoxManager:setTerrainConfig(DestructionConfig)

	clone.Name = RoundConfig.ActiveMapName
	setReplayIdentityAttributes(clone, payloadMapId, payloadRoundId)
	local pivotToken = RuntimeProfiler.Begin("Client/Replay/MapSimulator/PivotMapClone")
	pivotInstance(clone, context.replayPivot)
	RuntimeProfiler.End("Client/Replay/MapSimulator/PivotMapClone", pivotToken)
	local parentToken = RuntimeProfiler.Begin("Client/Replay/MapSimulator/ParentMapClone")
	clone.Parent = mapFolder
	RuntimeProfiler.End("Client/Replay/MapSimulator/ParentMapClone", parentToken)
	context.staticMapRoot = clone
	context.bedrockTopY = getBedrockTopY(clone)
	if not isFiniteNumber(context.bedrockTopY) then
		RuntimeProfiler.Count("Client/Replay/MapSimulator/MissingBedrock")
		warn(
			("[ReplayMapSimulator] Replay map %s is missing a BasePart named %s; destruction will not clamp."):format(
				tostring(payloadMapId),
				BEDROCK_PART_NAME
			)
		)
	end

	local outputFolder = Instance.new("Folder")
	outputFolder.Name = CURRENT_VOXELS_FOLDER_NAME
	outputFolder.Parent = mapFolder

	local debrisFolder = Instance.new("Folder")
	debrisFolder.Name = DEBRIS_FOLDER_NAME
	debrisFolder.Parent = mapFolder

	context.mapRoot = mapFolder
	context.outputFolder = outputFolder
	context.debrisFolder = debrisFolder
	return context
end

local function normalizePrewarmPriority(priority: any): string
	return if priority == PRIORITY_ACTIVE then PRIORITY_ACTIVE else PRIORITY_BACKGROUND
end

local function findPreparedSceneEvictionIndex(currentMapId: string): number?
	local fallbackIndex = nil
	for index, mapId in ipairs(preparedSceneOrder) do
		if mapId == currentMapId then
			continue
		end
		local entry = preparedSceneCache[mapId]
		if fallbackIndex == nil then
			fallbackIndex = index
		end
		if not entry or entry.priority ~= PRIORITY_ACTIVE then
			return index
		end
	end
	return fallbackIndex
end

local function rememberPreparedScene(mapId: string, scene: Folder, mapContext, priority: any)
	if activePrewarmMapId ~= mapId then
		destroyPreparedSceneEntry({
			scene = scene,
			mapContext = mapContext,
		})
		RuntimeProfiler.Count("Client/Replay/MapSimulator/PreparedSceneDiscardedInactiveMap")
		return
	end

	clearPreparedScenesExcept(mapId)
	local existing = preparedSceneCache[mapId]
	if existing then
		destroyPreparedSceneEntry(existing)
	end
	destroyDuplicatePreparedScenes(mapId, scene)
	setReplayIdentityAttributes(scene, mapId, nil)
	if typeof(mapContext) == "table" then
		mapContext.mapId = mapId
		mapContext.roundId = nil
		if mapContext.mapFolder then
			setReplayIdentityAttributes(mapContext.mapFolder, mapId, nil)
		end
		if mapContext.staticMapRoot then
			setReplayIdentityAttributes(mapContext.staticMapRoot, mapId, nil)
		end
	end
	if not preparedSceneCache[mapId] then
		table.insert(preparedSceneOrder, mapId)
	end

	preparedSceneCache[mapId] = {
		mapId = mapId,
		scene = scene,
		mapContext = mapContext,
		priority = normalizePrewarmPriority(priority),
	}

	while #preparedSceneOrder > MAX_PREPARED_REUSABLE_SCENES do
		local evictionIndex = findPreparedSceneEvictionIndex(mapId)
		if not evictionIndex then
			break
		end
		local oldMapId = table.remove(preparedSceneOrder, evictionIndex)
		local oldEntry = oldMapId and preparedSceneCache[oldMapId]
		preparedSceneCache[oldMapId] = nil
		destroyPreparedSceneEntry(oldEntry)
	end
end

local function isPreparedSceneEntryUsable(entry, expectedMapId: string): boolean
	if typeof(entry) ~= "table" then
		return false
	end
	if entry.mapId ~= expectedMapId then
		warnPreparedSceneMismatch("entry-map", expectedMapId, entry.mapId)
		return false
	end
	if not (entry.scene and entry.mapContext) then
		return false
	end

	local sceneMapId = entry.scene:GetAttribute("ReplayMapId")
	if sceneMapId ~= nil and sceneMapId ~= expectedMapId then
		warnPreparedSceneMismatch("scene-attribute", expectedMapId, sceneMapId)
		return false
	end
	if typeof(entry.mapContext) ~= "table" or entry.mapContext.mapId ~= expectedMapId then
		warnPreparedSceneMismatch(
			"context-map",
			expectedMapId,
			if typeof(entry.mapContext) == "table" then entry.mapContext.mapId else nil
		)
		return false
	end

	local staticMapRoot = entry.mapContext.staticMapRoot
	if staticMapRoot and staticMapRoot:GetAttribute("ReplayMapId") ~= nil then
		local rootMapId = staticMapRoot:GetAttribute("ReplayMapId")
		if rootMapId ~= expectedMapId then
			warnPreparedSceneMismatch("map-root-attribute", expectedMapId, rootMapId)
			return false
		end
	end
	return true
end

function ReplayMapSimulator.SetActivePrewarmMap(mapId: any): string?
	local resolvedMapId = normalizeMapId(mapId)
	if activePrewarmMapId == resolvedMapId then
		clearPreparedScenesExcept(resolvedMapId)
		clearPreparedTemplatesExcept(resolvedMapId)
		return resolvedMapId
	end

	activePrewarmMapId = resolvedMapId
	activePrewarmSerial += 1
	prewarmRequested = resolvedMapId ~= nil and prewarmRequested or false
	clearPreparedScenesExcept(resolvedMapId)
	clearPreparedTemplatesExcept(resolvedMapId)
	RuntimeProfiler.Count(
		if resolvedMapId
			then "Client/Replay/MapSimulator/ActivePrewarmMapSet"
			else "Client/Replay/MapSimulator/ActivePrewarmMapCleared"
	)
	return resolvedMapId
end

function ReplayMapSimulator.PrewarmReusableScene(mapId: any, options): boolean
	mapId = normalizeMapId(mapId)
	if not mapId then
		return false
	end
	local priority = normalizePrewarmPriority(if typeof(options) == "table" then options.priority else nil)
	if priority ~= PRIORITY_ACTIVE then
		RuntimeProfiler.Count("Client/Replay/MapSimulator/BackgroundScenePrewarmSkipped")
		return false
	end

	ReplayMapSimulator.SetActivePrewarmMap(mapId)
	clearPreparedScenesExcept(mapId)
	clearPreparedTemplatesExcept(mapId)

	local existing = preparedSceneCache[mapId]
	if existing then
		existing.priority = PRIORITY_ACTIVE
		RuntimeProfiler.Count("Client/Replay/MapSimulator/ReusableScenePrewarmCacheHit")
		return true
	end

	prewarmRequested = true
	if prewarmWorkerRunning then
		RuntimeProfiler.Count("Client/Replay/MapSimulator/ActiveScenePrewarmCoalesced")
		return true
	end

	prewarmWorkerRunning = true
	RuntimeProfiler.Count("Client/Replay/MapSimulator/ActiveReusableScenePrewarmQueued")
	task.spawn(function()
		while prewarmRequested do
			prewarmRequested = false
			task.wait()

			local targetMapId = activePrewarmMapId
			if not targetMapId then
				RuntimeProfiler.Count("Client/Replay/MapSimulator/ActiveScenePrewarmSkippedNoActiveMap")
				continue
			end

			clearPreparedScenesExcept(targetMapId)
			clearPreparedTemplatesExcept(targetMapId)

			local cached = preparedSceneCache[targetMapId]
			if cached and isPreparedSceneEntryUsable(cached, targetMapId) then
				RuntimeProfiler.Count("Client/Replay/MapSimulator/ReusableScenePrewarmCacheHit")
				continue
			end

			if not getMapTemplate(targetMapId) then
				RuntimeProfiler.Count("Client/Replay/MapSimulator/ActiveScenePrewarmMissingTemplate")
				continue
			end

			local serial = activePrewarmSerial
			local token = RuntimeProfiler.Begin("Client/Replay/MapSimulator/PrewarmReusableScene")
			local ok, err = pcall(function()
				ReplayMapSimulator.PrewarmTemplate(targetMapId)
				task.wait()
				if not isActivePrewarmRequest(targetMapId, serial) then
					RuntimeProfiler.Count("Client/Replay/MapSimulator/ActiveScenePrewarmCanceled")
					return
				end

				local scene = createPreparedScene(targetMapId)
				local mapContext = ReplayMapSimulator.Create(scene, {
					mapId = targetMapId,
					mapPivot = CFrame.new(),
				})
				if not isActivePrewarmRequest(targetMapId, serial) then
					destroyPreparedSceneEntry({
						scene = scene,
						mapContext = mapContext,
					})
					RuntimeProfiler.Count("Client/Replay/MapSimulator/ActiveScenePrewarmCanceled")
					return
				end
				if not (mapContext and mapContext.mapRoot) then
					ReplayMapSimulator.ScheduleDestroyScene(scene, "InvalidPrewarm")
					return
				end

				task.wait()
				if not isActivePrewarmRequest(targetMapId, serial) then
					destroyPreparedSceneEntry({
						scene = scene,
						mapContext = mapContext,
					})
					RuntimeProfiler.Count("Client/Replay/MapSimulator/ActiveScenePrewarmCanceled")
					return
				end

				prewarmStaticDestructibleTargets(mapContext)
				if not isActivePrewarmRequest(targetMapId, serial) then
					destroyPreparedSceneEntry({
						scene = scene,
						mapContext = mapContext,
					})
					RuntimeProfiler.Count("Client/Replay/MapSimulator/ActiveScenePrewarmCanceled")
					return
				end

				rememberPreparedScene(targetMapId, scene, mapContext, PRIORITY_ACTIVE)
				clearPreparedTemplatesExcept(nil)
				RuntimeProfiler.Count("Client/Replay/MapSimulator/PrewarmedActiveReusableScenes")
			end)
			RuntimeProfiler.End("Client/Replay/MapSimulator/PrewarmReusableScene", token)
			if not ok then
				warn("[ReplayMapSimulator] Failed to prewarm reusable replay scene: " .. tostring(err))
			end
		end
		prewarmWorkerRunning = false
		if prewarmRequested then
			ReplayMapSimulator.PrewarmActiveScene(activePrewarmMapId)
		end
	end)
	return true
end

function ReplayMapSimulator.PrewarmActiveScene(mapId: any): boolean
	mapId = normalizeMapId(mapId)
	if not mapId then
		ReplayMapSimulator.SetActivePrewarmMap(nil)
		return false
	end

	return ReplayMapSimulator.PrewarmReusableScene(mapId, {
		priority = PRIORITY_ACTIVE,
	})
end

function ReplayMapSimulator.PrewarmReusableScenes(_limit: number?): number
	if not activePrewarmMapId then
		RuntimeProfiler.Count("Client/Replay/MapSimulator/ReusableScenePrewarmSkippedNoActiveMap")
		return 0
	end

	if ReplayMapSimulator.PrewarmActiveScene(activePrewarmMapId) then
		RuntimeProfiler.Count("Client/Replay/MapSimulator/ReusableScenePrewarmQueued", 1)
		return 1
	end
	return 0
end

function ReplayMapSimulator.TakePreparedScene(payload): (Folder?, any?)
	local mapId = getPayloadMapId(payload)
	local roundId = getPayloadRoundId(payload)
	if not mapId then
		RuntimeProfiler.Count("Client/Replay/MapSimulator/PreparedSceneMisses")
		warn("[ReplayMapSimulator] Cannot use prepared replay scene without payload mapId")
		return nil, nil
	end

	local entry = preparedSceneCache[mapId]
	if not isPreparedSceneEntryUsable(entry, mapId) then
		preparedSceneCache[mapId] = nil
		destroyPreparedSceneEntry(entry)
		RuntimeProfiler.Count("Client/Replay/MapSimulator/PreparedSceneMisses")
		RuntimeProfiler.Count("Client/Replay/MapSimulator/PreparedSceneRejected")
		return nil, nil
	end

	preparedSceneCache[mapId] = nil
	for index, queuedMapId in ipairs(preparedSceneOrder) do
		if queuedMapId == mapId then
			table.remove(preparedSceneOrder, index)
			break
		end
	end

	local existing = Workspace:FindFirstChild(SCENE_NAME)
	if existing and existing ~= entry.scene then
		ReplayMapSimulator.ScheduleDestroyScene(existing, "ExistingActive")
	end

	entry.scene.Name = SCENE_NAME
	entry.scene:SetAttribute(LOCAL_REPLAY_ATTR, true)
	setReplayIdentityAttributes(entry.scene, mapId, roundId)
	entry.scene.Parent = Workspace
	entry.mapContext.livePivot = if typeof(payload) == "table" and isFiniteCFrame(payload.mapPivot)
		then payload.mapPivot
		else CFrame.new()
	entry.mapContext.scene = entry.scene
	entry.mapContext.replayType = if typeof(payload) == "table" and typeof(payload.type) == "string"
		then payload.type
		else nil
	entry.mapContext.mapId = mapId
	entry.mapContext.roundId = roundId
	if entry.mapContext.mapFolder then
		setReplayIdentityAttributes(entry.mapContext.mapFolder, mapId, roundId)
	end
	if entry.mapContext.staticMapRoot then
		setReplayIdentityAttributes(entry.mapContext.staticMapRoot, mapId, roundId)
	end
	RuntimeProfiler.Count("Client/Replay/MapSimulator/PreparedSceneHits")
	return entry.scene, entry.mapContext
end

function ReplayMapSimulator.Destroy(_context)
	if type(VoxManager.resetTerrainState) == "function" then
		VoxManager:resetTerrainState()
	end
	if type(VoxManager.cleanupVoxelCache) == "function" then
		VoxManager:cleanupVoxelCache()
	end
end

function ReplayMapSimulator.GetMaxDestructionEventsPerStep(): number
	return MAX_DESTRUCTION_EVENTS_PER_STEP
end

function ReplayMapSimulator.GetDebugInfo(context)
	if typeof(context) ~= "table" then
		return {}
	end

	return {
		mapId = context.mapId,
		replayType = context.replayType,
		normalizedDestructionEvents = context.normalizedDestructionEvents or 0,
		baselineDestructionEvents = context.baselineDestructionEvents or 0,
		skippedDestructionEventsBeforeWindow = context.skippedDestructionEventsBeforeWindow or 0,
		skippedDestructionEventsAfterWindow = context.skippedDestructionEventsAfterWindow or 0,
		appliedDestructionEvents = context.appliedDestructionEvents or 0,
		targetFailures = context.targetFailures or 0,
		applyFailures = context.applyFailures or 0,
		fallbackTargetUses = context.fallbackTargetUses or 0,
		targetsHit = context.targetsHit or 0,
		lastTargetCount = context.lastTargetCount or 0,
		lastPrefilteredTargetCount = context.lastPrefilteredTargetCount or 0,
		lastCappedTargetCount = context.lastCappedTargetCount or 0,
		replayTargetsSkippedByPrefilter = context.replayTargetsSkippedByPrefilter or 0,
		replayTargetsSkippedByCap = context.replayTargetsSkippedByCap or 0,
		debrisPartCount = context.debrisPartCount or 0,
		debrisPayloadBlocks = context.debrisPayloadBlocks or 0,
		debrisSpawnAttempts = context.debrisSpawnAttempts or 0,
	}
end

return ReplayMapSimulator
