local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
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
type MeshRecord = {
	mesh: SpecialMesh,
	finalScale: Vector3,
	startScale: Vector3,
}
type PartRecord = {
	part: BasePart,
	finalTransparency: number,
}
type VisualRecord = {
	clone: Instance,
	meshRecords: { MeshRecord },
	partRecords: { PartRecord },
}

local ReflectShield = {} :: AbilityTypes.ClientBehavior

local PREVIEW_FOLDER_NAME = "ReflectShieldPreview"
local VISUAL_FOLDER_NAME = "ReflectShieldVisuals"
local RENDER_STEP_NAME = "BombBattlesReflectShieldPreview"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3
local COMMIT_ACTION_NAME = "BombBattlesReflectShieldCommit"
local COMMIT_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 50

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

local function getSpecialMeshes(root: Instance): { SpecialMesh }
	local meshes = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("SpecialMesh") then
			table.insert(meshes, descendant)
		end
	end
	return meshes
end

local function getBounds(instance: Instance): (CFrame, Vector3)
	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	end

	local part = instance :: BasePart
	return part.CFrame, part.Size
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

local function alignGhostToFloor(ghost: Instance, floorPosition: Vector3, facing: Vector3): (CFrame, Vector3)
	local pivot = CFrame.lookAt(floorPosition, floorPosition + facing)
	pivotTo(ghost, pivot)

	local boundsCFrame, boundsSize = getBounds(ghost)
	local bottomY = boundsCFrame.Position.Y - boundsSize.Y * 0.5
	local finalPivot = pivot + Vector3.yAxis * (floorPosition.Y - bottomY)
	pivotTo(ghost, finalPivot)

	return getBounds(ghost)
end

local function getPlacementSize(boundsSize: Vector3, definition: AbilityDefinition): Vector3
	local thickness = math.max(tonumber(definition.reflectionThickness) or boundsSize.Z, 0.1)
	return Vector3.new(boundsSize.X, boundsSize.Y, math.min(boundsSize.Z, thickness))
end

local function isProtectedOrCharacter(part: BasePart): boolean
	if hasUnsafeTaggedAncestor(part) then
		return true
	end

	local model = part:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local function isPlacementClear(boundsCFrame: CFrame, boundsSize: Vector3, floor: Instance, definition: AbilityDefinition): boolean
	local placementSize = getPlacementSize(boundsSize, definition)
	local up = boundsCFrame.UpVector
	local overlapSize = Vector3.new(
		math.max(placementSize.X * 0.95, 0.1),
		math.max(placementSize.Y - 0.25, 0.1),
		math.max(placementSize.Z * 0.95, 0.1)
	)
	local overlapCFrame = boundsCFrame + up * 0.18

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}
	local previewFolder = workspace:FindFirstChild(PREVIEW_FOLDER_NAME)
	if previewFolder then
		table.insert(exclude, previewFolder)
	end
	local visualFolder = workspace:FindFirstChild(VISUAL_FOLDER_NAME)
	if visualFolder then
		table.insert(exclude, visualFolder)
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

local function styleGhost(ghost: Instance, definition: AbilityDefinition)
	local transparency = definition.previewTransparency or 0.5
	for _, part in ipairs(getBaseParts(ghost)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = transparency
	end
end

local function setGhostColor(ghost: Instance, definition: AbilityDefinition, valid: boolean)
	local color = if valid
		then definition.previewValidColor or Color3.fromRGB(76, 255, 97)
		else definition.previewInvalidColor or Color3.fromRGB(255, 68, 68)

	for _, part in ipairs(getBaseParts(ghost)) do
		part.Color = color
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

	local boundsCFrame, boundsSize = alignGhostToFloor(ghost, floor.position, floor.facing)
	local valid = isPlacementClear(boundsCFrame, boundsSize, floor.floor, definition)
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

local function startPreview(context: ClientActivateRequestedContext): boolean
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	local template = getTemplate(context.definition)
	if not template then
		warn("[ReflectShield] Missing ReplicatedStorage.Assets.Abilities.ReflectShield.Reflect Shield")
		return true
	end

	cancelPreview()

	local ghost = template:Clone()
	ghost.Name = "ReflectShieldPreview"
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

local function destroyVisual(shieldId: string)
	local visual = activeVisuals[shieldId]
	activeVisuals[shieldId] = nil
	if visual and visual.clone.Parent then
		visual.clone:Destroy()
	end
end

local function fadeAndDestroyVisual(shieldId: string, definition: AbilityDefinition)
	local visual = activeVisuals[shieldId]
	if not visual or not visual.clone.Parent then
		return
	end

	local fadeOutSeconds = math.max(tonumber(definition.fadeOutSeconds) or 0.25, 0.01)
	local outInfo = TweenInfo.new(fadeOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local startScaleX = math.max(tonumber(definition.meshStartScaleX) or 0.01, 0.001)

	for _, record in ipairs(visual.meshRecords) do
		if record.mesh.Parent then
			TweenService:Create(record.mesh, outInfo, {
				Scale = Vector3.new(startScaleX, record.finalScale.Y, record.finalScale.Z),
			}):Play()
		end
	end
	for _, record in ipairs(visual.partRecords) do
		if record.part.Parent then
			TweenService:Create(record.part, outInfo, {
				Transparency = 1,
			}):Play()
		end
	end

	task.delay(fadeOutSeconds, function()
		destroyVisual(shieldId)
	end)
end

local function playPlacedVisual(definition: AbilityDefinition, shieldId: string, cframe: CFrame, activeEndsAt: number)
	destroyVisual(shieldId)

	local template = getTemplate(definition)
	if not template then
		return
	end

	local clone = template:Clone()
	clone.Name = "ReflectShield_" .. shieldId
	pivotTo(clone, cframe)

	local partRecords = {}
	for _, part in ipairs(getBaseParts(clone)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		table.insert(partRecords, {
			part = part,
			finalTransparency = part.Transparency,
		})
	end

	local meshRecords = {}
	local startScaleX = math.max(tonumber(definition.meshStartScaleX) or 0.01, 0.001)
	for _, mesh in ipairs(getSpecialMeshes(clone)) do
		local finalScale = mesh.Scale
		local startScale = Vector3.new(startScaleX, finalScale.Y, finalScale.Z)
		mesh.Scale = startScale
		table.insert(meshRecords, {
			mesh = mesh,
			finalScale = finalScale,
			startScale = startScale,
		})
	end

	clone.Parent = getVisualFolder()
	activeVisuals[shieldId] = {
		clone = clone,
		meshRecords = meshRecords,
		partRecords = partRecords,
	}

	local growthSeconds = math.max(tonumber(definition.growthSeconds) or 0.28, 0.01)
	local inInfo = TweenInfo.new(growthSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	for _, record in ipairs(meshRecords) do
		if record.mesh.Parent then
			TweenService:Create(record.mesh, inInfo, {
				Scale = record.finalScale,
			}):Play()
		end
	end

	local fadeOutSeconds = math.max(tonumber(definition.fadeOutSeconds) or 0.25, 0.01)
	local delaySeconds = math.max(activeEndsAt - workspace:GetServerTimeNow() - fadeOutSeconds, 0)
	task.delay(delaySeconds, function()
		if activeVisuals[shieldId] then
			fadeAndDestroyVisual(shieldId, definition)
		end
	end)
end

local function pulseVisual(shieldId: string)
	local visual = activeVisuals[shieldId]
	if not visual then
		return
	end

	local outInfo = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local backInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, record in ipairs(visual.meshRecords) do
		if record.mesh.Parent then
			TweenService:Create(record.mesh, outInfo, {
				Scale = Vector3.new(record.finalScale.X * 1.06, record.finalScale.Y, record.finalScale.Z),
			}):Play()
		end
	end

	task.delay(0.07, function()
		for _, record in ipairs(visual.meshRecords) do
			if record.mesh.Parent then
				TweenService:Create(record.mesh, backInfo, {
					Scale = record.finalScale,
				}):Play()
			end
		end
	end)
end

local function getEffectData(payload: any): any
	if typeof(payload) == "table" and typeof(payload.payload) == "table" then
		return payload.payload
	end
	return payload
end

function ReflectShield.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if preview.active then
		cancelPreview()
	end

	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, nil)
	return true
end

function ReflectShield.OnEffect(context: ClientEffectContext)
	if context.payload.abilityId ~= "ReflectShield" then
		return
	end

	local definition = AbilityConfig.GetDefinition("ReflectShield")
	if not definition then
		return
	end

	local data = getEffectData(context.payload)
	local shieldId = if typeof(data) == "table" and typeof(data.shieldId) == "string" then data.shieldId else ""
	if shieldId == "" then
		return
	end

	if context.effectName == "ReflectShieldPlaced" then
		local cframe = data.cframe
		if typeof(cframe) ~= "CFrame" then
			return
		end
		local activeEndsAt = if typeof(data.activeEndsAt) == "number" and data.activeEndsAt > 0
			then data.activeEndsAt
			else workspace:GetServerTimeNow() + (definition.durationSeconds or 7)
		playPlacedVisual(definition, shieldId, cframe, activeEndsAt)
	elseif context.effectName == "ReflectShieldExpired" then
		fadeAndDestroyVisual(shieldId, definition)
	elseif context.effectName == "ReflectShieldReflected" then
		pulseVisual(shieldId)
	end
end

return ReflectShield
