local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local WorldTextConstants = require(ReplicatedStorage.Shared.Effects.WorldTextConstants)

local REMOTES_FOLDER_NAME = "Remotes"
local KILL_FEED_REMOTE_NAME = "KillFeed"
local ROUND_TEAM_ATTR = "RoundTeam"
local ASSIST_WINDOW_SECONDS = 10

local StudioAICombatants = {}

local byUserId = {}
local byModel = {}
local killFeedRemote: RemoteEvent? = nil
local replayService = nil
local worldTextService = nil
local teamKillRecorder: ((any) -> ())? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function getUserIdKey(userId: any): string?
	if not isFiniteNumber(userId) then
		return nil
	end
	return tostring(math.floor(userId))
end

local function getReplayService()
	if replayService then
		return replayService
	end

	local services = game:GetService("ServerScriptService"):FindFirstChild("Services")
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

local function getWorldTextService()
	if worldTextService then
		return worldTextService
	end

	local services = game:GetService("ServerScriptService"):FindFirstChild("Services")
	local module = services and services:FindFirstChild("WorldTextService")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end

	local ok, service = pcall(require, module)
	if ok and typeof(service) == "table" then
		worldTextService = service
		return service
	end
	return nil
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

local function ensureKillFeedRemote(): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(KILL_FEED_REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = KILL_FEED_REMOTE_NAME
	remote.Parent = folder
	return remote
end

local function fireKillFeed(payload)
	local remote = killFeedRemote or ensureKillFeedRemote()
	killFeedRemote = remote
	remote:FireAllClients(payload)
end

local function recordReplayEvent(eventType: string, payload)
	local service = getReplayService()
	if not (service and type(service.RecordEvent) == "function") then
		return
	end

	pcall(function()
		service.RecordEvent(eventType, payload)
	end)
end

local function sendWorldText(kind: string, payload)
	local service = getWorldTextService()
	if not (service and type(service.SendEvent) == "function") then
		return
	end

	pcall(function()
		service.SendEvent(kind, payload, {
			radius = WorldTextConstants.DEFAULT_RELEVANCE_RADIUS,
		})
	end)
end

local function getPlayerTeamName(player: Player): string?
	local teamName = player:GetAttribute(ROUND_TEAM_ATTR)
	if typeof(teamName) == "string" and teamName ~= "" then
		return teamName
	end
	return if player.Team then player.Team.Name else nil
end

local function getPlayerIdentity(player: Player)
	return {
		userId = player.UserId,
		name = player.Name,
		displayName = if player.DisplayName ~= "" then player.DisplayName else player.Name,
		teamName = getPlayerTeamName(player),
		isNPC = false,
	}
end

local function getBotIdentity(record)
	if typeof(record) ~= "table" then
		return nil
	end
	return {
		userId = record.userId,
		name = record.name,
		displayName = record.displayName,
		teamName = record.teamName,
		isNPC = true,
	}
end

local function getRecordFromOwner(owner: any)
	if typeof(owner) == "table" and isFiniteNumber(owner.UserId) then
		return byUserId[math.floor(owner.UserId)]
	end
	if typeof(owner) == "Instance" and owner:IsA("Model") then
		return byModel[owner]
	end
	return nil
end

local function getOwnerIdentity(owner: any)
	if typeof(owner) == "Instance" and owner:IsA("Player") then
		return getPlayerIdentity(owner)
	end

	local record = getRecordFromOwner(owner)
	if record then
		return getBotIdentity(record)
	end

	if typeof(owner) == "table" and isFiniteNumber(owner.UserId) then
		return {
			userId = math.floor(owner.UserId),
			name = if typeof(owner.Name) == "string" and owner.Name ~= "" then owner.Name else tostring(owner.UserId),
			displayName = if typeof(owner.DisplayName) == "string" and owner.DisplayName ~= "" then owner.DisplayName else tostring(owner.UserId),
			teamName = if typeof(owner.teamName) == "string" then owner.teamName else nil,
			isNPC = owner.studioAIBot == true,
		}
	end
	return nil
end

local function isAliveRecord(record): boolean
	if typeof(record) ~= "table" or record.alive == false then
		return false
	end
	local model = record.model
	local humanoid = record.humanoid
	local rootPart = record.rootPart
	return typeof(model) == "Instance"
		and model.Parent ~= nil
		and typeof(humanoid) == "Instance"
		and humanoid:IsA("Humanoid")
		and humanoid.Health > 0
		and typeof(rootPart) == "Instance"
		and rootPart:IsA("BasePart")
		and rootPart.Parent ~= nil
end

local function resolveDeathContributor(record, currentTime: number)
	local victimTeam = record.teamName
	local bestKey = nil
	local bestContributor = nil
	local bestDamagedAt = -math.huge

	for attackerKey, contributor in pairs(record.damageContributors or {}) do
		if typeof(contributor) ~= "table" or not isFiniteNumber(contributor.damagedAt) then
			continue
		end
		if currentTime - contributor.damagedAt > ASSIST_WINDOW_SECONDS then
			continue
		end
		if attackerKey == tostring(record.userId) then
			continue
		end
		if victimTeam and contributor.teamName == victimTeam then
			continue
		end
		if contributor.damagedAt > bestDamagedAt then
			bestKey = attackerKey
			bestContributor = contributor
			bestDamagedAt = contributor.damagedAt
		end
	end

	return bestKey, bestContributor
end

local function getIdentityByKey(key: string?)
	if typeof(key) ~= "string" or key == "" then
		return nil
	end

	local userId = tonumber(key)
	if not userId then
		return nil
	end

	local ok, player = pcall(function()
		return Players:GetPlayerByUserId(userId)
	end)
	if ok and player then
		return getPlayerIdentity(player)
	end

	return getBotIdentity(byUserId[userId])
end

local function onBotDied(record)
	if not record or record.deadRecorded == true then
		return
	end
	record.deadRecorded = true
	record.alive = false

	local currentTime = now()
	local victim = getBotIdentity(record)
	local killerKey, contributor = resolveDeathContributor(record, currentTime)
	local killer = getIdentityByKey(killerKey)
	local position = if record.rootPart and record.rootPart.Parent then record.rootPart.Position else nil

	local payload = {
		timestamp = currentTime,
		roundId = record.roundId,
		victimUserId = victim.userId,
		victimName = victim.name,
		victimDisplayName = victim.displayName,
		victimTeam = victim.teamName,
		victimIsNPC = true,
		killerUserId = if killer then killer.userId else nil,
		killerName = if killer then killer.name else nil,
		killerDisplayName = if killer then killer.displayName else nil,
		killerTeam = if killer then killer.teamName else nil,
		killerIsNPC = if killer then killer.isNPC == true else nil,
		sourceType = if contributor then contributor.sourceType else nil,
		sourceId = if contributor then contributor.sourceId else nil,
		position = position,
	}

	if teamKillRecorder then
		teamKillRecorder(payload)
	end
	recordReplayEvent("PlayerKilled", payload)
	if killer and killer.teamName and victim.teamName and killer.teamName ~= victim.teamName then
		fireKillFeed(payload)
	end
	sendWorldText(WorldTextConstants.Kinds.PlayerKilled, payload)
end

function StudioAICombatants.IsBotOwner(owner: any): boolean
	return RunService:IsStudio()
		and typeof(owner) == "table"
		and owner.studioAIBot == true
		and isFiniteNumber(owner.UserId)
end

function StudioAICombatants.GetOwnerIdentity(owner: any)
	return getOwnerIdentity(owner)
end

function StudioAICombatants.GetDisplayName(userId: any): string?
	local key = getUserIdKey(userId)
	local record = key and byUserId[tonumber(key)]
	return if record then record.displayName or record.name else nil
end

function StudioAICombatants.SetTeamKillRecorder(callback)
	teamKillRecorder = if type(callback) == "function" then callback else nil
end

function StudioAICombatants.Register(record)
	if not RunService:IsStudio() or typeof(record) ~= "table" or not isFiniteNumber(record.userId) then
		return false
	end
	local model = record.model
	local humanoid = record.humanoid
	local rootPart = record.rootPart
	if not (
		typeof(model) == "Instance"
		and model:IsA("Model")
		and typeof(humanoid) == "Instance"
		and humanoid:IsA("Humanoid")
		and typeof(rootPart) == "Instance"
		and rootPart:IsA("BasePart")
	) then
		return false
	end

	local userId = math.floor(record.userId)
	StudioAICombatants.Unregister(userId)

	record.userId = userId
	record.name = if typeof(record.name) == "string" and record.name ~= "" then record.name else tostring(userId)
	record.displayName = if typeof(record.displayName) == "string" and record.displayName ~= "" then record.displayName else record.name
	record.teamName = if typeof(record.teamName) == "string" and record.teamName ~= "" then record.teamName else nil
	record.damageContributors = {}
	record.alive = humanoid.Health > 0
	record.deadRecorded = false
	record.deathConnection = humanoid.Died:Connect(function()
		onBotDied(record)
	end)

	byUserId[userId] = record
	byModel[model] = record
	return true
end

function StudioAICombatants.Unregister(recordOrUserId: any)
	local record = nil
	if typeof(recordOrUserId) == "table" then
		record = recordOrUserId
	elseif isFiniteNumber(recordOrUserId) then
		record = byUserId[math.floor(recordOrUserId)]
	end
	if not record then
		return false
	end

	if record.deathConnection then
		record.deathConnection:Disconnect()
		record.deathConnection = nil
	end
	if isFiniteNumber(record.userId) then
		byUserId[math.floor(record.userId)] = nil
	end
	if record.model then
		byModel[record.model] = nil
	end
	return true
end

function StudioAICombatants.GetAliveBots(options)
	options = if typeof(options) == "table" then options else {}
	local result = {}
	local enemyOfTeam = options.enemyOfTeam
	local excludeUserId = if isFiniteNumber(options.excludeUserId) then math.floor(options.excludeUserId) else nil
	local roundId = if isFiniteNumber(options.roundId) then math.floor(options.roundId) else nil

	for _, record in pairs(byUserId) do
		if not isAliveRecord(record) then
			continue
		end
		if excludeUserId and record.userId == excludeUserId then
			continue
		end
		if roundId and record.roundId ~= roundId then
			continue
		end
		if typeof(enemyOfTeam) == "string" and enemyOfTeam ~= "" and record.teamName == enemyOfTeam then
			continue
		end
		table.insert(result, record)
	end
	return result
end

function StudioAICombatants.ApplyDamage(owner: any, record, damage: number, sourceContext)
	if not isAliveRecord(record) or not (isFiniteNumber(damage) and damage > 0) then
		return 0, false
	end

	local attacker = getOwnerIdentity(owner)
	if not attacker then
		return 0, false
	end

	local healthBefore = record.humanoid.Health
	local appliedDamage = math.min(damage, healthBefore)
	local sourceType = if typeof(sourceContext) == "table" and typeof(sourceContext.sourceType) == "string"
		then sourceContext.sourceType
		else nil
	local sourceId = if typeof(sourceContext) == "table" and typeof(sourceContext.sourceId) == "string"
		then sourceContext.sourceId
		else nil

	record.damageContributors[tostring(attacker.userId)] = {
		damagedAt = now(),
		teamName = attacker.teamName,
		sourceType = sourceType,
		sourceId = sourceId,
	}

	record.humanoid:TakeDamage(damage)
	local healthAfter = record.humanoid.Health
	local killed = healthBefore > 0 and healthAfter <= 0

	local payload = {
		victimUserId = record.userId,
		victimName = record.name,
		victimDisplayName = record.displayName,
		victimTeam = record.teamName,
		victimIsNPC = true,
		attackerUserId = attacker.userId,
		attackerName = attacker.name,
		attackerDisplayName = attacker.displayName,
		attackerTeam = attacker.teamName,
		attackerIsNPC = attacker.isNPC == true,
		amount = appliedDamage,
		sourceType = sourceType,
		sourceId = sourceId,
		position = record.rootPart.Position,
		victimHealthAfter = healthAfter,
	}
	recordReplayEvent("PlayerDamaged", payload)
	sendWorldText(WorldTextConstants.Kinds.PlayerDamaged, payload)
	if killed then
		onBotDied(record)
	end
	return appliedDamage, killed
end

function StudioAICombatants.GetReplaySnapshots(maxCount: number?, timestamp: number?)
	local limit = if isFiniteNumber(maxCount) then math.max(math.floor(maxCount), 0) else math.huge
	local snapshots = {}
	if limit <= 0 then
		return snapshots
	end

	for _, record in pairs(byUserId) do
		if #snapshots >= limit then
			break
		end
		if not isAliveRecord(record) then
			continue
		end

		local rootPart = record.rootPart
		local humanoid = record.humanoid
		local velocity = rootPart.AssemblyLinearVelocity
		local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
		table.insert(snapshots, {
			userId = record.userId,
			name = record.name,
			displayName = record.displayName,
			isNPC = true,
			cframe = rootPart.CFrame,
			serverCFrame = rootPart.CFrame,
			rootSource = "server",
			health = humanoid.Health,
			maxHealth = humanoid.MaxHealth,
			alive = humanoid.Health > 0,
			teamName = record.teamName,
			bombSkinId = BombSkinConfig.DefaultSkinId,
			animationState = {
				sampleTime = timestamp,
				grounded = humanoid.FloorMaterial ~= Enum.Material.Air,
				sprinting = false,
				crouching = false,
				sliding = false,
				effectiveSpeed = horizontalVelocity.Magnitude,
				moveMagnitude = if horizontalVelocity.Magnitude > 0.5 then math.clamp(horizontalVelocity.Magnitude / 24, 0, 1) else 0,
				shiftLocked = false,
				linearVelocity = velocity,
				bombCooking = false,
				bombSkinId = BombSkinConfig.DefaultSkinId,
			},
		})
	end
	return snapshots
end

return StudioAICombatants
