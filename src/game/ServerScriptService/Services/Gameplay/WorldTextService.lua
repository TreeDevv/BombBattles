local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldTextConstants = require(ReplicatedStorage.Shared.Effects.WorldTextConstants)

local WorldTextService = {}

local remote: RemoteEvent? = nil

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteVector3(value: any): boolean
	return typeof(value) == "Vector3"
		and isFiniteNumber(value.X)
		and isFiniteNumber(value.Y)
		and isFiniteNumber(value.Z)
end

local function ensureRemotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(WorldTextConstants.REMOTES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = WorldTextConstants.REMOTES_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureRemote(): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(WorldTextConstants.REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local created = Instance.new("RemoteEvent")
	created.Name = WorldTextConstants.REMOTE_NAME
	created.Parent = folder
	return created
end

local function getPlayerRootPosition(player: Player): Vector3?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart.Position else nil
end

local function addTarget(targets: { [Player]: boolean }, player: Player?)
	if player and player.Parent == Players then
		targets[player] = true
	end
end

local function addNearbyTargets(targets: { [Player]: boolean }, position: Vector3?, radius: number)
	if not isFiniteVector3(position) then
		return
	end

	local radiusSquared = radius * radius
	for _, player in ipairs(Players:GetPlayers()) do
		local playerPosition = getPlayerRootPosition(player)
		if playerPosition and (playerPosition - position).Magnitude ^ 2 <= radiusSquared then
			targets[player] = true
		end
	end
end

local function buildPlayerList(...): { Player }
	local players = {}
	for index = 1, select("#", ...) do
		local player = select(index, ...)
		if player and player.Parent == Players then
			table.insert(players, player)
		end
	end
	return players
end

local function sendPayload(targets: { [Player]: boolean }, payload)
	if typeof(payload) ~= "table" then
		return
	end

	local resolvedRemote = remote or ensureRemote()
	remote = resolvedRemote

	for player in pairs(targets) do
		pcall(function()
			resolvedRemote:FireClient(player, payload)
		end)
	end
end

function WorldTextService.SendEvent(kind: string, payload, options)
	if typeof(kind) ~= "string" or kind == "" or typeof(payload) ~= "table" then
		return
	end

	local position = if isFiniteVector3(payload.position) then payload.position else nil
	local radius = WorldTextConstants.DEFAULT_RELEVANCE_RADIUS
	if typeof(options) == "table" and isFiniteNumber(options.radius) then
		radius = math.max(0, options.radius)
	end

	local targets = {}
	if typeof(options) == "table" and typeof(options.players) == "table" then
		for _, player in ipairs(options.players) do
			addTarget(targets, player)
		end
	end
	addNearbyTargets(targets, position, radius)

	if not next(targets) then
		return
	end

	local eventPayload = {}
	for key, value in pairs(payload) do
		if typeof(key) == "string" or typeof(key) == "number" then
			eventPayload[key] = value
		end
	end
	eventPayload.kind = kind

	sendPayload(targets, eventPayload)
end

function WorldTextService.BombExploded(owner: Player?, position: Vector3, payload)
	payload = typeof(payload) == "table" and payload or {}
	payload.position = position
	if owner then
		payload.ownerUserId = owner.UserId
	end
	WorldTextService.SendEvent(WorldTextConstants.Kinds.BombExploded, payload, {
		players = buildPlayerList(owner),
	})
end

function WorldTextService.BombThrown(owner: Player?, position: Vector3, payload)
	payload = typeof(payload) == "table" and payload or {}
	payload.position = position
	if owner then
		payload.ownerUserId = owner.UserId
	end
	WorldTextService.SendEvent(WorldTextConstants.Kinds.BombThrown, payload, {
		players = buildPlayerList(owner),
	})
end

function WorldTextService.PlayerDamaged(attacker: Player?, victim: Player?, amount: number, position: Vector3, payload)
	payload = typeof(payload) == "table" and payload or {}
	payload.position = position
	payload.amount = amount
	if attacker then
		payload.attackerUserId = attacker.UserId
	end
	if victim then
		payload.victimUserId = victim.UserId
	end
	WorldTextService.SendEvent(WorldTextConstants.Kinds.PlayerDamaged, payload, {
		players = buildPlayerList(attacker, victim),
	})
end

function WorldTextService.PlayerKilled(killer: Player?, victim: Player?, position: Vector3?, payload)
	payload = typeof(payload) == "table" and payload or {}
	if isFiniteVector3(position) then
		payload.position = position
	end
	if killer then
		payload.killerUserId = killer.UserId
	end
	if victim then
		payload.victimUserId = victim.UserId
	end
	WorldTextService.SendEvent(WorldTextConstants.Kinds.PlayerKilled, payload, {
		players = buildPlayerList(killer, victim),
	})
end

function WorldTextService.AbilityUsed(player: Player, abilityName: string, position: Vector3?, payload)
	payload = typeof(payload) == "table" and payload or {}
	if isFiniteVector3(position) then
		payload.position = position
	end
	payload.abilityName = abilityName
	if player then
		payload.userId = player.UserId
	end
	WorldTextService.SendEvent(WorldTextConstants.Kinds.AbilityUsed, payload, {
		players = buildPlayerList(player),
	})
end

function WorldTextService:OnStart()
	remote = ensureRemote()
end

return WorldTextService
