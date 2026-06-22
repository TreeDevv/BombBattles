local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityVisualOverlay = require(ReplicatedStorage.Shared.Effects.AbilityVisualOverlay)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombFusePulse = require(ReplicatedStorage.Shared.Effects.BombFusePulse)
local BombHeldVisualFactory = require(ReplicatedStorage.Shared.Effects.BombHeldVisualFactory)
local BombProjectileVisualMotion = require(ReplicatedStorage.Shared.Effects.BombProjectileVisualMotion)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)

local BombHeldVisualRuntime = {}

local function syncHeldBaseVisual(controller, held)
	local replaceBase = held ~= nil
		and typeof(controller._localAbilityHeldVisualOptions) == "table"
		and controller._localAbilityHeldVisualOptions.replaceBaseVisual == true
	AbilityVisualOverlay.SyncBaseVisual(held, replaceBase)
end

local function getPulseStyle(visual): { baseColor: Color3, fillStart: number, outlineStart: number }
	return BombProjectileVisualMotion.GetPulseStyle(visual)
end

function BombHeldVisualRuntime.RefreshAbilityVisual(controller, context, player: Player)
	local held = controller._heldBombs[player]
	if not held then
		return
	end
	if player ~= context.localPlayer or typeof(controller._localAbilityHeldVisualOptions) ~= "table" then
		AbilityVisualOverlay.Destroy(held)
		syncHeldBaseVisual(controller, held)
		return
	end

	AbilityVisualOverlay.Apply(
		held,
		controller._localAbilityHeldVisualOptions.assetPath,
		controller._localAbilityHeldVisualOptions.name,
		controller._localAbilityHeldVisualOptions.disabledAttachmentName
	)

	syncHeldBaseVisual(controller, held)
end

function BombHeldVisualRuntime.Destroy(controller, player: Player)
	local held = controller._heldBombs[player]
	if held then
		BombFusePulse.Stop(held)
		AbilityVisualOverlay.Destroy(held)
	end
	if held and held.instance.Parent then
		held.instance:Destroy()
	end
	controller._heldBombs[player] = nil

	BombHeldVisualFactory.DestroyCharacterVisuals(player.Character)
end

function BombHeldVisualRuntime.Hide(controller, player: Player)
	controller._heldBombWanted[player] = nil
	controller._heldBombSkinIds[player] = nil
	controller._heldBombVisualScales[player] = nil
	controller._heldBombPulseTimes[player] = nil
	BombHeldVisualRuntime.Destroy(controller, player)
end

function BombHeldVisualRuntime.Ensure(controller, context, player: Player, attempt: number)
	if controller._heldBombWanted[player] ~= true or player.Parent ~= context.players then
		return
	end

	local held = controller._heldBombs[player]
	local skinId = controller._heldBombSkinIds[player] or context.getPlayerBombSkinId(player)
	local visualScale = math.max(tonumber(controller._heldBombVisualScales[player]) or BombConfig.HeldVisualScale, 0.05)
	if
		held
		and held.instance.Parent
		and held.skinId == skinId
		and math.abs((held.visualScale or BombConfig.HeldVisualScale) - visualScale) <= 0.075
	then
		BombHeldVisualRuntime.RefreshAbilityVisual(controller, context, player)
		syncHeldBaseVisual(controller, held)
		return
	end
	BombHeldVisualRuntime.Destroy(controller, player)

	local character = player.Character
	if not character then
		if attempt < context.maxAttachAttempts then
			task.delay(context.attachRetrySeconds, function()
				BombHeldVisualRuntime.Ensure(controller, context, player, attempt + 1)
			end)
		end
		return
	end

	held = BombHeldVisualFactory.Create(character, skinId, visualScale)
	if not held then
		if attempt < context.maxAttachAttempts then
			task.delay(context.attachRetrySeconds, function()
				BombHeldVisualRuntime.Ensure(controller, context, player, attempt + 1)
			end)
		end
		return
	end
	controller._heldBombs[player] = held
	BombHeldVisualRuntime.RefreshAbilityVisual(controller, context, player)

	local pulseTimes = controller._heldBombPulseTimes[player]
	if pulseTimes then
		BombFusePulse.Start(held, held.instance, pulseTimes.fuseStartedAt, pulseTimes.fuseEndsAt, getPulseStyle)
		syncHeldBaseVisual(controller, held)
	end
end

function BombHeldVisualRuntime.Show(controller, context, player: Player, skinId: any?)
	controller._heldBombWanted[player] = true
	local resolvedSkinId = BombSkinConfig.NormalizeSkinId(skinId)
	controller._heldBombSkinIds[player] = if resolvedSkinId ~= "" then resolvedSkinId else context.getPlayerBombSkinId(player)
	BombHeldVisualRuntime.Ensure(controller, context, player, 0)
end

function BombHeldVisualRuntime.SetEffects(controller, player: Player, fuseSpark: boolean, trail: boolean)
	local held = controller._heldBombs[player]
	if not held then
		return
	end

	BombVisualUtil.SetEffectState(held.instance, {
		vfx = true,
		fuseSpark = fuseSpark,
		trail = trail,
	})
	syncHeldBaseVisual(controller, held)
end

function BombHeldVisualRuntime.SetLocalVisualScale(controller, context, scale: number)
	local visualScale = math.max(tonumber(scale) or 1, 0.05) * BombConfig.HeldVisualScale
	controller._heldBombVisualScales[context.localPlayer] = visualScale
	if controller._heldBombWanted[context.localPlayer] == true then
		BombHeldVisualRuntime.Ensure(controller, context, context.localPlayer, 0)
	end
end

function BombHeldVisualRuntime.ResetLocalVisualScale(controller, context)
	controller._heldBombVisualScales[context.localPlayer] = nil
	if controller._heldBombWanted[context.localPlayer] == true then
		BombHeldVisualRuntime.Ensure(controller, context, context.localPlayer, 0)
	end
end

function BombHeldVisualRuntime.SetLocalAbilityVisual(controller, context, options)
	controller._localAbilityHeldVisualOptions = if typeof(options) == "table" then options else nil
	BombHeldVisualRuntime.RefreshAbilityVisual(controller, context, context.localPlayer)
end

function BombHeldVisualRuntime.ClearLocalAbilityVisual(controller, context)
	controller._localAbilityHeldVisualOptions = nil
	BombHeldVisualRuntime.RefreshAbilityVisual(controller, context, context.localPlayer)
end

function BombHeldVisualRuntime.StartPulse(controller, context, player: Player, startedAt: number?, fuseSeconds: number?)
	local fuseStartedAt = if typeof(startedAt) == "number" then startedAt else context.getServerTime()
	local duration = if typeof(fuseSeconds) == "number" then math.max(fuseSeconds, 0.001) else BombConfig.FuseSeconds
	local fuseEndsAt = fuseStartedAt + duration

	controller._heldBombPulseTimes[player] = {
		fuseStartedAt = fuseStartedAt,
		fuseEndsAt = fuseEndsAt,
	}

	local held = controller._heldBombs[player]
	if held and held.instance.Parent then
		BombFusePulse.Start(held, held.instance, fuseStartedAt, fuseEndsAt, getPulseStyle)
		BombHeldVisualRuntime.SetEffects(controller, player, true, false)
		syncHeldBaseVisual(controller, held)
	end
end

return table.freeze(BombHeldVisualRuntime)
