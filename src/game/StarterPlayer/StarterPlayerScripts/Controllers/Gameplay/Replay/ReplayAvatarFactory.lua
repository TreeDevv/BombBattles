local Players = game:GetService("Players")

local ReplayAvatarFactory = {}

local DEFAULT_MAX_CACHE = 32
local DEFAULT_PRELOAD_TIMEOUT_SECONDS = 1.5

local maxCache = DEFAULT_MAX_CACHE
local debugEnabled = false
local started = false
local templateCache = {}
local templateOrder = {}
local loadingByKey = {}
local playerConnections = {}

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

local function createGeneratedTemplate(userId: number): Model?
	local positiveUserId = getPositiveUserId(userId)
	if not positiveUserId then
		warnDebug("Skipped generated avatar for non-positive user", tostring(userId))
		return nil
	end

	local ok, model = pcall(function()
		local description = Players:GetHumanoidDescriptionFromUserIdAsync(positiveUserId)
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R6)
	end)

	if ok then
		local generatedModel = validateTemplate(model, positiveUserId, "HumanoidDescriptionR6", true)
		if generatedModel then
			return generatedModel
		end
	end

	local fallbackOk, fallbackModel = pcall(function()
		return Players:CreateHumanoidModelFromUserIdAsync(positiveUserId)
	end)
	if fallbackOk then
		return validateTemplate(fallbackModel, positiveUserId, "UserIdFallback", true)
	end

	return nil
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
	local liveTemplate = createLiveTemplate(resolvedUserId)
	if liveTemplate then
		warnDebug("Loaded live replay avatar", tostring(resolvedUserId))
		return rememberTemplate(resolvedUserId, liveTemplate, true)
	end

	local generatedTemplate = createGeneratedTemplate(resolvedUserId)
	if generatedTemplate then
		warnDebug("Loaded generated replay avatar", tostring(resolvedUserId))
		return rememberTemplate(resolvedUserId, generatedTemplate, false)
	end

	warnDebug("No replay avatar template available", tostring(resolvedUserId))

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

local function preloadOne(userId: number)
	local key = getUserIdKey(userId)
	if not key or loadingByKey[key] then
		return
	end

	loadingByKey[key] = true
	task.spawn(function()
		ReplayAvatarFactory.GetTemplate(userId)
		loadingByKey[key] = nil
	end)
end

function ReplayAvatarFactory.PreloadUserIds(userIds, timeoutSeconds: number?)
	if typeof(userIds) ~= "table" then
		return
	end

	for _, userId in ipairs(userIds) do
		if isFiniteNumber(userId) then
			ReplayAvatarFactory.CacheLiveCharacter(userId)
		end
	end

	for _, userId in ipairs(userIds) do
		if isFiniteNumber(userId) and not ReplayAvatarFactory.GetCachedTemplate(userId) then
			preloadOne(userId)
		end
	end

	local timeoutAt = os.clock() + math.max(timeoutSeconds or DEFAULT_PRELOAD_TIMEOUT_SECONDS, 0)
	while os.clock() < timeoutAt do
		local pending = false
		for _, userId in ipairs(userIds) do
			local key = getUserIdKey(userId)
			if key and loadingByKey[key] and not ReplayAvatarFactory.GetCachedTemplate(userId) then
				pending = true
				break
			end
		end
		if not pending then
			break
		end
		task.wait()
	end

	for _, userId in ipairs(userIds) do
		if isFiniteNumber(userId) and not ReplayAvatarFactory.GetCachedTemplate(userId) then
			warnDebug("Preload finished without cached avatar", tostring(math.floor(userId)))
		end
	end
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
end

return table.freeze(ReplayAvatarFactory)
