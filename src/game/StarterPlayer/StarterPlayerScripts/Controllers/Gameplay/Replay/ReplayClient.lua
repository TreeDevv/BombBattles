local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local FinisherVFX = require(ReplicatedStorage.Shared.Effects.FinisherVFX)
local HipBombVisual = require(ReplicatedStorage.Shared.Effects.HipBombVisual)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local EventTextPresenter = require(ReplicatedStorage.Shared.Effects.EventTextPresenter)
local ScreenEffects = require(ReplicatedStorage.Shared.UI.ScreenEffects)
local ReplayMapSimulator = require(script.Parent:WaitForChild("ReplayMapSimulator"))
local ReplayAssets = require(script.Parent:WaitForChild("ReplayAssets"))
local ReplayOverlay = require(script.Parent:WaitForChild("ReplayOverlay"))
local ReplayRemoteBinder = require(script.Parent:WaitForChild("ReplayRemoteBinder"))
local ReplayCameraController = require(script.Parent:WaitForChild("ReplayCameraController"))
local ReplayStateBuilder = require(script.Parent:WaitForChild("ReplayStateBuilder"))
local ReplayVisualFactory = require(script.Parent:WaitForChild("ReplayVisualFactory"))
local ReplayAvatarFactory = require(script.Parent:WaitForChild("ReplayAvatarFactory"))
local ReplayCharacterVisualPool = require(script.Parent:WaitForChild("ReplayCharacterVisualPool"))
local ReplayLocalRecorder = require(script.Parent:WaitForChild("ReplayLocalRecorder"))
local ReplayPayloadPrep = require(script.Parent:WaitForChild("ReplayPayloadPrep"))
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
ReplayClient._replayBuildInProgress = false
ReplayClient._pendingKillReplayPayload = nil
ReplayClient._pendingKillReplayKey = nil
ReplayClient._pendingLocalKillReplayKey = nil
ReplayClient._killReplayFadeSerial = 0
ReplayClient._visualsEnabled = nil
ReplayClient._boundRemotes = {}
ReplayClient._explosionVfxBudget = {
	windowStartedAt = 0,
	windowCount = 0,
	heartbeat = 0,
	heartbeatCount = 0,
}
ReplayClient.ReplayStarted = Signal.new()
ReplayClient.ReplayEnded = Signal.new()

local SCENE_NAME = "_LocalReplayScene"
local OVERLAY_NAME = "_KillReplayOverlay"
local REPLAY_RENDER_STEP_NAME = "BombBattlesReplayClient"
local REPLAY_RENDER_PRIORITY = Enum.RenderPriority.Last.Value + 1
local LOCAL_REPLAY_ATTR = "BombBattlesLocalReplay"
local REPLAY_ASSETS_FOLDER_NAME = "ReplayAssets"
local REPLAY_VISUALS_ENABLED_ATTR = "ReplayVisualsEnabled"
local CAMERA_SPECTATING_ATTR = "Camera_Spectating"
local BASE_BOMB_SIZE = Vector3.new(1.4, 1.4, 1.4)
local MAX_REPLAY_DURATION_SECONDS = 12
local MAX_REPLAY_WALL_SECONDS = MAX_REPLAY_DURATION_SECONDS + 4
local MAX_REPLAY_OBJECTS = 720
local MAX_KILL_REPLAY_PLAYER_VISUALS = 6
local MAX_POTG_REPLAY_PLAYER_VISUALS = 10
local MAX_KILL_REPLAY_BOMB_VISUALS = 12
local MAX_POTG_REPLAY_BOMB_VISUALS = 32
local MAX_EVENT_VISUALS = 160
local MAX_EVENTS_PER_STEP = 12
local EXPLOSION_VFX_CLEANUP_SECONDS = 4
local BURST_MARKER_LIFETIME = 0.45
local CAMERA_SMOOTH_RESPONSIVENESS = 8
local CAMERA_DEFAULT_FOV = 72
local ANIMATION_STATE_SEND_RATE = 15
local ANIMATION_STATE_SEND_INTERVAL = 1 / ANIMATION_STATE_SEND_RATE
local MAX_AVATAR_TEMPLATE_CACHE = 32
local MAX_REPLAY_POSE_JOINTS = 32
local MIN_REPLAY_CAMERA_FOV = 20
local MAX_REPLAY_CAMERA_FOV = 120
local POTG_REPLAY_END_FADE_SECONDS = 0.25
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

local function buildLocalAnimationStatePayload()
	return ReplayLocalRecorder.BuildAnimationStatePayload()
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

	if visual.fallback and rootPart then
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

local function makeNameplate(parent: Instance, userId: number, teamName: any, color: Color3, displayName: any): BillboardGui
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
	label.Text = if typeof(displayName) == "string" and displayName ~= ""
		then displayName
		elseif getPlayerDisplayName
		then getPlayerDisplayName(userId)
		else tostring(userId)
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

local function getMotorJointKey(motor: Motor6D): string
	local part0Name = if motor.Part0 then motor.Part0.Name else ""
	local part1Name = if motor.Part1 then motor.Part1.Name else ""
	return part0Name .. ">" .. motor.Name .. ">" .. part1Name
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

local function makeAvatarCharacterVisual(
	parent: Instance,
	userId: number,
	teamName: any,
	hasPoseSnapshots: boolean?,
	bombSkinId: any,
	displayName: any
)
	if not isFiniteNumber(userId) then
		RuntimeProfiler.Count("Client/Replay/AvatarFactory/SkippedNonPositiveUserIds")
		return nil
	end

	local pooledVisual = ReplayCharacterVisualPool.Take("avatar", parent, userId, teamName, bombSkinId, displayName)
	if pooledVisual then
		return pooledVisual
	end

	local model = ReplayAvatarFactory.CloneCachedTemplate(userId)
	if not model then
		if userId <= 0 then
			RuntimeProfiler.Count("Client/Replay/AvatarFactory/MissingCachedNPCAvatars")
		else
			RuntimeProfiler.Count("Client/Replay/AvatarFactory/MissingCachedPlayerAvatars")
		end
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

	local nameplate = makeNameplate(rootPart, userId, teamName, color, displayName)
	model.Parent = parent
	local hipBomb = HipBombVisual.new(model, nil, {
		mode = "animated",
		skinId = bombSkinId,
	})

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
		hipBomb = hipBomb,
		lastCFrame = nil,
		replayPoolKey = ReplayCharacterVisualPool.BuildKey("avatar", userId, teamName, bombSkinId, displayName),
	}
end

local function makeCharacterVisual(
	parent: Instance,
	userId: number,
	teamName: any,
	hasPoseSnapshots: boolean?,
	bombSkinId: any,
	displayName: any
)
	local avatarVisual = makeAvatarCharacterVisual(parent, userId, teamName, hasPoseSnapshots, bombSkinId, displayName)
	if avatarVisual then
		return avatarVisual
	end
	RuntimeProfiler.Count("Client/Replay/AvatarFactory/SkippedCharacterFallbacks")
	return nil
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

local function makeBombVisual(parent: Instance, bombId: string, bombType: any, bombSkinId: any)
	local instance, rootPart, resolvedSkinId = BombVisualUtil.CreateBombVisual(bombSkinId, "ReplayBomb_" .. bombId, {
		anchored = true,
		canCollide = false,
		canQuery = false,
		massless = true,
		effectState = {
			vfx = true,
			fuseSpark = true,
			trail = true,
		},
		visualScale = BombConfig.ProjectileVisualScale,
	})
	local records, preparedRootPart = prepareReplayClone(instance)
	rootPart = BombVisualUtil.GetRootPart(instance) or preparedRootPart or rootPart
	if rootPart and #records > 0 then
		instance.Parent = parent
		BombVisualUtil.SetEffectState(instance, {
			vfx = true,
			fuseSpark = true,
			trail = true,
		})
		local visual = {
			instance = instance,
			rootPart = rootPart,
			parts = records,
			fallback = false,
			bombType = bombType,
			bombSkinId = resolvedSkinId,
			lastCFrame = nil,
		}
		attachReplayBombPulse(visual, instance, rootPart)
		return visual
	end
	instance:Destroy()

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

local function updateReplayHipBomb(visual, cframe: CFrame, alive: boolean?, snapshot)
	local hipBomb = visual and visual.hipBomb
	if not hipBomb then
		return
	end

	local animationState = if typeof(snapshot) == "table" and typeof(snapshot.animationState) == "table"
		then snapshot.animationState
		else {}
	local visible = alive ~= false and animationState.bombCooking ~= true
	hipBomb:SetVisible(visible)
	if not visible then
		return
	end

	local ok = hipBomb:Step(1 / 60, {
		cframe = cframe,
		linearVelocity = if typeof(animationState.linearVelocity) == "Vector3" then animationState.linearVelocity else Vector3.zero,
		grounded = if typeof(animationState.grounded) == "boolean" then animationState.grounded else true,
		sprinting = animationState.sprinting == true,
		sliding = animationState.sliding == true,
		landingRecoveryAlpha = animationState.landingRecoveryAlpha,
	})
	if not ok then
		hipBomb:Destroy()
		visual.hipBomb = nil
	end
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
		updateReplayHipBomb(visual, resolvedCFrame, alive, snapshot)
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
	updateReplayHipBomb(visual, resolvedCFrame, alive, snapshot)
end

local function hideCharacter(visual)
	for _, entry in ipairs(visual.parts) do
		setPartVisible(entry.part, false)
	end
	if visual.hipBomb then
		visual.hipBomb:SetVisible(false)
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

local function getExplosionTemplate(bombSkinId: any): Instance?
	local template = BombVisualUtil.GetExplosionTemplate(bombSkinId)
	return template
end

local function playReplayExplosionVfx(parent: Instance, bombSkinId: any, position: Vector3): (boolean, boolean)
	local budget = ReplayClient._explosionVfxBudget
	local now = os.clock()
	if now - budget.windowStartedAt > 0.35 then
		budget.windowStartedAt = now
		budget.windowCount = 0
	end

	local heartbeat = math.floor(now * 60)
	if heartbeat ~= budget.heartbeat then
		budget.heartbeat = heartbeat
		budget.heartbeatCount = 0
	end

	local soundLightOnly = false
	if budget.windowCount >= 3 then
		RuntimeProfiler.Count("Client/Replay/ExplosionVfxDowngraded/WindowBudget")
		soundLightOnly = true
	elseif budget.heartbeatCount >= 1 then
		RuntimeProfiler.Count("Client/Replay/ExplosionVfxDowngraded/HeartbeatBudget")
		soundLightOnly = true
	else
		budget.windowCount += 1
		budget.heartbeatCount += 1
	end

	if not soundLightOnly then
		local template = getExplosionTemplate(bombSkinId)
		local estimatedObjects = if template then #template:GetDescendants() + 1 else 1
		if not reserveReplayObjects(math.min(estimatedObjects, MAX_REPLAY_OBJECTS)) then
			RuntimeProfiler.Count("Client/Replay/ExplosionVfxDowngraded/ObjectBudget")
			soundLightOnly = true
		end
	end
	local emitModule = getReplayEmitModule()
	if soundLightOnly then
		emitModule = nil
	elseif emitModule and not ensureReplayEmitModuleInitialized(emitModule) then
		emitModule = nil
	end

	local result = BombVisualUtil.PlayExplosionEffect({
		parent = parent,
		position = position,
		skinId = bombSkinId,
		emitModule = emitModule,
		name = "ReplayBombExplosionVFX",
		cleanupSeconds = EXPLOSION_VFX_CLEANUP_SECONDS,
		emitCountScale = 0.55,
		soundLightOnly = soundLightOnly,
		warnPrefix = "[ReplayClient]",
	})
	return result.emitted == true or soundLightOnly, result.playedSound == true
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

local preprocessFrames = ReplayPayloadPrep.PreprocessFrames
local getEventTimestamp = ReplayPayloadPrep.GetEventTimestamp
local function preprocessEvents(rawEvents, startTime: number, endTime: number)
	return ReplayPayloadPrep.PreprocessEvents(rawEvents, startTime, endTime, MAX_EVENT_VISUALS)
end
local findKillTimestamp = ReplayPayloadPrep.FindKillTimestamp
local collectExplosionPositions = ReplayPayloadPrep.CollectExplosionPositions
local collectReplayMeta = ReplayPayloadPrep.CollectReplayMeta
local collectPlayerMeta = ReplayPayloadPrep.CollectPlayerMeta
local preloadAvatarTemplates = ReplayPayloadPrep.PrewarmAvatarTemplates
local collectBombMeta = ReplayPayloadPrep.CollectBombMeta
local findFramePair = ReplayPayloadPrep.FindFramePair
local interpolateSnapshot = ReplayPayloadPrep.InterpolateSnapshot

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
		ReplayMapSimulator.ScheduleDestroyScene(existing, "ExistingScene")
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
	local key = getUserIdKey(resolvedUserId)
	local activeReplay = ReplayClient._activeReplay
	if key and activeReplay and typeof(activeReplay.frames) == "table" then
		for _, frame in ipairs(activeReplay.frames) do
			local snapshot = frame.players and frame.players[key]
			if typeof(snapshot) == "table" then
				if typeof(snapshot.displayName) == "string" and snapshot.displayName ~= "" then
					return snapshot.displayName
				end
				if typeof(snapshot.name) == "string" and snapshot.name ~= "" then
					return snapshot.name
				end
			end
		end
	end

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
		wasSpectating = LocalPlayer:GetAttribute(CAMERA_SPECTATING_ATTR),
	}
end

local function getFallbackCameraSubject(): Instance?
	local character = LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function restoreCamera(state, forceCharacterCamera: boolean?)
	local cameraState = state and state.cameraState
	local wasSpectating = if cameraState then cameraState.wasSpectating else state and state.previousCameraSpectating
	if state then
		LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, wasSpectating == true)
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	if not cameraState then
		return
	end

	local subject = if forceCharacterCamera == true then getFallbackCameraSubject() else cameraState.cameraSubject
	if not (subject and subject.Parent) then
		subject = if forceCharacterCamera == true then cameraState.cameraSubject else getFallbackCameraSubject()
	end

	pcall(function()
		if subject then
			camera.CameraSubject = subject
		end
		camera.CameraType = if forceCharacterCamera == true then Enum.CameraType.Custom else cameraState.cameraType or Enum.CameraType.Custom
		if forceCharacterCamera ~= true then
			camera.CFrame = cameraState.cframe or camera.CFrame
			camera.Focus = cameraState.focus or camera.Focus
		end
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
	local emittedExplosionVfx, playedAssetSound = playReplayExplosionVfx(parent, event.bombSkinId, position)
	if not emittedExplosionVfx then
		createReplayTemplateEffect(parent, getExplosionTemplate(event.bombSkinId), position, "ReplayExplosionTemplate", 1.1, bombColor)
	end
	createRingMarker(parent, position, outerRadius, Color3.fromRGB(255, 150, 64), 0.72)
	createPulseSphere(parent, position, terrainRadius, Color3.fromRGB(255, 96, 54), 0.55)
	createPulseSphere(parent, position, innerRadius, Color3.fromRGB(255, 218, 83), 0.32)
	playReplayEventText(parent, event, position)
	if not playedAssetSound then
		playOptionalEventSound("Explosion", anchor)
	end
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

	if typeof(event.finisherId) == "string" and event.finisherId ~= "" then
		FinisherVFX.PlayAt(event.finisherId, position, {
			parent = parent,
		})
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

function ReplayClient.BuildReplayEventQueues(events)
	if typeof(events) ~= "table" then
		return {
			[EVENT_PHASE_PRE_IMPACT] = {},
			[EVENT_PHASE_IMPACT] = {},
			[EVENT_PHASE_POST_IMPACT] = {},
		}, 0
	end

	local queues = {
		[EVENT_PHASE_PRE_IMPACT] = {},
		[EVENT_PHASE_IMPACT] = {},
		[EVENT_PHASE_POST_IMPACT] = {},
	}
	local total = 0
	for _, event in ipairs(events) do
		if typeof(event) == "table" then
			local phase = getReplayEventPhase(event)
			table.insert(queues[phase], event)
			total += 1
		end
	end
	return queues, total
end

local function hasPendingReplayEvents(state): boolean
	if typeof(state) == "table" and isFiniteNumber(state.pendingEventCount) then
		return state.pendingEventCount > 0
	end
	return false
end

local function fireDueReplayEvents(state, replayTime: number, phase: string)
	local queues = state.eventQueues
	local events = if typeof(queues) == "table" then queues[phase] else state.events
	if typeof(events) ~= "table" then
		return 0
	end

	if typeof(state.nextEventIndicesByPhase) ~= "table" then
		state.nextEventIndicesByPhase = {}
	end
	local nextEventIndicesByPhase = state.nextEventIndicesByPhase
	local index = if isFiniteNumber(nextEventIndicesByPhase[phase])
		then math.max(math.floor(nextEventIndicesByPhase[phase]), 1)
		else 1
	local fired = 0
	while index <= #events do
		if fired >= MAX_EVENTS_PER_STEP then
			break
		end

		local event = events[index]
		local timestamp = getEventTimestamp(event)
		if timestamp and timestamp > replayTime then
			break
		end

		index += 1
		if isFiniteNumber(state.pendingEventCount) then
			state.pendingEventCount = math.max(state.pendingEventCount - 1, 0)
		end
		fired += 1
		playReplayEvent(event)
	end
	nextEventIndicesByPhase[phase] = index
	return fired
end

local function getFallbackReplayCameraVisual(state)
	for _, userId in ipairs({
		state.cameraUserId,
		state.killerUserId,
		state.playerUserId,
		state.victimUserId,
	}) do
		local key = getUserIdKey(userId)
		local visual = key and state.playerVisuals[key]
		if visual and getVisualPosition(visual) then
			return visual
		end
	end

	for _, visual in pairs(state.playerVisuals) do
		if getVisualPosition(visual) then
			return visual
		end
	end
	return nil
end

local function updateReplayCamera(state)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable

	local visual = getFallbackReplayCameraVisual(state)
	local position = getVisualPosition(visual)
	if not position then
		local lookAt = Vector3.new(0, 2, 0)
		camera.CFrame = CFrame.lookAt(Vector3.new(0, 6, 12), lookAt)
		camera.Focus = CFrame.new(lookAt)
		camera.FieldOfView = CAMERA_DEFAULT_FOV
		return
	end

	local visualCFrame = getVisualCFrame(visual)
	local direction = if visualCFrame then Vector3.new(visualCFrame.LookVector.X, 0, visualCFrame.LookVector.Z) else Vector3.new(0, 0, 1)
	if direction.Magnitude <= 0.05 then
		direction = Vector3.new(0, 0, 1)
	else
		direction = direction.Unit
	end

	local side = Vector3.new(-direction.Z, 0, direction.X)
	local lookAt = position + Vector3.new(0, 2.1, 0)
	local cameraPosition = lookAt - direction * 11 + side * 1.35 + Vector3.new(0, 4.5, 0)
	camera.CFrame = CFrame.lookAt(cameraPosition, lookAt)
	camera.Focus = CFrame.new(lookAt)
	camera.FieldOfView = CAMERA_DEFAULT_FOV
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

function ReplayClient.GetReplayPayloadType(payload): string?
	return if typeof(payload) == "table" and typeof(payload.type) == "string" then payload.type else nil
end

function ReplayClient.GetReplayPayloadKey(payload): string?
	if typeof(payload) ~= "table" then
		return nil
	end

	local replayType = ReplayClient.GetReplayPayloadType(payload)
	if typeof(replayType) ~= "string" or replayType == "" then
		return nil
	end

	return table.concat({
		replayType,
		tostring(payload.startTime),
		tostring(payload.endTime),
		tostring(payload.victimUserId),
	}, "|")
end

function ReplayClient.IsSameActiveReplay(activeReplay, payload): boolean
	if not activeReplay or typeof(payload) ~= "table" then
		return false
	end

	local replayType = ReplayClient.GetReplayPayloadType(payload)
	if
		activeReplay.replayType ~= replayType
		or activeReplay.startTime ~= payload.startTime
		or activeReplay.endTime ~= payload.endTime
	then
		return false
	end

	if replayType == "POTGReplay" then
		return activeReplay.playerUserId == payload.playerUserId
	end

	return activeReplay.victimUserId == payload.victimUserId
end

function ReplayClient:HasPendingLocalKillReplay(): boolean
	return self._pendingLocalKillReplayKey ~= nil
end

function ReplayClient.BuildReplaySignalPayloadFromState(state, reason: string)
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

function ReplayClient.BuildReplaySignalPayloadFromPayload(payload, reason: string)
	return {
		type = ReplayClient.GetReplayPayloadType(payload),
		reason = reason,
		playerUserId = if typeof(payload) == "table" then payload.playerUserId else nil,
		killerUserId = if typeof(payload) == "table" then payload.killerUserId else nil,
		victimUserId = if typeof(payload) == "table" then payload.victimUserId else nil,
		startTime = if typeof(payload) == "table" then payload.startTime else nil,
		endTime = if typeof(payload) == "table" then payload.endTime else nil,
	}
end

function ReplayClient.GetPayloadFrameCount(payload): number
	return if typeof(payload) == "table" and typeof(payload.frames) == "table" then #payload.frames else 0
end

function ReplayClient.WarnReplayBuildSkipped(reason: string, payload)
	warn(
		("[ReplayClient] Replay skipped reason=%s type=%s frames=%d start=%s end=%s"):format(
			reason,
			tostring(ReplayClient.GetReplayPayloadType(payload)),
			ReplayClient.GetPayloadFrameCount(payload),
			tostring(if typeof(payload) == "table" then payload.startTime else nil),
			tostring(if typeof(payload) == "table" then payload.endTime else nil)
		)
	)
end

function ReplayClient.DebugReplayClient(message: string, ...)
	if DEBUG_REPLAY_CLIENT then
		warn("[ReplayClient] " .. message, ...)
	end
end

local function getPOTGCutsceneController()
	local controllersFolder = script.Parent.Parent
	local module = controllersFolder and controllersFolder:FindFirstChild("POTGCutsceneController")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end

	local ok, controller = pcall(require, module)
	return if ok and typeof(controller) == "table" then controller else nil
end

function ReplayClient:_getRemoteBinderDeps()
	return {
		debugReplayClient = ReplayClient.DebugReplayClient,
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
	self._killReplayFadeSerial += 1
	self._pendingLocalKillReplayKey = nil
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
		restoreCamera(state, state.replayType == "POTGReplay")
	end)

	for _, visual in pairs(state.playerVisuals or {}) do
		if ReplayCharacterVisualPool.Release(visual) then
			continue
		end
		local driver = visual.animationDriver
		if driver then
			pcall(function()
				driver:Destroy()
			end)
		end
		local hipBomb = visual.hipBomb
		if hipBomb then
			pcall(function()
				hipBomb:Destroy()
			end)
			visual.hipBomb = nil
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
			ReplayMapSimulator.ScheduleDestroyScene(state.scene, tostring(reason or "ReplayEnded"))
		end)
	end

	ReplayClient.DebugReplayClient(
		"Replay ended",
		state.replayType,
		"reason",
		reason or "Canceled",
		"playhead",
		state.playhead,
		"end",
		state.endTime
	)
	self.ReplayEnded:Fire(ReplayClient.BuildReplaySignalPayloadFromState(state, reason or "Canceled"))
end

function ReplayClient:_getStateBuilderDeps()
	return {
		ReplayMapSimulator = ReplayMapSimulator,
		ReplayCameraController = ReplayCameraController,
		areReplayVisualsEnabled = areReplayVisualsEnabled,
		warnReplayBuildSkipped = ReplayClient.WarnReplayBuildSkipped,
		isFiniteNumber = isFiniteNumber,
		maxReplayDurationSeconds = MAX_REPLAY_DURATION_SECONDS,
		maxReplayObjects = MAX_REPLAY_OBJECTS,
		maxKillReplayPlayerVisuals = MAX_KILL_REPLAY_PLAYER_VISUALS,
		maxPOTGReplayPlayerVisuals = MAX_POTG_REPLAY_PLAYER_VISUALS,
		maxKillReplayBombVisuals = MAX_KILL_REPLAY_BOMB_VISUALS,
		maxPOTGReplayBombVisuals = MAX_POTG_REPLAY_BOMB_VISUALS,
		createScene = createScene,
		takePreparedSceneContext = function(payload)
			return ReplayMapSimulator.TakePreparedScene(payload)
		end,
		preprocessFrames = preprocessFrames,
		preprocessEvents = preprocessEvents,
		collectExplosionPositions = collectExplosionPositions,
		getBombKey = getBombKey,
		findKillTimestamp = findKillTimestamp,
		findImpactPosition = findImpactPosition,
		buildReplayEventQueues = ReplayClient.BuildReplayEventQueues,
		hasRecordedCameraForUser = hasRecordedCameraForUser,
		createOverlay = createOverlay,
		captureCameraState = captureCameraState,
		collectReplayMeta = collectReplayMeta,
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
		},
	}
end

function ReplayClient:_buildReplayState(payload)
	local token = RuntimeProfiler.Begin("Client/Replay/Death/BuildReplayState")
	local state = ReplayStateBuilder.Build(self, payload, self:_getStateBuilderDeps())
	RuntimeProfiler.End("Client/Replay/Death/BuildReplayState", token)
	return state
end

function ReplayClient:_queueKillReplay(payload): boolean
	if ReplayClient.GetReplayPayloadType(payload) ~= "KillReplay" then
		return false
	end
	if ReplayClient.IsSameActiveReplay(self._activeReplay, payload) then
		RuntimeProfiler.Count("Client/Replay/DroppedQueuedDuplicate")
		return true
	end

	local key = ReplayClient.GetReplayPayloadKey(payload)
	if key and key == self._pendingKillReplayKey then
		RuntimeProfiler.Count("Client/Replay/DroppedQueuedDuplicate")
		return true
	end

	self._pendingKillReplayPayload = payload
	self._pendingKillReplayKey = key
	RuntimeProfiler.Count("Client/Replay/QueuedDuringBuild")
	ReplayClient.DebugReplayClient("Queued KillReplay during build", tostring(key))
	return true
end

function ReplayClient:_flushQueuedKillReplay()
	if self._replayBuildInProgress then
		return
	end

	local payload = self._pendingKillReplayPayload
	if not payload then
		return
	end
	self._pendingKillReplayPayload = nil
	self._pendingKillReplayKey = nil

	if ReplayClient.IsSameActiveReplay(self._activeReplay, payload) then
		RuntimeProfiler.Count("Client/Replay/DroppedQueuedDuplicate")
		return
	end

	RuntimeProfiler.Count("Client/Replay/PlayedQueuedReplay")
	self:PlayKillReplay(payload)
end

function ReplayClient:_beginPOTGReplayEndFade(state, reason: string)
	if state.potgEndFadeStarted == true or state.ending == true then
		return
	end
	state.potgEndFadeStarted = true

	local fadeStarted = ScreenEffects.FadeToBlack(POTG_REPLAY_END_FADE_SECONDS)
	local delaySeconds = if fadeStarted then POTG_REPLAY_END_FADE_SECONDS else 0
	task.delay(delaySeconds, function()
		if self._activeReplay ~= state then
			return
		end

		ScreenEffects.HoldBlack()
		state.ending = true
		self:CancelReplay(reason)
	end)
end

function ReplayClient:_stepReplay(state, deltaTime: number?)
	local stepToken = RuntimeProfiler.Begin("Client/Replay/Step")
	if state.ending == true then
		RuntimeProfiler.End("Client/Replay/Step", stepToken)
		return
	end

	local resolvedDeltaTime = if isFiniteNumber(deltaTime) and deltaTime >= 0 then math.min(deltaTime, 0.1) else 1 / 60
	state.wallClockElapsed = (state.wallClockElapsed or 0) + resolvedDeltaTime
	if state.wallClockElapsed > MAX_REPLAY_WALL_SECONDS then
		self:CancelReplay("TimedOut")
		RuntimeProfiler.End("Client/Replay/Step", stepToken)
		return
	end

	state.playhead = math.min(state.playhead + resolvedDeltaTime, state.endTime)
	local replayTime = state.playhead
	local left, right, nextIndex, alpha = findFramePair(state.frames, replayTime, state.frameIndex)
	state.frameIndex = nextIndex
	if not left then
		RuntimeProfiler.End("Client/Replay/Step", stepToken)
		return
	end

	local visualsToken = RuntimeProfiler.Begin("Client/Replay/UpdateVisuals")
	updateVisuals(state, left, right, alpha, replayTime)
	RuntimeProfiler.End("Client/Replay/UpdateVisuals", visualsToken)
	local preEventToken = RuntimeProfiler.Begin("Client/Replay/FireEvents/PreImpact")
	fireDueReplayEvents(state, replayTime, EVENT_PHASE_PRE_IMPACT)
	RuntimeProfiler.End("Client/Replay/FireEvents/PreImpact", preEventToken)
	local impactEventToken = RuntimeProfiler.Begin("Client/Replay/FireEvents/Impact")
	local impactEventsFired = fireDueReplayEvents(state, replayTime, EVENT_PHASE_IMPACT)
	RuntimeProfiler.End("Client/Replay/FireEvents/Impact", impactEventToken)
	local destructionToken = RuntimeProfiler.Begin("Client/Replay/ApplyDestructionEvents")
	state.nextDestructionIndex =
		ReplayMapSimulator.ApplyEventsUpTo(state.mapContext, state.destructionEvents, replayTime, state.nextDestructionIndex, {
			spawnDebris = true,
			maxEvents = ReplayMapSimulator.GetMaxDestructionEventsPerStep(),
		})
	RuntimeProfiler.End("Client/Replay/ApplyDestructionEvents", destructionToken)
	local postEventToken = RuntimeProfiler.Begin("Client/Replay/FireEvents/PostImpact")
	fireDueReplayEvents(state, replayTime, EVENT_PHASE_POST_IMPACT)
	RuntimeProfiler.End("Client/Replay/FireEvents/PostImpact", postEventToken)
	local cameraToken = RuntimeProfiler.Begin("Client/Replay/Camera")
	local recordedCameraUpdated = updateRecordedReplayCamera(state, left, right, alpha, replayTime)
	if not recordedCameraUpdated and state.cameraController then
		state.cameraController:Step(resolvedDeltaTime, replayTime)
	elseif not recordedCameraUpdated then
		updateReplayCamera(state)
	end
	RuntimeProfiler.End("Client/Replay/Camera", cameraToken)

	local destructionPending = typeof(state.destructionEvents) == "table"
		and state.nextDestructionIndex <= #state.destructionEvents
	if
		state.replayType == "POTGReplay"
		and state.potgEndFadeStarted ~= true
		and not destructionPending
		and not hasPendingReplayEvents(state)
		and state.endTime - state.playhead <= POTG_REPLAY_END_FADE_SECONDS
	then
		self:_beginPOTGReplayEndFade(state, "Completed")
	end
	if state.playhead >= state.endTime and not destructionPending and not hasPendingReplayEvents(state) then
		if state.replayType == "POTGReplay" then
			self:_beginPOTGReplayEndFade(state, "Completed")
		else
			self:CancelReplay("Completed")
		end
	end
	RuntimeProfiler.End("Client/Replay/Step", stepToken)
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
		eventCursors = state.nextEventIndicesByPhase,
		destructionEvents = if typeof(state.destructionEvents) == "table" then #state.destructionEvents else 0,
		map = ReplayMapSimulator.GetDebugInfo(state.mapContext),
	}
end

function ReplayClient:PlayReplay(payload): boolean
	local playToken = RuntimeProfiler.Begin("Client/Replay/PlayReplay")
	local replayType = ReplayClient.GetReplayPayloadType(payload)
	ReplayClient.DebugReplayClient("PlayReplay called", replayType, "frames", ReplayClient.GetPayloadFrameCount(payload))
	RuntimeProfiler.Count("Client/Replay/ReceivedFrames", if typeof(payload) == "table" and typeof(payload.frames) == "table" then #payload.frames else 0)
	RuntimeProfiler.Count("Client/Replay/ReceivedEvents", if typeof(payload) == "table" and typeof(payload.events) == "table" then #payload.events else 0)
	RuntimeProfiler.Count("Client/Replay/ReceivedDestructionEvents", if typeof(payload) == "table" and typeof(payload.destructionEvents) == "table" then #payload.destructionEvents else 0)

	if self._replayBuildInProgress then
		if replayType == "KillReplay" and self:_queueKillReplay(payload) then
			RuntimeProfiler.End("Client/Replay/PlayReplay", playToken)
			return false
		end
		RuntimeProfiler.Count("Client/Replay/SkippedBuildInProgress")
		RuntimeProfiler.End("Client/Replay/PlayReplay", playToken)
		return false
	end

	if (replayType == "KillReplay" or replayType == "POTGReplay") and ReplayClient.IsSameActiveReplay(self._activeReplay, payload) then
		RuntimeProfiler.Count("Client/Replay/SkippedDuplicateReplay")
		RuntimeProfiler.End("Client/Replay/PlayReplay", playToken)
		return false
	end

	local cancelToken = RuntimeProfiler.Begin("Client/Replay/CancelExisting")
	self:CancelReplay("Interrupted")
	RuntimeProfiler.End("Client/Replay/CancelExisting", cancelToken)

	local started = false

	self._replayBuildInProgress = true
	local ok, err = pcall(function()
		local buildToken = RuntimeProfiler.Begin("Client/Replay/PlayReplay/BuildState")
		local state = self:_buildReplayState(payload)
		RuntimeProfiler.End("Client/Replay/PlayReplay/BuildState", buildToken)
		if not state then
			return
		end

		self._explosionVfxBudget.windowStartedAt = 0
		self._explosionVfxBudget.windowCount = 0
		self._explosionVfxBudget.heartbeat = 0
		self._explosionVfxBudget.heartbeatCount = 0

		started = true
		state.previousCameraSpectating = if state.cameraState then state.cameraState.wasSpectating else LocalPlayer:GetAttribute(CAMERA_SPECTATING_ATTR)
		LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, true)
		ReplayClient.DebugReplayClient(
			"Replay started",
			state.replayType,
			"start",
			state.startTime,
			"end",
			state.endTime,
			"frames",
			#state.frames,
			"playerVisuals",
			countTableEntries(state.playerVisuals),
			"bombVisuals",
			countTableEntries(state.bombVisuals),
			"cameraUserId",
			state.cameraUserId,
			"hasRecordedCamera",
			state.hasRecordedCamera,
			"overlay",
			state.overlay ~= nil
		)
		self.ReplayStarted:Fire(ReplayClient.BuildReplaySignalPayloadFromState(state, "Started"))
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

		local initialStepToken = RuntimeProfiler.Begin("Client/Replay/InitialStep")
		self:_stepReplay(state, 0)
		RuntimeProfiler.End("Client/Replay/InitialStep", initialStepToken)
	end)
	self._replayBuildInProgress = false
	task.defer(function()
		self:_flushQueuedKillReplay()
	end)

	if not ok then
		warn("[ReplayClient] Failed to play replay: " .. tostring(err))
		self:CancelReplay("Error")
		if replayType then
			self.ReplayEnded:Fire(ReplayClient.BuildReplaySignalPayloadFromPayload(payload, "Failed"))
		end
	elseif not started and replayType then
		ReplayClient.DebugReplayClient("Replay did not start", replayType)
		self.ReplayEnded:Fire(ReplayClient.BuildReplaySignalPayloadFromPayload(payload, "Skipped"))
	end

	RuntimeProfiler.End("Client/Replay/PlayReplay", playToken)
	return started
end

function ReplayClient:PlayKillReplay(payload)
	local token = RuntimeProfiler.Begin("Client/Replay/Death/PlayKillReplay")
	local started = self:PlayReplay(payload)
	RuntimeProfiler.End("Client/Replay/Death/PlayKillReplay", token)
	return started
end

function ReplayClient:ReceiveKillReplay(payload)
	local victimUserId = if typeof(payload) == "table" then payload.victimUserId else nil
	local isLocalKillReplay = victimUserId == nil
		or (typeof(victimUserId) == "number" and math.floor(victimUserId) == LocalPlayer.UserId)
	if not isLocalKillReplay then
		task.defer(function()
			self:PlayKillReplay(payload)
		end)
		return true
	end

	self._killReplayFadeSerial += 1
	local serial = self._killReplayFadeSerial
	self._pendingLocalKillReplayKey = ReplayClient.GetReplayPayloadKey(payload) or tostring(serial)
	task.defer(function()
		if not ScreenEffects.IsBlack(0.01) then
			if ScreenEffects.FadeToBlack(0.25) then
				task.wait(0.25)
				RunService.RenderStepped:Wait()
			end
		end
		if serial ~= self._killReplayFadeSerial then
			return
		end
		if LocalPlayer:GetAttribute("RoundAlive") == true then
			self._pendingLocalKillReplayKey = nil
			ScreenEffects.FadeFromBlack(0.25)
			return
		end

		ScreenEffects.HoldBlack()
		self._pendingLocalKillReplayKey = nil
		self:PlayKillReplay(payload)
	end)
	return true
end

function ReplayClient:PlayPOTGReplay(payload)
	local cutsceneController = getPOTGCutsceneController()
	if
		cutsceneController
		and type(cutsceneController.QueueAfterRoundIntro) == "function"
		and cutsceneController:QueueAfterRoundIntro(function()
			self:PlayPOTGReplay(payload)
		end)
	then
		return false
	end

	if not ScreenEffects.IsBlack(0.01) and ScreenEffects.FadeToBlack(0.2) then
		task.wait(0.2)
		RunService.RenderStepped:Wait()
	end

	ScreenEffects.HoldBlack()
	local started = self:PlayReplay(payload)
	if started then
		ScreenEffects.FadeFromBlack(0.3)
	else
		ScreenEffects.FadeFromBlack(0.2)
	end
	return started
end

function ReplayClient:RequestKillReplay(reason: string?): boolean
	return ReplayRemoteBinder.RequestKillReplay(self, reason, self:_getRemoteBinderDeps())
end

function ReplayClient:_bindRemoteInstance(remoteName: string, remote: Instance): boolean
	return ReplayRemoteBinder.BindRemoteInstance(self, remoteName, remote, self:_getRemoteBinderDeps())
end

function ReplayClient:_bindRemote(remotesFolder: Instance, remoteName: string)
	ReplayRemoteBinder.BindRemote(self, remotesFolder, remoteName, self:_getRemoteBinderDeps())
end

function ReplayClient:_startAnimationStatePublisher(remotesFolder: Instance, constants)
	ReplayRemoteBinder.StartAnimationStatePublisher(self, remotesFolder, constants, self:_getRemoteBinderDeps())
end

function ReplayClient:OnStart()
	ReplayClient.DebugReplayClient("OnStart")
	self:_disconnectAll()
	self:CancelReplay()
	ReplayAvatarFactory.Start({
		maxCache = MAX_AVATAR_TEMPLATE_CACHE,
		debug = DEBUG_REPLAY_ANIMATION,
	})
	ReplayAssets.PrewarmContent(REPLAY_ASSETS_FOLDER_NAME)

	local constants = getReplayConstants()
	if not constants then
		ReplayClient.DebugReplayClient("Missing ReplayConstants; remotes not bound")
		return
	end

	local function bindRemotes(remotesFolder: Instance)
		if not (remotesFolder and remotesFolder:IsA("Folder")) then
			ReplayClient.DebugReplayClient("Replay remotes folder unavailable", if remotesFolder then remotesFolder.ClassName else "nil")
			return false
		end

		ReplayClient.DebugReplayClient("Binding replay remotes folder", remotesFolder:GetFullName())
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
		ReplayClient.DebugReplayClient("Replay remotes bound")
		return
	end

	warn("[ReplayClient] Waiting for remotes folder: " .. tostring(constants.REMOTES_FOLDER_NAME))
	table.insert(self._connections, ReplicatedStorage.ChildAdded:Connect(function(child)
		if child.Name == constants.REMOTES_FOLDER_NAME then
			if bindRemotes(child) then
				ReplayClient.DebugReplayClient("Replay remotes bound after folder appeared")
			end
		end
	end))
end

return ReplayClient
