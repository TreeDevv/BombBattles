local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local InstanceUtil = require(ReplicatedStorage.Shared.Common.InstanceUtil)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)

local HipBombVisual = {}
HipBombVisual.__index = HipBombVisual

local DEFAULT_CONFIG = BombConfig.HipCarry or {}
local BOMB_WELD_NAME = "BombHipWeld"
local BOMB_SKIN_VISUAL_NAME = "BombSkinVisual"
local BOMB_VISUAL_ROOT_NAME = "BombVisualRoot"
local EPSILON = 1e-4
local DEFAULT_PHYSICS_CONFIG = {
	Enabled = false,
	BobName = "BombHipBob",
	AnchorAttachmentName = "BombHipAnchor",
	BobAttachmentName = "BombHipBobAttachment",
	SocketName = "BombHipSocket",
	WeldName = "BombHipPhysicsWeld",
	HangLength = 0.72,
	BobSize = Vector3.new(0.18, 0.18, 0.18),
	BobDensity = 0.45,
	BobFriction = 0.7,
	BobElasticity = 0,
	UpperAngleDegrees = 34,
	TwistLowerAngleDegrees = -18,
	TwistUpperAngleDegrees = 18,
	MaxFrictionTorque = 0.08,
	LinearDamping = 1.7,
	AngularDamping = 3.2,
	AccelerationSideKickScale = 0.014,
	AccelerationBackKickScale = 0.014,
	VelocitySideKickScale = 0.035,
	VelocityBackKickScale = 0.035,
	MaxKickSpeed = 7,
	MaxLinearSpeed = 70,
	MaxAngularSpeed = 24,
}

local function getConfigValue(name: string, fallback)
	local value = DEFAULT_CONFIG[name]
	return if value ~= nil then value else fallback
end

local function getPhysicsConfig()
	local config = DEFAULT_CONFIG.Physics
	return if typeof(config) == "table" then config else DEFAULT_PHYSICS_CONFIG
end

local function getPhysicsValue(name: string, fallback)
	local config = getPhysicsConfig()
	local value = config[name]
	if value ~= nil then
		return value
	end
	return DEFAULT_PHYSICS_CONFIG[name] or fallback
end

local function shouldUsePhysics(options): boolean
	if typeof(options) == "table" then
		local mode = options.mode
		if mode == "animated" or mode == "motor" then
			return false
		elseif mode == "physics" then
			return true
		end
	end

	return getPhysicsValue("Enabled", false) == true
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function clampNumber(value: number, minValue: number, maxValue: number): number
	return math.clamp(if isFiniteNumber(value) then value else 0, minValue, maxValue)
end

local function clampVector(vector: Vector3, limits: Vector3): Vector3
	return Vector3.new(
		clampNumber(vector.X, -limits.X, limits.X),
		clampNumber(vector.Y, -limits.Y, limits.Y),
		clampNumber(vector.Z, -limits.Z, limits.Z)
	)
end

local function stepSpring(current: Vector3, velocity: Vector3, target: Vector3, stiffness: number, damping: number, dt: number): (Vector3, Vector3)
	local force = (target - current) * math.max(stiffness, 0)
	local dampedVelocity = velocity * math.max(damping, 0)
	local nextVelocity = velocity + ((force - dampedVelocity) * dt)
	local nextCurrent = current + (nextVelocity * dt)
	return nextCurrent, nextVelocity
end

local function getFirstBasePart(instance: Instance?): BasePart?
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local getBaseParts = InstanceUtil.GetBaseParts

local function getCarrierPart(character: Model): BasePart?
	local lowerTorso = character:FindFirstChild("LowerTorso")
	if lowerTorso and lowerTorso:IsA("BasePart") then
		return lowerTorso
	end

	local torso = character:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		return torso
	end

	local upperTorso = character:FindFirstChild("UpperTorso")
	return if upperTorso and upperTorso:IsA("BasePart") then upperTorso else nil
end

local function createBombInstance(template: Instance?, skinId: any): (Instance, BasePart?, string?)
	if template then
		local clone = template:Clone()
		local rootPart = getFirstBasePart(clone)
		BombVisualUtil.SetEffectState(clone, {
			vfx = true,
			fuseSpark = false,
			trail = false,
		})
		return clone, rootPart, nil
	end

	local model, rootPart, resolvedSkinId = BombVisualUtil.CreateBombVisual(skinId, getConfigValue("VisualName", "BombHipVisual"), {
		anchored = false,
		canCollide = false,
		canQuery = false,
		massless = true,
		effectState = {
			vfx = true,
			fuseSpark = false,
			trail = false,
		},
	})
	return model, rootPart, resolvedSkinId
end

local function scaleInstance(instance: Instance, rootPart: BasePart, scale: number)
	if scale <= 0 or math.abs(scale - 1) <= EPSILON then
		return
	end

	if instance:IsA("Model") then
		local ok = pcall(function()
			instance:ScaleTo(scale)
		end)
		if ok then
			return
		end
	end

	local rootCFrame = rootPart.CFrame
	for _, part in ipairs(getBaseParts(instance)) do
		local relative = rootCFrame:ToObjectSpace(part.CFrame)
		local rotationOnly = relative - relative.Position
		part.Size *= scale
		part.CFrame = rootCFrame * CFrame.new(relative.Position * scale) * rotationOnly
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("Attachment") then
			descendant.Position *= scale
		end
	end
end

local function prepareBombParts(instance: Instance, rootPart: BasePart)
	for _, part in ipairs(getBaseParts(instance)) do
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true

		if part ~= rootPart then
			local weld = Instance.new("WeldConstraint")
			weld.Name = BOMB_WELD_NAME
			weld.Part0 = rootPart
			weld.Part1 = part
			weld.Parent = rootPart
		end
	end
end

local function getVisibleSkinRoot(instance: Instance): Instance
	local visual = instance:FindFirstChild(BOMB_SKIN_VISUAL_NAME)
	return visual or instance
end

local function getVisibleHalfWidth(instance: Instance, rootPart: BasePart): number?
	local visibleRoot = getVisibleSkinRoot(instance)
	local minX = math.huge
	local maxX = -math.huge

	for _, part in ipairs(getBaseParts(visibleRoot)) do
		if not (part == rootPart and part.Name == BOMB_VISUAL_ROOT_NAME) then
			local localCFrame = rootPart.CFrame:ToObjectSpace(part.CFrame)
			local halfSize = part.Size * 0.5

			for signX = -1, 1, 2 do
				for signY = -1, 1, 2 do
					for signZ = -1, 1, 2 do
						local point = localCFrame
							* Vector3.new(halfSize.X * signX, halfSize.Y * signY, halfSize.Z * signZ)
						minX = math.min(minX, point.X)
						maxX = math.max(maxX, point.X)
					end
				end
			end
		end
	end

	if minX == math.huge or maxX == -math.huge then
		return nil
	end

	return math.max(math.abs(minX), math.abs(maxX))
end

local function withTranslationX(cframe: CFrame, x: number): CFrame
	local position = cframe.Position
	local rotation = cframe - position
	return CFrame.new(x, position.Y, position.Z) * rotation
end

local function resolveBaseOffset(instance: Instance, rootPart: BasePart, baseOffset: CFrame): CFrame
	if getConfigValue("DynamicXOffsetEnabled", false) ~= true then
		return baseOffset
	end

	local visibleHalfWidth = getVisibleHalfWidth(instance, rootPart)
	local referenceHalfWidth = getConfigValue("ReferenceHalfWidth", nil)
	if not (isFiniteNumber(visibleHalfWidth) and isFiniteNumber(referenceHalfWidth)) then
		return baseOffset
	end

	local extraOffset = math.max(visibleHalfWidth - referenceHalfWidth, 0)
	if extraOffset <= EPSILON then
		return baseOffset
	end

	return withTranslationX(baseOffset, baseOffset.Position.X + extraOffset)
end

local function setAssemblyVelocity(part: BasePart, linearVelocity: Vector3, angularVelocity: Vector3)
	part.AssemblyLinearVelocity = linearVelocity
	part.AssemblyAngularVelocity = angularVelocity
end

local function setInstanceVisible(instance: Instance, visible: boolean)
	for _, part in ipairs(getBaseParts(instance)) do
		part.LocalTransparencyModifier = if visible then 0 else 1
	end
end

local function getLinearVelocity(state): Vector3
	if typeof(state) ~= "table" then
		return Vector3.zero
	end
	local velocity = state.linearVelocity
	return if typeof(velocity) == "Vector3" then velocity else Vector3.zero
end

local function getCFrameBasis(state, carrierPart: BasePart?): CFrame?
	if typeof(state) == "table" and typeof(state.cframe) == "CFrame" then
		return state.cframe
	end
	return if carrierPart then carrierPart.CFrame else nil
end

local function getStateMultiplier(state): number
	if typeof(state) ~= "table" then
		return 1
	end

	local multiplier = 1
	if state.sliding == true then
		multiplier *= getConfigValue("SlideMultiplier", 1.2)
	elseif state.sprinting == true then
		multiplier *= getConfigValue("SprintMultiplier", 1.1)
	end
	if state.grounded == false then
		multiplier *= getConfigValue("AirMultiplier", 1.15)
	end
	local landingRecoveryAlpha = state.landingRecoveryAlpha
	if isFiniteNumber(landingRecoveryAlpha) and landingRecoveryAlpha > 0 then
		local landingMultiplier = getConfigValue("LandingMultiplier", 1.12)
		multiplier *= 1 + ((landingMultiplier - 1) * math.clamp(landingRecoveryAlpha, 0, 1))
	end

	return multiplier
end

local function getLandingAlpha(state): number
	if typeof(state) ~= "table" then
		return 0
	end

	local landingRecoveryAlpha = state.landingRecoveryAlpha
	return if isFiniteNumber(landingRecoveryAlpha) then math.clamp(landingRecoveryAlpha, 0, 1) else 0
end

local function createPhysicsRig(character: Model, carrierPart: BasePart, rootPart: BasePart, baseOffset: CFrame)
	local hangLength = math.max(getPhysicsValue("HangLength", 0.32), 0.05)
	local initialCFrame = carrierPart.CFrame * baseOffset
	local anchorCFrame = baseOffset * CFrame.new(0, hangLength, 0)

	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Name = getPhysicsValue("AnchorAttachmentName", "BombHipAnchor")
	anchorAttachment.CFrame = anchorCFrame
	anchorAttachment.Parent = carrierPart

	local bobPart = Instance.new("Part")
	bobPart.Name = getPhysicsValue("BobName", "BombHipBob")
	bobPart.Size = getPhysicsValue("BobSize", Vector3.new(0.18, 0.18, 0.18))
	bobPart.Transparency = 1
	bobPart.Anchored = false
	bobPart.CanCollide = false
	bobPart.CanQuery = false
	bobPart.CanTouch = false
	bobPart.Massless = false
	bobPart.CFrame = initialCFrame
	bobPart.CustomPhysicalProperties = PhysicalProperties.new(
		math.max(getPhysicsValue("BobDensity", 0.45), 0.01),
		math.clamp(getPhysicsValue("BobFriction", 0.7), 0, 2),
		math.clamp(getPhysicsValue("BobElasticity", 0), 0, 1)
	)
	bobPart.Parent = character

	local bobAttachment = Instance.new("Attachment")
	bobAttachment.Name = getPhysicsValue("BobAttachmentName", "BombHipBobAttachment")
	bobAttachment.Position = Vector3.new(0, hangLength, 0)
	bobAttachment.Parent = bobPart

	local visualWeld = Instance.new("WeldConstraint")
	visualWeld.Name = getPhysicsValue("WeldName", "BombHipPhysicsWeld")
	visualWeld.Part0 = bobPart
	visualWeld.Part1 = rootPart
	visualWeld.Parent = bobPart

	local socket = Instance.new("BallSocketConstraint")
	socket.Name = getPhysicsValue("SocketName", "BombHipSocket")
	socket.Attachment0 = anchorAttachment
	socket.Attachment1 = bobAttachment
	socket.LimitsEnabled = true
	socket.UpperAngle = math.max(getPhysicsValue("UpperAngleDegrees", 34), 0)
	socket.TwistLimitsEnabled = true
	socket.TwistLowerAngle = getPhysicsValue("TwistLowerAngleDegrees", -18)
	socket.TwistUpperAngle = getPhysicsValue("TwistUpperAngleDegrees", 18)
	socket.MaxFrictionTorque = math.max(getPhysicsValue("MaxFrictionTorque", 0.08), 0)
	socket.Parent = bobPart

	setAssemblyVelocity(bobPart, carrierPart.AssemblyLinearVelocity, Vector3.zero)

	return {
		anchorAttachment = anchorAttachment,
		bobAttachment = bobAttachment,
		bobPart = bobPart,
		visualWeld = visualWeld,
		socket = socket,
		anchorCFrame = anchorCFrame,
	}
end

function HipBombVisual.new(character: Model, template: Instance?, options)
	local config = BombConfig.HipCarry
	if config and config.Enabled == false then
		return nil
	end
	if not (character and character:IsA("Model")) then
		return nil
	end

	local carrierPart = if typeof(options) == "table" and typeof(options.carrierPart) == "Instance" and options.carrierPart:IsA("BasePart")
		then options.carrierPart
		else getCarrierPart(character)
	if not carrierPart then
		return nil
	end

	local skinId = if typeof(options) == "table" then options.skinId else nil
	local instance, rootPart, resolvedSkinId = createBombInstance(template, skinId)
	if not rootPart then
		instance:Destroy()
		return nil
	end

	local scale = if typeof(options) == "table" and isFiniteNumber(options.scale)
		then math.max(options.scale, 0.05)
		else getConfigValue("Scale", 0.42)
	scaleInstance(instance, rootPart, scale)
	prepareBombParts(instance, rootPart)

	local visualName = getConfigValue("VisualName", "BombHipVisual")
	instance.Name = visualName
	if instance:IsA("Model") then
		instance.PrimaryPart = rootPart
	end

	local baseOffset = if typeof(options) == "table" and typeof(options.baseOffset) == "CFrame"
		then options.baseOffset
		else getConfigValue("BaseOffset", CFrame.new(1.25, -0.55, 0.05))
	baseOffset = resolveBaseOffset(instance, rootPart, baseOffset)
	local initialCFrame = carrierPart.CFrame * baseOffset
	if instance:IsA("Model") then
		instance:PivotTo(initialCFrame)
	else
		rootPart.CFrame = initialCFrame
	end

	instance.Parent = character

	local usePhysics = shouldUsePhysics(options)
	local motor = nil
	local physicsRig = nil
	if usePhysics then
		local ok, rig = pcall(function()
			return createPhysicsRig(character, carrierPart, rootPart, baseOffset)
		end)
		if ok and rig then
			physicsRig = rig
		else
			usePhysics = false
		end
	end
	if not usePhysics then
		motor = Instance.new("Motor6D")
		motor.Name = getConfigValue("MotorName", "BombHipMotor")
		motor.Part0 = carrierPart
		motor.Part1 = rootPart
		motor.C0 = baseOffset
		motor.C1 = CFrame.new()
		motor.Parent = carrierPart
	end

	local self = setmetatable({
		instance = instance,
		rootPart = rootPart,
		skinId = resolvedSkinId,
		carrierPart = carrierPart,
		motor = motor,
		physicsRig = physicsRig,
		physicsEnabled = usePhysics,
		baseOffset = baseOffset,
		baseC1 = CFrame.new(),
		visible = true,
		translation = Vector3.zero,
		translationVelocity = Vector3.zero,
		rotation = Vector3.zero,
		rotationVelocity = Vector3.zero,
		movementImpulseTranslation = Vector3.zero,
		movementImpulseRotation = Vector3.zero,
		lastLocalVelocity = nil,
		idleTime = 0,
		landingImpulse = 0,
		debugStepCount = 0,
	}, HipBombVisual)

	return self
end

function HipBombVisual:_stepPhysics(dt: number, state)
	local physicsRig = self.physicsRig
	local carrierPart = self.carrierPart
	local rootPart = self.rootPart
	if not (physicsRig and carrierPart and carrierPart.Parent and rootPart and rootPart.Parent) then
		return false
	end

	local bobPart = physicsRig.bobPart
	local socket = physicsRig.socket
	local anchorAttachment = physicsRig.anchorAttachment
	if not (bobPart and bobPart.Parent and socket and socket.Parent and anchorAttachment and anchorAttachment.Parent) then
		return false
	end

	local minDt = getConfigValue("MinStepSeconds", 1 / 120)
	local maxDt = getConfigValue("MaxStepSeconds", 1 / 20)
	dt = clampNumber(dt, minDt, maxDt)

	anchorAttachment.CFrame = physicsRig.anchorCFrame

	local basis = getCFrameBasis(state, carrierPart)
	local localVelocity = Vector3.zero
	local localAcceleration = Vector3.zero
	if basis then
		local worldVelocity = getLinearVelocity(state)
		local horizontalVelocity = Vector3.new(worldVelocity.X, 0, worldVelocity.Z)
		localVelocity = basis:VectorToObjectSpace(horizontalVelocity)
		local lastLocalVelocity = self.lastPhysicsLocalVelocity or localVelocity
		localAcceleration = (localVelocity - lastLocalVelocity) / math.max(dt, minDt)
		self.lastPhysicsLocalVelocity = localVelocity

		local kickLocal = Vector3.new(
			(-localAcceleration.X * getPhysicsValue("AccelerationSideKickScale", 0.014))
				+ (-localVelocity.X * getPhysicsValue("VelocitySideKickScale", 0.035)),
			0,
			(-localAcceleration.Z * getPhysicsValue("AccelerationBackKickScale", 0.014))
				+ (-localVelocity.Z * getPhysicsValue("VelocityBackKickScale", 0.035))
		)
		local maxKickSpeed = math.max(getPhysicsValue("MaxKickSpeed", 7), 0)
		if maxKickSpeed > 0 and kickLocal.Magnitude > maxKickSpeed then
			kickLocal = kickLocal.Unit * maxKickSpeed
		end
		if kickLocal.Magnitude > 0.025 then
			bobPart:ApplyImpulse(basis:VectorToWorldSpace(kickLocal) * bobPart.AssemblyMass)
		end
	end

	local linearVelocity = bobPart.AssemblyLinearVelocity
	local maxLinearSpeed = math.max(getPhysicsValue("MaxLinearSpeed", 42), 1)
	if linearVelocity.Magnitude > maxLinearSpeed then
		linearVelocity = linearVelocity.Unit * maxLinearSpeed
	end

	local angularVelocity = bobPart.AssemblyAngularVelocity
	local maxAngularSpeed = math.max(getPhysicsValue("MaxAngularSpeed", 14), 1)
	if angularVelocity.Magnitude > maxAngularSpeed then
		angularVelocity = angularVelocity.Unit * maxAngularSpeed
	end

	local linearDamping = math.max(getPhysicsValue("LinearDamping", 1.7), 0)
	local angularDamping = math.max(getPhysicsValue("AngularDamping", 3.2), 0)
	setAssemblyVelocity(
		bobPart,
		linearVelocity * math.exp(-linearDamping * dt),
		angularVelocity * math.exp(-angularDamping * dt)
	)

	self.debugStepCount = (self.debugStepCount or 0) + 1
	socket:SetAttribute("HipDebugMode", "Physics")
	socket:SetAttribute("HipDebugStepCount", self.debugStepCount)
	socket:SetAttribute("HipDebugLocalOffset", carrierPart.CFrame:PointToObjectSpace(rootPart.Position))
	socket:SetAttribute("HipDebugLocalVelocity", localVelocity)
	socket:SetAttribute("HipDebugLocalAcceleration", localAcceleration)
	socket:SetAttribute("HipDebugLinearVelocity", bobPart.AssemblyLinearVelocity)
	socket:SetAttribute("HipDebugAngularVelocity", bobPart.AssemblyAngularVelocity)
	socket:SetAttribute("HipDebugLastUpdated", os.clock())
	return true
end

function HipBombVisual:SetVisible(visible: boolean)
	self.visible = visible
	if self.instance and self.instance.Parent then
		setInstanceVisible(self.instance, visible)
	end
end

function HipBombVisual:Reset()
	self:SetVisible(false)
	self.translation = Vector3.zero
	self.translationVelocity = Vector3.zero
	self.rotation = Vector3.zero
	self.rotationVelocity = Vector3.zero
	self.movementImpulseTranslation = Vector3.zero
	self.movementImpulseRotation = Vector3.zero
	self.lastLocalVelocity = nil
	self.lastPhysicsLocalVelocity = nil
	self.idleTime = 0
	self.landingImpulse = 0
	self.debugStepCount = 0

	if self.motor and self.motor.Parent then
		self.motor.C0 = self.baseOffset or CFrame.new()
		self.motor.C1 = self.baseC1 or CFrame.new()
	end
	if self.physicsRig and self.physicsRig.bobPart and self.physicsRig.bobPart.Parent then
		setAssemblyVelocity(self.physicsRig.bobPart, Vector3.zero, Vector3.zero)
	end
end

function HipBombVisual:Step(dt: number, state)
	if self.physicsEnabled then
		return self:_stepPhysics(dt, state)
	end

	local motor = self.motor
	local carrierPart = self.carrierPart
	if not (motor and motor.Parent and carrierPart and carrierPart.Parent) then
		return false
	end

	local minDt = getConfigValue("MinStepSeconds", 1 / 120)
	local maxDt = getConfigValue("MaxStepSeconds", 1 / 20)
	dt = clampNumber(dt, minDt, maxDt)

	local basis = getCFrameBasis(state, carrierPart)
	local localVelocity = Vector3.zero
	if basis then
		local worldVelocity = getLinearVelocity(state)
		local horizontalVelocity = Vector3.new(worldVelocity.X, 0, worldVelocity.Z)
		localVelocity = basis:VectorToObjectSpace(horizontalVelocity)
	end

	local lastLocalVelocity = self.lastLocalVelocity or Vector3.zero
	local localAcceleration = (localVelocity - lastLocalVelocity) / math.max(dt, minDt)
	self.lastLocalVelocity = localVelocity

	local multiplier = getStateMultiplier(state)
	local landingAlpha = getLandingAlpha(state)
	local landingImpulse = self.landingImpulse or 0
	if landingAlpha > landingImpulse then
		landingImpulse = landingAlpha
	end
	landingImpulse *= math.exp(-getConfigValue("LandingImpulseDecay", 7) * dt)
	self.landingImpulse = landingImpulse
	self.idleTime = (self.idleTime or 0) + dt

	local speedAlpha = math.clamp(localVelocity.Magnitude / 24, 0, 1)
	local accelerationMagnitude = localAcceleration.Magnitude
	local movementChanged = accelerationMagnitude > 18
	local steadyScale = if movementChanged then 1 else getConfigValue("SteadySpeedSettleScale", 0.28)
	local impulseDecay = math.exp(-math.max(getConfigValue("MovementImpulseDecay", 6.8), 0) * dt)
	local impulseTranslation = (self.movementImpulseTranslation or Vector3.zero) * impulseDecay
	local impulseRotation = (self.movementImpulseRotation or Vector3.zero) * impulseDecay
	if movementChanged then
		local maxImpulseTranslation = getConfigValue("MaxMovementImpulseTranslation", Vector3.new(0.22, 0, 0.48))
		local addedTranslationImpulse = clampVector(
			Vector3.new(
				-localAcceleration.X * getConfigValue("MovementImpulseSideScale", 0.0018),
				0,
				-localAcceleration.Z * getConfigValue("MovementImpulseBackScale", 0.0045)
			),
			maxImpulseTranslation
		)
		local maxImpulsePitch = math.rad(getConfigValue("MaxMovementImpulsePitchDegrees", 13))
		local maxImpulseRoll = math.rad(getConfigValue("MaxMovementImpulseRollDegrees", 12))
		local addedRotationImpulse = Vector3.new(
			clampNumber(-localAcceleration.Z * getConfigValue("MovementImpulsePitchScale", 0.0026), -maxImpulsePitch, maxImpulsePitch),
			0,
			clampNumber(-localAcceleration.X * getConfigValue("MovementImpulseRollScale", 0.002), -maxImpulseRoll, maxImpulseRoll)
		)
		impulseTranslation = clampVector(impulseTranslation + addedTranslationImpulse, maxImpulseTranslation)
		impulseRotation = Vector3.new(
			clampNumber(impulseRotation.X + addedRotationImpulse.X, -maxImpulsePitch, maxImpulsePitch),
			0,
			clampNumber(impulseRotation.Z + addedRotationImpulse.Z, -maxImpulseRoll, maxImpulseRoll)
		)
	end
	self.movementImpulseTranslation = impulseTranslation
	self.movementImpulseRotation = impulseRotation

	local side = (-localVelocity.X * getConfigValue("VelocitySideScale", 0.0022))
		+ (-localAcceleration.X * getConfigValue("AccelerationSideScale", 0.0005))
	local back = (-localVelocity.Z * getConfigValue("VelocityBackScale", 0.0028))
		+ (-localAcceleration.Z * getConfigValue("AccelerationBackScale", 0.00045))
	local idleAmplitude = getConfigValue("IdleBobAmplitude", 0.02) * (1 - (speedAlpha * 0.55))
	local idlePhase = (self.idleTime or 0) * math.pi * 2 * getConfigValue("IdleBobFrequency", 1.35)
	local idleBob = math.sin(idlePhase) * idleAmplitude

	local targetTranslation = clampVector(
		(Vector3.new(side * steadyScale, idleBob - (landingImpulse * 0.045), back * steadyScale) + impulseTranslation) * multiplier,
		getConfigValue("MaxTranslation", Vector3.new(0.1, 0.06, 0.13))
	)

	local maxPitch = math.rad(getConfigValue("MaxPitchDegrees", 8))
	local maxYaw = math.rad(getConfigValue("MaxYawDegrees", 5))
	local maxRoll = math.rad(getConfigValue("MaxRollDegrees", 7))
	local idleRoll = math.sin(idlePhase * 0.74) * math.rad(getConfigValue("IdleRollDegrees", 1.5)) * (1 - (speedAlpha * 0.45))
	local landingImpulseRadians = landingImpulse * math.rad(getConfigValue("LandingImpulseDegrees", 7))
	local targetRotation = Vector3.new(
		clampNumber((localVelocity.Z * -0.0018 * steadyScale) + impulseRotation.X + landingImpulseRadians, -maxPitch, maxPitch),
		clampNumber((localVelocity.X * 0.0025) + (localAcceleration.X * 0.00035), -maxYaw, maxYaw),
		clampNumber(
			(localVelocity.X * -0.0015 * steadyScale)
				+ impulseRotation.Z
				+ idleRoll,
			-maxRoll,
			maxRoll
		)
	) * multiplier
	targetRotation = Vector3.new(
		clampNumber(targetRotation.X, -maxPitch, maxPitch),
		clampNumber(targetRotation.Y, -maxYaw, maxYaw),
		clampNumber(targetRotation.Z, -maxRoll, maxRoll)
	)

	self.translation, self.translationVelocity = stepSpring(
		self.translation,
		self.translationVelocity or Vector3.zero,
		targetTranslation,
		getConfigValue("PendulumStiffness", 46),
		getConfigValue("PendulumDamping", 9),
		dt
	)
	self.translation = clampVector(self.translation, getConfigValue("MaxTranslation", Vector3.new(0.1, 0.06, 0.13)))
	self.translationVelocity = clampVector(self.translationVelocity, Vector3.new(1.5, 1.2, 1.5))

	self.rotation, self.rotationVelocity = stepSpring(
		self.rotation,
		self.rotationVelocity or Vector3.zero,
		targetRotation,
		getConfigValue("RotationStiffness", 42),
		getConfigValue("RotationDamping", 8),
		dt
	)
	self.rotation = Vector3.new(
		clampNumber(self.rotation.X, -maxPitch, maxPitch),
		clampNumber(self.rotation.Y, -maxYaw, maxYaw),
		clampNumber(self.rotation.Z, -maxRoll, maxRoll)
	)
	self.rotationVelocity = clampVector(self.rotationVelocity, Vector3.new(maxPitch * 8, maxYaw * 8, maxRoll * 8))

	local finalTranslation = clampVector(
		self.translation,
		getConfigValue("MaxTranslation", Vector3.new(0.1, 0.06, 0.13))
	)
	local finalRotation = Vector3.new(
		self.rotation.X,
		self.rotation.Y,
		clampNumber(self.rotation.Z, -maxRoll, maxRoll)
	)

	local animatedOffset = CFrame.Angles(finalRotation.X, finalRotation.Y, finalRotation.Z)
		* CFrame.new(finalTranslation)
	local motionScale = getConfigValue("DebugMotionScale", 1)
	if motionScale ~= 1 then
		animatedOffset = CFrame.Angles(finalRotation.X * motionScale, finalRotation.Y * motionScale, finalRotation.Z * motionScale)
			* CFrame.new(finalTranslation * motionScale)
	end
	motor.C0 = self.baseOffset * animatedOffset
	motor.C1 = self.baseC1 or CFrame.new()
	self.debugStepCount = (self.debugStepCount or 0) + 1
	motor:SetAttribute("HipDebugStepCount", self.debugStepCount)
	motor:SetAttribute("HipDebugTranslation", self.translation)
	motor:SetAttribute("HipDebugRotation", self.rotation)
	motor:SetAttribute("HipDebugFinalTranslation", finalTranslation)
	motor:SetAttribute("HipDebugFinalRotation", finalRotation)
	motor:SetAttribute("HipDebugImpulseTranslation", impulseTranslation)
	motor:SetAttribute("HipDebugImpulseRotation", impulseRotation)
	motor:SetAttribute("HipDebugLocalVelocity", localVelocity)
	motor:SetAttribute("HipDebugLocalAcceleration", localAcceleration)
	motor:SetAttribute("HipDebugLastUpdated", os.clock())
	return true
end

function HipBombVisual:Destroy()
	if self.motor and self.motor.Parent then
		self.motor:Destroy()
	end
	if self.physicsRig then
		for _, value in pairs(self.physicsRig) do
			if typeof(value) == "Instance" and value.Parent then
				value:Destroy()
			end
		end
	end
	if self.instance and self.instance.Parent then
		self.instance:Destroy()
	end

	self.motor = nil
	self.physicsRig = nil
	self.instance = nil
	self.rootPart = nil
	self.carrierPart = nil
end

return HipBombVisual
