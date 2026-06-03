local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)
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
	holdStartedAt: number,
	cookStartedAt: number?,
}

type ProjectileState = {
	id: string,
	owner: Player,
	path: any,
	launchedAt: number,
	explodeAt: number,
	position: Vector3,
	lastPosition: Vector3,
	landed: boolean,
	physicalProjectile: Instance?,
	physicalRoot: BasePart?,
}

local BombService = {}

local beginRemote: RemoteEvent? = nil
local releaseRemote: RemoteEvent? = nil
local effectRemote: RemoteEvent? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local cookStates: { [Player]: CookState } = {}
local activeProjectiles: { [string]: ProjectileState } = {}
local seenRoundIds: { [Player]: number } = {}
local characterConnections: { [Player]: RBXScriptConnection } = {}
local nextProjectileId = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function isStudioBombTeamProtectionBypassEnabled(): boolean
	if not RunService:IsStudio() then
		return false
	end

	local studioTesting = RoundConfig.StudioTesting
	return studioTesting ~= nil and studioTesting.AllowBombTeamProtectionBypass == true
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

local function getThrowOrigin(rootPart: BasePart): Vector3
	return rootPart.CFrame:PointToWorldSpace(BombConfig.ThrowOffset)
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

local function preparePhysicalProjectile(projectileId: string, owner: Player): (Instance, BasePart)
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

	projectile.Name = "BombProjectile_" .. projectileId
	if projectile:IsA("Model") and rootPart then
		projectile.PrimaryPart = rootPart
	end

	for _, descendant in ipairs(projectile:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = true
			descendant.CanQuery = true
			descendant.CanTouch = false
		end
	end
	if projectile:IsA("BasePart") then
		projectile.Anchored = false
		projectile.CanCollide = true
		projectile.CanQuery = true
		projectile.CanTouch = false
	end

	assert(rootPart, "Bomb projectile requires a BasePart")
	projectile:SetAttribute("ProjectileId", projectileId)
	projectile:SetAttribute("OwnerUserId", owner.UserId)
	return projectile, rootPart
end

local function getTargetPositionFromPayload(payload: any, origin: Vector3, fallbackDirection: Vector3): Vector3
	if typeof(payload) == "table" then
		local targetPosition = payload.targetPosition
		if BombTrajectory.IsFiniteVector(targetPosition) then
			return targetPosition
		end

		local aimDirection = payload.aimDirection
		if BombTrajectory.IsFiniteVector(aimDirection) then
			local direction = sanitizeAimDirection(aimDirection, fallbackDirection)
			return origin + direction * BombConfig.NoHitFallbackDistance
		end
	elseif BombTrajectory.IsFiniteVector(payload) then
		if payload.Magnitude > 1.5 then
			return payload
		end

		local direction = sanitizeAimDirection(payload, fallbackDirection)
		return origin + direction * BombConfig.NoHitFallbackDistance
	end

	return origin + fallbackDirection * BombConfig.NoHitFallbackDistance
end

local function calculateTrajectory(origin: Vector3, targetPosition: Vector3)
	return BombTrajectory.CreatePath(
		origin,
		targetPosition,
		BombConfig.TravelSpeed,
		BombConfig.ArcHeightMin,
		BombConfig.ArcHeightPerStud,
		BombConfig.ArcHeightMax
	)
end

local function createTargetResolveParams(owner: Player): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = owner.Character
	params.FilterDescendantsInstances = if character then { character } else {}
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return params
end

local function resolveLandingTarget(owner: Player, origin: Vector3, targetPosition: Vector3, useDirectTarget: boolean): Vector3
	local params = createTargetResolveParams(owner)
	local resolvedTargetPosition = BombTrajectory.ResolveLandingTarget(
		origin,
		targetPosition,
		useDirectTarget,
		BombConfig.LandingResolveUp,
		BombConfig.LandingResolveDown,
		BombConfig.NoHitFallbackDistance,
		function(rayOrigin: Vector3, rayDirection: Vector3)
			return workspace:Raycast(rayOrigin, rayDirection, params)
		end
	)
	return resolvedTargetPosition
end

local function createProjectileId(player: Player): string
	nextProjectileId += 1
	return string.format("%d:%d", player.UserId, nextProjectileId)
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
	local bypassTeamProtection = isStudioBombTeamProtectionBypassEnabled()

	for _, core in ipairs(CollectionService:GetTagged(RoundConfig.Tags.TeamCore)) do
		local trackedCore = RoundService:GetTrackedCore(core)
		if not trackedCore then
			continue
		end
		if not bypassTeamProtection and ownerTeam and trackedCore:GetAttribute("Team") == ownerTeam then
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

local function destroyPhysicalProjectile(state: ProjectileState?)
	if not state then
		return
	end

	local projectile = state.physicalProjectile
	state.physicalProjectile = nil
	state.physicalRoot = nil
	if projectile and projectile.Parent then
		projectile:Destroy()
	end
end

local function getProjectilePhysicsPosition(state: ProjectileState): Vector3
	local rootPart = state.physicalRoot
	if rootPart and rootPart.Parent then
		return rootPart.Position
	end

	return state.position
end

local function explode(owner: Player, position: Vector3, source: string, projectileId: string?)
	if projectileId then
		local state = activeProjectiles[projectileId]
		if state then
			position = getProjectilePhysicsPosition(state)
			destroyPhysicalProjectile(state)
		end
		activeProjectiles[projectileId] = nil
	end
	fireEffect("Explode", {
		player = owner,
		projectileId = projectileId,
		position = position,
		source = source,
		innerRadius = BombConfig.InnerRadius,
		outerRadius = BombConfig.OuterRadius,
	})

	if not isActivePlayer(owner) then
		return
	end

	local debrisPayloads = DestructionService:DestroySphere(position, BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius)
	if #debrisPayloads > 0 then
		fireEffect("TerrainDebris", {
			payloads = debrisPayloads,
		})
	end
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

local function scheduleInHandExplosion(player: Player, state: CookState, cookStartedAt: number)
	task.delay(BombConfig.FuseSeconds, function()
		local currentState = cookStates[player]
		if currentState == state and currentState.cookStartedAt == cookStartedAt then
			explodeInHand(player, "InHand")
		end
	end)
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

local function startActiveCook(player: Player, state: CookState)
	if cookStates[player] ~= state or state.cookStartedAt then
		return
	end
	if not isActivePlayer(player) then
		stopCooking(player)
		return
	end
	if not consumeBomb(player) then
		stopCooking(player)
		return
	end

	local cookStartedAt = now()
	state.cookStartedAt = cookStartedAt
	setCookingAttributes(player, true, cookStartedAt)

	fireEffect("Cook", {
		player = player,
		startedAt = cookStartedAt,
		fuseSeconds = BombConfig.FuseSeconds,
	})

	scheduleInHandExplosion(player, state, cookStartedAt)
end

local function createSweepParams(owner: Player): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = owner.Character
	params.FilterDescendantsInstances = if character then { character } else {}
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return params
end

local function getSurfaceNormal(owner: Player, position: Vector3): Vector3
	local params = createSweepParams(owner)
	local rayOrigin = position + Vector3.yAxis * BombConfig.PostImpactNormalProbeUp
	local rayDirection = Vector3.new(0, -(BombConfig.PostImpactNormalProbeUp + BombConfig.PostImpactNormalProbeDown), 0)
	local hit = workspace:Raycast(rayOrigin, rayDirection, params)
	if hit and BombTrajectory.IsFiniteVector(hit.Normal) and hit.Normal.Magnitude > 0.05 then
		return hit.Normal.Unit
	end

	return Vector3.yAxis
end

local function sweepProjectile(owner: Player, fromPosition: Vector3, toPosition: Vector3): RaycastResult?
	local direction = toPosition - fromPosition
	if direction.Magnitude <= 0.001 then
		return nil
	end

	local params = createSweepParams(owner)
	local spherecastOk, spherecastResult = pcall(function()
		return workspace:Spherecast(fromPosition, BombConfig.SweepRadius, direction, params)
	end)
	if spherecastOk then
		return spherecastResult
	end

	return workspace:Raycast(fromPosition, direction, params)
end

local function clampVectorMagnitude(vector: Vector3, maxMagnitude: number): Vector3
	if vector.Magnitude <= maxMagnitude then
		return vector
	end

	return vector.Unit * maxMagnitude
end

local function getPostImpactVelocity(incomingVelocity: Vector3, normal: Vector3): Vector3
	if incomingVelocity.Magnitude <= 0.001 then
		return Vector3.zero
	end

	local unitNormal = if normal.Magnitude > 0.05 then normal.Unit else Vector3.yAxis
	local normalComponent = unitNormal * incomingVelocity:Dot(unitNormal)
	local tangentComponent = incomingVelocity - normalComponent
	local bouncedComponent = -normalComponent * BombConfig.PostImpactBounce
	local velocity = (tangentComponent + bouncedComponent) * BombConfig.PostImpactVelocityScale
	return clampVectorMagnitude(velocity, BombConfig.PostImpactMaxSpeed)
end

local function setProjectileAssemblyMotion(projectile: Instance, velocity: Vector3, angularVelocity: Vector3)
	for _, descendant in ipairs(projectile:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = velocity
			descendant.AssemblyAngularVelocity = angularVelocity
			pcall(function()
				descendant:SetNetworkOwner(nil)
			end)
		end
	end
	if projectile:IsA("BasePart") then
		projectile.AssemblyLinearVelocity = velocity
		projectile.AssemblyAngularVelocity = angularVelocity
		pcall(function()
			projectile:SetNetworkOwner(nil)
		end)
	end
end

local function spawnPhysicalProjectile(state: ProjectileState, position: Vector3, normal: Vector3, incomingVelocity: Vector3): Instance?
	local projectile, rootPart = preparePhysicalProjectile(state.id, state.owner)
	local unitNormal = if normal.Magnitude > 0.05 then normal.Unit else Vector3.yAxis
	local spawnPosition = position + unitNormal * BombConfig.PostImpactSpawnNormalOffset
	local spawnCFrame = CFrame.new(spawnPosition)

	if projectile:IsA("Model") then
		projectile:PivotTo(spawnCFrame)
	else
		projectile.CFrame = spawnCFrame
	end

	projectile.Parent = getProjectileFolder()

	local velocity = getPostImpactVelocity(incomingVelocity, unitNormal)
	local spinAxis = incomingVelocity:Cross(unitNormal)
	if spinAxis.Magnitude <= 0.05 then
		spinAxis = Vector3.new(0.35, 1, 0.2)
	end
	local angularVelocity = spinAxis.Unit * BombConfig.PostImpactAngularSpeed
	setProjectileAssemblyMotion(projectile, velocity, angularVelocity)

	state.physicalProjectile = projectile
	state.physicalRoot = rootPart
	state.position = rootPart.Position
	state.lastPosition = rootPart.Position
	return projectile
end

local function fireProjectileImpact(state: ProjectileState, position: Vector3, normal: Vector3, incomingVelocity: Vector3)
	if state.landed then
		return
	end

	state.landed = true
	state.position = position
	state.lastPosition = position
	local physicalProjectile = spawnPhysicalProjectile(state, position, normal, incomingVelocity)
	fireEffect("Impact", {
		player = state.owner,
		projectileId = state.id,
		position = position,
		impactNormal = normal,
		impactVelocity = incomingVelocity,
		physicalProjectile = physicalProjectile,
	})
end

local function throwBomb(player: Player, rootPart: BasePart, targetPayload: any, startedAt: number, remainingFuse: number)
	local fallbackDirection = rootPart.CFrame.LookVector
	local origin = getThrowOrigin(rootPart)
	local targetPosition = getTargetPositionFromPayload(targetPayload, origin, fallbackDirection)
	local useDirectTarget = typeof(targetPayload) == "table" and targetPayload.targetHit == true
	local resolvedTargetPosition = resolveLandingTarget(player, origin, targetPosition, useDirectTarget)
	local trajectory = calculateTrajectory(origin, resolvedTargetPosition)
	local projectileId = createProjectileId(player)
	local launchTime = now()
	local explodeAt = launchTime + remainingFuse
	local state: ProjectileState = {
		id = projectileId,
		owner = player,
		path = trajectory,
		launchedAt = launchTime,
		explodeAt = explodeAt,
		position = origin,
		lastPosition = origin,
		landed = false,
		physicalProjectile = nil,
		physicalRoot = nil,
	}
	activeProjectiles[projectileId] = state

	fireEffect("Throw", {
		player = player,
		projectileId = projectileId,
		origin = trajectory.origin,
		targetPosition = trajectory.resolvedTargetPosition,
		controlPoint = trajectory.controlPoint,
		duration = trajectory.duration,
		startedAt = launchTime,
		fuseStartedAt = startedAt,
		remainingFuse = remainingFuse,
	})

	task.delay(remainingFuse + BombConfig.ProjectileLifetimePadding, function()
		local currentState = activeProjectiles[projectileId]
		if currentState then
			destroyPhysicalProjectile(currentState)
			activeProjectiles[projectileId] = nil
		end
	end)
end

local function updateProjectileStates(currentTime: number)
	for projectileId, state in pairs(activeProjectiles) do
		if not state.owner.Parent then
			destroyPhysicalProjectile(state)
			activeProjectiles[projectileId] = nil
			continue
		end
		if currentTime >= state.explodeAt then
			if state.landed then
				state.position = getProjectilePhysicsPosition(state)
				state.lastPosition = state.position
			else
				local fuseAlpha = math.clamp((state.explodeAt - state.launchedAt) / state.path.duration, 0, 1)
				state.position = BombTrajectory.Evaluate(state.path, fuseAlpha)
				state.lastPosition = state.position
			end

			explode(state.owner, state.position, "Projectile", projectileId)
			continue
		end
		if state.landed then
			state.position = getProjectilePhysicsPosition(state)
			state.lastPosition = state.position
			continue
		end

		local alpha = math.clamp((currentTime - state.launchedAt) / state.path.duration, 0, 1)
		local nextPosition = BombTrajectory.Evaluate(state.path, alpha)
		local hit = sweepProjectile(state.owner, state.lastPosition, nextPosition)
		if hit then
			fireProjectileImpact(state, hit.Position, hit.Normal, BombTrajectory.GetVelocity(state.path, alpha))
		elseif alpha >= 1 then
			local position = state.path.resolvedTargetPosition
			fireProjectileImpact(state, position, getSurfaceNormal(state.owner, position), BombTrajectory.GetVelocity(state.path, 1))
		else
			state.position = nextPosition
			state.lastPosition = nextPosition
		end
	end
end

local function beginCook(player: Player)
	if not isActivePlayer(player) then
		return
	end
	if cookStates[player] then
		return
	end
	if getBombCount(player) <= 0 then
		return
	end

	local state = {
		holdStartedAt = now(),
	}
	cookStates[player] = state
	setCookingAttributes(player, false, 0)

	task.delay(BombConfig.CookDelaySeconds, function()
		startActiveCook(player, state)
	end)
end

local function releaseCook(player: Player, targetPayload: any)
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

	local currentTime = now()
	local cookStartedAt = state.cookStartedAt
	local throwStartedAt = currentTime
	local remainingFuse = BombConfig.FuseSeconds

	if cookStartedAt then
		local elapsed = currentTime - cookStartedAt
		if elapsed >= BombConfig.FuseSeconds then
			explodeInHand(player, "InHand")
			return
		end

		throwStartedAt = cookStartedAt
		remainingFuse = math.max(BombConfig.FuseSeconds - elapsed, 0)
	elseif not consumeBomb(player) then
		stopCooking(player)
		return
	end

	if remainingFuse <= 0 then
		explodeInHand(player, "InHand")
		return
	end

	stopCooking(player)
	throwBomb(player, rootPart, targetPayload, throwStartedAt, remainingFuse)
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

local function clearPlayerProjectiles(player: Player)
	for projectileId, state in pairs(activeProjectiles) do
		if state.owner == player then
			destroyPhysicalProjectile(state)
			activeProjectiles[projectileId] = nil
		end
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
		updateProjectileStates(currentTime)
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
	clearPlayerProjectiles(player)
	disconnectCharacter(player)
end

return BombService
