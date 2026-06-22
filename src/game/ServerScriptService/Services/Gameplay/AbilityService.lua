local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local DataService = require(ServerScriptService.Services.DataService)
local EmoteService = require(ServerScriptService.Services.EmoteService)
local RoundService = require(ServerScriptService.Services.RoundService)
local ReplicaService = require(ServerScriptService.Packages.ReplicaService)

local REMOTES_FOLDER_NAME = AbilityConfig.RemotesFolderName
local REQUEST_REMOTE_NAME = AbilityConfig.RequestRemoteName
local EFFECT_REMOTE_NAME = AbilityConfig.EffectRemoteName
local MESSAGE_TYPES = AbilityConfig.MessageTypes
local DEBUG_REPLAY_EVENTS = false

local ABILITY_STATE_TOKEN = ReplicaService.NewClassToken(AbilityConfig.Scope)

type PlayerRuntime = {
	replica: any?,
	requestWindowStartedAt: number,
	requestCount: number,
	messageWindows: { [string]: { startedAt: number, count: number } },
}

type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityHookResult = AbilityTypes.AbilityHookResult
type AbilityLoadout = AbilityTypes.AbilityLoadout
type AbilitySlotState = AbilityTypes.AbilitySlotState
type AbilityState = AbilityTypes.AbilityState
type ServerBehavior = AbilityTypes.ServerBehavior
type ResolvedAbilityRequest = {
	slot: string,
	slotState: AbilitySlotState,
	abilityId: string,
	definition: AbilityDefinition,
	messageType: string,
	payload: any?,
	clientSequence: number?,
}
type HookCandidate = {
	player: Player,
	slot: string,
	slotState: AbilitySlotState,
	abilityId: string,
	definition: AbilityDefinition,
	behavior: ServerBehavior,
	priority: number,
}

local AbilityService = {}

local requestRemote: RemoteEvent? = nil
local effectRemote: RemoteEvent? = nil
local hookFrameConnection: RBXScriptConnection? = nil
local hookCacheFrame = 0
local runtimes: { [Player]: PlayerRuntime } = {}
local behaviorModules: { [string]: ServerBehavior } = {}
local behaviorHookNames: { [string]: boolean } = {}
local hookCandidateCache: { [string]: { frame: number, currentTime: number, candidates: { HookCandidate } } } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local replayService = nil

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

	if DEBUG_REPLAY_EVENTS then
		warn("[AbilityService] ReplayService require failed:", service)
	end
	return nil
end

local function recordReplayEvent(eventType: string, payload: any?)
	local service = getReplayService()
	if not (service and type(service.RecordEvent) == "function") then
		return
	end

	local ok, err = pcall(function()
		service.RecordEvent(eventType, payload)
	end)
	if DEBUG_REPLAY_EVENTS and not ok then
		warn("[AbilityService] Replay event failed:", eventType, err)
	end
end

local worldTextService = nil

local function getWorldTextService()
	if worldTextService then
		return worldTextService
	end

	local services = ServerScriptService:FindFirstChild("Services")
	local worldTextModule = services and services:FindFirstChild("WorldTextService")
	if not (worldTextModule and worldTextModule:IsA("ModuleScript")) then
		return nil
	end

	local ok, service = pcall(require, worldTextModule)
	if ok and typeof(service) == "table" then
		worldTextService = service
		return worldTextService
	end

	return nil
end

local function sendWorldText(methodName: string, ...)
	local service = getWorldTextService()
	if not service then
		return
	end

	local method = service[methodName]
	if type(method) ~= "function" then
		return
	end

	pcall(function(...)
		method(...)
	end, ...)
end

local function getPlayerRootPosition(player: Player): Vector3?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart.Position else nil
end

local function ensureRemotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = REMOTES_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureRemote(name: string): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

local function getBehaviorFolder(): Instance?
	local services = ServerScriptService:FindFirstChild("Services")
	return services and services:FindFirstChild("AbilityBehaviors")
end

local function loadBehaviors()
	table.clear(behaviorModules)
	table.clear(behaviorHookNames)
	table.clear(hookCandidateCache)

	local folder = getBehaviorFolder()
	if not folder then
		return
	end

	for _, child in ipairs(folder:GetChildren()) do
		if not child:IsA("ModuleScript") then
			continue
		end

		local ok, behavior = pcall(require, child)
		if ok and typeof(behavior) == "table" then
			behaviorModules[child.Name] = behavior
			for key, value in pairs(behavior) do
				if typeof(key) == "string" and type(value) == "function" then
					behaviorHookNames[key] = true
				end
			end
		else
			warn("[AbilityService] Failed to load ability behavior " .. child:GetFullName() .. ": " .. tostring(behavior))
		end
	end
end

local function createRuntime(): PlayerRuntime
	return {
		replica = nil,
		requestWindowStartedAt = 0,
		requestCount = 0,
		messageWindows = {},
	}
end

local function getRuntime(player: Player): PlayerRuntime
	local runtime = runtimes[player]
	if runtime then
		return runtime
	end

	runtime = createRuntime()
	runtimes[player] = runtime
	return runtime
end

local function createReplica(player: Player, loadout: any?): any
	local runtime = getRuntime(player)
	if runtime.replica and runtime.replica:IsActive() then
		return runtime.replica
	end

	local replica = ReplicaService.NewReplica({
		ClassToken = ABILITY_STATE_TOKEN,
		Tags = { Player = player },
		Data = AbilityConfig.BuildInitialState(loadout),
		Replication = player,
	})

	runtime.replica = replica
	return replica
end

local function getReplica(player: Player): any?
	local runtime = runtimes[player]
	local replica = runtime and runtime.replica
	if replica and replica:IsActive() then
		return replica
	end
	return nil
end

local function getSlotState(player: Player, slot: string): AbilitySlotState?
	local replica = getReplica(player)
	if not replica then
		return nil
	end

	local slots = replica.Data.slots
	return if typeof(slots) == "table" then slots[slot] else nil
end

local function publishPlayerDebugState(player: Player)
	local replica = getReplica(player)
	player:SetAttribute("AbilityService_StateCreated", replica ~= nil)
	if not replica then
		return
	end

	local slots = replica.Data.slots
	for _, slot in ipairs(AbilityConfig.SlotOrder) do
		local slotState = if typeof(slots) == "table" then slots[slot] else nil
		player:SetAttribute(
			"AbilityService_" .. slot .. "AbilityId",
			if typeof(slotState) == "table" and typeof(slotState.abilityId) == "string" then slotState.abilityId else ""
		)
		player:SetAttribute(
			"AbilityService_" .. slot .. "CooldownEndsAt",
			if typeof(slotState) == "table" and typeof(slotState.cooldownEndsAt) == "number" then slotState.cooldownEndsAt else 0
		)
	end
end

local function getBehavior(abilityId: string, definition: AbilityDefinition?): ServerBehavior?
	local behaviorId = AbilityConfig.GetBehaviorId(abilityId)
	if behaviorId == "" and definition and typeof(definition.id) == "string" then
		behaviorId = definition.id
	end

	return behaviorModules[behaviorId]
end

local function isAliveActivePlayer(player: Player): boolean
	if not CombatEligibility.IsCombatActive(player, RoundService) then
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function isPlainString(value: any, maxLength: number): boolean
	return typeof(value) == "string" and value ~= "" and #value <= maxLength
end

local function checkWindow(window: { startedAt: number, count: number }, maxPerSecond: number, currentTime: number): boolean
	if currentTime - window.startedAt >= 1 then
		window.startedAt = currentTime
		window.count = 0
	end

	window.count += 1
	return window.count <= maxPerSecond
end

local function isRateLimited(
	player: Player,
	abilityId: string,
	messageType: string,
	definition: AbilityDefinition,
	currentTime: number
): boolean
	local runtime = getRuntime(player)
	local globalWindow = {
		startedAt = runtime.requestWindowStartedAt,
		count = runtime.requestCount,
	}

	local allowed = checkWindow(globalWindow, AbilityConfig.GlobalMaxMessagesPerSecond, currentTime)
	runtime.requestWindowStartedAt = globalWindow.startedAt
	runtime.requestCount = globalWindow.count
	if not allowed then
		return true
	end

	local key = abilityId .. ":" .. messageType
	local window = runtime.messageWindows[key]
	if not window then
		window = { startedAt = currentTime, count = 0 }
		runtime.messageWindows[key] = window
	end

	local maxPerSecond = definition.maxClientMessagesPerSecond or AbilityConfig.DefaultMaxMessagesPerSecond
	return not checkWindow(window, maxPerSecond, currentTime)
end

local function resolveRequest(player: Player, request: any): ResolvedAbilityRequest?
	if typeof(request) ~= "table" then
		return nil
	end

	local slot = request.slot
	if not AbilityConfig.IsKnownSlot(slot) then
		return nil
	end

	local slotState = getSlotState(player, slot)
	if typeof(slotState) ~= "table" then
		return nil
	end

	local equippedAbilityId = slotState.abilityId
	local requestedAbilityId = if typeof(request.abilityId) == "string" and request.abilityId ~= "" then request.abilityId else equippedAbilityId
	if requestedAbilityId ~= equippedAbilityId then
		return nil
	end
	if not isPlainString(requestedAbilityId, AbilityConfig.MaxAbilityIdLength) then
		return nil
	end

	local definition = AbilityConfig.GetDefinition(requestedAbilityId)
	if not definition or definition.slot ~= slot then
		return nil
	end

	local messageType = request.messageType
	if not isPlainString(messageType, AbilityConfig.MaxMessageTypeLength) then
		return nil
	end

	return {
		slot = slot,
		slotState = slotState,
		abilityId = requestedAbilityId,
		definition = definition,
		messageType = messageType,
		payload = request.payload,
		clientSequence = request.clientSequence,
	}
end

local function setSlotValues(player: Player, slot: string, values: { [string]: any })
	local replica = getReplica(player)
	if replica then
		replica:SetValues({ "slots", slot }, values)
		publishPlayerDebugState(player)
	end
end

local function fireAbilityEffect(effectName: string, payload: any?)
	if effectRemote then
		effectRemote:FireAllClients(effectName, payload)
	end
end

local function fireAbilityEffectToPlayer(player: Player, effectName: string, payload: any?)
	if effectRemote and player.Parent == Players then
		effectRemote:FireClient(player, effectName, payload)
	end
end

local function activate(player: Player, resolved: ResolvedAbilityRequest, currentTime: number)
	local activateLabel = "Server/Ability/Activate/" .. resolved.abilityId
	local activateToken = RuntimeProfiler.Begin(activateLabel)
	if not isAliveActivePlayer(player) then
		RuntimeProfiler.End(activateLabel, activateToken)
		return
	end
	if typeof(resolved.slotState.cooldownEndsAt) == "number" and resolved.slotState.cooldownEndsAt > currentTime then
		RuntimeProfiler.End(activateLabel, activateToken)
		return
	end

	EmoteService:CancelActive(player, "Ability")

	local behavior = getBehavior(resolved.abilityId, resolved.definition)
	local context = {
		player = player,
		slot = resolved.slot,
		abilityId = resolved.abilityId,
		definition = resolved.definition,
		slotState = resolved.slotState,
		payload = resolved.payload,
		now = currentTime,
	}

	if behavior and type(behavior.CanActivate) == "function" then
		local canActivateLabel = "Server/Ability/CanActivate/" .. resolved.abilityId
		local canActivateToken = RuntimeProfiler.Begin(canActivateLabel)
		local ok, canActivate = pcall(function()
			return behavior.CanActivate(context)
		end)
		RuntimeProfiler.End(canActivateLabel, canActivateToken)
		if not ok then
			warn("[AbilityService] CanActivate failed for " .. resolved.abilityId .. ": " .. tostring(canActivate))
			RuntimeProfiler.End(activateLabel, activateToken)
			return
		end
		if canActivate == false then
			RuntimeProfiler.End(activateLabel, activateToken)
			return
		end
	end

	local behaviorResult = nil
	if behavior and type(behavior.OnActivate) == "function" then
		local onActivateLabel = "Server/Ability/OnActivate/" .. resolved.abilityId
		local onActivateToken = RuntimeProfiler.Begin(onActivateLabel)
		local ok, result = pcall(function()
			return behavior.OnActivate(context)
		end)
		RuntimeProfiler.End(onActivateLabel, onActivateToken)
		if not ok then
			warn("[AbilityService] OnActivate failed for " .. resolved.abilityId .. ": " .. tostring(result))
			RuntimeProfiler.End(activateLabel, activateToken)
			return
		end
		behaviorResult = result
	end
	if behaviorResult == false then
		RuntimeProfiler.End(activateLabel, activateToken)
		return
	end

	local cooldownSeconds = if typeof(behaviorResult) == "table" and typeof(behaviorResult.cooldownSeconds) == "number"
		then math.max(behaviorResult.cooldownSeconds, 0)
		else math.max(tonumber(resolved.definition.cooldownSeconds) or 0, 0)
	local durationSeconds = math.max(tonumber(resolved.definition.durationSeconds) or 0, 0)
	local state = if typeof(behaviorResult) == "table" and typeof(behaviorResult.state) == "table"
		then behaviorResult.state
		else resolved.slotState.state

	setSlotValues(player, resolved.slot, {
		cooldownEndsAt = currentTime + cooldownSeconds,
		activeEndsAt = if durationSeconds > 0 then currentTime + durationSeconds else 0,
		state = state,
	})

	local replica = getReplica(player)
	if replica then
		replica:SetValue({ "lastActivatedAt" }, currentTime)
	end

	fireAbilityEffect("Activated", {
		player = player,
		slot = resolved.slot,
		abilityId = resolved.abilityId,
		startedAt = currentTime,
		activeEndsAt = if durationSeconds > 0 then currentTime + durationSeconds else 0,
	})
	local abilityName = resolved.definition.displayName or resolved.abilityId
	local abilityPosition = getPlayerRootPosition(player)
	recordReplayEvent("AbilityUsed", {
		userId = player.UserId,
		abilityName = abilityName,
		position = abilityPosition,
	})
	sendWorldText("AbilityUsed", player, abilityName, abilityPosition, {
		slot = resolved.slot,
		abilityId = resolved.abilityId,
	})
	if type(DataService.RecordAbilityUsage) == "function" then
		DataService:RecordAbilityUsage(player, resolved.abilityId)
	end

	if typeof(behaviorResult) == "table" and typeof(behaviorResult.effect) == "table" then
		fireAbilityEffect(behaviorResult.effect.name or resolved.abilityId, {
			player = player,
			slot = resolved.slot,
			abilityId = resolved.abilityId,
			payload = behaviorResult.effect.payload,
		})
	end
	RuntimeProfiler.Count("Server/Ability/Activated")
	RuntimeProfiler.End(activateLabel, activateToken)
end

local function handleClientMessage(player: Player, request: any)
	local token = RuntimeProfiler.Begin("Server/Ability/HandleClientMessage")
	RuntimeProfiler.Count("Server/Ability/ClientMessages")
	RuntimeProfiler.Count("Server/Ability/ClientMessageWeight", RuntimeProfiler.EstimatePayloadWeight(request, 128))
	local currentTime = now()
	local resolved = resolveRequest(player, request)
	if not resolved then
		RuntimeProfiler.End("Server/Ability/HandleClientMessage", token)
		return
	end
	if isRateLimited(player, resolved.abilityId, resolved.messageType, resolved.definition, currentTime) then
		RuntimeProfiler.Count("Server/Ability/RateLimited")
		RuntimeProfiler.End("Server/Ability/HandleClientMessage", token)
		return
	end

	if resolved.messageType == MESSAGE_TYPES.Activate then
		activate(player, resolved, currentTime)
		RuntimeProfiler.End("Server/Ability/HandleClientMessage", token)
		return
	end

	local behavior = getBehavior(resolved.abilityId, resolved.definition)
	if behavior and type(behavior.OnClientMessage) == "function" then
		local clientMessageLabel = "Server/Ability/OnClientMessage/" .. resolved.abilityId
		local clientMessageToken = RuntimeProfiler.Begin(clientMessageLabel)
		local ok, err = pcall(function()
			behavior.OnClientMessage({
				player = player,
				slot = resolved.slot,
				abilityId = resolved.abilityId,
				definition = resolved.definition,
				slotState = resolved.slotState,
				messageType = resolved.messageType,
				payload = resolved.payload,
				clientSequence = resolved.clientSequence,
				now = currentTime,
			})
		end)
		RuntimeProfiler.End(clientMessageLabel, clientMessageToken)
		if not ok then
			warn("[AbilityService] OnClientMessage failed for " .. resolved.abilityId .. ": " .. tostring(err))
		end
	end
	RuntimeProfiler.End("Server/Ability/HandleClientMessage", token)
end

local function cleanupPlayer(player: Player)
	local runtime = runtimes[player]
	if not runtime then
		return
	end

	if runtime.replica then
		runtime.replica:Destroy()
	end
	runtimes[player] = nil
end

local function collectHookCandidates(hookName: string, currentTime: number): { HookCandidate }
	local label = "Server/Ability/CollectHookCandidates/" .. hookName
	local token = RuntimeProfiler.Begin(label)
	local candidates = {}

	for player, runtime in pairs(runtimes) do
		local replica = runtime.replica
		if not (player.Parent == Players and replica and replica:IsActive()) then
			continue
		end

		local slots = replica.Data.slots
		if typeof(slots) ~= "table" then
			continue
		end

		for slot, slotState in pairs(slots) do
			if typeof(slotState) ~= "table" or typeof(slotState.abilityId) ~= "string" or slotState.abilityId == "" then
				continue
			end

			local definition = AbilityConfig.GetDefinition(slotState.abilityId)
			local behavior = getBehavior(slotState.abilityId, definition)
			if not (behavior and type(behavior[hookName]) == "function") then
				continue
			end
			local alwaysRunHooks = behavior.AlwaysRunHooks
			local alwaysRunHook = typeof(alwaysRunHooks) == "table" and alwaysRunHooks[hookName] == true
			if not alwaysRunHook and (typeof(slotState.activeEndsAt) ~= "number" or slotState.activeEndsAt <= currentTime) then
				continue
			end

			table.insert(candidates, {
				player = player,
				slot = slot,
				slotState = slotState,
				abilityId = slotState.abilityId,
				definition = definition,
				behavior = behavior,
				priority = (definition and definition.hookPriority) or 0,
			})
		end
	end

	table.sort(candidates, function(left, right)
		if left.priority == right.priority then
			if left.player.UserId == right.player.UserId then
				return left.slot < right.slot
			end
			return left.player.UserId < right.player.UserId
		end

		return left.priority > right.priority
	end)

	RuntimeProfiler.Count("Server/Ability/HookCandidates/" .. hookName, #candidates)
	RuntimeProfiler.End(label, token)
	return candidates
end

local function getCachedHookCandidates(hookName: string, currentTime: number): { HookCandidate }
	if behaviorHookNames[hookName] ~= true then
		return {}
	end

	local cached = hookCandidateCache[hookName]
	if cached and cached.frame == hookCacheFrame then
		return cached.candidates
	end

	local candidates = collectHookCandidates(hookName, currentTime)
	hookCandidateCache[hookName] = {
		frame = hookCacheFrame,
		currentTime = currentTime,
		candidates = candidates,
	}
	return candidates
end

function AbilityService:OnStart()
	loadBehaviors()
	requestRemote = ensureRemote(REQUEST_REMOTE_NAME)
	effectRemote = ensureRemote(EFFECT_REMOTE_NAME)

	if not hookFrameConnection then
		hookFrameConnection = RunService.Heartbeat:Connect(function()
			hookCacheFrame += 1
			table.clear(hookCandidateCache)
		end)
	end

	requestRemote.OnServerEvent:Connect(handleClientMessage)

	for abilityId, behavior in pairs(behaviorModules) do
		if type(behavior.OnStart) == "function" then
			local ok, err = pcall(function()
				behavior.OnStart(self)
			end)
			if not ok then
				warn("[AbilityService] OnStart failed for " .. abilityId .. ": " .. tostring(err))
			end
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		createReplica(player)
		publishPlayerDebugState(player)
	end
end

function AbilityService:OnPlayerAdded(player: Player)
	createReplica(player)
	publishPlayerDebugState(player)
end

function AbilityService:OnPlayerRemoving(player: Player)
	for abilityId, behavior in pairs(behaviorModules) do
		if type(behavior.OnPlayerRemoving) == "function" then
			local ok, err = pcall(function()
				behavior.OnPlayerRemoving(player)
			end)
			if not ok then
				warn("[AbilityService] OnPlayerRemoving failed for " .. abilityId .. ": " .. tostring(err))
			end
		end
	end

	cleanupPlayer(player)
end

function AbilityService:RunHook(hookName: string, context: any?): AbilityHookResult
	if typeof(hookName) ~= "string" or hookName == "" then
		return AbilityResult.Continue()
	end
	if behaviorHookNames[hookName] ~= true then
		return AbilityResult.Continue()
	end

	local hookLabel = "Server/Ability/RunHook/" .. hookName
	local hookToken = RuntimeProfiler.Begin(hookLabel)
	local currentTime = now()
	for _, candidate in ipairs(getCachedHookCandidates(hookName, currentTime)) do
		local behaviorLabel = "Server/Ability/Hook/" .. hookName .. "/" .. candidate.abilityId
		local behaviorToken = RuntimeProfiler.Begin(behaviorLabel)
		local ok, result = pcall(function()
			return candidate.behavior[hookName]({
				player = candidate.player,
				slot = candidate.slot,
				abilityId = candidate.abilityId,
				definition = candidate.definition,
				slotState = candidate.slotState,
				hook = hookName,
				context = context,
				now = currentTime,
			})
		end)
		RuntimeProfiler.End(behaviorLabel, behaviorToken)
		if not ok then
			warn("[AbilityService] Hook " .. hookName .. " failed for " .. candidate.abilityId .. ": " .. tostring(result))
			continue
		end

		if AbilityResult.IsHandled(result) then
			if typeof(result) == "table" and typeof(result.kind) == "string" then
				RuntimeProfiler.Count("Server/Ability/HandledResult/" .. result.kind)
			else
				RuntimeProfiler.Count("Server/Ability/HandledResult/Unknown")
			end
			RuntimeProfiler.End(hookLabel, hookToken)
			return result
		end
	end

	RuntimeProfiler.End(hookLabel, hookToken)
	return AbilityResult.Continue()
end

function AbilityService:HasHookCandidates(hookName: string): boolean
	if typeof(hookName) ~= "string" or hookName == "" or behaviorHookNames[hookName] ~= true then
		return false
	end

	return #getCachedHookCandidates(hookName, now()) > 0
end

function AbilityService:FireEffect(effectName: string, payload: any?)
	fireAbilityEffect(effectName, payload)
end

function AbilityService:FireEffectToPlayer(player: Player, effectName: string, payload: any?)
	fireAbilityEffectToPlayer(player, effectName, payload)
end

function AbilityService:SetSlotValues(player: Player, slot: string, values: { [string]: any }): boolean
	if not AbilityConfig.IsKnownSlot(slot) then
		return false
	end
	local state = self:GetPlayerState(player)
	local slots = state and state.slots
	if typeof(slots) ~= "table" or typeof(slots[slot]) ~= "table" then
		return false
	end

	setSlotValues(player, slot, values)
	return true
end

function AbilityService:SetEquippedAbility(player: Player, slot: string, abilityId: string): boolean
	if not AbilityConfig.IsKnownSlot(slot) then
		return false
	end

	local resolvedAbilityId = ""
	if typeof(abilityId) == "string" and abilityId ~= "" then
		resolvedAbilityId = AbilityConfig.NormalizeAbilityId(abilityId)
		local definition = AbilityConfig.GetDefinition(resolvedAbilityId)
		if not definition or definition.slot ~= slot then
			return false
		end
	end

	local replica = createReplica(player)
	replica:SetValue({ "slots", slot }, AbilityConfig.BuildSlotState(slot, resolvedAbilityId))
	publishPlayerDebugState(player)
	return true
end

function AbilityService:SetLoadout(player: Player, loadout: AbilityLoadout): boolean
	local replica = createReplica(player, loadout)

	for _, slot in ipairs(AbilityConfig.SlotOrder) do
		local abilityId = AbilityConfig.GetSlotAbility(loadout, slot)
		replica:SetValue({ "slots", slot }, AbilityConfig.BuildSlotState(slot, abilityId))
	end

	publishPlayerDebugState(player)
	return true
end

function AbilityService:GetPlayerState(player: Player): AbilityState?
	local replica = getReplica(player)
	return replica and replica.Data or nil
end

return AbilityService
