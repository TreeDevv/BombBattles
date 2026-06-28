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
type AbilityHookResult = AbilityTypes.AbilityHookResult
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext

type FreezeRecord = {
	player: Player,
}

local FreezeBomb = {} :: AbilityTypes.ServerBehavior
FreezeBomb.AlwaysRunHooks = table.freeze({
	OnBeforeExplosion = true,
	OnBeforePlayerBombDamage = true,
})

local MIN_AIM_HORIZONTAL = 0.08
local MAX_AIM_MAGNITUDE = 1.5
local ZONE_FOLDER_NAME = "FreezeBombZones"
local SLOW_UNTIL_ATTRIBUTE = "FreezeBomb_SlowUntil"
local SLOW_MULTIPLIER_ATTRIBUTE = "FreezeBomb_SlowMultiplier"

local PROJECTILES: { [string]: FreezeRecord } = {}
local projectileSerial = 0
local abilityService: AbilityServiceLike? = nil

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
	return ("FreezeBomb_%d_%d_%04d"):format(
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

local function applyFreeze(owner: Player, target: Player, definition: AbilityDefinition?, projectileId: string?, notify: boolean)
	if not isEnemyPlayer(owner, target) then
		return
	end

	local character = target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (character and humanoid and humanoid.Health > 0) then
		return
	end

	local now = workspace:GetServerTimeNow()
	local duration = math.max(getDefinitionNumber(definition, "freezeSlowDurationSeconds", 2.5), 0)
	local multiplier = math.clamp(getDefinitionNumber(definition, "freezeSlowMultiplier", 0.6), 0.05, 1)
	if duration <= 0 or multiplier >= 1 then
		return
	end

	local previousUntil = character:GetAttribute(SLOW_UNTIL_ATTRIBUTE)
	local wasActive = typeof(previousUntil) == "number" and previousUntil > now
	local slowUntil = math.max(if typeof(previousUntil) == "number" then previousUntil else 0, now + duration)

	character:SetAttribute(SLOW_UNTIL_ATTRIBUTE, slowUntil)
	character:SetAttribute(SLOW_MULTIPLIER_ATTRIBUTE, multiplier)

	if notify and not wasActive and abilityService then
		abilityService:FireEffectToPlayer(target, "FreezeBombApplied", {
			abilityId = "FreezeTnt",
			projectileId = projectileId,
			durationSeconds = duration,
			slowMultiplier = multiplier,
			slowUntil = slowUntil,
		})
	end
end

local function getZoneTargets(owner: Player, zone: BasePart, overlapParams: OverlapParams): { Player }
	local targetsByPlayer: { [Player]: boolean } = {}
	local ok, parts = pcall(function()
		return workspace:GetPartsInPart(zone, overlapParams)
	end)
	if not ok then
		warn("[FreezeBomb] Failed to query freeze zone overlaps: " .. tostring(parts))
		return {}
	end

	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		local target = model and Players:GetPlayerFromCharacter(model)
		if isEnemyPlayer(owner, target) then
			targetsByPlayer[target :: Player] = true
		end
	end

	local targets = {}
	for target in pairs(targetsByPlayer) do
		table.insert(targets, target)
	end
	return targets
end

local function startFreezeZone(owner: Player, definition: AbilityDefinition?, projectileId: string, position: Vector3): boolean
	local radius = math.max(BombConfig.OuterRadius, 1)
	local durationSeconds = math.max(getDefinitionNumber(definition, "freezeZoneDurationSeconds", 4), 0)
	local tickSeconds = math.max(getDefinitionNumber(definition, "freezeZoneTickSeconds", 0.25), 0.05)
	if durationSeconds <= 0 then
		return false
	end

	local zone = Instance.new("Part")
	zone.Name = "FreezeBombZone_" .. projectileId
	zone.Shape = Enum.PartType.Ball
	zone.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
	zone.CFrame = CFrame.new(position)
	zone.Transparency = 1
	zone.Anchored = true
	zone.CanCollide = false
	zone.CanTouch = false
	zone.CanQuery = true
	zone.Parent = getZoneFolder()

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { zone }

	task.spawn(function()
		local expiresAt = workspace:GetServerTimeNow() + durationSeconds
		while zone.Parent and owner.Parent == Players do
			for _, target in ipairs(getZoneTargets(owner, zone, overlapParams)) do
				applyFreeze(owner, target, definition, projectileId, true)
			end

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

local function getTrackedProjectile(player: Player, context): FreezeRecord?
	if typeof(context) ~= "table" then
		return nil
	end

	local projectileId = context.projectileId or context.sourceId
	if typeof(projectileId) ~= "string" or projectileId == "" then
		return nil
	end

	local record = PROJECTILES[projectileId]
	if record and record.player == player then
		return record
	end
	return nil
end

local function cleanupProjectileLater(projectileId: string, record: FreezeRecord, delaySeconds: number)
	task.delay(delaySeconds, function()
		if PROJECTILES[projectileId] == record then
			PROJECTILES[projectileId] = nil
		end
	end)
end

function FreezeBomb.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function FreezeBomb.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getBombProjectileService() ~= nil
end

function FreezeBomb.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local projectileService = getBombProjectileService()
	local rootPart = getCharacterRoot(context.player)
	if not (projectileService and rootPart) then
		return false
	end

	local origin = getThrowOrigin(rootPart)
	local aimDirection = getAimDirectionFromPayload(context.payload, rootPart.CFrame.LookVector)
	local projectileId = AbilityBehaviorServices.GetClientProjectileId(context) or createProjectileId(context.player)
	local skinId = BombSkinService:GetEquippedSkinId(context.player)
	local launchSpeed = getDefinitionNumber(context.definition, "projectileLaunchSpeed", BombConfig.ProjectileLaunchSpeed)
	local upwardVelocity = getDefinitionNumber(context.definition, "projectileUpwardVelocity", BombConfig.ProjectileUpwardVelocity)
	local gravityScale = getDefinitionNumber(context.definition, "projectileGravityScale", BombConfig.ProjectileGravityScale)
	local remainingFuse = math.max(getDefinitionNumber(context.definition, "projectileMaxFlightSeconds", BombConfig.FuseSeconds), 0.05)
	local highlightColor = if typeof(context.definition.freezeHighlightColor) == "Color3"
		then context.definition.freezeHighlightColor
		else Color3.fromRGB(91, 226, 255)

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
			explosion = {
				abilityId = "FreezeTnt",
				suppressDefaultExplosionVfx = true,
			},
			visuals = {
				abilityVisualOverlay = true,
				abilityVisualAssetPath = context.definition.travelVfxAssetPath,
				abilityVisualName = "FreezeBombVFX",
				abilityVisualDisabledAttachmentName = "Impact",
				highlightColor = highlightColor,
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
	cleanupProjectileLater(projectileId, record, remainingFuse + BombConfig.ProjectileLifetimePadding + 8)

	local state = context.slotState.state
	local freezeBombsThrown = if typeof(state) == "table" and typeof(state.freezeBombsThrown) == "number"
		then state.freezeBombsThrown
		else 0
	local freezeZonesCreated = if typeof(state) == "table" and typeof(state.freezeZonesCreated) == "number"
		then state.freezeZonesCreated
		else 0

	return {
		state = {
			freezeBombsThrown = freezeBombsThrown + 1,
			freezeZonesCreated = freezeZonesCreated,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "FreezeBombFired",
			payload = {
				projectileId = projectileId,
			},
		},
	}
end

function FreezeBomb.OnBeforeExplosion(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	local record = getTrackedProjectile(context.player, payload)
	if not record then
		return AbilityResult.Continue()
	end

	local projectileId = payload.projectileId
	if typeof(projectileId) ~= "string" or projectileId == "" then
		return AbilityResult.Continue()
	end

	if typeof(payload.position) == "Vector3" then
		local zoneCreated = startFreezeZone(record.player, context.definition, projectileId, payload.position)
		if zoneCreated and abilityService then
			abilityService:FireEffect("FreezeBombAreaStarted", {
				player = record.player,
				slot = context.slot,
				abilityId = "FreezeTnt",
				projectileId = projectileId,
				position = payload.position,
				durationSeconds = getDefinitionNumber(context.definition, "freezeZoneDurationSeconds", 4),
				zoneVfxAssetPath = context.definition.zoneVfxAssetPath or context.definition.assetPath,
				impactVfxAssetPath = context.definition.impactVfxAssetPath,
			})

			local state = context.slotState.state
			local freezeBombsThrown = if typeof(state) == "table" and typeof(state.freezeBombsThrown) == "number"
				then state.freezeBombsThrown
				else 0
			local freezeZonesCreated = if typeof(state) == "table" and typeof(state.freezeZonesCreated) == "number"
				then state.freezeZonesCreated
				else 0
			abilityService:SetSlotValues(record.player, context.slot, {
				state = {
					freezeBombsThrown = freezeBombsThrown,
					freezeZonesCreated = freezeZonesCreated + 1,
					lastActivatedAt = if typeof(state) == "table" and typeof(state.lastActivatedAt) == "number"
						then state.lastActivatedAt
						else context.now,
				},
			})
		end
	end

	return AbilityResult.Continue()
end

function FreezeBomb.OnBeforePlayerBombDamage(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	local record = getTrackedProjectile(context.player, payload)
	if not record then
		return AbilityResult.Continue()
	end

	local target = if typeof(payload) == "table" then payload.target else nil
	if typeof(target) == "Instance" and target:IsA("Player") then
		applyFreeze(record.player, target, context.definition, payload.sourceId, true)
	end

	return AbilityResult.Continue()
end

function FreezeBomb.OnPlayerRemoving(player: Player)
	for projectileId, record in pairs(PROJECTILES) do
		if record.player == player then
			PROJECTILES[projectileId] = nil
		end
	end
end

return FreezeBomb
