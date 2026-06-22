local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityBehaviorServices = require(ServerScriptService.Services.AbilityBehaviorServices)

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombThrowOrigin = require(ReplicatedStorage.Shared.Common.BombThrowOrigin)
local BombProjectileConfig = require(ReplicatedStorage.Shared.Bombs.BombProjectileConfig)
local BombSkinService = require(ServerScriptService.Services.BombSkinService)
local RoundService = require(ServerScriptService.Services.RoundService)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext

type FireRecord = {
	player: Player,
}

local FireBomb = {} :: AbilityTypes.ServerBehavior
FireBomb.AlwaysRunHooks = table.freeze({
	OnBeforeExplosion = true,
})

local RESULT_KIND = AbilityResult.Kind
local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5
local ZONE_FOLDER_NAME = "FireBombZones"

local PROJECTILES: { [string]: FireRecord } = {}
local projectileSerial = 0
local abilityService: AbilityServiceLike? = nil
local warnedMissingTemplate = false
local warnedInvalidTemplate = false

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

local function createProjectileId(player: Player): string
	projectileSerial += 1
	return ("FireBomb_%d_%d_%04d"):format(
		player.UserId,
		math.floor(workspace:GetServerTimeNow() * 1000),
		projectileSerial % 10000
	)
end

local function getZoneFolder(): Folder
	local existing = workspace:FindFirstChild(ZONE_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = ZONE_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function getInstanceByPath(path: any): Instance?
	if typeof(path) ~= "table" then
		return nil
	end

	local current: Instance? = ReplicatedStorage
	for _, name in ipairs(path) do
		if typeof(name) ~= "string" or name == "" or not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getFireTemplate(definition: AbilityDefinition?): BasePart?
	local template = getInstanceByPath(if definition then definition.assetPath else nil)
	if not template then
		if not warnedMissingTemplate then
			warn("[FireBomb] Missing ReplicatedStorage.Assets.Abilities.FireBomb.Fire")
			warnedMissingTemplate = true
		end
		return nil
	end
	if not template:IsA("BasePart") then
		if not warnedInvalidTemplate then
			warn("[FireBomb] Fire asset must be a BasePart for server overlap damage")
			warnedInvalidTemplate = true
		end
		return nil
	end

	return template
end

local function prepareGameplayZone(zone: BasePart)
	zone.Anchored = true
	zone.CanCollide = false
	zone.CanTouch = false
	zone.CanQuery = true
	zone.Transparency = 1
	zone.AssemblyLinearVelocity = Vector3.zero
	zone.AssemblyAngularVelocity = Vector3.zero

	for _, descendant in ipairs(zone:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") or descendant:IsA("Beam") then
			descendant.Enabled = false
		elseif descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
			descendant.Enabled = false
		elseif descendant:IsA("Sound") then
			descendant:Stop()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Transparency = 1
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
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

local function getDamageTargets(owner: Player, zone: BasePart, overlapParams: OverlapParams): { [Player]: Humanoid }
	local targets: { [Player]: Humanoid } = {}
	local ok, parts = pcall(function()
		return workspace:GetPartsInPart(zone, overlapParams)
	end)
	if not ok then
		warn("[FireBomb] Failed to query fire zone overlaps: " .. tostring(parts))
		return targets
	end

	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		if not (humanoid and humanoid.Health > 0) then
			continue
		end

		local target = Players:GetPlayerFromCharacter(model)
		if isEnemyPlayer(owner, target) then
			targets[target :: Player] = humanoid
		end
	end

	return targets
end

local function resolvePlayerDamage(owner: Player, target: Player, humanoid: Humanoid, damage: number, sourceContext): (number, boolean)
	local service = abilityService
	if not service then
		return damage, false
	end

	local character = target.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local hookResult = service:RunHook("OnBeforePlayerDamage", {
		owner = owner,
		target = target,
		character = character,
		humanoid = humanoid,
		rootPart = if rootPart and rootPart:IsA("BasePart") then rootPart else nil,
		damage = damage,
		sourceType = sourceContext.sourceType,
		sourceId = sourceContext.sourceId,
		projectileId = sourceContext.projectileId,
		sourceContext = sourceContext,
	})
	if typeof(hookResult) ~= "table" then
		return damage, false
	end
	if hookResult.kind == RESULT_KIND.Block or hookResult.kind == RESULT_KIND.Absorb or hookResult.skipDamage == true then
		return 0, true
	end
	if typeof(hookResult.damage) == "number" then
		return math.max(hookResult.damage, 0), false
	end
	if typeof(hookResult.damageMultiplier) == "number" then
		return math.max(damage * hookResult.damageMultiplier, 0), false
	end

	return damage, false
end

local function damageTargets(owner: Player, zone: BasePart, overlapParams: OverlapParams, damage: number, projectileId: string)
	if damage <= 0 then
		return
	end

	for target, humanoid in pairs(getDamageTargets(owner, zone, overlapParams)) do
		local healthBefore = humanoid.Health
		if healthBefore <= 0 then
			continue
		end

		local sourceContext = {
			sourceType = "Ability",
			sourceId = "FireBomb",
			projectileId = projectileId,
		}
		local resolvedDamage, blocked = resolvePlayerDamage(owner, target, humanoid, damage, sourceContext)
		if blocked or resolvedDamage <= 0 then
			continue
		end

		local appliedDamage = math.min(resolvedDamage, healthBefore)
		RoundService:RecordPlayerDamage(owner, target, appliedDamage, sourceContext)
		humanoid:TakeDamage(resolvedDamage)
	end
end

local function startBurnZone(owner: Player, definition: AbilityDefinition?, projectileId: string, position: Vector3)
	local template = getFireTemplate(definition)
	if not template then
		return false
	end

	local durationSeconds = math.max(getDefinitionNumber(definition, "fireDurationSeconds", 6), 0)
	local tickSeconds = math.max(getDefinitionNumber(definition, "fireTickSeconds", 0.5), 0.05)
	local tickDamage = math.max(getDefinitionNumber(definition, "fireTickDamage", 10), 0)
	if durationSeconds <= 0 or tickDamage <= 0 then
		return false
	end

	local zone = template:Clone()
	zone.Name = "FireBombZone_" .. projectileId
	prepareGameplayZone(zone)
	zone.CFrame = CFrame.new(position)
	zone.Parent = getZoneFolder()

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { zone }

	task.spawn(function()
		local expiresAt = workspace:GetServerTimeNow() + durationSeconds

		while zone.Parent and owner.Parent == Players do
			damageTargets(owner, zone, overlapParams, tickDamage, projectileId)

			local remaining = expiresAt - workspace:GetServerTimeNow()
			if remaining <= 0 then
				break
			end
			task.wait(math.min(tickSeconds, remaining))
		end

		if zone.Parent then
			zone:Destroy()
		end
	end)

	return true
end

local function getTrackedProjectile(player: Player, context): FireRecord?
	if typeof(context) ~= "table" then
		return nil
	end

	local projectileId = context.projectileId
	if typeof(projectileId) ~= "string" or projectileId == "" then
		return nil
	end

	local record = PROJECTILES[projectileId]
	if record and record.player == player then
		return record
	end
	return nil
end

local function cleanupProjectileLater(projectileId: string, record: FireRecord, delaySeconds: number)
	task.delay(delaySeconds, function()
		if PROJECTILES[projectileId] == record then
			PROJECTILES[projectileId] = nil
		end
	end)
end

function FireBomb.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function FireBomb.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getBombProjectileService() ~= nil
end

function FireBomb.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local projectileService = getBombProjectileService()
	local rootPart = getCharacterRoot(context.player)
	if not (projectileService and rootPart) then
		return false
	end

	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(context.payload, rootPart.CFrame.LookVector)
	local projectileId = createProjectileId(context.player)
	local skinId = BombSkinService:GetEquippedSkinId(context.player)
	local launchSpeed = getDefinitionNumber(context.definition, "projectileLaunchSpeed", BombConfig.ProjectileLaunchSpeed)
	local upwardVelocity = getDefinitionNumber(context.definition, "projectileUpwardVelocity", BombConfig.ProjectileUpwardVelocity)
	local gravityScale = getDefinitionNumber(context.definition, "projectileGravityScale", BombConfig.ProjectileGravityScale)
	local remainingFuse = math.max(getDefinitionNumber(context.definition, "projectileMaxFlightSeconds", BombConfig.FuseSeconds), 0.05)

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
				directHitExplodes = false,
				playerContactExplodes = false,
				playerContactImpacts = false,
			},
			visuals = {
				abilityVisualOverlay = true,
				abilityVisualAssetPath = context.definition.travelVfxAssetPath,
				abilityVisualName = "FireBombProjectileVFX",
				abilityVisualDisabledAttachmentName = "Impact",
			},
		},
	})
	if not launched then
		return false
	end

	local record = {
		player = context.player,
	}
	PROJECTILES[projectileId] = record
	cleanupProjectileLater(projectileId, record, remainingFuse + BombConfig.ProjectileLifetimePadding + 4)

	local state = context.slotState.state
	local fireBombsThrown = if typeof(state) == "table" and typeof(state.fireBombsThrown) == "number"
		then state.fireBombsThrown
		else 0
	local fireZonesCreated = if typeof(state) == "table" and typeof(state.fireZonesCreated) == "number"
		then state.fireZonesCreated
		else 0

	return {
		state = {
			fireBombsThrown = fireBombsThrown + 1,
			fireZonesCreated = fireZonesCreated,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "FireBombFired",
			payload = {
				projectileId = projectileId,
			},
		},
	}
end

function FireBomb.OnBeforeExplosion(context: ServerHookContext)
	local payload = context.context
	local record = getTrackedProjectile(context.player, payload)
	if not record then
		return AbilityResult.Continue()
	end

	local projectileId = payload.projectileId
	PROJECTILES[projectileId] = nil

	if typeof(payload.position) == "Vector3" then
		local zoneCreated = startBurnZone(record.player, context.definition, projectileId, payload.position)
		if zoneCreated and abilityService then
			abilityService:FireEffect("FireBombAreaStarted", {
				player = record.player,
				slot = context.slot,
				abilityId = "FireBomb",
				projectileId = projectileId,
				position = payload.position,
				durationSeconds = getDefinitionNumber(context.definition, "fireDurationSeconds", 6),
				assetPath = context.definition.assetPath,
				impactVfxAssetPath = context.definition.impactVfxAssetPath,
			})

			local state = context.slotState.state
			local fireBombsThrown = if typeof(state) == "table" and typeof(state.fireBombsThrown) == "number"
				then state.fireBombsThrown
				else 0
			local fireZonesCreated = if typeof(state) == "table" and typeof(state.fireZonesCreated) == "number"
				then state.fireZonesCreated
				else 0
			abilityService:SetSlotValues(record.player, context.slot, {
				state = {
					fireBombsThrown = fireBombsThrown,
					fireZonesCreated = fireZonesCreated + 1,
					lastActivatedAt = if typeof(state) == "table" and typeof(state.lastActivatedAt) == "number"
						then state.lastActivatedAt
						else context.now,
				},
			})
		end
	end

	return AbilityResult.Continue()
end

function FireBomb.OnPlayerRemoving(player: Player)
	for projectileId, record in pairs(PROJECTILES) do
		if record.player == player then
			PROJECTILES[projectileId] = nil
		end
	end
end

return FireBomb
