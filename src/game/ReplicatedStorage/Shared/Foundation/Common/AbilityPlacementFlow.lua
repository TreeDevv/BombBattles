local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local InstanceUtil = require(ReplicatedStorage.Shared.Common.InstanceUtil)
local PlacementSurfaceUtil = require(ReplicatedStorage.Shared.Common.PlacementSurfaceUtil)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

export type TargetRootResolver = () -> Instance?
export type GhostStyler = (Instance, any) -> ()
export type GhostColorer = (Instance, any, boolean) -> ()
type PreviewMode = "Surface" | "Floor" | "ForwardOffsetFloat" | "ForwardSolid"
export type PlacementState = {
	active: boolean,
	controller: any?,
	slot: string,
	abilityId: string,
	definition: any?,
	ghost: Instance?,
	inputConnection: RBXScriptConnection?,
	valid: boolean,
	surfacePosition: Vector3?,
	surfaceNormal: Vector3?,
	floorPosition: Vector3?,
	floatingPosition: Vector3?,
	facing: Vector3?,
}

export type PreviewOptions = {
	state: PlacementState,
	abilityName: string,
	previewFolderName: string,
	renderStepName: string,
	commitActionName: string,
	template: Instance,
	context: any,
	mode: PreviewMode,
	resolveTargetRoot: TargetRootResolver?,
	unsafeTags: { string }?,
	extraExcludeInstances: { Instance }?,
	alwaysValid: boolean?,
	requirePlacementClear: boolean?,
	placementDistance: number?,
	styleGhost: GhostStyler?,
	setGhostColor: GhostColorer?,
	validateGhostPlacement: ((Instance, any, PlacementSurfaceUtil.FloorPlacement, { Instance }) -> boolean)?,
}

local AbilityPlacementFlow = {}

local DEFAULT_RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3
local DEFAULT_COMMIT_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 50
local DEFAULT_UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local function getLocalPlayer(): Player
	return Players.LocalPlayer
end

local function defaultTargetRoot(): Instance?
	return PracticeRangeTargeting.GetClientTargetRoot(
		getLocalPlayer(),
		nil,
		nil,
		workspace:FindFirstChild(RoundConfig.ActiveMapName)
	)
end

function AbilityPlacementFlow.GetRootPart(): BasePart?
	local character = getLocalPlayer().Character
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

function AbilityPlacementFlow.GetPreviewFolder(name: string): Folder
	local existing = workspace:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = workspace
	return folder
end

function AbilityPlacementFlow.GetExcludes(previewFolderName: string, extra: { Instance }?): { Instance }
	local exclude = {}
	local character = getLocalPlayer().Character
	if character then
		table.insert(exclude, character)
	end
	local previewFolder = workspace:FindFirstChild(previewFolderName)
	if previewFolder then
		table.insert(exclude, previewFolder)
	end
	for _, instance in ipairs(extra or {}) do
		table.insert(exclude, instance)
	end
	return exclude
end

function AbilityPlacementFlow.DefaultStyleGhost(ghost: Instance, definition: any)
	local transparency = definition.previewTransparency or 0.5
	for _, part in ipairs(InstanceUtil.GetBaseParts(ghost)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = transparency
	end
end

function AbilityPlacementFlow.DefaultSetGhostColor(ghost: Instance, definition: any, valid: boolean)
	local color = if valid
		then definition.previewValidColor or Color3.fromRGB(76, 255, 97)
		else definition.previewInvalidColor or Color3.fromRGB(255, 68, 68)

	for _, part in ipairs(InstanceUtil.GetBaseParts(ghost)) do
		part.Color = color
	end
end

local function getTargetRoot(resolveTargetRoot: TargetRootResolver?): Instance?
	if resolveTargetRoot then
		return resolveTargetRoot()
	end
	return defaultTargetRoot()
end

function AbilityPlacementFlow.ResolveSurfacePlacement(options): PlacementSurfaceUtil.FloorPlacement?
	local rootPart = AbilityPlacementFlow.GetRootPart()
	local camera = workspace.CurrentCamera
	if not (rootPart and camera) then
		return nil
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	return PlacementSurfaceUtil.ResolveAimedSurfacePlacement({
		rootPart = rootPart,
		definition = options.definition,
		rayOrigin = ray.Origin,
		rayDirection = ray.Direction,
		targetRoot = getTargetRoot(options.resolveTargetRoot),
		unsafeTags = options.unsafeTags or DEFAULT_UNSAFE_TAGS,
		excludeInstances = AbilityPlacementFlow.GetExcludes(options.previewFolderName, options.extraExcludeInstances),
	})
end

function AbilityPlacementFlow.ResolveFloorPlacement(options): PlacementSurfaceUtil.FloorPlacement?
	local rootPart = AbilityPlacementFlow.GetRootPart()
	if not rootPart then
		return nil
	end

	return PlacementSurfaceUtil.ResolveFloorPlacement({
		rootPart = rootPart,
		definition = options.definition,
		payload = options.payload,
		targetRoot = getTargetRoot(options.resolveTargetRoot),
		unsafeTags = options.unsafeTags or DEFAULT_UNSAFE_TAGS,
		excludeInstances = AbilityPlacementFlow.GetExcludes(options.previewFolderName or "", options.extraExcludeInstances),
		useRootPosition = options.useRootPosition,
	})
end

function AbilityPlacementFlow.ResolveForwardOffsetPlacement(options): PlacementSurfaceUtil.FloorPlacement?
	local rootPart = AbilityPlacementFlow.GetRootPart()
	if not rootPart then
		return nil
	end

	return PlacementSurfaceUtil.ResolveForwardOffsetPlacement({
		rootPart = rootPart,
		definition = options.definition,
		payload = options.payload,
		distance = options.placementDistance,
	})
end

function AbilityPlacementFlow.ResolveForwardSolidPlacement(options): PlacementSurfaceUtil.FloorPlacement?
	local rootPart = AbilityPlacementFlow.GetRootPart()
	if not rootPart then
		return nil
	end

	return PlacementSurfaceUtil.ResolveForwardSolidPlacement({
		rootPart = rootPart,
		definition = options.definition,
		distance = options.placementDistance,
		excludeInstances = AbilityPlacementFlow.GetExcludes(options.previewFolderName or "", options.extraExcludeInstances),
	})
end

function AbilityPlacementFlow.Cancel(state: PlacementState, renderStepName: string, commitActionName: string)
	RunService:UnbindFromRenderStep(renderStepName)
	ContextActionService:UnbindAction(commitActionName)
	if state.inputConnection then
		state.inputConnection:Disconnect()
		state.inputConnection = nil
	end
	if state.ghost and state.ghost.Parent then
		state.ghost:Destroy()
	end

	state.active = false
	state.controller = nil
	state.slot = ""
	state.abilityId = ""
	state.definition = nil
	state.ghost = nil
	state.valid = false
	state.surfacePosition = nil
	state.surfaceNormal = nil
	state.floorPosition = nil
	state.floatingPosition = nil
	state.facing = nil
end

local function isCancelInput(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton2
		or input.KeyCode == Enum.KeyCode.Escape
end

local function setStatePlacement(
	state: PlacementState,
	placement: PlacementSurfaceUtil.FloorPlacement,
	mode: PreviewMode
)
	state.facing = placement.facing
	if mode == "Surface" then
		state.surfacePosition = placement.position
		state.surfaceNormal = placement.normal
		state.floorPosition = nil
		state.floatingPosition = nil
	elseif mode == "ForwardOffsetFloat" or mode == "ForwardSolid" then
		state.surfacePosition = nil
		state.surfaceNormal = nil
		state.floorPosition = nil
		state.floatingPosition = placement.position
	else
		state.floorPosition = placement.position
		state.surfacePosition = nil
		state.surfaceNormal = nil
		state.floatingPosition = nil
	end
end

function AbilityPlacementFlow.Commit(
	state: PlacementState,
	renderStepName: string,
	commitActionName: string,
	mode: PreviewMode
)
	if not state.active or not state.valid or not state.controller then
		return
	end

	local payload
	if mode == "Surface" then
		payload = {
			surfacePosition = state.surfacePosition,
			surfaceNormal = state.surfaceNormal,
			facing = state.facing,
		}
	elseif mode == "ForwardOffsetFloat" then
		payload = {
			facing = state.facing,
		}
	elseif mode == "ForwardSolid" then
		payload = nil
	else
		payload = {
			floorPosition = state.floorPosition,
			facing = state.facing,
		}
	end

	state.controller:SendMessage(state.slot, AbilityConfig.MessageTypes.Activate, payload)
	AbilityPlacementFlow.Cancel(state, renderStepName, commitActionName)
end

function AbilityPlacementFlow.StartPreview(options: PreviewOptions): boolean
	local context = options.context
	local state = options.state
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	AbilityPlacementFlow.Cancel(state, options.renderStepName, options.commitActionName)

	local ghost = options.template:Clone()
	ghost.Name = options.abilityName .. "Preview"
	local styleGhost = options.styleGhost or AbilityPlacementFlow.DefaultStyleGhost
	local setGhostColor = options.setGhostColor or AbilityPlacementFlow.DefaultSetGhostColor
	styleGhost(ghost, context.definition)
	setGhostColor(ghost, context.definition, false)
	ghost.Parent = AbilityPlacementFlow.GetPreviewFolder(options.previewFolderName)

	state.active = true
	state.controller = context.controller
	state.slot = context.slot
	state.abilityId = context.abilityId
	state.definition = context.definition
	state.ghost = ghost
	state.valid = false

	local function updatePreview()
		if not state.active then
			return
		end
		local controller = state.controller
		if not controller or controller:GetEquippedAbilityId(state.slot) ~= state.abilityId then
			AbilityPlacementFlow.Cancel(state, options.renderStepName, options.commitActionName)
			return
		end
		local definition = state.definition
		local currentGhost = state.ghost
		if not (definition and currentGhost) then
			state.valid = false
			return
		end

		local placement
		if options.mode == "Surface" then
			placement = AbilityPlacementFlow.ResolveSurfacePlacement({
				definition = definition,
				previewFolderName = options.previewFolderName,
				resolveTargetRoot = options.resolveTargetRoot,
				unsafeTags = options.unsafeTags,
				extraExcludeInstances = options.extraExcludeInstances,
			})
		elseif options.mode == "ForwardOffsetFloat" then
			placement = AbilityPlacementFlow.ResolveForwardOffsetPlacement({
				definition = definition,
				placementDistance = options.placementDistance,
			})
		elseif options.mode == "ForwardSolid" then
			placement = AbilityPlacementFlow.ResolveForwardSolidPlacement({
				definition = definition,
				previewFolderName = options.previewFolderName,
				extraExcludeInstances = options.extraExcludeInstances,
				placementDistance = options.placementDistance,
			})
		else
			placement = AbilityPlacementFlow.ResolveFloorPlacement({
				definition = definition,
				previewFolderName = options.previewFolderName,
				resolveTargetRoot = options.resolveTargetRoot,
				unsafeTags = options.unsafeTags,
				extraExcludeInstances = options.extraExcludeInstances,
			})
		end
		if not placement then
			state.valid = false
			setGhostColor(currentGhost, definition, false)
			return
		end

		local boundsCFrame, boundsSize
		if options.mode == "ForwardOffsetFloat" then
			PlacementSurfaceUtil.PivotTo(
				currentGhost,
				PlacementSurfaceUtil.GetFloorPivot(placement.position, placement.facing, placement.normal)
			)
			boundsCFrame, boundsSize = PlacementSurfaceUtil.GetBounds(currentGhost)
		else
			boundsCFrame, boundsSize = PlacementSurfaceUtil.AlignToFloor(currentGhost, placement)
		end
		local valid
		if options.validateGhostPlacement then
			valid = options.validateGhostPlacement(
				currentGhost,
				definition,
				placement,
				AbilityPlacementFlow.GetExcludes(options.previewFolderName)
			)
		elseif options.alwaysValid == true or options.requirePlacementClear == false then
			valid = true
		else
			valid = PlacementSurfaceUtil.IsPlacementClear({
				boundsCFrame = boundsCFrame,
				boundsSize = boundsSize,
				support = placement.floor,
				unsafeTags = options.unsafeTags or DEFAULT_UNSAFE_TAGS,
				excludeInstances = AbilityPlacementFlow.GetExcludes(options.previewFolderName),
			})
		end
		state.valid = valid
		setStatePlacement(state, placement, options.mode)
		setGhostColor(currentGhost, definition, valid)
	end

	RunService:UnbindFromRenderStep(options.renderStepName)
	RunService:BindToRenderStep(options.renderStepName, DEFAULT_RENDER_PRIORITY, updatePreview)
	updatePreview()

	ContextActionService:UnbindAction(options.commitActionName)
	ContextActionService:BindActionAtPriority(
		options.commitActionName,
		function(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject)
			if inputState == Enum.UserInputState.Begin then
				AbilityPlacementFlow.Commit(state, options.renderStepName, options.commitActionName, options.mode)
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		DEFAULT_COMMIT_ACTION_PRIORITY,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.Touch,
		Enum.KeyCode.ButtonR2
	)

	state.inputConnection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if isCancelInput(input) then
			AbilityPlacementFlow.Cancel(state, options.renderStepName, options.commitActionName)
		end
	end)

	return true
end

function AbilityPlacementFlow.SendInstant(context: any): boolean
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, nil)
	return true
end

function AbilityPlacementFlow.SendInstantFloor(context: any): boolean
	return AbilityPlacementFlow.SendInstant(context)
end

return table.freeze(AbilityPlacementFlow)
