local TweenService = game:GetService("TweenService")

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
	Rate: number?,
	ZIndex: number?,
	Enabled: boolean?,
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

local function firstNumber(sequence: NumberSequence): number
	local keypoints = sequence.Keypoints
	return if keypoints[1] then keypoints[1].Value else 0
end

local function lastNumber(sequence: NumberSequence): number
	local keypoints = sequence.Keypoints
	return if keypoints[#keypoints] then keypoints[#keypoints].Value else firstNumber(sequence)
end

local function firstColor(sequence: ColorSequence): Color3
	local keypoints = sequence.Keypoints
	return if keypoints[1] then keypoints[1].Value else Color3.new(1, 1, 1)
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
		Rate = if typeof(raw.Rate) == "number" and raw.Rate > 0 then raw.Rate else 20,
		ZIndex = if typeof(raw.ZIndex) == "number" then math.floor(raw.ZIndex) else 1,
		Enabled = raw.Enabled == true,
	}
end

function UIParticleEmitter.new(config: any)
	local self = setmetatable({}, UIParticleEmitter)
	self.Config = readConfig(config)
	self.Particles = {}
	self._enabled = false

	if self.Config.Enabled then
		self:Enable()
	end

	return self
end

function UIParticleEmitter:SetColor(color: Color3)
	if typeof(color) == "Color3" then
		self.Config.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.25), color)
	end
end

function UIParticleEmitter:SetParent(parent: GuiObject?)
	self.Config.Parent = parent
end

function UIParticleEmitter:Emit(count: number?)
	local parent = self.Config.Parent
	if not (parent and parent.Parent) then
		return
	end

	local amount = math.max(1, math.floor(count or 1))
	for _ = 1, amount do
		local lifetime = math.max(0.05, sampleRange(self.Config.Lifetime :: NumberRange))
		local sizeMultiplier = math.max(0.05, sampleRange(self.Config.SizeMultiplier :: NumberRange))
		local startSize = math.max(1, firstNumber(self.Config.Size :: NumberSequence) * sizeMultiplier)
		local endSize = math.max(startSize, lastNumber(self.Config.Size :: NumberSequence) * sizeMultiplier)
		local startTransparency = math.clamp(firstNumber(self.Config.Transparency :: NumberSequence), 0, 1)
		local endTransparency = math.clamp(lastNumber(self.Config.Transparency :: NumberSequence), 0, 1)
		local startRotation = sampleRange(self.Config.Rotation :: NumberRange)
		local endRotation = startRotation + sampleRange(self.Config.RotationSpeed :: NumberRange) * lifetime

		local particle = Instance.new("ImageLabel")
		particle.Name = "DestructionMeterParticle"
		particle.AnchorPoint = Vector2.new(0.5, 0.5)
		particle.BackgroundTransparency = 1
		particle.BorderSizePixel = 0
		particle.Image = self.Config.Image or DEFAULT_IMAGE
		particle.ImageColor3 = firstColor(self.Config.Color :: ColorSequence)
		particle.ImageTransparency = startTransparency
		particle.Position = UDim2.fromScale(0.5, 0.5)
		particle.Rotation = startRotation
		particle.Size = UDim2.fromOffset(startSize, startSize)
		particle.ZIndex = (parent.ZIndex or 1) + (self.Config.ZIndex or 1)
		particle.Parent = parent
		table.insert(self.Particles, particle)

		local tween = TweenService:Create(particle, TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			ImageTransparency = endTransparency,
			Rotation = endRotation,
			Size = UDim2.fromOffset(endSize, endSize),
		})
		tween:Play()
		tween.Completed:Once(function()
			local index = table.find(self.Particles, particle)
			if index then
				table.remove(self.Particles, index)
			end
			if particle.Parent then
				particle:Destroy()
			end
		end)
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
	for _, particle in ipairs(table.clone(self.Particles)) do
		if particle.Parent then
			particle:Destroy()
		end
	end
	table.clear(self.Particles)
end

function UIParticleEmitter:Destroy()
	self:Disable()
	self:Clear()
end

return UIParticleEmitter
