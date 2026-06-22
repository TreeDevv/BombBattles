local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)

local BombProjectileVisualMotion = {}

local TIME_SCALE_ENTER_RATE = 7.5
local TIME_SCALE_EXIT_RATE = 5.5

local function getVisualNumber(visual, key: string, fallback: number): number
	local visuals = visual and visual.visuals
	local value = if typeof(visuals) == "table" then visuals[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getVisualColor(visual, key: string, fallback: Color3): Color3
	local visuals = visual and visual.visuals
	local value = if typeof(visuals) == "table" then visuals[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

local function getProjectileSpinSpeed(visual): number
	local fallback = BombConfig.VisualSpinRadiansPerSecond
	if visual and visual.burrowing == true then
		return getVisualNumber(visual, "burrowSpinRadiansPerSecond", fallback * 2.4)
	end
	return getVisualNumber(visual, "spinRadiansPerSecond", fallback)
end

local function getProjectileVisualTimeScale(visual): number
	local timeScale = if visual and typeof(visual.timeScale) == "number" then visual.timeScale else 1
	return math.clamp(timeScale, 0.005, 1)
end

local function updateProjectileVisualTimeScale(visual, deltaTime: number): number
	local currentTimeScale = getProjectileVisualTimeScale(visual)
	local targetTimeScale = math.clamp(
		if visual and typeof(visual.targetTimeScale) == "number" then visual.targetTimeScale else 1,
		0.005,
		1
	)
	local rate = if targetTimeScale < currentTimeScale then TIME_SCALE_ENTER_RATE else TIME_SCALE_EXIT_RATE
	local alpha = 1 - math.exp(-rate * math.max(deltaTime, 0))
	local nextTimeScale = currentTimeScale + (targetTimeScale - currentTimeScale) * math.clamp(alpha, 0, 1)
	if math.abs(nextTimeScale - targetTimeScale) < 0.001 then
		nextTimeScale = targetTimeScale
	end
	visual.timeScale = math.clamp(nextTimeScale, 0.005, 1)
	return visual.timeScale
end

function BombProjectileVisualMotion.AdvanceMotion(
	position: Vector3,
	velocity: Vector3,
	acceleration: Vector3,
	deltaTime: number
): (Vector3, Vector3)
	local clampedDt = math.clamp(deltaTime, 0, 0.25)
	local nextPosition = position + velocity * clampedDt + acceleration * (0.5 * clampedDt * clampedDt)
	local nextVelocity = velocity + acceleration * clampedDt
	return nextPosition, nextVelocity
end

function BombProjectileVisualMotion.GetVisualNumber(visual, key: string, fallback: number): number
	return getVisualNumber(visual, key, fallback)
end

function BombProjectileVisualMotion.GetVisualColor(visual, key: string, fallback: Color3): Color3
	return getVisualColor(visual, key, fallback)
end

function BombProjectileVisualMotion.GetPulseStyle(visual): { baseColor: Color3, pulseColor: Color3, fillStart: number, outlineStart: number }
	return {
		baseColor = getVisualColor(visual, "highlightColor", BombConfig.PulseWhite),
		pulseColor = getVisualColor(visual, "highlightPulseColor", BombConfig.PulseRed),
		fillStart = getVisualNumber(visual, "highlightFillTransparency", BombConfig.PulseStartFillTransparency),
		outlineStart = getVisualNumber(visual, "highlightOutlineTransparency", BombConfig.PulseStartOutlineTransparency),
	}
end

function BombProjectileVisualMotion.SetCFrame(visual, position: Vector3, tangent: Vector3, spin: number)
	if tangent.Magnitude < 0.05 then
		tangent = Vector3.zAxis
	else
		tangent = tangent.Unit
	end
	local cframe = CFrame.lookAt(position, position + tangent) * CFrame.Angles(spin, spin * 0.35, 0)
	if visual.instance:IsA("Model") then
		visual.instance:PivotTo(cframe)
	else
		visual.rootPart.CFrame = cframe
	end
end

function BombProjectileVisualMotion.AdvanceTarget(visual, deltaTime: number, timeScale: number): (Vector3?, Vector3?)
	if typeof(visual.targetPosition) ~= "Vector3" then
		return nil, nil
	end

	local targetVelocity = if typeof(visual.targetVelocity) == "Vector3" then visual.targetVelocity else Vector3.zero
	if visual.settled or visual.frozen then
		return visual.targetPosition, Vector3.zero
	end

	local targetAcceleration = if typeof(visual.targetAcceleration) == "Vector3"
		then visual.targetAcceleration
		elseif typeof(visual.acceleration) == "Vector3" then visual.acceleration
		else Vector3.zero
	local motionDt = math.max(deltaTime, 0) * math.clamp(timeScale, 0.005, 1)
	local nextPosition, nextVelocity = BombProjectileVisualMotion.AdvanceMotion(
		visual.targetPosition,
		targetVelocity,
		targetAcceleration,
		motionDt
	)
	visual.targetPosition = nextPosition
	visual.targetVelocity = nextVelocity
	return nextPosition, nextVelocity
end

function BombProjectileVisualMotion.Step(visual, deltaTime: number, path, startedAt: number?, serverTime: number)
	local visualTimeScale = updateProjectileVisualTimeScale(visual, deltaTime)
	if not visual.spinLocked then
		visual.spin += deltaTime * getProjectileSpinSpeed(visual) * visualTimeScale
	end

	if visual.customProjectile then
		local position = visual.position or visual.targetPosition or visual.rootPart.Position
		local velocity = visual.velocity or visual.targetVelocity or Vector3.zero
		if visual.settled then
			position = visual.targetPosition or position
			velocity = Vector3.zero
		else
			local acceleration = visual.acceleration or Vector3.zero
			local motionDt = deltaTime * visualTimeScale
			velocity += acceleration * motionDt
			position += velocity * motionDt
			local targetPosition, targetVelocity = BombProjectileVisualMotion.AdvanceTarget(visual, deltaTime, visualTimeScale)

			local correctionScale = math.clamp(0.15 + visualTimeScale * 0.85, 0.15, 1)
			local positionAlpha = 1 - math.exp(-18 * deltaTime * correctionScale)
			local velocityAlpha = 1 - math.exp(-14 * deltaTime * correctionScale)
			if typeof(targetPosition) == "Vector3" then
				position = position:Lerp(targetPosition, positionAlpha)
			end
			if typeof(targetVelocity) == "Vector3" then
				velocity = velocity:Lerp(targetVelocity, velocityAlpha)
			end
		end

		visual.position = position
		visual.velocity = velocity
		if not visual.handoffConnection then
			local tangent = if velocity.Magnitude > 0.05 then velocity else visual.targetVelocity or Vector3.zAxis
			BombProjectileVisualMotion.SetCFrame(visual, position, tangent, visual.spin)
		end
	elseif path and typeof(startedAt) == "number" then
		local alpha = math.clamp((serverTime - startedAt) / path.duration, 0, 1)
		local position = BombTrajectory.Evaluate(path, alpha)
		local tangent = BombTrajectory.GetTangent(path, alpha)
		BombProjectileVisualMotion.SetCFrame(visual, position, tangent, visual.spin)
	end
end

return table.freeze(BombProjectileVisualMotion)
