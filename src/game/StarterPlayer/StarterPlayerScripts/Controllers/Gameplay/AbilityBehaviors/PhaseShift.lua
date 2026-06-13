local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local CameraController = require(script.Parent.Parent:WaitForChild("CameraController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type VisualRecord = {
	highlight: Highlight,
	serial: number,
	activeEndsAt: number,
	baseFillTransparency: number,
	baseOutlineTransparency: number,
}

local PhaseShift = {} :: AbilityTypes.ClientBehavior

local ACTIVE_UNTIL_ATTR = "PhaseShift_ActiveUntil"
local VISUAL_FOLDER_NAME = "PhaseShiftVisuals"
local LocalPlayer = Players.LocalPlayer
local RAINBOW_COLORS = {
	Color3.fromRGB(255, 80, 90),
	Color3.fromRGB(255, 190, 70),
	Color3.fromRGB(255, 245, 95),
	Color3.fromRGB(95, 255, 140),
	Color3.fromRGB(80, 220, 255),
	Color3.fromRGB(130, 110, 255),
	Color3.fromRGB(255, 100, 235),
}

local activeVisuals: { [Player]: VisualRecord } = {}
local visualSerial = 0
local predictedCooldownEndsAt = 0

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getCharacter(player: Player): Model?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return if humanoid and humanoid.Health > 0 then character else nil
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

local function getDepthMode(definition: AbilityDefinition?): Enum.HighlightDepthMode
	local depthMode = definition and definition.highlightDepthMode
	if depthMode == "Occluded" then
		return Enum.HighlightDepthMode.Occluded
	end
	return Enum.HighlightDepthMode.AlwaysOnTop
end

local function destroyVisual(player: Player, fadeSeconds: number?)
	local record = activeVisuals[player]
	activeVisuals[player] = nil
	if not (record and record.highlight.Parent) then
		return
	end

	local highlight = record.highlight
	local duration = math.max(fadeSeconds or 0, 0)
	if duration <= 0 then
		highlight:Destroy()
		return
	end

	TweenService:Create(highlight, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	}):Play()
	task.delay(duration, function()
		if highlight.Parent then
			highlight:Destroy()
		end
	end)
end

local function startRainbowLoop(player: Player, serial: number, definition: AbilityDefinition?)
	local cycleSeconds = math.max(getDefinitionNumber(definition, "highlightCycleSeconds", 0.42), 0.05)
	local stepSeconds = cycleSeconds / #RAINBOW_COLORS

	task.spawn(function()
		local colorIndex = 1
		while true do
			local record = activeVisuals[player]
			if not (record and record.serial == serial and record.highlight.Parent) then
				return
			end
			if workspace:GetServerTimeNow() >= record.activeEndsAt then
				return
			end

			colorIndex = (colorIndex % #RAINBOW_COLORS) + 1
			local color = RAINBOW_COLORS[colorIndex]
			TweenService:Create(record.highlight, TweenInfo.new(stepSeconds, Enum.EasingStyle.Linear), {
				FillColor = color,
				OutlineColor = color,
			}):Play()
			task.wait(stepSeconds)
		end
	end)
end

local function playVisual(player: Player, definition: AbilityDefinition?, activeEndsAt: number)
	local character = getCharacter(player)
	if not character then
		return
	end

	local fadeSeconds = math.max(getDefinitionNumber(definition, "highlightFadeSeconds", 0.16), 0.01)
	destroyVisual(player, fadeSeconds)

	visualSerial += 1
	local serial = visualSerial
	local fillTransparency = math.clamp(getDefinitionNumber(definition, "highlightFillTransparency", 0.38), 0, 1)
	local outlineTransparency = math.clamp(getDefinitionNumber(definition, "highlightOutlineTransparency", 0.08), 0, 1)

	local highlight = Instance.new("Highlight")
	highlight.Name = "PhaseShift_" .. tostring(player.UserId)
	highlight.Adornee = character
	highlight.DepthMode = getDepthMode(definition)
	highlight.FillColor = RAINBOW_COLORS[1]
	highlight.OutlineColor = RAINBOW_COLORS[1]
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.Parent = getVisualFolder()

	activeVisuals[player] = {
		highlight = highlight,
		serial = serial,
		activeEndsAt = activeEndsAt,
		baseFillTransparency = fillTransparency,
		baseOutlineTransparency = outlineTransparency,
	}

	TweenService:Create(highlight, TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FillTransparency = fillTransparency,
		OutlineTransparency = outlineTransparency,
	}):Play()
	startRainbowLoop(player, serial, definition)

	local delaySeconds = math.max(activeEndsAt - workspace:GetServerTimeNow() - fadeSeconds, 0)
	task.delay(delaySeconds, function()
		local current = activeVisuals[player]
		if current and current.serial == serial then
			destroyVisual(player, fadeSeconds)
		end
	end)
end

local function playBlockPulse(player: Player, definition: AbilityDefinition?)
	local record = activeVisuals[player]
	if not (record and record.highlight.Parent) then
		return
	end

	local pulseSeconds = math.max(getDefinitionNumber(definition, "highlightPulseSeconds", 0.18), 0.03)
	local pulseFill = math.clamp(getDefinitionNumber(definition, "highlightPulseFillTransparency", 0.12), 0, 1)
	local pulseOutline = math.clamp(getDefinitionNumber(definition, "highlightPulseOutlineTransparency", 0), 0, 1)
	local outInfo = TweenInfo.new(pulseSeconds * 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local backInfo = TweenInfo.new(pulseSeconds * 0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	TweenService:Create(record.highlight, outInfo, {
		FillTransparency = pulseFill,
		OutlineTransparency = pulseOutline,
	}):Play()
	task.delay(pulseSeconds * 0.35, function()
		local current = activeVisuals[player]
		if not (current and current.highlight == record.highlight and record.highlight.Parent) then
			return
		end

		TweenService:Create(record.highlight, backInfo, {
			FillTransparency = record.baseFillTransparency,
			OutlineTransparency = record.baseOutlineTransparency,
		}):Play()
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

local function playLocalFovPunch(definition: AbilityDefinition?, durationKey: string, bonusKey: string)
	local duration = getDefinitionNumber(definition, durationKey, 0)
	local bonus = getDefinitionNumber(definition, bonusKey, 0)
	if duration <= 0 or bonus <= 0 then
		return
	end

	CameraController:PlayAbilityFOVPunch(duration, bonus)
end

function PhaseShift.OnActivateRequested(context: ClientActivateRequestedContext): boolean
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
	playLocalFovPunch(context.definition, "fovPunchDuration", "fovPunchBonus")

	return true
end

function PhaseShift.OnEffect(context: ClientEffectContext)
	if context.payload.abilityId ~= "PhaseShift" then
		return
	end

	local player = context.payload.player
	if not (typeof(player) == "Instance" and player:IsA("Player")) then
		return
	end

	local definition = AbilityConfig.GetDefinition("PhaseShift")
	if not definition then
		return
	end

	if context.effectName == "Activated" then
		local activeEndsAt = if typeof(context.payload.activeEndsAt) == "number" and context.payload.activeEndsAt > 0
			then context.payload.activeEndsAt
			else workspace:GetServerTimeNow() + getDefinitionNumber(definition, "durationSeconds", 1.25)

		if player == context.localPlayer then
			local character = player.Character
			if character then
				character:SetAttribute(ACTIVE_UNTIL_ATTR, activeEndsAt)
			end
		end

		playVisual(player, definition, activeEndsAt)
	elseif context.effectName == "PhaseShiftBlocked" then
		playBlockPulse(player, definition)
		if player == context.localPlayer then
			playLocalFovPunch(definition, "blockFovPunchDuration", "blockFovPunchBonus")
		end
	end
end

return PhaseShift
