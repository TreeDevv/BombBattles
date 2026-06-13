local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local CameraController = require(script.Parent.Parent:WaitForChild("CameraController"))

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
	valid: boolean,
	floorPosition: Vector3?,
	facing: Vector3?,
	inputConnection: RBXScriptConnection?,
}
type ForceFieldMeshRecord = {
	mesh: SpecialMesh,
	finalScale: Vector3,
}
type ActiveVisual = {
	id: string,
	owner: Player,
	folder: Instance,
	centerPiece: Instance,
	forceField: BasePart?,
	meshRecords: { ForceFieldMeshRecord },
	radius: number,
	activeEndsAt: number,
}
type HighlightRecord = {
	highlight: Highlight,
	tween: Tween?,
}
type BeamAttachments = {
	beamEnd: Attachment?,
	beamEffects: Attachment?,
	lightningEffects: Attachment?,
}

local Interceptor = {} :: AbilityTypes.ClientBehavior

local PREVIEW_FOLDER_NAME = "InterceptorPreview"
local RENDER_STEP_NAME = "BombBattlesInterceptorPreview"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3
local COMMIT_ACTION_NAME = "BombBattlesInterceptorCommit"
local COMMIT_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 50
local ABILITIES_FOLDER_NAME = "Abilities"
local INTERCEPTOR_FOLDER_NAME = "Interceptor"
local HIGHLIGHT_STEP_SECONDS = 0.1
local HIGHLIGHT_NAME = "InterceptorTeammateHighlight"

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
	ghost = nil,
	valid = false,
	floorPosition = nil,
	facing = nil,
	inputConnection = nil,
}

local ACTIVE_VISUALS: { [string]: ActiveVisual } = {}
local PENDING_INTERCEPTS: { [string]: { Vector3 } } = {}
local HIGHLIGHTS: { [Player]: HighlightRecord } = {}
local highlightConnection: RBXScriptConnection? = nil
local lastHighlightStep = 0
local emitModule = nil
local emitModuleInitialized = false
local warnedMissingEmitModule = false

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
	if template and template:IsA("Model") then
		return template
	end
	return nil
end

local function getCenterTemplate(definition: AbilityDefinition?): Instance?
	local template = getTemplate(definition)
	local center = template and template:FindFirstChild("CenterPiece")
	if center and (center:IsA("Model") or center:IsA("BasePart")) then
		return center
	end
	return nil
end

local function getForceFieldTemplate(definition: AbilityDefinition?): BasePart?
	local template = getTemplate(definition)
	local forceField = template and template:FindFirstChild("ForceField")
	return if forceField and forceField:IsA("BasePart") then forceField else nil
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

local function getBounds(instance: Instance): (CFrame, Vector3)
	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	end

	local part = instance :: BasePart
	return part.CFrame, part.Size
end

local function getPivot(instance: Instance): CFrame
	if instance:IsA("Model") then
		return instance:GetPivot()
	end
	return (instance :: BasePart).CFrame
end

local function pivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	else
		(instance :: BasePart).CFrame = cframe
	end
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

local function getActiveMap(): Instance?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
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

	local activeMap = getActiveMap()
	if activeMap and not hit.Instance:IsDescendantOf(activeMap) then
		return nil
	end

	return {
		position = hit.Position,
		facing = facing,
		floor = hit.Instance,
	}
end

local function alignGhostToFloor(ghost: Instance, floorPosition: Vector3, facing: Vector3): (CFrame, Vector3)
	local pivot = CFrame.lookAt(floorPosition, floorPosition + facing)
	pivotTo(ghost, pivot)

	local boundsCFrame, boundsSize = getBounds(ghost)
	local bottomY = boundsCFrame.Position.Y - boundsSize.Y * 0.5
	local finalPivot = pivot + Vector3.yAxis * (floorPosition.Y - bottomY)
	pivotTo(ghost, finalPivot)

	return getBounds(ghost)
end

local function isProtectedOrCharacter(part: BasePart): boolean
	if hasUnsafeTaggedAncestor(part) then
		return true
	end

	local model = part:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local function isPlacementClear(boundsCFrame: CFrame, boundsSize: Vector3, floor: Instance): boolean
	local up = boundsCFrame.UpVector
	local overlapSize = Vector3.new(
		math.max(boundsSize.X * 0.95, 0.1),
		math.max(boundsSize.Y - 0.25, 0.1),
		math.max(boundsSize.Z * 0.95, 0.1)
	)
	local overlapCFrame = boundsCFrame + up * 0.18

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}
	local previewFolder = workspace:FindFirstChild(PREVIEW_FOLDER_NAME)
	if previewFolder then
		table.insert(exclude, previewFolder)
	end
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = true

	for _, part in ipairs(workspace:GetPartBoundsInBox(overlapCFrame, overlapSize, params)) do
		if part == floor or part:IsDescendantOf(floor) then
			continue
		end
		if isProtectedOrCharacter(part) then
			return false
		end
		if part.CanCollide and part.Transparency < 1 then
			return false
		end
	end

	return true
end

local function hidePreviewVfx(ghost: Instance)
	for _, descendant in ipairs(ghost:GetDescendants()) do
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

local function styleGhost(ghost: Instance, definition: AbilityDefinition)
	local transparency = definition.previewTransparency or 0.5
	for _, part in ipairs(getBaseParts(ghost)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end

	local cylinder = ghost:FindFirstChild("Cylinder", true)
	if cylinder and cylinder:IsA("BasePart") then
		cylinder.Transparency = transparency
	end

	hidePreviewVfx(ghost)
end

local function setGhostColor(ghost: Instance, definition: AbilityDefinition, _valid: boolean)
	local color = definition.previewValidColor or Color3.fromRGB(76, 255, 97)
	local cylinder = ghost:FindFirstChild("Cylinder", true)
	if not (cylinder and cylinder:IsA("BasePart")) then
		return
	end

	local surfaceAppearance = cylinder:FindFirstChild("SurfaceAppearance")
	if surfaceAppearance and surfaceAppearance:IsA("SurfaceAppearance") then
		surfaceAppearance.Color = color
		surfaceAppearance.EmissiveTint = color
	else
		cylinder.Color = color
	end
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

	if not preview.controller then
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

	local boundsCFrame, boundsSize = alignGhostToFloor(ghost, floor.position, floor.facing)
	local valid = isPlacementClear(boundsCFrame, boundsSize, floor.floor)
	preview.valid = valid
	preview.floorPosition = floor.position
	preview.facing = floor.facing
	setGhostColor(ghost, definition, valid)
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

local function getEmitModule()
	if emitModule then
		return emitModule
	end

	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local moduleScript = packages and packages:FindFirstChild("EmitModule")
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		if not warnedMissingEmitModule then
			warn("[Interceptor] Missing ReplicatedStorage.Packages.EmitModule")
			warnedMissingEmitModule = true
		end
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	if not ok then
		if not warnedMissingEmitModule then
			warn("[Interceptor] Failed to require EmitModule: " .. tostring(result))
			warnedMissingEmitModule = true
		end
		return nil
	end

	emitModule = result
	return emitModule
end

local function ensureEmitModuleInitialized(module): boolean
	if emitModuleInitialized then
		return true
	end
	if not module then
		return false
	end

	local initFn = module.init or module.Init
	if type(initFn) == "function" then
		local ok, err = pcall(function()
			initFn()
		end)
		if not ok then
			warn("[Interceptor] Failed to initialize EmitModule: " .. tostring(err))
			return false
		end
	end

	emitModuleInitialized = true
	return true
end

local function getEffectData(payload: any): any
	if typeof(payload) == "table" and typeof(payload.payload) == "table" then
		return payload.payload
	end
	return payload
end

local function getRuntimeFolder(interceptorId: string): Instance?
	local abilitiesFolder = workspace:FindFirstChild(ABILITIES_FOLDER_NAME)
	local interceptorFolder = abilitiesFolder and abilitiesFolder:FindFirstChild(INTERCEPTOR_FOLDER_NAME)
	return interceptorFolder and interceptorFolder:FindFirstChild(interceptorId)
end

local function getCenterPiece(folder: Instance): Instance?
	local centerPiece = folder:FindFirstChild("CenterPiece")
	if centerPiece and (centerPiece:IsA("Model") or centerPiece:IsA("BasePart")) then
		return centerPiece
	end
	return nil
end

local function getForceFieldCFrame(definition: AbilityDefinition, centerPiece: Instance, forceFieldTemplate: BasePart): CFrame
	local template = getTemplate(definition)
	local centerTemplate = template and template:FindFirstChild("CenterPiece")
	if centerTemplate and (centerTemplate:IsA("Model") or centerTemplate:IsA("BasePart")) then
		local relative = getPivot(centerTemplate):ToObjectSpace(forceFieldTemplate.CFrame)
		return getPivot(centerPiece) * relative
	end

	local boundsCFrame = getBounds(centerPiece)
	return CFrame.new(boundsCFrame.Position)
end

local function scaledVector(vector: Vector3, scale: number): Vector3
	return Vector3.new(
		math.max(vector.X * scale, 0.01),
		math.max(vector.Y * scale, 0.01),
		math.max(vector.Z * scale, 0.01)
	)
end

local function getForceFieldRadius(size: Vector3): number
	return math.max(size.X, size.Y, size.Z) * 0.5
end

local function prepareForceField(forceField: BasePart, definition: AbilityDefinition)
	local startScale = math.clamp(tonumber(definition.startScale) or 0.01, 0.001, 1)
	local finalSize = forceField.Size
	local finalTransparency = forceField.Transparency
	local meshRecords: { ForceFieldMeshRecord } = {}
	for _, descendant in forceField:GetDescendants() do
		if descendant:IsA("SpecialMesh") then
			local mesh = descendant :: SpecialMesh
			table.insert(meshRecords, {
				mesh = mesh,
				finalScale = mesh.Scale,
			})
			mesh.Scale = scaledVector(mesh.Scale, startScale)
		end
	end

	forceField.Anchored = true
	forceField.CanCollide = false
	forceField.CanQuery = false
	forceField.CanTouch = false
	forceField.Massless = true
	forceField.Transparency = 1
	forceField.Size = scaledVector(finalSize, startScale)

	return finalSize, finalTransparency, meshRecords
end

local function tweenForceFieldIn(
	forceField: BasePart,
	definition: AbilityDefinition,
	finalSize: Vector3,
	finalTransparency: number,
	meshRecords: { ForceFieldMeshRecord }
)
	local fadeInSeconds = math.max(tonumber(definition.fadeInSeconds) or 0.18, 0.01)
	local growthSeconds = math.max(tonumber(definition.growthSeconds) or fadeInSeconds, 0.01)
	local tweenInfo = TweenInfo.new(math.max(fadeInSeconds, growthSeconds), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(forceField, tweenInfo, {
		Size = finalSize,
		Transparency = finalTransparency,
	}):Play()
	for _, record in meshRecords do
		if record.mesh.Parent then
			TweenService:Create(record.mesh, tweenInfo, {
				Scale = record.finalScale,
			}):Play()
		end
	end
end

local function removeHighlight(player: Player)
	local record = HIGHLIGHTS[player]
	HIGHLIGHTS[player] = nil
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

local function getTeamName(player: Player): string?
	local teamName = player:GetAttribute("RoundTeam")
	return if typeof(teamName) == "string" and teamName ~= "" then teamName else nil
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

local function addOrUpdateHighlight(player: Player, character: Model)
	local record = HIGHLIGHTS[player]
	if record and record.highlight.Adornee == character and record.highlight.Parent then
		return
	end
	if record then
		removeHighlight(player)
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = HIGHLIGHT_NAME
	highlight.Adornee = character
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = Color3.fromRGB(255, 48, 48)
	highlight.FillTransparency = 0.62
	highlight.OutlineColor = Color3.fromRGB(255, 78, 78)
	highlight.OutlineTransparency = 0.25
	highlight.Parent = character

	local tween = TweenService:Create(highlight, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		FillColor = Color3.fromRGB(255, 225, 225),
		OutlineColor = Color3.fromRGB(255, 205, 205),
		FillTransparency = 0.48,
		OutlineTransparency = 0.08,
	})
	tween:Play()

	HIGHLIGHTS[player] = {
		highlight = highlight,
		tween = tween,
	}
end

local function clearAllHighlights()
	for player in pairs(HIGHLIGHTS) do
		removeHighlight(player)
	end
end

local function updateHighlights()
	local desired: { [Player]: Model } = {}

	for _, visual in pairs(ACTIVE_VISUALS) do
		if not visual.folder.Parent then
			continue
		end

		local ownerTeam = getTeamName(visual.owner)
		if not ownerTeam then
			continue
		end

		local boundsCFrame = getBounds(visual.centerPiece)
		local center = boundsCFrame.Position
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= visual.owner and getTeamName(player) ~= ownerTeam then
				continue
			end

			local character = player.Character
			local rootPart = getPlayerRoot(player)
			if character and rootPart and (rootPart.Position - center).Magnitude <= visual.radius then
				desired[player] = character
			end
		end
	end

	for player, character in pairs(desired) do
		addOrUpdateHighlight(player, character)
	end
	for player in pairs(HIGHLIGHTS) do
		if not desired[player] then
			removeHighlight(player)
		end
	end
end

local function stopHighlightLoopIfIdle()
	if next(ACTIVE_VISUALS) ~= nil then
		return
	end
	if highlightConnection then
		highlightConnection:Disconnect()
		highlightConnection = nil
	end
	clearAllHighlights()
end

local function ensureHighlightLoop()
	if highlightConnection then
		return
	end

	lastHighlightStep = 0
	highlightConnection = RunService.Heartbeat:Connect(function()
		local currentTime = os.clock()
		if currentTime - lastHighlightStep < HIGHLIGHT_STEP_SECONDS then
			return
		end
		lastHighlightStep = currentTime
		updateHighlights()
		stopHighlightLoopIfIdle()
	end)
end

local function expireVisual(interceptorId: string)
	local visual = ACTIVE_VISUALS[interceptorId]
	ACTIVE_VISUALS[interceptorId] = nil
	if not visual then
		stopHighlightLoopIfIdle()
		return
	end

	local forceField = visual.forceField
	if forceField and forceField.Parent then
		local definition = AbilityConfig.GetDefinition("Interceptor")
		local fadeOutSeconds = math.max(tonumber(definition and definition.fadeOutSeconds) or 0.25, 0.01)
		local startScale = math.clamp(tonumber(definition and definition.startScale) or 0.01, 0.001, 1)
		local targetSize = forceField.Size * startScale
		local tweenInfo = TweenInfo.new(fadeOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(forceField, tweenInfo, {
			Size = targetSize,
			Transparency = 1,
		}):Play()
		for _, record in visual.meshRecords do
			if record.mesh.Parent then
				TweenService:Create(record.mesh, tweenInfo, {
					Scale = scaledVector(record.finalScale, startScale),
				}):Play()
			end
		end
		task.delay(fadeOutSeconds, function()
			if forceField.Parent then
				forceField:Destroy()
			end
		end)
	end

	stopHighlightLoopIfIdle()
end

local function getAttachment(parent: Instance?, childName: string): Attachment?
	local child = parent and parent:FindFirstChild(childName)
	return if child and child:IsA("Attachment") then child else nil
end

local function findBeamAttachments(centerPiece: Instance): BeamAttachments
	local cylinder = centerPiece:FindFirstChild("Cylinder", true)
	local blast = cylinder and cylinder:FindFirstChild("Blast")
	return {
		beamEnd = getAttachment(blast, "Beam end"),
		beamEffects = getAttachment(blast, "Beam effects 2"),
		lightningEffects = getAttachment(blast, "Lightning effects 2"),
	}
end

local function setAttachmentWorldCFrame(attachment: Attachment, cframe: CFrame)
	local ok = pcall(function()
		attachment.WorldCFrame = cframe
	end)
	if ok then
		return
	end

	local parent = attachment.Parent
	if parent and parent:IsA("BasePart") then
		attachment.CFrame = parent.CFrame:ToObjectSpace(cframe)
	elseif parent and parent:IsA("Attachment") then
		attachment.CFrame = parent.WorldCFrame:ToObjectSpace(cframe)
	end
end

local function moveAttachmentToWorldPosition(attachment: Attachment, position: Vector3)
	local ok = pcall(function()
		attachment.WorldPosition = position
	end)
	if ok then
		return
	end

	setAttachmentWorldCFrame(attachment, attachment.WorldCFrame - attachment.WorldPosition + position)
end

local function faceAttachmentTowardWorldPosition(attachment: Attachment, targetPosition: Vector3)
	local origin = attachment.WorldPosition
	if (targetPosition - origin).Magnitude <= 0.001 then
		return
	end
	setAttachmentWorldCFrame(attachment, CFrame.lookAt(origin, targetPosition))
end

local function emitBeamEnd(beamEnd: Attachment)
	local module = getEmitModule()
	if not (module and ensureEmitModuleInitialized(module) and type(module.emit) == "function") then
		return
	end

	local ok, err = pcall(function()
		return module.emit(beamEnd)
	end)
	if not ok then
		warn("[Interceptor] Failed to emit intercept VFX: " .. tostring(err))
	end
end

local function playIntercept(interceptorId: string, position: Vector3)
	local visual = ACTIVE_VISUALS[interceptorId]
	if not visual then
		local pending = PENDING_INTERCEPTS[interceptorId]
		if not pending then
			pending = {}
			PENDING_INTERCEPTS[interceptorId] = pending
		end
		table.insert(pending, position)
		return
	end

	local attachments = findBeamAttachments(visual.centerPiece)
	local beamEnd = attachments.beamEnd
	if beamEnd then
		moveAttachmentToWorldPosition(beamEnd, position)
		if attachments.beamEffects then
			faceAttachmentTowardWorldPosition(attachments.beamEffects, beamEnd.WorldPosition)
		end
		if attachments.lightningEffects then
			setAttachmentWorldCFrame(attachments.lightningEffects, beamEnd.WorldCFrame)
		end
		emitBeamEnd(beamEnd)
	end

	if type(CameraController.PlayExplosionShake) == "function" then
		local definition = AbilityConfig.GetDefinition("Interceptor")
		CameraController:PlayExplosionShake(position, if definition then definition.cameraShakeRadius else 45)
	end
end

local function flushPendingIntercepts(interceptorId: string)
	local pending = PENDING_INTERCEPTS[interceptorId]
	PENDING_INTERCEPTS[interceptorId] = nil
	if not pending then
		return
	end

	for _, position in ipairs(pending) do
		playIntercept(interceptorId, position)
	end
end

local function createVisual(interceptorId: string, owner: Player, data)
	local definition = AbilityConfig.GetDefinition("Interceptor")
	if not definition then
		return
	end
	data = if typeof(data) == "table" then data else {}

	local folder = getRuntimeFolder(interceptorId)
	local centerPiece = folder and getCenterPiece(folder)
	local forceFieldTemplate = getForceFieldTemplate(definition)
	if not (folder and centerPiece and forceFieldTemplate) then
		return
	end

	expireVisual(interceptorId)

	local forceField = forceFieldTemplate:Clone()
	forceField.Name = "ForceField"
	forceField.CFrame = getForceFieldCFrame(definition, centerPiece, forceFieldTemplate)
	local finalSize, finalTransparency, meshRecords = prepareForceField(forceField, definition)
	forceField.Parent = folder
	tweenForceFieldIn(forceField, definition, finalSize, finalTransparency, meshRecords)

	local activeEndsAt = if typeof(data.activeEndsAt) == "number" then data.activeEndsAt else workspace:GetServerTimeNow() + 8
	ACTIVE_VISUALS[interceptorId] = {
		id = interceptorId,
		owner = owner,
		folder = folder,
		centerPiece = centerPiece,
		forceField = forceField,
		meshRecords = meshRecords,
		radius = if typeof(data.radius) == "number" then data.radius else getForceFieldRadius(finalSize),
		activeEndsAt = activeEndsAt,
	}

	ensureHighlightLoop()
	flushPendingIntercepts(interceptorId)

	local delaySeconds = math.max(activeEndsAt - workspace:GetServerTimeNow(), 0)
	task.delay(delaySeconds + 0.05, function()
		expireVisual(interceptorId)
	end)
end

local function playPlaced(payload: any)
	local data = getEffectData(payload)
	local interceptorId = if typeof(data) == "table" then data.interceptorId else nil
	local owner = if typeof(payload) == "table" then payload.player else nil
	if typeof(interceptorId) ~= "string" or not (typeof(owner) == "Instance" and owner:IsA("Player")) then
		return
	end

	task.spawn(function()
		local deadline = os.clock() + 2
		while os.clock() < deadline do
			if getRuntimeFolder(interceptorId) then
				createVisual(interceptorId, owner, data)
				return
			end
			task.wait(0.05)
		end
	end)
end

local function playExpired(payload: any)
	local data = getEffectData(payload)
	local interceptorId = if typeof(data) == "table" then data.interceptorId else nil
	if typeof(interceptorId) == "string" then
		expireVisual(interceptorId)
	end
end

local function playIntercepted(payload: any)
	local data = getEffectData(payload)
	if typeof(data) ~= "table" then
		return
	end

	local interceptorId = data.interceptorId
	local position = data.position
	if typeof(interceptorId) == "string" and typeof(position) == "Vector3" then
		playIntercept(interceptorId, position)
	end
end

local function startPreview(context: ClientActivateRequestedContext): boolean
	local centerTemplate = getCenterTemplate(context.definition)
	if not centerTemplate then
		warn("[Interceptor] Missing ReplicatedStorage.Assets.Abilities.Interceptor.Interceptor.CenterPiece")
		return true
	end

	cancelPreview()

	local ghost = centerTemplate:Clone()
	ghost.Name = "InterceptorPreview"
	styleGhost(ghost, context.definition)
	setGhostColor(ghost, context.definition, false)
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

function Interceptor.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if preview.active and preview.slot == context.slot and preview.abilityId == context.abilityId then
		cancelPreview()
		return true
	end

	return startPreview(context)
end

function Interceptor.OnEffect(context: ClientEffectContext)
	if context.payload.abilityId ~= "Interceptor" then
		return
	end

	if context.effectName == "InterceptorPlaced" then
		playPlaced(context.payload)
	elseif context.effectName == "InterceptorExpired" then
		playExpired(context.payload)
	elseif context.effectName == "InterceptorIntercepted" then
		playIntercepted(context.payload)
	end
end

return Interceptor
