local RunService = game:GetService("RunService")

local DEFAULT_IMAGE = "rbxassetid://7083340510"
local DEFAULT_LIFETIME = NumberRange.new(0.35, 0.45)
local DEFAULT_SIZE = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.3, 48),
	NumberSequenceKeypoint.new(1, 80),
})
local DEFAULT_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.75, 0.2),
	NumberSequenceKeypoint.new(1, 1),
})

local rng = Random.new()

type ParticleRecord = {
	Visual: ImageLabel,
	Connection: RBXScriptConnection?,
}

type Config = {
	Parent: GuiObject?,
	Image: string?,
	Color: ColorSequence?,
	Transparency: NumberSequence?,
	Size: NumberSequence?,
	SizeMultiplier: NumberRange?,
	Lifetime: NumberRange?,
	Rotation: NumberRange?,
	RotationSpeed: NumberRange?,
	Velocity: Vector2?,
	Acceleration: Vector2?,
	Speed: NumberRange?,
	SpreadAngle: NumberRange?,
	Rate: number?,
	ZIndex: number?,
	Enabled: boolean?,
	LockedToParent: boolean?,
	SizeDominantAxis: string?,
	SizeIsInPixels: boolean?,
	AffectedByParentTransparency: boolean?,
}

local UIParticleEmitter = {}
UIParticleEmitter.__index = UIParticleEmitter

local function parseNumbers(value: any): { number }
	if typeof(value) == "number" then
		return { value }
	end
	if typeof(value) ~= "string" then
		return {}
	end

	local numbers = {}
	for token in string.gmatch(value, "[-+]?%d*%.?%d+") do
		table.insert(numbers, tonumber(token) or 0)
	end
	return numbers
end

local function readNumberRange(value: any, fallback: NumberRange): NumberRange
	if typeof(value) == "NumberRange" then
		return value
	end

	local numbers = parseNumbers(value)
	if #numbers >= 2 then
		return NumberRange.new(numbers[1], numbers[2])
	end
	if #numbers == 1 then
		return NumberRange.new(numbers[1], numbers[1])
	end
	return fallback
end

local function readVector2(value: any, fallback: Vector2): Vector2
	if typeof(value) == "Vector2" then
		return value
	end

	local numbers = parseNumbers(value)
	if #numbers >= 2 then
		return Vector2.new(numbers[1], numbers[2])
	end
	return fallback
end

local function readNumberSequence(value: any, fallback: NumberSequence): NumberSequence
	if typeof(value) == "NumberSequence" then
		return value
	end

	local numbers = parseNumbers(value)
	if #numbers >= 3 and #numbers % 3 == 0 then
		local keypoints = {}
		for index = 1, #numbers, 3 do
			table.insert(keypoints, NumberSequenceKeypoint.new(math.clamp(numbers[index], 0, 1), numbers[index + 1], numbers[index + 2]))
		end
		return NumberSequence.new(keypoints)
	end
	if #numbers >= 2 then
		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, numbers[1]),
			NumberSequenceKeypoint.new(1, numbers[2]),
		})
	end
	if #numbers == 1 then
		return NumberSequence.new(numbers[1])
	end
	return fallback
end

local function readColorSequence(value: any, fallback: ColorSequence): ColorSequence
	if typeof(value) == "ColorSequence" then
		return value
	end
	if typeof(value) == "Color3" then
		return ColorSequence.new(value)
	end

	local numbers = parseNumbers(value)
	if #numbers >= 4 and #numbers % 4 == 0 then
		local keypoints = {}
		for index = 1, #numbers, 4 do
			table.insert(
				keypoints,
				ColorSequenceKeypoint.new(
					math.clamp(numbers[index], 0, 1),
					Color3.new(math.clamp(numbers[index + 1], 0, 1), math.clamp(numbers[index + 2], 0, 1), math.clamp(numbers[index + 3], 0, 1))
				)
			)
		end
		return ColorSequence.new(keypoints)
	end
	if #numbers >= 5 and #numbers % 5 == 0 then
		local keypoints = {}
		for index = 1, #numbers, 5 do
			table.insert(
				keypoints,
				ColorSequenceKeypoint.new(
					math.clamp(numbers[index], 0, 1),
					Color3.new(math.clamp(numbers[index + 1], 0, 1), math.clamp(numbers[index + 2], 0, 1), math.clamp(numbers[index + 3], 0, 1))
				)
			)
		end
		return ColorSequence.new(keypoints)
	end
	return fallback
end

local function sampleRange(value: NumberRange): number
	if value.Min == value.Max then
		return value.Min
	end
	return rng:NextNumber(value.Min, value.Max)
end

local function evalNumberSequence(sequence: NumberSequence, alpha: number): number
	local keypoints = sequence.Keypoints
	if #keypoints == 0 then
		return 0
	end
	if alpha <= 0 then
		return keypoints[1].Value
	end
	if alpha >= 1 then
		return keypoints[#keypoints].Value
	end

	for index = 2, #keypoints do
		local previous = keypoints[index - 1]
		local current = keypoints[index]
		if alpha <= current.Time then
			local span = math.max(current.Time - previous.Time, 0.001)
			local localAlpha = math.clamp((alpha - previous.Time) / span, 0, 1)
			return previous.Value + (current.Value - previous.Value) * localAlpha
		end
	end

	return keypoints[#keypoints].Value
end

local function evalColorSequence(sequence: ColorSequence, alpha: number): Color3
	local keypoints = sequence.Keypoints
	if #keypoints == 0 then
		return Color3.new(1, 1, 1)
	end
	if alpha <= 0 or #keypoints == 1 then
		return keypoints[1].Value
	end
	if alpha >= 1 then
		return keypoints[#keypoints].Value
	end

	for index = 2, #keypoints do
		local previous = keypoints[index - 1]
		local current = keypoints[index]
		if alpha <= current.Time then
			local span = math.max(current.Time - previous.Time, 0.001)
			return previous.Value:Lerp(current.Value, math.clamp((alpha - previous.Time) / span, 0, 1))
		end
	end

	return keypoints[#keypoints].Value
end

local function rotateVector(vector: Vector2, degrees: number): Vector2
	local radians = math.rad(degrees)
	local cos = math.cos(radians)
	local sin = math.sin(radians)
	return Vector2.new(vector.X * cos - vector.Y * sin, vector.X * sin + vector.Y * cos)
end

local function readConfig(config: any): Config
	local raw = {}
	if typeof(config) == "Instance" then
		raw = config:GetAttributes()
	elseif typeof(config) == "table" then
		raw = config
	end

	local image = raw.Image
	if typeof(image) == "number" then
		image = "rbxassetid://" .. tostring(math.floor(image))
	elseif typeof(image) ~= "string" or image == "" then
		image = DEFAULT_IMAGE
	end

	return {
		Parent = if typeof(raw.Parent) == "Instance" and raw.Parent:IsA("GuiObject") then raw.Parent else nil,
		Image = image,
		Color = readColorSequence(raw.Color, ColorSequence.new(Color3.new(1, 1, 1))),
		Transparency = readNumberSequence(raw.Transparency, DEFAULT_TRANSPARENCY),
		Size = readNumberSequence(raw.Size, DEFAULT_SIZE),
		SizeMultiplier = readNumberRange(raw.SizeMultiplier, NumberRange.new(1, 1)),
		Lifetime = readNumberRange(raw.Lifetime, DEFAULT_LIFETIME),
		Rotation = readNumberRange(raw.Rotation, NumberRange.new(0, 0)),
		RotationSpeed = readNumberRange(raw.RotationSpeed, NumberRange.new(0, 0)),
		Velocity = readVector2(raw.Velocity, Vector2.zero),
		Acceleration = readVector2(raw.Acceleration, Vector2.zero),
		Speed = readNumberRange(raw.Speed, NumberRange.new(1, 1)),
		SpreadAngle = readNumberRange(raw.SpreadAngle, NumberRange.new(0, 0)),
		Rate = if typeof(raw.Rate) == "number" and raw.Rate > 0 then raw.Rate else 20,
		ZIndex = if typeof(raw.ZIndex) == "number" then math.floor(raw.ZIndex) else 1,
		Enabled = raw.Enabled == true,
		LockedToParent = raw.LockedToParent == true,
		SizeDominantAxis = if raw.SizeDominantAxis == "Y" then "Y" else "X",
		SizeIsInPixels = raw.SizeIsInPixels == true,
		AffectedByParentTransparency = raw.AffectedByParentTransparency == true,
	}
end

function UIParticleEmitter.new(config: any)
	local self = setmetatable({}, UIParticleEmitter)
	self.Config = readConfig(config)
	self.Particles = {} :: { ParticleRecord }
	self._enabled = false

	if self.Config.Enabled then
		self:Enable()
	end

	return self
end

function UIParticleEmitter:SetColor(color: Color3 | ColorSequence)
	if typeof(color) == "Color3" then
		self.Config.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.25), color)
	elseif typeof(color) == "ColorSequence" then
		self.Config.Color = ColorSequence.new(color.Keypoints)
	end
end

function UIParticleEmitter:SetParent(parent: GuiObject?)
	self.Config.Parent = parent
end

function UIParticleEmitter:_removeParticle(record: ParticleRecord)
	if record.Connection then
		record.Connection:Disconnect()
		record.Connection = nil
	end

	local index = table.find(self.Particles, record)
	if index then
		table.remove(self.Particles, index)
	end

	if record.Visual.Parent then
		record.Visual:Destroy()
	end
end

function UIParticleEmitter:Emit(count: number?)
	local parent = self.Config.Parent
	if not (parent and parent.Parent) then
		return
	end

	local amount = math.max(1, math.floor(count or 1))
	for _ = 1, amount do
		local lifetime = math.max(0.05, sampleRange(self.Config.Lifetime :: NumberRange))
		local sizeMultiplier = math.max(0.001, sampleRange(self.Config.SizeMultiplier :: NumberRange))
		local rotation = sampleRange(self.Config.Rotation :: NumberRange)
		local rotationSpeed = sampleRange(self.Config.RotationSpeed :: NumberRange)
		local velocity = rotateVector(self.Config.Velocity or Vector2.zero, sampleRange(self.Config.SpreadAngle :: NumberRange))
		local acceleration = self.Config.Acceleration or Vector2.zero
		local speed = sampleRange(self.Config.Speed :: NumberRange)
		local position = Vector2.zero
		local basePosition = if self.Config.LockedToParent
			then Vector2.new(rng:NextNumber(), rng:NextNumber())
			else Vector2.new(0.5, 0.5)
		local startedAt = os.clock()

		local particle = Instance.new("ImageLabel")
		particle.Name = "DestructionMeterParticle"
		particle.AnchorPoint = Vector2.new(0.5, 0.5)
		particle.BackgroundTransparency = 1
		particle.BorderSizePixel = 0
		particle.Image = self.Config.Image or DEFAULT_IMAGE
		particle.Position = UDim2.fromScale(basePosition.X, basePosition.Y)
		particle.Rotation = rotation
		particle.ZIndex = (parent.ZIndex or 1) + (self.Config.ZIndex or 1)
		particle.Parent = parent

		local record: ParticleRecord = {
			Visual = particle,
			Connection = nil,
		}
		table.insert(self.Particles, record)

		local function updateParticle(deltaTime: number)
			if not particle.Parent then
				self:_removeParticle(record)
				return
			end

			local alpha = math.clamp((os.clock() - startedAt) / lifetime, 0, 1)
			if alpha >= 1 then
				self:_removeParticle(record)
				return
			end

			velocity += acceleration * deltaTime
			position += Vector2.new(velocity.X, -velocity.Y) * deltaTime * speed

			local size = math.max(0, evalNumberSequence(self.Config.Size :: NumberSequence, alpha) * sizeMultiplier)
			local transparency = math.clamp(evalNumberSequence(self.Config.Transparency :: NumberSequence, alpha), 0, 1)
			if self.Config.AffectedByParentTransparency and parent:IsA("Frame") then
				transparency = math.clamp(transparency + parent.BackgroundTransparency, 0, 1)
			end

			particle.ImageColor3 = evalColorSequence(self.Config.Color :: ColorSequence, alpha)
			particle.ImageTransparency = transparency
			particle.Position = UDim2.new(basePosition.X, position.X, basePosition.Y, position.Y)
			particle.Rotation += rotationSpeed * deltaTime
			particle.Size = UDim2.fromOffset(size, size)
		end

		updateParticle(0)
		record.Connection = RunService.RenderStepped:Connect(updateParticle)
	end
end

function UIParticleEmitter:Enable()
	if self._enabled then
		return
	end

	self._enabled = true
	task.spawn(function()
		while self._enabled do
			self:Emit()
			task.wait(1 / math.max(self.Config.Rate or 20, 1))
		end
	end)
end

function UIParticleEmitter:Disable()
	self._enabled = false
end

function UIParticleEmitter:Clear()
	for _, record in ipairs(table.clone(self.Particles)) do
		self:_removeParticle(record)
	end
	table.clear(self.Particles)
end

function UIParticleEmitter:Destroy()
	self:Disable()
	self:Clear()
end

return UIParticleEmitter
