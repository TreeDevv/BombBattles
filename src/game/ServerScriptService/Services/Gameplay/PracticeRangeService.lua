local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local BombService = require(ServerScriptService.Services.BombService)
local DestructionService = require(ServerScriptService.Services.DestructionService)

local LOBBY_NAME = "Lobby"
local PRACTICE_RANGE_NAME = "PracticeRange"
local ZONE_NAME = "Zone"
local HOUSE_MODEL_NAME = "Classic House"
local HOUSE_RESET_DELAY_SECONDS = 30
local RECONCILE_INTERVAL_SECONDS = 0.25
local VOXEL_FOLDER_NAME = "CurrentVoxels"

type HouseSnapshot = {
	template: Model,
	parent: Instance,
}

local PracticeRangeService = {}

local zone = nil
local zonePart: BasePart? = nil
local practiceRange: Model? = nil
local houseSnapshots: { HouseSnapshot } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}
local resetScheduled = false
local warnedMissingRange = false
local warnedZonePlusFailed = false
local warnedZonePlusMismatch = false
local monitorConnection: RBXScriptConnection? = nil
local monitorAccumulator = 0
local ZonePlus = nil

local function getPracticeRange(): Model?
	local lobby = workspace:FindFirstChild(LOBBY_NAME)
	local range = lobby and lobby:FindFirstChild(PRACTICE_RANGE_NAME)
	return if range and range:IsA("Model") then range else nil
end

local function getZonePart(range: Instance): BasePart?
	local part = range:FindFirstChild(ZONE_NAME)
	return if part and part:IsA("BasePart") then part else nil
end

local function setPracticeActive(player: Player, active: boolean)
	if player.Parent ~= Players then
		return
	end

	local attr = CombatEligibility.PracticeRangeActiveAttribute
	if player:GetAttribute(attr) == active then
		return
	end

	player:SetAttribute(attr, active)
	if active and type(BombService.RefillBombsForPractice) == "function" then
		BombService:RefillBombsForPractice(player)
	end
end

local function tagDestructibleTree(root: Instance)
	if not CollectionService:HasTag(root, DestructionConfig.Tag) then
		CollectionService:AddTag(root, DestructionConfig.Tag)
	end
end

local function cacheHouseSnapshots(range: Model)
	table.clear(houseSnapshots)

	for _, child in ipairs(range:GetChildren()) do
		if child:IsA("Model") and child.Name == HOUSE_MODEL_NAME then
			tagDestructibleTree(child)
			table.insert(houseSnapshots, {
				template = child:Clone(),
				parent = child.Parent,
			})
		end
	end
end

local function isPositionInsideZone(position: Vector3): boolean
	local part = zonePart
	if not part then
		return false
	end

	local localPosition = part.CFrame:PointToObjectSpace(position)
	local halfSize = part.Size * 0.5
	return math.abs(localPosition.X) <= halfSize.X
		and math.abs(localPosition.Y) <= halfSize.Y
		and math.abs(localPosition.Z) <= halfSize.Z
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

local function isPlayerInsideZone(player: Player): boolean
	local rootPart = getCharacterRoot(player)
	return rootPart ~= nil and isPositionInsideZone(rootPart.Position)
end

local function isPlayerPracticeEligible(player: Player): boolean
	return isPlayerInsideZone(player)
end

local function destroyCurrentHouses(range: Model)
	for _, child in ipairs(range:GetChildren()) do
		if child:IsA("Model") and child.Name == HOUSE_MODEL_NAME then
			child:Destroy()
		end
	end
end

local function getInstancePosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	local part = instance:FindFirstChildWhichIsA("BasePart", true)
	return if part then part.Position else nil
end

local function cleanupPracticeVoxelsIn(folder: Instance)
	for _, child in ipairs(folder:GetChildren()) do
		local position = getInstancePosition(child)
		if position and isPositionInsideZone(position) then
			child:Destroy()
		end
	end
end

local function cleanupPracticeVoxels()
	for _, child in ipairs(workspace:GetChildren()) do
		if child.Name == VOXEL_FOLDER_NAME then
			cleanupPracticeVoxelsIn(child)
		else
			local folder = child:FindFirstChild(VOXEL_FOLDER_NAME)
			if folder then
				cleanupPracticeVoxelsIn(folder)
			end
		end
	end
end

local function restoreHouses()
	local range = practiceRange
	if not range or not range.Parent then
		return
	end

	destroyCurrentHouses(range)
	cleanupPracticeVoxels()

	for _, snapshot in ipairs(houseSnapshots) do
		local clone = snapshot.template:Clone()
		clone.Parent = if snapshot.parent and snapshot.parent.Parent then snapshot.parent else range
		tagDestructibleTree(clone)
	end

	DestructionService:InvalidateTargetCache("PracticeRangeReset")
end

local function scheduleHouseReset()
	if resetScheduled then
		return
	end
	resetScheduled = true

	task.delay(HOUSE_RESET_DELAY_SECONDS, function()
		resetScheduled = false
		restoreHouses()
	end)
end

local function onDestruction(payload)
	if typeof(payload) ~= "table" then
		return
	end
	if typeof(payload.position) == "Vector3" and not isPositionInsideZone(payload.position) then
		return
	end

	local sourceContext = payload.sourceContext
	local ownerUserId = if typeof(sourceContext) == "table" then sourceContext.ownerUserId else nil
	local player = if typeof(ownerUserId) == "number" then Players:GetPlayerByUserId(ownerUserId) else nil
	if player and not CombatEligibility.IsPracticeRangeActive(player) then
		return
	end

	scheduleHouseReset()
end

local function reconcilePlayer(player: Player)
	if player.Parent ~= Players then
		return
	end

	setPracticeActive(player, isPlayerPracticeEligible(player))
end

local function reconcileAllPlayers()
	local manualInsideCount = 0

	for _, player in ipairs(Players:GetPlayers()) do
		local inside = isPlayerInsideZone(player)
		if inside then
			manualInsideCount += 1
		end
		setPracticeActive(player, inside)
	end

	if zone and manualInsideCount > 0 and not warnedZonePlusMismatch then
		local zonePlayers = zone:getPlayers()
		if #zonePlayers == 0 then
			warn("[PracticeRangeService] ZonePlus reported no players while manual bounds detected players inside the practice range")
			warnedZonePlusMismatch = true
		end
	end
end

local function startReconcileMonitor()
	if monitorConnection then
		return
	end

	monitorConnection = RunService.Heartbeat:Connect(function(deltaTime: number)
		monitorAccumulator += deltaTime
		if monitorAccumulator < RECONCILE_INTERVAL_SECONDS then
			return
		end

		monitorAccumulator = 0
		reconcileAllPlayers()
	end)
end

local function bindPlayer(player: Player)
	if playerConnections[player] then
		return
	end

	local connections = {}
	playerConnections[player] = connections

	table.insert(connections, player.CharacterAdded:Connect(function()
		task.defer(function()
			reconcilePlayer(player)
		end)
	end))
	table.insert(connections, player:GetAttributeChangedSignal(CombatEligibility.AFKAttribute):Connect(function()
		reconcilePlayer(player)
	end))

	task.defer(function()
		reconcilePlayer(player)
	end)
end

local function getZonePlus()
	if ZonePlus then
		return ZonePlus
	end

	local module = ReplicatedStorage.Packages:FindFirstChild("ZonePlus")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end

	local ok, result = pcall(require, module)
	if not ok then
		if not warnedZonePlusFailed then
			warn("[PracticeRangeService] ZonePlus failed to load; using manual bounds detection: " .. tostring(result))
			warnedZonePlusFailed = true
		end
		return nil
	end

	ZonePlus = result
	return ZonePlus
end

local function startZone(range: Model, part: BasePart)
	zonePart = part
	local zonePlus = getZonePlus()
	if not zonePlus then
		return
	end

	local ok, result = pcall(function()
		return zonePlus.new(part)
	end)
	if not ok then
		if not warnedZonePlusFailed then
			warn("[PracticeRangeService] ZonePlus failed to start; falling back to manual bounds detection: " .. tostring(result))
			warnedZonePlusFailed = true
		end
		return
	end

	zone = result

	zone.playerEntered:Connect(function(player: Player)
		reconcilePlayer(player)
	end)
	zone.playerExited:Connect(function(player: Player)
		reconcilePlayer(player)
	end)

	task.defer(function()
		if not zone then
			return
		end
		for _, player in ipairs(zone:getPlayers()) do
			reconcilePlayer(player)
		end
	end)
end

function PracticeRangeService:OnStart()
	practiceRange = getPracticeRange()
	if not practiceRange then
		if not warnedMissingRange then
			warn("[PracticeRangeService] Missing Workspace.Lobby.PracticeRange")
			warnedMissingRange = true
		end
		return
	end

	local part = getZonePart(practiceRange)
	if not part then
		warn("[PracticeRangeService] Missing Workspace.Lobby.PracticeRange.Zone")
		return
	end

	cacheHouseSnapshots(practiceRange)
	DestructionService:InvalidateTargetCache("PracticeRangeStart")
	startZone(practiceRange, part)
	startReconcileMonitor()

	if type(DestructionService.ObserveDestruction) == "function" then
		DestructionService:ObserveDestruction(onDestruction)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		bindPlayer(player)
	end
end

function PracticeRangeService:OnPlayerAdded(player: Player)
	bindPlayer(player)
end

function PracticeRangeService:OnPlayerRemoving(player: Player)
	local connections = playerConnections[player]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		playerConnections[player] = nil
	end
	player:SetAttribute(CombatEligibility.PracticeRangeActiveAttribute, nil)
end

return PracticeRangeService
