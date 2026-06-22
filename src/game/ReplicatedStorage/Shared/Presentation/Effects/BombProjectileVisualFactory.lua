local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)

local BombProjectileVisualFactory = {}

local function prepareProjectileInstance(instance: Instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanQuery = false
		instance.CanTouch = false
	end
end

function BombProjectileVisualFactory.Create(parent: Instance, projectileId: string, skinId: any, visualScale: number?)
	local resolvedSkinId = BombSkinConfig.NormalizeSkinId(skinId)
	if resolvedSkinId == "" then
		resolvedSkinId = BombSkinConfig.DefaultSkinId
	end

	local resolvedVisualScale = math.max(tonumber(visualScale) or BombConfig.ProjectileVisualScale, 0.05)
	local visualName = "BombProjectile_" .. projectileId
	local instance, rootPart = BombVisualUtil.CreateBombVisual(resolvedSkinId, visualName, {
		anchored = false,
		canCollide = false,
		canQuery = false,
		massless = true,
		effectState = {
			vfx = true,
			fuseSpark = true,
			trail = true,
		},
		visualScale = resolvedVisualScale,
	})

	if not rootPart then
		instance:Destroy()
		return nil
	end

	instance.Name = visualName
	if instance:IsA("Model") then
		instance.PrimaryPart = rootPart
	end

	prepareProjectileInstance(instance)
	instance.Parent = parent

	return {
		instance = instance,
		rootPart = rootPart,
		connection = nil,
		path = nil,
		customProjectile = false,
		position = nil,
		velocity = nil,
		targetPosition = nil,
		targetVelocity = nil,
		targetAcceleration = nil,
		targetUpdatedAt = nil,
		acceleration = nil,
		settled = false,
		spin = 0,
		spinLocked = false,
		ownsInstance = true,
		skinId = resolvedSkinId,
		highlight = nil,
		pulseConnection = nil,
		handoffConnection = nil,
		handoffPhysical = nil,
		fuseStartedAt = nil,
		fuseEndsAt = nil,
		abilityVisualOverlay = nil,
		frozen = false,
		frozenUntil = nil,
		visuals = nil,
		visualScale = resolvedVisualScale,
		burrowing = false,
		timeScale = 1,
		targetTimeScale = 1,
	}
end

return table.freeze(BombProjectileVisualFactory)
