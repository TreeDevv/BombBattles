local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityBehaviorServices = require(ServerScriptService.Services.AbilityBehaviorServices)

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombThrowOrigin = require(ReplicatedStorage.Shared.Common.BombThrowOrigin)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerClientMessageContext = AbilityTypes.ServerClientMessageContext

type ChargeRecord = {
	slot: string,
	abilityId: string,
	definition: AbilityDefinition,
	startedAt: number,
	health: number,
	humanoid: Humanoid?,
	healthConnection: RBXScriptConnection?,
}

local ChargeBomb = {} :: AbilityTypes.ServerBehavior

local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5
local CHARGE_RECORDS: { [Player]: ChargeRecord } = {}
local projectileSerial = 0
local abilityService: AbilityServiceLike? = nil

local function getBombProjectileService()
	return AbilityBehaviorServices.GetBombProjectileService()
end

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getCharacterParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart and not rootPart:IsA("BasePart") then
		rootPart = nil
	end
	return character, humanoid, rootPart
end

local function getCharacterRoot(player: Player): BasePart?
	local _, humanoid, rootPart = getCharacterParts(player)
	if humanoid and humanoid.Health > 0 and rootPart then
		return rootPart
	end
	return nil
end

local function getThrowOrigin(rootPart: BasePart): Vector3
	return BombThrowOrigin.GetOrigin(rootPart)
end

local function getHorizontalDirection(direction: any): Vector3?
	if typeof(direction) ~= "Vector3" then
		return nil
	end

	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	if horizontal.Magnitude <= MIN_AIM_HORIZONTAL then
		return nil
	end

	return horizontal.Unit
end

local function sanitizeAimDirection(direction: any, fallback: Vector3): Vector3
	local fallbackHorizontal = getHorizontalDirection(fallback) or Vector3.zAxis
	if typeof(direction) ~= "Vector3" then
		return fallbackHorizontal
	end
	if direction.X ~= direction.X or direction.Y ~= direction.Y or direction.Z ~= direction.Z then
		return fallbackHorizontal
	end
	if direction.Magnitude < 0.05 or direction.Magnitude > MAX_AIM_MAGNITUDE then
		return fallbackHorizontal
	end

	local unit = direction.Unit
	local horizontal = getHorizontalDirection(unit)
	if not horizontal then
		horizontal = fallbackHorizontal
		unit = Vector3.new(horizontal.X, unit.Y, horizontal.Z)
	end

	unit = Vector3.new(unit.X, math.clamp(unit.Y, BombConfig.MinAimY, BombConfig.MaxAimY), unit.Z)
	if unit.Magnitude < 0.05 then
		return Vector3.new(fallbackHorizontal.X, 0.15, fallbackHorizontal.Z).Unit
	end

	return unit.Unit
end

local function getAimDirectionFromPayload(payload: any, fallbackDirection: Vector3): Vector3
	if typeof(payload) == "table" then
		return sanitizeAimDirection(payload.aimDirection, fallbackDirection)
	end
	return sanitizeAimDirection(fallbackDirection, Vector3.zAxis)
end

local function lerpNumber(fromValue: number, toValue: number, alpha: number): number
	return fromValue + ((toValue - fromValue) * alpha)
end

local function getChargeAlpha(record: ChargeRecord, currentTime: number): number
	local fullChargeSeconds = math.max(getDefinitionNumber(record.definition, "fullChargeSeconds", 5), 0.05)
	return math.clamp((currentTime - record.startedAt) / fullChargeSeconds, 0, 1)
end

local function getChargeScale(definition: AbilityDefinition, chargeAlpha: number): number
	return lerpNumber(
		getDefinitionNumber(definition, "minChargeScale", 1),
		getDefinitionNumber(definition, "maxChargeScale", 2.5),
		chargeAlpha
	)
end

local function createProjectileId(player: Player): string
	projectileSerial += 1
	return ("ChargeBomb_%d_%d_%04d"):format(player.UserId, math.floor(workspace:GetServerTimeNow() * 1000), projectileSerial % 10000)
end

local function disconnectRecord(record: ChargeRecord?)
	if record and record.healthConnection then
		record.healthConnection:Disconnect()
		record.healthConnection = nil
	end
end

local function getSlotState(player: Player, slot: string)
	local service = abilityService
	local state = service and service:GetPlayerState(player)
	local slots = state and state.slots
	return if typeof(slots) == "table" then slots[slot] else nil
end

local function setCooldownForCancel(player: Player, record: ChargeRecord, currentTime: number, reason: string)
	local service = abilityService
	if not service then
		return
	end

	local slotState = getSlotState(player, record.slot)
	local state = if typeof(slotState) == "table" and typeof(slotState.state) == "table" then slotState.state else {}
	local chargeCancels = if typeof(state.chargeCancels) == "number" then state.chargeCancels else 0
	local cooldownSeconds = math.max(getDefinitionNumber(record.definition, "cooldownSeconds", 10), 0)

	service:SetSlotValues(player, record.slot, {
		cooldownEndsAt = currentTime + cooldownSeconds,
		activeEndsAt = 0,
		state = {
			throws = if typeof(state.throws) == "number" then state.throws else 0,
			chargeCancels = chargeCancels + 1,
			lastActivatedAt = if typeof(state.lastActivatedAt) == "number" then state.lastActivatedAt else 0,
			lastCancelledAt = currentTime,
			lastCancelReason = reason,
			lastChargeScale = if typeof(state.lastChargeScale) == "number" then state.lastChargeScale else 1,
			lastChargeAlpha = if typeof(state.lastChargeAlpha) == "number" then state.lastChargeAlpha else 0,
		},
	})
	service:FireEffect("ChargeBombCancelled", {
		player = player,
		slot = record.slot,
		abilityId = record.abilityId,
		reason = reason,
	})
end

local function cancelCharge(player: Player, reason: string, spendCooldown: boolean)
	local record = CHARGE_RECORDS[player]
	CHARGE_RECORDS[player] = nil
	disconnectRecord(record)
	if record and spendCooldown then
		setCooldownForCancel(player, record, workspace:GetServerTimeNow(), reason)
	end
end

local function bindDamageCancel(player: Player, record: ChargeRecord)
	local humanoid = record.humanoid
	if not humanoid then
		return
	end

	record.healthConnection = humanoid.HealthChanged:Connect(function(nextHealth)
		if CHARGE_RECORDS[player] ~= record then
			return
		end
		if nextHealth < record.health then
			cancelCharge(player, "Damaged", true)
			return
		end
		record.health = nextHealth
	end)
end

local function buildExplosionConfig(definition: AbilityDefinition, scale: number)
	return {
		chargeScale = scale,
		innerRadius = BombConfig.InnerRadius * scale,
		nearRadius = BombConfig.NearRadius * scale,
		outerRadius = BombConfig.OuterRadius * scale,
		terrainRadius = (BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius) * scale,
		maxTargetsPerExplosion = getDefinitionNumber(definition, "maxTargetsPerExplosion", 72),
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
	}
end

function ChargeBomb.CanActivate(context: ServerActivateContext): boolean
	return CHARGE_RECORDS[context.player] ~= nil and getCharacterRoot(context.player) ~= nil and getBombProjectileService() ~= nil
end

function ChargeBomb.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local projectileService = getBombProjectileService()
	local rootPart = getCharacterRoot(context.player)
	local record = CHARGE_RECORDS[context.player]
	CHARGE_RECORDS[context.player] = nil
	disconnectRecord(record)
	if not (projectileService and rootPart and record) then
		return false
	end

	local chargeAlpha = getChargeAlpha(record, context.now)
	local chargeScale = getChargeScale(context.definition, chargeAlpha)
	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(context.payload, rootPart.CFrame.LookVector)
	local projectileId = createProjectileId(context.player)
	local skinId = BombSkinService:GetEquippedSkinId(context.player)

	local launched = projectileService:Launch({
		owner = context.player,
		projectileId = projectileId,
		bombType = BombProjectileConfig.BombType.Normal,
		skinId = skinId,
		origin = origin,
		aimDirection = aimDirection,
		fuseStartedAt = context.now,
		launchedAt = context.now,
		remainingFuse = BombConfig.FuseSeconds,
		modifier = {
			physics = {
				radius = BombConfig.SweepRadius * chargeScale,
			},
			explosion = buildExplosionConfig(context.definition, chargeScale),
			visuals = {
				visualScale = BombConfig.ProjectileVisualScale * chargeScale,
				chargeScale = chargeScale,
			},
		},
	})
	if not launched then
		return false
	end

	local state = context.slotState.state
	local throws = if typeof(state) == "table" and typeof(state.throws) == "number" then state.throws else 0
	local chargeCancels = if typeof(state) == "table" and typeof(state.chargeCancels) == "number" then state.chargeCancels else 0

	return {
		state = {
			throws = throws + 1,
			chargeCancels = chargeCancels,
			lastActivatedAt = context.now,
			lastCancelledAt = if typeof(state) == "table" and typeof(state.lastCancelledAt) == "number" then state.lastCancelledAt else 0,
			lastChargeScale = chargeScale,
			lastChargeAlpha = chargeAlpha,
		},
		effect = {
			name = "ChargeBombFired",
			payload = {
				projectileId = projectileId,
				chargeAlpha = chargeAlpha,
				chargeScale = chargeScale,
			},
		},
	}
end

function ChargeBomb.OnClientMessage(context: ServerClientMessageContext)
	local payload = context.payload
	if context.messageType ~= AbilityConfig.MessageTypes.Intent or typeof(payload) ~= "table" then
		return
	end

	local phase = payload.phase
	if phase == "BeginCharge" then
		local cooldownEndsAt = if typeof(context.slotState.cooldownEndsAt) == "number" then context.slotState.cooldownEndsAt else 0
		if cooldownEndsAt > context.now then
			return
		end
		local _, humanoid, rootPart = getCharacterParts(context.player)
		if not (humanoid and humanoid.Health > 0 and rootPart) then
			return
		end

		cancelCharge(context.player, "Restarted", false)
		local record: ChargeRecord = {
			slot = context.slot,
			abilityId = context.abilityId,
			definition = context.definition,
			startedAt = context.now,
			health = humanoid.Health,
			humanoid = humanoid,
			healthConnection = nil,
		}
		CHARGE_RECORDS[context.player] = record
		bindDamageCancel(context.player, record)
	elseif phase == "CancelCharge" then
		cancelCharge(context.player, "Cancelled", false)
	end
end

function ChargeBomb.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function ChargeBomb.OnPlayerRemoving(player: Player)
	cancelCharge(player, "PlayerRemoving", false)
end

return ChargeBomb
