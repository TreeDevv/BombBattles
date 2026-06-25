local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local BombFusePulse = require(ReplicatedStorage.Shared.Effects.BombFusePulse)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local BombProjectileVisualHandoff = {}

local HANDOFF_SECONDS = 0.14
local HANDOFF_MAX_SECONDS = 0.28

local function smoothstep(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * (3 - 2 * alpha)
end

function BombProjectileVisualHandoff.SetLocalTransparency(instance: Instance?, alpha: number)
	if not instance then
		return
	end

	alpha = math.clamp(alpha, 0, 1)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = alpha
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = alpha
		end
	end
end

local function pivotInstanceToCFrame(instance: Instance, rootPart: BasePart, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	else
		rootPart.CFrame = cframe
	end
end

local function getServerTime(options): number
	local callback = options and options.getServerTime
	if typeof(callback) == "function" then
		return callback()
	end
	return workspace:GetServerTimeNow()
end

local function syncAbilityVisual(options, visual)
	local callback = options and options.syncAbilityVisual
	if typeof(callback) == "function" then
		callback(visual)
	end
end

local function syncBaseVisual(options, visual)
	local callback = options and options.syncBaseVisual
	if typeof(callback) == "function" then
		callback(visual)
	end
end

local function syncAudio(options, visual)
	local callback = options and options.syncAudio
	if typeof(callback) == "function" then
		callback(visual)
	end
end

local function getPulseStyle(options, visual)
	local callback = options and options.getPulseStyle
	if typeof(callback) == "function" then
		return callback(visual)
	end
	return {
		baseColor = BombConfig.PulseWhite,
		pulseColor = BombConfig.PulseRed,
		fillStart = BombConfig.PulseStartFillTransparency,
		outlineStart = BombConfig.PulseStartOutlineTransparency,
	}
end

local function startPulse(options, visual, projectile: Instance)
	local now = getServerTime(options)
	BombFusePulse.Start(
		visual,
		projectile,
		visual.fuseStartedAt or now,
		visual.fuseEndsAt or (now + BombConfig.ProjectileLifetimePadding),
		function(pulseVisual)
			return getPulseStyle(options, pulseVisual)
		end
	)
end

local function finalizeHandoff(visual, projectile: Instance, rootPart: BasePart, options)
	visual.instance = projectile
	visual.rootPart = rootPart
	visual.path = nil
	visual.ownsInstance = false
	syncAbilityVisual(options, visual)
	startPulse(options, visual, projectile)
	visual.handoffPhysical = nil
	visual.position = rootPart.Position
	visual.velocity = rootPart.AssemblyLinearVelocity
	visual.targetPosition = visual.position
	visual.targetVelocity = visual.velocity
	RuntimeProfiler.Count("Client/BombController/ProjectilePhysicalHandoffCompleted")
	syncAudio(options, visual)
	syncBaseVisual(options, visual)
end

function BombProjectileVisualHandoff.Attach(visual, projectile: Instance, rootPart: BasePart, options): boolean
	if visual.instance == projectile and visual.ownsInstance == false then
		return true
	end

	if visual.handoffConnection then
		return true
	end

	local airborneInstance = visual.instance
	local airborneRootPart = visual.rootPart
	if not (visual.ownsInstance and airborneInstance and airborneInstance.Parent and airborneRootPart and airborneRootPart.Parent) then
		visual.instance = projectile
		visual.rootPart = rootPart
		visual.path = nil
		visual.ownsInstance = false
		syncAbilityVisual(options, visual)
		BombProjectileVisualHandoff.SetLocalTransparency(projectile, 0)
		syncBaseVisual(options, visual)
		BombVisualUtil.SetEffectState(projectile, {
			vfx = true,
			fuseSpark = true,
			trail = true,
		})
		startPulse(options, visual, projectile)
		syncAudio(options, visual)
		syncBaseVisual(options, visual)
		return true
	end

	visual.handoffPhysical = projectile
	RuntimeProfiler.Count("Client/BombController/ProjectilePhysicalHandoffStarted")
	BombProjectileVisualHandoff.SetLocalTransparency(projectile, 1)
	BombVisualUtil.SetEffectState(projectile, {
		vfx = false,
		fuseSpark = false,
		trail = false,
	})

	local startCFrame = airborneRootPart.CFrame
	local elapsed = 0
	visual.handoffConnection = RunService.RenderStepped:Connect(function(deltaTime)
		if not (projectile.Parent and rootPart.Parent and airborneInstance.Parent and airborneRootPart.Parent) then
			if visual.handoffConnection then
				visual.handoffConnection:Disconnect()
				visual.handoffConnection = nil
			end
			BombProjectileVisualHandoff.SetLocalTransparency(projectile, 0)
			visual.handoffPhysical = nil
			RuntimeProfiler.Count("Client/BombController/ProjectilePhysicalHandoffFailed")
			return
		end

		elapsed += math.max(deltaTime, 0)
		local alpha = smoothstep(elapsed / HANDOFF_SECONDS)
		local physicalCFrame = rootPart.CFrame
		local blendedCFrame = startCFrame:Lerp(physicalCFrame, alpha)
		pivotInstanceToCFrame(airborneInstance, airborneRootPart, blendedCFrame)
		BombProjectileVisualHandoff.SetLocalTransparency(airborneInstance, alpha)
		BombProjectileVisualHandoff.SetLocalTransparency(projectile, 1 - alpha)

		if alpha >= 1 or elapsed >= HANDOFF_MAX_SECONDS then
			if visual.handoffConnection then
				visual.handoffConnection:Disconnect()
				visual.handoffConnection = nil
			end
			if visual.connection then
				visual.connection:Disconnect()
				visual.connection = nil
			end

			BombVisualUtil.SetEffectState(projectile, {
				vfx = true,
				fuseSpark = true,
				trail = true,
			})
			if airborneInstance.Parent then
				airborneInstance:Destroy()
			end

			finalizeHandoff(visual, projectile, rootPart, options)
		end
	end)

	local skinId = BombSkinConfig.NormalizeSkinId(projectile:GetAttribute("BombSkinId"))
	if skinId ~= "" then
		visual.skinId = skinId
	end
	return true
end

return table.freeze(BombProjectileVisualHandoff)
