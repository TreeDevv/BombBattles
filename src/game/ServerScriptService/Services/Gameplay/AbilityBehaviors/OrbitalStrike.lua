local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local DestructionService = require(ServerScriptService.Services.DestructionService)
local RoundService = require(ServerScriptService.Services.RoundService)

type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerClientMessageContext = AbilityTypes.ServerClientMessageContext

type TargetSession = {
	sessionId: number,
	slot: string,
	abilityId: string,
}

local OrbitalStrike = {} :: AbilityTypes.ServerBehavior

local OBJECTS_FOLDER_NAME = "OrbitalStrikeObjects"
local WARNING_FOLDER_NAME = "Warnings"
local DAMAGE_ZONE_FOLDER_NAME = "DamageZones"
local TELEGRAPH_EFFECT = "OrbitalStrikeTelegraph"
local IMPACT_EFFECT = "OrbitalStrikeImpact"
local HIT_FLASH_EFFECT = "OrbitalStrikeHitFlash"
local BEGIN_TARGETING_EFFECT = "OrbitalStrikeBeginTargeting"
local REJECTED_EFFECT = "OrbitalStrikeRejected"
local CANCELLED_EFFECT = "OrbitalStrikeCancelled"
local TARGET_RAY_DISTANCE = 10000
local TARGET_HIT_TOLERANCE = 8

local abilityService: AbilityServiceLike? = nil
local sessions: { [Player]: TargetSession } = {}
local nextSessionId = 0

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function isFiniteVector(value: any): boolean
	return typeof(value) == "Vector3"
		and value.X == value.X
		and value.Y == value.Y
		and value.Z == value.Z
		and value.Magnitude < math.huge
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

local function isReady(context: ServerClientMessageContext): boolean
	if context.player.Parent ~= Players then
		return false
	end
	if context.slotState.abilityId ~= context.abilityId then
		return false
	end
	if not CombatEligibility.IsCombatActive(context.player, RoundService) then
		return false
	end
	if not getCharacterRoot(context.player) then
		return false
	end
	if typeof(context.slotState.cooldownEndsAt) == "number" and context.slotState.cooldownEndsAt > context.now then
		return false
	end
	return true
end

local function getActiveMap(): Model?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getTargetBoundsRoot(player: Player): Model?
	local targetRoot = if CombatEligibility.IsPracticeOnly(player, RoundService)
		then PracticeRangeTargeting.GetServerTargetRoot(player, getActiveMap())
		else getActiveMap()
	return if targetRoot and targetRoot:IsA("Model") then targetRoot else nil
end

local function getTeamName(player: Player): string?
	local teamName = player:GetAttribute("RoundTeam")
	return if typeof(teamName) == "string" and teamName ~= "" then teamName else nil
end

local function isEnemyPlayer(owner: Player, target: Player?): boolean
	if not target or target == owner then
		return false
	end
	if target.Parent ~= Players or not RoundService:IsPlayerActive(target) then
		return false
	end

	local ownerTeam = getTeamName(owner)
	local targetTeam = getTeamName(target)
	return not (ownerTeam and targetTeam and ownerTeam == targetTeam)
end

local function getMapVerticalBounds(map: Model?, radius: number, fallbackPosition: Vector3): (number, number)
	if not map then
		return fallbackPosition.Y + radius * 2, fallbackPosition.Y - radius * 3
	end

	local boundsCFrame, boundsSize = map:GetBoundingBox()
	local topY = boundsCFrame.Position.Y + boundsSize.Y * 0.5 + radius
	local bottomY = boundsCFrame.Position.Y - boundsSize.Y * 0.5 - radius
	return math.max(topY, fallbackPosition.Y + radius), math.min(bottomY, fallbackPosition.Y - radius)
end

local function getObjectsFolder(player: Player): Folder
	local parent = PracticeRangeTargeting.GetObjectParentForServer(player, getActiveMap())
	local existing = parent:FindFirstChild(OBJECTS_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = OBJECTS_FOLDER_NAME
	folder.Parent = parent
	return folder
end

local function getChildFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function makeRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return params
end

local function validateTarget(payload: any): (Vector3?, string?)
	if typeof(payload) ~= "table" then
		return nil, "InvalidPayload"
	end
	local rayOrigin = payload.rayOrigin
	local rayDirection = payload.rayDirection
	local clientHitPosition = payload.hitPosition
	if not isFiniteVector(rayOrigin) or not isFiniteVector(rayDirection) or not isFiniteVector(clientHitPosition) then
		return nil, "InvalidRay"
	end
	if rayDirection.Magnitude < 0.05 then
		return nil, "InvalidRay"
	end

	local hit = workspace:Raycast(rayOrigin, rayDirection.Unit * TARGET_RAY_DISTANCE, makeRaycastParams())
	if not hit then
		return nil, "NoSurface"
	end
	if (hit.Position - clientHitPosition).Magnitude > TARGET_HIT_TOLERANCE then
		return nil, "RayMismatch"
	end

	return hit.Position, nil
end

local function fireToPlayer(player: Player, effectName: string, payload: any?)
	if abilityService and type(abilityService.FireEffectToPlayer) == "function" then
		abilityService:FireEffectToPlayer(player, effectName, payload)
	end
end

local function fireAll(effectName: string, payload: any?)
	if abilityService and type(abilityService.FireEffect) == "function" then
		abilityService:FireEffect(effectName, payload)
	end
end

local function reject(player: Player, sessionId: number?, reason: string)
	fireToPlayer(player, REJECTED_EFFECT, {
		abilityId = "OrbitalStrike",
		sessionId = sessionId,
		reason = reason,
	})
end

local function setCooldownAndState(context: ServerClientMessageContext, position: Vector3): boolean
	if not abilityService then
		return false
	end

	local state = context.slotState.state
	local strikesCalled = if typeof(state) == "table" and typeof(state.strikesCalled) == "number" then state.strikesCalled else 0
	return abilityService:SetSlotValues(context.player, context.slot, {
		cooldownEndsAt = context.now + math.max(getDefinitionNumber(context.definition, "cooldownSeconds", 60), 0),
		activeEndsAt = 0,
		state = {
			strikesCalled = strikesCalled + 1,
			lastActivatedAt = context.now,
			lastTargetPosition = position,
		},
	})
end

local function spawnWarningPart(position: Vector3, radius: number, lifetime: number): BasePart
	local warning = Instance.new("Part")
	warning.Name = "OrbitalStrikeWarning"
	warning.Anchored = true
	warning.CanCollide = false
	warning.CanTouch = false
	warning.CanQuery = false
	warning.Shape = Enum.PartType.Cylinder
	warning.Size = Vector3.new(0.08, radius * 2, radius * 2)
	warning.CFrame = CFrame.new(position + Vector3.yAxis * 0.08) * CFrame.Angles(0, 0, math.rad(90))
	warning.Color = Color3.fromRGB(255, 70, 70)
	warning.Material = Enum.Material.Neon
	warning.Transparency = 0.62
	warning.Parent = getChildFolder(getObjectsFolder(player), WARNING_FOLDER_NAME)

	task.delay(lifetime, function()
		if warning.Parent then
			warning:Destroy()
		end
	end)
	return warning
end

local function createDamageZone(position: Vector3, radius: number, topY: number, bottomY: number): BasePart
	local height = math.max(topY - bottomY, radius * 2)
	local zone = Instance.new("Part")
	zone.Name = "OrbitalStrikeDamageZone"
	zone.Anchored = true
	zone.CanCollide = false
	zone.CanTouch = false
	zone.CanQuery = true
	zone.Transparency = 1
	zone.Shape = Enum.PartType.Cylinder
	zone.Size = Vector3.new(height, radius * 2, radius * 2)
	zone.CFrame = CFrame.new(position.X, bottomY + height * 0.5, position.Z) * CFrame.Angles(0, 0, math.rad(90))
	zone.Parent = getChildFolder(getObjectsFolder(player), DAMAGE_ZONE_FOLDER_NAME)
	return zone
end

local function shouldSuppressAbilityDamage(result): boolean
	return typeof(result) == "table" and (result.kind == AbilityResult.Kind.Block or result.kind == AbilityResult.Kind.Absorb)
end

local function getDamageTargets(owner: Player, zone: BasePart, overlapParams: OverlapParams): { [Player]: { humanoid: Humanoid, rootPart: BasePart, character: Model } }
	local targets = {}
	local ok, parts = pcall(function()
		return workspace:GetPartsInPart(zone, overlapParams)
	end)
	if not ok then
		warn("[OrbitalStrike] Failed to query damage zone overlaps: " .. tostring(parts))
		return targets
	end

	for _, part in ipairs(parts) do
		local character = part:FindFirstAncestorOfClass("Model")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if not (character and humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart")) then
			continue
		end

		local target = Players:GetPlayerFromCharacter(character)
		if isEnemyPlayer(owner, target) then
			targets[target :: Player] = {
				humanoid = humanoid,
				rootPart = rootPart,
				character = character,
			}
		end
	end

	return targets
end

local function damagePlayers(
	owner: Player,
	zone: BasePart,
	overlapParams: OverlapParams,
	origin: Vector3,
	radius: number,
	damage: number,
	sessionId: number,
	hitFlashSent: { [Player]: boolean },
	hitFlashDuration: number,
	hitFlashTransparency: number
)
	if damage <= 0 then
		return
	end

	for target, targetInfo in pairs(getDamageTargets(owner, zone, overlapParams)) do
		local humanoid = targetInfo.humanoid
		local healthBefore = humanoid.Health
		if healthBefore <= 0 then
			continue
		end

		local distance = Vector3.new(targetInfo.rootPart.Position.X - origin.X, 0, targetInfo.rootPart.Position.Z - origin.Z).Magnitude
		local hookResult = if abilityService
			then abilityService:RunHook("OnBeforePlayerBombDamage", {
				owner = owner,
				target = target,
				character = targetInfo.character,
				humanoid = humanoid,
				rootPart = targetInfo.rootPart,
				origin = origin,
				distance = distance,
				damage = damage,
				explosion = {
					outerRadius = radius,
					sourceType = "Ability",
					sourceId = "OrbitalStrike",
				},
			})
			else nil
		if shouldSuppressAbilityDamage(hookResult) then
			continue
		end
		local resolvedDamage = damage
		if typeof(hookResult) == "table" and typeof(hookResult.damage) == "number" then
			resolvedDamage = math.max(hookResult.damage, 0)
		elseif typeof(hookResult) == "table" and typeof(hookResult.damageMultiplier) == "number" then
			resolvedDamage = math.max(resolvedDamage * hookResult.damageMultiplier, 0)
		end
		if typeof(hookResult) == "table" and hookResult.skipDamage == true then
			continue
		end
		if resolvedDamage <= 0 then
			continue
		end

		RoundService:RecordPlayerDamage(owner, target, math.min(resolvedDamage, healthBefore), {
			sourceType = "Ability",
			sourceId = "OrbitalStrike",
		})
		humanoid:TakeDamage(resolvedDamage)
		if humanoid.Health < healthBefore and not hitFlashSent[target] then
			hitFlashSent[target] = true
			fireToPlayer(target, HIT_FLASH_EFFECT, {
				abilityId = "OrbitalStrike",
				sessionId = sessionId,
				durationSeconds = hitFlashDuration,
				initialTransparency = hitFlashTransparency,
			})
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
	return nil
end

local function isPositionInsideColumn(position: Vector3, origin: Vector3, radius: number, topY: number, bottomY: number): boolean
	if position.Y < bottomY or position.Y > topY then
		return false
	end
	local horizontal = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z)
	return horizontal.Magnitude <= radius
end

local function damageCores(owner: Player, origin: Vector3, radius: number, topY: number, bottomY: number, damage: number)
	if damage <= 0 then
		return
	end

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
		if not position or not isPositionInsideColumn(position, origin, radius, topY, bottomY) then
			continue
		end

		local hookResult = if abilityService
			then abilityService:RunHook("OnBeforeCoreBombDamage", {
				owner = owner,
				core = trackedCore,
				origin = origin,
				position = position,
				damage = damage,
				explosion = {
					outerRadius = radius,
					sourceType = "Ability",
					sourceId = "OrbitalStrike",
				},
			})
			else nil
		if shouldSuppressAbilityDamage(hookResult) then
			continue
		end
		local resolvedDamage = damage
		if typeof(hookResult) == "table" and typeof(hookResult.damage) == "number" then
			resolvedDamage = math.max(hookResult.damage, 0)
		elseif typeof(hookResult) == "table" and typeof(hookResult.damageMultiplier) == "number" then
			resolvedDamage = math.max(resolvedDamage * hookResult.damageMultiplier, 0)
		end
		if typeof(hookResult) == "table" and hookResult.skipDamage == true then
			continue
		end
		if resolvedDamage > 0 then
			RoundService:DamageCore(trackedCore, resolvedDamage, {
				attackerUserId = owner.UserId,
				sourceType = "Ability",
				sourceId = "OrbitalStrike",
			})
		end
	end
end

local function startDamageTicks(player: Player, definition: AbilityDefinition, sessionId: number, position: Vector3, radius: number, topY: number, bottomY: number)
	local durationSeconds = math.max(getDefinitionNumber(definition, "strikeDurationSeconds", 3), 0)
	local tickSeconds = math.max(getDefinitionNumber(definition, "strikeTickSeconds", 0.5), 0.05)
	local tickCount = math.max(math.floor(durationSeconds / tickSeconds + 0.5), 1)
	local playerTickDamage = math.max(getDefinitionNumber(definition, "totalPlayerDamage", 115), 0) / tickCount
	local coreTickDamage = math.max(getDefinitionNumber(definition, "totalCoreDamage", 30), 0) / tickCount
	local hitFlashDuration = math.max(getDefinitionNumber(definition, "blackFlashHitDuration", 3), 0.1)
	local hitFlashTransparency = math.clamp(getDefinitionNumber(definition, "blackFlashClosestTransparency", 0.3), 0, 1)
	local hitFlashSent: { [Player]: boolean } = {}

	local zone = createDamageZone(position, radius, topY, bottomY)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { zone }

	task.spawn(function()
		for _ = 1, tickCount do
			if not (zone.Parent and player.Parent == Players and CombatEligibility.IsCombatActive(player, RoundService)) then
				break
			end
			damagePlayers(
				player,
				zone,
				overlapParams,
				position,
				radius,
				playerTickDamage,
				sessionId,
				hitFlashSent,
				hitFlashDuration,
				hitFlashTransparency
			)
			if coreTickDamage > 0 then
				damageCores(player, position, radius, topY, bottomY, coreTickDamage)
			end
			task.wait(tickSeconds)
		end

		if zone.Parent then
			zone:Destroy()
		end
	end)
end

local function getTerrainColumnData(definition: AbilityDefinition, position: Vector3, radius: number, bottomY: number)
	local explosionRadius = math.max(getDefinitionNumber(definition, "terrainOnlyExplosionRadius", radius), 1)
	local depth = math.max(position.Y - bottomY, explosionRadius)
	local columnBottomY = position.Y - depth
	local step = math.max(explosionRadius * getDefinitionNumber(definition, "terrainColumnStepScale", 0.55), 1)
	local stepCount = math.max(math.floor(depth / step) + 1, 1)
	if (stepCount - 1) * step < depth then
		stepCount += 1
	end
	local duration = math.max(getDefinitionNumber(definition, "terrainColumnDurationSeconds", 1.4), 0)
	local interval = if stepCount > 1 then duration / (stepCount - 1) else 0
	return explosionRadius, depth, columnBottomY, step, stepCount, interval
end

local function startTerrainColumn(player: Player, definition: AbilityDefinition, position: Vector3, radius: number, bottomY: number)
	local explosionRadius, depth, _, step, stepCount, interval = getTerrainColumnData(definition, position, radius, bottomY)
	local sourceContext = {
		sourceType = "Ability",
		sourceId = "OrbitalStrike",
		ownerUserId = player.UserId,
		timestamp = workspace:GetServerTimeNow(),
	}

	task.spawn(function()
		local transparentCollisionClearance =
			math.max(getDefinitionNumber(definition, "terrainTransparentCollisionClearance", 0), 0)
		local maxTargetsPerExplosion = getDefinitionNumber(definition, "terrainColumnMaxTargetsPerStep", 32)
		for index = 0, stepCount - 1 do
			local offset = math.min(index * step, depth)
			DestructionService:DestroySphere(position - Vector3.yAxis * offset, explosionRadius, sourceContext, {
				forceSubtract = true,
				transparentCollisionClearance = transparentCollisionClearance,
				maxTargetsPerExplosion = maxTargetsPerExplosion,
			})
			if index < stepCount - 1 and interval > 0 then
				task.wait(interval)
			end
		end
	end)
end

local function scheduleStrike(player: Player, definition: AbilityDefinition, sessionId: number, position: Vector3)
	local delaySeconds = math.max(getDefinitionNumber(definition, "strikeDelay", 1.35), 0)
	task.delay(delaySeconds, function()
		local currentSession = sessions[player]
		if currentSession and currentSession.sessionId == sessionId then
			sessions[player] = nil
		end
		if player.Parent ~= Players or not CombatEligibility.IsCombatActive(player, RoundService) then
			return
		end

		local radius = getDefinitionNumber(definition, "strikeRadius", 22)
		local boundsRoot = getTargetBoundsRoot(player)
		local topY, bottomY = getMapVerticalBounds(boundsRoot, radius, position)
		local terrainRadius, _terrainDepth, columnBottomY, terrainStep, _terrainStepCount, terrainStepInterval =
			getTerrainColumnData(definition, position, radius, bottomY)
		fireAll(IMPACT_EFFECT, {
			player = player,
			abilityId = "OrbitalStrike",
			sessionId = sessionId,
			position = position,
			radius = radius,
			durationSeconds = getDefinitionNumber(definition, "strikeDurationSeconds", 3),
			columnTopY = position.Y,
			columnBottomY = columnBottomY,
			terrainStep = terrainStep,
			terrainStepInterval = terrainStepInterval,
			terrainExplosionRadius = terrainRadius,
			blackFlashRadius = getDefinitionNumber(definition, "blackFlashRadius", 260),
			blackFlashDuration = getDefinitionNumber(definition, "blackFlashDuration", 3),
			blackFlashClosestTransparency = getDefinitionNumber(definition, "blackFlashClosestTransparency", 0.3),
		})
		startTerrainColumn(player, definition, position, radius, bottomY)
		startDamageTicks(player, definition, sessionId, position, radius, topY, bottomY)
	end)
end

local function beginTargeting(context: ServerClientMessageContext)
	if not isReady(context) then
		reject(context.player, nil, "NotReady")
		return
	end

	nextSessionId += 1
	local sessionId = nextSessionId
	sessions[context.player] = {
		sessionId = sessionId,
		slot = context.slot,
		abilityId = context.abilityId,
	}

	fireToPlayer(context.player, BEGIN_TARGETING_EFFECT, {
		player = context.player,
		slot = context.slot,
		abilityId = context.abilityId,
		sessionId = sessionId,
		serverTime = context.now,
		strikeRadius = getDefinitionNumber(context.definition, "strikeRadius", 22),
		cameraHeight = getDefinitionNumber(context.definition, "cameraHeight", 110),
		targetFOV = getDefinitionNumber(context.definition, "targetFOV", 40),
	})
end

local function confirmTarget(context: ServerClientMessageContext)
	local payload = context.payload
	if typeof(payload) ~= "table" then
		reject(context.player, nil, "InvalidPayload")
		return
	end

	local sessionId = payload.sessionId
	local session = sessions[context.player]
	if typeof(sessionId) ~= "number" or not session or session.sessionId ~= sessionId then
		reject(context.player, if typeof(sessionId) == "number" then sessionId else nil, "InvalidSession")
		return
	end
	if session.slot ~= context.slot or session.abilityId ~= context.abilityId then
		reject(context.player, sessionId, "InvalidSession")
		return
	end
	if not isReady(context) then
		sessions[context.player] = nil
		reject(context.player, sessionId, "NotReady")
		return
	end

	local position, reason = validateTarget(payload)
	if not position then
		sessions[context.player] = nil
		reject(context.player, sessionId, reason or "InvalidTarget")
		return
	end
	if not setCooldownAndState(context, position) then
		sessions[context.player] = nil
		reject(context.player, sessionId, "CooldownFailed")
		return
	end

	local radius = getDefinitionNumber(context.definition, "strikeRadius", 22)
	local warningLifetime = math.max(
		getDefinitionNumber(context.definition, "warningLifetimeSeconds", 1.6),
		getDefinitionNumber(context.definition, "strikeDelay", 1.35)
	)
	spawnWarningPart(position, radius, warningLifetime)
	fireAll(TELEGRAPH_EFFECT, {
		player = context.player,
		slot = context.slot,
		abilityId = context.abilityId,
		sessionId = sessionId,
		position = position,
		radius = radius,
		strikeDelay = getDefinitionNumber(context.definition, "strikeDelay", 1.35),
		serverTime = context.now,
	})
	scheduleStrike(context.player, context.definition, sessionId, position)
end

local function cancelTargeting(context: ServerClientMessageContext)
	local payload = context.payload
	local sessionId = if typeof(payload) == "table" then payload.sessionId else nil
	local session = sessions[context.player]
	if not session then
		return
	end
	if typeof(sessionId) == "number" and session.sessionId ~= sessionId then
		return
	end

	sessions[context.player] = nil
	fireToPlayer(context.player, CANCELLED_EFFECT, {
		abilityId = context.abilityId,
		sessionId = session.sessionId,
	})
end

function OrbitalStrike.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function OrbitalStrike.CanActivate(_context: ServerActivateContext): boolean
	return false
end

function OrbitalStrike.OnClientMessage(context: ServerClientMessageContext)
	local payload = context.payload
	local action = if typeof(payload) == "table" and typeof(payload.action) == "string" then payload.action else ""

	if context.messageType == AbilityConfig.MessageTypes.Intent then
		if action == "BeginTargeting" then
			beginTargeting(context)
		elseif action == "ConfirmTarget" then
			confirmTarget(context)
		end
	elseif context.messageType == AbilityConfig.MessageTypes.Cancel then
		cancelTargeting(context)
	end
end

function OrbitalStrike.OnPlayerRemoving(player: Player)
	sessions[player] = nil
end

return OrbitalStrike
