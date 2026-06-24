local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityHookResult = AbilityTypes.AbilityHookResult
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext
type DomeRecord = {
	rootPart: BasePart,
	activeEndsAt: number,
	serial: number,
}

local ForcefieldDome = {} :: AbilityTypes.ServerBehavior

local RESULT_KIND = AbilityResult.Kind
local ACTIVE_DOMES: { [Player]: DomeRecord } = {}
local REPEL_TIMES: { [string]: number } = {}

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

local function getRadius(definition: AbilityDefinition?): number
	return math.max(tonumber(definition and definition.radius) or 15, 1)
end

local function getActiveDome(player: Player, currentTime: number): DomeRecord?
	local dome = ACTIVE_DOMES[player]
	if not dome or currentTime >= dome.activeEndsAt then
		ACTIVE_DOMES[player] = nil
		return nil
	end

	local rootPart = getCharacterRoot(player)
	if not rootPart or rootPart ~= dome.rootPart then
		ACTIVE_DOMES[player] = nil
		return nil
	end

	return dome
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

local function getRepelDirection(center: Vector3, hitPosition: Vector3, fallback: Vector3): Vector3
	local direction = hitPosition - center
	if direction.Magnitude < 0.05 then
		direction = Vector3.new(fallback.X, 0, fallback.Z)
	end
	if direction.Magnitude < 0.05 then
		direction = Vector3.zAxis
	end

	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	if horizontal.Magnitude < 0.05 then
		return direction.Unit
	end

	return Vector3.new(horizontal.Unit.X, 0.18, horizontal.Unit.Z).Unit
end

local function isProjectileTouchingDome(context, center: Vector3, radius: number): (boolean, Vector3)
	local position = context.position
	if typeof(position) ~= "Vector3" then
		return false, center
	end

	local nextPosition = if typeof(context.nextPosition) == "Vector3" then context.nextPosition else position
	local closestPoint = closestPointOnSegment(position, nextPosition, center)
	local sweepRadius = math.max(tonumber(context.sweepRadius) or BombConfig.SweepRadius or 0, 0)
	return (closestPoint - center).Magnitude <= radius + sweepRadius, closestPoint
end

function ForcefieldDome.CanActivate(context: ServerActivateContext): boolean
	if getActiveDome(context.player, context.now) then
		return false
	end

	return getCharacterRoot(context.player) ~= nil
end

function ForcefieldDome.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local rootPart = getCharacterRoot(context.player)
	if not rootPart then
		return false
	end

	local durationSeconds = math.max(tonumber(context.definition.durationSeconds) or 0, 0)
	local activeEndsAt = context.now + durationSeconds
	local previous = ACTIVE_DOMES[context.player]
	local serial = (previous and previous.serial or 0) + 1

	ACTIVE_DOMES[context.player] = {
		rootPart = rootPart,
		activeEndsAt = activeEndsAt,
		serial = serial,
	}

	task.delay(durationSeconds + 0.1, function()
		local current = ACTIVE_DOMES[context.player]
		if current and current.serial == serial then
			ACTIVE_DOMES[context.player] = nil
		end
	end)

	local state = context.slotState.state
	local activationCount = if typeof(state) == "table" and typeof(state.activationCount) == "number"
		then state.activationCount
		else 0

	return {
		state = {
			activationCount = activationCount + 1,
			lastActivatedAt = context.now,
		},
	}
end

function ForcefieldDome.OnBeforeExplosion(context: ServerHookContext): AbilityHookResult
	local dome = getActiveDome(context.player, context.now)
	local payload = context.context
	if not (dome and typeof(payload) == "table" and typeof(payload.position) == "Vector3") then
		return AbilityResult.Continue()
	end

	local radius = getRadius(context.definition)
	local explosionRadius = math.max(tonumber(payload.outerRadius) or 0, 0)
	if (payload.position - dome.rootPart.Position).Magnitude <= radius + explosionRadius then
		return {
			kind = RESULT_KIND.Absorb,
			skipDamage = true,
			skipKnockback = true,
		}
	end

	return AbilityResult.Continue()
end

function ForcefieldDome.OnBeforePlayerBombDamage(context: ServerHookContext): AbilityHookResult
	local dome = getActiveDome(context.player, context.now)
	local payload = context.context
	if not (dome and typeof(payload) == "table" and payload.target == context.player) then
		return AbilityResult.Continue()
	end

	return {
		kind = RESULT_KIND.Absorb,
		skipDamage = true,
		skipKnockback = true,
	}
end

function ForcefieldDome.OnBeforeOwnerBombKnockback(context: ServerHookContext): AbilityHookResult
	local dome = getActiveDome(context.player, context.now)
	local payload = context.context
	if not (dome and typeof(payload) == "table" and payload.owner == context.player) then
		return AbilityResult.Continue()
	end

	return {
		kind = RESULT_KIND.Absorb,
		skipKnockback = true,
	}
end

function ForcefieldDome.OnProjectileStep(context: ServerHookContext): AbilityHookResult
	local dome = getActiveDome(context.player, context.now)
	local payload = context.context
	if not (dome and typeof(payload) == "table" and typeof(payload.projectileId) == "string") then
		return AbilityResult.Continue()
	end
	if payload.owner == context.player then
		return AbilityResult.Continue()
	end

	local radius = getRadius(context.definition)
	local touching, hitPosition = isProjectileTouchingDome(payload, dome.rootPart.Position, radius)
	if not touching then
		return AbilityResult.Continue()
	end

	local repelKey = tostring(context.player.UserId) .. ":" .. payload.projectileId
	local lastRepelledAt = REPEL_TIMES[repelKey]
	local repelCooldown = math.max(tonumber(context.definition.repelCooldownSeconds) or 0.35, 0)
	if typeof(lastRepelledAt) == "number" and context.now - lastRepelledAt < repelCooldown then
		return AbilityResult.Continue()
	end
	REPEL_TIMES[repelKey] = context.now

	local incomingVelocity = if typeof(payload.currentVelocity) == "Vector3" then payload.currentVelocity else Vector3.zAxis
	local origin = dome.rootPart.Position
		+ getRepelDirection(dome.rootPart.Position, hitPosition, incomingVelocity) * (radius + BombConfig.SweepRadius + 0.35)
	local aimDirection = getRepelDirection(dome.rootPart.Position, origin, incomingVelocity)

	return {
		kind = RESULT_KIND.RedirectProjectile,
		owner = context.player,
		sourceType = "Ability",
		sourceId = "ForcefieldDome",
		origin = origin,
		aimDirection = aimDirection,
		launchSpeed = context.definition.repelLaunchSpeed,
		upwardVelocity = context.definition.repelUpwardVelocity,
		maxFlightSeconds = context.definition.repelMaxFlightSeconds,
	}
end

function ForcefieldDome.OnPlayerRemoving(player: Player)
	ACTIVE_DOMES[player] = nil
end

return ForcefieldDome
