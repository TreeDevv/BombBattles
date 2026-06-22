local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CrateRollConfig = require(ReplicatedStorage.Shared.Config.CrateRollConfig)

local LocalPlayer = Players.LocalPlayer

local HEADER_TAG = "CrateHeader"
local CRATE_TYPE_ATTRIBUTE = "CrateType"
local OPEN_DISTANCE = 18
local CLOSE_DISTANCE = 22
local PROMPT_HEADER_LIFT = Vector3.new(0, 2.25, 0)
local HIGHLIGHT_NAME = "CratePromptHighlight"
local PROMPT_LIFT_ACTIVE_ATTRIBUTE = "CrateHeaderPromptLiftActive"
local RUNTIME_CHANCE_LABEL_ATTRIBUTE = "CrateHeaderRuntimeChanceLabel"
local REVEAL_SCALE_NAME = "CrateHeaderRevealScale"

local PANEL_OPEN_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local PANEL_CLOSE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local LABEL_IN_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LABEL_OUT_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local PROMPT_LIFT_TWEEN = TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PROMPT_DROP_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HIGHLIGHT_IN_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HIGHLIGHT_OUT_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local LABEL_STAGGER_SECONDS = 0.045

local RARITY_COLORS = table.freeze({
	Common = Color3.fromRGB(220, 228, 235),
	Uncommon = Color3.fromRGB(101, 230, 145),
	Rare = Color3.fromRGB(91, 174, 255),
	Epic = Color3.fromRGB(189, 112, 255),
	Legendary = Color3.fromRGB(255, 194, 83),
	Mythic = Color3.fromRGB(255, 92, 148),
})

local HIGHLIGHT_STYLES = table.freeze({
	Basic = table.freeze({
		fillColor = Color3.fromRGB(66, 157, 255),
		outlineColor = Color3.fromRGB(255, 205, 89),
	}),
	Premium = table.freeze({
		fillColor = Color3.fromRGB(183, 112, 255),
		outlineColor = Color3.fromRGB(255, 205, 89),
	}),
	FinisherBasic = table.freeze({
		fillColor = Color3.fromRGB(91, 174, 255),
		outlineColor = Color3.fromRGB(255, 205, 89),
	}),
	FinisherPremium = table.freeze({
		fillColor = Color3.fromRGB(255, 92, 148),
		outlineColor = Color3.fromRGB(255, 205, 89),
	}),
})

type LabelRecord = {
	label: TextLabel,
	textTransparency: number,
	textStrokeTransparency: number,
	textColor: Color3,
	scale: UIScale,
	scaleValue: number,
	strokes: { UIStroke },
	strokeTransparencies: { [UIStroke]: number },
}

type HeaderRecord = {
	header: GuiObject,
	billboard: BillboardGui,
	normal: GuiObject,
	hovered: GuiObject,
	hoveredSize: UDim2,
	hoveredPosition: UDim2,
	hoveredAnchorPoint: Vector2,
	hoveredClipsDescendants: boolean,
	billboardBaseOffset: Vector3,
	labelRecords: { LabelRecord },
	activeTweens: { Tween },
	promptTweens: { Tween },
	connections: { RBXScriptConnection },
	runtimeChanceLabels: { TextLabel },
	promptLiftToken: number,
	promptLiftActive: boolean,
	highlight: Highlight?,
	toggleToken: number,
	targetOpen: boolean,
	isOpen: boolean,
}

local CrateHeaderController = {}

CrateHeaderController._connections = {} :: { RBXScriptConnection }
CrateHeaderController._records = {} :: { [Instance]: HeaderRecord }
CrateHeaderController._rootPart = nil :: BasePart?
CrateHeaderController._heartbeatConnection = nil :: RBXScriptConnection?

local function getCollapsedYSize(size: UDim2): UDim2
	return UDim2.new(size.X.Scale, size.X.Offset, 0, 0)
end

local function formatPercent(weight: number, totalWeight: number): string
	if totalWeight <= 0 then
		return "0%"
	end

	local percent = (weight / totalWeight) * 100
	if math.abs(percent - math.round(percent)) < 0.01 then
		return string.format("%d%%", math.round(percent))
	end

	return string.format("%.1f%%", percent)
end

local function getUpperDisplay(value: string): string
	return string.upper(value)
end

local function getRarityColor(rarity: string): Color3
	return RARITY_COLORS[rarity] or Color3.new(1, 1, 1)
end

local function getOrCreateRevealScale(label: TextLabel): UIScale
	local scale = label:FindFirstChild(REVEAL_SCALE_NAME)
	if scale and scale:IsA("UIScale") then
		return scale
	end

	local newScale = Instance.new("UIScale")
	newScale.Name = REVEAL_SCALE_NAME
	newScale.Scale = 1
	newScale.Parent = label
	return newScale
end

local function findBillboardGui(instance: Instance): BillboardGui?
	local billboard = instance:FindFirstAncestorWhichIsA("BillboardGui")
	if billboard then
		return billboard
	end
	if instance:IsA("BillboardGui") then
		return instance
	end
	return nil
end

local function getWorldPositionFromInstance(instance: Instance?): Vector3?
	if not instance then
		return nil
	end

	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end

	return nil
end

local function getBillboardWorldPosition(billboard: BillboardGui): Vector3?
	local adornee = billboard.Adornee
	return getWorldPositionFromInstance(adornee) or getWorldPositionFromInstance(billboard.Parent)
end

local function getBillboardBaseOffset(billboard: BillboardGui): Vector3
	local offset = billboard.StudsOffsetWorldSpace
	if billboard:GetAttribute(PROMPT_LIFT_ACTIVE_ATTRIBUTE) == true then
		return offset - PROMPT_HEADER_LIFT
	end
	return offset
end

local function getPromptBillboard(prompt: ProximityPrompt): BillboardGui?
	local parent = prompt.Parent
	if parent then
		local billboard = parent:FindFirstChildWhichIsA("BillboardGui")
		if billboard then
			return billboard
		end
	end

	local cursor: Instance? = prompt.Parent
	while cursor do
		if cursor:IsA("BillboardGui") then
			return cursor
		end
		cursor = cursor.Parent
	end
	return nil
end

local function getCrateModelFromPrompt(prompt: ProximityPrompt): Model?
	return prompt:FindFirstAncestorWhichIsA("Model")
end

local function getPromptCrateId(prompt: ProximityPrompt): string
	local value = prompt:GetAttribute(CrateRollConfig.PromptCrateIdAttribute)
	if typeof(value) == "string" then
		return value
	end
	return ""
end

local function getCrateType(instance: Instance): string
	local cursor: Instance? = instance
	while cursor do
		local value = cursor:GetAttribute(CRATE_TYPE_ATTRIBUTE)
		if typeof(value) == "string" then
			return value
		end
		cursor = cursor.Parent
	end
	return ""
end

local function setTextIfPresent(parent: Instance, name: string, text: string)
	local child = parent:FindFirstChild(name)
	if child and child:IsA("TextLabel") then
		child.Text = text
	end
end

local function compareLabels(labelOrder: { [TextLabel]: number }, a: TextLabel, b: TextLabel): boolean
	if a.LayoutOrder ~= b.LayoutOrder then
		return a.LayoutOrder < b.LayoutOrder
	end

	return (labelOrder[a] or 0) < (labelOrder[b] or 0)
end

local function collectTextLabels(root: Instance): { TextLabel }
	local labels = {}
	local labelOrder = {}
	for _, child in ipairs(root:GetChildren()) do
		if child:IsA("TextLabel") then
			table.insert(labels, child)
			labelOrder[child] = #labels
		end
	end

	table.sort(labels, function(a, b)
		return compareLabels(labelOrder, a, b)
	end)
	return labels
end

local function getChanceLabels(record: HeaderRecord, chances: Instance): { TextLabel }
	local labels = collectTextLabels(chances)
	local template = labels[#labels]
	for _ = #labels + 1, #CrateRollConfig.RarityOrder do
		if not template then
			break
		end

		local clone = template:Clone()
		clone:SetAttribute(RUNTIME_CHANCE_LABEL_ATTRIBUTE, true)
		clone.Parent = chances
		table.insert(record.runtimeChanceLabels, clone)
		table.insert(labels, clone)
	end

	return labels
end

local function captureLabels(root: Instance): { LabelRecord }
	local labels = {}
	local labelOrder = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			table.insert(labels, descendant)
			labelOrder[descendant] = #labels
		end
	end
	table.sort(labels, function(a, b)
		return compareLabels(labelOrder, a, b)
	end)

	local records = {}
	for _, label in ipairs(labels) do
		local strokes = {}
		local strokeTransparencies = {}
		for _, descendant in ipairs(label:GetDescendants()) do
			if descendant:IsA("UIStroke") then
				table.insert(strokes, descendant)
				strokeTransparencies[descendant] = descendant.Transparency
			end
		end

		local scale = getOrCreateRevealScale(label)
		table.insert(records, {
			label = label,
			textTransparency = label.TextTransparency,
			textStrokeTransparency = label.TextStrokeTransparency,
			textColor = label.TextColor3,
			scale = scale,
			scaleValue = scale.Scale,
			strokes = strokes,
			strokeTransparencies = strokeTransparencies,
		})
	end

	return records
end

function CrateHeaderController:_disconnectControllerConnections()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}

	if self._heartbeatConnection then
		self._heartbeatConnection:Disconnect()
		self._heartbeatConnection = nil
	end
end

function CrateHeaderController:_disconnectRecord(record: HeaderRecord)
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	record.connections = {}
end

function CrateHeaderController:_cancelTweens(record: HeaderRecord)
	for _, tween in ipairs(record.activeTweens) do
		tween:Cancel()
	end
	record.activeTweens = {}
end

function CrateHeaderController:_cancelPromptTweens(record: HeaderRecord)
	for _, tween in ipairs(record.promptTweens) do
		tween:Cancel()
	end
	record.promptTweens = {}
end

function CrateHeaderController:_trackTween(record: HeaderRecord, tween: Tween): Tween
	table.insert(record.activeTweens, tween)
	tween.Completed:Once(function()
		local index = table.find(record.activeTweens, tween)
		if index then
			table.remove(record.activeTweens, index)
		end
	end)
	return tween
end

function CrateHeaderController:_trackPromptTween(record: HeaderRecord, tween: Tween): Tween
	table.insert(record.promptTweens, tween)
	tween.Completed:Once(function()
		local index = table.find(record.promptTweens, tween)
		if index then
			table.remove(record.promptTweens, index)
		end
	end)
	return tween
end

function CrateHeaderController:_getOrCreateHighlight(record: HeaderRecord, crateModel: Model, crateId: string): Highlight
	local highlight = record.highlight
	if not (highlight and highlight.Parent) then
		local existing = crateModel:FindFirstChild(HIGHLIGHT_NAME)
		highlight = if existing and existing:IsA("Highlight") then existing else nil
		if not highlight then
			highlight = Instance.new("Highlight")
			highlight.Name = HIGHLIGHT_NAME
			highlight.Parent = crateModel
		end
		record.highlight = highlight
	end

	local style = HIGHLIGHT_STYLES[crateId] or HIGHLIGHT_STYLES.Basic
	highlight.Adornee = crateModel
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = style.fillColor
	highlight.OutlineColor = style.outlineColor
	highlight.Enabled = true
	return highlight
end

function CrateHeaderController:_setPromptVisuals(prompt: ProximityPrompt, isShown: boolean)
	if not CollectionService:HasTag(prompt, CrateRollConfig.PromptTag) then
		return
	end

	local billboard = getPromptBillboard(prompt)
	if not billboard then
		return
	end

	local header = billboard:FindFirstChild(HEADER_TAG)
	if not (header and header:IsA("GuiObject")) then
		return
	end

	local record = self._records[header]
	if not record then
		self:_register(header)
		record = self._records[header]
	end
	if not record then
		return
	end

	record.promptLiftToken += 1
	local token = record.promptLiftToken
	record.promptLiftActive = isShown
	record.billboard:SetAttribute(PROMPT_LIFT_ACTIVE_ATTRIBUTE, isShown)
	self:_cancelPromptTweens(record)

	local targetOffset = if isShown then record.billboardBaseOffset + PROMPT_HEADER_LIFT else record.billboardBaseOffset
	self:_trackPromptTween(record, TweenService:Create(record.billboard, if isShown then PROMPT_LIFT_TWEEN else PROMPT_DROP_TWEEN, {
		StudsOffsetWorldSpace = targetOffset,
	})):Play()

	local crateModel = getCrateModelFromPrompt(prompt)
	if not crateModel then
		return
	end

	local crateId = getPromptCrateId(prompt)
	local highlight = self:_getOrCreateHighlight(record, crateModel, crateId)
	if isShown then
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 1
		self:_trackPromptTween(record, TweenService:Create(highlight, HIGHLIGHT_IN_TWEEN, {
			FillTransparency = 0.82,
			OutlineTransparency = 0.08,
		})):Play()
	else
		local fadeTween = self:_trackPromptTween(record, TweenService:Create(highlight, HIGHLIGHT_OUT_TWEEN, {
			FillTransparency = 1,
			OutlineTransparency = 1,
		}))
		fadeTween.Completed:Once(function(playbackState)
			if record.promptLiftToken ~= token or record.promptLiftActive or playbackState ~= Enum.PlaybackState.Completed then
				return
			end
			highlight.Enabled = false
		end)
		fadeTween:Play()
	end
end

function CrateHeaderController:_resetPromptVisuals(record: HeaderRecord)
	record.promptLiftToken += 1
	record.promptLiftActive = false
	self:_cancelPromptTweens(record)
	record.billboard.StudsOffsetWorldSpace = record.billboardBaseOffset
	record.billboard:SetAttribute(PROMPT_LIFT_ACTIVE_ATTRIBUTE, false)
	if record.highlight then
		record.highlight.Enabled = false
		record.highlight:Destroy()
		record.highlight = nil
	end
end

function CrateHeaderController:_setLabelsHidden(record: HeaderRecord)
	for _, labelRecord in ipairs(record.labelRecords) do
		labelRecord.label.TextTransparency = 1
		labelRecord.label.TextStrokeTransparency = 1
		labelRecord.scale.Scale = 0.92
		for _, stroke in ipairs(labelRecord.strokes) do
			stroke.Transparency = 1
		end
	end
end

function CrateHeaderController:_restoreLabels(record: HeaderRecord)
	for _, labelRecord in ipairs(record.labelRecords) do
		labelRecord.label.TextTransparency = labelRecord.textTransparency
		labelRecord.label.TextStrokeTransparency = labelRecord.textStrokeTransparency
		labelRecord.label.TextColor3 = labelRecord.textColor
		labelRecord.scale.Scale = labelRecord.scaleValue
		for _, stroke in ipairs(labelRecord.strokes) do
			local transparency = labelRecord.strokeTransparencies[stroke]
			if transparency ~= nil then
				stroke.Transparency = transparency
			end
		end
	end
end

function CrateHeaderController:_tweenLabelsIn(record: HeaderRecord, token: number)
	for index, labelRecord in ipairs(record.labelRecords) do
		task.delay((index - 1) * LABEL_STAGGER_SECONDS, function()
			if record.toggleToken ~= token or not record.targetOpen then
				return
			end

			self:_trackTween(record, TweenService:Create(labelRecord.label, LABEL_IN_TWEEN, {
				TextTransparency = labelRecord.textTransparency,
				TextStrokeTransparency = labelRecord.textStrokeTransparency,
			})):Play()
			self:_trackTween(record, TweenService:Create(labelRecord.scale, LABEL_IN_TWEEN, {
				Scale = labelRecord.scaleValue,
			})):Play()
			for _, stroke in ipairs(labelRecord.strokes) do
				local transparency = labelRecord.strokeTransparencies[stroke]
				if transparency ~= nil then
					self:_trackTween(record, TweenService:Create(stroke, LABEL_IN_TWEEN, {
						Transparency = transparency,
					})):Play()
				end
			end
		end)
	end
end

function CrateHeaderController:_tweenLabelsOut(record: HeaderRecord)
	for _, labelRecord in ipairs(record.labelRecords) do
		self:_trackTween(record, TweenService:Create(labelRecord.label, LABEL_OUT_TWEEN, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		})):Play()
		self:_trackTween(record, TweenService:Create(labelRecord.scale, LABEL_OUT_TWEEN, {
			Scale = 0.92,
		})):Play()
		for _, stroke in ipairs(labelRecord.strokes) do
			self:_trackTween(record, TweenService:Create(stroke, LABEL_OUT_TWEEN, {
				Transparency = 1,
			})):Play()
		end
	end
end

function CrateHeaderController:_open(record: HeaderRecord)
	if record.targetOpen then
		return
	end

	record.toggleToken += 1
	local token = record.toggleToken
	local wasVisible = record.hovered.Visible
	record.targetOpen = true
	record.isOpen = true
	self:_cancelTweens(record)

	record.normal.Visible = false
	record.hovered.Visible = true
	record.hovered.ClipsDescendants = true
	if not wasVisible then
		record.hovered.Size = getCollapsedYSize(record.hoveredSize)
		self:_setLabelsHidden(record)
	end

	local panelTween = self:_trackTween(record, TweenService:Create(record.hovered, PANEL_OPEN_TWEEN, {
		Size = record.hoveredSize,
	}))
	panelTween:Play()
	self:_tweenLabelsIn(record, token)
end

function CrateHeaderController:_close(record: HeaderRecord)
	if not record.targetOpen and not record.isOpen then
		return
	end

	record.toggleToken += 1
	local token = record.toggleToken
	record.targetOpen = false
	record.isOpen = false
	self:_cancelTweens(record)
	self:_tweenLabelsOut(record)

	local panelTween = self:_trackTween(record, TweenService:Create(record.hovered, PANEL_CLOSE_TWEEN, {
		Size = getCollapsedYSize(record.hoveredSize),
	}))
	panelTween:Play()
	panelTween.Completed:Once(function(playbackState)
		if record.toggleToken ~= token or record.targetOpen or playbackState ~= Enum.PlaybackState.Completed then
			return
		end

		record.hovered.Visible = false
		record.hovered.Size = record.hoveredSize
		record.hovered.Position = record.hoveredPosition
		record.hovered.AnchorPoint = record.hoveredAnchorPoint
		record.hovered.ClipsDescendants = record.hoveredClipsDescendants
		self:_restoreLabels(record)
		record.normal.Visible = true
	end)
end

function CrateHeaderController:_applyCrateText(record: HeaderRecord)
	local crateType = getCrateType(record.header)
	local crateDefinition = CrateRollConfig.GetDefinition(crateType)
	if not crateDefinition then
		warn(("[CrateHeaderController] Unknown CrateType %q on %s"):format(crateType, record.header:GetFullName()))
		return
	end

	setTextIfPresent(record.normal, "Header", crateDefinition.displayName)
	setTextIfPresent(record.hovered, "Header", crateDefinition.displayName)

	local chances = record.hovered:FindFirstChild("Chances")
	if not chances then
		return
	end

	local labels = getChanceLabels(record, chances)
	local totalWeight = 0
	for _, rarity in ipairs(CrateRollConfig.RarityOrder) do
		totalWeight += tonumber(crateDefinition.rarityWeights[rarity]) or 0
	end

	for index, rarity in ipairs(CrateRollConfig.RarityOrder) do
		local label = labels[index]
		if label then
			local weight = tonumber(crateDefinition.rarityWeights[rarity]) or 0
			label.Name = rarity
			label.Text = string.format("%s - %s", getUpperDisplay(rarity), formatPercent(weight, totalWeight))
			label.TextColor3 = getRarityColor(rarity)
			label.Visible = true
		end
	end

	for index = #CrateRollConfig.RarityOrder + 1, #labels do
		labels[index].Visible = false
	end
end

function CrateHeaderController:_resetRecord(record: HeaderRecord)
	record.toggleToken += 1
	record.targetOpen = false
	record.isOpen = false
	self:_resetPromptVisuals(record)
	self:_cancelTweens(record)
	record.normal.Visible = true
	record.hovered.Visible = false
	record.hovered.Size = record.hoveredSize
	record.hovered.Position = record.hoveredPosition
	record.hovered.AnchorPoint = record.hoveredAnchorPoint
	record.hovered.ClipsDescendants = record.hoveredClipsDescendants
	self:_restoreLabels(record)
end

function CrateHeaderController:_unregister(instance: Instance)
	local record = self._records[instance]
	if not record then
		return
	end

	self._records[instance] = nil
	self:_resetRecord(record)
	self:_disconnectRecord(record)
	for _, label in ipairs(record.runtimeChanceLabels) do
		label:Destroy()
	end
	record.runtimeChanceLabels = {}
end

function CrateHeaderController:_register(instance: Instance)
	if self._records[instance] then
		return
	end
	if not instance:IsA("GuiObject") then
		return
	end

	local billboard = findBillboardGui(instance)
	if not billboard then
		return
	end

	local normal = instance:FindFirstChild("Normal")
	local hovered = instance:FindFirstChild("Hovered")
	if not (normal and normal:IsA("GuiObject") and hovered and hovered:IsA("GuiObject")) then
		warn("[CrateHeaderController] Tagged CrateHeader is missing Normal or Hovered: " .. instance:GetFullName())
		return
	end

	local record: HeaderRecord = {
		header = instance,
		billboard = billboard,
		normal = normal,
		hovered = hovered,
		hoveredSize = hovered.Size,
		hoveredPosition = hovered.Position,
		hoveredAnchorPoint = hovered.AnchorPoint,
		hoveredClipsDescendants = hovered.ClipsDescendants,
		billboardBaseOffset = getBillboardBaseOffset(billboard),
		labelRecords = {},
		activeTweens = {},
		promptTweens = {},
		connections = {},
		runtimeChanceLabels = {},
		promptLiftToken = 0,
		promptLiftActive = false,
		highlight = nil,
		toggleToken = 0,
		targetOpen = false,
		isOpen = false,
	}

	self._records[instance] = record
	self:_applyCrateText(record)
	record.labelRecords = captureLabels(hovered)
	self:_resetRecord(record)

	table.insert(record.connections, instance:GetAttributeChangedSignal(CRATE_TYPE_ATTRIBUTE):Connect(function()
		self:_applyCrateText(record)
		record.labelRecords = captureLabels(hovered)
		if not record.targetOpen then
			self:_restoreLabels(record)
		end
	end))
	table.insert(record.connections, instance.AncestryChanged:Connect(function(_, parent)
		if not parent then
			self:_unregister(instance)
		end
	end))
end

function CrateHeaderController:_refreshRootPart()
	local character = LocalPlayer.Character
	self._rootPart = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
end

function CrateHeaderController:_updateProximity()
	local rootPart = self._rootPart
	if not (rootPart and rootPart.Parent) then
		self:_refreshRootPart()
		rootPart = self._rootPart
	end
	if not rootPart then
		return
	end

	local rootPosition = rootPart.Position
	for _, record in pairs(self._records) do
		local headerPosition = getBillboardWorldPosition(record.billboard)
		if headerPosition then
			local distance = (rootPosition - headerPosition).Magnitude
			if not record.targetOpen and distance <= OPEN_DISTANCE then
				self:_open(record)
			elseif record.targetOpen and distance >= CLOSE_DISTANCE then
				self:_close(record)
			end
		end
	end
end

function CrateHeaderController:OnStart()
	self:_disconnectControllerConnections()
	for instance in pairs(self._records) do
		self:_unregister(instance)
	end

	table.insert(self._connections, CollectionService:GetInstanceAddedSignal(HEADER_TAG):Connect(function(instance)
		self:_register(instance)
	end))
	table.insert(self._connections, CollectionService:GetInstanceRemovedSignal(HEADER_TAG):Connect(function(instance)
		self:_unregister(instance)
	end))
	table.insert(self._connections, LocalPlayer.CharacterAdded:Connect(function()
		task.defer(function()
			self:_refreshRootPart()
		end)
	end))
	table.insert(self._connections, LocalPlayer.CharacterRemoving:Connect(function()
		self._rootPart = nil
		for _, record in pairs(self._records) do
			self:_close(record)
			self:_resetPromptVisuals(record)
		end
	end))
	table.insert(self._connections, ProximityPromptService.PromptShown:Connect(function(prompt)
		self:_setPromptVisuals(prompt, true)
	end))
	table.insert(self._connections, ProximityPromptService.PromptHidden:Connect(function(prompt)
		self:_setPromptVisuals(prompt, false)
	end))

	for _, instance in ipairs(CollectionService:GetTagged(HEADER_TAG)) do
		self:_register(instance)
	end
	self:_refreshRootPart()

	self._heartbeatConnection = RunService.Heartbeat:Connect(function()
		self:_updateProximity()
	end)
end

return CrateHeaderController
