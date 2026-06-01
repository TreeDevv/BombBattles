local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local DestructionService = require(ServerScriptService.Services.DestructionService)
local RoundService = require(ServerScriptService.Services.RoundService)

local REMOTES_FOLDER_NAME = "Remotes"
local BEGIN_REMOTE_NAME = "BeginBombCook"
local RELEASE_REMOTE_NAME = "ReleaseBombCook"
local EFFECT_REMOTE_NAME = "BombEffect"
local ROUND_ID_ATTR = "RoundId"
local ROUND_TEAM_ATTR = "RoundTeam"
local ATTR = BombConfig.Attributes

type CookState = {
	startedAt: number,
}

local BombService = {}

local beginRemote: RemoteEvent? = nil
local releaseRemote: RemoteEvent? = nil
local effectRemote: RemoteEvent? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local cookStates: { [Player]: CookState } = {}
local seenRoundIds: { [Player]: number } = {}
local characterConnections: { [Player]: RBXScriptConnection } = {}

local function now(): number
	return workspace:GetServerTimeNow()
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

local function fireEffect(effectName: string, payload)
	if effectRemote then
		effectRemote:FireAllClients(effectName, payload)
	end
end

local function setBombAttributes(player: Player, count: number, rechargeEndsAt: number?)
	player:SetAttribute(ATTR.Max, BombConfig.MaxBombs)
	player:SetAttribute(ATTR.Count, math.clamp(math.floor(count), 0, BombConfig.MaxBombs))
	player:SetAttribute(ATTR.RechargeEndsAt, rechargeEndsAt or 0)
end

local function setCookingAttributes(player: Player, cooking: boolean, startedAt: number?)
	player:SetAttribute(ATTR.Cooking, cooking)
	player:SetAttribute(ATTR.CookStartedAt, startedAt or 0)
end

local function resetPlayerBombs(player: Player)
	cookStates[player] = nil
	setBombAttributes(player, BombConfig.MaxBombs, 0)
	setCookingAttributes(player, false, 0)
end

local function getBombCount(player: Player): number
	local count = player:GetAttribute(ATTR.Count)
	return if typeof(count) == "number" then math.clamp(math.floor(count), 0, BombConfig.MaxBombs) else BombConfig.MaxBombs
end

local function isActivePlayer(player: Player): boolean
	return player.Parent == Players and RoundService:IsPlayerActive(player)
end

local function getCharacterParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return character, humanoid, rootPart
	end

	return character, humanoid, nil
end

local function getTeamName(player: Player): string?
	local teamName = player:GetAttribute(ROUND_TEAM_ATTR)
	return if typeof(teamName) == "string" and teamName ~= "" then teamName else nil
end

local function sanitizeAimDirection(direction: any, fallback: Vector3): Vector3
	if typeof(direction) ~= "Vector3" then
		return fallback
	end
	if direction.X ~= direction.X or direction.Y ~= direction.Y or direction.Z ~= direction.Z then
		return fallback
	end
	if direction.Magnitude < 0.05 or direction.Magnitude > 1.5 then
		return fallback
	end

	local unit = direction.Unit
	unit = Vector3.new(unit.X, math.clamp(unit.Y, BombConfig.MinAimY, BombConfig.MaxAimY), unit.Z)
	if unit.Magnitude < 0.05 then
		return fallback
	end

	return unit.Unit
end

local function getBombAsset(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local bombs = assets and assets:FindFirstChild("Bombs")
	if not bombs then
		return nil
	end

	return bombs:FindFirstChild(BombConfig.RuntimeBombName) or bombs:FindFirstChildWhichIsA("Model") or bombs:FindFirstChildWhichIsA("BasePart")
end

local function getFirstBasePart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function prepareProjectileInstance(): (Instance, BasePart)
	local asset = getBombAsset()
	local projectile: Instance
	local rootPart: BasePart?

	if asset then
		projectile = asset:Clone()
		rootPart = getFirstBasePart(projectile)
	else
		local part = Instance.new("Part")
		part.Name = BombConfig.RuntimeBombName
		part.Shape = Enum.PartType.Ball
		part.Size = BombConfig.RuntimeBombSize
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(45, 45, 45)
		projectile = part
		rootPart = part
	end

	projectile.Name = "BombProjectile"
	if projectile:IsA("Model") and rootPart then
		projectile.PrimaryPart = rootPart
	end

	for _, descendant in ipairs(projectile:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = true
			descendant.CanQuery = false
			descendant.CanTouch = true
		end
	end
	if projectile:IsA("BasePart") then
		projectile.Anchored = false
		projectile.CanCollide = true
		projectile.CanQuery = false
		projectile.CanTouch = true
	end

	assert(rootPart, "Bomb projectile requires a BasePart")
	return projectile, rootPart
end

local function getProjectileFolder(): Folder
	local existing = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = BombConfig.ProjectileFolderName
	folder.Parent = workspace
	return folder
end

local function getDamageForDistance(distance: number, directDamage: number, nearMax: number, nearMin: number, outerMax: number, outerMin: number): number
	if distance <= BombConfig.InnerRadius then
		return directDamage
	end
	if distance <= BombConfig.NearRadius then
		local alpha = (distance - BombConfig.InnerRadius) / math.max(BombConfig.NearRadius - BombConfig.InnerRadius, 0.001)
		return nearMax + (nearMin - nearMax) * alpha
	end
	if distance <= BombConfig.OuterRadius then
		local alpha = (distance - BombConfig.NearRadius) / math.max(BombConfig.OuterRadius - BombConfig.NearRadius, 0.001)
		return outerMax + (outerMin - outerMax) * alpha
	end

	return 0
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

local function applyKnockback(rootPart: BasePart, origin: Vector3, distance: number)
	local away = rootPart.Position - origin
	if away.Magnitude < 0.05 then
		away = Vector3.yAxis
	else
		away = away.Unit
	end

	local radiusAlpha = math.clamp(1 - (distance / BombConfig.OuterRadius), 0, 1)
	local scale = math.max(radiusAlpha, BombConfig.KnockbackMinScale)
	rootPart.AssemblyLinearVelocity += Vector3.new(
		away.X * BombConfig.KnockbackHorizontal * scale,
		BombConfig.KnockbackVertical * scale,
		away.Z * BombConfig.KnockbackHorizontal * scale
	)
end

local function damageEnemyPlayers(owner: Player, origin: Vector3)
	local ownerTeam = getTeamName(owner)

	for _, player in ipairs(Players:GetPlayers()) do
		if player == owner then
			continue
		end
		if ownerTeam and getTeamName(player) == ownerTeam then
			continue
		end

		local _, humanoid, rootPart = getCharacterParts(player)
		if not (humanoid and rootPart and humanoid.Health > 0) then
			continue
		end

		local distance = (rootPart.Position - origin).Magnitude
		local damage = getDamageForDistance(
			distance,
			BombConfig.PlayerDirectDamage,
			BombConfig.PlayerNearDamageMax,
			BombConfig.PlayerNearDamageMin,
			BombConfig.PlayerOuterDamageMax,
			BombConfig.PlayerOuterDamageMin
		)
		if damage <= 0 then
			continue
		end

		humanoid:TakeDamage(damage)
		applyKnockback(rootPart, origin, distance)
	end
end

local function damageEnemyAnchors(owner: Player, origin: Vector3)
	local ownerTeam = getTeamName(owner)

	for _, core in ipairs(CollectionService:GetTagged(RoundConfig.Tags.TeamCore)) do
		local trackedCore = RoundService:GetTrackedCore(core)
		if not trackedCore then
			continue
		end
		if ownerTeam and trackedCore:GetAttribute("Team") == ownerTeam then
			continue
		end

		local position = getInstancePosition(trackedCore)
		if not position then
			continue
		end

		local damage = getDamageForDistance(
			(position - origin).Magnitude,
			BombConfig.AnchorDirectDamage,
			BombConfig.AnchorNearDamageMax,
			BombConfig.AnchorNearDamageMin,
			BombConfig.AnchorOuterDamageMax,
			BombConfig.AnchorOuterDamageMin
		)
		if damage > 0 then
			RoundService:DamageCore(trackedCore, damage)
		end
	end
end

local function explode(owner: Player, position: Vector3, source: string, projectile: Instance?)
	if projectile and projectile.Parent then
		projectile:Destroy()
	end

	fireEffect("Explode", {
		player = owner,
		position = position,
		source = source,
		innerRadius = BombConfig.InnerRadius,
		outerRadius = BombConfig.OuterRadius,
	})

	if not isActivePlayer(owner) then
		return
	end

	DestructionService:DestroySphere(position, BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius)
	damageEnemyPlayers(owner, position)
	damageEnemyAnchors(owner, position)
end

local function stopCooking(player: Player)
	cookStates[player] = nil
	setCookingAttributes(player, false, 0)
end

local function explodeInHand(player: Player, source: string)
	local _, _, rootPart = getCharacterParts(player)
	local position = if rootPart then rootPart.Position else Vector3.zero
	stopCooking(player)
	explode(player, position, source, nil)
end

local function consumeBomb(player: Player): boolean
	local count = getBombCount(player)
	if count <= 0 then
		return false
	end

	count -= 1
	local rechargeEndsAt = player:GetAttribute(ATTR.RechargeEndsAt)
	if typeof(rechargeEndsAt) ~= "number" or rechargeEndsAt <= 0 then
		rechargeEndsAt = now() + BombConfig.RechargeSeconds
	end

	setBombAttributes(player, count, if count < BombConfig.MaxBombs then rechargeEndsAt else 0)
	return true
end

local function beginCook(player: Player)
	if not isActivePlayer(player) then
		return
	end
	if cookStates[player] then
		return
	end
	if not consumeBomb(player) then
		return
	end

	local startedAt = now()
	cookStates[player] = {
		startedAt = startedAt,
	}
	setCookingAttributes(player, true, startedAt)

	fireEffect("Cook", {
		player = player,
		startedAt = startedAt,
		fuseSeconds = BombConfig.FuseSeconds,
	})

	task.delay(BombConfig.FuseSeconds, function()
		local state = cookStates[player]
		if state and state.startedAt == startedAt then
			explodeInHand(player, "InHand")
		end
	end)
end

local function releaseCook(player: Player, aimDirection: any)
	local state = cookStates[player]
	if not state then
		return
	end

	if not isActivePlayer(player) then
		stopCooking(player)
		return
	end

	local _, _, rootPart = getCharacterParts(player)
	if not rootPart then
		stopCooking(player)
		return
	end

	local elapsed = now() - state.startedAt
	if elapsed >= BombConfig.FuseSeconds then
		explodeInHand(player, "InHand")
		return
	end

	stopCooking(player)

	local fallbackDirection = rootPart.CFrame.LookVector
	local direction = sanitizeAimDirection(aimDirection, fallbackDirection)
	local projectile, projectileRoot = prepareProjectileInstance()
	local spawnCFrame = CFrame.new(rootPart.CFrame:PointToWorldSpace(BombConfig.ThrowOffset))
	local folder = getProjectileFolder()

	if projectile:IsA("Model") then
		projectile:PivotTo(spawnCFrame)
	else
		projectile.CFrame = spawnCFrame
	end
	projectile.Parent = folder
	projectileRoot:SetNetworkOwner(nil)
	projectile:SetAttribute("OwnerUserId", player.UserId)
	projectile:SetAttribute("StartedAt", state.startedAt)

	projectileRoot.AssemblyLinearVelocity = (direction * BombConfig.ThrowSpeed)
		+ Vector3.yAxis * BombConfig.ThrowUpBoost
		+ rootPart.AssemblyLinearVelocity * BombConfig.InheritedVelocityScale

	fireEffect("Throw", {
		player = player,
		projectile = projectile,
		position = projectileRoot.Position,
		direction = direction,
		startedAt = state.startedAt,
	})

	local impacted = false
	projectileRoot.Touched:Connect(function(hit)
		if impacted or not hit or hit:IsDescendantOf(player.Character or workspace) then
			return
		end
		impacted = true
		fireEffect("Impact", {
			player = player,
			projectile = projectile,
			position = projectileRoot.Position,
		})
	end)

	local remainingFuse = math.max(BombConfig.FuseSeconds - elapsed, 0)
	task.delay(remainingFuse, function()
		if projectile.Parent then
			explode(player, projectileRoot.Position, "Projectile", projectile)
		end
	end)
	task.delay(remainingFuse + BombConfig.ProjectileLifetimePadding, function()
		if projectile.Parent then
			projectile:Destroy()
		end
	end)
end

local function updateRecharge(player: Player, currentTime: number)
	local count = getBombCount(player)
	if count >= BombConfig.MaxBombs then
		setBombAttributes(player, BombConfig.MaxBombs, 0)
		return
	end

	local rechargeEndsAt = player:GetAttribute(ATTR.RechargeEndsAt)
	if typeof(rechargeEndsAt) ~= "number" or rechargeEndsAt <= 0 then
		setBombAttributes(player, count, currentTime + BombConfig.RechargeSeconds)
		return
	end
	if currentTime < rechargeEndsAt then
		return
	end

	count += 1
	setBombAttributes(
		player,
		count,
		if count < BombConfig.MaxBombs then currentTime + BombConfig.RechargeSeconds else 0
	)
end

local function syncPlayerRoundState(player: Player)
	local roundId = player:GetAttribute(ROUND_ID_ATTR)
	if typeof(roundId) ~= "number" then
		if seenRoundIds[player] ~= nil then
			seenRoundIds[player] = nil
			resetPlayerBombs(player)
		end
		if cookStates[player] then
			stopCooking(player)
		end
		return
	end

	if seenRoundIds[player] ~= roundId then
		seenRoundIds[player] = roundId
		resetPlayerBombs(player)
	end
end

local function disconnectCharacter(player: Player)
	local connection = characterConnections[player]
	if connection then
		connection:Disconnect()
		characterConnections[player] = nil
	end
end

function BombService:OnStart()
	beginRemote = ensureRemote(BEGIN_REMOTE_NAME)
	releaseRemote = ensureRemote(RELEASE_REMOTE_NAME)
	effectRemote = ensureRemote(EFFECT_REMOTE_NAME)

	beginRemote.OnServerEvent:Connect(beginCook)
	releaseRemote.OnServerEvent:Connect(releaseCook)

	if heartbeatConnection then
		heartbeatConnection:Disconnect()
	end
	heartbeatConnection = game:GetService("RunService").Heartbeat:Connect(function()
		local currentTime = now()
		for _, player in ipairs(Players:GetPlayers()) do
			syncPlayerRoundState(player)
			if not isActivePlayer(player) and cookStates[player] then
				stopCooking(player)
			end
			updateRecharge(player, currentTime)
		end
	end)
end

function BombService:OnPlayerAdded(player: Player)
	resetPlayerBombs(player)
	disconnectCharacter(player)
	characterConnections[player] = player.CharacterAdded:Connect(function()
		if cookStates[player] then
			stopCooking(player)
		end
	end)
end

function BombService:OnPlayerRemoving(player: Player)
	stopCooking(player)
	seenRoundIds[player] = nil
	disconnectCharacter(player)
end

return BombService
