local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local BombService = require(ServerScriptService.Services.BombService)
local RoundService = require(ServerScriptService.Services.RoundService)

local ROUND_TEAM_ATTR = "RoundTeam"
local ROUND_ID_ATTR = "RoundId"
local SERVICE_FOLDER_NAME = "StudioAIBots"
local BOT_USER_ID_BASE = -900000
local MONITOR_INTERVAL_SECONDS = 1
local PATH_TIMEOUT_SECONDS = 3
local GROUND_PROBE_UP = 32
local GROUND_PROBE_DOWN = 140
local TEAM_COLORS = {
	Red = Color3.fromRGB(219, 48, 48),
	Blue = Color3.fromRGB(50, 112, 255),
}

type BotRecord = {
	id: number,
	owner: { [string]: any },
	teamName: string,
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	homePosition: Vector3,
	alive: boolean,
	movementToken: number,
	throwToken: number,
	deathConnection: RBXScriptConnection?,
}

local StudioAIBotService = {}

local bots: { BotRecord } = {}
local monitorRunning = false
local activeRoundId: number? = nil
local nextBotId = 0
local rng = Random.new()

local function getConfig()
	local studioTesting = RoundConfig.StudioTesting
	local config = studioTesting and studioTesting.AIBots
	return if typeof(config) == "table" then config else {}
end

local function isEnabled(): boolean
	local config = getConfig()
	return RunService:IsStudio() and config.Enabled == true
end

local function readNumber(value: any, fallback: number, minValue: number?, maxValue: number?): number
	local numberValue = if typeof(value) == "number" and value == value then value else fallback
	if minValue then
		numberValue = math.max(numberValue, minValue)
	end
	if maxValue then
		numberValue = math.min(numberValue, maxValue)
	end
	return numberValue
end

local function getActiveMap(): Model?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getServiceFolder(): Folder
	local existing = workspace:FindFirstChild(SERVICE_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = SERVICE_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function isCurrentRound(state): boolean
	return typeof(state) == "table" and state.state == RoundStates.Active and typeof(state.roundId) == "number"
end

local function getTaggedParts(tagName: string, map: Instance, teamName: string): { BasePart }
	local parts = {}
	for _, instance in ipairs(CollectionService:GetTagged(tagName)) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(map) and instance:GetAttribute("Team") == teamName then
			table.insert(parts, instance)
		end
	end
	return parts
end

local function getTaggedInstances(tagName: string, map: Instance, teamName: string): { Instance }
	local instances = {}
	for _, instance in ipairs(CollectionService:GetTagged(tagName)) do
		if instance:IsDescendantOf(map) and instance:GetAttribute("Team") == teamName then
			table.insert(instances, instance)
		end
	end
	return instances
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

local function countRealRoundPlayers(teamName: string, roundId: number): number
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute(ROUND_ID_ATTR) == roundId and player:GetAttribute(ROUND_TEAM_ATTR) == teamName then
			count += 1
		end
	end
	return count
end

local function countBots(teamName: string): number
	local count = 0
	for _, bot in ipairs(bots) do
		if bot.teamName == teamName then
			count += 1
		end
	end
	return count
end

local function makePart(name: string, size: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.Massless = false
	part.Parent = parent
	return part
end

local function makeJoint(name: string, parent: Instance, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame?)
	local joint = Instance.new("Motor6D")
	joint.Name = name
	joint.Part0 = part0
	joint.Part1 = part1
	joint.C0 = c0
	joint.C1 = c1 or CFrame.new()
	joint.Parent = parent
end

local function createBotModel(teamName: string, spawnCFrame: CFrame, botId: number): (Model, Humanoid, BasePart)
	local teamColor = TEAM_COLORS[teamName] or Color3.fromRGB(180, 180, 180)
	local model = Instance.new("Model")
	model.Name = ("StudioAI_%s_%02d"):format(teamName, botId)
	model:SetAttribute("StudioAIBot", true)
	model:SetAttribute("Team", teamName)

	local root = makePart("HumanoidRootPart", Vector3.new(2, 2, 1), teamColor, model)
	root.Transparency = 1
	root.CanCollide = false
	root.CFrame = spawnCFrame + Vector3.new(0, 3, 0)

	local torso = makePart("Torso", Vector3.new(2, 2, 1), teamColor, model)
	torso.CanCollide = true
	torso.CFrame = root.CFrame
	local head = makePart("Head", Vector3.new(1.1, 1.1, 1.1), Color3.fromRGB(245, 218, 185), model)
	head.CFrame = root.CFrame + Vector3.new(0, 1.55, 0)
	local leftArm = makePart("Left Arm", Vector3.new(1, 2, 1), teamColor, model)
	leftArm.CFrame = root.CFrame + Vector3.new(-1.5, 0, 0)
	local rightArm = makePart("Right Arm", Vector3.new(1, 2, 1), teamColor, model)
	rightArm.CFrame = root.CFrame + Vector3.new(1.5, 0, 0)
	local leftLeg = makePart("Left Leg", Vector3.new(1, 2, 1), Color3.fromRGB(45, 45, 55), model)
	leftLeg.CanCollide = true
	leftLeg.CFrame = root.CFrame + Vector3.new(-0.5, -2, 0)
	local rightLeg = makePart("Right Leg", Vector3.new(1, 2, 1), Color3.fromRGB(45, 45, 55), model)
	rightLeg.CanCollide = true
	rightLeg.CFrame = root.CFrame + Vector3.new(0.5, -2, 0)

	makeJoint("RootJoint", root, root, torso, CFrame.new())
	makeJoint("Neck", torso, torso, head, CFrame.new(0, 1, 0), CFrame.new(0, -0.55, 0))
	makeJoint("Left Shoulder", torso, torso, leftArm, CFrame.new(-1.5, 0.5, 0), CFrame.new(0, 0.5, 0))
	makeJoint("Right Shoulder", torso, torso, rightArm, CFrame.new(1.5, 0.5, 0), CFrame.new(0, 0.5, 0))
	makeJoint("Left Hip", torso, torso, leftLeg, CFrame.new(-0.5, -1, 0), CFrame.new(0, 1, 0))
	makeJoint("Right Hip", torso, torso, rightLeg, CFrame.new(0.5, -1, 0), CFrame.new(0, 1, 0))

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.DisplayName = ("AI %s"):format(teamName)
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.NameDisplayDistance = 0
	humanoid.WalkSpeed = readNumber(getConfig().WalkSpeed, 18, 1, 80)
	humanoid.UseJumpPower = true
	humanoid.JumpPower = readNumber(getConfig().JumpPower, 45, 0, 140)
	humanoid.Parent = model

	model.PrimaryPart = root
	model:PivotTo(spawnCFrame + Vector3.new(0, 4, 0))
	return model, humanoid, root
end

local function raycastGround(position: Vector3, map: Instance?): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = if map then { map } else {}
	params.IgnoreWater = false

	local result = workspace:Raycast(position + Vector3.yAxis * GROUND_PROBE_UP, Vector3.yAxis * -GROUND_PROBE_DOWN, params)
	return if result then result.Position else position
end

local function randomPatrolPoint(bot: BotRecord, map: Instance?): Vector3
	local config = getConfig()
	local radius = readNumber(config.PatrolRadius, 42, 4, 250)
	local angle = rng:NextNumber(0, math.pi * 2)
	local distance = rng:NextNumber(radius * 0.35, radius)
	local offset = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
	return raycastGround(bot.homePosition + offset, map) + Vector3.new(0, 3, 0)
end

local function computePath(fromPosition: Vector3, toPosition: Vector3): { PathWaypoint }?
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 8,
	})

	local ok = pcall(function()
		path:ComputeAsync(fromPosition, toPosition)
	end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		return nil
	end

	local waypoints = path:GetWaypoints()
	return if #waypoints > 0 then waypoints else nil
end

local function moveTo(bot: BotRecord, position: Vector3, token: number): boolean
	if bot.movementToken ~= token or not bot.alive then
		return false
	end

	bot.humanoid:MoveTo(position)
	local finished = false
	local reached = false
	local connection = bot.humanoid.MoveToFinished:Connect(function(didReach)
		finished = true
		reached = didReach
	end)

	local startedAt = os.clock()
	while bot.movementToken == token and bot.alive and not finished and os.clock() - startedAt < PATH_TIMEOUT_SECONDS do
		task.wait(0.1)
	end
	connection:Disconnect()
	return reached
end

local function startMovementLoop(bot: BotRecord)
	bot.movementToken += 1
	local token = bot.movementToken

	task.spawn(function()
		while bot.movementToken == token and bot.alive do
			local map = getActiveMap()
			local destination = randomPatrolPoint(bot, map)
			local waypoints = computePath(bot.rootPart.Position, destination)
			if waypoints then
				for _, waypoint in ipairs(waypoints) do
					if waypoint.Action == Enum.PathWaypointAction.Jump then
						bot.humanoid.Jump = true
					end
					if not moveTo(bot, waypoint.Position, token) then
						break
					end
				end
			else
				moveTo(bot, destination, token)
			end

			task.wait(readNumber(getConfig().PatrolRepathSeconds, 3.5, 0.5, 20))
		end
	end)
end

local function getEnemyTeam(teamName: string): string
	return if teamName == RoundConfig.Teams.Red.name then RoundConfig.Teams.Blue.name else RoundConfig.Teams.Red.name
end

local function getTargetPosition(teamName: string): Vector3?
	local map = getActiveMap()
	if not map then
		return nil
	end

	local enemyTeam = getEnemyTeam(teamName)
	local cores = getTaggedInstances(RoundConfig.Tags.TeamCore, map, enemyTeam)
	if #cores > 0 then
		return getInstancePosition(cores[rng:NextInteger(1, #cores)])
	end

	local spawns = getTaggedParts(RoundConfig.Tags.TeamSpawn, map, enemyTeam)
	if #spawns > 0 then
		return spawns[rng:NextInteger(1, #spawns)].Position
	end
	return nil
end

local function throwBomb(bot: BotRecord)
	local target = getTargetPosition(bot.teamName)
	if not target then
		return
	end

	local config = getConfig()
	local spread = readNumber(config.AimSpreadStuds, 10, 0, 80)
	local aimTarget = target
		+ Vector3.new(rng:NextNumber(-spread, spread), rng:NextNumber(0, spread * 0.35), rng:NextNumber(-spread, spread))
	local origin = bot.rootPart.Position + Vector3.new(0, readNumber(config.ThrowOriginHeight, 3.2, 0, 10), 0)
	local direction = aimTarget - origin
	if direction.Magnitude <= 0.05 then
		return
	end

	BombService:LaunchStudioAIBomb({
		owner = bot.owner,
		origin = origin,
		aimDirection = direction.Unit,
		remainingFuse = BombConfig.FuseSeconds,
		skinId = BombSkinConfig.DefaultSkinId,
	})
end

local function startThrowLoop(bot: BotRecord)
	bot.throwToken += 1
	local token = bot.throwToken

	task.spawn(function()
		while bot.throwToken == token and bot.alive do
			local config = getConfig()
			local minDelay = readNumber(config.ThrowMinSeconds, 1.8, 0.2, 60)
			local maxDelay = readNumber(config.ThrowMaxSeconds, 3.4, minDelay, 60)
			task.wait(rng:NextNumber(minDelay, maxDelay))
			if bot.throwToken == token and bot.alive then
				throwBomb(bot)
			end
		end
	end)
end

local function removeBot(bot: BotRecord)
	bot.alive = false
	bot.movementToken += 1
	bot.throwToken += 1
	if bot.deathConnection then
		bot.deathConnection:Disconnect()
		bot.deathConnection = nil
	end
	if bot.model.Parent then
		bot.model:Destroy()
	end
end

local function removeBotAt(index: number)
	local bot = bots[index]
	if not bot then
		return
	end
	removeBot(bot)
	table.remove(bots, index)
end

local function cleanupAll()
	for _, bot in ipairs(bots) do
		removeBot(bot)
	end
	table.clear(bots)
	activeRoundId = nil

	local folder = workspace:FindFirstChild(SERVICE_FOLDER_NAME)
	if folder then
		folder:Destroy()
	end
end

local function spawnBot(teamName: string, spawnPart: BasePart, roundId: number)
	nextBotId += 1
	local botId = nextBotId
	local model, humanoid, rootPart = createBotModel(teamName, spawnPart.CFrame, botId)
	model.Parent = getServiceFolder()

	local owner = {
		studioAIBot = true,
		UserId = BOT_USER_ID_BASE - botId,
		Name = ("StudioAI_%s_%02d"):format(teamName, botId),
		DisplayName = ("AI %s"):format(teamName),
		teamName = teamName,
		Character = model,
	}

	local bot: BotRecord = {
		id = botId,
		owner = owner,
		teamName = teamName,
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		homePosition = spawnPart.Position,
		alive = true,
		movementToken = 0,
		throwToken = 0,
		deathConnection = nil,
	}

	bot.deathConnection = humanoid.Died:Connect(function()
		if not bot.alive then
			return
		end
		bot.alive = false
		bot.movementToken += 1
		bot.throwToken += 1
		local respawnDelay = readNumber(getConfig().RespawnSeconds, 4, 0, 60)
		task.delay(respawnDelay, function()
			if activeRoundId ~= roundId or not isEnabled() then
				return
			end
			local state = RoundService:GetState()
			if not isCurrentRound(state) or state.roundId ~= roundId then
				return
			end
			for index, existing in ipairs(bots) do
				if existing == bot then
					removeBotAt(index)
					break
				end
			end
			spawnBot(teamName, spawnPart, roundId)
		end)
	end)

	table.insert(bots, bot)
	startMovementLoop(bot)
	startThrowLoop(bot)
end

local function trimExtraBots(teamName: string, desiredCount: number)
	for index = #bots, 1, -1 do
		if countBots(teamName) <= desiredCount then
			return
		end
		if bots[index].teamName == teamName then
			removeBotAt(index)
		end
	end
end

local function syncBotsForTeam(teamName: string, map: Model, roundId: number, targetTeamSize: number, maxBotsTotal: number)
	local realPlayers = countRealRoundPlayers(teamName, roundId)
	local desiredBots = math.max(targetTeamSize - realPlayers, 0)
	local availableBudget = math.max(maxBotsTotal - #bots + countBots(teamName), 0)
	desiredBots = math.min(desiredBots, availableBudget)

	trimExtraBots(teamName, desiredBots)

	local spawns = getTaggedParts(RoundConfig.Tags.TeamSpawn, map, teamName)
	if #spawns == 0 then
		return
	end

	while countBots(teamName) < desiredBots do
		spawnBot(teamName, spawns[rng:NextInteger(1, #spawns)], roundId)
	end
end

local function syncBots()
	if not isEnabled() then
		cleanupAll()
		return
	end

	local state = RoundService:GetState()
	if not isCurrentRound(state) then
		cleanupAll()
		return
	end

	local map = getActiveMap()
	if not map then
		cleanupAll()
		return
	end

	if activeRoundId ~= state.roundId then
		cleanupAll()
		activeRoundId = state.roundId
	end

	local config = getConfig()
	local targetTeamSize = math.floor(readNumber(config.TargetTeamSize, 6, 0, 24))
	local maxBotsTotal = math.floor(readNumber(config.MaxBotsTotal, targetTeamSize * 2, 0, 48))
	syncBotsForTeam(RoundConfig.Teams.Red.name, map, state.roundId, targetTeamSize, maxBotsTotal)
	syncBotsForTeam(RoundConfig.Teams.Blue.name, map, state.roundId, targetTeamSize, maxBotsTotal)
end

function StudioAIBotService:OnStart()
	if not RunService:IsStudio() or monitorRunning then
		return
	end

	monitorRunning = true
	task.spawn(function()
		while monitorRunning do
			local ok, err = pcall(syncBots)
			if not ok then
				warn("[StudioAIBotService] sync failed:", err)
			end
			task.wait(MONITOR_INTERVAL_SECONDS)
		end
	end)
end

return StudioAIBotService
