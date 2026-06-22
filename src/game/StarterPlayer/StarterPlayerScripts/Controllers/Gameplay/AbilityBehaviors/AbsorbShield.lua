local Players = game:GetService("Players")
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
type BubbleRecord = {
	clone: Instance,
	records: { PartRecord },
	activeEndsAt: number,
	serial: number,
	pulseSerial: number,
	characterConnection: RBXScriptConnection?,
	humanoidConnection: RBXScriptConnection?,
}
type EmpowerRecord = {
	highlight: Highlight,
	tween: Tween?,
	characterConnection: RBXScriptConnection?,
	humanoidConnection: RBXScriptConnection?,
}

local AbsorbShield = {} :: AbilityTypes.ClientBehavior

local ABILITY_ID = "AbsorbShield"
local VISUAL_FOLDER_NAME = "AbsorbShieldVisuals"
local DEFAULT_ASSET_PATH = table.freeze({ "Assets", "Abilities", "AbsorbShield", "AbsorbShield" })

local LocalPlayer = Players.LocalPlayer
local activeBubbles: { [Player]: BubbleRecord } = {}
local empowerHighlights: { [Player]: EmpowerRecord } = {}
local serial = 0

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?): Color3
	local color = definition and definition.vfxColor
	return if typeof(color) == "Color3" then color else Color3.fromRGB(255, 81, 2)
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

local function getTemplate(definition: AbilityDefinition?): Instance?
	local template = findChildPath(ReplicatedStorage, getAssetPath(definition))
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end

	warn("[AbsorbShield] Missing ReplicatedStorage.Assets.Abilities.AbsorbShield.AbsorbShield")
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

local function emitRoot(root: Instance)
	EmitService.Emit(root, "[AbsorbShield]")
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

local function attachToRoot(clone: Instance, rootPart: BasePart): boolean
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
	weld.Name = "AbsorbShieldRootWeld"
	weld.Part0 = rootPart
	weld.Part1 = primaryPart
	weld.Parent = primaryPart
	return true
end

local function disconnectBubble(record: BubbleRecord?)
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

local function destroyBubble(player: Player)
	local record = activeBubbles[player]
	activeBubbles[player] = nil
	disconnectBubble(record)
	if record and record.clone.Parent then
		record.clone:Destroy()
	end
end

local function destroyEmpowerHighlight(player: Player)
	local record = empowerHighlights[player]
	empowerHighlights[player] = nil
	if not record then
		return
	end
	if record.tween then
		record.tween:Cancel()
	end
	if record.characterConnection then
		record.characterConnection:Disconnect()
	end
	if record.humanoidConnection then
		record.humanoidConnection:Disconnect()
	end
	if record.highlight.Parent then
		record.highlight:Destroy()
	end
end

local function tweenBubble(record: BubbleRecord, tweenInfo: TweenInfo, transparency: number, scale: number)
	for _, partRecord in ipairs(record.records) do
		if partRecord.part.Parent then
			TweenService:Create(partRecord.part, tweenInfo, {
				Size = scaledVector(partRecord.finalSize, scale),
				Transparency = transparency,
			}):Play()
		end
		for _, meshRecord in ipairs(partRecord.meshRecords) do
			if meshRecord.mesh.Parent then
				TweenService:Create(meshRecord.mesh, tweenInfo, {
					Scale = scaledVector(meshRecord.finalScale, scale),
				}):Play()
			end
		end
	end
end

local function fadeBubble(player: Player, definition: AbilityDefinition, collapse: boolean)
	local record = activeBubbles[player]
	if not record or not record.clone.Parent then
		return
	end

	record.pulseSerial += 1
	local fadeOutSeconds = math.max(getDefinitionNumber(definition, "fadeOutSeconds", 0.18), 0.01)
	local startScale = math.clamp(getDefinitionNumber(definition, "startScale", 0.35), 0.001, 1)
	local targetScale = if collapse then startScale else 0.001
	local tweenInfo = TweenInfo.new(fadeOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tweenBubble(record, tweenInfo, 1, targetScale)

	task.delay(fadeOutSeconds, function()
		if activeBubbles[player] == record then
			destroyBubble(player)
		elseif record.clone.Parent then
			record.clone:Destroy()
		end
	end)
end

local function pulseBubble(player: Player, definition: AbilityDefinition)
	local record = activeBubbles[player]
	if not record or not record.clone.Parent then
		return
	end

	local pulseScale = math.max(getDefinitionNumber(definition, "pulseScale", 1.04), 1)
	local color = getDefinitionColor(definition)
	local outInfo = TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local backInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	for _, partRecord in ipairs(record.records) do
		if partRecord.part.Parent then
			TweenService:Create(partRecord.part, outInfo, {
				Size = scaledVector(partRecord.finalSize, pulseScale),
				Color = color,
			}):Play()
		end
	end
	task.delay(0.11, function()
		for _, partRecord in ipairs(record.records) do
			if partRecord.part.Parent then
				TweenService:Create(partRecord.part, backInfo, {
					Size = partRecord.finalSize,
				}):Play()
			end
		end
	end)
end

local function flashAndCollapseBubble(player: Player, definition: AbilityDefinition)
	local record = activeBubbles[player]
	if not record or not record.clone.Parent then
		return
	end

	record.pulseSerial += 1
	local color = getDefinitionColor(definition)
	local flashSeconds = math.max(getDefinitionNumber(definition, "absorbFlashSeconds", 0.12), 0.01)
	local collapseSeconds = math.max(getDefinitionNumber(definition, "absorbCollapseSeconds", 0.18), 0.01)
	local flashInfo = TweenInfo.new(flashSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local collapseInfo = TweenInfo.new(collapseSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	for _, partRecord in ipairs(record.records) do
		if partRecord.part.Parent then
			TweenService:Create(partRecord.part, flashInfo, {
				Size = scaledVector(partRecord.finalSize, 1.18),
				Color = color,
				Transparency = 0.35,
			}):Play()
		end
	end

	emitRoot(record.clone)
	task.delay(flashSeconds, function()
		for _, partRecord in ipairs(record.records) do
			if partRecord.part.Parent then
				TweenService:Create(partRecord.part, collapseInfo, {
					Size = scaledVector(partRecord.finalSize, 0.08),
					Transparency = 1,
				}):Play()
			end
			for _, meshRecord in ipairs(partRecord.meshRecords) do
				if meshRecord.mesh.Parent then
					TweenService:Create(meshRecord.mesh, collapseInfo, {
						Scale = scaledVector(meshRecord.finalScale, 0.08),
					}):Play()
				end
			end
		end
	end)

	task.delay(flashSeconds + collapseSeconds, function()
		if activeBubbles[player] == record then
			destroyBubble(player)
		elseif record.clone.Parent then
			record.clone:Destroy()
		end
	end)
end

local function styleHighlights(root: Instance, color: Color3)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Highlight") then
			descendant.FillColor = color
			descendant.OutlineColor = color
			descendant.Enabled = true
		end
	end
end

local function playBubble(player: Player, definition: AbilityDefinition, activeEndsAt: number)
	local character, humanoid, rootPart = getLiveCharacter(player)
	local template = getTemplate(definition)
	if not (character and humanoid and rootPart and template) then
		return
	end

	destroyBubble(player)
	serial += 1
	local clone = template:Clone()
	clone.Name = "AbsorbShield_" .. tostring(player.UserId)
	if not attachToRoot(clone, rootPart) then
		clone:Destroy()
		return
	end

	local color = getDefinitionColor(definition)
	local startScale = math.clamp(getDefinitionNumber(definition, "startScale", 0.35), 0.001, 1)
	local finalTransparency = math.clamp(getDefinitionNumber(definition, "visualTransparency", 0.9), 0, 1)
	styleHighlights(clone, color)

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

		part.Color = color
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
	local record: BubbleRecord = {
		clone = clone,
		records = records,
		activeEndsAt = activeEndsAt,
		serial = serial,
		pulseSerial = 0,
		characterConnection = nil,
		humanoidConnection = nil,
	}
	record.humanoidConnection = humanoid.Died:Connect(function()
		if activeBubbles[player] == record then
			destroyBubble(player)
		end
	end)
	record.characterConnection = character.AncestryChanged:Connect(function(_instance: Instance, parent: Instance?)
		if parent == nil and activeBubbles[player] == record then
			destroyBubble(player)
		end
	end)
	activeBubbles[player] = record

	emitRoot(clone)
	local growthSeconds = math.max(getDefinitionNumber(definition, "growthSeconds", 0.18), 0.01)
	local inInfo = TweenInfo.new(growthSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	tweenBubble(record, inInfo, finalTransparency, 1)

	task.spawn(function()
		task.wait(growthSeconds)
		local pulseSeconds = math.max(getDefinitionNumber(definition, "pulseSeconds", 0.75), 0.2)
		local pulseSerial = record.pulseSerial
		while activeBubbles[player] == record and record.pulseSerial == pulseSerial and workspace:GetServerTimeNow() < activeEndsAt do
			pulseBubble(player, definition)
			task.wait(pulseSeconds)
		end
	end)

	local delaySeconds = math.max(activeEndsAt - workspace:GetServerTimeNow() - getDefinitionNumber(definition, "fadeOutSeconds", 0.18), 0)
	task.delay(delaySeconds, function()
		if activeBubbles[player] == record then
			fadeBubble(player, definition, true)
		end
	end)
end

local function playEmpowerHighlight(player: Player, definition: AbilityDefinition)
	local character, humanoid = getLiveCharacter(player)
	if not (character and humanoid) then
		return
	end

	destroyEmpowerHighlight(player)
	local color = getDefinitionColor(definition)
	local highlight = Instance.new("Highlight")
	highlight.Name = "AbsorbShieldEmpowered_" .. tostring(player.UserId)
	highlight.Adornee = character
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = math.clamp(getDefinitionNumber(definition, "highlightFillTransparency", 0.58), 0, 1)
	highlight.OutlineTransparency = math.clamp(getDefinitionNumber(definition, "highlightOutlineTransparency", 0.05), 0, 1)
	highlight.Parent = getVisualFolder()

	local pulseFill = math.clamp(getDefinitionNumber(definition, "highlightPulseFillTransparency", 0.25), 0, 1)
	local tween = TweenService:Create(
		highlight,
		TweenInfo.new(0.68, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{
			FillTransparency = pulseFill,
			OutlineTransparency = 0,
		}
	)
	tween:Play()

	local record: EmpowerRecord = {
		highlight = highlight,
		tween = tween,
		characterConnection = nil,
		humanoidConnection = nil,
	}
	record.humanoidConnection = humanoid.Died:Connect(function()
		if empowerHighlights[player] == record then
			destroyEmpowerHighlight(player)
		end
	end)
	record.characterConnection = character.AncestryChanged:Connect(function(_instance: Instance, parent: Instance?)
		if parent == nil and empowerHighlights[player] == record then
			destroyEmpowerHighlight(player)
		end
	end)
	empowerHighlights[player] = record
end

function AbsorbShield.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end
	local slotState = context.slotState
	local state = slotState and slotState.state
	if typeof(state) == "table" and state.empowered == true then
		return true
	end

	if context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, nil) then
		local duration = getDefinitionNumber(context.definition, "durationSeconds", 7)
		playBubble(context.localPlayer, context.definition, workspace:GetServerTimeNow() + duration)
	end
	return true
end

function AbsorbShield.OnEffect(context: ClientEffectContext)
	if context.payload.abilityId ~= ABILITY_ID then
		return
	end

	local definition = AbilityConfig.GetDefinition(ABILITY_ID)
	if not definition then
		return
	end

	local payload = context.payload
	local player = payload.player
	if not (typeof(player) == "Instance" and player:IsA("Player")) then
		return
	end

	if context.effectName == "Activated" then
		local activeEndsAt = if typeof(payload.activeEndsAt) == "number" and payload.activeEndsAt > 0
			then payload.activeEndsAt
			else workspace:GetServerTimeNow() + getDefinitionNumber(definition, "durationSeconds", 7)
		playBubble(player, definition, activeEndsAt)
	elseif context.effectName == "AbsorbShieldAbsorbed" then
		flashAndCollapseBubble(player, definition)
		playEmpowerHighlight(player, definition)
	elseif context.effectName == "AbsorbShieldExpired" then
		fadeBubble(player, definition, true)
	elseif context.effectName == "AbsorbShieldEmpowerConsumed" or context.effectName == "AbsorbShieldEmpowerCleared" then
		destroyEmpowerHighlight(player)
	end
end

return AbsorbShield
