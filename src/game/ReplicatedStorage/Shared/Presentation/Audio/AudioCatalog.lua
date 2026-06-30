local AudioCatalog = {}

local SOUND_FOLDER_PATH = table.freeze({ "Assets", "Sounds" })
local THROW_SOUND_NAMES = table.freeze({ "BB THrow v1", "BB THrow v2" })

local aliases = {
	DefaultExplosion = "BB Normal Explosion",
	NormalExplosion = "BB Normal Explosion",

	BombTick = "BB Bomb Tick",
	JumpPadActivate = "BB Place Jumppad",
	JumpPadPlace = "BB Place Jumppad",
	JumpPadArm = "BB Place Jumppad",
	JumpPadTrigger = "BB Air Burst",
	GrappleHookFire = "BB Grapple",
	GrappleHookLatch = "BB Grapple",
	GrappleHookBomb = "BB Grapple",
	GrappleHookRelease = "BB Grapple",
	PlatformActivate = "BB Air Burst",
	PlatformPlace = "BB Air Burst",
	PlatformLand = "BB Air Burst",

	MineBombInstall = "BB Tripmine Install",
	MineBombExplosion = "BB Tripmine Explosion",
	BlackHoleSummon = "BB Blackhole Summon",
	BlackHoleExplosion = "BB Blackhole Explosion",
	OrbitalStrike = "BB Orbital Strike",
	ChargeBomb = "BB Charge",
	AcidBomb = "BB Acid",
	FreezeBomb = "BB Freeze TNT",
	FireBomb = "BB Fire Linger",
	TimeBubble = "BB Time Bubble",
	MagnetField = "BB Magnet Hum",
	Forcefield = "BB Forcefield",
	ReflectShield = "BB Reflect Shield",
	AbsorbShield = "BB Absorb Shield",
	ShockAbsorber = "BB Shock Absorber",
	Interceptor = "BB Interceptor",
	InfinityAura = "BB Infinity Aura",
	InfinityActivate = "BB Infinity Activate",
	AirBurst = "BB Air Burst",
	PhaseShift = "BB Phase Shift",
	GravityBootsEquip = "BB Gravity Boots Equip",
	HeavenFireImpact = "BB Cutscene Fire Explosion 1",
}

local explosionSoundsBySkinId = {
	Default = { "BB Normal Explosion" },
	Red = { "BB Normal Explosion" },
	Blue = { "BB Normal Explosion" },
	Gold = { "BB Normal Explosion" },
	Rusty = { "BB Normal Explosion" },
	Toy = { "BB Normal Explosion" },
	TNT = { "BB Normal Explosion" },
	Cannonball = { "BB Normal Explosion" },
	WaterBalloon = { "BB Waterballoon", "BB Water Bomb Ballon" },
	Paint = { "BB Paint Bomb", "BB paint" },
	Smoke = { "BB Smoke Bomb" },
	Firework = { "BB Fireworks" },
	Beehive = { "BB Beehive" },
	Chicken = { "BB Chicken" },
	Pizza = { "BB Pizza" },
	Snowball = { "BB Snow or Ice" },
	Slime = { "BB Slime" },
	Disco = { "BB Disco" },
	RubberDuck = { "BB Duck" },
	Pumpkin = { "BB Pumpkin" },
	Meteor = { "BB Meteor" },
	Ghost = { "BB GHost" },
	Shark = { "BB Shark" },
	TreasureChest = { "BB Treasure", "BB Treasure (1)", "BB Treasure Coins" },
	UFO = { "BB Normal Explosion" },
	FatGuy = { "BB Fat Bomb" },
	HollowPurple = { "BB Blackhole Explosion" },
	EventHorizon = { "BB Blackhole Explosion" },
	Nuke = { "BB Normal Explosion" },
}

local abilityEventCues = {
	Activated = {
		AirBurst = { soundName = "BB Air Burst", mode = "LocalOrCharacter" },
		AbsorbShield = { soundName = "BB Absorb Shield", mode = "LocalOrCharacter" },
		Forcefield = { soundName = "BB Forcefield", mode = "LocalOrCharacter" },
		GravityBoots = { soundName = "BB Gravity Boots Equip", mode = "Local" },
		Infinity = { soundName = "BB Infinity Activate", mode = "LocalOrCharacter" },
		PhaseShift = { soundName = "BB Phase Shift", mode = "LocalOrCharacter" },
		ShockAbsorber = { soundName = "BB Shock Absorber", mode = "LocalOrCharacter" },
	},

	AcidBombAreaStarted = {
		AcidBomb = { soundName = "BB Acid", mode = "Position", loop = true, durationKey = "durationSeconds" },
	},
	BlackHoleStarted = {
		BlackHole = { soundName = "BB Blackhole Summon", mode = "Position" },
	},
	FatBombImpact = {
		FatBomb = { soundName = "BB Fat Bomb", mode = "Position" },
	},
	HeavenFireImpact = {
		HeavenFire = { soundName = "BB Cutscene Fire Explosion 1", mode = "Position" },
	},
	MineBombPlaced = {
		MineBomb = { soundName = "BB Tripmine Install", mode = "Position" },
	},
	OrbitalStrikeTelegraph = {
		OrbitalStrike = { soundName = "BB Orbital Strike", mode = "Position" },
	},
	OrbitalStrikeImpact = {
		OrbitalStrike = { soundName = "BB Orbital Strike", mode = "Position" },
	},
	ReflectShieldPlaced = {
		ReflectShield = { soundName = "BB Reflect Shield", mode = "Position" },
	},
	ReflectShieldReflected = {
		ReflectShield = { soundName = "BB Reflect Shield", mode = "Position" },
	},
	TimeBubbleCreated = {
		TimeBubble = { soundName = "BB Time Bubble", mode = "Position", loop = true, durationKey = "durationSeconds" },
	},
	WindBombImpact = {
		WindBomb = { soundName = "BB Air Burst", mode = "Position" },
	},
	AbsorbShieldAbsorbed = {
		AbsorbShield = { soundName = "BB Absorb Shield", mode = "LocalOrCharacter" },
	},
	PhaseShiftBlocked = {
		PhaseShift = { soundName = "BB Phase Shift", mode = "LocalOrCharacter" },
	},
}

local function cloneArray(source: { string }?): { string }
	local copy = {}
	for _, value in ipairs(source or {}) do
		table.insert(copy, value)
	end
	return copy
end

function AudioCatalog.GetSoundFolderPath(): { string }
	return cloneArray(SOUND_FOLDER_PATH)
end

function AudioCatalog.GetThrowSoundNames(): { string }
	return cloneArray(THROW_SOUND_NAMES)
end

function AudioCatalog.ResolveName(soundName: any): string
	if typeof(soundName) ~= "string" or soundName == "" then
		return ""
	end

	return aliases[soundName] or soundName
end

function AudioCatalog.GetExplosionSoundNames(skinId: any): { string }
	local names = if typeof(skinId) == "string" then explosionSoundsBySkinId[skinId] else nil
	if not names then
		names = explosionSoundsBySkinId.Default
	end
	return cloneArray(names)
end

function AudioCatalog.GetAbilityEventCue(effectName: any, abilityId: any)
	if typeof(effectName) ~= "string" or typeof(abilityId) ~= "string" then
		return nil
	end

	local byAbility = abilityEventCues[effectName]
	if typeof(byAbility) ~= "table" then
		return nil
	end

	return byAbility[abilityId]
end

return table.freeze(AudioCatalog)
