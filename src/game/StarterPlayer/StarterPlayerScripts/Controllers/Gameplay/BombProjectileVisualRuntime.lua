local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local AbilityVisualOverlay = require(ReplicatedStorage.Shared.Effects.AbilityVisualOverlay)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombFuseAudioRuntime = require(script.Parent:WaitForChild("BombFuseAudioRuntime"))
local BombFusePulse = require(ReplicatedStorage.Shared.Effects.BombFusePulse)
local BombImpactEffects = require(ReplicatedStorage.Shared.Effects.BombImpactEffects)
local BombProjectileVisualFactory = require(ReplicatedStorage.Shared.Effects.BombProjectileVisualFactory)
local BombProjectileVisualHandoff = require(ReplicatedStorage.Shared.Effects.BombProjectileVisualHandoff)
local BombProjectileVisualMotion = require(ReplicatedStorage.Shared.Effects.BombProjectileVisualMotion)
local BombProjectileVisualState = require(ReplicatedStorage.Shared.Effects.BombProjectileVisualState)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local AudioCatalog = require(ReplicatedStorage.Shared.Audio.AudioCatalog)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local SoundUtil = require(ReplicatedStorage.Shared.Audio.SoundUtil)
local TeamPerspective = require(ReplicatedStorage.Shared.Common.TeamPerspective)

local BombProjectileVisualRuntime = {}
local LocalPlayer = Players.LocalPlayer
local ROUND_TEAM_ATTR = "RoundTeam"
local THROW_SOUND_GROUP_KIND = "SFX"
local throwSoundIndex = 0

local function syncAbilityVisual(visual)
	AbilityVisualOverlay.SyncFromVisuals(visual)
end

local function syncBaseVisual(visual)
	local visuals = visual and visual.visuals
	local hideBase = typeof(visuals) == "table"
		and visuals.hideBaseVisual == true
	AbilityVisualOverlay.SyncBaseVisual(visual, hideBase)
end

local function getPulseStyle(visual): { baseColor: Color3, pulseColor: Color3, fillStart: number, outlineStart: number }
	return BombProjectileVisualMotion.GetPulseStyle(visual)
end

local function getPlayerTeamName(player: Player?): string?
	if not player then
		return nil
	end
	local teamName = player:GetAttribute(ROUND_TEAM_ATTR)
	if typeof(teamName) == "string" and teamName ~= "" then
		return teamName
	end
	return if player.Team then player.Team.Name else nil
end

local function getPayloadPlayer(payload): Player?
	if typeof(payload) ~= "table" then
		return nil
	end
	local player = payload.player
	return if typeof(player) == "Instance" and player:IsA("Player") then player else nil
end

local function getPayloadOwnerUserId(payload): number?
	if typeof(payload.ownerUserId) == "number" then
		return payload.ownerUserId
	end
	local player = getPayloadPlayer(payload)
	return if player then player.UserId else nil
end

local function getPayloadOwnerTeam(payload): string?
	if typeof(payload.ownerTeam) == "string" and payload.ownerTeam ~= "" then
		return payload.ownerTeam
	end
	return getPlayerTeamName(getPayloadPlayer(payload))
end

local function getFriendlyPulseColor(payload): Color3
	local ownerUserId = getPayloadOwnerUserId(payload)
	if ownerUserId == LocalPlayer.UserId then
		return TeamPerspective.Colors.Friendly
	end

	local localTeam = getPlayerTeamName(LocalPlayer)
	local ownerTeam = getPayloadOwnerTeam(payload)
	if localTeam and ownerTeam == localTeam then
		return TeamPerspective.Colors.Friendly
	end

	return TeamPerspective.Colors.Enemy
end

local function copyVisualsWithPulseColor(visuals, pulseColor: Color3)
	local copy = {}
	if typeof(visuals) == "table" then
		for key, value in pairs(visuals) do
			copy[key] = value
		end
	end
	copy.highlightPulseColor = pulseColor
	return copy
end

local function applyOwnerPulseColor(visual, payload)
	if not visual or typeof(payload) ~= "table" then
		return
	end
	visual.ownerUserId = getPayloadOwnerUserId(payload)
	visual.ownerTeam = getPayloadOwnerTeam(payload)
	visual.visuals = copyVisualsWithPulseColor(visual.visuals, getFriendlyPulseColor(payload))
end

local function playThrowSound(position: Vector3)
	local soundNames = AudioCatalog.GetThrowSoundNames()
	local soundCount = #soundNames
	if soundCount <= 0 then
		return
	end

	throwSoundIndex = (throwSoundIndex % soundCount) + 1
	SoundUtil.PlayAtPosition(soundNames[throwSoundIndex], position, workspace, THROW_SOUND_GROUP_KIND)
end

function BombProjectileVisualRuntime.GetFolder(controller, context): Folder
	if controller._projectileVisualFolder and controller._projectileVisualFolder.Parent then
		return controller._projectileVisualFolder
	end

	local folder = Instance.new("Folder")
	folder.Name = context.projectileVisualFolderName
	folder.Parent = workspace
	controller._projectileVisualFolder = folder
	return folder
end

function BombProjectileVisualRuntime.FindPhysicalProjectile(projectileId: string, physicalProjectile: any): (Instance?, BasePart?)
	if typeof(physicalProjectile) == "Instance" then
		local rootPart = BombVisualUtil.GetRootPart(physicalProjectile)
		if rootPart then
			return physicalProjectile, rootPart
		end
	end

	local folder = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	local projectile = folder and folder:FindFirstChild("BombProjectile_" .. projectileId)
	if projectile then
		local rootPart = BombVisualUtil.GetRootPart(projectile)
		if rootPart then
			return projectile, rootPart
		end
	end

	return nil, nil
end

function BombProjectileVisualRuntime.TransferToPhysical(controller, context, projectileId: string, physicalProjectile: any): boolean
	local visual = controller._projectileVisuals[projectileId]
	if not visual then
		return false
	end

	local projectile, rootPart = BombProjectileVisualRuntime.FindPhysicalProjectile(projectileId, physicalProjectile)
	if not (projectile and rootPart) then
		return false
	end

	return BombProjectileVisualHandoff.Attach(visual, projectile, rootPart, {
		getServerTime = context.getServerTime,
		getPulseStyle = getPulseStyle,
		syncAbilityVisual = syncAbilityVisual,
		syncAudio = function(updatedVisual)
			BombFuseAudioRuntime.Refresh(updatedVisual, updatedVisual.instance)
		end,
		syncBaseVisual = syncBaseVisual,
	})
end

function BombProjectileVisualRuntime.RetryTransferToPhysical(controller, context, projectileId: string, physicalProjectile: any)
	task.delay(0.08, function()
		local visual = controller._projectileVisuals[projectileId]
		if not visual or not visual.ownsInstance then
			return
		end

		BombProjectileVisualRuntime.TransferToPhysical(controller, context, projectileId, physicalProjectile)
	end)
end

function BombProjectileVisualRuntime.Create(controller, context, projectileId: string, skinId: any, visualScale: number?)
	return BombProjectileVisualFactory.Create(
		BombProjectileVisualRuntime.GetFolder(controller, context),
		projectileId,
		skinId,
		visualScale
	)
end

function BombProjectileVisualRuntime.Destroy(controller, projectileId: string)
	local visual = controller._projectileVisuals[projectileId]
	if not visual then
		return
	end

	if visual.connection then
		visual.connection:Disconnect()
	end
	if visual.handoffConnection then
		visual.handoffConnection:Disconnect()
	end
	if visual.handoffPhysical then
		BombProjectileVisualHandoff.SetLocalTransparency(visual.handoffPhysical, 0)
		BombVisualUtil.SetEffectState(visual.handoffPhysical, {
			vfx = true,
			fuseSpark = true,
			trail = true,
		})
	end
	BombFuseAudioRuntime.Stop(visual)
	BombFusePulse.Stop(visual)
	AbilityVisualOverlay.Destroy(visual)
	if visual.ownsInstance and visual.instance.Parent then
		visual.instance:Destroy()
	end
	controller._projectileVisuals[projectileId] = nil
end

function BombProjectileVisualRuntime.PlayThrowEffect(controller, context, payload)
	if typeof(payload) ~= "table" then
		return
	end

	local projectileId = payload.projectileId
	if typeof(projectileId) ~= "string" then
		return
	end

	local customProjectile = payload.customProjectile == true
	local path = if customProjectile then nil else BombTrajectory.FromPayload(payload)
	if not customProjectile and not path then
		return
	end
	local startPosition = if typeof(payload.position) == "Vector3" then payload.position else payload.origin
	if customProjectile and typeof(startPosition) ~= "Vector3" then
		return
	end
	local startedAt = if typeof(payload.startedAt) == "number" then payload.startedAt else context.getServerTime()

	local visual = controller._projectileVisuals[projectileId]
	local reusePredictedVisual = customProjectile
		and visual ~= nil
		and visual.ownsInstance == true
		and visual.customProjectile == true
		and visual.handoffConnection == nil
	if not reusePredictedVisual then
		BombProjectileVisualRuntime.Destroy(controller, projectileId)
		visual = BombProjectileVisualRuntime.Create(controller, context, projectileId, payload.bombSkinId, payload.visualScale)
		if not visual then
			return
		end
		controller._projectileVisuals[projectileId] = visual
	else
		RuntimeProfiler.Count("Client/BombController/ProjectilePredictionReconciled")
	end

	visual.path = path
	BombProjectileVisualState.ApplyLaunch(visual, payload, startPosition, startedAt, reusePredictedVisual)
	applyOwnerPulseColor(visual, payload)
	syncAbilityVisual(visual)
	syncBaseVisual(visual)
	if not reusePredictedVisual then
		playThrowSound(startPosition)
	end

	local lifetime = if typeof(payload.remainingFuse) == "number" then payload.remainingFuse else BombConfig.FuseSeconds
	local fuseStartedAt = if typeof(payload.fuseStartedAt) == "number" then payload.fuseStartedAt else startedAt
	local fuseEndsAt = startedAt + lifetime
	BombFusePulse.Start(visual, visual.instance, fuseStartedAt, fuseEndsAt, getPulseStyle)
	BombFuseAudioRuntime.Start(visual, visual.instance)
	syncBaseVisual(visual)
	if visual.connection then
		return
	end

	visual.connection = RunService.RenderStepped:Connect(function(deltaTime)
		local token = RuntimeProfiler.Begin("Client/BombController/ProjectileVisual")
		BombProjectileVisualMotion.Step(visual, deltaTime, path, startedAt, context.getServerTime())
		RuntimeProfiler.End("Client/BombController/ProjectileVisual", token)
	end)

	local cleanupDelay = lifetime + BombConfig.ProjectileLifetimePadding + (if customProjectile then 10 else 0)
	task.delay(cleanupDelay, function()
		BombProjectileVisualRuntime.Destroy(controller, projectileId)
	end)
end

function BombProjectileVisualRuntime.HandleSnapshot(controller, context, payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end
	if payload.customProjectile ~= true then
		return
	end
	if typeof(payload.position) ~= "Vector3" then
		return
	end

	local projectileId = payload.projectileId
	local visual = controller._projectileVisuals[projectileId]
	if not visual then
		BombProjectileVisualRuntime.PlayThrowEffect(controller, context, {
			player = payload.player,
			projectileId = projectileId,
			customProjectile = true,
			position = payload.position,
			velocity = if typeof(payload.velocity) == "Vector3" then payload.velocity else Vector3.zero,
			acceleration = Vector3.new(0, -workspace.Gravity, 0),
			startedAt = if typeof(payload.serverTime) == "number" then payload.serverTime else context.getServerTime(),
			fuseStartedAt = if typeof(payload.serverTime) == "number" then payload.serverTime else context.getServerTime(),
			remainingFuse = if typeof(payload.remainingFuse) == "number" then payload.remainingFuse else BombConfig.FuseSeconds,
			bombSkinId = payload.bombSkinId,
			visuals = payload.visuals,
			ownerUserId = payload.ownerUserId,
			ownerTeam = payload.ownerTeam,
		})
		visual = controller._projectileVisuals[projectileId]
		if not visual then
			return
		end
	end

	if typeof(payload.visuals) == "table" then
		visual.visuals = payload.visuals
	end
	applyOwnerPulseColor(visual, payload)
	syncAbilityVisual(visual)
	syncBaseVisual(visual)

	if payload.physicalProjectile then
		if BombProjectileVisualRuntime.TransferToPhysical(controller, context, projectileId, payload.physicalProjectile) then
			return
		end
		BombProjectileVisualRuntime.RetryTransferToPhysical(controller, context, projectileId, payload.physicalProjectile)
	end

	BombProjectileVisualState.ApplySnapshot(visual, payload, context.getServerTime())
	BombFusePulse.Update(visual, getPulseStyle, context.getServerTime())
end

function BombProjectileVisualRuntime.HandleAttach(controller, context, payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end
	if payload.customProjectile ~= true or typeof(payload.position) ~= "Vector3" then
		return
	end

	local projectileId = payload.projectileId
	local visual = controller._projectileVisuals[projectileId]
	if not visual then
		BombProjectileVisualRuntime.PlayThrowEffect(controller, context, {
			player = payload.player,
			projectileId = projectileId,
			customProjectile = true,
			position = payload.position,
			velocity = Vector3.zero,
			acceleration = Vector3.zero,
			startedAt = if typeof(payload.serverTime) == "number" then payload.serverTime else context.getServerTime(),
			fuseStartedAt = if typeof(payload.serverTime) == "number" then payload.serverTime else context.getServerTime(),
			remainingFuse = if typeof(payload.remainingFuse) == "number" then payload.remainingFuse else BombConfig.FuseSeconds,
			bombSkinId = payload.bombSkinId,
			visuals = payload.visuals,
			ownerUserId = payload.ownerUserId,
			ownerTeam = payload.ownerTeam,
		})
		visual = controller._projectileVisuals[projectileId]
		if not visual then
			return
		end
	end

	if typeof(payload.visuals) == "table" then
		visual.visuals = payload.visuals
	end
	applyOwnerPulseColor(visual, payload)
	syncAbilityVisual(visual)
	syncBaseVisual(visual)
	BombProjectileVisualState.ApplyAttach(visual, payload)
	BombProjectileVisualMotion.SetCFrame(
		visual,
		payload.position,
		if typeof(payload.normal) == "Vector3" then payload.normal else Vector3.yAxis,
		visual.spin
	)
	BombImpactEffects.PlayImpact(payload.position)
end

function BombProjectileVisualRuntime.HandleSettle(controller, payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end
	if payload.customProjectile ~= true or typeof(payload.position) ~= "Vector3" then
		return
	end

	local visual = controller._projectileVisuals[payload.projectileId]
	if visual then
		BombProjectileVisualState.ApplySettle(visual, payload.position)
	end
end

function BombProjectileVisualRuntime.HandleDestroy(controller, payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end

	BombProjectileVisualRuntime.Destroy(controller, payload.projectileId)
end

function BombProjectileVisualRuntime.HandleImpact(controller, context, payload)
	if typeof(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local projectileId = payload.projectileId
	if typeof(projectileId) == "string" then
		if payload.customProjectile == true then
			if payload.physicalProjectile then
				if BombProjectileVisualRuntime.TransferToPhysical(controller, context, projectileId, payload.physicalProjectile) then
					BombImpactEffects.PlayImpact(payload.position)
					return
				end
				BombProjectileVisualRuntime.RetryTransferToPhysical(controller, context, projectileId, payload.physicalProjectile)
			end

			local visual = controller._projectileVisuals[projectileId]
			if visual then
				BombProjectileVisualState.ApplyImpact(visual, payload)
			end
			BombImpactEffects.PlayImpact(payload.position)
			return
		end

		local transferred = BombProjectileVisualRuntime.TransferToPhysical(controller, context, projectileId, payload.physicalProjectile)
		if not transferred then
			BombProjectileVisualRuntime.Destroy(controller, projectileId)
		end
	end

	BombImpactEffects.PlayImpact(payload.position)
end

function BombProjectileVisualRuntime.HandleBurrowStart(controller, payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local visual = controller._projectileVisuals[payload.projectileId]
	local color = BombProjectileVisualMotion.GetVisualColor(visual, "highlightColor", Color3.fromRGB(255, 207, 84))
	if visual then
		BombProjectileVisualState.ApplyBurrowStart(visual, payload)
	end
	BombImpactEffects.PlayDrillPulse(payload.position, (tonumber(payload.radius) or 4.5) * 1.8, color, 0.18)
end

function BombProjectileVisualRuntime.HandleBurrowStep(controller, payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local visual = controller._projectileVisuals[payload.projectileId]
	local color = BombProjectileVisualMotion.GetVisualColor(visual, "highlightColor", Color3.fromRGB(255, 207, 84))
	if visual then
		BombProjectileVisualState.ApplyBurrowStep(visual, payload)
	end

	local lastPosition = if typeof(payload.lastPosition) == "Vector3" then payload.lastPosition else payload.position
	BombImpactEffects.PlayDrillTrail(lastPosition, payload.position, tonumber(payload.radius) or 2.4, color)
end

function BombProjectileVisualRuntime.HandleBurrowEnd(controller, payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end

	local visual = controller._projectileVisuals[payload.projectileId]
	if visual then
		BombProjectileVisualState.ApplyBurrowEnd(visual)
	end
	if typeof(payload.position) == "Vector3" then
		local color = BombProjectileVisualMotion.GetVisualColor(visual, "highlightColor", Color3.fromRGB(255, 207, 84))
		BombImpactEffects.PlayDrillPulse(payload.position, 5.5, color, 0.14)
	end
end

return table.freeze(BombProjectileVisualRuntime)
