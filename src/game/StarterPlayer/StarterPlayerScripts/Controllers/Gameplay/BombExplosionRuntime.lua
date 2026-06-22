local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local ExplosionVisibility = require(ReplicatedStorage.Shared.Effects.ExplosionVisibility)
local OwnerExplosionLaunch = require(ReplicatedStorage.Shared.Effects.OwnerExplosionLaunch)
local PlayerSettings = require(ReplicatedStorage.Shared.Common.PlayerSettings)
local PlayerHitFlash = require(ReplicatedStorage.Shared.Effects.PlayerHitFlash)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local SettingsConfig = require(ReplicatedStorage.Shared.Config.SettingsConfig)
local VoxelDebris = require(ReplicatedStorage.Packages.VoxManager.Voxelizer.Debris)

local BombExplosionRuntime = {}

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
	local explosionQuality = PlayerSettings:Get("explosionVfxQuality")
	if explosionQuality == SettingsConfig.Quality.Minimal or explosionQuality == SettingsConfig.Quality.Off then
		decision.quality = ExplosionVisibility.Quality.SoundOnly
	elseif explosionQuality == SettingsConfig.Quality.Reduced and decision.quality == ExplosionVisibility.Quality.Full then
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

function BombExplosionRuntime.PlayTerrainDebris(controller, context, payloads)
	if typeof(payloads) ~= "table" then
		return
	end
	if PlayerSettings:Get("debrisVfxQuality") ~= SettingsConfig.Quality.Full then
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

	for _, payload in ipairs(payloads) do
		VoxelDebris.spawnPayload(payload)
	end
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
		OwnerExplosionLaunch.ApplyForPlayer(context.localPlayer, payload.position)
		context.playLocalExplosionShake()
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
end

return table.freeze(BombExplosionRuntime)
