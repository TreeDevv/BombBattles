local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local ScreenEffects = require(ReplicatedStorage.Shared.UI.ScreenEffects)
local CameraController = require(script.Parent.Parent:WaitForChild("CameraController"))

type AbilityControllerLike = AbilityTypes.AbilityControllerLike
type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext
type Controls = {
	Disable: ((any) -> ())?,
	Enable: ((any) -> ())?,
}

type SavedCameraState = {
	cameraType: Enum.CameraType,
	cameraSubject: Instance?,
	cframe: CFrame,
	fieldOfView: number,
	mouseBehavior: Enum.MouseBehavior,
	mouseIconEnabled: boolean,
}

type TargetingState = {
	active: boolean,
	sessionId: number,
	controller: AbilityControllerLike?,
	slot: string,
	abilityId: string,
	definition: AbilityDefinition?,
	savedCamera: SavedCameraState?,
	markerFolder: Folder?,
	radiusPart: BasePart?,
	centerPart: BasePart?,
	ui: ScreenGui?,
	tweenValue: NumberValue?,
	tween: Tween?,
	restoreTweening: boolean,
	currentFocus: Vector3?,
	placementCenter: Vector3?,
	placementOffset: Vector3,
	placementForward: Vector3,
	keyboardInput: Vector2,
	gamepadInput: Vector2,
	touchInput: Vector2,
	touchPad: Frame?,
	touchKnob: Frame?,
	touchInputObject: InputObject?,
	controls: Controls?,
	controlsDisabled: boolean,
	targetPosition: Vector3?,
	valid: boolean,
	connections: { RBXScriptConnection },
}

local OrbitalStrike = {} :: AbilityTypes.ClientBehavior

local LocalPlayer = Players.LocalPlayer
local RENDER_STEP_NAME = "BombBattlesOrbitalStrikeTargeting"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 6
local ACTION_NAME = "BombBattlesOrbitalStrikeTargetingInput"
local ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 80
local PREVIEW_FOLDER_NAME = "OrbitalStrikePreview"
local VFX_FOLDER_NAME = "OrbitalStrikeVFX"
local CAMERA_TWEEN_SECONDS = 0.4
local FOCUS_RESPONSIVENESS = 14

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
	"NoStrikeZone",
	"ProtectedZone",
}

local KEY_DIRECTIONS = {
	[Enum.KeyCode.W] = Vector2.new(0, 1),
	[Enum.KeyCode.Up] = Vector2.new(0, 1),
	[Enum.KeyCode.DPadUp] = Vector2.new(0, 1),
	[Enum.KeyCode.S] = Vector2.new(0, -1),
	[Enum.KeyCode.Down] = Vector2.new(0, -1),
	[Enum.KeyCode.DPadDown] = Vector2.new(0, -1),
	[Enum.KeyCode.A] = Vector2.new(-1, 0),
	[Enum.KeyCode.Left] = Vector2.new(-1, 0),
	[Enum.KeyCode.DPadLeft] = Vector2.new(-1, 0),
	[Enum.KeyCode.D] = Vector2.new(1, 0),
	[Enum.KeyCode.Right] = Vector2.new(1, 0),
	[Enum.KeyCode.DPadRight] = Vector2.new(1, 0),
}

local heldMoveKeys: { [Enum.KeyCode]: boolean } = {}
local emitModule = nil
local emitModuleInitialized = false
local warnedMissingTemplate = false
local warnedMissingEmitModule = false

local state: TargetingState = {
	active = false,
	sessionId = 0,
	controller = nil,
	slot = "",
	abilityId = "",
	definition = nil,
	savedCamera = nil,
	markerFolder = nil,
	radiusPart = nil,
	centerPart = nil,
	ui = nil,
	tweenValue = nil,
	tween = nil,
	restoreTweening = false,
	currentFocus = nil,
	placementCenter = nil,
	placementOffset = Vector3.zero,
	placementForward = Vector3.zAxis,
	keyboardInput = Vector2.zero,
	gamepadInput = Vector2.zero,
	touchInput = Vector2.zero,
	touchPad = nil,
	touchKnob = nil,
	touchInputObject = nil,
	controls = nil,
	controlsDisabled = false,
	targetPosition = nil,
	valid = false,
	connections = {},
}

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

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

local function getStrikeTemplate(definition: AbilityDefinition?): Instance?
	local path = definition and definition.assetPath
	if typeof(path) ~= "table" then
		return nil
	end

	local template = getByPath(ReplicatedStorage, path)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	if not warnedMissingTemplate then
		warn("[OrbitalStrike] Missing ReplicatedStorage.Assets.Abilities.OrbitalStrike.Orbital Strike")
		warnedMissingTemplate = true
	end
	return nil
end

local function getEmitModule()
	if emitModule then
		return emitModule
	end

	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local moduleScript = packages and packages:FindFirstChild("EmitModule")
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		if not warnedMissingEmitModule then
			warn("[OrbitalStrike] Missing ReplicatedStorage.Packages.EmitModule")
			warnedMissingEmitModule = true
		end
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	if not ok then
		if not warnedMissingEmitModule then
			warn("[OrbitalStrike] Failed to require EmitModule: " .. tostring(result))
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
			warn("[OrbitalStrike] Failed to initialize EmitModule: " .. tostring(err))
			return false
		end
	end

	emitModuleInitialized = true
	return true
end

local function getVfxFolder(): Folder
	local existing = workspace:FindFirstChild(VFX_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = VFX_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function prepareVisualInstance(instance: Instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = false
		instance.AssemblyLinearVelocity = Vector3.zero
		instance.AssemblyAngularVelocity = Vector3.zero
	end
end

local function pivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function cleanupVisualAfterDelay(clone: Instance, cleanupSeconds: number)
	task.delay(math.max(cleanupSeconds, 0), function()
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

local function getPayloadNumber(payload: any, key: string, fallback: number): number
	local value = if typeof(payload) == "table" then payload[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function playStrikeVfx(payload: any)
	local position = if typeof(payload) == "table" then payload.position else nil
	if typeof(position) ~= "Vector3" then
		return
	end

	local definition = AbilityConfig.GetDefinition("OrbitalStrike")
	local template = getStrikeTemplate(definition)
	if not template then
		return
	end

	local clone = template:Clone()
	clone.Name = "OrbitalStrikeVFX"
	prepareVisualInstance(clone)
	pivotTo(clone, CFrame.new(position))
	clone.Parent = getVfxFolder()

	local cleanupSeconds = math.max(getDefinitionNumber(definition, "strikeVisualCleanupSeconds", 5), 0.25)
	local module = getEmitModule()
	if module and ensureEmitModuleInitialized(module) and type(module.emit) == "function" then
		local columnTopY = getPayloadNumber(payload, "columnTopY", position.Y)
		local columnBottomY = getPayloadNumber(payload, "columnBottomY", position.Y)
		local depth = math.max(columnTopY - columnBottomY, 0)
		local step = math.max(getPayloadNumber(payload, "terrainStep", math.max(getPayloadNumber(payload, "terrainExplosionRadius", 22), 1)), 1)
		local stepCount = math.max(math.floor(depth / step) + 1, 1)
		if (stepCount - 1) * step < depth then
			stepCount += 1
		end
		local interval = math.max(getPayloadNumber(payload, "terrainStepInterval", 0), 0)

		task.spawn(function()
			for index = 0, stepCount - 1 do
				local offset = math.min(index * step, depth)
				local stepPosition = Vector3.new(position.X, columnTopY - offset, position.Z)
				pivotTo(clone, CFrame.new(stepPosition))
				local ok, err = pcall(function()
					return module.emit(clone)
				end)
				if not ok then
					warn("[OrbitalStrike] Failed to emit strike VFX: " .. tostring(err))
					break
				end
				if index < stepCount - 1 and interval > 0 then
					task.wait(interval)
				end
			end
			cleanupVisualAfterDelay(clone, cleanupSeconds)
		end)
		return
	end

	cleanupVisualAfterDelay(clone, cleanupSeconds)
end

local function getControls(): Controls?
	local playerScripts = LocalPlayer:FindFirstChild("PlayerScripts")
	if not playerScripts then
		return nil
	end

	local playerModule = playerScripts:FindFirstChild("PlayerModule")
	if not (playerModule and playerModule:IsA("ModuleScript")) then
		return nil
	end

	local ok, module = pcall(require, playerModule)
	if not ok or typeof(module) ~= "table" or type(module.GetControls) ~= "function" then
		return nil
	end

	return module:GetControls()
end

local function disableMovementControls()
	if state.controlsDisabled then
		return
	end

	local controls = state.controls or getControls()
	state.controls = controls
	if controls and type(controls.Disable) == "function" then
		local ok = pcall(function()
			controls:Disable()
		end)
		state.controlsDisabled = ok
	end
end

local function restoreMovementControls()
	local controls = state.controls
	if state.controlsDisabled and controls and type(controls.Enable) == "function" then
		pcall(function()
			controls:Enable()
		end)
	end
	state.controls = nil
	state.controlsDisabled = false
end

local function flattenDirection(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	return if flat.Magnitude > 0.05 then flat.Unit else Vector3.zero
end

local function axisAlignedDirection(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude <= 0.05 then
		return Vector3.zero
	end

	if math.abs(flat.X) >= math.abs(flat.Z) then
		return Vector3.new(if flat.X >= 0 then 1 else -1, 0, 0)
	end
	return Vector3.new(0, 0, if flat.Z >= 0 then 1 else -1)
end

local function disconnectAll()
	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end
	table.clear(state.connections)
end

local function updateKeyboardInput()
	local input = Vector2.zero
	for keyCode, held in pairs(heldMoveKeys) do
		if held then
			input += KEY_DIRECTIONS[keyCode] or Vector2.zero
		end
	end

	state.keyboardInput = if input.Magnitude > 1 then input.Unit else input
end

local function clearMoveInput()
	table.clear(heldMoveKeys)
	state.keyboardInput = Vector2.zero
	state.gamepadInput = Vector2.zero
	state.touchInput = Vector2.zero
	state.touchInputObject = nil
end

local function cancelTween()
	if state.tween then
		state.tween:Cancel()
		state.tween = nil
	end
	if state.tweenValue then
		state.tweenValue:Destroy()
		state.tweenValue = nil
	end
end

local function destroyPreview()
	if state.markerFolder and state.markerFolder.Parent then
		state.markerFolder:Destroy()
	end
	if state.ui and state.ui.Parent then
		state.ui:Destroy()
	end
	state.markerFolder = nil
	state.radiusPart = nil
	state.centerPart = nil
	state.ui = nil
	state.touchPad = nil
	state.touchKnob = nil
end

local function getRootPart(): BasePart?
	local character = LocalPlayer.Character
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

local function smoothstep(value: number): number
	local x = math.clamp(value, 0, 1)
	return x * x * (3 - 2 * x)
end

local function playProximityBlackFlash(payload: any, definition: AbilityDefinition?)
	local position = if typeof(payload) == "table" then payload.position else nil
	if typeof(position) ~= "Vector3" then
		return
	end

	local rootPart = getRootPart()
	if not rootPart then
		return
	end

	local radius = math.max(getPayloadNumber(payload, "blackFlashRadius", getDefinitionNumber(definition, "blackFlashRadius", 260)), 0)
	if radius <= 0 then
		return
	end

	local rootPosition = rootPart.Position
	local distance = Vector3.new(rootPosition.X - position.X, 0, rootPosition.Z - position.Z).Magnitude
	if distance > radius then
		return
	end

	local strength = smoothstep(1 - distance / radius)
	if strength <= 0 then
		return
	end

	local closestTransparency =
		math.clamp(getPayloadNumber(payload, "blackFlashClosestTransparency", getDefinitionNumber(definition, "blackFlashClosestTransparency", 0.3)), 0, 1)
	local initialTransparency = 1 - ((1 - closestTransparency) * strength)
	if initialTransparency >= 1 then
		return
	end

	ScreenEffects.FlashBlack(getPayloadNumber(payload, "blackFlashDuration", getDefinitionNumber(definition, "blackFlashDuration", 3)), initialTransparency)
end

local function playHitBlackFlash(payload: any)
	if typeof(payload) ~= "table" or payload.abilityId ~= "OrbitalStrike" then
		return
	end

	local definition = AbilityConfig.GetDefinition("OrbitalStrike")
	local duration = if typeof(payload.durationSeconds) == "number"
		then payload.durationSeconds
		else getDefinitionNumber(definition, "blackFlashHitDuration", 3)
	local initialTransparency = if typeof(payload.initialTransparency) == "number"
		then payload.initialTransparency
		else getDefinitionNumber(definition, "blackFlashClosestTransparency", 0.3)
	ScreenEffects.FlashBlack(duration, initialTransparency)
end

local function getActiveMap(): Model?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getInstancePosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end

	local ok, pivot = pcall(function()
		return (instance :: any):GetPivot()
	end)
	if ok and typeof(pivot) == "CFrame" then
		return pivot.Position
	end
	return nil
end

local function getEnemyTeamName(): string?
	local localTeam = LocalPlayer.Team
	local localTeamName = localTeam and localTeam.Name or nil
	if not localTeamName then
		return nil
	end

	for _, teamConfig in pairs(RoundConfig.Teams) do
		if typeof(teamConfig) == "table" and typeof(teamConfig.name) == "string" and teamConfig.name ~= localTeamName then
			return teamConfig.name
		end
	end
	return nil
end

local function getClosestTaggedTeamPosition(tagName: string, teamName: string, map: Model, origin: Vector3): Vector3?
	local closestPosition: Vector3? = nil
	local closestDistance = math.huge
	for _, instance in ipairs(CollectionService:GetTagged(tagName)) do
		if not instance:IsDescendantOf(map) or instance:GetAttribute("Team") ~= teamName then
			continue
		end

		local position = getInstancePosition(instance)
		if not position then
			continue
		end

		local distance = (Vector3.new(position.X, origin.Y, position.Z) - origin).Magnitude
		if distance < closestDistance then
			closestDistance = distance
			closestPosition = position
		end
	end
	return closestPosition
end

local function resolvePlacementForward(rootPart: BasePart): Vector3
	local map = getActiveMap()
	local enemyTeamName = getEnemyTeamName()
	local origin = rootPart.Position
	local targetPosition: Vector3? = nil
	if map and enemyTeamName then
		targetPosition = getClosestTaggedTeamPosition(RoundConfig.Tags.TeamCore, enemyTeamName, map, origin)
			or getClosestTaggedTeamPosition(RoundConfig.Tags.TeamSpawn, enemyTeamName, map, origin)
	end

	local forward = if targetPosition then axisAlignedDirection(targetPosition - origin) else Vector3.zero
	if forward.Magnitude > 0.05 then
		return forward
	end

	forward = axisAlignedDirection(rootPart.CFrame.LookVector)
	if forward.Magnitude > 0.05 then
		return forward
	end

	return Vector3.zAxis
end

local function hasTaggedAncestor(instance: Instance, tags: { string }): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		for _, tagName in ipairs(tags) do
			if CollectionService:HasTag(current, tagName) then
				return true
			end
		end
		current = current.Parent
	end
	return false
end

local function isInsideMapBounds(position: Vector3, map: Model?): boolean
	if not map then
		return false
	end

	local boundsCFrame, boundsSize = map:GetBoundingBox()
	local localPosition = boundsCFrame:PointToObjectSpace(position)
	local halfSize = boundsSize * 0.5 + Vector3.new(3, 12, 3)
	return math.abs(localPosition.X) <= halfSize.X
		and math.abs(localPosition.Y) <= halfSize.Y
		and math.abs(localPosition.Z) <= halfSize.Z
end

local function clampToMapFootprint(position: Vector3, map: Model?): Vector3
	if not map then
		return position
	end

	local boundsCFrame, boundsSize = map:GetBoundingBox()
	local localPosition = boundsCFrame:PointToObjectSpace(position)
	local halfSize = boundsSize * 0.5
	localPosition = Vector3.new(
		math.clamp(localPosition.X, -halfSize.X, halfSize.X),
		localPosition.Y,
		math.clamp(localPosition.Z, -halfSize.Z, halfSize.Z)
	)
	return boundsCFrame:PointToWorldSpace(localPosition)
end

local function makeRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true

	local excluded = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(excluded, player.Character)
		end
	end
	if state.markerFolder then
		table.insert(excluded, state.markerFolder)
	end
	local map = getActiveMap()
	local strikeObjects = map and map:FindFirstChild("OrbitalStrikeObjects")
	if strikeObjects then
		table.insert(excluded, strikeObjects)
	end
	local projectileFolder = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	if projectileFolder then
		table.insert(excluded, projectileFolder)
	end
	local fireFolder = workspace:FindFirstChild("FireBombZones")
	if fireFolder then
		table.insert(excluded, fireFolder)
	end

	params.FilterDescendantsInstances = excluded
	return params
end

local function getMarkerFolder(): Folder
	if state.markerFolder and state.markerFolder.Parent then
		return state.markerFolder
	end

	local folder = Instance.new("Folder")
	folder.Name = PREVIEW_FOLDER_NAME
	folder.Parent = workspace
	state.markerFolder = folder
	return folder
end

local function createMarkerPart(name: string, size: Vector3, transparency: number): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Transparency = transparency
	part.Shape = Enum.PartType.Cylinder
	part.Size = size
	part.Parent = getMarkerFolder()
	return part
end

local function ensureMarker(definition: AbilityDefinition)
	local radius = getDefinitionNumber(definition, "strikeRadius", 22)
	if not state.radiusPart then
		state.radiusPart = createMarkerPart("OrbitalStrikeRadius", Vector3.new(0.08, radius * 2, radius * 2), 0.7)
	end
	if not state.centerPart then
		state.centerPart = createMarkerPart("OrbitalStrikeCenter", Vector3.new(0.16, 2.5, 2.5), 0.25)
	end
end

local function setMarker(position: Vector3?, valid: boolean)
	if not (state.radiusPart and state.centerPart and position) then
		return
	end

	local color = if valid then Color3.fromRGB(80, 255, 140) else Color3.fromRGB(255, 70, 70)
	local cframe = CFrame.new(position + Vector3.yAxis * 0.08) * CFrame.Angles(0, 0, math.rad(90))
	state.radiusPart.CFrame = cframe
	state.centerPart.CFrame = cframe
	state.radiusPart.Color = color
	state.centerPart.Color = color
end

local function getMoveInput(): Vector2
	local input = state.keyboardInput + state.gamepadInput + state.touchInput
	if input.Magnitude > 1 then
		return input.Unit
	end
	return input
end

local function getPanDirection(input: Vector2): Vector3
	if input.Magnitude <= 0.05 then
		return Vector3.zero
	end

	local forward = flattenDirection(state.placementForward)
	if forward.Magnitude <= 0.05 then
		forward = Vector3.zAxis
	end

	local right = forward:Cross(Vector3.yAxis)
	if right.Magnitude <= 0.05 then
		right = Vector3.xAxis
	else
		right = right.Unit
	end

	local direction = right * input.X + forward * input.Y
	return if direction.Magnitude > 0.05 then direction.Unit * math.min(input.Magnitude, 1) else Vector3.zero
end

local function raycastPlacement(desiredPosition: Vector3, definition: AbilityDefinition): (Vector3?, Instance?, Vector3?)
	local rayUp = math.max(getDefinitionNumber(definition, "floorRaycastUp", 80), 1)
	local rayDown = math.max(getDefinitionNumber(definition, "floorRaycastDown", 180), 1)
	local hit = workspace:Raycast(
		desiredPosition + Vector3.yAxis * rayUp,
		Vector3.yAxis * -(rayUp + rayDown),
		makeRaycastParams()
	)
	if not hit then
		return nil, nil, nil
	end

	return hit.Position, hit.Instance, hit.Normal
end

local function updatePlacementFromMove(definition: AbilityDefinition, dt: number): (Vector3?, boolean)
	local rootPart = getRootPart()
	if not rootPart then
		return nil, false
	end

	local center = state.placementCenter or rootPart.Position
	state.placementCenter = center
	local panDirection = getPanDirection(getMoveInput())
	if panDirection.Magnitude > 0.05 then
		local speed = math.max(getDefinitionNumber(definition, "placementPanSpeed", 180), 1)
		state.placementOffset += panDirection * speed * dt
	end

	local activeMap = getActiveMap()
	local desiredPosition = clampToMapFootprint(center + state.placementOffset, activeMap)
	state.placementOffset = desiredPosition - center
	local targetPosition, hitInstance, normal = raycastPlacement(desiredPosition, definition)
	if not targetPosition then
		return desiredPosition, false
	end

	local valid = true
	if activeMap and hitInstance and not hitInstance:IsDescendantOf(activeMap) then
		valid = false
	end
	if not isInsideMapBounds(targetPosition, activeMap) then
		valid = false
	end
	if normal and normal.Y < getDefinitionNumber(definition, "minFloorNormalY", 0.45) then
		valid = false
	end
	if hitInstance and hasTaggedAncestor(hitInstance, UNSAFE_TAGS) then
		valid = false
	end

	return targetPosition, valid
end

local function getCameraGoal(definition: AbilityDefinition, focus: Vector3): (CFrame, number)
	local height = getDefinitionNumber(definition, "cameraHeight", 110)
	local fov = getDefinitionNumber(definition, "targetFOV", 40)
	local position = focus + Vector3.yAxis * height
	local forward = flattenDirection(state.placementForward)
	local cameraUp = if forward.Magnitude > 0.05 then forward else Vector3.zAxis
	return CFrame.lookAt(position, focus, cameraUp), fov
end

local function getBlendAlpha(): number
	return if state.tweenValue then math.clamp(state.tweenValue.Value, 0, 1) else 1
end

local function restoreCamera()
	local camera = workspace.CurrentCamera
	local saved = state.savedCamera
	if not (camera and saved) then
		return
	end

	local subject = saved.cameraSubject
	if not (subject and subject.Parent) then
		local character = LocalPlayer.Character
		subject = character and character:FindFirstChildOfClass("Humanoid") or nil
	end
	if subject then
		camera.CameraSubject = subject
	end
	camera.CameraType = saved.cameraType
	camera.FieldOfView = saved.fieldOfView
	UserInputService.MouseBehavior = saved.mouseBehavior
	UserInputService.MouseIconEnabled = saved.mouseIconEnabled
end

local function finishCleanup()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	ContextActionService:UnbindAction(ACTION_NAME)
	disconnectAll()
	cancelTween()
	destroyPreview()
	restoreCamera()
	restoreMovementControls()
	clearMoveInput()

	state.active = false
	state.sessionId = 0
	state.controller = nil
	state.slot = ""
	state.abilityId = ""
	state.definition = nil
	state.savedCamera = nil
	state.restoreTweening = false
	state.currentFocus = nil
	state.placementCenter = nil
	state.placementOffset = Vector3.zero
	state.placementForward = Vector3.zAxis
	state.targetPosition = nil
	state.valid = false
end

local function endTargeting(snap: boolean)
	if not state.active then
		return
	end

	local camera = workspace.CurrentCamera
	local saved = state.savedCamera
	if snap or not (camera and saved and state.definition) then
		finishCleanup()
		return
	end

	local sessionId = state.sessionId
	local restoreAlpha = getBlendAlpha()
	state.restoreTweening = true
	ContextActionService:UnbindAction(ACTION_NAME)
	disconnectAll()
	destroyPreview()
	cancelTween()

	local value = Instance.new("NumberValue")
	value.Value = restoreAlpha
	state.tweenValue = value
	state.tween = TweenService:Create(value, TweenInfo.new(CAMERA_TWEEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Value = 0,
	})
	state.tween.Completed:Once(function()
		if state.sessionId == sessionId and state.restoreTweening then
			finishCleanup()
		end
	end)
	state.tween:Play()
end

local function startTweenIn()
	cancelTween()
	local value = Instance.new("NumberValue")
	value.Value = 0
	state.tweenValue = value
	state.tween = TweenService:Create(value, TweenInfo.new(CAMERA_TWEEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Value = 1,
	})
	state.tween.Completed:Once(function()
		if state.tweenValue == value then
			state.tween = nil
		end
	end)
	state.tween:Play()
end

local function stepTargeting(dt: number)
	local camera = workspace.CurrentCamera
	local definition = state.definition
	local saved = state.savedCamera
	if not (camera and definition and saved) then
		endTargeting(true)
		return
	end

	if not state.restoreTweening then
		if not getRootPart() then
			endTargeting(true)
			return
		end
		if state.controller and state.controller:GetEquippedAbilityId(state.slot) ~= state.abilityId then
			endTargeting(false)
			return
		end

		disableMovementControls()

		local targetPosition, valid = updatePlacementFromMove(definition, dt)
		state.targetPosition = targetPosition
		state.valid = valid
		setMarker(targetPosition, valid)

		local rootPart = getRootPart()
		local desiredFocus = targetPosition or (rootPart and rootPart.Position) or saved.cframe.Position
		state.currentFocus = if state.currentFocus
			then state.currentFocus:Lerp(desiredFocus, 1 - math.exp(-FOCUS_RESPONSIVENESS * dt))
			else desiredFocus
	end

	local focus = state.currentFocus or saved.cframe.Position
	local overheadCFrame, overheadFOV = getCameraGoal(definition, focus)
	local alpha = getBlendAlpha()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = saved.cframe:Lerp(overheadCFrame, alpha)
	camera.FieldOfView = saved.fieldOfView + (overheadFOV - saved.fieldOfView) * alpha
end

local function confirmTarget()
	if not (state.active and state.controller and state.valid and state.targetPosition) then
		return
	end

	state.controller:SendMessage(state.slot, AbilityConfig.MessageTypes.Intent, {
		action = "ConfirmTarget",
		sessionId = state.sessionId,
		position = state.targetPosition,
	})
	endTargeting(false)
end

local function cancelTarget()
	if not state.active then
		return
	end

	if state.controller then
		state.controller:SendMessage(state.slot, AbilityConfig.MessageTypes.Cancel, {
			action = "CancelTargeting",
			sessionId = state.sessionId,
		})
	end
	endTargeting(false)
end

local function handleTargetingAction(_actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	local keyDirection = KEY_DIRECTIONS[inputObject.KeyCode]
	if keyDirection then
		if inputState == Enum.UserInputState.Begin then
			heldMoveKeys[inputObject.KeyCode] = true
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			heldMoveKeys[inputObject.KeyCode] = nil
		end
		updateKeyboardInput()
		return Enum.ContextActionResult.Sink
	end

	if inputObject.KeyCode == Enum.KeyCode.Space or inputObject.KeyCode == Enum.KeyCode.ButtonL3 then
		return Enum.ContextActionResult.Sink
	end

	if inputObject.KeyCode == Enum.KeyCode.Thumbstick1 then
		if inputState == Enum.UserInputState.Change then
			local position = inputObject.Position
			local input = Vector2.new(position.X, position.Y)
			state.gamepadInput = if input.Magnitude >= 0.18 then input else Vector2.zero
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			state.gamepadInput = Vector2.zero
		end
		return Enum.ContextActionResult.Sink
	end

	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end

	if
		inputObject.UserInputType == Enum.UserInputType.MouseButton1
		or inputObject.KeyCode == Enum.KeyCode.ButtonA
		or inputObject.KeyCode == Enum.KeyCode.ButtonR2
	then
		confirmTarget()
	elseif
		inputObject.UserInputType == Enum.UserInputType.MouseButton2
		or inputObject.KeyCode == Enum.KeyCode.Q
		or inputObject.KeyCode == Enum.KeyCode.Escape
		or inputObject.KeyCode == Enum.KeyCode.ButtonB
	then
		cancelTarget()
	end

	return Enum.ContextActionResult.Sink
end

local function createButton(parent: Instance, text: string, position: UDim2, color: Color3): TextButton
	local button = Instance.new("TextButton")
	button.Name = text .. "Button"
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = position
	button.Size = UDim2.fromOffset(112, 44)
	button.BackgroundColor3 = color
	button.BackgroundTransparency = 0.12
	button.BorderSizePixel = 0
	button.Text = text
	button.TextColor3 = Color3.new(1, 1, 1)
	button.TextSize = 16
	button.Font = Enum.Font.GothamMedium
	button.AutoButtonColor = true
	button.Visible = UserInputService.TouchEnabled
	button.Parent = parent
	return button
end

local function updateTouchPadVisual()
	local knob = state.touchKnob
	if not knob then
		return
	end

	knob.Position = UDim2.fromScale(0.5, 0.5)
		+ UDim2.fromOffset(state.touchInput.X * 42, -state.touchInput.Y * 42)
end

local function setTouchInputFromPosition(screenPosition: Vector3)
	local pad = state.touchPad
	if not pad then
		return
	end

	local absolutePosition = pad.AbsolutePosition
	local absoluteSize = pad.AbsoluteSize
	if absoluteSize.X <= 0 or absoluteSize.Y <= 0 then
		state.touchInput = Vector2.zero
		updateTouchPadVisual()
		return
	end

	local center = absolutePosition + absoluteSize * 0.5
	local offset = Vector2.new(screenPosition.X - center.X, screenPosition.Y - center.Y)
	local radius = math.max(math.min(absoluteSize.X, absoluteSize.Y) * 0.5 - 18, 1)
	local input = Vector2.new(offset.X / radius, -offset.Y / radius)
	state.touchInput = if input.Magnitude > 1 then input.Unit else input
	updateTouchPadVisual()
end

local function clearTouchInput(inputObject: InputObject?)
	if inputObject and state.touchInputObject and inputObject ~= state.touchInputObject then
		return
	end

	state.touchInputObject = nil
	state.touchInput = Vector2.zero
	updateTouchPadVisual()
end

local function createTouchMovePad(parent: Instance)
	if not UserInputService.TouchEnabled then
		return
	end

	local pad = Instance.new("Frame")
	pad.Name = "MovePad"
	pad.AnchorPoint = Vector2.new(0, 1)
	pad.Position = UDim2.new(0, 28, 1, -42)
	pad.Size = UDim2.fromOffset(132, 132)
	pad.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	pad.BackgroundTransparency = 0.42
	pad.BorderSizePixel = 0
	pad.Parent = parent

	local padCorner = Instance.new("UICorner")
	padCorner.CornerRadius = UDim.new(1, 0)
	padCorner.Parent = pad

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.Size = UDim2.fromOffset(48, 48)
	knob.BackgroundColor3 = Color3.fromRGB(235, 245, 255)
	knob.BackgroundTransparency = 0.14
	knob.BorderSizePixel = 0
	knob.Parent = pad

	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob

	state.touchPad = pad
	state.touchKnob = knob

	table.insert(state.connections, pad.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		state.touchInputObject = input
		setTouchInputFromPosition(input.Position)
	end))
	table.insert(state.connections, pad.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch and input == state.touchInputObject then
			setTouchInputFromPosition(input.Position)
		end
	end))
	table.insert(state.connections, UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch and input == state.touchInputObject then
			setTouchInputFromPosition(input.Position)
		end
	end))
	table.insert(state.connections, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			clearTouchInput(input)
		end
	end))
end

local function createUi()
	local gui = Instance.new("ScreenGui")
	gui.Name = "OrbitalStrikeTargetingGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 80

	local confirm = createButton(gui, "Confirm", UDim2.new(1, -76, 1, -94), Color3.fromRGB(40, 160, 90))
	local cancel = createButton(gui, "Cancel", UDim2.new(1, -76, 1, -148), Color3.fromRGB(180, 55, 55))
	table.insert(state.connections, confirm.Activated:Connect(confirmTarget))
	table.insert(state.connections, cancel.Activated:Connect(cancelTarget))
	createTouchMovePad(gui)

	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	state.ui = gui
end

local function bindCleanupSignals()
	table.insert(state.connections, LocalPlayer.CharacterRemoving:Connect(function()
		endTargeting(true)
	end))

	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(state.connections, humanoid.Died:Connect(function()
			endTargeting(true)
		end))
	end
end

local function beginLocalTargeting(context: ClientEffectContext)
	local payload = context.payload
	if payload.player ~= LocalPlayer or payload.abilityId ~= "OrbitalStrike" then
		return
	end

	local sessionId = payload.sessionId
	if typeof(sessionId) ~= "number" then
		return
	end

	endTargeting(true)

	local definition = AbilityConfig.GetDefinition("OrbitalStrike")
	local camera = workspace.CurrentCamera
	local rootPart = getRootPart()
	if not (definition and camera and rootPart) then
		return
	end

	state.active = true
	state.sessionId = sessionId
	state.controller = context.controller
	state.slot = if typeof(payload.slot) == "string" then payload.slot else AbilityConfig.Slots.Offensive
	state.abilityId = "OrbitalStrike"
	state.definition = definition
	state.savedCamera = {
		cameraType = camera.CameraType,
		cameraSubject = camera.CameraSubject,
		cframe = camera.CFrame,
		fieldOfView = camera.FieldOfView,
		mouseBehavior = UserInputService.MouseBehavior,
		mouseIconEnabled = UserInputService.MouseIconEnabled,
	}
	state.restoreTweening = false
	state.currentFocus = rootPart.Position
	state.placementCenter = rootPart.Position
	state.placementOffset = Vector3.zero
	state.placementForward = resolvePlacementForward(rootPart)
	state.targetPosition = rootPart.Position
	state.valid = false
	clearMoveInput()

	disableMovementControls()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	camera.CameraType = Enum.CameraType.Scriptable

	ensureMarker(definition)
	createUi()
	bindCleanupSignals()

	ContextActionService:UnbindAction(ACTION_NAME)
	ContextActionService:BindActionAtPriority(
		ACTION_NAME,
		handleTargetingAction,
		false,
		ACTION_PRIORITY,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.MouseButton2,
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Up,
		Enum.KeyCode.Down,
		Enum.KeyCode.Left,
		Enum.KeyCode.Right,
		Enum.KeyCode.Space,
		Enum.KeyCode.Q,
		Enum.KeyCode.Escape,
		Enum.KeyCode.ButtonA,
		Enum.KeyCode.ButtonB,
		Enum.KeyCode.ButtonR2,
		Enum.KeyCode.Thumbstick1,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.ButtonL3
	)

	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, stepTargeting)
	startTweenIn()
end

local function createLocalTelegraph(payload: any)
	if typeof(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local radius = if typeof(payload.radius) == "number" then math.max(payload.radius, 1) else 22
	local lifetime = if typeof(payload.strikeDelay) == "number" then math.max(payload.strikeDelay, 0.2) else 1.35
	local folder = workspace:FindFirstChild(PREVIEW_FOLDER_NAME)
	if not (folder and folder:IsA("Folder")) then
		folder = Instance.new("Folder")
		folder.Name = PREVIEW_FOLDER_NAME
		folder.Parent = workspace
	end

	local ring = Instance.new("Part")
	ring.Name = "OrbitalStrikeTelegraph"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanTouch = false
	ring.CanQuery = false
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.05, radius * 2, radius * 2)
	ring.CFrame = CFrame.new(payload.position + Vector3.yAxis * 0.12) * CFrame.Angles(0, 0, math.rad(90))
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 75, 75)
	ring.Transparency = 0.58
	ring.Parent = folder

	task.delay(lifetime, function()
		if ring.Parent then
			ring:Destroy()
		end
	end)
end

function OrbitalStrike.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if context.inputState and context.inputState ~= Enum.UserInputState.Begin then
		return true
	end
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end
	if state.active then
		cancelTarget()
		return true
	end

	context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Intent, {
		action = "BeginTargeting",
	})
	return true
end

function OrbitalStrike.OnEffect(context: ClientEffectContext)
	local payload = context.payload
	if context.effectName == "OrbitalStrikeBeginTargeting" then
		beginLocalTargeting(context)
	elseif typeof(payload) == "table" and context.effectName == "OrbitalStrikeRejected" and payload.abilityId == "OrbitalStrike" then
		if typeof(payload.sessionId) ~= "number" or payload.sessionId == state.sessionId then
			endTargeting(false)
		end
	elseif typeof(payload) == "table" and context.effectName == "OrbitalStrikeCancelled" and payload.abilityId == "OrbitalStrike" then
		if typeof(payload.sessionId) ~= "number" or payload.sessionId == state.sessionId then
			endTargeting(false)
		end
	elseif typeof(payload) == "table" and context.effectName == "OrbitalStrikeTelegraph" and payload.abilityId == "OrbitalStrike" then
		createLocalTelegraph(payload)
	elseif typeof(payload) == "table" and context.effectName == "OrbitalStrikeImpact" and payload.abilityId == "OrbitalStrike" then
		local definition = AbilityConfig.GetDefinition("OrbitalStrike")
		playStrikeVfx(payload)
		playProximityBlackFlash(payload, definition)
		if typeof(payload.position) == "Vector3" and type(CameraController.PlayOrbitalStrikeShake) == "function" then
			CameraController:PlayOrbitalStrikeShake(payload.position, definition)
		end
	elseif context.effectName == "OrbitalStrikeHitFlash" then
		playHitBlackFlash(payload)
	end
end

return OrbitalStrike
