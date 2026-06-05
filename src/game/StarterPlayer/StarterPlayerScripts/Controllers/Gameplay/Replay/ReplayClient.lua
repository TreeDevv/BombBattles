local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local EventTextPresenter = require(ReplicatedStorage.Shared.Effects.EventTextPresenter)
local ReplayMapSimulator = require(script.Parent:WaitForChild("ReplayMapSimulator"))
local ReplayAssets = require(script.Parent:WaitForChild("ReplayAssets"))
local ReplayOverlay = require(script.Parent:WaitForChild("ReplayOverlay"))
local ReplayRemoteBinder = require(script.Parent:WaitForChild("ReplayRemoteBinder"))
local ReplayCameraController = require(script.Parent:WaitForChild("ReplayCameraController"))
local ReplayStateBuilder = require(script.Parent:WaitForChild("ReplayStateBuilder"))
local ReplayVisualFactory = require(script.Parent:WaitForChild("ReplayVisualFactory"))
local ReplayAvatarFactory = require(script.Parent:WaitForChild("ReplayAvatarFactory"))
local KillEffectController = nil
local ReplayAnimationDriver = nil

do
	local controllersFolder = script.Parent.Parent
	local killEffectModule = controllersFolder and controllersFolder:FindFirstChild("KillEffectController")
	if killEffectModule and killEffectModule:IsA("ModuleScript") then
		local ok, loadedKillEffectController = pcall(require, killEffectModule)
		if ok then
			KillEffectController = loadedKillEffectController
		else
			warn("[ReplayClient] Failed to require KillEffectController: " .. tostring(loadedKillEffectController))
		end
	end
end

do
	local driverModule = script.Parent:WaitForChild("ReplayAnimationDriver", 10)
	if driverModule and driverModule:IsA("ModuleScript") then
		local ok, loadedDriver = pcall(require, driverModule)
		if ok then
			ReplayAnimationDriver = loadedDriver
		else
			warn("[ReplayClient] Failed to require ReplayAnimationDriver: " .. tostring(loadedDriver))
		end
	end
end

local ReplayClient = {}

ReplayClient._connections = {} :: { RBXScriptConnection }
ReplayClient._activeReplay = nil
ReplayClient._visualsEnabled = nil
ReplayClient._boundRemotes = {}
ReplayClient.ReplayStarted = Signal.new()
ReplayClient.ReplayEnded = Signal.new()

local SCENE_NAME = "_LocalReplayScene"
local OVERLAY_NAME = "_KillReplayOverlay"
local REPLAY_RENDER_STEP_NAME = "BombBattlesReplayClient"
local REPLAY_RENDER_PRIORITY = Enum.RenderPriority.Last.Value + 1
local LOCAL_REPLAY_ATTR = "BombBattlesLocalReplay"
local REPLAY_ASSETS_FOLDER_NAME = "ReplayAssets"
local REPLAY_VISUALS_ENABLED_ATTR = "ReplayVisualsEnabled"
local BASE_BOMB_SIZE = Vector3.new(1.4, 1.4, 1.4)
local MAX_REPLAY_DURATION_SECONDS = 12
local MAX_REPLAY_WALL_SECONDS = MAX_REPLAY_DURATION_SECONDS + 4
local MAX_REPLAY_OBJECTS = 720
local MAX_EVENT_VISUALS = 160
local MAX_EVENTS_PER_STEP = 12
local EXPLOSION_VFX_CLEANUP_SECONDS = 8
local BURST_MARKER_LIFETIME = 0.45
local CAMERA_SMOOTH_RESPONSIVENESS = 8
local CAMERA_DEFAULT_FOV = 72
local CAMERA_BOMB_FOV = 74
local CAMERA_IMPACT_FOV = 78
local KILLCAM_SLOW_MO_WINDOW = 0.85
local KILLCAM_SLOW_MO_SCALE = 0.45
local KILLCAM_KILLER_INTRO_SECONDS = 0.75
local KILLCAM_IMPACT_FOCUS_SECONDS = 1.15
local KILLCAM_BOMB_FOLLOW_END_LEAD = 0.65
local ANIMATION_STATE_SEND_RATE = 15
local ANIMATION_STATE_SEND_INTERVAL = 1 / ANIMATION_STATE_SEND_RATE
local MAX_ANIMATION_LINEAR_SPEED = 220
local MAX_AVATAR_TEMPLATE_CACHE = 32
local REPLAY_AVATAR_PRELOAD_TIMEOUT_SECONDS = 1.5
local MAX_REPLAY_POSE_JOINTS = 32
local MIN_REPLAY_CAMERA_FOV = 20
local MAX_REPLAY_CAMERA_FOV = 120
local DEBUG_REPLAY_ANIMATION = false
local DEBUG_REPLAY_POSE_JOINTS = false
local DEBUG_REPLAY_TIMING = false
local DEBUG_REPLAY_CLIENT = RunService:IsStudio()
local DEBUG_REPLAY_TIMING_INTERVAL = 0.5
local EVENT_PHASE_PRE_IMPACT = "PreImpact"
local EVENT_PHASE_IMPACT = "Impact"
local EVENT_PHASE_POST_IMPACT = "PostImpact"
local POST_IMPACT_EVENT_TYPES = table.freeze({
	PlayerDamaged = true,
	PlayerKilled = true,
	BaseDamaged = true,
})

local getReplayState
local getPlayerDisplayName
local replayAnimationDriverFailureLoggedByUserId = {}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteCFrame(value: any): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end

	local components = { value:GetComponents() }
	for _, component in ipairs(components) do
		if not isFiniteNumber(component) then
			return false
		end
	end
	return true
end

local function countTableEntries(value): number
	if typeof(value) ~= "table" then
		return 0
	end

	local count = 0
	for _ in pairs(value) do
		count += 1
	end
	return count
end

local function getModelRigType(model: Model?): Enum.HumanoidRigType?
	local humanoid = model and model:FindFirstChildOfClass("Humanoid")
	return if humanoid then humanoid.RigType else nil
end

local function getReplayConstants()
	return ReplayAssets.GetReplayConstants()
end

local function getSnapshotCFrame(snapshot): CFrame?
	if typeof(snapshot) ~= "table" then
		return nil
	end
	if typeof(snapshot.cframe) == "CFrame" then
		return snapshot.cframe
	end
	if typeof(snapshot.position) == "Vector3" then
		return CFrame.new(snapshot.position)
	end
	return nil
end

local function getUserIdKey(value: any): string?
	if not isFiniteNumber(value) then
		return nil
	end
	return tostring(math.floor(value))
end

local function getBombKey(value: any): string?
	local valueType = typeof(value)
	if valueType == "string" and value ~= "" then
		return value
	end
	if valueType == "number" and value == value then
		return tostring(value)
	end
	return nil
end

local function getTeamColor(teamName: any, userId: any): Color3
	if teamName == "Red" then
		return Color3.fromRGB(231, 77, 77)
	end
	if teamName == "Blue" then
		return Color3.fromRGB(72, 145, 255)
	end

	local seed = if isFiniteNumber(userId) then math.floor(userId) else 1
	return Color3.fromHSV((seed % 360) / 360, 0.55, 0.95)
end

local function getBoolAttribute(instance: Instance?, name: string): boolean?
	local value = instance and instance:GetAttribute(name)
	return if typeof(value) == "boolean" then value else nil
end

local function getNumberAttribute(instance: Instance?, name: string): number?
	local value = instance and instance:GetAttribute(name)
	return if isFiniteNumber(value) then value else nil
end

local function getStringAttribute(instance: Instance?, name: string): string?
	local value = instance and instance:GetAttribute(name)
	return if typeof(value) == "string" and value ~= "" then value else nil
end

local function clampVectorMagnitude(value: any, maxMagnitude: number): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	if value.X ~= value.X or value.Y ~= value.Y or value.Z ~= value.Z then
		return nil
	end

	local magnitude = value.Magnitude
	if magnitude <= maxMagnitude then
		return value
	end
	if magnitude <= 0 then
		return Vector3.zero
	end
	return value.Unit * maxMagnitude
end

local function getMotorJointKey(motor: Motor6D): string
	local part0Name = if motor.Part0 then motor.Part0.Name else ""
	local part1Name = if motor.Part1 then motor.Part1.Name else ""
	return part0Name .. ">" .. motor.Name .. ">" .. part1Name
end

local function collectLocalPoseJoints(character: Model): { any }
	local joints = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if #joints >= MAX_REPLAY_POSE_JOINTS then
			break
		end
		if not descendant:IsA("Motor6D") then
			continue
		end
		if not isFiniteCFrame(descendant.Transform) then
			continue
		end
		table.insert(joints, {
			name = descendant.Name,
			part0 = if descendant.Part0 then descendant.Part0.Name else nil,
			part1 = if descendant.Part1 then descendant.Part1.Name else nil,
			key = getMotorJointKey(descendant),
			transform = descendant.Transform,
		})
	end
	return joints
end

local function getLocalCameraSnapshot(sampleTime: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local cframe = camera.CFrame
	local focus = camera.Focus
	if not (isFiniteCFrame(cframe) and isFiniteCFrame(focus)) then
		return nil
	end

	return {
		sampleTime = sampleTime,
		cframe = cframe,
		focus = focus,
		fieldOfView = math.clamp(camera.FieldOfView, MIN_REPLAY_CAMERA_FOV, MAX_REPLAY_CAMERA_FOV),
	}
end

local function getLocalHumanoidState(character: Model?, humanoid: Humanoid?, rootPart: BasePart?)
	local sampleTime = workspace:GetServerTimeNow()
	local linearVelocity = if rootPart then rootPart.AssemblyLinearVelocity else Vector3.zero
	local horizontalVelocity = Vector3.new(linearVelocity.X, 0, linearVelocity.Z)
	local effectiveSpeed = getNumberAttribute(character, "Movement_EffectiveSpeed") or horizontalVelocity.Magnitude
	local moveMagnitude = getNumberAttribute(character, "Movement_MoveMagnitude")
	if not moveMagnitude then
		moveMagnitude = if effectiveSpeed > 0.5 then math.clamp(effectiveSpeed / 24, 0, 1) else 0
	end

	local grounded = getBoolAttribute(character, "Movement_Grounded")
	if grounded == nil and humanoid then
		grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	end

	local attrs = BombConfig.Attributes
	local rootCFrame = if rootPart and isFiniteCFrame(rootPart.CFrame) then rootPart.CFrame else nil
	local state = {
		sampleTime = sampleTime,
		rootCFrame = rootCFrame,
		grounded = if grounded == nil then true else grounded,
		sprinting = getBoolAttribute(character, "Movement_Sprinting") or effectiveSpeed >= 21,
		crouching = getBoolAttribute(character, "Movement_Crouching") or false,
		sliding = getBoolAttribute(character, "Movement_Sliding") or false,
		effectiveSpeed = effectiveSpeed,
		moveMagnitude = moveMagnitude,
		jumpSerial = getNumberAttribute(character, "Movement_JumpSerial"),
		lastJumpKind = getStringAttribute(character, "Movement_LastJumpKind"),
		shiftLocked = getBoolAttribute(character, "Camera_ShiftLocked") or false,
		linearVelocity = clampVectorMagnitude(linearVelocity, MAX_ANIMATION_LINEAR_SPEED) or Vector3.zero,
		bombCooking = LocalPlayer:GetAttribute(attrs.Cooking) == true,
		bombCookStartedAt = getNumberAttribute(LocalPlayer, attrs.CookStartedAt),
	}

	if character then
		local joints = collectLocalPoseJoints(character)
		if #joints > 0 then
			state.pose = {
				sampleTime = sampleTime,
				joints = joints,
			}
		end
	end

	local cameraSnapshot = getLocalCameraSnapshot(sampleTime)
	if cameraSnapshot then
		state.camera = cameraSnapshot
	end

	return state
end

local function buildLocalAnimationStatePayload()
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and rootPart and rootPart:IsA("BasePart")) then
		return nil
	end

	return getLocalHumanoidState(character, humanoid, rootPart)
end

local function getReplayAssetsFolder(): Folder?
	return ReplayAssets.GetReplayAssetsFolder(REPLAY_ASSETS_FOLDER_NAME)
end

local function getAssetsFolder(): Folder?
	return ReplayAssets.GetAssetsFolder()
end

local function getReplayEmitModule()
	return ReplayAssets.GetEmitModule()
end

local function ensureReplayEmitModuleInitialized(emitModule): boolean
	return ReplayAssets.EnsureEmitModuleInitialized(emitModule)
end

local function getByPath(root: Instance, path): Instance?
	return ReplayAssets.GetByPath(root, path)
end

local function normalizeLookupName(value: any): string
	return ReplayAssets.NormalizeLookupName(value)
end

local function buildLookupNames(...): { string }
	return ReplayAssets.BuildLookupNames(...)
end

local function findChildLoose(parent: Instance?, name: any): Instance?
	return ReplayAssets.FindChildLoose(parent, name)
end

local function isReplayTemplate(instance: Instance?): boolean
	return ReplayAssets.IsReplayTemplate(instance)
end

local function findReplayTemplateInFolder(folder: Instance?, names): Instance?
	return ReplayAssets.FindReplayTemplateInFolder(folder, names)
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

local function getFirstBasePart(root: Instance): BasePart?
	if root:IsA("BasePart") then
		return root
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

local function pivotReplayInstance(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function placeReplayEffectInstance(instance: Instance, position: Vector3)
	pivotReplayInstance(instance, CFrame.new(position))

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanQuery = false
		instance.CanTouch = false
	end
end

local function prepareReplayClone(clone: Instance)
	local records = {}
	local rootPart = getFirstBasePart(clone)

	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			table.insert(records, {
				part = descendant,
				baseSize = descendant.Size,
				transparency = descendant.Transparency,
			})
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = false
		elseif descendant:IsA("Sound") then
			descendant.Looped = false
			descendant:Stop()
		end
	end

	if clone:IsA("BasePart") then
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.CastShadow = false
		table.insert(records, {
			part = clone,
			baseSize = clone.Size,
			transparency = clone.Transparency,
		})
	end

	return records, rootPart
end

local function reserveReplayObjects(count: number?): boolean
	local state = if getReplayState then getReplayState() else nil
	if not state then
		return true
	end

	local amount = math.max(math.floor(tonumber(count) or 1), 1)
	local maxObjects = if isFiniteNumber(state.maxObjects) then state.maxObjects else MAX_REPLAY_OBJECTS
	local current = if isFiniteNumber(state.objectCount) then state.objectCount else 0
	if current + amount > maxObjects then
		return false
	end

	state.objectCount = current + amount
	return true
end

local function areReplayVisualsEnabled(): boolean
	if typeof(ReplayClient._visualsEnabled) == "boolean" then
		return ReplayClient._visualsEnabled
	end

	local attribute = LocalPlayer:GetAttribute(REPLAY_VISUALS_ENABLED_ATTR)
	return if typeof(attribute) == "boolean" then attribute else true
end

local function makePart(name: string, size: Vector3, color: Color3, shape: Enum.PartType?): Part
	return ReplayVisualFactory.MakePart(name, size, color, shape)
end

local function setPartVisible(part: BasePart, visible: boolean, transparency: number?)
	ReplayVisualFactory.SetPartVisible(part, visible, transparency)
end

local function setPartRecordsVisible(records, visible: boolean)
	ReplayVisualFactory.SetPartRecordsVisible(records, visible)
end

local function getBombTypeColor(bombType: any): Color3
	local name = string.lower(if typeof(bombType) == "string" then bombType else "")
	if string.find(name, "fire", 1, true) then
		return Color3.fromRGB(255, 88, 48)
	elseif string.find(name, "freeze", 1, true) or string.find(name, "ice", 1, true) then
		return Color3.fromRGB(102, 214, 255)
	elseif string.find(name, "acid", 1, true) then
		return Color3.fromRGB(110, 235, 94)
	elseif string.find(name, "blackhole", 1, true) or string.find(name, "black hole", 1, true) then
		return Color3.fromRGB(130, 85, 255)
	elseif string.find(name, "mega", 1, true) or string.find(name, "fat", 1, true) then
		return Color3.fromRGB(255, 171, 64)
	elseif string.find(name, "bullet", 1, true) or string.find(name, "fast", 1, true) then
		return Color3.fromRGB(255, 232, 108)
	elseif string.find(name, "wind", 1, true) then
		return Color3.fromRGB(129, 255, 228)
	end
	return Color3.fromRGB(38, 38, 45)
end

local function getReplayBombPulseProgress(visual, snapshot, replayTime): (number, number)
	local fuseStartedAt = if typeof(snapshot) == "table" and isFiniteNumber(snapshot.fuseStartedAt)
		then snapshot.fuseStartedAt
		else nil
	local fuseEndsAt = if typeof(snapshot) == "table" and isFiniteNumber(snapshot.fuseEndsAt)
		then snapshot.fuseEndsAt
		else nil
	local resolvedReplayTime = if isFiniteNumber(replayTime) then replayTime else (fuseStartedAt or 0)

	if not fuseStartedAt and fuseEndsAt then
		fuseStartedAt = fuseEndsAt - BombConfig.FuseSeconds
	elseif fuseStartedAt and not fuseEndsAt then
		fuseEndsAt = fuseStartedAt + BombConfig.FuseSeconds
	elseif not fuseStartedAt and not fuseEndsAt then
		if not isFiniteNumber(visual.fallbackFuseStartedAt) then
			visual.fallbackFuseStartedAt = resolvedReplayTime
		end
		fuseStartedAt = visual.fallbackFuseStartedAt
		fuseEndsAt = fuseStartedAt + BombConfig.FuseSeconds
	end

	local fuseDuration = math.max(fuseEndsAt - fuseStartedAt, 0.001)
	local elapsed = math.clamp(resolvedReplayTime - fuseStartedAt, 0, fuseDuration)
	return elapsed / fuseDuration, elapsed
end

local function getReplayBombPulseColor(fuseProgress: number, elapsed: number): Color3
	local progress = math.clamp(fuseProgress, 0, 1)
	local pulseElapsed = math.max(elapsed, 0)
	local startHz = math.max(BombConfig.PulseStartHz, 0.01)
	local endHz = math.max(BombConfig.PulseEndHz, startHz)
	local cycles = (startHz * pulseElapsed) + (0.5 * (endHz - startHz) * progress * pulseElapsed)
	local alpha = (1 - math.cos(cycles * math.pi * 2)) * 0.5
	return BombConfig.PulseWhite:Lerp(BombConfig.PulseRed, alpha)
end

local function setReplayBombPulseVisible(visual, visible: boolean)
	if visual.highlight and visual.highlight.Parent then
		visual.highlight.Enabled = visible
	end
	if visual.glow and visual.glow.Parent then
		visual.glow.Enabled = visible
	end
end

local function attachReplayBombPulse(visual, adornee: Instance, rootPart: BasePart?)
	local highlight = Instance.new("Highlight")
	highlight.Name = "BombFuseHighlight"
	highlight.Adornee = adornee
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillTransparency = BombConfig.PulseStartFillTransparency
	highlight.OutlineTransparency = BombConfig.PulseStartOutlineTransparency
	highlight.Enabled = false
	highlight.Parent = adornee
	visual.highlight = highlight

	if rootPart then
		local light = Instance.new("PointLight")
		light.Name = "BombThrowGlow"
		light.Color = BombConfig.PreviewColor
		light.Brightness = 1.3
		light.Range = 9
		light.Enabled = false
		light.Parent = rootPart
		visual.glow = light
	end
end

local function updateReplayBombPulse(visual, snapshot, replayTime)
	local fuseProgress, elapsed = getReplayBombPulseProgress(visual, snapshot, replayTime)
	local color = getReplayBombPulseColor(fuseProgress, elapsed)
	local fillTransparency = BombConfig.PulseStartFillTransparency
		+ ((BombConfig.PulseEndFillTransparency - BombConfig.PulseStartFillTransparency) * fuseProgress)
	local outlineTransparency = BombConfig.PulseStartOutlineTransparency
		+ ((BombConfig.PulseEndOutlineTransparency - BombConfig.PulseStartOutlineTransparency) * fuseProgress)

	if visual.highlight and visual.highlight.Parent then
		visual.highlight.Enabled = true
		visual.highlight.FillColor = color
		visual.highlight.OutlineColor = color
		visual.highlight.FillTransparency = math.clamp(fillTransparency, 0, 1)
		visual.highlight.OutlineTransparency = math.clamp(outlineTransparency, 0, 1)
	end
	if visual.glow and visual.glow.Parent then
		visual.glow.Enabled = true
		visual.glow.Color = color
		visual.glow.Brightness = 1.3 + (0.9 * fuseProgress)
		visual.glow.Range = 9 + (3 * fuseProgress)
	end
end

local function getTemplateFromCategory(root: Instance?, categoryName: string, names): Instance?
	local category = root and root:FindFirstChild(categoryName)
	return findReplayTemplateInFolder(category, names)
end

local function getBombTemplate(bombType: any): Instance?
	local names = buildLookupNames(
		bombType,
		BombConfig.RuntimeBombName,
		"NormalBomb",
		"BasicBomb",
		"Default"
	)

	local replayAssets = getReplayAssetsFolder()
	local replayTemplate = getTemplateFromCategory(replayAssets, "Bombs", names)
	if replayTemplate then
		return replayTemplate
	end

	local assets = getAssetsFolder()
	return getTemplateFromCategory(assets, "Bombs", names)
end

local function makeNameplate(parent: Instance, userId: number, teamName: any, color: Color3): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ReplayNameplate"
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(180, 44)
	billboard.StudsOffset = Vector3.new(0, 4.1, 0)
	billboard.Parent = parent

	local label = Instance.new("TextLabel")
	label.Name = "Name"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 26)
	label.Font = Enum.Font.GothamBold
	label.Text = if getPlayerDisplayName then getPlayerDisplayName(userId) else tostring(userId)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextSize = 16
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0.35
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = billboard

	local team = Instance.new("TextLabel")
	team.Name = "Team"
	team.BackgroundTransparency = 1
	team.Position = UDim2.new(0, 0, 0, 24)
	team.Size = UDim2.new(1, 0, 0, 18)
	team.Font = Enum.Font.GothamMedium
	team.Text = if typeof(teamName) == "string" and teamName ~= "" then teamName else "USER " .. tostring(userId)
	team.TextColor3 = color
	team.TextSize = 12
	team.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	team.TextStrokeTransparency = 0.45
	team.TextTruncate = Enum.TextTruncate.AtEnd
	team.Parent = billboard

	return billboard
end

local function prepareReplayAvatar(model: Model)
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	if not (rootPart and rootPart:IsA("BasePart")) then
		rootPart = getFirstBasePart(model)
	end
	if not rootPart then
		return nil, nil
	end

	model.PrimaryPart = rootPart

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.AutoRotate = false
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.NameDisplayDistance = 0
	end

	local records = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = false
		elseif descendant:IsA("Sound") then
			descendant.Looped = false
			descendant:Stop()
		elseif descendant:IsA("BillboardGui") or descendant:IsA("Highlight") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = descendant == rootPart
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			descendant.Massless = true
			table.insert(records, {
				part = descendant,
				root = descendant == rootPart,
				transparency = descendant.Transparency,
			})
		end
	end

	return records, rootPart
end

local function buildReplayPoseJoints(model: Model)
	local joints = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if #joints >= MAX_REPLAY_POSE_JOINTS then
			break
		end
		if not descendant:IsA("Motor6D") then
			continue
		end

		table.insert(joints, {
			joint = descendant,
			name = descendant.Name,
			part0 = if descendant.Part0 then descendant.Part0.Name else nil,
			part1 = if descendant.Part1 then descendant.Part1.Name else nil,
			key = getMotorJointKey(descendant),
		})
	end
	return joints
end

local function makeAvatarCharacterVisual(parent: Instance, userId: number, teamName: any, hasPoseSnapshots: boolean?)
	local model = ReplayAvatarFactory.CloneCachedTemplate(userId)
	if not model then
		return nil
	end
	model.Name = "ReplayPlayer_" .. tostring(userId)

	local records, rootPart = prepareReplayAvatar(model)
	if not (records and rootPart and #records > 0) then
		model:Destroy()
		return nil
	end

	local color = getTeamColor(teamName, userId)
	local teamRing = makePart("TeamRing", Vector3.new(2.8, 0.08, 2.8), color, Enum.PartType.Cylinder)
	teamRing.Material = Enum.Material.Neon
	teamRing.Transparency = 0.18
	teamRing.Parent = model
	table.insert(records, {
		part = teamRing,
		offset = CFrame.new(0, -2.9, 0),
		transparency = teamRing.Transparency,
	})

	local highlight = Instance.new("Highlight")
	highlight.Name = "TeamOutline"
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillTransparency = 1
	highlight.OutlineColor = color
	highlight.OutlineTransparency = 0.12
	highlight.Parent = model

	local nameplate = makeNameplate(rootPart, userId, teamName, color)
	model.Parent = parent

	local poseJoints = buildReplayPoseJoints(model)
	local animationDriver = nil
	if ReplayAnimationDriver then
		local ok, driver = pcall(function()
			return ReplayAnimationDriver.new(model)
		end)
		if ok and driver then
			animationDriver = driver
			if DEBUG_REPLAY_ANIMATION then
				print(
					("[ReplayClient] Animation driver ready user=%s rigType=%s tracks=%d bombTracks=%d hasPose=%s"):format(
						tostring(userId),
						tostring(getModelRigType(model)),
						countTableEntries(driver.tracks),
						countTableEntries(driver.bombTracks),
						tostring(hasPoseSnapshots == true)
					)
				)
			end
		elseif DEBUG_REPLAY_ANIMATION and not replayAnimationDriverFailureLoggedByUserId[userId] then
			replayAnimationDriverFailureLoggedByUserId[userId] = true
			warn("[ReplayClient] Failed to create replay animation driver: " .. tostring(driver))
		end
	end

	return {
		avatar = true,
		model = model,
		root = rootPart,
		parts = records,
		nameplate = nameplate,
		highlight = highlight,
		poseJoints = poseJoints,
		animationDriver = animationDriver,
		lastCFrame = nil,
	}
end

local function makeCharacterVisual(parent: Instance, userId: number, teamName: any, hasPoseSnapshots: boolean?)
	local avatarVisual = makeAvatarCharacterVisual(parent, userId, teamName, hasPoseSnapshots)
	if avatarVisual then
		return avatarVisual
	end

	local model = Instance.new("Model")
	model.Name = "ReplayPlayer_" .. tostring(userId)
	model.Parent = parent

	local color = getTeamColor(teamName, userId)
	local root = makePart("Root", Vector3.new(0.2, 0.2, 0.2), color, nil)
	root.Transparency = 1
	root.Parent = model
	model.PrimaryPart = root

	local body = makePart("Body", Vector3.new(2, 2.4, 2), color, nil)
	body.Parent = model

	local head = makePart("Head", Vector3.new(1.25, 1.25, 1.25), Color3.fromRGB(245, 218, 178), Enum.PartType.Ball)
	head.Parent = model

	local leftArm = makePart("LeftArm", Vector3.new(0.55, 1.7, 0.55), color:Lerp(Color3.new(0, 0, 0), 0.12), nil)
	leftArm.Parent = model

	local rightArm = makePart("RightArm", Vector3.new(0.55, 1.7, 0.55), color:Lerp(Color3.new(0, 0, 0), 0.12), nil)
	rightArm.Parent = model

	local teamRing = makePart("TeamRing", Vector3.new(2.8, 0.08, 2.8), color, Enum.PartType.Cylinder)
	teamRing.Material = Enum.Material.Neon
	teamRing.Transparency = 0.18
	teamRing.Parent = model

	local highlight = Instance.new("Highlight")
	highlight.Name = "TeamOutline"
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillTransparency = 1
	highlight.OutlineColor = color
	highlight.OutlineTransparency = 0.12
	highlight.Parent = model

	local nameplate = makeNameplate(root, userId, teamName, color)

	local parts = {
		{ part = root, offset = CFrame.new(), root = true },
		{ part = body, offset = CFrame.new(0, 0.1, 0) },
		{ part = head, offset = CFrame.new(0, 1.95, 0) },
		{ part = leftArm, offset = CFrame.new(-1.35, 0.15, 0) },
		{ part = rightArm, offset = CFrame.new(1.35, 0.15, 0) },
		{ part = teamRing, offset = CFrame.new(0, -2.7, 0) },
	}

	return {
		model = model,
		root = root,
		parts = parts,
		nameplate = nameplate,
		highlight = highlight,
		lastCFrame = nil,
	}
end

local function makeFallbackBombVisual(parent: Instance, bombId: string, bombType: any)
	local model = Instance.new("Model")
	model.Name = "ReplayBomb_" .. bombId
	model.Parent = parent

	local color = getBombTypeColor(bombType)
	local shell = makePart("Shell", BASE_BOMB_SIZE, color, Enum.PartType.Ball)
	shell.Material = Enum.Material.Neon
	shell.Parent = model
	model.PrimaryPart = shell

	local accent = makePart("TypeAccent", Vector3.new(0.42, 0.42, 0.42), color:Lerp(Color3.new(1, 1, 1), 0.42), Enum.PartType.Ball)
	accent.Material = Enum.Material.Neon
	accent.Parent = model

	local records = {
		{ part = shell, baseSize = shell.Size, transparency = shell.Transparency },
		{ part = accent, baseSize = accent.Size, transparency = accent.Transparency },
	}

	local visual = {
		instance = model,
		rootPart = shell,
		parts = records,
		fallback = true,
		offsets = {
			[shell] = CFrame.new(),
			[accent] = CFrame.new(0.46, 0.58, 0),
		},
		bombType = bombType,
		lastCFrame = nil,
	}
	attachReplayBombPulse(visual, model, shell)
	return visual
end

local function makeBombVisual(parent: Instance, bombId: string, bombType: any)
	local template = getBombTemplate(bombType)
	if template then
		local clone = template:Clone()
		clone.Name = "ReplayBomb_" .. bombId
		local records, rootPart = prepareReplayClone(clone)
		if rootPart and #records > 0 then
			clone.Parent = parent
			local visual = {
				instance = clone,
				rootPart = rootPart,
				parts = records,
				fallback = false,
				bombType = bombType,
				lastCFrame = nil,
			}
			attachReplayBombPulse(visual, clone, rootPart)
			return visual
		end
		clone:Destroy()
	end

	return makeFallbackBombVisual(parent, bombId, bombType)
end

local function getSnapshotPose(snapshot)
	if typeof(snapshot) ~= "table" then
		return nil
	end

	local pose = snapshot.pose
	if typeof(pose) ~= "table" or typeof(pose.joints) ~= "table" then
		return nil
	end
	return pose
end

local function getPoseJointMap(pose)
	if typeof(pose) ~= "table" or typeof(pose.joints) ~= "table" then
		return nil
	end
	if typeof(pose._jointMap) == "table" then
		return pose._jointMap
	end

	local map = {}
	for _, record in ipairs(pose.joints) do
		if typeof(record) ~= "table" then
			continue
		end
		if not isFiniteCFrame(record.transform) then
			continue
		end

		if typeof(record.key) == "string" and record.key ~= "" then
			map[record.key] = record
		end
		if typeof(record.name) == "string" and record.name ~= "" and not map[record.name] then
			map[record.name] = record
		end
	end
	pose._jointMap = map
	return map
end

local function getPoseJointRecord(map, poseJoint)
	if typeof(map) ~= "table" or typeof(poseJoint) ~= "table" then
		return nil
	end
	if typeof(poseJoint.key) == "string" and poseJoint.key ~= "" and map[poseJoint.key] then
		return map[poseJoint.key]
	end
	if typeof(poseJoint.name) == "string" and poseJoint.name ~= "" then
		return map[poseJoint.name]
	end
	return nil
end

local function applyPoseSnapshots(visual, leftSnapshot, rightSnapshot, alpha: number): boolean
	local poseJoints = visual.poseJoints
	if typeof(poseJoints) ~= "table" or #poseJoints == 0 then
		return false
	end

	local leftPose = getSnapshotPose(leftSnapshot)
	local rightPose = getSnapshotPose(rightSnapshot)
	if not (leftPose or rightPose) then
		return false
	end

	local leftMap = getPoseJointMap(leftPose)
	local rightMap = getPoseJointMap(rightPose)
	if not (leftMap or rightMap) then
		return false
	end

	local applied = 0
	local clampedAlpha = math.clamp(alpha, 0, 1)
	for _, poseJoint in ipairs(poseJoints) do
		local joint = poseJoint.joint
		if not (joint and joint.Parent) then
			continue
		end

		local leftRecord = getPoseJointRecord(leftMap, poseJoint)
		local rightRecord = getPoseJointRecord(rightMap, poseJoint)
		local leftTransform = leftRecord and leftRecord.transform
		local rightTransform = rightRecord and rightRecord.transform
		local transform = nil

		if isFiniteCFrame(leftTransform) and isFiniteCFrame(rightTransform) then
			transform = leftTransform:Lerp(rightTransform, clampedAlpha)
		elseif isFiniteCFrame(rightTransform) then
			transform = rightTransform
		elseif isFiniteCFrame(leftTransform) then
			transform = leftTransform
		end

		if transform then
			joint.Transform = transform
			applied += 1
		end
	end

	return applied > 0
end

local function setCharacterCFrame(visual, cframe: CFrame, alive: boolean?, snapshot, leftSnapshot, rightSnapshot, alpha: number?)
	local poseApplied = false
	local resolvedCFrame = cframe
	if DEBUG_REPLAY_POSE_JOINTS and visual.avatar then
		poseApplied = applyPoseSnapshots(visual, leftSnapshot or snapshot, rightSnapshot or snapshot, alpha or 0)
	end

	visual.lastCFrame = resolvedCFrame
	local bodyTransparency = if alive == false then 0.45 else 0

	if visual.avatar then
		if visual.root and visual.root.Parent then
			visual.root.CFrame = resolvedCFrame
		else
			pivotReplayInstance(visual.model, resolvedCFrame)
		end

		for _, entry in ipairs(visual.parts) do
			local part = entry.part
			if not (part and part.Parent) then
				continue
			end

			if entry.offset then
				part.CFrame = resolvedCFrame * entry.offset
			end

			if entry.root then
				part.Transparency = 1
			else
				setPartVisible(part, true, math.max(entry.transparency or 0, bodyTransparency))
			end
		end

		if visual.nameplate then
			visual.nameplate.Enabled = true
		end
		if visual.highlight then
			visual.highlight.Enabled = true
		end
		if visual.animationDriver and not (DEBUG_REPLAY_POSE_JOINTS and poseApplied) then
			visual.animationDriver:Step(snapshot, resolvedCFrame)
		end
		return
	end

	for _, entry in ipairs(visual.parts) do
		entry.part.CFrame = resolvedCFrame * entry.offset
		if entry.root then
			entry.part.Transparency = 1
		else
			setPartVisible(entry.part, true, bodyTransparency)
		end
	end

	if visual.nameplate then
		visual.nameplate.Enabled = true
	end
	if visual.highlight then
		visual.highlight.Enabled = true
	end
end

local function hideCharacter(visual)
	for _, entry in ipairs(visual.parts) do
		setPartVisible(entry.part, false)
	end
	if visual.nameplate then
		visual.nameplate.Enabled = false
	end
	if visual.highlight then
		visual.highlight.Enabled = false
	end
end

local function setBombCFrame(visual, cframe: CFrame, snapshot, replayTime: number)
	visual.lastCFrame = cframe
	pivotReplayInstance(visual.instance, cframe)

	if visual.fallback and typeof(snapshot) == "table" and isFiniteNumber(snapshot.sizeScale) then
		local scale = math.clamp(snapshot.sizeScale, 0.35, 4)
		for _, record in ipairs(visual.parts) do
			if record.part and record.part.Parent then
				record.part.Size = record.baseSize * scale
			end
		end
	end

	if visual.fallback and visual.offsets then
		for _, record in ipairs(visual.parts) do
			local offset = visual.offsets[record.part]
			if offset then
				record.part.CFrame = cframe * offset
			end
		end
	end

	setPartRecordsVisible(visual.parts, true)
	updateReplayBombPulse(visual, snapshot, replayTime)
end

local function hideBomb(visual)
	setPartRecordsVisible(visual.parts, false)
	setReplayBombPulseVisible(visual, false)
end

local function getReplayBombKeysForEvent(event): { string }
	local keys = {}
	local seen = {}

	local function addKey(value)
		local key = getBombKey(value)
		if key and not seen[key] then
			seen[key] = true
			table.insert(keys, key)
		end
	end

	if typeof(event) == "table" then
		addKey(event.projectileId)
		addKey(event.sourceId)
		addKey(event.bombId)
	end
	return keys
end

local function hideReplayBombForEvent(state, event)
	if not (state and typeof(state.bombVisuals) == "table") then
		return
	end

	if typeof(state.explodedBombs) ~= "table" then
		state.explodedBombs = {}
	end
	for _, key in ipairs(getReplayBombKeysForEvent(event)) do
		state.explodedBombs[key] = true
		local visual = state.bombVisuals[key]
		if visual then
			hideBomb(visual)
		end
	end
end

local function scheduleDestroy(instance: Instance, lifetime: number)
	ReplayVisualFactory.ScheduleDestroy(instance, lifetime)
end

local function playTween(instance: Instance, tweenInfo: TweenInfo, goals)
	ReplayVisualFactory.PlayTween(instance, tweenInfo, goals)
end

local function createEffectAnchor(parent: Instance, position: Vector3, name: string): Part
	return ReplayVisualFactory.CreateEffectAnchor(parent, position, name)
end

local function playReplayEventText(parent: Instance, event, position: Vector3?)
	return EventTextPresenter.PlayReplayEvent(parent, event, {
		position = position,
	})
end

local function createPulseSphere(parent: Instance, position: Vector3, radius: number, color: Color3, lifetime: number?)
	return ReplayVisualFactory.CreatePulseSphere(parent, position, radius, color, lifetime, BURST_MARKER_LIFETIME)
end

local function createRingMarker(parent: Instance, position: Vector3, radius: number, color: Color3, lifetime: number?)
	return ReplayVisualFactory.CreateRingMarker(parent, position, radius, color, lifetime, BURST_MARKER_LIFETIME)
end

local function fadeAndDestroyTemplate(clone: Instance, records, lifetime: number)
	local fadeSeconds = math.clamp(lifetime * 0.35, 0.15, 0.45)
	local fadeDelay = math.max(lifetime - fadeSeconds, 0)

	task.delay(fadeDelay, function()
		for _, record in ipairs(records or {}) do
			local part = record.part
			if part and part.Parent then
				playTween(part, TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					Transparency = 1,
				})
			end
		end
	end)

	scheduleDestroy(clone, lifetime + 0.05)
end

local function createReplayTemplateEffect(
	parent: Instance,
	template: Instance?,
	position: Vector3,
	name: string,
	lifetime: number,
	tint: Color3?
): Instance?
	if not isReplayTemplate(template) then
		return nil
	end

	local clone = template:Clone()
	clone.Name = name
	local records, rootPart = prepareReplayClone(clone)
	if not (rootPart and #records > 0) then
		clone:Destroy()
		return nil
	end

	for _, record in ipairs(records) do
		local part = record.part
		if part and part.Parent then
			if tint then
				part.Color = part.Color:Lerp(tint, 0.3)
			end
			part.Transparency = record.transparency
		end
	end

	pivotReplayInstance(clone, CFrame.new(position))
	clone.Parent = parent
	fadeAndDestroyTemplate(clone, records, lifetime)
	return clone
end

local function getExplosionTemplate(bombType: any): Instance?
	local names = buildLookupNames(
		bombType,
		"Default",
		"Explosion"
	)

	local replayAssets = getReplayAssetsFolder()
	local replayVfx = replayAssets and replayAssets:FindFirstChild("VFX")
	local replayExplosion = replayVfx and replayVfx:FindFirstChild("Explosion")
	local replayTemplate = findReplayTemplateInFolder(replayExplosion, names)
	if replayTemplate then
		return replayTemplate
	end

	local assets = getAssetsFolder()
	local vfx = assets and assets:FindFirstChild("VFX")
	local explosion = vfx and vfx:FindFirstChild("Explosion")
	return findReplayTemplateInFolder(explosion, names)
end

local function playReplayExplosionVfx(parent: Instance, bombType: any, position: Vector3): boolean
	local template = getExplosionTemplate(bombType)
	local emitModule = getReplayEmitModule()
	if not (template and emitModule and ensureReplayEmitModuleInitialized(emitModule)) then
		return false
	end
	if type(emitModule.emit) ~= "function" then
		return false
	end

	local clone = template:Clone()
	clone.Name = "ReplayBombExplosionVFX"
	placeReplayEffectInstance(clone, position)
	clone.Parent = parent

	local cleanedUp = false
	local function cleanup()
		if cleanedUp then
			return
		end
		cleanedUp = true
		if clone.Parent then
			clone:Destroy()
		end
	end

	local ok, env = pcall(function()
		return emitModule.emit(clone)
	end)
	if ok and typeof(env) == "table" and env.Finished and type(env.Finished.finally) == "function" then
		env.Finished:finally(cleanup):catch(function(err)
			warn("[ReplayClient] Explosion VFX emit failed: " .. tostring(err))
		end)
	else
		if not ok then
			warn("[ReplayClient] Explosion VFX emit failed: " .. tostring(env))
		end
		task.delay(EXPLOSION_VFX_CLEANUP_SECONDS, cleanup)
	end

	task.delay(EXPLOSION_VFX_CLEANUP_SECONDS, cleanup)
	return true
end

local function resolveAbilityDefinition(abilityName: any)
	if typeof(abilityName) ~= "string" or abilityName == "" then
		return nil, nil
	end

	local directDefinition = AbilityConfig.GetDefinition(abilityName)
	if directDefinition then
		return directDefinition.id, directDefinition
	end

	local normalizedName = normalizeLookupName(abilityName)
	for abilityId, definition in pairs(AbilityConfig.Definitions) do
		if normalizeLookupName(abilityId) == normalizedName then
			return abilityId, definition
		end
		if typeof(definition) == "table" then
			if normalizeLookupName(definition.displayName) == normalizedName then
				return abilityId, definition
			end
			if normalizeLookupName(definition.behaviorId) == normalizedName then
				return abilityId, definition
			end
		end
	end

	return abilityName, nil
end

local function getAbilityTemplate(abilityName: any): Instance?
	local abilityId, definition = resolveAbilityDefinition(abilityName)
	local names = buildLookupNames(
		abilityId,
		abilityName,
		if typeof(definition) == "table" then definition.behaviorId else nil,
		"Default"
	)

	local replayAssets = getReplayAssetsFolder()
	local replayAbilities = replayAssets and replayAssets:FindFirstChild("Abilities")
	local replayTemplate = findReplayTemplateInFolder(replayAbilities, names)
	if replayTemplate then
		return replayTemplate
	end

	local pathTemplate = if typeof(definition) == "table" then getByPath(ReplicatedStorage, definition.assetPath) else nil
	if isReplayTemplate(pathTemplate) then
		return pathTemplate
	end

	local assets = getAssetsFolder()
	local abilities = assets and assets:FindFirstChild("Abilities")
	return findReplayTemplateInFolder(abilities, names)
end

local function playOptionalEventSound(soundName: string, parent: Instance?)
	ReplayAssets.PlayOptionalEventSound(soundName, parent)
end

local function preprocessFrames(rawFrames)
	local frames = {}
	if typeof(rawFrames) ~= "table" then
		return frames
	end

	for _, frame in ipairs(rawFrames) do
		if typeof(frame) ~= "table" or not isFiniteNumber(frame.timestamp) then
			continue
		end

		local processed = {
			timestamp = frame.timestamp,
			players = {},
			bombs = {},
		}

		if typeof(frame.players) == "table" then
			for _, playerSnapshot in ipairs(frame.players) do
				local key = getUserIdKey(playerSnapshot.userId)
				if key and getSnapshotCFrame(playerSnapshot) then
					processed.players[key] = playerSnapshot
				end
			end
		end

		if typeof(frame.bombs) == "table" then
			for index, bombSnapshot in ipairs(frame.bombs) do
				local key = getBombKey(bombSnapshot.bombId) or tostring(index)
				if getSnapshotCFrame(bombSnapshot) then
					processed.bombs[key] = bombSnapshot
				end
			end
		end

		table.insert(frames, processed)
	end

	table.sort(frames, function(left, right)
		return left.timestamp < right.timestamp
	end)

	return frames
end

local function getEventTimestamp(event): number?
	if typeof(event) ~= "table" then
		return nil
	end
	if isFiniteNumber(event.timestamp) then
		return event.timestamp
	end
	if isFiniteNumber(event.t) then
		return event.t
	end
	return nil
end

local function preprocessEvents(rawEvents, startTime: number, endTime: number)
	local events = {}
	if typeof(rawEvents) ~= "table" then
		return events
	end

	for _, event in ipairs(rawEvents) do
		if #events >= MAX_EVENT_VISUALS then
			break
		end

		local timestamp = getEventTimestamp(event)
		if not timestamp or timestamp < startTime or timestamp > endTime then
			continue
		end
		if typeof(event.eventType) ~= "string" or event.eventType == "" then
			continue
		end

		event.__replayOrder = #events + 1
		table.insert(events, event)
	end

	table.sort(events, function(left, right)
		local leftTimestamp = getEventTimestamp(left) or 0
		local rightTimestamp = getEventTimestamp(right) or 0
		if leftTimestamp == rightTimestamp then
			return (left.__replayOrder or 0) < (right.__replayOrder or 0)
		end
		return leftTimestamp < rightTimestamp
	end)

	return events
end

local function findKillTimestamp(events, victimUserId: any, startTime: number, endTime: number): number
	local victimKey = getUserIdKey(victimUserId)
	local firstKillTimestamp = nil

	for _, event in ipairs(events) do
		if event.eventType ~= "PlayerKilled" then
			continue
		end

		local timestamp = getEventTimestamp(event)
		if not timestamp then
			continue
		end

		firstKillTimestamp = firstKillTimestamp or timestamp
		local eventVictimKey = getUserIdKey(event.victimUserId)
		if victimKey and eventVictimKey == victimKey then
			return timestamp
		end
	end

	if firstKillTimestamp then
		return firstKillTimestamp
	end

	local duration = math.max(endTime - startTime, 0.1)
	return math.clamp(startTime + math.max(duration - 2, duration * 0.72), startTime, endTime)
end

local function collectExplosionPositions(events)
	local positionsBySourceId = {}
	for _, event in ipairs(events) do
		if event.eventType ~= "BombExploded" then
			continue
		end

		local position = nil
		if typeof(event.position) == "Vector3" then
			position = event.position
		elseif typeof(event.cframe) == "CFrame" then
			position = event.cframe.Position
		end
		local key = getBombKey(event.bombId) or getBombKey(event.sourceId)
		if position and key then
			positionsBySourceId[key] = position
		end
	end
	return positionsBySourceId
end

local function collectPlayerMeta(frames)
	local meta = {}
	for _, frame in ipairs(frames) do
		for key, snapshot in pairs(frame.players) do
			if not meta[key] then
				meta[key] = {
					userId = snapshot.userId,
					teamName = snapshot.teamName,
					hasPose = getSnapshotPose(snapshot) ~= nil,
				}
			elseif not meta[key].hasPose and getSnapshotPose(snapshot) ~= nil then
				meta[key].hasPose = true
			end
		end
	end
	return meta
end

local function preloadAvatarTemplates(playerMeta)
	local userIds = {}
	local seen = {}
	for _, meta in pairs(playerMeta or {}) do
		local userId = meta and meta.userId
		local key = getUserIdKey(userId)
		if key and not seen[key] then
			seen[key] = true
			table.insert(userIds, math.floor(userId))
		end
	end

	ReplayAvatarFactory.PreloadUserIds(userIds, REPLAY_AVATAR_PRELOAD_TIMEOUT_SECONDS)
end

local function collectBombMeta(frames)
	local meta = {}
	for _, frame in ipairs(frames) do
		for key, snapshot in pairs(frame.bombs) do
			local record = meta[key]
			if not record then
				record = {
					bombId = snapshot.bombId,
					bombType = snapshot.bombType,
					ownerUserId = snapshot.ownerUserId,
				}
				meta[key] = record
			else
				if record.bombType == nil and typeof(snapshot.bombType) == "string" and snapshot.bombType ~= "" then
					record.bombType = snapshot.bombType
				end
				if record.ownerUserId == nil and isFiniteNumber(snapshot.ownerUserId) then
					record.ownerUserId = snapshot.ownerUserId
				end
			end
		end
	end
	return meta
end

local function findFramePair(frames, replayTime: number, startIndex: number)
	local count = #frames
	if count == 0 then
		return nil, nil, 1, 0
	end
	if count == 1 then
		return frames[1], frames[1], 1, 0
	end

	local index = math.clamp(startIndex or 1, 1, count - 1)
	while index < count - 1 and frames[index + 1].timestamp <= replayTime do
		index += 1
	end
	while index > 1 and frames[index].timestamp > replayTime do
		index -= 1
	end

	local left = frames[index]
	local right = frames[index + 1] or left
	local span = math.max(right.timestamp - left.timestamp, 0.001)
	local alpha = math.clamp((replayTime - left.timestamp) / span, 0, 1)
	return left, right, index, alpha
end

local function interpolateSnapshot(leftSnapshot, rightSnapshot, alpha: number): (CFrame?, any)
	local leftCFrame = getSnapshotCFrame(leftSnapshot)
	local rightCFrame = getSnapshotCFrame(rightSnapshot)

	if leftCFrame and rightCFrame then
		return leftCFrame:Lerp(rightCFrame, alpha), rightSnapshot or leftSnapshot
	end
	if leftCFrame then
		return leftCFrame, leftSnapshot
	end
	if rightCFrame then
		return rightCFrame, rightSnapshot
	end
	return nil, nil
end

local function getSnapshotCamera(snapshot)
	if typeof(snapshot) ~= "table" or typeof(snapshot.camera) ~= "table" then
		return nil
	end

	local camera = snapshot.camera
	if not isFiniteCFrame(camera.cframe) then
		return nil
	end

	local focus = if isFiniteCFrame(camera.focus) then camera.focus else CFrame.new(camera.cframe.Position + camera.cframe.LookVector * 24)
	local fieldOfView = if isFiniteNumber(camera.fieldOfView)
		then math.clamp(camera.fieldOfView, MIN_REPLAY_CAMERA_FOV, MAX_REPLAY_CAMERA_FOV)
		else CAMERA_DEFAULT_FOV

	return {
		cframe = camera.cframe,
		focus = focus,
		fieldOfView = fieldOfView,
	}
end

local function hasRecordedCameraForUser(frames, userId: any): boolean
	local key = getUserIdKey(userId)
	if not key then
		return false
	end

	for _, frame in ipairs(frames) do
		local snapshot = frame.players and frame.players[key]
		if getSnapshotCamera(snapshot) then
			return true
		end
	end
	return false
end

local function interpolateCameraSnapshot(leftSnapshot, rightSnapshot, alpha: number)
	local leftCamera = getSnapshotCamera(leftSnapshot)
	local rightCamera = getSnapshotCamera(rightSnapshot)

	if leftCamera and rightCamera then
		local clampedAlpha = math.clamp(alpha, 0, 1)
		return {
			cframe = leftCamera.cframe:Lerp(rightCamera.cframe, clampedAlpha),
			focus = leftCamera.focus:Lerp(rightCamera.focus, clampedAlpha),
			fieldOfView = leftCamera.fieldOfView + (rightCamera.fieldOfView - leftCamera.fieldOfView) * clampedAlpha,
		}
	end
	return rightCamera or leftCamera
end

local function createScene(): Folder
	local existing = workspace:FindFirstChild(SCENE_NAME)
	local sceneName = SCENE_NAME
	if existing and existing:GetAttribute(LOCAL_REPLAY_ATTR) == true then
		existing:Destroy()
	elseif existing then
		sceneName = SCENE_NAME .. "_" .. tostring(LocalPlayer.UserId)
	end

	local folder = Instance.new("Folder")
	folder.Name = sceneName
	folder:SetAttribute(LOCAL_REPLAY_ATTR, true)
	folder.Parent = workspace
	return folder
end

getPlayerDisplayName = function(userId: any): string
	if not isFiniteNumber(userId) then
		return "UNKNOWN"
	end

	local resolvedUserId = math.floor(userId)
	local _, player = pcall(function()
		return Players:GetPlayerByUserId(resolvedUserId)
	end)
	if player then
		return if player.DisplayName ~= "" then player.DisplayName else player.Name
	end
	for _, candidate in ipairs(Players:GetPlayers()) do
		if candidate.UserId == resolvedUserId then
			return if candidate.DisplayName ~= "" then candidate.DisplayName else candidate.Name
		end
	end

	return tostring(resolvedUserId)
end

local function createOverlay(payload)
	return ReplayOverlay.Create(payload, {
		overlayName = OVERLAY_NAME,
		localReplayAttribute = LOCAL_REPLAY_ATTR,
		getPlayerDisplayName = getPlayerDisplayName,
		isFiniteNumber = isFiniteNumber,
	})
end

local function captureCameraState()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	return {
		camera = camera,
		cameraType = camera.CameraType,
		cameraSubject = camera.CameraSubject,
		cframe = camera.CFrame,
		focus = camera.Focus,
		fieldOfView = camera.FieldOfView,
	}
end

local function getFallbackCameraSubject(): Instance?
	local character = LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function restoreCamera(state)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local cameraState = state and state.cameraState
	if not cameraState then
		return
	end

	local subject = cameraState.cameraSubject
	if not (subject and subject.Parent) then
		subject = getFallbackCameraSubject()
	end

	pcall(function()
		if subject then
			camera.CameraSubject = subject
		end
		camera.CameraType = cameraState.cameraType or Enum.CameraType.Custom
		camera.CFrame = cameraState.cframe or camera.CFrame
		camera.Focus = cameraState.focus or camera.Focus
		if isFiniteNumber(cameraState.fieldOfView) then
			camera.FieldOfView = cameraState.fieldOfView
		end
	end)
end

local function getVisualCFrame(visual): CFrame?
	local cframe = visual and visual.lastCFrame
	return if typeof(cframe) == "CFrame" then cframe else nil
end

local function getVisualPosition(visual): Vector3?
	local cframe = getVisualCFrame(visual)
	return if typeof(cframe) == "CFrame" then cframe.Position else nil
end

getReplayState = function()
	return ReplayClient._activeReplay
end

local function getEffectsParent(state): Instance?
	return state and (state.effectsFolder or state.scene)
end

local function getEventPosition(event): Vector3?
	if typeof(event) ~= "table" then
		return nil
	end
	if typeof(event.position) == "Vector3" then
		return event.position
	end
	if typeof(event.cframe) == "CFrame" then
		return event.cframe.Position
	end
	return nil
end

local function findImpactPosition(events, positionsBySourceId, sourceId: any, victimUserId: any): Vector3?
	local sourceKey = getBombKey(sourceId)
	if sourceKey and positionsBySourceId and positionsBySourceId[sourceKey] then
		return positionsBySourceId[sourceKey]
	end

	for _, event in ipairs(events) do
		if event.eventType == "BombExploded" then
			local position = getEventPosition(event)
			if position then
				return position
			end
		end
	end

	local victimKey = getUserIdKey(victimUserId)
	for _, event in ipairs(events) do
		if event.eventType == "PlayerKilled" then
			local eventVictimKey = getUserIdKey(event.victimUserId)
			if not victimKey or eventVictimKey == victimKey then
				local position = getEventPosition(event)
				if position then
					return position
				end
			end
		end
	end

	return nil
end

local function getPlayerVisualByUserId(state, userId)
	local key = getUserIdKey(userId)
	return if key then state.playerVisuals[key] else nil
end

local function getPlayerEventPosition(state, userId): Vector3?
	local visual = getPlayerVisualByUserId(state, userId)
	return getVisualPosition(visual)
end

local function flashPlayerVisual(visual, color: Color3, lifetime: number)
	if not visual then
		return
	end

	local originals = {}
	for _, entry in ipairs(visual.parts) do
		if not entry.root and entry.part and entry.part.Parent then
			originals[entry.part] = entry.part.Color
			entry.part.Color = color
		end
	end

	task.delay(lifetime, function()
		for part, originalColor in pairs(originals) do
			if part.Parent then
				part.Color = originalColor
			end
		end
	end)
end

local function playBombThrownEvent(event)
	local state = getReplayState()
	local ownerVisual = if state then getPlayerVisualByUserId(state, event.ownerUserId) else nil
	if ownerVisual and ownerVisual.animationDriver then
		ownerVisual.animationDriver:PlayBombRelease()
	end

	local parent = getEffectsParent(state)
	local position = getEventPosition(event)
	if not (parent and position) then
		return
	end
	if not reserveReplayObjects(4) then
		return
	end

	local color = getBombTypeColor(event.bombType)
	createPulseSphere(parent, position, 2.2, color:Lerp(Color3.fromRGB(255, 226, 112), 0.35), 0.32)
	createRingMarker(parent, position, 2.4, color, 0.42)
	playReplayEventText(parent, event, position)
end

local function PlayExplosionEvent(event)
	local state = getReplayState()
	local parent = getEffectsParent(state)
	local position = getEventPosition(event)
	if not (parent and position) then
		return
	end
	if not reserveReplayObjects(8) then
		return
	end

	hideReplayBombForEvent(state, event)
	local outerRadius = if isFiniteNumber(event.outerRadius)
		then event.outerRadius
		elseif isFiniteNumber(event.radius)
		then event.radius
		else 12
	local terrainRadius = if isFiniteNumber(event.terrainRadius) then event.terrainRadius else outerRadius
	local innerRadius = if isFiniteNumber(event.innerRadius) then event.innerRadius else outerRadius * 0.45
	outerRadius = math.clamp(outerRadius, 2, 28)
	terrainRadius = math.clamp(terrainRadius, 2, 32)
	innerRadius = math.clamp(innerRadius, 1, outerRadius)

	local anchor = createEffectAnchor(parent, position, "ReplayExplosionAnchor")
	local bombColor = getBombTypeColor(event.bombType)
	if not playReplayExplosionVfx(parent, event.bombType, position) then
		createReplayTemplateEffect(parent, getExplosionTemplate(event.bombType), position, "ReplayExplosionTemplate", 1.1, bombColor)
	end
	createRingMarker(parent, position, outerRadius, Color3.fromRGB(255, 150, 64), 0.72)
	createPulseSphere(parent, position, terrainRadius, Color3.fromRGB(255, 96, 54), 0.55)
	createPulseSphere(parent, position, innerRadius, Color3.fromRGB(255, 218, 83), 0.32)
	playReplayEventText(parent, event, position)
	playOptionalEventSound("Explosion", anchor)
	scheduleDestroy(anchor, 1.4)
end

local function PlayDamageEvent(event)
	local state = getReplayState()
	local parent = getEffectsParent(state)
	if not parent then
		return
	end

	local visual = getPlayerVisualByUserId(state, event.victimUserId)
	local position = getVisualPosition(visual) or getEventPosition(event)
	if not position then
		return
	end
	if not reserveReplayObjects(3) then
		return
	end

	flashPlayerVisual(visual, Color3.fromRGB(255, 70, 70), 0.16)
	playReplayEventText(parent, event, position)
end

local function shouldPlayReplayKillEffect(state, event): boolean
	if typeof(state) ~= "table" or typeof(event) ~= "table" then
		return false
	end

	local killerKey = getUserIdKey(event.killerUserId)
	local victimKey = getUserIdKey(event.victimUserId)
	if not killerKey or not victimKey or killerKey == victimKey then
		return false
	end

	local replayKillerKey = getUserIdKey(state.killerUserId)
	local featuredPlayerKey = getUserIdKey(state.playerUserId)
	return killerKey == replayKillerKey or killerKey == featuredPlayerKey
end

local function playReplayKillEffect(event)
	if not (KillEffectController and type(KillEffectController.PlayReplayKillEffect) == "function") then
		return false
	end

	return KillEffectController:PlayReplayKillEffect({
		killerUserId = event.killerUserId,
		victimUserId = event.victimUserId,
		replayType = if getReplayState() then getReplayState().replayType else nil,
		reason = "ReplayElimination",
	})
end

local function PlayKillEvent(event)
	local state = getReplayState()
	if shouldPlayReplayKillEffect(state, event) then
		playReplayKillEffect(event)
	end

	local parent = getEffectsParent(state)
	if not parent then
		return
	end

	local position = getPlayerEventPosition(state, event.victimUserId) or getEventPosition(event)
	if not position then
		return
	end
	if not reserveReplayObjects(5) then
		return
	end

	createPulseSphere(parent, position + Vector3.new(0, 1.2, 0), 3.2, Color3.fromRGB(255, 48, 72), 0.45)
	createRingMarker(parent, position, 3.6, Color3.fromRGB(255, 48, 72), 0.55)
	playReplayEventText(parent, event, position)
end

local function playBaseDamageEvent(event)
	local state = getReplayState()
	local parent = getEffectsParent(state)
	local sourceKey = getBombKey(event.sourceId)
	local position = getEventPosition(event)
		or (sourceKey and state and state.eventPositionsBySourceId and state.eventPositionsBySourceId[sourceKey])
	if not (parent and position) then
		return
	end
	if not reserveReplayObjects(5) then
		return
	end

	local marker = makePart("ReplayBaseDamageMarker", Vector3.new(0.32, 3.2, 0.32), Color3.fromRGB(255, 142, 62), nil)
	marker.Material = Enum.Material.Neon
	marker.Transparency = 0.15
	marker.CFrame = CFrame.new(position + Vector3.new(0, 1.6, 0))
	marker.Parent = parent
	playTween(marker, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 1,
		Size = Vector3.new(0.12, 4.6, 0.12),
	})
	scheduleDestroy(marker, 0.55)
	createRingMarker(parent, position, 4.2, Color3.fromRGB(255, 142, 62), 0.52)
	createPulseSphere(parent, position, 3.4, Color3.fromRGB(255, 142, 62), 0.4)
end

local function PlayAbilityEvent(event)
	local state = getReplayState()
	local parent = getEffectsParent(state)
	if not parent then
		return
	end

	local position = getEventPosition(event) or getPlayerEventPosition(state, event.userId)
	if not position then
		return
	end
	if not reserveReplayObjects(8) then
		return
	end

	local abilityName = if typeof(event.abilityName) == "string" and event.abilityName ~= "" then event.abilityName else "ABILITY"
	local abilityId, definition = resolveAbilityDefinition(abilityName)
	local template = getAbilityTemplate(abilityName)
	local abilityColor = if typeof(definition) == "table" and definition.slot == AbilityConfig.Slots.Offensive
		then Color3.fromRGB(255, 158, 76)
		else Color3.fromRGB(90, 226, 255)
	createReplayTemplateEffect(parent, template, position, "ReplayAbility_" .. tostring(abilityId or abilityName), 1.25, abilityColor)
	createRingMarker(parent, position, 3.0, abilityColor, 0.5)
	createPulseSphere(parent, position + Vector3.new(0, 1.1, 0), 2.5, abilityColor, 0.35)
	playReplayEventText(parent, event, position)
end

local function playReplayEvent(event)
	local eventType = event.eventType
	if eventType == "BombThrown" then
		playBombThrownEvent(event)
	elseif eventType == "BombExploded" then
		PlayExplosionEvent(event)
	elseif eventType == "PlayerDamaged" then
		PlayDamageEvent(event)
	elseif eventType == "PlayerKilled" then
		PlayKillEvent(event)
	elseif eventType == "BaseDamaged" then
		playBaseDamageEvent(event)
	elseif eventType == "AbilityUsed" then
		PlayAbilityEvent(event)
	end
end

local function getReplayEventPhase(event): string
	local eventType = if typeof(event) == "table" then event.eventType else nil
	if eventType == "BombExploded" then
		return EVENT_PHASE_IMPACT
	end
	if POST_IMPACT_EVENT_TYPES[eventType] then
		return EVENT_PHASE_POST_IMPACT
	end
	return EVENT_PHASE_PRE_IMPACT
end

local function refreshNextReplayEventIndex(state)
	local events = state.events
	if typeof(events) ~= "table" then
		state.nextEventIndex = 1
		return
	end

	local firedEventIndices = state.firedEventIndices
	local index = 1
	while index <= #events and typeof(firedEventIndices) == "table" and firedEventIndices[index] == true do
		index += 1
	end
	state.nextEventIndex = index
end

local function hasPendingReplayEvents(state): boolean
	local events = state.events
	if typeof(events) ~= "table" then
		return false
	end

	local firedEventIndices = state.firedEventIndices
	for index = 1, #events do
		if not (typeof(firedEventIndices) == "table" and firedEventIndices[index] == true) then
			return true
		end
	end
	return false
end

local function fireDueReplayEvents(state, replayTime: number, phase: string)
	local events = state.events
	if typeof(events) ~= "table" then
		return
	end

	if typeof(state.firedEventIndices) ~= "table" then
		state.firedEventIndices = {}
	end
	local firedEventIndices = state.firedEventIndices
	local fired = 0
	for index, event in ipairs(events) do
		if fired >= MAX_EVENTS_PER_STEP then
			break
		end
		if firedEventIndices[index] == true then
			continue
		end

		local timestamp = getEventTimestamp(event)
		if timestamp and timestamp > replayTime then
			break
		end
		if getReplayEventPhase(event) ~= phase then
			continue
		end

		firedEventIndices[index] = true
		fired += 1
		playReplayEvent(event)
	end
	refreshNextReplayEventIndex(state)
end

local function getFirstVisiblePlayerPosition(state): Vector3?
	for _, visual in pairs(state.playerVisuals) do
		local position = getVisualPosition(visual)
		if position then
			return position
		end
	end
	return nil
end

local function getReplayPlaybackSpeed(state, replayTime: number): number
	local killTimestamp = state.killTimestamp
	if not isFiniteNumber(killTimestamp) then
		return 1
	end

	if math.abs(replayTime - killTimestamp) <= KILLCAM_SLOW_MO_WINDOW then
		return KILLCAM_SLOW_MO_SCALE
	end

	return 1
end

local function updateReplayCamera(state)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable

	local victimPosition = if state.victimUserId then getVisualPosition(state.playerVisuals[tostring(state.victimUserId)]) else nil
	local killerPosition = if state.killerUserId then getVisualPosition(state.playerVisuals[tostring(state.killerUserId)]) else nil
	local focus = victimPosition or killerPosition or getFirstVisiblePlayerPosition(state) or Vector3.zero
	if victimPosition and killerPosition then
		focus = victimPosition:Lerp(killerPosition, 0.42)
	end

	local direction = Vector3.new(0.65, 0, 1)
	if victimPosition and killerPosition then
		local delta = victimPosition - killerPosition
		if delta.Magnitude > 0.05 then
			direction = delta.Unit
		end
	end

	local lookAt = focus + Vector3.new(0, 1.8, 0)
	local cameraPosition = lookAt - direction * 18 + Vector3.new(0, 8, 0)
	camera.CFrame = CFrame.lookAt(cameraPosition, lookAt)
	camera.Focus = CFrame.new(lookAt)
end

local function getRawCameraSampleTime(snapshot): number?
	local camera = if typeof(snapshot) == "table" then snapshot.camera else nil
	if typeof(camera) == "table" and isFiniteNumber(camera.sampleTime) then
		return camera.sampleTime
	end
	return nil
end

local function formatReplayDebugTime(value: any): string
	return if isFiniteNumber(value) then ("%.3f"):format(value) else "nil"
end

local function formatReplayDebugNumber(value: any): string
	return if isFiniteNumber(value) then ("%.2f"):format(value) else "nil"
end

local function debugReplayTiming(state, replayTime: number, left, right, alpha: number, cameraUserKey: string)
	if not DEBUG_REPLAY_TIMING then
		return
	end

	local elapsed = if isFiniteNumber(state and state.wallClockElapsed) then state.wallClockElapsed else 0
	if elapsed - (state.lastTimingDebugAt or -math.huge) < DEBUG_REPLAY_TIMING_INTERVAL then
		return
	end
	state.lastTimingDebugAt = elapsed

	local leftSnapshot = left.players and left.players[cameraUserKey]
	local rightSnapshot = right.players and right.players[cameraUserKey]
	local rootCFrame = select(1, interpolateSnapshot(leftSnapshot, rightSnapshot, alpha))
	local cameraSnapshot = interpolateCameraSnapshot(leftSnapshot, rightSnapshot, alpha)
	local cameraRootDistance = if rootCFrame and cameraSnapshot
		then (cameraSnapshot.cframe.Position - rootCFrame.Position).Magnitude
		else nil
	local rootSource = if typeof(rightSnapshot) == "table" and typeof(rightSnapshot.rootSource) == "string"
		then rightSnapshot.rootSource
		elseif typeof(leftSnapshot) == "table" and typeof(leftSnapshot.rootSource) == "string"
		then leftSnapshot.rootSource
		else "unknown"
	print(
		("[ReplayClient] timing user=%s replay=%s left=%s right=%s alpha=%.2f camL=%s camR=%s root=%s camRootDist=%s"):format(
			cameraUserKey,
			formatReplayDebugTime(replayTime),
			formatReplayDebugTime(left.timestamp),
			formatReplayDebugTime(right.timestamp),
			math.clamp(alpha or 0, 0, 1),
			formatReplayDebugTime(getRawCameraSampleTime(leftSnapshot)),
			formatReplayDebugTime(getRawCameraSampleTime(rightSnapshot)),
			rootSource,
			formatReplayDebugNumber(cameraRootDistance)
		)
	)
end

local function updateRecordedReplayCamera(state, left, right, alpha: number, replayTime: number): boolean
	local cameraUserKey = getUserIdKey(state and state.cameraUserId)
	if not cameraUserKey then
		return false
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end

	if not left then
		return false
	end

	local leftSnapshot = left.players and left.players[cameraUserKey]
	local rightSnapshot = right.players and right.players[cameraUserKey]
	local cameraSnapshot = interpolateCameraSnapshot(leftSnapshot, rightSnapshot, alpha)
	if not cameraSnapshot then
		return false
	end

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = cameraSnapshot.cframe
	camera.Focus = cameraSnapshot.focus
	camera.FieldOfView = cameraSnapshot.fieldOfView
	debugReplayTiming(state, replayTime, left, right, alpha, cameraUserKey)
	return true
end

local function updateVisuals(state, left, right, alpha: number, replayTime: number)
	if not left then
		return
	end

	for key, visual in pairs(state.playerVisuals) do
		local cframe, snapshot = interpolateSnapshot(left.players[key], right.players[key], alpha)
		if cframe then
			setCharacterCFrame(visual, cframe, snapshot and snapshot.alive, snapshot, left.players[key], right.players[key], alpha)
		else
			hideCharacter(visual)
		end
	end

	for key, visual in pairs(state.bombVisuals) do
		local cframe, snapshot = interpolateSnapshot(left.bombs[key], right.bombs[key], alpha)
		if state.explodedBombs and state.explodedBombs[key] then
			hideBomb(visual)
		elseif cframe then
			setBombCFrame(visual, cframe, snapshot, replayTime)
		else
			hideBomb(visual)
		end
	end
end

local function getReplayPayloadType(payload): string?
	return if typeof(payload) == "table" and typeof(payload.type) == "string" then payload.type else nil
end

local function buildReplaySignalPayloadFromState(state, reason: string)
	return {
		type = state and state.replayType,
		reason = reason,
		playerUserId = state and state.playerUserId,
		killerUserId = state and state.killerUserId,
		victimUserId = state and state.victimUserId,
		startTime = state and state.startTime,
		endTime = state and state.endTime,
	}
end

local function buildReplaySignalPayloadFromPayload(payload, reason: string)
	return {
		type = getReplayPayloadType(payload),
		reason = reason,
		playerUserId = if typeof(payload) == "table" then payload.playerUserId else nil,
		killerUserId = if typeof(payload) == "table" then payload.killerUserId else nil,
		victimUserId = if typeof(payload) == "table" then payload.victimUserId else nil,
		startTime = if typeof(payload) == "table" then payload.startTime else nil,
		endTime = if typeof(payload) == "table" then payload.endTime else nil,
	}
end

local function getPayloadFrameCount(payload): number
	return if typeof(payload) == "table" and typeof(payload.frames) == "table" then #payload.frames else 0
end

local function warnReplayBuildSkipped(reason: string, payload)
	warn(
		("[ReplayClient] Replay skipped reason=%s type=%s frames=%d start=%s end=%s"):format(
			reason,
			tostring(getReplayPayloadType(payload)),
			getPayloadFrameCount(payload),
			tostring(if typeof(payload) == "table" then payload.startTime else nil),
			tostring(if typeof(payload) == "table" then payload.endTime else nil)
		)
	)
end

local function debugReplayClient(message: string, ...)
	if DEBUG_REPLAY_CLIENT then
		warn("[ReplayClient] " .. message, ...)
	end
end

local function getRemoteBinderDeps()
	return {
		debugReplayClient = debugReplayClient,
		getReplayConstants = getReplayConstants,
		isFiniteNumber = isFiniteNumber,
		buildLocalAnimationStatePayload = buildLocalAnimationStatePayload,
		animationStateSendInterval = ANIMATION_STATE_SEND_INTERVAL,
	}
end

function ReplayClient:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	self._connections = {}
	self._boundRemotes = {}
end

function ReplayClient:CancelReplay(reason: string?)
	local state = self._activeReplay
	self._activeReplay = nil
	if not state then
		return
	end

	if state.renderConnection then
		pcall(function()
			state.renderConnection:Disconnect()
		end)
		state.renderConnection = nil
	end
	if typeof(state.renderBindingName) == "string" then
		pcall(function()
			RunService:UnbindFromRenderStep(state.renderBindingName)
		end)
		state.renderBindingName = nil
	end

	pcall(function()
		restoreCamera(state)
	end)

	for _, visual in pairs(state.playerVisuals or {}) do
		local driver = visual.animationDriver
		if driver then
			pcall(function()
				driver:Destroy()
			end)
		end
	end

	if state.overlay then
		pcall(function()
			state.overlay:Destroy()
		end)
	end
	if state.mapContext then
		pcall(function()
			ReplayMapSimulator.Destroy(state.mapContext)
		end)
	end
	if state.scene then
		pcall(function()
			state.scene:Destroy()
		end)
	end

	self.ReplayEnded:Fire(buildReplaySignalPayloadFromState(state, reason or "Canceled"))
end

local function getStateBuilderDeps()
	return {
		ReplayMapSimulator = ReplayMapSimulator,
		ReplayCameraController = ReplayCameraController,
		areReplayVisualsEnabled = areReplayVisualsEnabled,
		warnReplayBuildSkipped = warnReplayBuildSkipped,
		isFiniteNumber = isFiniteNumber,
		maxReplayDurationSeconds = MAX_REPLAY_DURATION_SECONDS,
		maxReplayObjects = MAX_REPLAY_OBJECTS,
		createScene = createScene,
		preprocessFrames = preprocessFrames,
		preprocessEvents = preprocessEvents,
		collectExplosionPositions = collectExplosionPositions,
		getBombKey = getBombKey,
		findKillTimestamp = findKillTimestamp,
		findImpactPosition = findImpactPosition,
		hasRecordedCameraForUser = hasRecordedCameraForUser,
		createOverlay = createOverlay,
		captureCameraState = captureCameraState,
		collectPlayerMeta = collectPlayerMeta,
		preloadAvatarTemplates = preloadAvatarTemplates,
		collectBombMeta = collectBombMeta,
		reserveReplayObjects = reserveReplayObjects,
		makeCharacterVisual = makeCharacterVisual,
		makeBombVisual = makeBombVisual,
		cameraControllerDeps = {
			isFiniteNumber = isFiniteNumber,
			getUserIdKey = getUserIdKey,
			getBombKey = getBombKey,
			getVisualPosition = getVisualPosition,
			getVisualCFrame = getVisualCFrame,
			cameraSmoothResponsiveness = CAMERA_SMOOTH_RESPONSIVENESS,
			cameraDefaultFov = CAMERA_DEFAULT_FOV,
			cameraBombFov = CAMERA_BOMB_FOV,
			cameraImpactFov = CAMERA_IMPACT_FOV,
			killcamKillerIntroSeconds = KILLCAM_KILLER_INTRO_SECONDS,
			killcamImpactFocusSeconds = KILLCAM_IMPACT_FOCUS_SECONDS,
			killcamBombFollowEndLead = KILLCAM_BOMB_FOLLOW_END_LEAD,
		},
	}
end

function ReplayClient:_buildReplayState(payload)
	return ReplayStateBuilder.Build(self, payload, getStateBuilderDeps())
end

function ReplayClient:_stepReplay(state, deltaTime: number?)
	local resolvedDeltaTime = if isFiniteNumber(deltaTime) and deltaTime >= 0 then math.min(deltaTime, 0.1) else 1 / 60
	state.wallClockElapsed = (state.wallClockElapsed or 0) + resolvedDeltaTime
	if state.wallClockElapsed > MAX_REPLAY_WALL_SECONDS then
		self:CancelReplay("TimedOut")
		return
	end

	local speedScale = if state.hasRecordedCamera then 1 else getReplayPlaybackSpeed(state, state.playhead)
	state.playhead = math.min(state.playhead + resolvedDeltaTime * speedScale, state.endTime)
	local replayTime = state.playhead
	local left, right, nextIndex, alpha = findFramePair(state.frames, replayTime, state.frameIndex)
	state.frameIndex = nextIndex
	if not left then
		return
	end

	updateVisuals(state, left, right, alpha, replayTime)
	fireDueReplayEvents(state, replayTime, EVENT_PHASE_PRE_IMPACT)
	fireDueReplayEvents(state, replayTime, EVENT_PHASE_IMPACT)
	state.nextDestructionIndex =
		ReplayMapSimulator.ApplyEventsUpTo(state.mapContext, state.destructionEvents, replayTime, state.nextDestructionIndex, {
			spawnDebris = true,
			maxEvents = ReplayMapSimulator.GetMaxDestructionEventsPerStep(),
		})
	fireDueReplayEvents(state, replayTime, EVENT_PHASE_POST_IMPACT)
	local recordedCameraUpdated = updateRecordedReplayCamera(state, left, right, alpha, replayTime)
	if not recordedCameraUpdated and state.cameraController then
		state.cameraController:Step(resolvedDeltaTime, replayTime)
	elseif not recordedCameraUpdated then
		updateReplayCamera(state)
	end

	local destructionPending = typeof(state.destructionEvents) == "table"
		and state.nextDestructionIndex <= #state.destructionEvents
	if state.playhead >= state.endTime and not destructionPending and not hasPendingReplayEvents(state) then
		self:CancelReplay("Completed")
	end
end

function ReplayClient:SetReplayVisualsEnabled(enabled: boolean)
	self._visualsEnabled = enabled == true
	LocalPlayer:SetAttribute(REPLAY_VISUALS_ENABLED_ATTR, self._visualsEnabled)
	if not self._visualsEnabled then
		self:CancelReplay("VisualsDisabled")
	end
	return self._visualsEnabled
end

function ReplayClient:GetReplayVisualsEnabled(): boolean
	return areReplayVisualsEnabled()
end

function ReplayClient:GetActiveReplayDebugInfo()
	local state = self._activeReplay
	if not state then
		return nil
	end

	return {
		replayType = state.replayType,
		startTime = state.startTime,
		endTime = state.endTime,
		playhead = state.playhead,
		events = if typeof(state.events) == "table" then #state.events else 0,
		eventsPending = hasPendingReplayEvents(state),
		nextEventIndex = state.nextEventIndex,
		destructionEvents = if typeof(state.destructionEvents) == "table" then #state.destructionEvents else 0,
		map = ReplayMapSimulator.GetDebugInfo(state.mapContext),
	}
end

function ReplayClient:PlayReplay(payload): boolean
	debugReplayClient("PlayReplay called", getReplayPayloadType(payload), "frames", getPayloadFrameCount(payload))
	self:CancelReplay("Interrupted")

	local replayType = getReplayPayloadType(payload)
	local started = false

	local ok, err = pcall(function()
		local state = self:_buildReplayState(payload)
		if not state then
			return
		end

		started = true
		debugReplayClient(
			"Replay started",
			state.replayType,
			"start",
			state.startTime,
			"end",
			state.endTime,
			"frames",
			#state.frames
		)
		self.ReplayStarted:Fire(buildReplaySignalPayloadFromState(state, "Started"))
		RunService:UnbindFromRenderStep(REPLAY_RENDER_STEP_NAME)
		state.renderBindingName = REPLAY_RENDER_STEP_NAME
		RunService:BindToRenderStep(REPLAY_RENDER_STEP_NAME, REPLAY_RENDER_PRIORITY, function(deltaTime)
			local activeState = self._activeReplay
			if activeState == state then
				local stepOk, stepErr = pcall(function()
					self:_stepReplay(state, deltaTime)
				end)
				if not stepOk then
					warn("[ReplayClient] Failed during kill replay playback: " .. tostring(stepErr))
					self:CancelReplay("Error")
				end
			end
		end)

		self:_stepReplay(state, 0)
	end)

	if not ok then
		warn("[ReplayClient] Failed to play replay: " .. tostring(err))
		self:CancelReplay("Error")
		if replayType then
			self.ReplayEnded:Fire(buildReplaySignalPayloadFromPayload(payload, "Failed"))
		end
	elseif not started and replayType then
		debugReplayClient("Replay did not start", replayType)
		self.ReplayEnded:Fire(buildReplaySignalPayloadFromPayload(payload, "Skipped"))
	end

	return started
end

function ReplayClient:PlayKillReplay(payload)
	self:PlayReplay(payload)
end

function ReplayClient:PlayPOTGReplay(payload)
	self:PlayReplay(payload)
end

function ReplayClient:RequestKillReplay(reason: string?): boolean
	return ReplayRemoteBinder.RequestKillReplay(self, reason, getRemoteBinderDeps())
end

function ReplayClient:_bindRemoteInstance(remoteName: string, remote: Instance): boolean
	return ReplayRemoteBinder.BindRemoteInstance(self, remoteName, remote, getRemoteBinderDeps())
end

function ReplayClient:_bindRemote(remotesFolder: Instance, remoteName: string)
	ReplayRemoteBinder.BindRemote(self, remotesFolder, remoteName, getRemoteBinderDeps())
end

function ReplayClient:_startAnimationStatePublisher(remotesFolder: Instance, constants)
	ReplayRemoteBinder.StartAnimationStatePublisher(self, remotesFolder, constants, getRemoteBinderDeps())
end

function ReplayClient:OnStart()
	debugReplayClient("OnStart")
	self:_disconnectAll()
	self:CancelReplay()
	ReplayAvatarFactory.Start({
		maxCache = MAX_AVATAR_TEMPLATE_CACHE,
		debug = DEBUG_REPLAY_ANIMATION,
	})

	local constants = getReplayConstants()
	if not constants then
		debugReplayClient("Missing ReplayConstants; remotes not bound")
		return
	end

	local function bindRemotes(remotesFolder: Instance)
		if not (remotesFolder and remotesFolder:IsA("Folder")) then
			debugReplayClient("Replay remotes folder unavailable", if remotesFolder then remotesFolder.ClassName else "nil")
			return false
		end

		debugReplayClient("Binding replay remotes folder", remotesFolder:GetFullName())
		for _, remoteName in pairs(constants.REMOTES) do
			if typeof(remoteName) == "string" and remoteName ~= constants.REMOTES.AnimationState then
				self:_bindRemote(remotesFolder, remoteName)
			end
		end

		self:_startAnimationStatePublisher(remotesFolder, constants)
		return true
	end

	local remotesFolder = ReplicatedStorage:FindFirstChild(constants.REMOTES_FOLDER_NAME)
	if bindRemotes(remotesFolder) then
		debugReplayClient("Replay remotes bound")
		return
	end

	warn("[ReplayClient] Waiting for remotes folder: " .. tostring(constants.REMOTES_FOLDER_NAME))
	table.insert(self._connections, ReplicatedStorage.ChildAdded:Connect(function(child)
		if child.Name == constants.REMOTES_FOLDER_NAME then
			if bindRemotes(child) then
				debugReplayClient("Replay remotes bound after folder appeared")
			end
		end
	end))
end

return ReplayClient
