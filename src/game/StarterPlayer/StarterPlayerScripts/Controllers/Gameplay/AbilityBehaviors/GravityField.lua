local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local AbilityPlacementFlow = require(ReplicatedStorage.Shared.Common.AbilityPlacementFlow)
local InstanceUtil = require(ReplicatedStorage.Shared.Common.InstanceUtil)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local RoundController = require(script.Parent.Parent:WaitForChild("RoundController"))

type AbilityControllerLike = AbilityTypes.AbilityControllerLike
type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext
type FloorPlacement = {
	position: Vector3,
	facing: Vector3,
	floor: Instance,
}
type PreviewState = {
	active: boolean,
	controller: AbilityControllerLike?,
	slot: string,
	abilityId: string,
	definition: AbilityDefinition?,
	ghost: Instance?,
	inputConnection: RBXScriptConnection?,
	valid: boolean,
	floorPosition: Vector3?,
	facing: Vector3?,
}
type PartRecord = {
	part: BasePart,
	finalSize: Vector3,
	startSize: Vector3,
	finalTransparency: number,
}
type VisualRecord = {
	id: string,
	clone: Instance,
	center: Vector3,
	radius: number,
	activeEndsAt: number,
	records: { PartRecord },
}
type HighlightRecord = {
	highlight: Highlight,
	tween: Tween?,
}

local GravityField = {} :: AbilityTypes.ClientBehavior

local DEFAULT_COLOR = Color3.fromRGB(172, 92, 255)
local PREVIEW_FOLDER_NAME = "GravityFieldPreview"
local VISUAL_FOLDER_NAME = "GravityFieldVisuals"
local HIGHLIGHT_NAME = "GravityFieldInsideHighlight"
local RENDER_STEP_NAME = "BombBattlesGravityFieldPreview"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3
local COMMIT_ACTION_NAME = "BombBattlesGravityFieldCommit"
local COMMIT_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 50
local HIGHLIGHT_STEP_SECONDS = 0.1

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local preview: PreviewState = {
	active = false,
	controller = nil,
	slot = "",
	abilityId = "",
	definition = nil,
	ghost = nil :: Instance?,
	inputConnection = nil :: RBXScriptConnection?,
	valid = false,
	floorPosition = nil :: Vector3?,
	facing = nil :: Vector3?,
}

local activeVisuals: { [string]: VisualRecord } = {}
local highlights: { [Player]: HighlightRecord } = {}
local highlightConnection: RBXScriptConnection? = nil
local lastHighlightStep = 0

local getBaseParts = InstanceUtil.GetBaseParts
local getBounds = InstanceUtil.GetBounds
local pivotTo = InstanceUtil.PivotTo
local scaledVector = InstanceUtil.ScaledVector

local function getTemplate(definition: AbilityDefinition?): Instance?
	local path = definition and definition.assetPath
	if typeof(path) ~= "table" then
		return nil
	end

	local template = InstanceUtil.GetByPath(ReplicatedStorage, path)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

local function getPreviewFolder(): Folder
	local existing = workspace:FindFirstChild(PREVIEW_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = PREVIEW_FOLDER_NAME
	folder.Parent = workspace
	return folder
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

local function getActiveMap(): Instance?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getTargetRoot(): Instance?
	return PracticeRangeTargeting.GetClientTargetRoot(
		Players.LocalPlayer,
		RoundController:Get("state"),
		RoundStates.Active,
		getActiveMap()
	)
end

local function hasUnsafeTaggedAncestor(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		for _, tagName in ipairs(UNSAFE_TAGS) do
			if CollectionService:HasTag(current, tagName) then
				return true
			end
		end
		current = current.Parent
	end
	return false
end

local function flattenDirection(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.zAxis
	end
	return flat.Unit
end

local function getRootPart(): BasePart?
	local character = Players.LocalPlayer.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

local function findFloor(rootPart: BasePart, definition: AbilityDefinition): FloorPlacement?
	local distance = definition.placementDistance or 8
	local rayUp = definition.floorRaycastUp or 8
	local rayDown = definition.floorRaycastDown or 32
	local facing = flattenDirection(rootPart.CFrame.LookVector)
	local target = rootPart.Position + facing * distance
	local rayOrigin = target + Vector3.yAxis * rayUp
	local rayDirection = Vector3.new(0, -(rayUp + rayDown), 0)
	local hit = workspace:Raycast(rayOrigin, rayDirection)
	if not hit then
		return nil
	end
	if hit.Normal.Y < (definition.minFloorNormalY or 0.65) then
		return nil
	end
	if hasUnsafeTaggedAncestor(hit.Instance) then
		return nil
	end

	if not PracticeRangeTargeting.IsInTargetRoot(hit.Instance, getTargetRoot()) then
		return nil
	end

	return {
		position = hit.Position,
		facing = facing,
		floor = hit.Instance,
	}
end

local function alignToFloor(instance: Instance, floorPosition: Vector3, facing: Vector3): (CFrame, Vector3)
	local pivot = CFrame.lookAt(floorPosition, floorPosition + facing)
	pivotTo(instance, pivot)

	local boundsCFrame, boundsSize = getBounds(instance)
	local bottomY = boundsCFrame.Position.Y - boundsSize.Y * 0.5
	local finalPivot = pivot + Vector3.yAxis * (floorPosition.Y - bottomY)
	pivotTo(instance, finalPivot)

	return getBounds(instance)
end

local function disableVfx(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter")
			or descendant:IsA("Beam")
			or descendant:IsA("Trail")
			or descendant:IsA("PointLight")
			or descendant:IsA("SpotLight")
			or descendant:IsA("SurfaceLight")
		then
			descendant.Enabled = false
		end
	end
end

local function setHighlightStyle(root: Instance, color: Color3, fillTransparency: number, outlineTransparency: number)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Highlight") then
			descendant.FillColor = color
			descendant.OutlineColor = color
			descendant.FillTransparency = fillTransparency
			descendant.OutlineTransparency = outlineTransparency
		end
	end
end

local function styleParts(root: Instance, color: Color3, transparency: number)
	for _, part in ipairs(getBaseParts(root)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Color = color
		part.Transparency = transparency
	end
end

local function styleGhost(ghost: Instance, definition: AbilityDefinition)
	styleParts(ghost, definition.previewValidColor or DEFAULT_COLOR, definition.previewTransparency or 0.58)
	setHighlightStyle(ghost, definition.previewValidColor or DEFAULT_COLOR, 0.9, 0.2)
	disableVfx(ghost)
end

local function setGhostColor(ghost: Instance, definition: AbilityDefinition, valid: boolean)
	local color = if valid
		then definition.previewValidColor or DEFAULT_COLOR
		else definition.previewInvalidColor or Color3.fromRGB(255, 68, 68)

	for _, part in ipairs(getBaseParts(ghost)) do
		part.Color = color
	end
	setHighlightStyle(ghost, color, 0.9, 0.2)
end

local function destroyGhost()
	if preview.ghost and preview.ghost.Parent then
		preview.ghost:Destroy()
	end
	preview.ghost = nil
end

local function cancelPreview()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	ContextActionService:UnbindAction(COMMIT_ACTION_NAME)
	if preview.inputConnection then
		preview.inputConnection:Disconnect()
		preview.inputConnection = nil
	end
	destroyGhost()

	preview.active = false
	preview.controller = nil
	preview.slot = ""
	preview.abilityId = ""
	preview.definition = nil
	preview.valid = false
	preview.floorPosition = nil
	preview.facing = nil
end

local function updatePreview()
	if not preview.active then
		return
	end

	local controller = preview.controller
	if not controller or controller:GetEquippedAbilityId(preview.slot) ~= preview.abilityId then
		cancelPreview()
		return
	end

	local rootPart = getRootPart()
	local ghost = preview.ghost
	local definition = preview.definition
	if not (rootPart and ghost and definition) then
		preview.valid = false
		if ghost and definition then
			setGhostColor(ghost, definition, false)
		end
		return
	end

	local floor = findFloor(rootPart, definition)
	if not floor then
		preview.valid = false
		setGhostColor(ghost, definition, false)
		return
	end

	alignToFloor(ghost, floor.position, floor.facing)
	preview.valid = true
	preview.floorPosition = floor.position
	preview.facing = floor.facing
	setGhostColor(ghost, definition, true)
end

local function commitPreview()
	if not preview.active or not preview.valid or not preview.controller then
		return
	end

	preview.controller:SendMessage(preview.slot, AbilityConfig.MessageTypes.Activate, {
		floorPosition = preview.floorPosition,
		facing = preview.facing,
	})
	cancelPreview()
end

local function isCancelInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton2
		or input.KeyCode == Enum.KeyCode.Escape
end

local function handleCommitAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		commitPreview()
	end

	return Enum.ContextActionResult.Sink
end

local function emitCenter(root: Instance)
	local center = root:FindFirstChild("center", true)
	if not (center and center:IsA("Attachment")) then
		return
	end

	EmitService.Emit(center, "[GravityField]")
end

local function startPreview(context: ClientActivateRequestedContext): boolean
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	local template = getTemplate(context.definition)
	if not template then
		warn("[GravityField] Missing ReplicatedStorage.Assets.Abilities.GravityField.Gravity Field")
		return true
	end

	cancelPreview()

	local ghost = template:Clone()
	ghost.Name = "GravityFieldPreview"
	styleGhost(ghost, context.definition)
	ghost.Parent = getPreviewFolder()

	preview.active = true
	preview.controller = context.controller
	preview.slot = context.slot
	preview.abilityId = context.abilityId
	preview.definition = context.definition
	preview.ghost = ghost
	preview.valid = false

	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, updatePreview)
	updatePreview()

	ContextActionService:UnbindAction(COMMIT_ACTION_NAME)
	ContextActionService:BindActionAtPriority(
		COMMIT_ACTION_NAME,
		handleCommitAction,
		false,
		COMMIT_ACTION_PRIORITY,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.Touch,
		Enum.KeyCode.ButtonR2
	)

	preview.inputConnection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if isCancelInput(input) then
			cancelPreview()
		end
	end)

	return true
end

local function removeHighlight(player: Player)
	local record = highlights[player]
	highlights[player] = nil
	if not record then
		return
	end
	if record.tween then
		record.tween:Cancel()
	end
	if record.highlight.Parent then
		record.highlight:Destroy()
	end
end

local function getPlayerRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

local function addOrUpdateHighlight(player: Player, character: Model, definition: AbilityDefinition)
	local record = highlights[player]
	if record and record.highlight.Adornee == character and record.highlight.Parent then
		return
	end
	if record then
		removeHighlight(player)
	end

	local color = definition.visualColor or DEFAULT_COLOR
	local highlight = Instance.new("Highlight")
	highlight.Name = HIGHLIGHT_NAME
	highlight.Adornee = character
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = color
	highlight.FillTransparency = definition.highlightFillTransparency or 0.88
	highlight.OutlineColor = color
	highlight.OutlineTransparency = definition.highlightOutlineTransparency or 0.18
	highlight.Parent = character

	local tween = TweenService:Create(highlight, TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		FillTransparency = 0.78,
		OutlineTransparency = 0.04,
	})
	tween:Play()

	highlights[player] = {
		highlight = highlight,
		tween = tween,
	}
end

local function clearHighlights()
	for player in pairs(highlights) do
		removeHighlight(player)
	end
end

local function stopHighlightLoopIfIdle()
	if next(activeVisuals) ~= nil then
		return
	end
	if highlightConnection then
		highlightConnection:Disconnect()
		highlightConnection = nil
	end
	clearHighlights()
end

local function updateHighlights()
	local definition = AbilityConfig.GetDefinition("GravityField")
	if not definition then
		clearHighlights()
		return
	end

	local desired: { [Player]: Model } = {}
	for _, visual in pairs(activeVisuals) do
		if not visual.clone.Parent then
			continue
		end
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			local rootPart = getPlayerRoot(player)
			if character and rootPart and (rootPart.Position - visual.center).Magnitude <= visual.radius then
				desired[player] = character
			end
		end
	end

	for player, character in pairs(desired) do
		addOrUpdateHighlight(player, character, definition)
	end
	for player in pairs(highlights) do
		if not desired[player] then
			removeHighlight(player)
		end
	end
end

local function ensureHighlightLoop()
	if highlightConnection then
		return
	end
	lastHighlightStep = 0
	highlightConnection = RunService.RenderStepped:Connect(function()
		local currentTime = os.clock()
		if currentTime - lastHighlightStep < HIGHLIGHT_STEP_SECONDS then
			return
		end
		lastHighlightStep = currentTime
		updateHighlights()
		stopHighlightLoopIfIdle()
	end)
end

local function destroyVisual(fieldId: string)
	local visual = activeVisuals[fieldId]
	activeVisuals[fieldId] = nil
	if visual and visual.clone.Parent then
		visual.clone:Destroy()
	end
	stopHighlightLoopIfIdle()
end

local function createPulseShell(definition: AbilityDefinition, cframe: CFrame, finalSize: Vector3)
	local template = getTemplate(definition)
	if not template then
		return
	end

	local shell = template:Clone()
	shell.Name = "GravityFieldPulse"
	pivotTo(shell, cframe)
	disableVfx(shell)
	setHighlightStyle(shell, definition.visualColor or DEFAULT_COLOR, 1, 1)

	local color = definition.visualColor or DEFAULT_COLOR
	local records = {}
	for _, part in ipairs(getBaseParts(shell)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Color = color
		part.Transparency = 0.52
		part.Size = scaledVector(finalSize, 0.12)
		table.insert(records, part)
	end

	shell.Parent = getVisualFolder()
	local tweenInfo = TweenInfo.new(0.46, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, part in ipairs(records) do
		TweenService:Create(part, tweenInfo, {
			Size = scaledVector(finalSize, 1.12),
			Transparency = 1,
		}):Play()
	end
	task.delay(0.5, function()
		if shell.Parent then
			shell:Destroy()
		end
	end)
end

local function pulseVisual(fieldId: string, definition: AbilityDefinition)
	local visual = activeVisuals[fieldId]
	if not visual or not visual.clone.Parent then
		return
	end

	local pulseScale = math.max(tonumber(definition.pulseScale) or 1.08, 1)
	local outInfo = TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local backInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, record in ipairs(visual.records) do
		if record.part.Parent then
			TweenService:Create(record.part, outInfo, {
				Size = scaledVector(record.finalSize, pulseScale),
			}):Play()
		end
	end
	task.delay(0.11, function()
		for _, record in ipairs(visual.records) do
			if record.part.Parent then
				TweenService:Create(record.part, backInfo, {
					Size = record.finalSize,
				}):Play()
			end
		end
	end)

	createPulseShell(definition, visual.clone:GetPivot(), visual.records[1] and visual.records[1].finalSize or Vector3.one)
	emitCenter(visual.clone)
end

local function fadeAndDestroyVisual(fieldId: string, definition: AbilityDefinition)
	local visual = activeVisuals[fieldId]
	if not visual or not visual.clone.Parent then
		return
	end

	local fadeOutSeconds = math.max(tonumber(definition.fadeOutSeconds) or 0.25, 0.01)
	local startScale = math.clamp(tonumber(definition.startScale) or 0.01, 0.001, 1)
	local tweenInfo = TweenInfo.new(fadeOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, record in ipairs(visual.records) do
		if record.part.Parent then
			TweenService:Create(record.part, tweenInfo, {
				Size = scaledVector(record.finalSize, startScale),
				Transparency = 1,
			}):Play()
		end
	end

	task.delay(fadeOutSeconds, function()
		destroyVisual(fieldId)
	end)
end

local function playPlacedVisual(definition: AbilityDefinition, fieldId: string, cframe: CFrame, radius: number, activeEndsAt: number)
	destroyVisual(fieldId)

	local template = getTemplate(definition)
	if not template then
		return
	end

	local clone = template:Clone()
	clone.Name = "GravityField_" .. fieldId
	pivotTo(clone, cframe)

	local startScale = math.clamp(tonumber(definition.startScale) or 0.01, 0.001, 1)
	local color = definition.visualColor or DEFAULT_COLOR
	local finalTransparency = math.clamp(tonumber(definition.visualTransparency) or 0.18, 0, 1)
	local records = {}
	for _, part in ipairs(getBaseParts(clone)) do
		local finalSize = part.Size
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Color = color
		part.Transparency = 1
		part.Size = scaledVector(finalSize, startScale)
		table.insert(records, {
			part = part,
			finalSize = finalSize,
			startSize = part.Size,
			finalTransparency = finalTransparency,
		})
	end
	setHighlightStyle(clone, color, 0.88, 0.12)

	clone.Parent = getVisualFolder()
	local center = cframe.Position
	activeVisuals[fieldId] = {
		id = fieldId,
		clone = clone,
		center = center,
		radius = radius,
		activeEndsAt = activeEndsAt,
		records = records,
	}

	ensureHighlightLoop()
	emitCenter(clone)
	createPulseShell(definition, cframe, records[1] and records[1].finalSize or Vector3.one)

	local growthSeconds = math.max(tonumber(definition.growthSeconds) or 0.32, 0.01)
	local tweenInfo = TweenInfo.new(growthSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	for _, record in ipairs(records) do
		TweenService:Create(record.part, tweenInfo, {
			Size = record.finalSize,
			Transparency = record.finalTransparency,
		}):Play()
	end

	task.spawn(function()
		task.wait(growthSeconds)
		local pulseSeconds = math.max(tonumber(definition.pulseSeconds) or 0.75, 0.15)
		while activeVisuals[fieldId] and workspace:GetServerTimeNow() < activeEndsAt do
			pulseVisual(fieldId, definition)
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

function GravityField.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if preview.active then
		cancelPreview()
	end

	return AbilityPlacementFlow.SendInstant(context)
end

function GravityField.OnEffect(context: ClientEffectContext)
	if context.payload.abilityId ~= "GravityField" then
		return
	end

	local definition = AbilityConfig.GetDefinition("GravityField")
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

	if context.effectName == "GravityFieldPlaced" then
		local cframe = data.cframe
		if typeof(cframe) ~= "CFrame" then
			return
		end
		local radius = if typeof(data.radius) == "number" and data.radius > 0 then data.radius else definition.radius or 15
		local activeEndsAt = if typeof(data.activeEndsAt) == "number" and data.activeEndsAt > 0
			then data.activeEndsAt
			else workspace:GetServerTimeNow() + (definition.durationSeconds or 5)
		playPlacedVisual(definition, fieldId, cframe, radius, activeEndsAt)
	elseif context.effectName == "GravityFieldExpired" then
		fadeAndDestroyVisual(fieldId, definition)
	end
end

return GravityField

