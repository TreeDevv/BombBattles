local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext
type MeshRecord = {
	mesh: SpecialMesh,
	finalScale: Vector3,
	startScale: Vector3,
}
type PartRecord = {
	part: BasePart,
	finalSize: Vector3,
	startSize: Vector3,
	finalTransparency: number,
	meshRecords: { MeshRecord },
}
type VisualRecord = {
	id: string,
	clone: Instance,
	records: { PartRecord },
	activeEndsAt: number,
}

local TimeBubble = {} :: AbilityTypes.ClientBehavior

local VISUAL_FOLDER_NAME = "TimeBubbleVisuals"
local activeVisuals: { [string]: VisualRecord } = {}

local function getByPath(root: Instance, path: { string }): Instance?
	local current: Instance? = root
	for _, name in ipairs(path) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getTemplate(definition: AbilityDefinition?): Instance?
	local path = definition and definition.assetPath
	if typeof(path) ~= "table" then
		return nil
	end

	local template = getByPath(ReplicatedStorage, path)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

local function getBaseParts(root: Instance): { BasePart }
	local parts = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function pivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	else
		(instance :: BasePart).CFrame = cframe
	end
end

local function scaledVector(vector: Vector3, scale: number): Vector3
	return Vector3.new(
		math.max(vector.X * scale, 0.01),
		math.max(vector.Y * scale, 0.01),
		math.max(vector.Z * scale, 0.01)
	)
end

local function getVisualFolder(): Folder
	local existing = workspace:FindFirstChild(VISUAL_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = VISUAL_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function emitCenter(root: Instance)
	local center = root:FindFirstChild("center", true)
	if not (center and center:IsA("Attachment")) then
		return
	end

	EmitService.Emit(center, "[TimeBubble]")
end

local function destroyVisual(fieldId: string)
	local visual = activeVisuals[fieldId]
	activeVisuals[fieldId] = nil
	if visual and visual.clone.Parent then
		visual.clone:Destroy()
	end
end

local function tweenRecords(records: { PartRecord }, tweenInfo: TweenInfo, transparency: number, scale: number)
	for _, record in ipairs(records) do
		if record.part.Parent then
			TweenService:Create(record.part, tweenInfo, {
				Size = scaledVector(record.finalSize, scale),
				Transparency = transparency,
			}):Play()
		end
		for _, meshRecord in ipairs(record.meshRecords) do
			if meshRecord.mesh.Parent then
				TweenService:Create(meshRecord.mesh, tweenInfo, {
					Scale = scaledVector(meshRecord.finalScale, scale),
				}):Play()
			end
		end
	end
end

local function fadeAndDestroyVisual(fieldId: string, definition: AbilityDefinition)
	local visual = activeVisuals[fieldId]
	if not visual or not visual.clone.Parent then
		return
	end

	local fadeOutSeconds = math.max(tonumber(definition.fadeOutSeconds) or 0.25, 0.01)
	local startScale = math.clamp(tonumber(definition.startScale) or 0.01, 0.001, 1)
	local tweenInfo = TweenInfo.new(fadeOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tweenRecords(visual.records, tweenInfo, 1, startScale)

	task.delay(fadeOutSeconds, function()
		destroyVisual(fieldId)
	end)
end

local function playPulse(fieldId: string, definition: AbilityDefinition)
	local visual = activeVisuals[fieldId]
	if not visual or not visual.clone.Parent then
		return
	end

	local pulseScale = math.max(tonumber(definition.pulseScale) or 1.06, 1)
	local outInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local backInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, record in ipairs(visual.records) do
		if record.part.Parent then
			TweenService:Create(record.part, outInfo, {
				Size = scaledVector(record.finalSize, pulseScale),
			}):Play()
		end
		for _, meshRecord in ipairs(record.meshRecords) do
			if meshRecord.mesh.Parent then
				TweenService:Create(meshRecord.mesh, outInfo, {
					Scale = scaledVector(meshRecord.finalScale, pulseScale),
				}):Play()
			end
		end
	end
	task.delay(0.12, function()
		for _, record in ipairs(visual.records) do
			if record.part.Parent then
				TweenService:Create(record.part, backInfo, {
					Size = record.finalSize,
				}):Play()
			end
			for _, meshRecord in ipairs(record.meshRecords) do
				if meshRecord.mesh.Parent then
					TweenService:Create(meshRecord.mesh, backInfo, {
						Scale = meshRecord.finalScale,
					}):Play()
				end
			end
		end
	end)

	emitCenter(visual.clone)
end

local function playCreatedVisual(definition: AbilityDefinition, fieldId: string, cframe: CFrame, activeEndsAt: number)
	destroyVisual(fieldId)

	local template = getTemplate(definition)
	if not template then
		return
	end

	local clone = template:Clone()
	clone.Name = "TimeBubble_" .. fieldId
	pivotTo(clone, cframe)

	local startScale = math.clamp(tonumber(definition.startScale) or 0.01, 0.001, 1)
	local color = definition.visualColor
	local finalTransparency = math.clamp(tonumber(definition.visualTransparency) or 0.16, 0, 1)
	local records = {}
	for _, part in ipairs(getBaseParts(clone)) do
		local finalSize = part.Size
		local meshRecords = {}
		for _, child in ipairs(part:GetChildren()) do
			if child:IsA("SpecialMesh") then
				local finalScale = child.Scale
				child.Scale = scaledVector(finalScale, startScale)
				table.insert(meshRecords, {
					mesh = child,
					finalScale = finalScale,
					startScale = child.Scale,
				})
			end
		end

		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		if typeof(color) == "Color3" then
			part.Color = color
		end
		part.Transparency = 1
		part.Size = scaledVector(finalSize, startScale)
		table.insert(records, {
			part = part,
			finalSize = finalSize,
			startSize = part.Size,
			finalTransparency = finalTransparency,
			meshRecords = meshRecords,
		})
	end

	clone.Parent = getVisualFolder()
	activeVisuals[fieldId] = {
		id = fieldId,
		clone = clone,
		records = records,
		activeEndsAt = activeEndsAt,
	}

	emitCenter(clone)
	local growthSeconds = math.max(tonumber(definition.growthSeconds) or 0.3, 0.01)
	local inInfo = TweenInfo.new(growthSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	for _, record in ipairs(records) do
		if record.part.Parent then
			TweenService:Create(record.part, inInfo, {
				Size = record.finalSize,
				Transparency = record.finalTransparency,
			}):Play()
		end
		for _, meshRecord in ipairs(record.meshRecords) do
			if meshRecord.mesh.Parent then
				TweenService:Create(meshRecord.mesh, inInfo, {
					Scale = meshRecord.finalScale,
				}):Play()
			end
		end
	end

	task.spawn(function()
		task.wait(growthSeconds)
		local pulseSeconds = math.max(tonumber(definition.pulseSeconds) or 0.7, 0.15)
		while activeVisuals[fieldId] and workspace:GetServerTimeNow() < activeEndsAt do
			playPulse(fieldId, definition)
			task.wait(pulseSeconds)
		end
	end)

	local delaySeconds = math.max(activeEndsAt - workspace:GetServerTimeNow() - (definition.fadeOutSeconds or 0.25), 0)
	task.delay(delaySeconds, function()
		if activeVisuals[fieldId] then
			fadeAndDestroyVisual(fieldId, definition)
		end
	end)
end

local function getEffectData(payload: any): any
	if typeof(payload) == "table" and typeof(payload.payload) == "table" then
		return payload.payload
	end
	return payload
end

function TimeBubble.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, nil)
	return true
end

function TimeBubble.OnEffect(context: ClientEffectContext)
	if context.payload.abilityId ~= "TimeBubble" then
		return
	end

	local definition = AbilityConfig.GetDefinition("TimeBubble")
	if not definition then
		return
	end

	local data = getEffectData(context.payload)
	if typeof(data) ~= "table" then
		return
	end

	local fieldId = data.fieldId
	if typeof(fieldId) ~= "string" then
		return
	end

	if context.effectName == "TimeBubbleCreated" then
		local cframe = data.cframe
		if typeof(cframe) ~= "CFrame" then
			return
		end
		local activeEndsAt = if typeof(data.activeEndsAt) == "number" and data.activeEndsAt > 0
			then data.activeEndsAt
			else workspace:GetServerTimeNow() + (definition.durationSeconds or 5)
		playCreatedVisual(definition, fieldId, cframe, activeEndsAt)
	elseif context.effectName == "TimeBubbleExpired" then
		fadeAndDestroyVisual(fieldId, definition)
	end
end

return TimeBubble
