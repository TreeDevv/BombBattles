local BombConfig = require(script.Parent.Parent.Config.BombConfig)
local ProjectilePhysics = require(script.Parent.ProjectilePhysics)

local BombProjectileConfig = {}

BombProjectileConfig.Enabled = true
BombProjectileConfig.BombType = {
	Normal = "NormalBomb",
	Bouncy = "BouncyBomb",
}

BombProjectileConfig.SnapshotHz = 20
BombProjectileConfig.FixedStepSeconds = 1 / 60
BombProjectileConfig.MaxStepsPerHeartbeat = 6
BombProjectileConfig.MaxSubstepDistance = 8
BombProjectileConfig.ProjectileLifetimePadding = BombConfig.ProjectileLifetimePadding

local BOUNCY_PHYSICS = table.freeze({
	radius = BombConfig.SweepRadius,
	gravity = workspace.Gravity * BombConfig.ProjectileGravityScale,
	postImpactGravity = workspace.Gravity * BombConfig.ProjectileGravityScale,
	launchSpeed = BombConfig.ProjectileLaunchSpeed,
	upwardVelocity = BombConfig.ProjectileUpwardVelocity,
	maxSpeed = 180,
	impactResponse = ProjectilePhysics.ImpactResponse.Bounce,
	restitution = 0.42,
	friction = 0.18,
	wallFriction = 0.08,
	floorNormalY = 0.58,
	settleNormalY = 0.68,
	settleSpeed = 9,
	settleHorizontalSpeed = 7,
	minBounceSpeed = 3,
	sandbagHorizontalScale = 0.2,
	sandbagMaxHorizontalSpeed = 16,
	sandbagDownwardVelocity = 18,
	surfaceOffset = 0.035,
	groundedFrictionPerSecond = 0.35,
	minRollSpeed = 2.5,
	minGroundImpactRollSpeed = 0,
	maxCollisionsPerStep = 3,
})

local NORMAL_PHYSICS = table.freeze({
	radius = BombConfig.SweepRadius,
	gravity = workspace.Gravity * BombConfig.ProjectileGravityScale,
	postImpactGravity = workspace.Gravity * 1.35,
	launchSpeed = BombConfig.ProjectileLaunchSpeed,
	upwardVelocity = BombConfig.ProjectileUpwardVelocity,
	maxSpeed = 180,
	impactResponse = ProjectilePhysics.ImpactResponse.Sandbag,
	restitution = 0,
	friction = 0.78,
	wallFriction = 0.68,
	floorNormalY = 0.58,
	settleNormalY = 0.68,
	settleSpeed = 90,
	settleHorizontalSpeed = 2.5,
	minBounceSpeed = 0.15,
	sandbagHorizontalScale = 0.82,
	sandbagMaxHorizontalSpeed = 22,
	sandbagDownwardVelocity = 18,
	surfaceOffset = 0.035,
	groundedFrictionPerSecond = 0.8,
	minRollSpeed = 1.25,
	minGroundImpactRollSpeed = 14,
	maxCollisionsPerStep = 3,
})

BombProjectileConfig.Defaults = table.freeze({
	radius = BOUNCY_PHYSICS.radius,
	gravity = BOUNCY_PHYSICS.gravity,
	postImpactGravity = BOUNCY_PHYSICS.postImpactGravity,
	launchSpeed = BOUNCY_PHYSICS.launchSpeed,
	upwardVelocity = BOUNCY_PHYSICS.upwardVelocity,
	maxSpeed = BOUNCY_PHYSICS.maxSpeed,
	impactResponse = BOUNCY_PHYSICS.impactResponse,
	restitution = BOUNCY_PHYSICS.restitution,
	friction = BOUNCY_PHYSICS.friction,
	wallFriction = BOUNCY_PHYSICS.wallFriction,
	floorNormalY = BOUNCY_PHYSICS.floorNormalY,
	settleNormalY = BOUNCY_PHYSICS.settleNormalY,
	settleSpeed = BOUNCY_PHYSICS.settleSpeed,
	settleHorizontalSpeed = BOUNCY_PHYSICS.settleHorizontalSpeed,
	minBounceSpeed = BOUNCY_PHYSICS.minBounceSpeed,
	sandbagHorizontalScale = BOUNCY_PHYSICS.sandbagHorizontalScale,
	sandbagMaxHorizontalSpeed = BOUNCY_PHYSICS.sandbagMaxHorizontalSpeed,
	sandbagDownwardVelocity = BOUNCY_PHYSICS.sandbagDownwardVelocity,
	surfaceOffset = BOUNCY_PHYSICS.surfaceOffset,
	groundedFrictionPerSecond = BOUNCY_PHYSICS.groundedFrictionPerSecond,
	minRollSpeed = BOUNCY_PHYSICS.minRollSpeed,
	minGroundImpactRollSpeed = BOUNCY_PHYSICS.minGroundImpactRollSpeed,
	maxCollisionsPerStep = BOUNCY_PHYSICS.maxCollisionsPerStep,
	fuseSeconds = BombConfig.FuseSeconds,
	visualSpinRadiansPerSecond = BombConfig.VisualSpinRadiansPerSecond,
})

BombProjectileConfig.BombTypes = table.freeze({
	[BombProjectileConfig.BombType.Normal] = table.freeze({
		physics = NORMAL_PHYSICS,
		fuse = table.freeze({
			seconds = BombConfig.FuseSeconds,
			explodeAfterSettled = false,
			armAfterSettled = false,
		}),
		collision = table.freeze({
			respectCanCollide = true,
			ignoreWater = true,
			directHitExplodes = false,
		}),
		explosion = table.freeze({
			innerRadius = BombConfig.InnerRadius,
			outerRadius = BombConfig.OuterRadius,
			terrainRadius = BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius,
		}),
		visuals = table.freeze({
			spinRadiansPerSecond = BombConfig.VisualSpinRadiansPerSecond,
		}),
	}),
	[BombProjectileConfig.BombType.Bouncy] = table.freeze({
		physics = BOUNCY_PHYSICS,
		fuse = table.freeze({
			seconds = BombConfig.FuseSeconds,
			explodeAfterSettled = false,
			armAfterSettled = false,
		}),
		collision = table.freeze({
			respectCanCollide = true,
			ignoreWater = true,
			directHitExplodes = false,
		}),
		explosion = table.freeze({
			innerRadius = BombConfig.InnerRadius,
			outerRadius = BombConfig.OuterRadius,
			terrainRadius = BombConfig.TerrainDestructionRadius or BombConfig.OuterRadius,
		}),
		visuals = table.freeze({
			spinRadiansPerSecond = BombConfig.VisualSpinRadiansPerSecond,
		}),
	}),
})

function BombProjectileConfig.GetBombTypeConfig(bombType: string?)
	local resolvedType = if typeof(bombType) == "string" and bombType ~= "" then bombType else BombProjectileConfig.BombType.Normal
	return BombProjectileConfig.BombTypes[resolvedType] or BombProjectileConfig.BombTypes[BombProjectileConfig.BombType.Normal]
end

return table.freeze(BombProjectileConfig)
