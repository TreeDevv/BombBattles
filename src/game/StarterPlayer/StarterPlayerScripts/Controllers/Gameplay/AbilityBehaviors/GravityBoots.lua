local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type VisualRecord = {
	model: Model,
	serial: number,
}

local GravityBoots = {} :: AbilityTypes.ClientBehavior

local ACTIVE_UNTIL_ATTR = "GravityBoots_ActiveUntil"
local VISUAL_FOLDER_NAME = "GravityBootsVisuals"
local LocalPlayer = Players.LocalPlayer
local predictedCooldownEndsAt = 0
local activeVisuals: { [Player]: VisualRecord } = {}
local visualSerial = 0

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
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

local function getCharacterRoot(player: Player): (Model?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return character, rootPart
	end
	return character, nil
end

local function findFoot(character: Model, side: string): BasePart?
	local candidates = if side == "Left"
		then { "LeftFoot", "LeftLowerLeg", "Left Leg" }
		else { "RightFoot", "RightLowerLeg", "Right Leg" }

	for _, name in ipairs(candidates) do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end

	return nil
end

local function makeCosmeticPart(name: string, color: Color3, transparency: number): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	return part
end

local function weldTo(part: BasePart, target: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = target
	weld.Part1 = part
	weld.Parent = part
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

local function addFootPad(model: Model, character: Model, side: string, color: Color3, transparency: number)
	local foot = findFoot(character, side)
	if not foot then
		return
	end

	local pad = makeCosmeticPart(side .. "GravityBootPad", color, transparency)
	pad.Size = Vector3.new(0.72, 0.16, 0.96)
	pad.CFrame = foot.CFrame
	pad.Parent = model
	weldTo(pad, foot)
end

local function playVisual(player: Player, definition: AbilityDefinition?, activeEndsAt: number)
	local character, rootPart = getCharacterRoot(player)
	if not (character and rootPart) then
		return
	end

	local fadeSeconds = math.max(getDefinitionNumber(definition, "visualFadeSeconds", 0.18), 0.01)
	destroyVisual(player, fadeSeconds)

	visualSerial += 1
	local serial = visualSerial
	local color = getDefinitionColor(definition, "visualColor", Color3.fromRGB(90, 190, 255))
	local transparency = math.clamp(getDefinitionNumber(definition, "visualTransparency", 0.18), 0, 1)

	local model = Instance.new("Model")
	model.Name = "GravityBoots_" .. tostring(player.UserId)

	local ring = makeCosmeticPart("GravityBootsAura", color, math.clamp(transparency + 0.18, 0, 1))
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(4.2, 0.08, 4.2)
	ring.CFrame = rootPart.CFrame * CFrame.new(0, -2.65, 0)
	ring.Parent = model
	weldTo(ring, rootPart)

	addFootPad(model, character, "Left", color, transparency)
	addFootPad(model, character, "Right", color, transparency)

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
