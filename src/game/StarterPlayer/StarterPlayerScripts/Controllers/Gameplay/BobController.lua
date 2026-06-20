local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local BOB_TAG = "Bob"
local DEFAULT_CYCLES_PER_SECOND = 0.35
local DEFAULT_ROTATION_CYCLES_PER_SECOND = 0.12
local DEFAULT_ROTATION_DEGREES = 5
local HEIGHT_AMPLITUDE_SCALE = 0.08
local MIN_AMPLITUDE = 0.08
local MAX_AMPLITUDE = 1.25
local TAU = math.pi * 2

type BobRecord = {
	instance: PVInstance,
	basePivot: CFrame,
	amplitude: number,
	rotationAmplitude: number,
	rotationSpeedRadians: number,
	speedRadians: number,
	phase: number,
	elapsed: number,
	attributeConnection: RBXScriptConnection?,
}

local BobController = {}

local records: { [Instance]: BobRecord } = {}
local tagAddedConnection: RBXScriptConnection? = nil
local tagRemovedConnection: RBXScriptConnection? = nil
local renderConnection: RBXScriptConnection? = nil

local function getTarget(instance: Instance): PVInstance?
	if instance:IsA("BasePart") or instance:IsA("Model") then
		return instance :: PVInstance
	end

	return nil
end

local function getTargetSize(target: PVInstance): Vector3?
	if target:IsA("BasePart") then
		return target.Size
	end
	if target:IsA("Model") then
		local ok, _, size = pcall(function()
			return target:GetBoundingBox()
		end)
		if ok then
			return size
		end
	end

	return nil
end

local function readNumberAttribute(instance: Instance, name: string): number?
	local value = instance:GetAttribute(name)
	if typeof(value) == "number" and value == value then
		return value
	end

	return nil
end

local function computeAmplitude(instance: Instance, target: PVInstance): number
	local override = readNumberAttribute(instance, "BobAmplitude")
	if override then
		return math.max(override, 0)
	end

	local size = getTargetSize(target)
	local height = if size then math.max(size.Y, 0) else 1
	return math.clamp(height * HEIGHT_AMPLITUDE_SCALE, MIN_AMPLITUDE, MAX_AMPLITUDE)
end

local function computeSpeedRadians(instance: Instance): number
	local cyclesPerSecond = readNumberAttribute(instance, "BobSpeed") or DEFAULT_CYCLES_PER_SECOND
	return math.max(cyclesPerSecond, 0) * TAU
end

local function computeRotationAmplitude(instance: Instance): number
	local degrees = readNumberAttribute(instance, "BobRotationDegrees") or DEFAULT_ROTATION_DEGREES
	return math.rad(math.max(degrees, 0))
end

local function computeRotationSpeedRadians(instance: Instance): number
	local cyclesPerSecond = readNumberAttribute(instance, "BobRotationSpeed") or DEFAULT_ROTATION_CYCLES_PER_SECOND
	return math.max(cyclesPerSecond, 0) * TAU
end

local function computeDeterministicPhase(instance: Instance, basePivot: CFrame): number
	local override = readNumberAttribute(instance, "BobPhase")
	if override then
		return override % TAU
	end

	local position = basePivot.Position
	local seed = math.floor(position.X * 73) + math.floor(position.Y * 37) + math.floor(position.Z * 91)
	local name = instance:GetFullName()
	for index = 1, #name do
		seed = (seed + string.byte(name, index) * (index * 17)) % 1000003
	end

	return (seed % 10000) / 10000 * TAU
end

local function refreshRecord(record: BobRecord)
	record.amplitude = computeAmplitude(record.instance, record.instance)
	record.rotationAmplitude = computeRotationAmplitude(record.instance)
	record.rotationSpeedRadians = computeRotationSpeedRadians(record.instance)
	record.speedRadians = computeSpeedRadians(record.instance)
	record.phase = computeDeterministicPhase(record.instance, record.basePivot)
end

local function untrackInstance(instance: Instance, restoreBase: boolean?)
	local record = records[instance]
	if not record then
		return
	end

	if record.attributeConnection then
		record.attributeConnection:Disconnect()
	end
	if restoreBase and record.instance.Parent then
		record.instance:PivotTo(record.basePivot)
	end

	records[instance] = nil
end

local function trackInstance(instance: Instance)
	local target = getTarget(instance)
	if not target or not target:IsDescendantOf(workspace) then
		untrackInstance(instance)
		return
	end

	untrackInstance(instance)

	local basePivot = target:GetPivot()
	local record: BobRecord = {
		instance = target,
		basePivot = basePivot,
		amplitude = computeAmplitude(instance, target),
		rotationAmplitude = computeRotationAmplitude(instance),
		rotationSpeedRadians = computeRotationSpeedRadians(instance),
		speedRadians = computeSpeedRadians(instance),
		phase = computeDeterministicPhase(instance, basePivot),
		elapsed = 0,
		attributeConnection = nil,
	}

	record.attributeConnection = instance.AttributeChanged:Connect(function(attributeName: string)
		if
			attributeName == "BobAmplitude"
			or attributeName == "BobRotationDegrees"
			or attributeName == "BobRotationSpeed"
			or attributeName == "BobSpeed"
			or attributeName == "BobPhase"
		then
			refreshRecord(record)
		end
	end)

	records[instance] = record
end

local function stepBobbedInstances(deltaTime: number)
	for source, record in pairs(records) do
		local instance = record.instance
		if not source.Parent
			or not instance.Parent
			or not instance:IsDescendantOf(workspace)
			or not CollectionService:HasTag(source, BOB_TAG)
		then
			untrackInstance(source)
			continue
		end

		record.elapsed = (record.elapsed + deltaTime) % 120
		local bobOffset = if record.amplitude > 0 and record.speedRadians > 0
			then math.sin(record.elapsed * record.speedRadians + record.phase) * record.amplitude
			else 0
		local yRotation = if record.rotationAmplitude > 0 and record.rotationSpeedRadians > 0
			then math.sin(record.elapsed * record.rotationSpeedRadians + record.phase) * record.rotationAmplitude
			else 0
		local basePosition = record.basePivot.Position
		local baseRotation = record.basePivot - basePosition
		instance:PivotTo(CFrame.new(basePosition + Vector3.new(0, bobOffset, 0)) * CFrame.Angles(0, yRotation, 0) * baseRotation)
	end
end

local function trackExistingInstances()
	for _, instance in ipairs(CollectionService:GetTagged(BOB_TAG)) do
		trackInstance(instance)
	end
end

function BobController:OnStart()
	trackExistingInstances()

	tagAddedConnection = CollectionService:GetInstanceAddedSignal(BOB_TAG):Connect(trackInstance)
	tagRemovedConnection = CollectionService:GetInstanceRemovedSignal(BOB_TAG):Connect(function(instance)
		untrackInstance(instance, true)
	end)
	renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
		local token = RuntimeProfiler.Begin("Client/BobController/Render")
		stepBobbedInstances(deltaTime)
		RuntimeProfiler.End("Client/BobController/Render", token)
	end)
end

function BobController:Destroy()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	if tagAddedConnection then
		tagAddedConnection:Disconnect()
		tagAddedConnection = nil
	end
	if tagRemovedConnection then
		tagRemovedConnection:Disconnect()
		tagRemovedConnection = nil
	end

	for instance in pairs(records) do
		untrackInstance(instance, true)
	end
	table.clear(records)
end

return BobController
