local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

local WallBuilder = {}

local PREVIEW_FOLDER_NAME = "WallBuilderPreview"
local RENDER_STEP_NAME = "BombBattlesWallBuilderPreview"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3
local COMMIT_ACTION_NAME = "BombBattlesWallBuilderCommit"
local COMMIT_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 50

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local preview = {
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

local function getByPath(root: Instance, path): Instance?
	local current: Instance? = root
	for _, name in ipairs(path) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getTemplate(definition): Instance?
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

local function findFloor(rootPart: BasePart, definition)
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

local function styleGhost(ghost: Instance, definition)
	local transparency = definition.previewTransparency or 0.5
	for _, part in ipairs(getBaseParts(ghost)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = transparency
	end
end

local function setGhostColor(ghost: Instance, definition, valid: boolean)
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

local function startPreview(context): boolean
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	local template = getTemplate(context.definition)
	if not template then
		warn("[WallBuilder] Missing ReplicatedStorage.Assets.Abilities.WallBuilder.Wall")
		return true
	end

	cancelPreview()

	local ghost = template:Clone()
	ghost.Name = "WallBuilderPreview"
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

function WallBuilder.OnActivateRequested(context): boolean
	if preview.active and preview.slot == context.slot and preview.abilityId == context.abilityId then
		cancelPreview()
		return true
	end

	return startPreview(context)
end

function WallBuilder.OnEffect(_context)
end

return WallBuilder
