local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local ReplayAvatarFactory = {}

local DEFAULT_MAX_CACHE = 32
local NPC_SCAN_SECONDS = 18
local NPC_SCAN_INTERVAL_SECONDS = 2

local maxCache = DEFAULT_MAX_CACHE
local debugEnabled = false
local started = false
local templateCache = {}
local templateOrder = {}
local playerConnections = {}
local workspaceConnections = {}
local watchedNPCModels = {}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function getUserIdKey(userId: any): string?
	if not isFiniteNumber(userId) then
		return nil
	end
	return tostring(math.floor(userId))
end

local function getPositiveUserId(userId: any): number?
	if not (isFiniteNumber(userId) and userId > 0) then
		return nil
	end
	return math.floor(userId)
end

local function getPlayerByUserId(userId: number): Player?
	local resolvedUserId = math.floor(userId)
	local ok, player = pcall(function()
		return Players:GetPlayerByUserId(resolvedUserId)
	end)
	if ok and player then
		return player
	end

	for _, candidate in ipairs(Players:GetPlayers()) do
		if candidate.UserId == resolvedUserId then
			return candidate
		end
	end

	return nil
end

local function getModelRigType(model: Model?): Enum.HumanoidRigType?
	local humanoid = model and model:FindFirstChildOfClass("Humanoid")
	return if humanoid then humanoid.RigType else nil
end

local function isR6Model(model: Model?): boolean
	return getModelRigType(model) == Enum.HumanoidRigType.R6
end

local function getReplayRoot(model: Model): BasePart?
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function warnDebug(message: string, ...)
	if debugEnabled then
		warn("[ReplayAvatarFactory] " .. message, ...)
	end
end

local function sanitizeTemplate(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = false
		elseif descendant:IsA("Sound") then
			descendant.Looped = false
			descendant:Stop()
		elseif descendant:IsA("BillboardGui") or descendant:IsA("Highlight") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			descendant.Massless = true
		end
	end
end

local function validateTemplate(model: any, userId: number, sourceName: string, requireR6: boolean): Model?
	if not (model and typeof(model) == "Instance" and model:IsA("Model")) then
		return nil
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = getReplayRoot(model)
	if not (humanoid and rootPart) then
		warnDebug(
			"Rejected avatar without humanoid/root",
			"user",
			tostring(userId),
			"source",
			sourceName
		)
		model:Destroy()
		return nil
	end

	if requireR6 and not isR6Model(model) then
		warnDebug(
			"Rejected generated non-R6 avatar",
			"user",
			tostring(userId),
			"source",
			sourceName,
			"rig",
			tostring(getModelRigType(model))
		)
		model:Destroy()
		return nil
	end

	sanitizeTemplate(model)
	return model
end

local function cloneCharacter(character: Model): Model?
	local originalArchivable = character.Archivable
	character.Archivable = true
	local ok, clone = pcall(function()
		return character:Clone()
	end)
	character.Archivable = originalArchivable
	return if ok and clone and clone:IsA("Model") then clone else nil
end

local function createLiveTemplate(userId: number): Model?
	local player = getPlayerByUserId(userId)
	local character = player and player.Character
	if not (character and character:IsA("Model")) then
		return nil
	end

	local clone = cloneCharacter(character)
	return validateTemplate(clone, userId, "LiveCharacter", false)
end

local function getNPCUserId(model: Instance?): number?
	if not (model and model:IsA("Model")) then
		return nil
	end

	local rawUserId = model:GetAttribute("StudioAIUserId")
	if isFiniteNumber(rawUserId) then
		return math.floor(rawUserId)
	end
	return nil
end

local function isReplayNPCModel(model: Instance?): boolean
	if not (model and model:IsA("Model")) then
		return false
	end
	if model:GetAttribute("StudioAIBot") == true then
		return getNPCUserId(model) ~= nil
	end
	return getNPCUserId(model) ~= nil
end

local function createModelTemplate(userId: number, model: Model, sourceName: string): Model?
	local clone = cloneCharacter(model)
	return validateTemplate(clone, userId, sourceName, false)
end

local function destroyTemplate(template: Instance?)
	if template and template.Parent == nil then
		template:Destroy()
	end
end

local function rememberTemplate(userId: number, template: Model, preferLive: boolean)
	local key = getUserIdKey(userId)
	if not key then
		template:Destroy()
		return nil
	end

	template.Name = "ReplayAvatarTemplate_" .. key
	template.Parent = nil

	local existing = templateCache[key]
	if existing == template then
		return template
	end
	if existing and preferLive then
		destroyTemplate(existing)
		templateCache[key] = nil
	end

	if not templateCache[key] then
		table.insert(templateOrder, key)
	end
	templateCache[key] = template

	while #templateOrder > maxCache do
		local oldKey = table.remove(templateOrder, 1)
		local oldTemplate = oldKey and templateCache[oldKey]
		templateCache[oldKey] = nil
		destroyTemplate(oldTemplate)
	end

	return template
end

function ReplayAvatarFactory.CacheLiveCharacter(userId: number): Model?
	local key = getUserIdKey(userId)
	if not key then
		return nil
	end

	local template = createLiveTemplate(math.floor(userId))
	if template then
		warnDebug("Cached live replay avatar", tostring(userId))
		return rememberTemplate(math.floor(userId), template, true)
	end
	return templateCache[key]
end

function ReplayAvatarFactory.CacheLiveModel(userId: number, model: Model, sourceName: string?): Model?
	local key = getUserIdKey(userId)
	if not key or not (model and model:IsA("Model")) then
		return nil
	end

	local template = createModelTemplate(math.floor(userId), model, sourceName or "LiveModel")
	if template then
		warnDebug("Cached live replay model", tostring(userId), sourceName or "LiveModel")
		RuntimeProfiler.Count("Client/Replay/AvatarFactory/CachedLiveModels")
		return rememberTemplate(math.floor(userId), template, true)
	end
	return templateCache[key]
end

local function cacheNPCModelIfEligible(model: Instance?)
	if not isReplayNPCModel(model) then
		return
	end

	local userId = getNPCUserId(model)
	if not userId then
		return
	end
	ReplayAvatarFactory.CacheLiveModel(userId, model :: Model, "StudioAIBot")
end

function ReplayAvatarFactory.GetTemplate(userId: number): Model?
	local key = getUserIdKey(userId)
	if not key then
		return nil
	end

	local cached = templateCache[key]
	if cached and cached.Parent == nil then
		return cached
	end
	templateCache[key] = nil

	local resolvedUserId = math.floor(userId)
	if resolvedUserId <= 0 then
		return nil
	end

	local liveTemplate = createLiveTemplate(resolvedUserId)
	if liveTemplate then
		warnDebug("Loaded live replay avatar", tostring(resolvedUserId))
		return rememberTemplate(resolvedUserId, liveTemplate, true)
	end

	RuntimeProfiler.Count("Client/Replay/AvatarFactory/LiveCharacterTemplateMiss")
	warnDebug("No live replay avatar template available", tostring(resolvedUserId))

	return nil
end

function ReplayAvatarFactory.CloneTemplate(userId: number): Model?
	local template = ReplayAvatarFactory.GetTemplate(userId)
	if not template then
		return nil
	end

	local ok, clone = pcall(function()
		return template:Clone()
	end)
	return if ok and clone and clone:IsA("Model") then clone else nil
end

function ReplayAvatarFactory.CloneCachedTemplate(userId: number): Model?
	local template = ReplayAvatarFactory.GetCachedTemplate(userId)
	if not template then
		return nil
	end

	local ok, clone = pcall(function()
		return template:Clone()
	end)
	return if ok and clone and clone:IsA("Model") then clone else nil
end

function ReplayAvatarFactory.PrewarmUserIds(userIds)
	if typeof(userIds) ~= "table" then
		return
	end

	local cached = 0
	local missing = 0
	for _, userId in ipairs(userIds) do
		local positiveUserId = getPositiveUserId(userId)
		if positiveUserId and not ReplayAvatarFactory.GetCachedTemplate(positiveUserId) then
			if ReplayAvatarFactory.CacheLiveCharacter(positiveUserId) then
				cached += 1
			else
				missing += 1
			end
		end
	end
	if cached > 0 then
		RuntimeProfiler.Count("Client/Replay/AvatarFactory/PrewarmLiveCached", cached)
	end
	if missing > 0 then
		RuntimeProfiler.Count("Client/Replay/AvatarFactory/PrewarmLiveMissing", missing)
	end
end

function ReplayAvatarFactory.PreloadUserIds(userIds, timeoutSeconds: number?)
	if typeof(userIds) ~= "table" then
		return
	end

	ReplayAvatarFactory.PrewarmUserIds(userIds)

	for _, userId in ipairs(userIds) do
		local positiveUserId = getPositiveUserId(userId)
		if positiveUserId and not ReplayAvatarFactory.GetCachedTemplate(positiveUserId) then
			warnDebug("Preload finished without cached avatar", tostring(positiveUserId))
		end
	end
end

function ReplayAvatarFactory.PrewarmCurrentPlayers()
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if getPositiveUserId(player.UserId) then
			ReplayAvatarFactory.CacheLiveCharacter(player.UserId)
			count += 1
			task.wait()
		end
	end
	RuntimeProfiler.Count("Client/Replay/AvatarFactory/PrewarmCurrentPlayersCount", count)
end

function ReplayAvatarFactory.PrewarmNPCs()
	local count = 0
	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("Model") and isReplayNPCModel(descendant) then
			cacheNPCModelIfEligible(descendant)
			count += 1
			task.wait()
		end
	end
	RuntimeProfiler.Count("Client/Replay/AvatarFactory/PrewarmNPCCount", count)
end

function ReplayAvatarFactory.GetCachedTemplate(userId: number): Model?
	local key = getUserIdKey(userId)
	local cached = key and templateCache[key]
	return if cached and cached.Parent == nil then cached else nil
end

local function disconnectPlayer(player: Player)
	local connections = playerConnections[player]
	playerConnections[player] = nil
	for _, connection in ipairs(connections or {}) do
		connection:Disconnect()
	end
end

local function watchPlayer(player: Player)
	if playerConnections[player] then
		return
	end

	local connections = {}
	playerConnections[player] = connections
	table.insert(connections, player.CharacterAdded:Connect(function()
		task.defer(function()
			ReplayAvatarFactory.CacheLiveCharacter(player.UserId)
		end)
	end))
	table.insert(connections, player.CharacterAppearanceLoaded:Connect(function()
		task.defer(function()
			ReplayAvatarFactory.CacheLiveCharacter(player.UserId)
		end)
	end))

	if player.Character then
		task.defer(function()
			ReplayAvatarFactory.CacheLiveCharacter(player.UserId)
		end)
	end
end

local function watchNPCModel(model: Instance?)
	if not (model and model:IsA("Model")) or watchedNPCModels[model] then
		return
	end
	if not isReplayNPCModel(model) then
		return
	end

	watchedNPCModels[model] = true
	task.defer(cacheNPCModelIfEligible, model)
	table.insert(workspaceConnections, model:GetAttributeChangedSignal("StudioAIUserId"):Connect(function()
		task.defer(cacheNPCModelIfEligible, model)
	end))
	table.insert(workspaceConnections, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			watchedNPCModels[model] = nil
		end
	end))
end

function ReplayAvatarFactory.Start(options)
	if typeof(options) == "table" then
		if isFiniteNumber(options.maxCache) then
			maxCache = math.max(math.floor(options.maxCache), 1)
		end
		debugEnabled = options.debug == true
	end

	if started then
		return
	end
	started = true

	for _, player in ipairs(Players:GetPlayers()) do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(disconnectPlayer)
	table.insert(workspaceConnections, Workspace.DescendantAdded:Connect(function(instance)
		if instance:IsA("Model") then
			watchNPCModel(instance)
		end
	end))

	task.spawn(function()
		ReplayAvatarFactory.PrewarmCurrentPlayers()
	end)
	task.spawn(function()
		local stopAt = os.clock() + NPC_SCAN_SECONDS
		while os.clock() < stopAt do
			ReplayAvatarFactory.PrewarmNPCs()
			task.wait(NPC_SCAN_INTERVAL_SECONDS)
		end
	end)
end

return table.freeze(ReplayAvatarFactory)
