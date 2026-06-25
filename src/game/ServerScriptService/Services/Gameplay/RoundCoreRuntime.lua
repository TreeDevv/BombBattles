local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local InstanceUtil = require(ReplicatedStorage.Shared.Common.InstanceUtil)

local RoundCoreRuntime = {}

local CORE_HEALTH_ATTR = RoundConfig.Cores.HealthAttribute
local CORE_DESTROYED_ATTR = RoundConfig.Cores.DestroyedAttribute
local CORE_INITIAL_HEALTH_ATTR = "RoundCoreInitialHealth"
local PART_ORIGINAL_TRANSPARENCY_ATTR = "RoundCoreOriginalTransparency"
local PART_ORIGINAL_CAN_COLLIDE_ATTR = "RoundCoreOriginalCanCollide"
local PART_ORIGINAL_CAN_QUERY_ATTR = "RoundCoreOriginalCanQuery"
local PART_ORIGINAL_CAN_TOUCH_ATTR = "RoundCoreOriginalCanTouch"

local function hasBasePartDescendant(instance: Instance): boolean
	return #InstanceUtil.GetBaseParts(instance) > 0
end

local function getSpawnAnchorTemplate(teamName: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local spawnAnchors = assets and assets:FindFirstChild("SpawnAnchors")
	local template = spawnAnchors and spawnAnchors:FindFirstChild(teamName)
	return if template and template:IsA("Model") then template else nil
end

local function copyCoreAttributes(source: Instance, target: Instance, teamName: string)
	for attributeName, value in pairs(source:GetAttributes()) do
		target:SetAttribute(attributeName, value)
	end

	target:SetAttribute("Team", teamName)
	if typeof(target:GetAttribute(CORE_HEALTH_ATTR)) ~= "number" then
		target:SetAttribute(CORE_HEALTH_ATTR, RoundConfig.Cores.DefaultHealth)
	end
	if typeof(target:GetAttribute(CORE_DESTROYED_ATTR)) ~= "boolean" then
		target:SetAttribute(CORE_DESTROYED_ATTR, false)
	end
end

local function anchorBaseParts(instance: Instance)
	for _, part in ipairs(InstanceUtil.GetBaseParts(instance)) do
		part.Anchored = true
	end
end

local function preservePartVisualState(part: BasePart)
	if typeof(part:GetAttribute(PART_ORIGINAL_TRANSPARENCY_ATTR)) ~= "number" then
		part:SetAttribute(PART_ORIGINAL_TRANSPARENCY_ATTR, part.Transparency)
	end
	if typeof(part:GetAttribute(PART_ORIGINAL_CAN_COLLIDE_ATTR)) ~= "boolean" then
		part:SetAttribute(PART_ORIGINAL_CAN_COLLIDE_ATTR, part.CanCollide)
	end
	if typeof(part:GetAttribute(PART_ORIGINAL_CAN_QUERY_ATTR)) ~= "boolean" then
		part:SetAttribute(PART_ORIGINAL_CAN_QUERY_ATTR, part.CanQuery)
	end
	if typeof(part:GetAttribute(PART_ORIGINAL_CAN_TOUCH_ATTR)) ~= "boolean" then
		part:SetAttribute(PART_ORIGINAL_CAN_TOUCH_ATTR, part.CanTouch)
	end
end

local function restorePartVisualState(part: BasePart)
	local transparency = part:GetAttribute(PART_ORIGINAL_TRANSPARENCY_ATTR)
	if typeof(transparency) == "number" then
		part.Transparency = math.clamp(transparency, 0, 1)
	end

	local canCollide = part:GetAttribute(PART_ORIGINAL_CAN_COLLIDE_ATTR)
	if typeof(canCollide) == "boolean" then
		part.CanCollide = canCollide
	end

	local canQuery = part:GetAttribute(PART_ORIGINAL_CAN_QUERY_ATTR)
	if typeof(canQuery) == "boolean" then
		part.CanQuery = canQuery
	end

	local canTouch = part:GetAttribute(PART_ORIGINAL_CAN_TOUCH_ATTR)
	if typeof(canTouch) == "boolean" then
		part.CanTouch = canTouch
	end
end

local function getInitialCoreHealth(core: Instance): number
	local initialHealth = core:GetAttribute(CORE_INITIAL_HEALTH_ATTR)
	if typeof(initialHealth) == "number" and initialHealth > 0 then
		return initialHealth
	end

	local health = core:GetAttribute(CORE_HEALTH_ATTR)
	if typeof(health) ~= "number" or health <= 0 then
		health = RoundConfig.Cores.DefaultHealth
	end

	core:SetAttribute(CORE_INITIAL_HEALTH_ATTR, health)
	return health
end

function RoundCoreRuntime.RestoreCoreVisuals(core: Instance?)
	if not core then
		return
	end

	for _, part in ipairs(InstanceUtil.GetBaseParts(core)) do
		restorePartVisualState(part)
		part.Anchored = true
	end
end

function RoundCoreRuntime.ApplyDestroyedVisuals(core: Instance?)
	if not core then
		return
	end

	for _, part in ipairs(InstanceUtil.GetBaseParts(core)) do
		preservePartVisualState(part)
		part.Transparency = 1
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Anchored = true
	end
end

function RoundCoreRuntime.PrepareCoreForRound(core: Instance, teamName: string): Instance
	local initialHealth = getInitialCoreHealth(core)
	core:SetAttribute("Team", teamName)
	core:SetAttribute(CORE_HEALTH_ATTR, initialHealth)
	core:SetAttribute(CORE_DESTROYED_ATTR, false)

	local humanoid = core:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = math.max(humanoid.MaxHealth, initialHealth)
		humanoid.Health = math.clamp(initialHealth, 0, humanoid.MaxHealth)
	end

	RoundCoreRuntime.RestoreCoreVisuals(core)
	return core
end

function RoundCoreRuntime.RepairEmptyCoreModel(core: Instance, teamName: string): Instance
	if hasBasePartDescendant(core) or not core:IsA("Model") then
		return core
	end

	local template = getSpawnAnchorTemplate(teamName)
	if not template then
		warn("[RoundCoreRuntime] TeamCore model has no BasePart descendants and no SpawnAnchors template exists:", teamName)
		return core
	end

	local parent = core.Parent
	if not parent then
		return core
	end

	local replacement = template:Clone()
	replacement.Name = core.Name
	copyCoreAttributes(core, replacement, teamName)
	anchorBaseParts(replacement)
	replacement.Parent = parent
	replacement:PivotTo(core:GetPivot())
	CollectionService:AddTag(replacement, RoundConfig.Tags.TeamCore)
	CollectionService:RemoveTag(core, RoundConfig.Tags.TeamCore)
	core:Destroy()

	warn("[RoundCoreRuntime] Repaired empty TeamCore model from SpawnAnchors template:", teamName)
	return replacement
end

function RoundCoreRuntime.IsCoreAlive(core: Instance): boolean
	if not core.Parent then
		return false
	end
	if core:GetAttribute(CORE_DESTROYED_ATTR) == true then
		return false
	end

	local health = core:GetAttribute(CORE_HEALTH_ATTR)
	if typeof(health) == "number" and health <= 0 then
		return false
	end

	local humanoid = core:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return false
	end

	return true
end

function RoundCoreRuntime.CountAliveCores(teamCoreInstances): { [string]: number }
	local counts = {
		[RoundConfig.Teams.Red.name] = 0,
		[RoundConfig.Teams.Blue.name] = 0,
	}

	for teamName, cores in pairs(teamCoreInstances) do
		counts[teamName] = counts[teamName] or 0
		for _, core in ipairs(cores) do
			if RoundCoreRuntime.IsCoreAlive(core) then
				counts[teamName] += 1
			end
		end
	end

	return counts
end

function RoundCoreRuntime.BuildRespawnState(coreCounts: { [string]: number }): { [string]: boolean }
	local respawnsEnabled = {}
	for _, teamConfig in pairs(RoundConfig.Teams) do
		respawnsEnabled[teamConfig.name] = (coreCounts[teamConfig.name] or 0) > 0
	end
	return respawnsEnabled
end

function RoundCoreRuntime.TeamHasRespawns(teamCoreInstances, teamName: string?): boolean
	if not teamName then
		return false
	end

	local cores = teamCoreInstances[teamName]
	if not cores then
		return false
	end

	for _, core in ipairs(cores) do
		if RoundCoreRuntime.IsCoreAlive(core) then
			return true
		end
	end

	return false
end

function RoundCoreRuntime.BindCore(options)
	local core: Instance = options.core
	local map: Instance = options.map
	local connections = options.connections
	local runtimeProfiler = options.runtimeProfiler

	connections:Reset(core)

	local function onCoreStateChanged()
		if options.isRoundActive() then
			options.syncCoreState()
		end
	end

	connections:Add(core, core:GetAttributeChangedSignal(CORE_HEALTH_ATTR):Connect(onCoreStateChanged))
	connections:Add(core, core:GetAttributeChangedSignal(CORE_DESTROYED_ATTR):Connect(onCoreStateChanged))
	connections:Add(core, core.AncestryChanged:Connect(function()
		if not core:IsDescendantOf(map) then
			onCoreStateChanged()
		end
	end))

	local humanoid = core:FindFirstChildOfClass("Humanoid")
	if humanoid then
		connections:Add(core, humanoid.Died:Connect(onCoreStateChanged))
		connections:Add(core, humanoid.HealthChanged:Connect(onCoreStateChanged))
	end

	if runtimeProfiler then
		runtimeProfiler.Count("Server/Round/Map/BoundTeamCore")
	end
end

function RoundCoreRuntime.SetupTeamCores(options): boolean
	local runtimeProfiler = options.runtimeProfiler
	local token = runtimeProfiler.Begin("Server/Round/Map/SetupTeamCores")
	options.disconnectCoreConnections()
	table.clear(options.teamCoreInstances)

	for _, teamName in ipairs(options.teamOrder) do
		local findToken = runtimeProfiler.Begin("Server/Round/Map/FindTeamCores")
		local cores = options.getTeamCores(teamName, options.map)
		runtimeProfiler.End("Server/Round/Map/FindTeamCores", findToken)
		runtimeProfiler.Count("Server/Round/Map/TeamCoreCandidates", #cores)
		local repairedCores = {}
		for _, core in ipairs(cores) do
			local coreToken = runtimeProfiler.Begin("Server/Round/Map/PrepareTeamCore")
			local repairedCore = RoundCoreRuntime.RepairEmptyCoreModel(core, teamName)
			table.insert(repairedCores, RoundCoreRuntime.PrepareCoreForRound(repairedCore, teamName))
			runtimeProfiler.End("Server/Round/Map/PrepareTeamCore", coreToken)
		end
		options.teamCoreInstances[teamName] = repairedCores

		for _, core in ipairs(repairedCores) do
			local bindToken = runtimeProfiler.Begin("Server/Round/Map/BindTeamCore")
			RoundCoreRuntime.BindCore({
				core = core,
				map = options.map,
				connections = options.coreConnections,
				runtimeProfiler = runtimeProfiler,
				isRoundActive = options.isRoundActive,
				syncCoreState = options.syncCoreState,
			})
			runtimeProfiler.End("Server/Round/Map/BindTeamCore", bindToken)
		end
	end

	local syncToken = runtimeProfiler.Begin("Server/Round/Map/SyncCoreState")
	options.syncCoreState()
	runtimeProfiler.End("Server/Round/Map/SyncCoreState", syncToken)
	runtimeProfiler.End("Server/Round/Map/SetupTeamCores", token)
	return true
end

function RoundCoreRuntime.FindTrackedCore(instance: Instance, teamCoreInstances): Instance?
	local current: Instance? = instance
	while current do
		if CollectionService:HasTag(current, RoundConfig.Tags.TeamCore) then
			for _, cores in pairs(teamCoreInstances) do
				if table.find(cores, current) then
					return current
				end
			end
		end

		current = current.Parent
	end

	return nil
end

function RoundCoreRuntime.MarkCoreDestroyed(core: Instance?): boolean
	if not core then
		return false
	end

	core:SetAttribute(CORE_HEALTH_ATTR, 0)
	core:SetAttribute(CORE_DESTROYED_ATTR, true)
	RoundCoreRuntime.ApplyDestroyedVisuals(core)
	return true
end

function RoundCoreRuntime.DamageCore(options): boolean
	if not options.isRoundActive then
		return false
	end
	if typeof(options.damage) ~= "number" or options.damage <= 0 then
		return false
	end

	local trackedCore = options.core
	if not trackedCore or not RoundCoreRuntime.IsCoreAlive(trackedCore) then
		return false
	end

	local sourceContext = options.sourceContext
	local teamName = trackedCore:GetAttribute("Team")
	local payload = {
		teamName = if typeof(teamName) == "string" then teamName else nil,
		baseId = trackedCore.Name,
		amount = options.damage,
		attackerUserId = if typeof(sourceContext) == "table" then sourceContext.attackerUserId else nil,
		sourceType = if typeof(sourceContext) == "table" then sourceContext.sourceType else nil,
		sourceId = if typeof(sourceContext) == "table" then sourceContext.sourceId else nil,
		roundTimeRemaining = options.getRoundSecondsRemaining(),
	}

	local humanoid = trackedCore:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local healthBefore = humanoid.Health
		payload.amount = math.min(options.damage, math.max(healthBefore, 0))
		humanoid:TakeDamage(options.damage)
		local healthAfter = humanoid.Health
		local destroyed = healthBefore > 0 and healthAfter <= 0
		payload.healthBefore = healthBefore
		payload.healthAfter = healthAfter
		payload.baseDestroyed = destroyed
		payload.coreDestroyed = destroyed
		payload.finalBlow = destroyed
		if destroyed then
			trackedCore:SetAttribute(CORE_HEALTH_ATTR, 0)
			trackedCore:SetAttribute(CORE_DESTROYED_ATTR, true)
			RoundCoreRuntime.ApplyDestroyedVisuals(trackedCore)
		end
		options.recordReplayEvent("BaseDamaged", payload)
		options.syncCoreState()
		return true
	end

	local health = trackedCore:GetAttribute(CORE_HEALTH_ATTR)
	if typeof(health) ~= "number" then
		health = RoundConfig.Cores.DefaultHealth
	end

	payload.amount = math.min(options.damage, math.max(health, 0))
	payload.healthBefore = health
	health -= options.damage
	trackedCore:SetAttribute(CORE_HEALTH_ATTR, math.max(health, 0))
	if health <= 0 then
		trackedCore:SetAttribute(CORE_DESTROYED_ATTR, true)
		RoundCoreRuntime.ApplyDestroyedVisuals(trackedCore)
	end
	payload.healthAfter = math.max(health, 0)
	payload.baseDestroyed = health <= 0
	payload.coreDestroyed = health <= 0
	payload.finalBlow = health <= 0

	options.recordReplayEvent("BaseDamaged", payload)
	options.syncCoreState()
	return true
end

return table.freeze(RoundCoreRuntime)
