local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local CameraController = require(script.Parent.Parent:WaitForChild("CameraController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type MeshRecord = {
	mesh: SpecialMesh,
	finalScale: Vector3,
}
type PartRecord = {
	part: BasePart,
	finalSize: Vector3,
	finalTransparency: number,
	meshRecords: { MeshRecord },
}
type VisualRecord = {
	instances: { Instance },
	emitters: { ParticleEmitter },
	beams: { Beam },
	trails: { Trail },
	lights: { Instance },
	bubble: Instance?,
	records: { PartRecord },
	serial: number,
	activeEndsAt: number,
	characterConnection: RBXScriptConnection?,
	humanoidConnection: RBXScriptConnection?,
	pulseSerial: number,
}

local Infinity = {} :: AbilityTypes.ClientBehavior

local ABILITY_ID = "Infinity"
local ACTIVE_UNTIL_ATTR = "Infinity_ActiveUntil"
local VISUAL_FOLDER_NAME = "InfinityVisuals"
local DEFAULT_ASSET_PATH = table.freeze({ "Assets", "Abilities", "Infinity", "Infinity" })
local DEFAULT_BUBBLE_PATH = table.freeze({ "Assets", "Abilities", "Infinity", "Infinity", "Bubble" })
local DEFAULT_RIG_EFFECTS_PATH = table.freeze({ "Assets", "Abilities", "Infinity", "Infinity", "RigEffects" })
local BODY_PART_TARGETS = table.freeze({
	Head = { "Head" },
	Torso = { "Torso", "UpperTorso", "LowerTorso" },
	["Left Arm"] = { "Left Arm", "LeftUpperArm", "LeftLowerArm", "LeftHand" },
	["Right Arm"] = { "Right Arm", "RightUpperArm", "RightLowerArm", "RightHand" },
	["Left Leg"] = { "Left Leg", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" },
	["Right Leg"] = { "Right Leg", "RightUpperLeg", "RightLowerLeg", "RightFoot" },
	HumanoidRootPart = { "HumanoidRootPart" },
})

local LocalPlayer = Players.LocalPlayer
local activeVisuals: { [Player]: VisualRecord } = {}
local serial = 0
local predictedCooldownEndsAt = 0

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?): Color3
	local color = definition and definition.visualColor
	return if typeof(color) == "Color3" then color else Color3.fromRGB(65, 235, 255)
end

local function findChildPath(root: Instance, path: { any }): Instance?
	local current: Instance? = root
	for _, rawName in ipairs(path) do
		if typeof(rawName) ~= "string" or rawName == "" or not current then
			return nil
		end
		current = current:FindFirstChild(rawName)
	end
	return current
end

local function getBubbleTemplate(definition: AbilityDefinition?): Instance?
	local path = definition and definition.bubbleAssetPath
	local template = findChildPath(ReplicatedStorage, if typeof(path) == "table" then path else DEFAULT_BUBBLE_PATH)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end

	warn("[Infinity] Missing ReplicatedStorage.Assets.Abilities.Infinity.Infinity.Bubble")
	return nil
end

local function getRigEffectsTemplate(definition: AbilityDefinition?): Model?
	local path = definition and definition.rigEffectsAssetPath
	local template = findChildPath(ReplicatedStorage, if typeof(path) == "table" then path else DEFAULT_RIG_EFFECTS_PATH)
	if template and template:IsA("Model") then
		return template
	end

	warn("[Infinity] Missing ReplicatedStorage.Assets.Abilities.Infinity.Infinity.RigEffects")
	return nil
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

local function getLiveCharacter(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return character, humanoid, rootPart
	end
	return character, humanoid, nil
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

local function getPrimaryPart(root: Instance): BasePart?
	if root:IsA("BasePart") then
		return root
	end
	if root:IsA("Model") and root.PrimaryPart then
		return root.PrimaryPart
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
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

local function getBubbleScaleFactor(clone: Instance, definition: AbilityDefinition): number
	local radius = math.max(getDefinitionNumber(definition, "radius", 20), 0.1)
	local maxDimension = 0
	for _, part in ipairs(getBaseParts(clone)) do
		maxDimension = math.max(maxDimension, part.Size.X, part.Size.Y, part.Size.Z)
	end
	if maxDimension <= 0 then
		return 1
	end
	return (radius * 2) / maxDimension
end

local function attachBubbleToRoot(clone: Instance, rootPart: BasePart): boolean
	local primaryPart = getPrimaryPart(clone)
	if not primaryPart then
		return false
	end

	pivotTo(clone, rootPart.CFrame)
	for _, part in ipairs(getBaseParts(clone)) do
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "InfinityBubbleRootWeld"
	weld.Part0 = rootPart
	weld.Part1 = primaryPart
	weld.Parent = primaryPart
	return true
end

local function getTargetParts(character: Model, sourcePartName: string): { BasePart }
	local targets = {}
	local targetNames = BODY_PART_TARGETS[sourcePartName]
	if not targetNames then
		return targets
	end

	for _, targetName in ipairs(targetNames) do
		local target = character:FindFirstChild(targetName)
		if target and target:IsA("BasePart") then
			table.insert(targets, target)
		end
	end

	return targets
end

local function shouldCloneRigChild(child: Instance): boolean
	return child:IsA("ParticleEmitter")
		or child:IsA("Attachment")
		or child:IsA("Beam")
		or child:IsA("Trail")
		or child:IsA("PointLight")
		or child:IsA("SpotLight")
		or child:IsA("SurfaceLight")
end

local function collectEffectDescendants(root: Instance, emitters: { ParticleEmitter }, beams: { Beam }, trails: { Trail }, lights: { Instance })
	if root:IsA("ParticleEmitter") then
		table.insert(emitters, root)
	elseif root:IsA("Beam") then
		table.insert(beams, root)
	elseif root:IsA("Trail") then
		table.insert(trails, root)
	elseif root:IsA("PointLight") or root:IsA("SpotLight") or root:IsA("SurfaceLight") then
		table.insert(lights, root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			table.insert(emitters, descendant)
		elseif descendant:IsA("Beam") then
			table.insert(beams, descendant)
		elseif descendant:IsA("Trail") then
			table.insert(trails, descendant)
		elseif descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
			table.insert(lights, descendant)
		end
	end
end

local function cloneRigEffects(sourceRig: Model, character: Model): ({ Instance }, { ParticleEmitter }, { Beam }, { Trail }, { Instance })
	local instances = {}
	local emitters = {}
	local beams = {}
	local trails = {}
	local lights = {}

	for sourcePartName in pairs(BODY_PART_TARGETS) do
		local sourcePart = sourceRig:FindFirstChild(sourcePartName)
		if not (sourcePart and sourcePart:IsA("BasePart")) then
			continue
		end

		local targets = getTargetParts(character, sourcePartName)
		if #targets == 0 then
			continue
		end

		for _, child in ipairs(sourcePart:GetChildren()) do
			if not shouldCloneRigChild(child) then
				continue
			end

			for _, target in ipairs(targets) do
				local clone = child:Clone()
				clone.Name = "Infinity_" .. child.Name
				clone.Parent = target
				collectEffectDescendants(clone, emitters, beams, trails, lights)
				table.insert(instances, clone)
			end
		end
	end

	return instances, emitters, beams, trails, lights
end

local function getMaxEmitterLifetime(emitters: { ParticleEmitter }): number
	local maxLifetime = 0
	for _, emitter in ipairs(emitters) do
		maxLifetime = math.max(maxLifetime, emitter.Lifetime.Max)
	end
	return maxLifetime
end

local function disconnectVisual(record: VisualRecord?)
	if not record then
		return
	end
	if record.characterConnection then
		record.characterConnection:Disconnect()
	end
	if record.humanoidConnection then
		record.humanoidConnection:Disconnect()
	end
end

local function destroyVisual(player: Player, definition: AbilityDefinition?, fade: boolean?)
	local record = activeVisuals[player]
	activeVisuals[player] = nil
	if not record then
		return
	end
	disconnectVisual(record)
	record.pulseSerial += 1

	for _, emitter in ipairs(record.emitters) do
		if emitter.Parent then
			emitter.Enabled = false
		end
	end
	for _, beam in ipairs(record.beams) do
		if beam.Parent then
			beam.Enabled = false
		end
	end
	for _, trail in ipairs(record.trails) do
		if trail.Parent then
			trail.Enabled = false
		end
	end
	for _, light in ipairs(record.lights) do
		if light.Parent then
			(light :: any).Enabled = false
		end
	end

	local fadeOutSeconds = if fade == true then math.max(getDefinitionNumber(definition, "fadeOutSeconds", 0.25), 0.01) else 0
	if record.bubble and record.bubble.Parent and #record.records > 0 and fadeOutSeconds > 0 then
		local startScale = math.clamp(getDefinitionNumber(definition, "startScale", 0.08), 0.001, 1)
		local tweenInfo = TweenInfo.new(fadeOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		for _, partRecord in ipairs(record.records) do
			if partRecord.part.Parent then
				TweenService:Create(partRecord.part, tweenInfo, {
					Size = scaledVector(partRecord.finalSize, startScale),
					Transparency = 1,
				}):Play()
			end
			for _, meshRecord in ipairs(partRecord.meshRecords) do
				if meshRecord.mesh.Parent then
					TweenService:Create(meshRecord.mesh, tweenInfo, {
						Scale = scaledVector(meshRecord.finalScale, startScale),
					}):Play()
				end
			end
		end
	end

	local cleanupSeconds = math.max(
		getDefinitionNumber(definition, "particleCleanupSeconds", 1.4),
		getMaxEmitterLifetime(record.emitters),
		fadeOutSeconds
	)
	task.delay(cleanupSeconds, function()
		for _, instance in ipairs(record.instances) do
			if instance.Parent then
				instance:Destroy()
			end
		end
	end)
end

local function pulseBubble(player: Player, definition: AbilityDefinition)
	local record = activeVisuals[player]
	if not (record and record.bubble and record.bubble.Parent) then
		return
	end

	local pulseScale = math.max(getDefinitionNumber(definition, "pulseScale", 1.025), 1)
	local color = getDefinitionColor(definition)
	local outInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local backInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, partRecord in ipairs(record.records) do
		if partRecord.part.Parent then
			TweenService:Create(partRecord.part, outInfo, {
				Size = scaledVector(partRecord.finalSize, pulseScale),
				Color = color,
			}):Play()
		end
		for _, meshRecord in ipairs(partRecord.meshRecords) do
			if meshRecord.mesh.Parent then
				TweenService:Create(meshRecord.mesh, outInfo, {
					Scale = scaledVector(meshRecord.finalScale, pulseScale),
				}):Play()
			end
		end
	end
	task.delay(0.12, function()
		for _, partRecord in ipairs(record.records) do
			if partRecord.part.Parent then
				TweenService:Create(partRecord.part, backInfo, {
					Size = partRecord.finalSize,
				}):Play()
			end
			for _, meshRecord in ipairs(partRecord.meshRecords) do
				if meshRecord.mesh.Parent then
					TweenService:Create(meshRecord.mesh, backInfo, {
						Scale = meshRecord.finalScale,
					}):Play()
				end
			end
		end
	end)
end

local function playVisual(player: Player, definition: AbilityDefinition, activeEndsAt: number)
	local character, humanoid, rootPart = getLiveCharacter(player)
	local bubbleTemplate = getBubbleTemplate(definition)
	local rigTemplate = getRigEffectsTemplate(definition)
	if not (character and humanoid and rootPart and bubbleTemplate and rigTemplate) then
		return
	end

	destroyVisual(player, definition, true)
	serial += 1
	local currentSerial = serial
	local instances, emitters, beams, trails, lights = cloneRigEffects(rigTemplate, character)

	local bubble = bubbleTemplate:Clone()
	bubble.Name = "InfinityBubble_" .. tostring(player.UserId)
	if not attachBubbleToRoot(bubble, rootPart) then
		bubble:Destroy()
		return
	end

	local color = getDefinitionColor(definition)
	local startScale = math.clamp(getDefinitionNumber(definition, "startScale", 0.08), 0.001, 1)
	local finalTransparency = math.clamp(getDefinitionNumber(definition, "visualTransparency", 0.82), 0, 1)
	local bubbleScale = getBubbleScaleFactor(bubble, definition)
	local records = {}
	for _, part in ipairs(getBaseParts(bubble)) do
		local finalSize = part.Size * bubbleScale
		local meshRecords = {}
		for _, child in ipairs(part:GetChildren()) do
			if child:IsA("SpecialMesh") then
				local finalMeshScale = child.Scale * bubbleScale
				child.Scale = scaledVector(finalMeshScale, startScale)
				table.insert(meshRecords, {
					mesh = child,
					finalScale = finalMeshScale,
				})
			end
		end
		part.Color = color
		part.Transparency = 1
		part.Size = scaledVector(finalSize, startScale)
		table.insert(records, {
			part = part,
			finalSize = finalSize,
			finalTransparency = finalTransparency,
			meshRecords = meshRecords,
		})
	end
	bubble.Parent = getVisualFolder()
	table.insert(instances, bubble)

	local record: VisualRecord = {
		instances = instances,
		emitters = emitters,
		beams = beams,
		trails = trails,
		lights = lights,
		bubble = bubble,
		records = records,
		serial = currentSerial,
		activeEndsAt = activeEndsAt,
		characterConnection = nil,
		humanoidConnection = nil,
		pulseSerial = 0,
	}
	record.humanoidConnection = humanoid.Died:Connect(function()
		if activeVisuals[player] == record then
			destroyVisual(player, definition, false)
		end
	end)
	record.characterConnection = character.AncestryChanged:Connect(function(_instance: Instance, parent: Instance?)
		if parent == nil and activeVisuals[player] == record then
			destroyVisual(player, definition, false)
		end
	end)
	activeVisuals[player] = record

	local growthSeconds = math.max(getDefinitionNumber(definition, "growthSeconds", 0.24), 0.01)
	local tweenInfo = TweenInfo.new(growthSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	for _, partRecord in ipairs(records) do
		if partRecord.part.Parent then
			TweenService:Create(partRecord.part, tweenInfo, {
				Size = partRecord.finalSize,
				Transparency = partRecord.finalTransparency,
			}):Play()
		end
		for _, meshRecord in ipairs(partRecord.meshRecords) do
			if meshRecord.mesh.Parent then
				TweenService:Create(meshRecord.mesh, tweenInfo, {
					Scale = meshRecord.finalScale,
				}):Play()
			end
		end
	end

	task.spawn(function()
		task.wait(growthSeconds)
		local pulseSeconds = math.max(getDefinitionNumber(definition, "pulseSeconds", 0.52), 0.15)
		local pulseSerial = record.pulseSerial
		while activeVisuals[player] == record and record.pulseSerial == pulseSerial and workspace:GetServerTimeNow() < activeEndsAt do
			pulseBubble(player, definition)
			task.wait(pulseSeconds)
		end
	end)

	local delaySeconds = math.max(activeEndsAt - workspace:GetServerTimeNow() - getDefinitionNumber(definition, "fadeOutSeconds", 0.25), 0)
	task.delay(delaySeconds, function()
		if activeVisuals[player] == record then
			destroyVisual(player, definition, true)
		end
	end)
end

local function setPredictedActive(definition: AbilityDefinition): number?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	local duration = math.max(getDefinitionNumber(definition, "durationSeconds", 6), 0)
	local activeEndsAt = workspace:GetServerTimeNow() + duration
	character:SetAttribute(ACTIVE_UNTIL_ATTR, activeEndsAt)
	return activeEndsAt
end

function Infinity.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	local now = workspace:GetServerTimeNow()
	if context.controller:GetCooldownRemaining(context.slot) > 0 or predictedCooldownEndsAt > now then
		return true
	end

	if not context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, nil) then
		return true
	end

	local activeEndsAt = setPredictedActive(context.definition)
	predictedCooldownEndsAt = now + math.max(getDefinitionNumber(context.definition, "cooldownSeconds", 40), 0)
	if activeEndsAt then
		playVisual(context.localPlayer, context.definition, activeEndsAt)
	end
	CameraController:PlayAbilityFOVPunch(0.28, 6)
	return true
end

function Infinity.OnEffect(context: ClientEffectContext)
	if context.payload.abilityId ~= ABILITY_ID then
		return
	end

	local player = context.payload.player
	if not (typeof(player) == "Instance" and player:IsA("Player")) then
		return
	end

	local definition = AbilityConfig.GetDefinition(ABILITY_ID)
	if not definition then
		return
	end

	if context.effectName == "Activated" then
		local activeEndsAt = if typeof(context.payload.activeEndsAt) == "number" and context.payload.activeEndsAt > 0
			then context.payload.activeEndsAt
			else workspace:GetServerTimeNow() + getDefinitionNumber(definition, "durationSeconds", 6)

		if player == context.localPlayer then
			local character = player.Character
			if character then
				character:SetAttribute(ACTIVE_UNTIL_ATTR, activeEndsAt)
			end
		end

		playVisual(player, definition, activeEndsAt)
	elseif context.effectName == "InfinityBlocked" then
		pulseBubble(player, definition)
	end
end

return Infinity
