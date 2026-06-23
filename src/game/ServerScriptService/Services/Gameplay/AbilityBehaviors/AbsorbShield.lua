local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityHookResult = AbilityTypes.AbilityHookResult
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext
type ActiveRecord = {
	character: Model,
	rootPart: BasePart,
	humanoid: Humanoid,
	slot: string,
	activeEndsAt: number,
	serial: number,
	deathConnection: RBXScriptConnection?,
}
type EmpowerRecord = {
	character: Model,
	slot: string,
	expiresAt: number,
	serial: number,
	deathConnection: RBXScriptConnection?,
}

local AbsorbShield = {} :: AbilityTypes.ServerBehavior

local ABILITY_ID = "AbsorbShield"
local ROUND_TEAM_ATTR = "RoundTeam"
local RESULT_KIND = AbilityResult.Kind
local ACTIVE_RECORDS: { [Player]: ActiveRecord } = {}
local EMPOWER_RECORDS: { [Player]: EmpowerRecord } = {}
local SERIALS: { [Player]: number } = {}
local abilityService: AbilityServiceLike? = nil

local function getByPath(root: Instance, path: { string }): Instance?
	local current: Instance? = root
	for _, name in ipairs(path) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getTemplate(definition: AbilityDefinition?): Instance?
	local path = definition and definition.assetPath
	if typeof(path) ~= "table" then
		return nil
	end

	local template = getByPath(ReplicatedStorage, path)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

local function getCharacterParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return character, humanoid, rootPart
	end
	return character, humanoid, nil
end

local function getRadius(definition: AbilityDefinition?): number
	return math.max(tonumber(definition and definition.radius) or 4.25, 0.5)
end

local function getScale(definition: AbilityDefinition?): number
	return math.max(tonumber(definition and definition.empoweredBombScale) or 1.5, 0.05)
end

local function copyState(state: any): { [string]: any }
	local nextState = {}
	if typeof(state) == "table" then
		for key, value in pairs(state) do
			nextState[key] = value
		end
	end
	return nextState
end

local function getSlotState(player: Player, slot: string)
	local service = abilityService
	local abilityState = service and service:GetPlayerState(player)
	local slots = abilityState and abilityState.slots
	return if typeof(slots) == "table" then slots[slot] else nil
end

local function setSlotRuntimeState(player: Player, slot: string, activeEndsAt: number, state: { [string]: any })
	local service = abilityService
	if not service then
		return
	end

	local slotState = getSlotState(player, slot)
	if not (typeof(slotState) == "table" and slotState.abilityId == ABILITY_ID) then
		return
	end

	service:SetSlotValues(player, slot, {
		cooldownEndsAt = if typeof(slotState.cooldownEndsAt) == "number" then slotState.cooldownEndsAt else 0,
		activeEndsAt = activeEndsAt,
		state = state,
	})
end

local function fireEffect(effectName: string, payload: any?)
	local service = abilityService
	if service then
		service:FireEffect(effectName, payload)
	end
end

local function getOwnerTeamName(owner: any): string?
	if typeof(owner) == "Instance" and owner:IsA("Player") then
		local teamName = owner:GetAttribute(ROUND_TEAM_ATTR)
		return if typeof(teamName) == "string" and teamName ~= "" then teamName else nil
	end
	if typeof(owner) == "table" and typeof(owner.teamName) == "string" and owner.teamName ~= "" then
		return owner.teamName
	end
	return nil
end

local function isEnemyOwner(owner: any, player: Player): boolean
	if owner == player then
		return false
	end
	if typeof(owner) ~= "Instance" and typeof(owner) ~= "table" then
		return false
	end

	local ownerTeam = getOwnerTeamName(owner)
	local playerTeam = getOwnerTeamName(player)
	if ownerTeam and playerTeam and ownerTeam == playerTeam then
		return false
	end

	return true
end

local function closestPointOnSegment(fromPosition: Vector3, toPosition: Vector3, point: Vector3): Vector3
	local segment = toPosition - fromPosition
	local lengthSquared = segment:Dot(segment)
	if lengthSquared <= 0.0001 then
		return fromPosition
	end

	local alpha = math.clamp((point - fromPosition):Dot(segment) / lengthSquared, 0, 1)
	return fromPosition + segment * alpha
end

local function disconnectActive(player: Player): ActiveRecord?
	local record = ACTIVE_RECORDS[player]
	ACTIVE_RECORDS[player] = nil
	if record and record.deathConnection then
		record.deathConnection:Disconnect()
		record.deathConnection = nil
	end
	return record
end

local function disconnectEmpower(player: Player): EmpowerRecord?
	local record = EMPOWER_RECORDS[player]
	EMPOWER_RECORDS[player] = nil
	if record and record.deathConnection then
		record.deathConnection:Disconnect()
		record.deathConnection = nil
	end
	return record
end

local function clearEmpower(player: Player, reason: string, consumedAt: number?, projectileId: string?)
	local record = disconnectEmpower(player)
	if not record then
		return
	end

	local slotState = getSlotState(player, record.slot)
	local state = copyState(slotState and slotState.state)
	state.empowered = false
	state.lastClearedAt = workspace:GetServerTimeNow()
	if consumedAt then
		state.empoweredBombsThrown = (tonumber(state.empoweredBombsThrown) or 0) + 1
		state.lastEmpoweredAt = consumedAt
	end

	local active = ACTIVE_RECORDS[player]
	local activeEndsAt = if active then active.activeEndsAt else 0
	setSlotRuntimeState(player, record.slot, activeEndsAt, state)

	fireEffect(if consumedAt then "AbsorbShieldEmpowerConsumed" else "AbsorbShieldEmpowerCleared", {
		player = player,
		slot = record.slot,
		abilityId = ABILITY_ID,
		reason = reason,
		projectileId = projectileId,
	})
end

local function getEmpowerRecord(player: Player, currentTime: number): EmpowerRecord?
	local record = EMPOWER_RECORDS[player]
	if not record then
		return nil
	end
	if currentTime >= record.expiresAt then
		clearEmpower(player, "Expired", nil, nil)
		return nil
	end
	if player.Character ~= record.character then
		clearEmpower(player, "CharacterChanged", nil, nil)
		return nil
	end
	return EMPOWER_RECORDS[player]
end

local function grantEmpower(context: ServerHookContext, absorbPosition: Vector3, absorbSource: string, projectileId: string?)
	disconnectEmpower(context.player)

	local character = context.player.Character
	if not (character and character:IsA("Model")) then
		return
	end

	local serial = (SERIALS[context.player] or 0) + 1
	SERIALS[context.player] = serial
	local empowerDurationSeconds = math.max(tonumber(context.definition.empowerDurationSeconds) or 180, 1)
	local expiresAt = context.now + empowerDurationSeconds
	local record: EmpowerRecord = {
		character = character,
		slot = context.slot,
		expiresAt = expiresAt,
		serial = serial,
		deathConnection = nil,
	}
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		record.deathConnection = humanoid.Died:Connect(function()
			local current = EMPOWER_RECORDS[context.player]
			if current and current.serial == serial then
				clearEmpower(context.player, "Death", nil, nil)
			end
		end)
	end
	EMPOWER_RECORDS[context.player] = record

	local state = copyState(context.slotState.state)
	state.empowered = true
	state.absorbs = (tonumber(state.absorbs) or 0) + 1
	state.lastAbsorbedAt = context.now
	state.lastAbsorbSource = absorbSource
	setSlotRuntimeState(context.player, context.slot, expiresAt, state)

	task.delay(empowerDurationSeconds + 0.05, function()
		local current = EMPOWER_RECORDS[context.player]
		if current and current.serial == serial then
			clearEmpower(context.player, "Expired", nil, nil)
		end
	end)

	fireEffect("AbsorbShieldAbsorbed", {
		player = context.player,
		slot = context.slot,
		abilityId = ABILITY_ID,
		position = absorbPosition,
		source = absorbSource,
		projectileId = projectileId,
	})
end

local function consumeShield(context: ServerHookContext, absorbPosition: Vector3, absorbSource: string, projectileId: string?)
	disconnectActive(context.player)
	grantEmpower(context, absorbPosition, absorbSource, projectileId)
end

local function getActiveRecord(player: Player, currentTime: number): ActiveRecord?
	local record = ACTIVE_RECORDS[player]
	if not record then
		return nil
	end
	if currentTime >= record.activeEndsAt then
		disconnectActive(player)
		return nil
	end

	local character, humanoid, rootPart = getCharacterParts(player)
	if character ~= record.character or humanoid ~= record.humanoid or rootPart ~= record.rootPart then
		disconnectActive(player)
		return nil
	end

	return record
end

local function buildExplosionConfig(definition: AbilityDefinition?, scale: number)
	return {
		innerRadius = BombConfig.InnerRadius * scale,
		nearRadius = BombConfig.NearRadius * scale,
		outerRadius = BombConfig.OuterRadius * scale,
		terrainRadius = (BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius) * scale,
		maxTargetsPerExplosion = getDefinitionNumber(definition, "empoweredMaxTargetsPerExplosion", 72),
		playerDirectDamage = BombConfig.PlayerDirectDamage * scale,
		playerNearDamageMax = BombConfig.PlayerNearDamageMax * scale,
		playerNearDamageMin = BombConfig.PlayerNearDamageMin * scale,
		playerOuterDamageMax = BombConfig.PlayerOuterDamageMax * scale,
		playerOuterDamageMin = BombConfig.PlayerOuterDamageMin * scale,
		anchorDirectDamage = BombConfig.AnchorDirectDamage * scale,
		anchorNearDamageMax = BombConfig.AnchorNearDamageMax * scale,
		anchorNearDamageMin = BombConfig.AnchorNearDamageMin * scale,
		anchorOuterDamageMax = BombConfig.AnchorOuterDamageMax * scale,
		anchorOuterDamageMin = BombConfig.AnchorOuterDamageMin * scale,
		knockbackHorizontal = BombConfig.KnockbackHorizontal * scale,
		knockbackVertical = BombConfig.KnockbackVertical * scale,
		knockbackMinScale = BombConfig.KnockbackMinScale,
		explosionVisualScale = scale,
		chargeScale = scale,
	}
end

function AbsorbShield.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function AbsorbShield.CanActivate(context: ServerActivateContext): boolean
	local _character, _humanoid, rootPart = getCharacterParts(context.player)
	return getActiveRecord(context.player, context.now) == nil
		and getEmpowerRecord(context.player, context.now) == nil
		and rootPart ~= nil
		and getTemplate(context.definition) ~= nil
end

function AbsorbShield.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local character, humanoid, rootPart = getCharacterParts(context.player)
	if not (character and humanoid and rootPart) then
		return false
	end

	disconnectActive(context.player)
	local serial = (SERIALS[context.player] or 0) + 1
	SERIALS[context.player] = serial
	local durationSeconds = math.max(tonumber(context.definition.durationSeconds) or 0, 0)
	local activeEndsAt = context.now + durationSeconds
	local record: ActiveRecord = {
		character = character,
		rootPart = rootPart,
		humanoid = humanoid,
		slot = context.slot,
		activeEndsAt = activeEndsAt,
		serial = serial,
		deathConnection = nil,
	}
	record.deathConnection = humanoid.Died:Connect(function()
		local current = ACTIVE_RECORDS[context.player]
		if current and current.serial == serial then
			disconnectActive(context.player)
		end
	end)
	ACTIVE_RECORDS[context.player] = record

	task.delay(durationSeconds + 0.05, function()
		local current = ACTIVE_RECORDS[context.player]
		if current and current.serial == serial then
			disconnectActive(context.player)
			fireEffect("AbsorbShieldExpired", {
				player = context.player,
				slot = context.slot,
				abilityId = ABILITY_ID,
			})
		end
	end)

	local state = copyState(context.slotState.state)
	state.activationCount = (tonumber(state.activationCount) or 0) + 1
	state.lastActivatedAt = context.now
	state.empowered = false

	return {
		state = state,
	}
end

function AbsorbShield.OnProjectileStep(context: ServerHookContext): AbilityHookResult
	local record = getActiveRecord(context.player, context.now)
	local payload = context.context
	if not (record and typeof(payload) == "table" and typeof(payload.projectileId) == "string") then
		return AbilityResult.Continue()
	end
	if not isEnemyOwner(payload.owner, context.player) then
		return AbilityResult.Continue()
	end

	local position = if typeof(payload.position) == "Vector3" then payload.position else record.rootPart.Position
	local nextPosition = if typeof(payload.nextPosition) == "Vector3" then payload.nextPosition else position
	local closest = closestPointOnSegment(position, nextPosition, record.rootPart.Position)
	local sweepRadius = math.max(tonumber(payload.sweepRadius) or BombConfig.SweepRadius or 0, 0)
	if (closest - record.rootPart.Position).Magnitude > getRadius(context.definition) + sweepRadius then
		return AbilityResult.Continue()
	end

	consumeShield(context, closest, "Projectile", payload.projectileId)
	return {
		kind = RESULT_KIND.Absorb,
		skipDamage = true,
		skipKnockback = true,
		suppressDefaultExplosionVfx = true,
	}
end

function AbsorbShield.OnBeforeExplosion(context: ServerHookContext): AbilityHookResult
	local record = getActiveRecord(context.player, context.now)
	local payload = context.context
	if not (record and typeof(payload) == "table" and typeof(payload.position) == "Vector3") then
		return AbilityResult.Continue()
	end
	if not isEnemyOwner(payload.owner, context.player) then
		return AbilityResult.Continue()
	end

	local explosionRadius = math.max(tonumber(payload.outerRadius) or 0, 0)
	if (payload.position - record.rootPart.Position).Magnitude > getRadius(context.definition) + explosionRadius then
		return AbilityResult.Continue()
	end

	local projectileId = if typeof(payload.projectileId) == "string" then payload.projectileId else nil
	consumeShield(context, payload.position, "Explosion", projectileId)
	return {
		kind = RESULT_KIND.Absorb,
		skipDamage = true,
		skipKnockback = true,
		suppressDefaultExplosionVfx = true,
	}
end

function AbsorbShield.OnBeforeProjectileLaunch(context: ServerHookContext): AbilityHookResult
	local record = getEmpowerRecord(context.player, context.now)
	local payload = context.context
	if not (record and typeof(payload) == "table" and payload.owner == context.player) then
		return AbilityResult.Continue()
	end
	if payload.sourceType ~= "Bomb" then
		return AbilityResult.Continue()
	end
	if typeof(payload.bombType) == "string" and payload.bombType ~= BombProjectileConfig.BombType.Normal then
		return AbilityResult.Continue()
	end

	local scale = getScale(context.definition)
	local projectileId = if typeof(payload.projectileId) == "string" then payload.projectileId else nil
	clearEmpower(context.player, "Consumed", context.now, projectileId)

	local physics = payload.physics
	local baseRadius = if typeof(physics) == "table" and typeof(physics.radius) == "number"
		then physics.radius
		else BombConfig.SweepRadius

	return {
		kind = RESULT_KIND.ModifyProjectileLaunch,
		physics = {
			radius = math.max(baseRadius * scale, 0.1),
		},
			explosion = buildExplosionConfig(context.definition, scale),
		visuals = {
			visualScale = BombConfig.ProjectileVisualScale * scale,
			chargeScale = scale,
			absorbShieldEmpowered = true,
		},
	}
end

function AbsorbShield.OnPlayerRemoving(player: Player)
	disconnectActive(player)
	disconnectEmpower(player)
	SERIALS[player] = nil
end

return AbsorbShield
