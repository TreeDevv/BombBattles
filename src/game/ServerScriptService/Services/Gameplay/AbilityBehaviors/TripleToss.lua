local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityBehaviorServices = require(ServerScriptService.Services.AbilityBehaviorServices)

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombThrowOrigin = require(ReplicatedStorage.Shared.Common.BombThrowOrigin)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type ServerActivateContext = AbilityTypes.ServerActivateContext

local TripleToss = {} :: AbilityTypes.ServerBehavior

local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5
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

local function getSpreadDirections(centerDirection: Vector3, bombCount: number, spreadDegrees: number): { Vector3 }
	bombCount = math.max(math.floor(bombCount), 1)
	spreadDegrees = math.max(spreadDegrees, 0)
	if centerDirection.Magnitude <= 0.05 then
		centerDirection = Vector3.zAxis
	else
		centerDirection = centerDirection.Unit
	end
	if bombCount == 1 or spreadDegrees <= 0 then
		return { centerDirection }
	end

	local directions = {}
	local step = spreadDegrees / (bombCount - 1)
	local startAngle = -spreadDegrees * 0.5
	for index = 1, bombCount do
		local angle = math.rad(startAngle + step * (index - 1))
		local rotated = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(centerDirection)
		table.insert(directions, if rotated.Magnitude > 0.05 then rotated.Unit else centerDirection)
	end
	return directions
end

local function createProjectileId(player: Player, index: number): string
	projectileSerial += 1
	return ("TripleToss_%d_%d_%02d_%04d"):format(
		player.UserId,
		math.floor(workspace:GetServerTimeNow() * 1000),
		index,
		projectileSerial % 10000
	)
end

function TripleToss.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getBombProjectileService() ~= nil
end

function TripleToss.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local projectileService = getBombProjectileService()
	local rootPart = getCharacterRoot(context.player)
	if not (projectileService and rootPart) then
		return false
	end

	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(context.payload, rootPart.CFrame.LookVector)
	local skinId = BombSkinService:GetEquippedSkinId(context.player)
	local bombCount = getDefinitionNumber(context.definition, "bombCount", 3)
	local spreadDegrees = getDefinitionNumber(context.definition, "spreadDegrees", 15)
	local launchSpeed = getDefinitionNumber(context.definition, "projectileLaunchSpeed", BombConfig.ProjectileLaunchSpeed)
	local upwardVelocity = getDefinitionNumber(context.definition, "projectileUpwardVelocity", BombConfig.ProjectileUpwardVelocity)
	local gravityScale = getDefinitionNumber(context.definition, "projectileGravityScale", BombConfig.ProjectileGravityScale)
	local remainingFuse = math.max(
		getDefinitionNumber(context.definition, "projectileMaxFlightSeconds", BombConfig.FuseSeconds),
		0.05
	)
	local gravity = workspace.Gravity * gravityScale
	local directions = getSpreadDirections(aimDirection, bombCount, spreadDegrees)
	local projectileIds = {}
	local clientProjectileId = AbilityBehaviorServices.GetClientProjectileId(context)

	for index, direction in ipairs(directions) do
		local projectileId = if index == 1 and clientProjectileId then clientProjectileId else createProjectileId(context.player, index)
		local launched = projectileService:Launch({
			owner = context.player,
			projectileId = projectileId,
			bombType = BombProjectileConfig.BombType.Normal,
			skinId = skinId,
			origin = origin,
			aimDirection = direction,
			fuseStartedAt = context.now,
			launchedAt = context.now,
			remainingFuse = remainingFuse,
			modifier = {
				physics = {
					launchSpeed = launchSpeed,
					upwardVelocity = upwardVelocity,
					gravity = gravity,
					postImpactGravity = gravity,
					maxSpeed = math.max(launchSpeed + math.abs(upwardVelocity), launchSpeed, 1),
				},
				collision = {
					directHitExplodes = false,
					playerContactExplodes = false,
					playerContactImpacts = false,
				},
			},
		})
		if not launched then
			for _, launchedProjectileId in ipairs(projectileIds) do
				projectileService:DestroyProjectile(launchedProjectileId, "TripleTossRollback")
			end
			return false
		end
		table.insert(projectileIds, projectileId)
	end

	local state = context.slotState.state
	local tripleTossesThrown = if typeof(state) == "table" and typeof(state.tripleTossesThrown) == "number"
		then state.tripleTossesThrown
		else 0

	return {
		state = {
			tripleTossesThrown = tripleTossesThrown + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "TripleTossThrown",
			payload = {
				projectileIds = projectileIds,
				spreadDegrees = spreadDegrees,
			},
		},
	}
end

return TripleToss
