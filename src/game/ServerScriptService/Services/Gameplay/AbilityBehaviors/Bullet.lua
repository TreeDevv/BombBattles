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
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerClientMessageContext = AbilityTypes.ServerClientMessageContext

type ChargeRecord = {
	startedAt: number,
	slot: string,
	abilityId: string,
	character: Model,
}

local Bullet = {} :: AbilityTypes.ServerBehavior

local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5
local CHARGE_RECORDS: { [Player]: ChargeRecord } = {}
local projectileSerial = 0

local function getBombProjectileService()
	return AbilityBehaviorServices.GetBombProjectileService()
end

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
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

local function getThrowOrigin(rootPart: BasePart): Vector3
	return BombThrowOrigin.GetOrigin(rootPart)
end

local function getAimDirectionFromPayload(payload: any, fallbackDirection: Vector3): Vector3
	if typeof(payload) == "table" then
		return sanitizeAimDirection(payload.aimDirection, fallbackDirection)
	end
	return sanitizeAimDirection(fallbackDirection, Vector3.zAxis)
end

local function getChargeAlpha(
	player: Player,
	definition: AbilityDefinition,
	currentTime: number,
	slot: string,
	abilityId: string,
	character: Model
): number
	local record = CHARGE_RECORDS[player]
	CHARGE_RECORDS[player] = nil
	if not record then
		return 0
	end
	if record.slot ~= slot or record.abilityId ~= abilityId or record.character ~= character then
		return 0
	end

	local fullChargeSeconds = math.max(getDefinitionNumber(definition, "fullChargeSeconds", 1.75), 0.05)
	return math.clamp((currentTime - record.startedAt) / fullChargeSeconds, 0, 1)
end

local function createProjectileId(player: Player): string
	projectileSerial += 1
	return ("BulletBomb_%d_%d_%04d"):format(player.UserId, math.floor(workspace:GetServerTimeNow() * 1000), projectileSerial % 10000)
end

local function lerpNumber(fromValue: number, toValue: number, alpha: number): number
	return fromValue + ((toValue - fromValue) * alpha)
end

function Bullet.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getBombProjectileService() ~= nil
end

function Bullet.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local projectileService = getBombProjectileService()
	local rootPart = getCharacterRoot(context.player)
	if not (projectileService and rootPart) then
		return false
	end

	local character = rootPart:FindFirstAncestorOfClass("Model")
	local chargeAlpha = if character
		then getChargeAlpha(context.player, context.definition, context.now, context.slot, context.abilityId, character)
		else 0
	local launchSpeed = lerpNumber(
		getDefinitionNumber(context.definition, "minLaunchSpeed", 150),
		getDefinitionNumber(context.definition, "maxLaunchSpeed", 320),
		chargeAlpha
	)
	local gravityScale = lerpNumber(
		getDefinitionNumber(context.definition, "maxGravityScale", BombConfig.ProjectileGravityScale),
		getDefinitionNumber(context.definition, "minGravityScale", 0),
		chargeAlpha
	)
	local upwardVelocity = lerpNumber(
		getDefinitionNumber(context.definition, "maxUpwardVelocity", BombConfig.ProjectileUpwardVelocity),
		getDefinitionNumber(context.definition, "minUpwardVelocity", 0),
		chargeAlpha
	)

	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(context.payload, rootPart.CFrame.LookVector)
	local projectileId = AbilityBehaviorServices.GetClientProjectileId(context) or createProjectileId(context.player)
	local skinId = BombSkinService:GetEquippedSkinId(context.player)
	local maxRange = math.max(getDefinitionNumber(context.definition, "maxRange", 450), 0)
	local remainingFuse = math.max(getDefinitionNumber(context.definition, "maxFlightSeconds", BombConfig.FuseSeconds), 0.05)

	local launched = projectileService:Launch({
		owner = context.player,
		projectileId = projectileId,
		bombType = BombProjectileConfig.BombType.Normal,
		skinId = skinId,
		origin = origin,
		aimDirection = aimDirection,
		fuseStartedAt = context.now,
		launchedAt = context.now,
		remainingFuse = remainingFuse,
		modifier = {
			physics = {
				launchSpeed = launchSpeed,
				upwardVelocity = upwardVelocity,
				gravity = workspace.Gravity * gravityScale,
				postImpactGravity = workspace.Gravity * gravityScale,
				maxSpeed = math.max(launchSpeed + math.abs(upwardVelocity), launchSpeed, 1),
			},
			collision = {
				directHitExplodes = true,
				playerContactExplodes = true,
				maxRange = maxRange,
			},
		},
	})
	if not launched then
		return false
	end

	local state = context.slotState.state
	local shotsFired = if typeof(state) == "table" and typeof(state.shotsFired) == "number" then state.shotsFired else 0

	return {
		state = {
			shotsFired = shotsFired + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "BulletFired",
			payload = {
				projectileId = projectileId,
				chargeAlpha = chargeAlpha,
			},
		},
	}
end

function Bullet.OnClientMessage(context: ServerClientMessageContext)
	local payload = context.payload
	if context.messageType ~= AbilityConfig.MessageTypes.Intent or typeof(payload) ~= "table" then
		return
	end

	local phase = payload.phase
	if phase == "BeginCharge" then
		if typeof(context.slotState.cooldownEndsAt) == "number" and context.slotState.cooldownEndsAt > context.now then
			CHARGE_RECORDS[context.player] = nil
			return
		end

		local rootPart = getCharacterRoot(context.player)
		local character = rootPart and rootPart:FindFirstAncestorOfClass("Model")
		if rootPart and character then
			CHARGE_RECORDS[context.player] = {
				startedAt = context.now,
				slot = context.slot,
				abilityId = context.abilityId,
				character = character,
			}
		else
			CHARGE_RECORDS[context.player] = nil
		end
	elseif phase == "CancelCharge" then
		CHARGE_RECORDS[context.player] = nil
	end
end

function Bullet.OnPlayerRemoving(player: Player)
	CHARGE_RECORDS[player] = nil
end

return Bullet
