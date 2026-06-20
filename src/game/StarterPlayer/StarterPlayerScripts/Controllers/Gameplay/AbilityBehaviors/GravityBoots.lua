local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type BootSideConfig = {
	bootName: string,
	legCandidates: { string },
	referenceLegName: string,
	referenceMotorName: string,
}

type VisualRecord = {
	model: Model,
	serial: number,
}

local GravityBoots = {} :: AbilityTypes.ClientBehavior

local ACTIVE_UNTIL_ATTR = "GravityBoots_ActiveUntil"
local VISUAL_FOLDER_NAME = "GravityBootsVisuals"
local DEFAULT_ASSET_PATH = table.freeze({ "Assets", "Abilities", "GravityBoots", "GravityBoots" })
local BOOT_SIDES: { BootSideConfig } = table.freeze({
	{
		bootName = "LeftBoot",
		legCandidates = { "Left Leg", "LeftLowerLeg", "LeftFoot" },
		referenceLegName = "Left Leg",
		referenceMotorName = "LeftBoot",
	},
	{
		bootName = "RightBoot",
		legCandidates = { "Right Leg", "RightLowerLeg", "RightFoot" },
		referenceLegName = "Right Leg",
		referenceMotorName = "LeftBoot",
	},
})

local LocalPlayer = Players.LocalPlayer
local predictedCooldownEndsAt = 0
local activeVisuals: { [Player]: VisualRecord } = {}
local visualSerial = 0

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
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

local function getBootAsset(definition: AbilityDefinition?): Model?
	local asset = findChildPath(ReplicatedStorage, getAssetPath(definition))
	if asset and asset:IsA("Model") then
		return asset
	end

	warn("[GravityBoots] Missing ReplicatedStorage.Assets.Abilities.GravityBoots.GravityBoots")
	return nil
end

local function findLeg(character: Model, sideConfig: BootSideConfig): BasePart?
	for _, name in ipairs(sideConfig.legCandidates) do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end

	return nil
end

local function findReferenceMotor(assetModel: Model, sideConfig: BootSideConfig): Motor6D?
	local rig = assetModel:FindFirstChild("Rig")
	local referenceLeg = rig and rig:FindFirstChild(sideConfig.referenceLegName)
	if not referenceLeg then
		return nil
	end

	local namedMotor = referenceLeg:FindFirstChild(sideConfig.referenceMotorName)
	if namedMotor and namedMotor:IsA("Motor6D") then
		return namedMotor
	end

	for _, child in ipairs(referenceLeg:GetChildren()) do
		if child:IsA("Motor6D") and child.Part1 and child.Part1.Name == sideConfig.bootName then
			return child
		end
	end

	return nil
end

local function prepareBootPart(boot: BasePart)
	boot.Anchored = false
	boot.CanCollide = false
	boot.CanQuery = false
	boot.CanTouch = false
	boot.Massless = true

	for _, descendant in ipairs(boot:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end
end

local function cloneBoot(model: Model, character: Model, assetModel: Model, sideConfig: BootSideConfig): boolean
	local leg = findLeg(character, sideConfig)
	local template = assetModel:FindFirstChild(sideConfig.bootName)
	local referenceMotor = findReferenceMotor(assetModel, sideConfig)
	if not (leg and template and template:IsA("BasePart") and referenceMotor) then
		warn("[GravityBoots] Missing boot attachment data for " .. sideConfig.bootName)
		return false
	end

	local boot = template:Clone()
	boot.Name = sideConfig.bootName
	prepareBootPart(boot)
	boot.CFrame = leg.CFrame * referenceMotor.C0 * referenceMotor.C1:Inverse()
	boot.Parent = model

	local motor = Instance.new("Motor6D")
	motor.Name = sideConfig.bootName .. "Motor"
	motor.Part0 = leg
	motor.Part1 = boot
	motor.C0 = referenceMotor.C0
	motor.C1 = referenceMotor.C1
	motor.Parent = boot

	return true
end

local function destroyVisual(player: Player, fadeSeconds: number?)
	local record = activeVisuals[player]
	activeVisuals[player] = nil
	if not (record and record.model.Parent) then
		return
	end

	local model = record.model
	local duration = math.max(fadeSeconds or 0, 0)
	if duration <= 0 then
		model:Destroy()
		return
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			TweenService:Create(descendant, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
			}):Play()
		end
	end
	task.delay(duration, function()
		if model.Parent then
			model:Destroy()
		end
	end)
end

local function playVisual(player: Player, definition: AbilityDefinition?, activeEndsAt: number)
	local character = player.Character
	local assetModel = getBootAsset(definition)
	if not (character and assetModel) then
		return
	end

	local fadeSeconds = math.max(getDefinitionNumber(definition, "visualFadeSeconds", 0.18), 0.01)
	destroyVisual(player, fadeSeconds)

	visualSerial += 1
	local serial = visualSerial

	local model = Instance.new("Model")
	model.Name = "GravityBoots_" .. tostring(player.UserId)

	local attachedAny = false
	for _, sideConfig in ipairs(BOOT_SIDES) do
		attachedAny = cloneBoot(model, character, assetModel, sideConfig) or attachedAny
	end
	if not attachedAny then
		model:Destroy()
		return
	end

	model.Parent = getVisualFolder()
	activeVisuals[player] = {
		model = model,
		serial = serial,
	}

	local delaySeconds = math.max(activeEndsAt - workspace:GetServerTimeNow() - fadeSeconds, 0)
	task.delay(delaySeconds, function()
		local current = activeVisuals[player]
		if current and current.serial == serial then
			destroyVisual(player, fadeSeconds)
		end
	end)
end

local function setPredictedActive(definition: AbilityDefinition)
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	local duration = math.max(getDefinitionNumber(definition, "durationSeconds", 0), 0)
	local activeEndsAt = workspace:GetServerTimeNow() + duration
	character:SetAttribute(ACTIVE_UNTIL_ATTR, activeEndsAt)
	return activeEndsAt
end

function GravityBoots.OnActivateRequested(context: ClientActivateRequestedContext): boolean
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

function GravityBoots.OnEffect(context: ClientEffectContext)
	if context.effectName ~= "Activated" or context.payload.abilityId ~= "GravityBoots" then
		return
	end

	local player = context.payload.player
	if not (typeof(player) == "Instance" and player:IsA("Player")) then
		return
	end

	local definition = AbilityConfig.GetDefinition("GravityBoots")
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

return GravityBoots
