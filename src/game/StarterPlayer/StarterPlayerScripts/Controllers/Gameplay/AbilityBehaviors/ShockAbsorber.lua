local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type BodyPartMap = { [string]: { string } }
type VisualRecord = {
	instances: { Instance },
	emitters: { ParticleEmitter },
	highlight: Highlight?,
	serial: number,
	activeEndsAt: number,
	characterConnection: RBXScriptConnection?,
	humanoidConnection: RBXScriptConnection?,
}

local ShockAbsorber = {} :: AbilityTypes.ClientBehavior

local ABILITY_ID = "ShockAbsorber"
local ACTIVE_UNTIL_ATTR = "ShockAbsorber_ActiveUntil"
local VISUAL_FOLDER_NAME = "ShockAbsorberVisuals"
local DEFAULT_ASSET_PATH = table.freeze({ "Assets", "Abilities", "ShockAbsorber", "ShockAbsorber", "Rig" })
local BODY_PART_TARGETS: BodyPartMap = table.freeze({
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
local visualSerial = 0
local predictedCooldownEndsAt = 0

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
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

local function getAssetPath(definition: AbilityDefinition?): { any }
	local path = definition and definition.assetPath
	return if typeof(path) == "table" then path else DEFAULT_ASSET_PATH
end

local function getReferenceRig(definition: AbilityDefinition?): Model?
	local asset = findChildPath(ReplicatedStorage, getAssetPath(definition))
	if asset and asset:IsA("Model") then
		return asset
	end

	warn("[ShockAbsorber] Missing ReplicatedStorage.Assets.Abilities.ShockAbsorber.ShockAbsorber.Rig")
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

local function getLiveCharacter(player: Player): Model?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return if humanoid and humanoid.Health > 0 then character else nil
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

local function getMaxEmitterLifetime(emitters: { ParticleEmitter }): number
	local maxLifetime = 0
	for _, emitter in ipairs(emitters) do
		local lifetime = emitter.Lifetime
		maxLifetime = math.max(maxLifetime, lifetime.Max)
	end
	return maxLifetime
end

local function destroyVisual(player: Player, fadeSeconds: number?, cleanupSeconds: number?)
	local record = activeVisuals[player]
	activeVisuals[player] = nil
	if not record then
		return
	end
	if record.characterConnection then
		record.characterConnection:Disconnect()
	end
	if record.humanoidConnection then
		record.humanoidConnection:Disconnect()
	end

	for _, emitter in ipairs(record.emitters) do
		if emitter.Parent then
			emitter.Enabled = false
		end
	end

	local duration = math.max(fadeSeconds or 0, 0)
	if record.highlight and record.highlight.Parent then
		local highlight = record.highlight
		if duration <= 0 then
			highlight:Destroy()
		else
			TweenService:Create(highlight, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				FillTransparency = 1,
				OutlineTransparency = 1,
			}):Play()
		end
	end

	local emitterLifetime = getMaxEmitterLifetime(record.emitters)
	local delaySeconds = math.max(cleanupSeconds or 0, emitterLifetime, duration)
	task.delay(delaySeconds, function()
		for _, instance in ipairs(record.instances) do
			if instance.Parent then
				instance:Destroy()
			end
		end
	end)
end

local function cloneParticleEmitters(sourceRig: Model, character: Model): ({ Instance }, { ParticleEmitter })
	local instances = {}
	local emitters = {}

	for sourcePartName in pairs(BODY_PART_TARGETS) do
		local sourcePart = sourceRig:FindFirstChild(sourcePartName)
		if not (sourcePart and sourcePart:IsA("BasePart")) then
			continue
		end

		local targets = getTargetParts(character, sourcePartName)
		if #targets == 0 then
			continue
		end

		for _, descendant in ipairs(sourcePart:GetDescendants()) do
			if not descendant:IsA("ParticleEmitter") then
				continue
			end

			for _, target in ipairs(targets) do
				local emitter = descendant:Clone()
				emitter.Name = "ShockAbsorber_" .. descendant.Name
				emitter.Enabled = descendant.Enabled
				emitter.Parent = target
				table.insert(instances, emitter)
				table.insert(emitters, emitter)
			end
		end
	end

	return instances, emitters
end

local function cloneHighlight(sourceRig: Model, character: Model, player: Player): Highlight?
	local template = sourceRig:FindFirstChildWhichIsA("Highlight", true)
	if not template then
		return nil
	end

	local highlight = template:Clone()
	highlight.Name = "ShockAbsorber_" .. tostring(player.UserId)
	highlight.Adornee = character
	highlight.Enabled = true
	highlight.Parent = getVisualFolder()
	return highlight
end

local function playVisual(player: Player, definition: AbilityDefinition?, activeEndsAt: number)
	local character = getLiveCharacter(player)
	local sourceRig = getReferenceRig(definition)
	if not (character and sourceRig) then
		return
	end

	local fadeSeconds = math.max(getDefinitionNumber(definition, "visualFadeSeconds", 0.18), 0.01)
	local cleanupSeconds = math.max(getDefinitionNumber(definition, "particleCleanupSeconds", 1.1), 0)
	destroyVisual(player, fadeSeconds, cleanupSeconds)

	visualSerial += 1
	local serial = visualSerial
	local instances, emitters = cloneParticleEmitters(sourceRig, character)
	local highlight = cloneHighlight(sourceRig, character, player)
	if highlight then
		table.insert(instances, highlight)
	end

	if #instances == 0 then
		return
	end

	local record: VisualRecord = {
		instances = instances,
		emitters = emitters,
		highlight = highlight,
		serial = serial,
		activeEndsAt = activeEndsAt,
		characterConnection = nil,
		humanoidConnection = nil,
	}
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		record.humanoidConnection = humanoid.Died:Connect(function()
			if activeVisuals[player] == record then
				destroyVisual(player, fadeSeconds, cleanupSeconds)
			end
		end)
	end
	record.characterConnection = character.AncestryChanged:Connect(function(_instance: Instance, parent: Instance?)
		if parent == nil and activeVisuals[player] == record then
			destroyVisual(player, 0, cleanupSeconds)
		end
	end)
	activeVisuals[player] = record

	local delaySeconds = math.max(activeEndsAt - workspace:GetServerTimeNow() - fadeSeconds, 0)
	task.delay(delaySeconds, function()
		local current = activeVisuals[player]
		if current and current.serial == serial then
			destroyVisual(player, fadeSeconds, cleanupSeconds)
		end
	end)
end

local function setPredictedActive(definition: AbilityDefinition): number?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	local duration = math.max(getDefinitionNumber(definition, "durationSeconds", 0), 0)
	local activeEndsAt = workspace:GetServerTimeNow() + duration
	character:SetAttribute(ACTIVE_UNTIL_ATTR, activeEndsAt)
	return activeEndsAt
end

function ShockAbsorber.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	local now = workspace:GetServerTimeNow()
	if context.controller:GetCooldownRemaining(context.slot) > 0 or predictedCooldownEndsAt > now then
		return true
	end

	if not context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, nil) then
		return true
	end

	local activeEndsAt = setPredictedActive(context.definition)
	predictedCooldownEndsAt = now + math.max(getDefinitionNumber(context.definition, "cooldownSeconds", 0), 0)
	if activeEndsAt then
		playVisual(context.localPlayer, context.definition, activeEndsAt)
	end

	return true
end

function ShockAbsorber.OnEffect(context: ClientEffectContext)
	if context.effectName ~= "Activated" or context.payload.abilityId ~= ABILITY_ID then
		return
	end

	local player = context.payload.player
	if not (typeof(player) == "Instance" and player:IsA("Player")) then
		return
	end

	local definition = AbilityConfig.GetDefinition(ABILITY_ID)
	local activeEndsAt = if typeof(context.payload.activeEndsAt) == "number" and context.payload.activeEndsAt > 0
		then context.payload.activeEndsAt
		else workspace:GetServerTimeNow() + getDefinitionNumber(definition, "durationSeconds", 5)

	if player == context.localPlayer then
		local character = player.Character
		if character then
			character:SetAttribute(ACTIVE_UNTIL_ATTR, activeEndsAt)
		end
	end

	playVisual(player, definition, activeEndsAt)
end

return ShockAbsorber
