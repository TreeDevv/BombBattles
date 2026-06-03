local AbilityConfig = {}

AbilityConfig.Scope = "AbilityState_1"
AbilityConfig.RemotesFolderName = "Remotes"
AbilityConfig.RequestRemoteName = "AbilityRequest"
AbilityConfig.EffectRemoteName = "AbilityEffect"

AbilityConfig.MessageTypes = table.freeze({
	Activate = "Activate",
	Intent = "Intent",
	Cancel = "Cancel",
})

AbilityConfig.Slots = table.freeze({
	Offensive = "Offensive",
	Defensive = "Defensive",
})

AbilityConfig.SlotOrder = table.freeze({
	AbilityConfig.Slots.Offensive,
	AbilityConfig.Slots.Defensive,
})

AbilityConfig.DefaultLoadout = table.freeze({
	[AbilityConfig.Slots.Offensive] = "",
	[AbilityConfig.Slots.Defensive] = "ForcefieldDome",
})

AbilityConfig.GlobalMaxMessagesPerSecond = 40
AbilityConfig.DefaultMaxMessagesPerSecond = 20
AbilityConfig.MaxMessageTypeLength = 48
AbilityConfig.MaxAbilityIdLength = 64

AbilityConfig.Definitions = table.freeze({
	ForcefieldDome = table.freeze({
		id = "ForcefieldDome",
		displayName = "Forcefield Dome",
		description = "Create a short-lived bubble that repels bombs and absorbs nearby explosions.",
		slot = AbilityConfig.Slots.Defensive,
		cooldownSeconds = 16,
		durationSeconds = 5,
		maxClientMessagesPerSecond = 8,
		hookPriority = 10,
		assetPath = table.freeze({ "Assets", "Abilities", "ForcefieldDome", "ForceField" }),
		radius = 15,
		growthSeconds = 0.22,
		fadeInSeconds = 0.18,
		fadeOutSeconds = 0.25,
		startScale = 0.01,
		repelCooldownSeconds = 0.35,
		repelLaunchSpeed = 125,
		repelUpwardVelocity = 20,
		repelMaxFlightSeconds = 2.2,
		replicatedState = table.freeze({
			activationCount = 0,
			lastActivatedAt = 0,
		}),
	}),

	WallBuilder = table.freeze({
		id = "WallBuilder",
		displayName = "Wall Builder",
		description = "Preview and place a short destructible wall.",
		slot = AbilityConfig.Slots.Defensive,
		cooldownSeconds = 8,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 20,
		hookPriority = 0,
		assetPath = table.freeze({ "Assets", "Abilities", "WallBuilder", "Wall" }),
		placementDistance = 8,
		floorRaycastUp = 8,
		floorRaycastDown = 32,
		minFloorNormalY = 0.65,
		lifetimeSeconds = 25,
		growthSeconds = 0.35,
		fadeSeconds = 0.45,
		bounceScale = 1.05,
		bounceOutSeconds = 0.09,
		bounceBackSeconds = 0.12,
		startHeight = 0.1,
		previewTransparency = 0.5,
		previewValidColor = Color3.fromRGB(76, 255, 97),
		previewInvalidColor = Color3.fromRGB(255, 68, 68),
		replicatedState = table.freeze({
			wallCount = 0,
			lastPlacedAt = 0,
		}),
	}),

	DebugPulse = table.freeze({
		id = "DebugPulse",
		displayName = "Debug Pulse",
		description = "Framework test ability with cooldown, replicated state, and client effect routing.",
		slot = AbilityConfig.Slots.Defensive,
		cooldownSeconds = 3,
		durationSeconds = 0.35,
		maxClientMessagesPerSecond = 20,
		hookPriority = 0,
		replicatedState = table.freeze({
			pulseCount = 0,
			lastActivatedAt = 0,
		}),
	}),
})

local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		copy[key] = deepCopy(child)
	end
	return copy
end

function AbilityConfig.IsKnownSlot(slot: any): boolean
	return slot == AbilityConfig.Slots.Offensive or slot == AbilityConfig.Slots.Defensive
end

function AbilityConfig.GetDefinition(abilityId: any)
	if typeof(abilityId) ~= "string" or abilityId == "" then
		return nil
	end

	return AbilityConfig.Definitions[abilityId]
end

function AbilityConfig.GetSlotAbility(loadout, slot: string): string
	if typeof(loadout) == "table" and typeof(loadout[slot]) == "string" then
		return loadout[slot]
	end

	return AbilityConfig.DefaultLoadout[slot] or ""
end

function AbilityConfig.BuildSlotState(slot: string, abilityId: string?)
	local resolvedAbilityId = if typeof(abilityId) == "string" then abilityId else AbilityConfig.GetSlotAbility(nil, slot)
	local definition = AbilityConfig.GetDefinition(resolvedAbilityId)

	return {
		abilityId = resolvedAbilityId,
		cooldownEndsAt = 0,
		activeEndsAt = 0,
		charges = 0,
		state = if definition and typeof(definition.replicatedState) == "table" then deepCopy(definition.replicatedState) else {},
	}
end

function AbilityConfig.BuildInitialState(loadout)
	local slots = {}

	for _, slot in ipairs(AbilityConfig.SlotOrder) do
		slots[slot] = AbilityConfig.BuildSlotState(slot, AbilityConfig.GetSlotAbility(loadout, slot))
	end

	return {
		slots = slots,
		lastActivatedAt = 0,
	}
end

function AbilityConfig.CloneDefinitionState(abilityId: string)
	local definition = AbilityConfig.GetDefinition(abilityId)
	if not definition or typeof(definition.replicatedState) ~= "table" then
		return {}
	end

	return deepCopy(definition.replicatedState)
end

return table.freeze(AbilityConfig)
