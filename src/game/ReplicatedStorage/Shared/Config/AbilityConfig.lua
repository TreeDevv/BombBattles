local BombConfig = require(script.Parent.BombConfig)

local AbilityConfig = {}

export type AbilitySlot = "Offensive" | "Defensive"
export type AbilityId = string
export type MessageType = string
export type InventoryAction = string
export type AbilityReplicatedState = { [string]: any }

export type AbilityDefinition = {
	id: AbilityId,
	displayName: string,
	inventoryTextStyleKey: string?,
	description: string,
	slot: AbilitySlot,
	icon: string,
	price: number,
	catalogOrder: number?,
	cooldownSeconds: number,
	durationSeconds: number,
	maxClientMessagesPerSecond: number,
	hookPriority: number,
	placeholder: boolean,
	behaviorId: string?,
	assetPath: { string }?,
	replicatedState: AbilityReplicatedState,
	[string]: any,
}

export type AbilitySlotState = {
	abilityId: AbilityId,
	cooldownEndsAt: number,
	activeEndsAt: number,
	charges: number,
	state: AbilityReplicatedState,
}

export type AbilityState = {
	slots: { [string]: AbilitySlotState },
	lastActivatedAt: number,
}

export type AbilityLoadout = { [string]: AbilityId }

export type AbilityRequest = {
	slot: AbilitySlot,
	abilityId: AbilityId?,
	messageType: MessageType,
	payload: any?,
	clientSequence: number?,
}

export type AbilityEffectPayload = {
	player: Player?,
	slot: AbilitySlot?,
	abilityId: AbilityId?,
	startedAt: number?,
	activeEndsAt: number?,
	payload: any?,
	[string]: any,
}

AbilityConfig.Scope = "AbilityState_1"
AbilityConfig.RemotesFolderName = "Remotes"
AbilityConfig.RequestRemoteName = "AbilityRequest"
AbilityConfig.EffectRemoteName = "AbilityEffect"
AbilityConfig.InventoryRequestRemoteName = "AbilityInventoryRequest"

AbilityConfig.MessageTypes = table.freeze({
	Activate = "Activate",
	Intent = "Intent",
	Cancel = "Cancel",
})

AbilityConfig.InventoryActions = table.freeze({
	Buy = "Buy",
	Equip = "Equip",
	Unequip = "Unequip",
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
	[AbilityConfig.Slots.Defensive] = "",
})

AbilityConfig.GlobalMaxMessagesPerSecond = 40
AbilityConfig.DefaultMaxMessagesPerSecond = 20
AbilityConfig.MaxMessageTypeLength = 48
AbilityConfig.MaxAbilityIdLength = 64
AbilityConfig.MaxInventoryActionLength = 32

local function inferDescription(displayName: string, slot: string): string
	local name = if displayName ~= "" then displayName else "Skill"
	local lowerName = string.lower(name)

	if slot == AbilityConfig.Slots.Offensive then
		if string.find(lowerName, "freeze", 1, true) then
			return ("%s slows enemies down with a chilling bomb effect."):format(name)
		elseif string.find(lowerName, "fast", 1, true) or string.find(lowerName, "fuse", 1, true) then
			return ("%s speeds up your pressure with a faster explosive threat."):format(name)
		elseif string.find(lowerName, "bouncy", 1, true) then
			return ("%s sends an explosive bouncing through awkward angles."):format(name)
		elseif string.find(lowerName, "sticky", 1, true) then
			return ("%s sticks pressure to a target area before it detonates."):format(name)
		elseif string.find(lowerName, "triple", 1, true) then
			return ("%s adds extra throws for wider offensive coverage."):format(name)
		elseif string.find(lowerName, "wind", 1, true) then
			return ("%s uses gusting force to disrupt enemy positioning."):format(name)
		elseif string.find(lowerName, "cluster", 1, true) then
			return ("%s breaks one attack into multiple explosive threats."):format(name)
		elseif string.find(lowerName, "drill", 1, true) then
			return ("%s punches pressure through cover and tight spaces."):format(name)
		elseif string.find(lowerName, "crater", 1, true) then
			return ("%s creates a heavy blast that controls the ground around it."):format(name)
		elseif string.find(lowerName, "landmine", 1, true) then
			return ("%s sets a hidden trap for enemies who step too close."):format(name)
		elseif string.find(lowerName, "fire", 1, true) then
			return ("%s adds burning pressure to deny enemy space."):format(name)
		elseif string.find(lowerName, "acid", 1, true) then
			return ("%s weakens an area with corrosive bomb pressure."):format(name)
		elseif string.find(lowerName, "black hole", 1, true) then
			return ("%s pulls enemies into a dangerous burst of gravity."):format(name)
		elseif string.find(lowerName, "orbital", 1, true) then
			return ("%s calls in a high-impact strike from above."):format(name)
		elseif string.find(lowerName, "charge", 1, true) then
			return ("%s rewards timing with a stronger explosive attack."):format(name)
		elseif string.find(lowerName, "bullet", 1, true) then
			return ("%s gives you a quick straight-line offensive option."):format(name)
		elseif string.find(lowerName, "fat", 1, true) or string.find(lowerName, "mega", 1, true) then
			return ("%s hits with a larger, heavier explosive threat."):format(name)
		end

		return ("%s helps pressure enemies and control space."):format(name)
	end

	if string.find(lowerName, "platform", 1, true) then
		return ("%s creates footing when you need safer positioning."):format(name)
	elseif string.find(lowerName, "shock", 1, true) then
		return ("%s softens explosive impact and helps you recover."):format(name)
	elseif string.find(lowerName, "wall", 1, true) then
		return ("%s creates cover to block pressure and shape the fight."):format(name)
	elseif string.find(lowerName, "gravity boots", 1, true) then
		return ("%s helps you stay mobile when gravity is working against you."):format(name)
	elseif string.find(lowerName, "jump", 1, true) then
		return ("%s launches you into a better defensive position."):format(name)
	elseif string.find(lowerName, "reflect", 1, true) then
		return ("%s turns incoming pressure back toward attackers."):format(name)
	elseif string.find(lowerName, "grapple", 1, true) then
		return ("%s pulls you quickly into a safer angle."):format(name)
	elseif string.find(lowerName, "absorb", 1, true) then
		return ("%s soaks up incoming danger before it overwhelms you."):format(name)
	elseif string.find(lowerName, "forcefield", 1, true) then
		return ("%s protects you with a temporary defensive bubble."):format(name)
	elseif string.find(lowerName, "magnet", 1, true) then
		return ("%s manipulates nearby threats before they reach you."):format(name)
	elseif string.find(lowerName, "gravity field", 1, true) then
		return ("%s bends movement around you to create breathing room."):format(name)
	elseif string.find(lowerName, "interceptor", 1, true) then
		return ("%s catches incoming danger before it lands."):format(name)
	elseif string.find(lowerName, "phase", 1, true) then
		return ("%s helps you slip out of a dangerous moment."):format(name)
	elseif string.find(lowerName, "time", 1, true) then
		return ("%s buys a moment of control when pressure spikes."):format(name)
	elseif string.find(lowerName, "emergency", 1, true) then
		return ("%s gives you quick cover when the fight turns bad."):format(name)
	elseif string.find(lowerName, "infinity", 1, true) then
		return ("%s gives you a high-end defensive answer in desperate fights."):format(name)
	end

	return ("%s helps protect you and create room to recover."):format(name)
end

local function withAssetId(assetId: string): string
	return "rbxassetid://" .. assetId
end

local function freezeCopy(value: { [any]: any })
	local copy = {}
	for key, child in pairs(value) do
		copy[key] = child
	end
	return table.freeze(copy)
end

local function buildDefinition(base, extra)
	local definition = {
		id = base.id,
		displayName = base.displayName,
		inventoryTextStyleKey = base.inventoryTextStyleKey,
		description = base.description or inferDescription(base.displayName or base.id or "Skill", base.slot),
		slot = base.slot,
		icon = withAssetId(base.iconAssetId),
		price = 0,
		catalogOrder = base.catalogOrder,
		cooldownSeconds = 0,
		durationSeconds = 0,
		maxClientMessagesPerSecond = AbilityConfig.DefaultMaxMessagesPerSecond,
		hookPriority = 0,
		placeholder = true,
		replicatedState = table.freeze({}),
	}

	for key, child in pairs(extra or {}) do
		definition[key] = child
	end

	return table.freeze(definition)
end

local defensiveCatalog = table.freeze({
	{ id = "Platform", displayName = "Platform", inventoryTextStyleKey = "PLATFORM", iconAssetId = "136711676098196" },
	{ id = "ShockAbsorber", displayName = "Shock Absorber", inventoryTextStyleKey = "SHOCK ABSORBER", iconAssetId = "123448923536833" },
	{ id = "AirBurst", displayName = "Air Burst", inventoryTextStyleKey = "AIR BURST", iconAssetId = "102527130035875" },
	{ id = "WallBuilder", displayName = "Wall Builder", inventoryTextStyleKey = "WALL BUILDER", iconAssetId = "99917097857374" },
	{ id = "GravityBoots", displayName = "Gravity Boots", inventoryTextStyleKey = "GRAVITY BOOTS", iconAssetId = "118223481948750" },
	{ id = "JumpPad", displayName = "Jump Pad", inventoryTextStyleKey = "JUMP PAD", iconAssetId = "94430024974597" },
	{ id = "ReflectShield", displayName = "Reflect Shield", inventoryTextStyleKey = "REFLECT SHIELD", iconAssetId = "81786411633013" },
	{ id = "GrappleHook", displayName = "Grapple Hook", inventoryTextStyleKey = "GRAPPLE HOOK", iconAssetId = "138804107751870" },
	{ id = "AbsorbShield", displayName = "Absorb Shield", inventoryTextStyleKey = "ABSORB SHIELD", iconAssetId = "71290366504096" },
	{ id = "Forcefield", displayName = "Forcefield", inventoryTextStyleKey = "FORCEFIELD", iconAssetId = "110089912251144" },
	{ id = "MagnetField", displayName = "Magnet Field", inventoryTextStyleKey = "MAGNET FIELD", iconAssetId = "76796507061068" },
	{ id = "GravityField", displayName = "Gravity Field", inventoryTextStyleKey = "GRAVITY FIELD", iconAssetId = "109821507935776" },
	{ id = "Interceptor", displayName = "Interceptor", inventoryTextStyleKey = "INTERCEPTOR", iconAssetId = "79843637066587" },
	{ id = "PhaseShift", displayName = "Phase Shift", inventoryTextStyleKey = "PHASE SHIFT", iconAssetId = "122467077922018" },
	{ id = "TimeBubble", displayName = "Time Bubble", inventoryTextStyleKey = "TIME BUBBLE", iconAssetId = "104620160269817" },
	{ id = "EmergencyFort", displayName = "Emergency Fort", inventoryTextStyleKey = "EMERGENCY FORT", iconAssetId = "136442923429012" },
	{ id = "Infinity", displayName = "Infinity", inventoryTextStyleKey = "INFINITY", iconAssetId = "89714242677283" },
})

local offensiveCatalog = table.freeze({
	{ id = "MegaBomb", displayName = "Mega Bomb", inventoryTextStyleKey = "MEGA BOMB", iconAssetId = "96568708901988" },
	{ id = "FastFuse", displayName = "Fast Fuse", inventoryTextStyleKey = "FAST FUSE", iconAssetId = "101539939321604" },
	{ id = "FreezeTnt", displayName = "Freeze TNT", inventoryTextStyleKey = "FREEZE TNT", iconAssetId = "129593234492271" },
	{ id = "BouncyBomb", displayName = "Bouncy Bomb", inventoryTextStyleKey = "BOUNCY BOMB", iconAssetId = "79076393049373" },
	{ id = "StickyBomb", displayName = "Sticky Bomb", inventoryTextStyleKey = "STICKY BOMB", iconAssetId = "130263139096586" },
	{ id = "TripleToss", displayName = "Triple Toss", inventoryTextStyleKey = "TRIPLE TOSS", iconAssetId = "84968276752634" },
	{ id = "WindBomb", displayName = "Wind Bomb", inventoryTextStyleKey = "WIND BOMB", iconAssetId = "115504590407893" },
	{ id = "Cluster", displayName = "Cluster", inventoryTextStyleKey = "CLUSTER", iconAssetId = "127189274614463" },
	{ id = "DrillBomb", displayName = "Drill Bomb", inventoryTextStyleKey = "DRILL BOMB", iconAssetId = "113945182909581" },
	{ id = "CraterBomb", displayName = "Crater Bomb", inventoryTextStyleKey = "CRATER BOMB", iconAssetId = "130648918506468" },
	{ id = "MineBomb", displayName = "Mine Bomb", inventoryTextStyleKey = "MINE BOMB", iconAssetId = "73014603414011" },
	{ id = "FireBomb", displayName = "Fire Bomb", inventoryTextStyleKey = "FIRE BOMB", iconAssetId = "113159868521055" },
	{ id = "AcidBomb", displayName = "Acid Bomb", inventoryTextStyleKey = "ACID BOMB", iconAssetId = "134306933274769" },
	{ id = "BlackHole", displayName = "Black Hole", inventoryTextStyleKey = "BLACK HOLE", iconAssetId = "118863030065458" },
	{ id = "OrbitalStrike", displayName = "Orbital Strike", inventoryTextStyleKey = "ORBITAL STRIKE", iconAssetId = "126795105864753" },
	{ id = "ChargeBomb", displayName = "Charge Bomb", inventoryTextStyleKey = "CHARGE BOMB", iconAssetId = "103666350250021" },
	{ id = "Bullet", displayName = "Bullet Bomb", inventoryTextStyleKey = "BULLET", iconAssetId = "86783291245906" },
	{ id = "FatBomb", displayName = "Fat Bomb", inventoryTextStyleKey = "FAT BOMB", iconAssetId = "114118294331662" },
})

local extraDefinitions = {
	Platform = {
		description = "Create a temporary emergency landing platform beneath you.",
		rarity = "Epic",
		cooldownSeconds = 14,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 8,
		platformSize = Vector3.new(7.5, 0.72, 7.5),
		verticalOffset = 2.45,
		fastFallSpeedThreshold = -60,
		fastFallTopOffset = 2.05,
		floorProbeUp = 1.5,
		floorProbeDown = 7,
		floorClearance = 0.08,
		minFloorNormalY = 0.55,
		overlapClearance = 0.12,
		fallbackStep = 1.7,
		allowEmergencyFallbackPlacement = true,
		lifetimeSeconds = 6.5,
		warningLeadSeconds = 1.1,
		growthSeconds = 0.1,
		fadeSeconds = 0.28,
		startHeight = 0.06,
		bounceScale = 1.025,
		bounceOutSeconds = 0.06,
		bounceBackSeconds = 0.09,
		stabilizedDownwardSpeed = -6,
		stabilizedMaxHorizontalSpeed = 34,
		predictedDownwardSpeed = -4,
		predictedHorizontalDamping = 0.58,
		predictedMaxHorizontalSpeed = 28,
		predictedPadLifetimeSeconds = 0.75,
		predictedPadTransparency = 0.78,
		stabilizeHorizontalDamping = 0.7,
		stabilizeDurationSeconds = 0.55,
		stabilizeTickSeconds = 0.05,
		rescueTickHorizontalDamping = 0.82,
		snapDownwardSpeedThreshold = -38,
		rootRescueHeight = 3.05,
		rescueHorizontalDamping = 0.45,
		rescueMaxHorizontalSpeed = 26,
		rescueUpwardVelocity = 4,
		airControlMinAirTime = 0.18,
		cleanupOnOwnerDeath = true,
		touchEffectCooldown = 0.45,
		color = Color3.fromRGB(96, 222, 255),
		topColor = Color3.fromRGB(235, 252, 255),
		supportColor = Color3.fromRGB(141, 255, 198),
		warningColor = Color3.fromRGB(255, 236, 117),
		failColor = Color3.fromRGB(255, 86, 86),
		transparency = 0.12,
		placeVisualSeconds = 0.18,
		touchVisualRadius = 2.6,
		touchVisualSeconds = 0.16,
		warningVisualRadius = 4.4,
		warningVisualSeconds = 0.22,
		despawnVisualRadius = 3.5,
		despawnVisualSeconds = 0.2,
		failVisualRadius = 3,
		placeholder = false,
		replicatedState = table.freeze({
			platformCount = 0,
			lastPlacedAt = 0,
		}),
	},

	AirBurst = {
		description = "Instantly launch yourself upward to escape danger.",
		cooldownSeconds = 10,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 8,
		verticalVelocity = 80,
		airControlSource = "AirBurst",
		airControlMinAirTime = 0.24,
		visualDurationSeconds = 0.28,
		visualStartRadius = 1.8,
		visualEndRadius = 7,
		visualThickness = 0.12,
		visualColor = Color3.fromRGB(132, 221, 255),
		placeholder = false,
		replicatedState = table.freeze({
			activationCount = 0,
			lastActivatedAt = 0,
		}),
	},

	FastFuse = {
		description = "Hold to aim a bomb that detonates much faster than normal.",
		rarity = "Common",
		cooldownSeconds = 8,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = 2,
		placeholder = false,
		replicatedState = table.freeze({
			fastFusesThrown = 0,
			lastActivatedAt = 0,
		}),
	},

	FreezeTnt = {
		description = "Throw a bomb that bursts into freezing energy and slows enemies caught in the chill.",
		rarity = "Common",
		behaviorId = "FreezeBomb",
		cooldownSeconds = 12,
		durationSeconds = BombConfig.FuseSeconds + BombConfig.ProjectileLifetimePadding + 4,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		assetPath = table.freeze({ "Assets", "Abilities", "FreezeBomb", "Freeze" }),
		zoneVfxAssetPath = table.freeze({ "Assets", "Abilities", "FreezeBomb", "Freeze" }),
		travelVfxAssetPath = table.freeze({ "Assets", "Abilities", "FreezeBomb", "IceBomb" }),
		impactVfxAssetPath = table.freeze({ "Assets", "Abilities", "FreezeBomb", "IceBomb", "Impact" }),
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = BombConfig.FuseSeconds,
		previewColor = Color3.fromRGB(91, 226, 255),
		freezeSlowMultiplier = 0.6,
		freezeSlowDurationSeconds = 2.5,
		freezeZoneDurationSeconds = 4,
		freezeZoneTickSeconds = 0.25,
		freezeVisualCleanupSeconds = 4,
		impactVisualCleanupSeconds = 3,
		freezeHighlightColor = Color3.fromRGB(91, 226, 255),
		placeholder = false,
		replicatedState = table.freeze({
			freezeBombsThrown = 0,
			freezeZonesCreated = 0,
			lastActivatedAt = 0,
		}),
	},

	GrappleHook = {
		description = "Zip to walls or pull enemies toward you with a fired hook.",
		cooldownSeconds = 10,
		durationSeconds = 1.5,
		maxClientMessagesPerSecond = 10,
		assetPath = table.freeze({ "Assets", "Abilities", "GrappleHook", "Hook" }),
		maxRange = 350,
		projectileSpeed = 375,
		hookTravelMaxSeconds = 0.65,
		missCooldownSeconds = 2,
		minAnchorDistance = 8,
		playerPullSpeed = 128,
		playerMinPullSpeed = 58,
		playerMaxPullSpeed = 138,
		playerPullAcceleration = 195,
		playerSteerAcceleration = 82,
		playerMaxSteerSpeed = 28,
		playerTangentialRetention = 0.9,
		playerMaxTangentialSpeed = 66,
		playerUpwardBias = 20,
		wallAssistMaxNormalY = 0.45,
		wallAssistStandOff = 4.5,
		wallAssistLift = 4.25,
		releaseUpwardVelocity = 46,
		releaseForwardVelocity = 72,
		releaseMomentumScale = 1,
		releaseMaxSpeed = 108,
		releaseWallKickSpeed = 30,
		releaseWallKickMaxDistance = 11,
		releaseWallKickIntoWallDot = 0.35,
		playerArrivalDistance = 7,
		playerMaxPullTime = 1.5,
		enemyPullSpeed = 95,
		enemyUpwardBias = 14,
		enemyReleaseDistance = 8,
		enemyMaxPullTime = 1,
		bombPullSpeed = 118,
		bombMinPullSpeed = 42,
		bombPullAcceleration = 180,
		bombUpwardBias = 10,
		bombReleaseDistance = 5,
		bombMaxPullTime = 1,
		damageOnEnemyHit = 20,
		enemyStunTime = 0.5,
		lineOfSightBreaksHook = true,
		airControlSource = "GrappleHook",
		airControlMinAirTime = 0.2,
		beamWidth = 0.12,
		beamVisible = false,
		beamColor = Color3.fromRGB(103, 229, 255),
		latchColor = Color3.fromRGB(133, 245, 255),
		bombBeamColor = Color3.fromRGB(255, 211, 92),
		enemyBeamColor = Color3.fromRGB(255, 95, 95),
		failColor = Color3.fromRGB(255, 86, 86),
		anchorColor = Color3.fromRGB(133, 245, 255),
		anchorMarkerSize = 0.62,
		springVisible = true,
		springColor = Color3.fromRGB(0, 0, 0),
		springCoilsTravel = 7,
		springCoilsTaut = 1,
		springRadiusTravel = 0.38,
		springRadiusTaut = 0.04,
		springThicknessTravel = 0.08,
		springThicknessTaut = 0.035,
		springDampingTravel = 0,
		springDampingTaut = 18,
		springStiffnessTravel = 35,
		springStiffnessTaut = 900,
		springRevealOnLand = false,
		springUncoilDelaySeconds = 0,
		springTautTweenSeconds = 0.16,
		latchPulseSize = 2.8,
		latchPulseSeconds = 0.2,
		failPulseSize = 2.2,
		failPulseSeconds = 0.16,
		remoteVisualDurationSeconds = 0.45,
		missVisualDurationSeconds = 0.16,
		placeholder = false,
		replicatedState = table.freeze({
			activationCount = 0,
			lastActivatedAt = 0,
		}),
	},

	GravityBoots = {
		description = "Greatly reduce knockback and gain stronger air control for a short duration.",
		cooldownSeconds = 12,
		durationSeconds = 5,
		maxClientMessagesPerSecond = 8,
		hookPriority = 0,
		knockbackMultiplier = 0.25,
		activeUntilAttribute = "GravityBoots_ActiveUntil",
		airSteeringScale = 1.4,
		airBrakeScale = 1.6,
		airGravityScaleMultiplier = 0.88,
		visualColor = Color3.fromRGB(90, 190, 255),
		visualTransparency = 0.18,
		visualFadeSeconds = 0.18,
		placeholder = false,
		replicatedState = table.freeze({
			activationCount = 0,
			lastActivatedAt = 0,
		}),
	},

	MegaBomb = {
		description = "Throw a bomb that is 2x the size and explosion.",
		rarity = "Common",
		cooldownSeconds = 16,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		megaScale = 2,
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = BombConfig.FuseSeconds,
		previewColor = BombConfig.PreviewDangerColor,
		placeholder = false,
		replicatedState = table.freeze({
			megaBombsThrown = 0,
			lastActivatedAt = 0,
		}),
	},

	BouncyBomb = {
		description = "Hold to aim a bomb that ricochets off terrain before exploding.",
		rarity = "Common",
		cooldownSeconds = 8,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		projectileLaunchSpeed = 150,
		projectileUpwardVelocity = 22,
		projectileGravityScale = 0.52,
		projectileMaxFlightSeconds = 4,
		previewColor = Color3.fromRGB(104, 236, 138),
		placeholder = false,
		replicatedState = table.freeze({
			bouncyBombsFired = 0,
			lastActivatedAt = 0,
		}),
	},

	Bullet = {
		description = "Hold to charge a fast impact bomb that flies straighter as it powers up.",
		cooldownSeconds = 8,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 12,
		fullChargeSeconds = 1.75,
		minLaunchSpeed = 150,
		maxLaunchSpeed = 320,
		maxRange = 450,
		maxFlightSeconds = 4,
		minGravityScale = 0,
		maxGravityScale = 0.52,
		minUpwardVelocity = 0,
		maxUpwardVelocity = 22,
		previewPoints = 16,
		previewColor = Color3.fromRGB(255, 228, 108),
		previewFullChargeColor = Color3.fromRGB(113, 223, 255),
		placeholder = false,
		replicatedState = table.freeze({
			shotsFired = 0,
			lastActivatedAt = 0,
		}),
	},

	ChargeBomb = {
		description = "Hold to charge a larger, stronger bomb. Taking damage cancels the charge.",
		rarity = "Divine",
		cooldownSeconds = 10,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 12,
		fullChargeSeconds = 5,
		minChargeScale = 1,
		maxChargeScale = 2.5,
		previewColor = Color3.fromRGB(255, 190, 86),
		previewFullChargeColor = Color3.fromRGB(255, 88, 66),
		placeholder = false,
		replicatedState = table.freeze({
			throws = 0,
			chargeCancels = 0,
			lastActivatedAt = 0,
			lastCancelledAt = 0,
			lastChargeScale = 1,
			lastChargeAlpha = 0,
		}),
	},

	StickyBomb = {
		description = "Throw a bomb that sticks to enemies, anchors, and terrain before detonating.",
		rarity = "Rare",
		cooldownSeconds = 12,
		durationSeconds = BombConfig.FuseSeconds + BombConfig.ProjectileLifetimePadding,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = BombConfig.FuseSeconds,
		previewColor = Color3.fromRGB(255, 211, 92),
		stickySurfaceOffset = 0.08,
		placeholder = false,
		replicatedState = table.freeze({
			stickyBombsThrown = 0,
			lastActivatedAt = 0,
		}),
	},

	TripleToss = {
		description = "Throw three bombs in a spread pattern.",
		rarity = "Rare",
		cooldownSeconds = 16,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		bombCount = 3,
		spreadDegrees = 15,
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = BombConfig.FuseSeconds,
		previewColor = BombConfig.PreviewColor,
		placeholder = false,
		replicatedState = table.freeze({
			tripleTossesThrown = 0,
			lastActivatedAt = 0,
		}),
	},

	WindBomb = {
		description = "Throw a low-damage bomb that launches enemies much farther.",
		rarity = "Rare",
		cooldownSeconds = 10,
		durationSeconds = BombConfig.FuseSeconds + BombConfig.ProjectileLifetimePadding + 1,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		assetPath = table.freeze({ "Assets", "Abilities", "WindBomb", "WindBomb" }),
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = BombConfig.FuseSeconds,
		previewColor = Color3.fromRGB(96, 221, 255),
		highlightColor = Color3.fromRGB(96, 221, 255),
		damageMultiplier = 0.5,
		knockbackMultiplier = 3,
		placeholder = false,
		replicatedState = table.freeze({
			windBombsThrown = 0,
			lastActivatedAt = 0,
		}),
	},

	Cluster = {
		description = "Throw a bomb that bursts into nine small bouncing explosives.",
		rarity = "Epic",
		cooldownSeconds = 16,
		durationSeconds = BombConfig.FuseSeconds + BombConfig.ProjectileLifetimePadding + 2,
		maxClientMessagesPerSecond = 12,
		hookPriority = 8,
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = BombConfig.FuseSeconds,
		previewColor = Color3.fromRGB(255, 160, 76),
		miniBombCount = 9,
		miniPowerScale = 0.35,
		miniFuseSeconds = 1.1,
		miniLaunchSpeed = 42,
		miniUpwardVelocity = 30,
		miniGravityScale = 0.85,
		miniRadiusScale = 0.45,
		miniVisualScale = BombConfig.ProjectileVisualScale * 0.45,
		miniSpawnYOffset = 1.25,
		miniRestitution = 0.34,
		miniFriction = 0.28,
		miniWallFriction = 0.16,
		miniGroundedFrictionPerSecond = 2,
		miniMinRollSpeed = 1.5,
		miniMinGroundImpactRollSpeed = 8,
		miniRepeatKnockbackWindowSeconds = 3,
		miniRepeatKnockbackMultiplier = 0,
		placeholder = false,
		replicatedState = table.freeze({
			clusterBombsThrown = 0,
			lastActivatedAt = 0,
		}),
	},

	FireBomb = {
		description = "Throw a bomb that leaves a burning area after exploding.",
		rarity = "Legendary",
		cooldownSeconds = 14,
		durationSeconds = BombConfig.FuseSeconds + BombConfig.ProjectileLifetimePadding + 1,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		assetPath = table.freeze({ "Assets", "Abilities", "FireBomb", "Fire" }),
		travelVfxAssetPath = table.freeze({ "Assets", "Abilities", "FireBomb", "FireBomb" }),
		impactVfxAssetPath = table.freeze({ "Assets", "Abilities", "FireBomb", "FireBomb", "Impact" }),
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = BombConfig.FuseSeconds,
		previewColor = Color3.fromRGB(255, 116, 54),
		fireDurationSeconds = 6,
		fireTickSeconds = 0.5,
		fireTickDamage = 10,
		fireVisualCleanupSeconds = 4,
		impactVisualCleanupSeconds = 3,
		placeholder = false,
		replicatedState = table.freeze({
			fireBombsThrown = 0,
			fireZonesCreated = 0,
			lastActivatedAt = 0,
		}),
	},

	AcidBomb = {
		description = "Throw a bomb that leaves acid behind, damaging enemies and blurring their vision.",
		rarity = "Legendary",
		behaviorId = "AcidBomb",
		cooldownSeconds = 14,
		durationSeconds = BombConfig.FuseSeconds + BombConfig.ProjectileLifetimePadding + 7,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		assetPath = table.freeze({ "Assets", "Abilities", "AcidBomb", "AcidFloor" }),
		zoneVfxAssetPath = table.freeze({ "Assets", "Abilities", "AcidBomb", "AcidFloor" }),
		travelVfxAssetPath = table.freeze({ "Assets", "Abilities", "AcidBomb", "AcidBomb" }),
		impactVfxAssetPath = table.freeze({ "Assets", "Abilities", "AcidBomb", "AcidBomb", "Impact" }),
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = BombConfig.FuseSeconds,
		previewColor = Color3.fromRGB(116, 255, 72),
		acidDurationSeconds = 7,
		acidTickSeconds = 0.5,
		acidTickDamage = 8,
		acidBlurDurationSeconds = 0.85,
		acidVisualCleanupSeconds = 4,
		impactVisualCleanupSeconds = 3,
		placeholder = false,
		replicatedState = table.freeze({
			acidBombsThrown = 0,
			acidZonesCreated = 0,
			lastActivatedAt = 0,
		}),
	},

	BlackHole = {
		description = "Throw a bomb that collapses into a black hole, pulling enemies and bombs inward before exploding.",
		rarity = "Mythic",
		behaviorId = "BlackHole",
		cooldownSeconds = 24,
		durationSeconds = BombConfig.FuseSeconds + BombConfig.ProjectileLifetimePadding + 5,
		maxClientMessagesPerSecond = 12,
		hookPriority = 12,
		assetPath = table.freeze({ "Assets", "Abilities", "BlackHole", "BlackHole" }),
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = BombConfig.FuseSeconds,
		previewColor = Color3.fromRGB(151, 93, 255),
		highlightColor = Color3.fromRGB(151, 93, 255),
		radius = 22,
		pullDurationSeconds = 2.6,
		pullStartLeadSeconds = 0.08,
		pullResponsiveness = 6.5,
		bombMaxPullSpeed = 105,
		bombCaptureRadius = 3,
		bombCaptureDamping = 0.56,
		playerPullSpeed = 68,
		playerMaxPullSpeed = 92,
		playerUpwardBias = 8,
		playerCaptureRadius = 4,
		visualCleanupSeconds = 4,
		explosionVisualScale = 1.12,
		placeholder = false,
		replicatedState = table.freeze({
			blackHolesThrown = 0,
			blackHolesOpened = 0,
			lastActivatedAt = 0,
		}),
	},

	OrbitalStrike = {
		description = "Marks an area for a devastating laser strike after a short delay.",
		rarity = "Divine",
		cooldownSeconds = 60,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 16,
		hookPriority = 0,
		assetPath = table.freeze({ "Assets", "Abilities", "OrbitalStrike", "Orbital Strike" }),
		strikeDelay = 1.35,
		strikeRadius = 18,
		strikeDurationSeconds = 3,
		strikeTickSeconds = 0.5,
		terrainColumnDurationSeconds = 2.5,
		terrainColumnStepScale = 0.55,
		terrainOnlyExplosionRadius = 18,
		terrainTransparentCollisionClearance = 8,
		cameraHeight = 110,
		targetFOV = 40,
		placementPanSpeed = 180,
		cameraShakeRadius = 260,
		cameraShakeMagnitude = 2.4,
		cameraShakeRoughness = 11,
		cameraShakeFadeInTime = 0.03,
		cameraShakeFadeOutTime = 0.45,
		cameraShakePositionInfluence = Vector3.new(0.18, 0.12, 0.18),
		cameraShakeRotationInfluence = Vector3.new(0.85, 0.45, 0.7),
		blackFlashRadius = 260,
		blackFlashDuration = 3,
		blackFlashHitDuration = 3,
		blackFlashClosestTransparency = 0.3,
		minFloorNormalY = 0.45,
		floorRaycastUp = 80,
		floorRaycastDown = 180,
		skyAccessRequired = true,
		warningLifetimeSeconds = 1.6,
		strikeVisualCleanupSeconds = 5,
		totalPlayerDamage = 115,
		totalCoreDamage = 0,
		placeholder = false,
		replicatedState = table.freeze({
			strikesCalled = 0,
			lastActivatedAt = 0,
		}),
	},

	CraterBomb = {
		description = "Fire a lower-damage bomb that destroys a much larger amount of terrain.",
		rarity = "Epic",
		cooldownSeconds = 12,
		durationSeconds = 6,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		projectileLaunchSpeed = 150,
		projectileUpwardVelocity = 22,
		projectileGravityScale = 0.52,
		projectileMaxFlightSeconds = 4,
		terrainRadius = 30,
		playerDamageMultiplier = 0.5,
		coreDamageMultiplier = 0.5,
		explosionVisualScale = 1.65,
		previewColor = Color3.fromRGB(255, 126, 74),
		placeholder = false,
		replicatedState = table.freeze({
			cratersFired = 0,
			lastActivatedAt = 0,
		}),
	},

	FatBomb = {
		description = "Throw a flare that calls down a giant impact after a short warning.",
		rarity = "Divine",
		cooldownSeconds = 26,
		durationSeconds = 7,
		maxClientMessagesPerSecond = 12,
		hookPriority = 12,
		assetPath = table.freeze({ "Assets", "Abilities", "FatBomb" }),
		flareVisualAssetPath = table.freeze({ "Assets", "Abilities", "FatBomb", "Flare" }),
		fallingCharacterAssetPath = table.freeze({ "Assets", "Abilities", "FatBomb", "Fat Guy" }),
		impactVfxAssetPath = table.freeze({ "Assets", "Abilities", "FatBomb", "FatImpact" }),
		projectileLaunchSpeed = BombConfig.ProjectileLaunchSpeed,
		projectileUpwardVelocity = BombConfig.ProjectileUpwardVelocity,
		projectileGravityScale = BombConfig.ProjectileGravityScale,
		projectileMaxFlightSeconds = 4.25,
		projectileFuseSeconds = 7,
		projectileVisualScale = 0.48,
		landedFlareScale = 1.15,
		fallingCharacterScale = 0.82,
		fallingSpawnHeight = 100,
		previewColor = Color3.fromRGB(255, 92, 36),
		highlightColor = Color3.fromRGB(255, 92, 36),
		flareColor = Color3.fromRGB(255, 86, 28),
		impactDelaySeconds = 1,
		revealDelaySeconds = 0.2,
		finalWarningSeconds = 0.35,
		exitSeconds = 0.18,
		damageRadius = 42,
		innerRadius = 14,
		nearRadius = 28,
		outerRadius = 42,
		terrainRadius = 32,
		forceTerrainSubtract = true,
		playerDirectDamage = 135,
		playerNearDamageMax = 110,
		playerNearDamageMin = 78,
		playerOuterDamageMax = 64,
		playerOuterDamageMin = 34,
		coreDamageMultiplier = 1.15,
		knockbackHorizontal = 170,
		knockbackVertical = 105,
		knockbackMinScale = 0.28,
		explosionVisualScale = 2.4,
		impactVfxScale = 2.4,
		impactShockwaveScale = 1.25,
		impactVisualCleanupSeconds = 6,
		cameraShakeRadius = 240,
		cameraShakeMagnitude = 3.4,
		cameraShakeRoughness = 12,
		cameraShakeFadeInTime = 0.02,
		cameraShakeFadeOutTime = 0.38,
		cameraShakePositionInfluence = Vector3.new(0.22, 0.18, 0.22),
		cameraShakeRotationInfluence = Vector3.new(1.2, 0.8, 1.1),
		placeholder = false,
		replicatedState = table.freeze({
			flaresThrown = 0,
			lastActivatedAt = 0,
		}),
	},

	DrillBomb = {
		description = "Throw a heavy bomb that drills forward through destructible cover before detonating.",
		rarity = "Epic",
		cooldownSeconds = 12,
		durationSeconds = BombConfig.FuseSeconds + BombConfig.ProjectileLifetimePadding + 6,
		maxClientMessagesPerSecond = 12,
		hookPriority = 0,
		projectileLaunchSpeed = 142,
		projectileUpwardVelocity = 18,
		projectileGravityScale = 0.52,
		projectileMaxFlightSeconds = 4,
		previewPoints = 18,
		previewColor = Color3.fromRGB(255, 198, 68),
		drillColor = Color3.fromRGB(255, 221, 86),
		drillTravelSpinRadiansPerSecond = 20,
		drillBurrowSpinRadiansPerSecond = 42,
		drillBurrowSpeed = 64,
		drillBurrowDistance = 44,
		drillBurrowDuration = 0.85,
		drillStartInset = 2.1,
		drillCarveRadius = 4.25,
		drillCarveStepDistance = 3.25,
		drillBurrowEffectInterval = 0.06,
		drillExplosionVisualScale = 1.12,
		placeholder = false,
		replicatedState = table.freeze({
			drillsFired = 0,
			lastActivatedAt = 0,
		}),
	},

	Forcefield = {
		description = "Create a short-lived bubble that repels bombs and absorbs nearby explosions.",
		cooldownSeconds = 16,
		durationSeconds = 5,
		maxClientMessagesPerSecond = 8,
		hookPriority = 10,
		behaviorId = "ForcefieldDome",
		assetPath = table.freeze({ "Assets", "Abilities", "ForcefieldDome", "Forcefield" }),
		radius = 15,
		growthSeconds = 0.22,
		fadeInSeconds = 0.18,
		fadeOutSeconds = 0.25,
		startScale = 0.01,
		repelCooldownSeconds = 0.35,
		repelLaunchSpeed = 125,
		repelUpwardVelocity = 20,
		repelMaxFlightSeconds = 2.2,
		placeholder = false,
		replicatedState = table.freeze({
			activationCount = 0,
			lastActivatedAt = 0,
		}),
	},

	MagnetField = {
		description = "Place a spherical magnet field that pulls all nearby bombs to its center.",
		rarity = "Legendary",
		cooldownSeconds = 20,
		durationSeconds = 5,
		maxClientMessagesPerSecond = 20,
		hookPriority = 5,
		assetPath = table.freeze({ "Assets", "Abilities", "MagnetField", "Magnet Field" }),
		placementDistance = 8,
		floorRaycastUp = 8,
		floorRaycastDown = 32,
		minFloorNormalY = 0.65,
		startScale = 0.01,
		growthSeconds = 0.32,
		fadeOutSeconds = 0.25,
		pulseSeconds = 0.75,
		pulseScale = 1.08,
		previewTransparency = 0.58,
		previewValidColor = Color3.fromRGB(255, 221, 76),
		previewInvalidColor = Color3.fromRGB(255, 68, 68),
		visualColor = Color3.fromRGB(255, 221, 76),
		visualTransparency = 0.18,
		highlightFillTransparency = 0.88,
		highlightOutlineTransparency = 0.18,
		radius = 15,
		pullResponsiveness = 5.5,
		maxPullSpeed = 95,
		captureRadius = 2.75,
		captureDamping = 0.68,
		placeholder = false,
		replicatedState = table.freeze({
			fieldsPlaced = 0,
			lastPlacedAt = 0,
		}),
	},

	GravityField = {
		description = "Place a spherical gravity field that forces free bombs straight down.",
		rarity = "Mythic",
		cooldownSeconds = 20,
		durationSeconds = 5,
		maxClientMessagesPerSecond = 20,
		hookPriority = 6,
		assetPath = table.freeze({ "Assets", "Abilities", "GravityField", "Gravity Field" }),
		placementDistance = 8,
		floorRaycastUp = 8,
		floorRaycastDown = 32,
		minFloorNormalY = 0.65,
		startScale = 0.01,
		growthSeconds = 0.32,
		fadeOutSeconds = 0.25,
		pulseSeconds = 0.75,
		pulseScale = 1.08,
		previewTransparency = 0.58,
		previewValidColor = Color3.fromRGB(172, 92, 255),
		previewInvalidColor = Color3.fromRGB(255, 68, 68),
		visualColor = Color3.fromRGB(172, 92, 255),
		visualTransparency = 0.18,
		highlightFillTransparency = 0.88,
		highlightOutlineTransparency = 0.18,
		radius = 15,
		dropSpeed = 120,
		maxDropSpeed = 140,
		placeholder = false,
		replicatedState = table.freeze({
			fieldsPlaced = 0,
			lastPlacedAt = 0,
		}),
	},

	PhaseShift = {
		description = "Become immune to damage and knockback for a brief moment.",
		rarity = "Mythic",
		cooldownSeconds = 18,
		durationSeconds = 1.25,
		maxClientMessagesPerSecond = 8,
		hookPriority = 30,
		blockPulseThrottleSeconds = 0.18,
		activeUntilAttribute = "PhaseShift_ActiveUntil",
		highlightDepthMode = "AlwaysOnTop",
		highlightFillTransparency = 0.38,
		highlightOutlineTransparency = 0.08,
		highlightFadeSeconds = 0.16,
		highlightPulseSeconds = 0.18,
		highlightPulseFillTransparency = 0.12,
		highlightPulseOutlineTransparency = 0,
		highlightCycleSeconds = 0.42,
		fovPunchDuration = 0.28,
		fovPunchBonus = 9,
		blockFovPunchDuration = 0.16,
		blockFovPunchBonus = 4,
		placeholder = true,
		replicatedState = table.freeze({
			activationCount = 0,
			blocks = 0,
			lastActivatedAt = 0,
			lastBlockedAt = 0,
		}),
	},

	TimeBubble = {
		description = "Generate a large bubble around yourself. Freeze bombs inside, stopping them from exploding until the time bubble is gone.",
		rarity = "Divine",
		cooldownSeconds = 28,
		durationSeconds = 5,
		maxClientMessagesPerSecond = 8,
		hookPriority = 7,
		assetPath = table.freeze({ "Assets", "Abilities", "TimeBubble", "Time Bubble" }),
		startScale = 0.01,
		growthSeconds = 0.3,
		fadeOutSeconds = 0.25,
		pulseSeconds = 0.7,
		pulseScale = 1.06,
		visualColor = Color3.fromRGB(91, 226, 255),
		visualTransparency = 0.16,
		frozenColor = Color3.fromRGB(91, 226, 255),
		radius = 18,
		placeholder = false,
		replicatedState = table.freeze({
			bubblesCreated = 0,
			lastActivatedAt = 0,
		}),
	},

	EmergencyFort = {
		description = "Instantly create a fortified bunker around yourself that can withstand several explosions.",
		rarity = "Divine",
		cooldownSeconds = 32,
		durationSeconds = 0,
		maxClientMessagesPerSecond = 8,
		hookPriority = 0,
		assetPath = table.freeze({ "Assets", "Abilities", "EmergencyFort", "Emergency Fort" }),
		floorRaycastUp = 8,
		floorRaycastDown = 32,
		minFloorNormalY = 0.65,
		fortHealth = 300,
		lifetimeSeconds = 12,
		growthSeconds = 0.16,
		fadeSeconds = 0.45,
		startHeight = 0.12,
		bounceScale = 1.04,
		bounceOutSeconds = 0.08,
		bounceBackSeconds = 0.11,
		cameraShakeRadius = 40,
		placeholder = false,
		replicatedState = table.freeze({
			fortsBuilt = 0,
			lastBuiltAt = 0,
		}),
	},

	WallBuilder = {
		description = "Preview and place a short destructible wall.",
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
		placeholder = false,
		replicatedState = table.freeze({
			wallCount = 0,
			lastPlacedAt = 0,
		}),
	},

	MineBomb = {
		description = "Place a hidden mine that springs up and explodes when enemies get close.",
		rarity = "Legendary",
		cooldownSeconds = 18,
		durationSeconds = 45,
		maxClientMessagesPerSecond = 20,
		hookPriority = 0,
		assetPath = table.freeze({ "Assets", "Abilities", "MineBomb", "Landmine" }),
		floorRaycastUp = 1,
		floorRaycastDown = 32,
		minFloorNormalY = 0.65,
		mineLifetimeSeconds = 45,
		triggerRadius = 6,
		triggerBounceSeconds = 0.8,
		triggerBounceHeight = 7,
		triggerCheckSeconds = 0.1,
		placedTransparency = 0.35,
		legendaryFillColor = Color3.fromRGB(255, 210, 76),
		legendaryOutlineColor = Color3.fromRGB(178, 92, 255),
		placeholder = false,
		replicatedState = table.freeze({
			minesPlaced = 0,
			lastPlacedAt = 0,
		}),
	},

	ReflectShield = {
		description = "Place a translucent barrier wall that reflects incoming bombs.",
		rarity = "Rare",
		cooldownSeconds = 16,
		durationSeconds = 7,
		maxClientMessagesPerSecond = 20,
		hookPriority = 15,
		assetPath = table.freeze({ "Assets", "Abilities", "ReflectShield", "Reflect Shield" }),
		placementDistance = 8,
		floorRaycastUp = 8,
		floorRaycastDown = 32,
		minFloorNormalY = 0.65,
		reflectionThickness = 3,
		reflectCooldownSeconds = 0.25,
		reflectSpeedMultiplier = 1,
		reflectMinLaunchSpeed = 70,
		reflectMaxLaunchSpeed = 190,
		reflectUpwardVelocity = 0,
		reflectMaxFlightSeconds = BombConfig.ProjectileMaxFlightSeconds,
		reflectSurfaceOffset = 1.15,
		growthSeconds = 0.28,
		fadeOutSeconds = 0.25,
		meshStartScaleX = 0.01,
		previewTransparency = 0.5,
		previewValidColor = Color3.fromRGB(76, 255, 97),
		previewInvalidColor = Color3.fromRGB(255, 68, 68),
		placeholder = false,
		replicatedState = table.freeze({
			shieldsPlaced = 0,
			lastPlacedAt = 0,
		}),
	},

	Interceptor = {
		description = "Place a short-lived interceptor that destroys bombs inside its bubble.",
		cooldownSeconds = 20,
		durationSeconds = 8,
		maxClientMessagesPerSecond = 20,
		hookPriority = 20,
		assetPath = table.freeze({ "Assets", "Abilities", "Interceptor", "Interceptor" }),
		placementDistance = 8,
		floorRaycastUp = 8,
		floorRaycastDown = 32,
		minFloorNormalY = 0.65,
		growthSeconds = 0.22,
		fadeInSeconds = 0.18,
		fadeOutSeconds = 0.25,
		startScale = 0.01,
		previewTransparency = 0.5,
		previewValidColor = Color3.fromRGB(76, 255, 97),
		previewInvalidColor = Color3.fromRGB(255, 68, 68),
		cameraShakeRadius = 45,
		placeholder = false,
		replicatedState = table.freeze({
			interceptorsPlaced = 0,
			lastPlacedAt = 0,
		}),
	},
}

local definitions = {}
local slotCatalog = {
	[AbilityConfig.Slots.Offensive] = {},
	[AbilityConfig.Slots.Defensive] = {},
}

local function registerCatalog(catalog, slot: string)
	for index, entry in ipairs(catalog) do
		local base = freezeCopy({
			id = entry.id,
			displayName = entry.displayName,
			inventoryTextStyleKey = entry.inventoryTextStyleKey,
			iconAssetId = entry.iconAssetId,
			slot = slot,
			catalogOrder = index,
		})
		definitions[entry.id] = buildDefinition(base, extraDefinitions[entry.id])
		table.insert(slotCatalog[slot], entry.id)
	end
end

registerCatalog(offensiveCatalog, AbilityConfig.Slots.Offensive)
registerCatalog(defensiveCatalog, AbilityConfig.Slots.Defensive)

definitions.DebugPulse = table.freeze({
	id = "DebugPulse",
	displayName = "Debug Pulse",
	description = "Framework test ability with cooldown, replicated state, and client effect routing.",
	slot = AbilityConfig.Slots.Defensive,
	icon = "",
	price = 0,
	cooldownSeconds = 3,
	durationSeconds = 0.35,
	maxClientMessagesPerSecond = 20,
	hookPriority = 0,
	placeholder = false,
	replicatedState = table.freeze({
		pulseCount = 0,
		lastActivatedAt = 0,
	}),
})

AbilityConfig.Aliases = table.freeze({
	ForcefieldDome = "Forcefield",
	Landmine = "MineBomb",
})

AbilityConfig.Definitions = table.freeze(definitions)
AbilityConfig.Catalog = table.freeze({
	[AbilityConfig.Slots.Offensive] = table.freeze(slotCatalog[AbilityConfig.Slots.Offensive]),
	[AbilityConfig.Slots.Defensive] = table.freeze(slotCatalog[AbilityConfig.Slots.Defensive]),
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

function AbilityConfig.NormalizeAbilityId(abilityId: any): string
	if typeof(abilityId) ~= "string" or abilityId == "" then
		return ""
	end

	return AbilityConfig.Aliases[abilityId] or abilityId
end

function AbilityConfig.GetDefinition(abilityId: any)
	local normalizedAbilityId = AbilityConfig.NormalizeAbilityId(abilityId)
	if normalizedAbilityId == "" then
		return nil
	end

	return AbilityConfig.Definitions[normalizedAbilityId]
end

function AbilityConfig.GetBehaviorId(abilityId: any): string
	local definition = AbilityConfig.GetDefinition(abilityId)
	if definition and typeof(definition.behaviorId) == "string" and definition.behaviorId ~= "" then
		return definition.behaviorId
	end

	return AbilityConfig.NormalizeAbilityId(abilityId)
end

function AbilityConfig.GetSlotAbility(loadout, slot: string): string
	local abilityId = if typeof(loadout) == "table" and typeof(loadout[slot]) == "string"
		then AbilityConfig.NormalizeAbilityId(loadout[slot])
		else AbilityConfig.DefaultLoadout[slot] or ""

	if abilityId == "" then
		return ""
	end

	local definition = AbilityConfig.GetDefinition(abilityId)
	return if definition and definition.slot == slot then definition.id else ""
end

function AbilityConfig.BuildSlotState(slot: string, abilityId: string?)
	local resolvedAbilityId = AbilityConfig.GetSlotAbility({ [slot] = abilityId or "" }, slot)
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

function AbilityConfig.IsCatalogAbility(abilityId: any, slot: string?): boolean
	local definition = AbilityConfig.GetDefinition(abilityId)
	if not definition or typeof(definition.catalogOrder) ~= "number" then
		return false
	end
	return slot == nil or definition.slot == slot
end

function AbilityConfig.GetCatalogIds(slot: string): { string }
	local source = AbilityConfig.Catalog[slot]
	if typeof(source) ~= "table" then
		return {}
	end

	local ids = table.clone(source)
	table.sort(ids, function(leftId, rightId)
		local left = AbilityConfig.GetDefinition(leftId)
		local right = AbilityConfig.GetDefinition(rightId)
		local leftPrice = if left then tonumber(left.price) or 0 else 0
		local rightPrice = if right then tonumber(right.price) or 0 else 0

		if leftPrice == rightPrice then
			local leftOrder = if left then tonumber(left.catalogOrder) or 0 else 0
			local rightOrder = if right then tonumber(right.catalogOrder) or 0 else 0
			return leftOrder < rightOrder
		end

		return leftPrice < rightPrice
	end)

	return ids
end

return table.freeze(AbilityConfig)
