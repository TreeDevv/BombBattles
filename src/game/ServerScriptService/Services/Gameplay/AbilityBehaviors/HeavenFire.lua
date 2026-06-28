local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local CombatMotionService = require(ServerScriptService.Services.CombatMotionService)
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

local HeavenFire = {} :: AbilityTypes.ServerBehavior

local ABILITY_ID = "HeavenFire"
local OBJECTS_FOLDER_NAME = "HeavenFireObjects"
local WARNING_FOLDER_NAME = "Warnings"
local EXPLOSION_ZONE_FOLDER_NAME = "ExplosionZones"
local TELEGRAPH_EFFECT = "HeavenFireTelegraph"
local IMPACT_EFFECT = "HeavenFireImpact"
local EXPLOSION_RESOLVED_EFFECT = "HeavenFireExplosionResolved"
local HIT_FLASH_EFFECT = "HeavenFireHitFlash"
local BEGIN_TARGETING_EFFECT = "HeavenFireBeginTargeting"
local REJECTED_EFFECT = "HeavenFireRejected"
local CANCELLED_EFFECT = "HeavenFireCancelled"
local TARGET_RAY_DISTANCE = 10000
local TARGET_HIT_TOLERANCE = 8
local KNOCKBACK_UNTIL_ATTR = "Bomb_KnockbackUntil"

local abilityService: AbilityServiceLike? = nil
local sessions: { [Player]: TargetSession } = {}
local nextSessionId = 0

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function readPositiveNumber(value: any, fallback: number): number
	return if typeof(value) == "number" and value == value and value > 0 then value else fallback
end

local function readOptionalPositiveNumber(value: any, fallback: number?): number?
	return if typeof(value) == "number" and value == value and value > 0 then value else fallback
end

local function readNonNegativeNumber(value: any, fallback: number): number
	return if typeof(value) == "number" and value == value and value >= 0 then value else fallback
end

local function clampMagnitude(vector: Vector3, maxMagnitude: number?): Vector3
	if not maxMagnitude or maxMagnitude <= 0 then
		return vector
	end

	local magnitude = vector.Magnitude
	if magnitude <= maxMagnitude or magnitude <= 0 then
		return vector
	end
	return vector.Unit * maxMagnitude
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
		abilityId = ABILITY_ID,
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

local function spawnWarningPart(player: Player, position: Vector3, radius: number, lifetime: number): BasePart
	local warning = Instance.new("Part")
	warning.Name = "HeavenFireWarning"
	warning.Anchored = true
	warning.CanCollide = false
	warning.CanTouch = false
	warning.CanQuery = false
	warning.Shape = Enum.PartType.Cylinder
	warning.Size = Vector3.new(0.08, radius * 2, radius * 2)
	warning.CFrame = CFrame.new(position + Vector3.yAxis * 0.08) * CFrame.Angles(0, 0, math.rad(90))
	warning.Color = Color3.fromRGB(255, 130, 55)
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

local function createExplosionZone(player: Player, position: Vector3, radius: number): BasePart
	local zone = Instance.new("Part")
	zone.Name = "HeavenFireExplosionZone"
	zone.Anchored = true
	zone.CanCollide = false
	zone.CanTouch = false
	zone.CanQuery = true
	zone.Transparency = 1
	zone.Shape = Enum.PartType.Ball
	zone.Size = Vector3.one * radius * 2
	zone.CFrame = CFrame.new(position)
	zone.Parent = getChildFolder(getObjectsFolder(player), EXPLOSION_ZONE_FOLDER_NAME)
	return zone
end

local function shouldSuppressAbilityDamage(result): boolean
	return typeof(result) == "table" and (result.kind == AbilityResult.Kind.Block or result.kind == AbilityResult.Kind.Absorb)
end

local function getFalloffDamage(definition: AbilityDefinition, distance: number): number
	local innerRadius = math.max(getDefinitionNumber(definition, "impactInnerRadius", 12), 0)
	local mediumRadius = math.max(getDefinitionNumber(definition, "impactMediumRadius", 24), innerRadius)
	local outerRadius = math.max(getDefinitionNumber(definition, "impactExplosionRadius", 32), mediumRadius)

	if distance <= innerRadius then
		return math.max(
			getDefinitionNumber(definition, "impactInnerDamage", getDefinitionNumber(definition, "totalPlayerDamage", 115)),
			0
		)
	elseif distance <= mediumRadius then
		return math.max(getDefinitionNumber(definition, "impactMediumDamage", 80), 0)
	elseif distance <= outerRadius then
		return math.max(getDefinitionNumber(definition, "impactOuterDamage", 40), 0)
	end
	return 0
end

local function getKnockbackConfig(definition: AbilityDefinition, radius: number)
	return {
		outerRadius = radius,
		knockbackHorizontal = getDefinitionNumber(definition, "impactKnockbackHorizontal", 130),
		knockbackVertical = getDefinitionNumber(definition, "impactKnockbackVertical", 80),
		knockbackMinScale = getDefinitionNumber(definition, "impactKnockbackMinScale", 0.25),
		maxKnockbackHorizontalSpeed = readOptionalPositiveNumber(
			definition.impactMaxKnockbackHorizontalSpeed,
			BombConfig.KnockbackMaxHorizontalSpeed
		),
		maxKnockbackVerticalSpeed = readOptionalPositiveNumber(
			definition.impactMaxKnockbackVerticalSpeed,
			BombConfig.KnockbackMaxVerticalSpeed
		),
		maxKnockbackAngularSpeed = readOptionalPositiveNumber(
			definition.impactMaxKnockbackAngularSpeed,
			BombConfig.KnockbackMaxAngularSpeed
		),
		movementSuppressSeconds = getDefinitionNumber(
			definition,
			"impactKnockbackMovementSuppressSeconds",
			BombConfig.KnockbackMovementSuppressSeconds
		),
	}
end

local function clampKnockbackVelocityDelta(rootPart: BasePart, velocityDelta: Vector3, knockbackConfig): Vector3
	local desiredVelocity = rootPart.AssemblyLinearVelocity + velocityDelta
	local maxHorizontalSpeed = readOptionalPositiveNumber(
		knockbackConfig.maxKnockbackHorizontalSpeed,
		BombConfig.KnockbackMaxHorizontalSpeed
	)
	local maxVerticalSpeed = readOptionalPositiveNumber(
		knockbackConfig.maxKnockbackVerticalSpeed,
		BombConfig.KnockbackMaxVerticalSpeed
	)

	local horizontal = clampMagnitude(Vector3.new(desiredVelocity.X, 0, desiredVelocity.Z), maxHorizontalSpeed)
	local vertical = desiredVelocity.Y
	if maxVerticalSpeed then
		vertical = math.min(vertical, maxVerticalSpeed)
	end

	return Vector3.new(horizontal.X, vertical, horizontal.Z) - rootPart.AssemblyLinearVelocity
end

local function markCharacterKnockback(character: Model?, suppressSeconds: number)
	if not character then
		return
	end

	local duration = math.max(suppressSeconds, 0)
	if duration <= 0 then
		return
	end

	local knockbackUntil = workspace:GetServerTimeNow() + duration
	character:SetAttribute(KNOCKBACK_UNTIL_ATTR, knockbackUntil)
	task.delay(duration + 0.1, function()
		if character.Parent and character:GetAttribute(KNOCKBACK_UNTIL_ATTR) == knockbackUntil then
			character:SetAttribute(KNOCKBACK_UNTIL_ATTR, nil)
		end
	end)
end

local function applyImpactKnockback(
	targetPlayer: Player?,
	character: Model?,
	rootPart: BasePart,
	origin: Vector3,
	distance: number,
	multiplier: number,
	knockbackConfig
)
	local horizontalAway = Vector3.new(rootPart.Position.X - origin.X, 0, rootPart.Position.Z - origin.Z)
	if horizontalAway.Magnitude < 0.05 then
		horizontalAway = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
	end
	if horizontalAway.Magnitude < 0.05 then
		horizontalAway = Vector3.xAxis
	else
		horizontalAway = horizontalAway.Unit
	end

	local outerRadius = readPositiveNumber(knockbackConfig.outerRadius, BombConfig.OuterRadius)
	local knockbackMinScale = readNonNegativeNumber(knockbackConfig.knockbackMinScale, BombConfig.KnockbackMinScale)
	local knockbackHorizontal = readNonNegativeNumber(knockbackConfig.knockbackHorizontal, BombConfig.KnockbackHorizontal)
	local knockbackVertical = readNonNegativeNumber(knockbackConfig.knockbackVertical, BombConfig.KnockbackVertical)
	local radiusAlpha = math.clamp(1 - distance / outerRadius, 0, 1)
	local scale = math.max(radiusAlpha, knockbackMinScale) * math.max(multiplier, 0)
	if scale <= 0 then
		return
	end

	local velocityDelta = Vector3.new(
		horizontalAway.X * knockbackHorizontal * scale,
		knockbackVertical * scale,
		horizontalAway.Z * knockbackHorizontal * scale
	)
	velocityDelta = clampKnockbackVelocityDelta(rootPart, velocityDelta, knockbackConfig)
	if velocityDelta.Magnitude > 0.001 then
		local maxAngularSpeed = readOptionalPositiveNumber(knockbackConfig.maxKnockbackAngularSpeed, BombConfig.KnockbackMaxAngularSpeed)
		if targetPlayer then
			CombatMotionService.SendImpulse(targetPlayer, character, velocityDelta, {
				sourceType = "Ability",
				sourceId = ABILITY_ID,
				movementSuppressSeconds = readNonNegativeNumber(
					knockbackConfig.movementSuppressSeconds,
					BombConfig.KnockbackMovementSuppressSeconds
				),
				maxAngularSpeed = maxAngularSpeed,
				maxHorizontalSpeed = knockbackConfig.maxKnockbackHorizontalSpeed,
				maxVerticalSpeed = knockbackConfig.maxKnockbackVerticalSpeed,
			})
		else
			rootPart:ApplyImpulse(velocityDelta * rootPart.AssemblyMass)
			if maxAngularSpeed then
				rootPart.AssemblyAngularVelocity = clampMagnitude(rootPart.AssemblyAngularVelocity, maxAngularSpeed)
			end
			markCharacterKnockback(
				character,
				readNonNegativeNumber(knockbackConfig.movementSuppressSeconds, BombConfig.KnockbackMovementSuppressSeconds)
			)
		end
	else
		markCharacterKnockback(character, readNonNegativeNumber(knockbackConfig.movementSuppressSeconds, BombConfig.KnockbackMovementSuppressSeconds))
	end
end

local function getDamageTargets(owner: Player, zone: BasePart, overlapParams: OverlapParams): { [Player]: { humanoid: Humanoid, rootPart: BasePart, character: Model } }
	local targets = {}
	local ok, parts = pcall(function()
		return workspace:GetPartsInPart(zone, overlapParams)
	end)
	if not ok then
		warn("[HeavenFire] Failed to query explosion overlaps: " .. tostring(parts))
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
	definition: AbilityDefinition,
	sessionId: number,
	hitFlashSent: { [Player]: boolean },
	hitFlashDuration: number,
	hitFlashTransparency: number
)
	local knockbackConfig = getKnockbackConfig(definition, radius)
	for target, targetInfo in pairs(getDamageTargets(owner, zone, overlapParams)) do
		local humanoid = targetInfo.humanoid
		local healthBefore = humanoid.Health
		if healthBefore <= 0 then
			continue
		end

		local distance = Vector3.new(targetInfo.rootPart.Position.X - origin.X, 0, targetInfo.rootPart.Position.Z - origin.Z).Magnitude
		local damage = getFalloffDamage(definition, distance)
		if damage <= 0 then
			continue
		end
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
					sourceId = ABILITY_ID,
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

		if typeof(hookResult) ~= "table" or hookResult.skipDamage ~= true then
			if resolvedDamage > 0 then
				RoundService:RecordPlayerDamage(owner, target, math.min(resolvedDamage, healthBefore), {
					sourceType = "Ability",
					sourceId = ABILITY_ID,
				})
				humanoid:TakeDamage(resolvedDamage)
				if humanoid.Health < healthBefore and not hitFlashSent[target] then
					hitFlashSent[target] = true
					fireToPlayer(target, HIT_FLASH_EFFECT, {
						abilityId = ABILITY_ID,
						sessionId = sessionId,
						durationSeconds = hitFlashDuration,
						initialTransparency = hitFlashTransparency,
					})
				end
			end
		end

		if typeof(hookResult) ~= "table" or hookResult.skipKnockback ~= true then
			local knockbackMultiplier = if typeof(hookResult) == "table" and typeof(hookResult.knockbackMultiplier) == "number"
				then math.max(hookResult.knockbackMultiplier, 0)
				else 1
			applyImpactKnockback(
				target,
				targetInfo.character,
				targetInfo.rootPart,
				origin,
				distance,
				knockbackMultiplier,
				knockbackConfig
			)
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

local function isPositionInsideExplosion(position: Vector3, origin: Vector3, radius: number): boolean
	return (position - origin).Magnitude <= radius
end

local function damageCores(owner: Player, origin: Vector3, radius: number, damage: number)
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
		if not position or not isPositionInsideExplosion(position, origin, radius) then
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
					sourceId = ABILITY_ID,
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
				sourceId = ABILITY_ID,
			})
		end
	end
end

local function applyExplosionDamage(player: Player, definition: AbilityDefinition, sessionId: number, position: Vector3, radius: number)
	local coreDamage = math.max(getDefinitionNumber(definition, "totalCoreDamage", 0), 0)
	local hitFlashDuration = math.max(getDefinitionNumber(definition, "blackFlashHitDuration", 3), 0.1)
	local hitFlashTransparency = math.clamp(getDefinitionNumber(definition, "blackFlashClosestTransparency", 0.3), 0, 1)
	local hitFlashSent: { [Player]: boolean } = {}

	local zone = createExplosionZone(player, position, radius)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { zone }

	damagePlayers(
		player,
		zone,
		overlapParams,
		position,
		radius,
		definition,
		sessionId,
		hitFlashSent,
		hitFlashDuration,
		hitFlashTransparency
	)
	damageCores(player, position, radius, coreDamage)
	if zone.Parent then
		zone:Destroy()
	end
end

local function applyTerrainExplosion(player: Player, definition: AbilityDefinition, position: Vector3, radius: number)
	local sourceContext = {
		sourceType = "Ability",
		sourceId = ABILITY_ID,
		ownerUserId = player.UserId,
		timestamp = workspace:GetServerTimeNow(),
	}
	local transparentCollisionClearance =
		math.max(getDefinitionNumber(definition, "terrainTransparentCollisionClearance", 0), 0)
	local maxTargetsPerExplosion = getDefinitionNumber(definition, "impactExplosionMaxTargets", 72)

	local debrisPayloads = DestructionService:DestroySphere(position, radius, sourceContext, {
		forceSubtract = true,
		transparentCollisionClearance = transparentCollisionClearance,
		maxTargetsPerExplosion = maxTargetsPerExplosion,
	})
	return if typeof(debrisPayloads) == "table" then debrisPayloads else {}
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

		local radius = getDefinitionNumber(definition, "impactExplosionRadius", 32)
		local explosionDelay = math.max(getDefinitionNumber(definition, "impactExplosionDelaySeconds", 3.4), 0)
		fireAll(IMPACT_EFFECT, {
			player = player,
			abilityId = ABILITY_ID,
			sessionId = sessionId,
			position = position,
			radius = radius,
			explosionDelaySeconds = explosionDelay,
			terrainExplosionRadius = radius,
			blackFlashRadius = getDefinitionNumber(definition, "blackFlashRadius", 260),
			blackFlashDuration = getDefinitionNumber(definition, "blackFlashDuration", 3),
			blackFlashClosestTransparency = getDefinitionNumber(definition, "blackFlashClosestTransparency", 0.3),
		})
		task.wait(explosionDelay)
		if player.Parent ~= Players or not CombatEligibility.IsCombatActive(player, RoundService) then
			return
		end
		local debrisPayloads = applyTerrainExplosion(player, definition, position, radius)
		applyExplosionDamage(player, definition, sessionId, position, radius)
		fireAll(EXPLOSION_RESOLVED_EFFECT, {
			player = player,
			abilityId = ABILITY_ID,
			sessionId = sessionId,
			position = position,
			radius = radius,
			terrainRadius = radius,
			terrainExplosionRadius = radius,
			debrisPayloads = if #debrisPayloads > 0 then debrisPayloads else nil,
			blackFlashRadius = getDefinitionNumber(definition, "blackFlashRadius", 260),
			blackFlashDuration = getDefinitionNumber(definition, "blackFlashDuration", 3),
			blackFlashClosestTransparency = getDefinitionNumber(definition, "blackFlashClosestTransparency", 0.3),
		})
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
		strikeRadius = getDefinitionNumber(context.definition, "impactExplosionRadius", 32),
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

	local radius = getDefinitionNumber(context.definition, "impactExplosionRadius", 32)
	local warningLifetime = math.max(
		getDefinitionNumber(context.definition, "warningLifetimeSeconds", 1.6),
		getDefinitionNumber(context.definition, "strikeDelay", 1.35)
			+ getDefinitionNumber(context.definition, "impactExplosionDelaySeconds", 3.4)
	)
	spawnWarningPart(context.player, position, radius, warningLifetime)
	fireAll(TELEGRAPH_EFFECT, {
		player = context.player,
		slot = context.slot,
		abilityId = context.abilityId,
		sessionId = sessionId,
		position = position,
		radius = radius,
		strikeDelay = getDefinitionNumber(context.definition, "strikeDelay", 1.35)
			+ getDefinitionNumber(context.definition, "impactExplosionDelaySeconds", 3.4),
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

function HeavenFire.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function HeavenFire.CanActivate(_context: ServerActivateContext): boolean
	return false
end

function HeavenFire.OnClientMessage(context: ServerClientMessageContext)
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

function HeavenFire.OnPlayerRemoving(player: Player)
	sessions[player] = nil
end

return HeavenFire
