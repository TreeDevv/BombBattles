local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local ExplosionVisibility = require(ReplicatedStorage.Shared.Effects.ExplosionVisibility)
local OwnerExplosionLaunch = require(ReplicatedStorage.Shared.Effects.OwnerExplosionLaunch)
local PlayerSettings = require(ReplicatedStorage.Shared.Common.PlayerSettings)
local PlayerHitFlash = require(ReplicatedStorage.Shared.Effects.PlayerHitFlash)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local VoxelDebris = require(ReplicatedStorage.Packages.VoxManager.Voxelizer.Debris)

local BombExplosionRuntime = {}
local MAX_TERRAIN_DEBRIS_PARTS_PER_EXPLOSION = 48
local MAX_TERRAIN_DEBRIS_PARTS_PER_HEARTBEAT = 16
local MAX_TERRAIN_DEBRIS_PAYLOADS_PER_HEARTBEAT = 1
local FULL_VFX_WINDOW_SECONDS = 0.35
local MAX_FULL_VFX_PER_WINDOW = 4
local MAX_FULL_VFX_PER_HEARTBEAT = 2
local OWN_EXPLOSION_EMIT_COUNT_SCALE = 0.85
local REMOTE_EXPLOSION_EMIT_COUNT_SCALE = 0.7

local fullVfxWindowStartedAt = 0
local fullVfxWindowCount = 0
local fullVfxHeartbeat = 0
local fullVfxHeartbeatCount = 0
local terrainDebrisQueue = {}
local terrainDebrisConnection: RBXScriptConnection? = nil

function BombExplosionRuntime.CreateVisibilityCache()
	return ExplosionVisibility.CreateCache()
end

local function getVisibilityOptions(context)
	return {
		localPlayer = context.localPlayer,
		explosionFolderName = context.explosionVfxFolderName,
		debrisFolderName = "VoxelDebris",
		projectileFolderName = context.projectileVisualFolderName,
		defaultTerrainRadius = BombConfig.TerrainRadius,
		defaultOuterRadius = BombConfig.OuterRadius,
	}
end

function BombExplosionRuntime.GetVfxFolder(context): Folder
	local existing = workspace:FindFirstChild(context.explosionVfxFolderName)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = context.explosionVfxFolderName
	folder.Parent = workspace
	return folder
end

function BombExplosionRuntime.RememberVisibility(controller, position: Vector3, decision)
	ExplosionVisibility.Remember(controller._explosionVisibilityCache, position, decision)
end

function BombExplosionRuntime.GetCachedVisibility(controller, position: Vector3)
	return ExplosionVisibility.GetCached(controller._explosionVisibilityCache, position)
end

local function reserveFullVfxSlot(priority: boolean): boolean
	local now = os.clock()
	if now - fullVfxWindowStartedAt > FULL_VFX_WINDOW_SECONDS then
		fullVfxWindowStartedAt = now
		fullVfxWindowCount = 0
	end

	local heartbeat = math.floor(now * 60)
	if heartbeat ~= fullVfxHeartbeat then
		fullVfxHeartbeat = heartbeat
		fullVfxHeartbeatCount = 0
	end

	if fullVfxWindowCount >= MAX_FULL_VFX_PER_WINDOW then
		RuntimeProfiler.Count(
			if priority
				then "Client/BombController/ExplosionVfxDowngraded/PriorityWindowBudget"
				else "Client/BombController/ExplosionVfxDowngraded/WindowBudget"
		)
		return false
	end
	if not priority and fullVfxHeartbeatCount >= MAX_FULL_VFX_PER_HEARTBEAT then
		RuntimeProfiler.Count("Client/BombController/ExplosionVfxDowngraded/HeartbeatBudget")
		return false
	end

	fullVfxHeartbeatCount += 1
	fullVfxWindowCount += 1
	return true
end

function BombExplosionRuntime.GetDebrisVisibilityDecision(controller, context, payloads)
	local position = ExplosionVisibility.GetDebrisPosition(payloads)
	if not position then
		return ExplosionVisibility.SkipDecision()
	end

	local cached = BombExplosionRuntime.GetCachedVisibility(controller, position)
	if cached then
		return cached
	end

	local options = getVisibilityOptions(context)
	local decision = ExplosionVisibility.Choose({
		position = position,
		terrainRadius = ExplosionVisibility.GetDebrisRadius(payloads, options),
	}, options)
	BombExplosionRuntime.RememberVisibility(controller, position, decision)
	return decision
end

function BombExplosionRuntime.PlayEffect(controller, context, position: Vector3, skinId: any, visualScale: number?, assetPath: any?, decision)
	decision = decision or ExplosionVisibility.Choose({
		position = position,
		terrainRadius = BombConfig.TerrainRadius,
	}, getVisibilityOptions(context))
	BombExplosionRuntime.RememberVisibility(controller, position, decision)
	RuntimeProfiler.Count("Client/BombController/ExplosionVisibility/" .. tostring(decision.quality))
	if decision.inView == false then
		RuntimeProfiler.Count("Client/BombController/ExplosionVisibility/Offscreen")
	end
	if decision.occluded == true then
		RuntimeProfiler.Count("Client/BombController/ExplosionVisibility/Occluded")
	end
	if decision.quality == ExplosionVisibility.Quality.Skip then
		return
	end

	local priorityFullVfx = context.priorityFullVfx == true
	if decision.quality == ExplosionVisibility.Quality.Full and not reserveFullVfxSlot(priorityFullVfx) then
		decision.quality = ExplosionVisibility.Quality.SoundOnly
	end
	local soundLightOnly = decision.quality == ExplosionVisibility.Quality.SoundOnly
	local emitModule = nil
	if soundLightOnly then
		emitModule = nil
	elseif EmitService.EnsureInitialized("[BombController]", 10) then
		emitModule = EmitService.GetModule("[BombController]", 10)
	end

	local result = BombVisualUtil.PlayExplosionEffect({
		parent = BombExplosionRuntime.GetVfxFolder(context),
		position = position,
		skinId = skinId,
		assetPath = assetPath,
		emitModule = emitModule,
		name = "BombExplosionVFX",
		cleanupSeconds = context.explosionVfxCleanupSeconds,
		visualScale = visualScale,
		soundLightOnly = soundLightOnly,
		emitCountScale = if priorityFullVfx then OWN_EXPLOSION_EMIT_COUNT_SCALE else REMOTE_EXPLOSION_EMIT_COUNT_SCALE,
		warnPrefix = "[BombController]",
	})
	if not result.template and not controller._warnedMissingExplosionVfx then
		controller._warnedMissingExplosionVfx = true
		warn("[BombController] Missing bomb explosion VFX template and default fallback")
	end
	if emitModule and not result.emitted then
		if not controller._warnedMissingExplosionVfx then
			controller._warnedMissingExplosionVfx = true
			warn("[BombController] Bomb explosion VFX was not emitted")
		end
	end
end

local function stopTerrainDebrisQueueIfIdle()
	if #terrainDebrisQueue > 0 then
		return
	end
	if terrainDebrisConnection then
		terrainDebrisConnection:Disconnect()
		terrainDebrisConnection = nil
	end
end

local function finishTerrainDebrisRecord(record)
	RuntimeProfiler.Count("Client/BombController/TerrainDebrisPartsSpawned", record.spawnedParts or 0)
	RuntimeProfiler.Count("Client/BombController/TerrainDebrisSpawnAttempts", record.spawnAttempts or 0)
end

local function processTerrainDebrisQueue()
	local framePartsRemaining = MAX_TERRAIN_DEBRIS_PARTS_PER_HEARTBEAT
	local payloadsProcessed = 0

	while framePartsRemaining > 0 and payloadsProcessed < MAX_TERRAIN_DEBRIS_PAYLOADS_PER_HEARTBEAT and #terrainDebrisQueue > 0 do
		local record = terrainDebrisQueue[1]
		if record.remainingParts <= 0 or record.nextIndex > #record.payloads then
			finishTerrainDebrisRecord(record)
			table.remove(terrainDebrisQueue, 1)
			continue
		end

		local payload = record.payloads[record.nextIndex]
		record.nextIndex += 1
		payloadsProcessed += 1

		local maxParts = math.min(record.remainingParts, framePartsRemaining)
		local spawned, attempts = VoxelDebris.spawnPayload(payload, {
			maxParts = maxParts,
		})
		spawned = if typeof(spawned) == "number" then math.max(math.floor(spawned), 0) else 0
		attempts = if typeof(attempts) == "number" then math.max(math.floor(attempts), 0) else 0

		record.spawnedParts += spawned
		record.spawnAttempts += attempts
		record.remainingParts -= spawned
		framePartsRemaining -= spawned

		if record.remainingParts <= 0 or record.nextIndex > #record.payloads then
			finishTerrainDebrisRecord(record)
			table.remove(terrainDebrisQueue, 1)
		end
	end

	RuntimeProfiler.Gauge("Client/BombController/TerrainDebrisQueueDepth", #terrainDebrisQueue)
	stopTerrainDebrisQueueIfIdle()
end

local function ensureTerrainDebrisQueueConnection()
	if terrainDebrisConnection then
		return
	end

	terrainDebrisConnection = RunService.Heartbeat:Connect(processTerrainDebrisQueue)
end

local function enqueueTerrainDebris(payloads)
	table.insert(terrainDebrisQueue, {
		payloads = payloads,
		nextIndex = 1,
		remainingParts = MAX_TERRAIN_DEBRIS_PARTS_PER_EXPLOSION,
		spawnedParts = 0,
		spawnAttempts = 0,
	})
	RuntimeProfiler.Count("Client/BombController/TerrainDebrisQueued")
	RuntimeProfiler.Count("Client/BombController/TerrainDebrisPayloadsQueued", #payloads)
	RuntimeProfiler.Gauge("Client/BombController/TerrainDebrisQueueDepth", #terrainDebrisQueue)
	ensureTerrainDebrisQueueConnection()
end

function BombExplosionRuntime.PlayTerrainDebris(controller, context, payloads)
	if typeof(payloads) ~= "table" then
		return
	end
	if PlayerSettings:Get("explosionDebrisEnabled") ~= true then
		RuntimeProfiler.Count("Client/BombController/TerrainDebrisSkipped/Settings")
		return
	end

	local decision = BombExplosionRuntime.GetDebrisVisibilityDecision(controller, context, payloads)
	if
		decision.quality == ExplosionVisibility.Quality.Skip
		or decision.quality == ExplosionVisibility.Quality.SoundOnly
	then
		RuntimeProfiler.Count("Client/BombController/TerrainDebrisSkipped")
		return
	end

	enqueueTerrainDebris(payloads)
end

function BombExplosionRuntime.HandleExplode(controller, context, payload, payloadPlayer: Player?)
	if typeof(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end

	if payloadPlayer and payload.source == "InHand" then
		context.hideHeldBomb(payloadPlayer)
	end
	if typeof(payload.projectileId) == "string" then
		context.destroyProjectileVisual(payload.projectileId)
	end
	local explosionVisibility = ExplosionVisibility.Choose(payload, getVisibilityOptions(context))
	BombExplosionRuntime.RememberVisibility(controller, payload.position, explosionVisibility)
	if payload.player == context.localPlayer then
		OwnerExplosionLaunch.ApplyForPlayer(context.localPlayer, payload.position, payload)
		context.playLocalExplosionShake()
		context.priorityFullVfx = true
	end
	PlayerHitFlash.PlayForUserIds(payload.hitUserIds)
	local explosionVfxAssetPath = if typeof(payload.explosionVfxAssetPath) == "table"
		then payload.explosionVfxAssetPath
		else nil
	if explosionVfxAssetPath then
		BombExplosionRuntime.PlayEffect(
			controller,
			context,
			payload.position,
			payload.bombSkinId,
			payload.explosionVisualScale,
			explosionVfxAssetPath,
			explosionVisibility
		)
	elseif payload.suppressDefaultExplosionVfx ~= true then
		BombExplosionRuntime.PlayEffect(
			controller,
			context,
			payload.position,
			payload.bombSkinId,
			payload.explosionVisualScale,
			nil,
			explosionVisibility
		)
	end
	if typeof(payload.debrisPayloads) == "table" then
		BombExplosionRuntime.PlayTerrainDebris(controller, context, payload.debrisPayloads)
	end
end

return table.freeze(BombExplosionRuntime)
