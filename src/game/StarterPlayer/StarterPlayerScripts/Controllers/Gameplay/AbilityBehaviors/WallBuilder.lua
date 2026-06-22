local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local AbilityPlacementFlow = require(ReplicatedStorage.Shared.Common.AbilityPlacementFlow)
local PlacementSurfaceUtil = require(ReplicatedStorage.Shared.Common.PlacementSurfaceUtil)
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
	normal: Vector3,
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
	surfacePosition: Vector3?,
	surfaceNormal: Vector3?,
	floorPosition: Vector3?,
	floatingPosition: Vector3?,
	facing: Vector3?,
}

local WallBuilder = {} :: AbilityTypes.ClientBehavior

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

local preview: PreviewState = {
	active = false,
	controller = nil,
	slot = "",
	abilityId = "",
	definition = nil,
	ghost = nil :: Instance?,
	inputConnection = nil :: RBXScriptConnection?,
	valid = false,
	surfacePosition = nil :: Vector3?,
	surfaceNormal = nil :: Vector3?,
	floorPosition = nil :: Vector3?,
	floatingPosition = nil :: Vector3?,
	facing = nil :: Vector3?,
}

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

local function getTargetRoot(): Instance?
	return PracticeRangeTargeting.GetClientTargetRoot(
		Players.LocalPlayer,
		RoundController:Get("state"),
		RoundStates.Active,
		getActiveMap()
	)
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

local function getPlacementExcludes(): { Instance }
	local exclude = {}
	local character = Players.LocalPlayer.Character
	if character then
		table.insert(exclude, character)
	end
	local previewFolder = workspace:FindFirstChild(PREVIEW_FOLDER_NAME)
	if previewFolder then
		table.insert(exclude, previewFolder)
	end
	return exclude
end

local function findSurface(rootPart: BasePart, definition: AbilityDefinition): FloorPlacement?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	return PlacementSurfaceUtil.ResolveAimedSurfacePlacement({
		rootPart = rootPart,
		definition = definition,
		rayOrigin = ray.Origin,
		rayDirection = ray.Direction,
		targetRoot = getTargetRoot(),
		unsafeTags = UNSAFE_TAGS,
		excludeInstances = getPlacementExcludes(),
	})
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
	preview.surfacePosition = nil
	preview.surfaceNormal = nil
	preview.floorPosition = nil
	preview.floatingPosition = nil
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

	local surface = findSurface(rootPart, definition)
	if not surface then
		preview.valid = false
		setGhostColor(ghost, definition, false)
		return
	end

	local boundsCFrame, boundsSize = PlacementSurfaceUtil.AlignToFloor(ghost, surface)
	local valid = PlacementSurfaceUtil.IsPlacementClear({
		boundsCFrame = boundsCFrame,
		boundsSize = boundsSize,
		support = surface.floor,
		unsafeTags = UNSAFE_TAGS,
		excludeInstances = getPlacementExcludes(),
	})
	preview.valid = valid
	preview.surfacePosition = surface.position
	preview.surfaceNormal = surface.normal
	preview.facing = surface.facing
	setGhostColor(ghost, definition, valid)
end

local function commitPreview()
	if not preview.active or not preview.valid or not preview.controller then
		return
	end

	preview.controller:SendMessage(preview.slot, AbilityConfig.MessageTypes.Activate, {
		surfacePosition = preview.surfacePosition,
		surfaceNormal = preview.surfaceNormal,
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
		warn("[WallBuilder] Missing ReplicatedStorage.Assets.Abilities.WallBuilder.Wall")
		return true
	end

	return AbilityPlacementFlow.StartPreview({
		state = preview,
		abilityName = "WallBuilder",
		previewFolderName = PREVIEW_FOLDER_NAME,
		renderStepName = RENDER_STEP_NAME,
		commitActionName = COMMIT_ACTION_NAME,
		template = template,
		context = context,
		mode = "ForwardOffsetFloat",
		alwaysValid = true,
		requirePlacementClear = false,
		styleGhost = styleGhost,
		setGhostColor = setGhostColor,
	})
end

function WallBuilder.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if preview.active and preview.slot == context.slot and preview.abilityId == context.abilityId then
		cancelPreview()
		return true
	end

	return startPreview(context)
end

function WallBuilder.OnEffect(_context: ClientEffectContext)
end

return WallBuilder
