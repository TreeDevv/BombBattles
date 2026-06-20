local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local HipBombVisual = require(ReplicatedStorage.Shared.Effects.HipBombVisual)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local VoxelDebris = require(ReplicatedStorage.Packages.VoxManager.Voxelizer.Debris)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local RoundController = require(script.Parent:WaitForChild("RoundController"))
local CameraController = require(script.Parent:WaitForChild("CameraController"))
local BombTrajectoryClient = require(script.Parent:WaitForChild("BombTrajectoryClient"))
local REMOTES_FOLDER_NAME = "Remotes"
local BEGIN_REMOTE_NAME = "BeginBombCook"
local RELEASE_REMOTE_NAME = "ReleaseBombCook"
local EFFECT_REMOTE_NAME = "BombEffect"
local BOMB_ACTION_NAME = "BombBattlesPrimaryBomb"
local PREVIEW_FOLDER_NAME = "BombPreview"
local TRAJECTORY_VFX_PATH = { "Assets", "VFX", "Trajectory", "TrajectoryLine" }
local TRAJECTORY_PREVIEW_NAME = "BombTrajectoryPreview"
local PROJECTILE_VISUAL_FOLDER_NAME = "BombProjectileVisuals"
local EXPLOSION_VFX_FOLDER_NAME = "BombExplosionVFX"
local HELD_BOMB_VISUAL_NAME = "BombHeldVisual"
local HELD_BOMB_GRIP_ATTACHMENT_NAME = "BombGripAttachment"
local HELD_BOMB_CONSTRAINT_NAME = "BombGripConstraint"
local HELD_BOMB_WELD_NAME = "BombHeldWeld"
local ABILITY_VISUAL_OVERLAY_NAME = "AbilityVisualOverlay"
local HIP_BOMB_VISUAL_NAME = (BombConfig.HipCarry and BombConfig.HipCarry.VisualName) or "BombHipVisual"
local HIP_BOMB_MOTOR_NAME = (BombConfig.HipCarry and BombConfig.HipCarry.MotorName) or "BombHipMotor"
local HELD_BOMB_ATTACH_RETRY_SECONDS = 0.1
local HELD_BOMB_ATTACH_MAX_ATTEMPTS = 5
local ANIMATOR_LOOKUP_TIMEOUT = 5
local ANIMATOR_RETRY_SECONDS = 0.25
local RENDER_STEP_NAME = "BombBattlesBombPreview"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2
local ROUND_ALIVE_ATTR = "RoundAlive"
local EXPLOSION_VFX_CLEANUP_SECONDS = 8
local AIR_CONTROL_FORCE_AIRBORNE_UNTIL_ATTR = "AirControl_ForceAirborneUntil"
local AIR_CONTROL_LAUNCH_SOURCE_ATTR = "AirControl_LaunchSource"
local AIR_CONTROL_LAUNCH_SERIAL_ATTR = "AirControl_LaunchSerial"
local AIR_CONTROL_LAUNCHED_AT_ATTR = "AirControl_LaunchedAt"
local AIR_CONTROL_EXPLOSIVE_MIN_AIR_TIME = 0.4
local HIT_FLASH_HIGHLIGHT_NAME = "BombHitFlash"
local HIT_FLASH_COLOR = Color3.fromRGB(255, 55, 55)
local HIT_FLASH_FILL_TRANSPARENCY = 0.28
local HIT_FLASH_OUTLINE_TRANSPARENCY = 0.05
local HIT_FLASH_FADE_SECONDS = 0.26
local HIT_FLASH_CLEANUP_SECONDS = 0.6
local PROJECTILE_PHYSICAL_HANDOFF_SECONDS = 0.14
local PROJECTILE_PHYSICAL_HANDOFF_MAX_SECONDS = 0.28
local FROZEN_BOMB_COLOR = Color3.fromRGB(91, 226, 255)
local FROZEN_BOMB_FILL_TRANSPARENCY = 0.18
local FROZEN_BOMB_OUTLINE_TRANSPARENCY = 0.02
local PROJECTILE_TIME_SCALE_ENTER_RATE = 7.5
local PROJECTILE_TIME_SCALE_EXIT_RATE = 5.5
local BEAM_CURVE_EPSILON = 1e-4
local ATTR = BombConfig.Attributes

type TrajectoryPreview = {
	model: Model,
	startPart: BasePart,
	endPart: BasePart,
	startAttachment: Attachment,
	endAttachment: Attachment,
	beams: { Beam },
	emitters: { ParticleEmitter },
	custom: boolean,
}

type AbilityTrajectoryPreviewOptions = {
	launchSpeed: number?,
	upwardVelocity: number?,
	gravity: number?,
	maxFlightSeconds: number?,
	maxPreviewTime: number?,
	color: Color3?,
	aimDirection: Vector3?,
	aimDirections: { Vector3 }?,
}

local BombController = {}
BombController.HoldStarted = Signal.new()
BombController.HoldReleased = Signal.new()
BombController.ThrowReleased = Signal.new()

BombController._beginRemote = nil :: RemoteEvent?
BombController._releaseRemote = nil :: RemoteEvent?
BombController._effectRemote = nil :: RemoteEvent?
BombController._effectConnection = nil :: RBXScriptConnection?
BombController._emitModule = nil :: any
BombController._emitModuleInitialized = false
BombController._warnedMissingExplosionVfx = false
BombController._warnedMissingEmitModule = false
BombController._warnedMissingAbilityVisuals = {} :: { [string]: boolean }
BombController._characterConnection = nil :: RBXScriptConnection?
BombController._characterRemovingConnection = nil :: RBXScriptConnection?
BombController._playerRemovingConnection = nil :: RBXScriptConnection?
BombController._cookingConnection = nil :: RBXScriptConnection?
BombController._humanoidConnection = nil :: RBXScriptConnection?
BombController._hipBombConnection = nil :: RBXScriptConnection?
BombController._stateConnections = {} :: { RBXScriptConnection }
BombController._character = nil :: Model?
BombController._animator = nil :: Animator?
BombController._animationLoadSerial = 0
BombController._bombTracks = {} :: { [string]: AnimationTrack }
BombController._animationObjects = {} :: { Animation }
BombController._animationConnections = {} :: { RBXScriptConnection }
BombController._releaseMarkerConnection = nil :: RBXScriptConnection?
BombController._previewFolder = nil :: Folder?
BombController._trajectoryPreview = nil :: TrajectoryPreview?
BombController._extraTrajectoryPreviews = {} :: { TrajectoryPreview }
BombController._trajectoryPreviewSkinId = nil :: string?
BombController._warnedMissingTrajectoryPreview = false
BombController._holding = false
BombController._previewing = false
BombController._releasePending = false
BombController._releaseFallbackSerial = 0
BombController._predictedProjectileSerial = 0
BombController._started = false
BombController._primaryBombInputSuppressed = false
BombController._abilityThrowActive = false
BombController._abilityReleaseCallback = nil :: (() -> ())?
BombController._lastDebugLogTimes = {} :: { [string]: number }
BombController._heldBombs = {} :: {
	[Player]: {
		instance: Instance,
		rootPart: BasePart,
		skinId: string?,
		visualScale: number?,
		highlight: Highlight?,
		pulseConnection: RBXScriptConnection?,
		fuseStartedAt: number?,
		fuseEndsAt: number?,
		abilityVisualOverlay: Instance?,
		frozen: boolean?,
		frozenUntil: number?,
	},
}
BombController._heldBombWanted = {} :: { [Player]: boolean }
BombController._heldBombSkinIds = {} :: { [Player]: string }
BombController._heldBombVisualScales = {} :: { [Player]: number }
BombController._heldBombPulseTimes = {} :: {
	[Player]: {
		fuseStartedAt: number,
		fuseEndsAt: number,
	},
}
BombController._localAbilityHeldVisualOptions = nil :: any?
BombController._hipBombs = {} :: { [Player]: any }
BombController._projectileVisualFolder = nil :: Folder?
BombController._projectileVisuals = {} :: {
	[string]: {
		instance: Instance,
		rootPart: BasePart,
		connection: RBXScriptConnection?,
		path: any,
		customProjectile: boolean?,
		position: Vector3?,
		velocity: Vector3?,
		targetPosition: Vector3?,
		targetVelocity: Vector3?,
		acceleration: Vector3?,
		settled: boolean?,
		spin: number,
		spinLocked: boolean?,
		ownsInstance: boolean,
		skinId: string?,
		highlight: Highlight?,
		pulseConnection: RBXScriptConnection?,
		handoffConnection: RBXScriptConnection?,
		handoffPhysical: Instance?,
		fuseStartedAt: number?,
		fuseEndsAt: number?,
		abilityVisualOverlay: Instance?,
		visuals: { [string]: any }?,
		visualScale: number?,
		burrowing: boolean?,
		timeScale: number?,
		targetTimeScale: number?,
	},
}

local replacementTransparencyByPart = setmetatable({}, { __mode = "k" }) :: { [BasePart]: number }

local function getRemote(name: string): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(name, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getCharacterParts(): (Model?, Humanoid?, BasePart?)
	local character = LocalPlayer.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	return character, humanoid, if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

local function getRootPart(): BasePart?
	local _, _, rootPart = getCharacterParts()
	return rootPart
end

local function getFallbackAimDirection(): Vector3
	return BombTrajectoryClient.GetFallbackAimDirection(getRootPart())
end

local function markAirControlLaunch(character: Model?, source: string, minAirTime: number)
	if not character then
		return
	end

	local now = os.clock()
	local currentForceUntil = character:GetAttribute(AIR_CONTROL_FORCE_AIRBORNE_UNTIL_ATTR)
	local currentSerial = character:GetAttribute(AIR_CONTROL_LAUNCH_SERIAL_ATTR)
	character:SetAttribute(
		AIR_CONTROL_FORCE_AIRBORNE_UNTIL_ATTR,
		math.max(if typeof(currentForceUntil) == "number" then currentForceUntil else 0, now + minAirTime)
	)
	character:SetAttribute(AIR_CONTROL_LAUNCH_SOURCE_ATTR, source)
	character:SetAttribute(AIR_CONTROL_LAUNCH_SERIAL_ATTR, (if typeof(currentSerial) == "number" then currentSerial else 0) + 1)
	character:SetAttribute(AIR_CONTROL_LAUNCHED_AT_ATTR, now)
end

local function applyOwnerClientExplosionLaunch(origin: Vector3)
	local character, humanoid, rootPart = getCharacterParts()
	if not (humanoid and rootPart and humanoid.Health > 0) then
		return
	end

	local distance = (rootPart.Position - origin).Magnitude
	if distance > BombConfig.OuterRadius then
		return
	end

	local away = rootPart.Position - origin
	if away.Magnitude < 0.05 then
		away = Vector3.yAxis
	else
		away = away.Unit
	end

	local radiusAlpha = math.clamp(1 - (distance / BombConfig.OuterRadius), 0, 1)
	local scale = math.max(radiusAlpha, BombConfig.OwnerClientLaunchMinScale)
	if scale <= 0 then
		return
	end

	local horizontal = BombConfig.OwnerClientLaunchHorizontal * scale
	local velocityDelta = Vector3.new(
		away.X * horizontal,
		BombConfig.OwnerClientLaunchVertical * scale,
		away.Z * horizontal
	)

	rootPart:ApplyImpulse(velocityDelta * rootPart.AssemblyMass)
	markAirControlLaunch(character, "Explosive", AIR_CONTROL_EXPLOSIVE_MIN_AIR_TIME)
end

local function getAimDirection(): Vector3
	return BombTrajectoryClient.GetAimDirection(getRootPart())
end

local function getMouseAimDirection(): Vector3
	return BombTrajectoryClient.GetMouseAimDirection(getRootPart())
end

local function isPrimaryBombInputOverGui(inputObject: InputObject): boolean
	if inputObject.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return false
	end

	local position = inputObject.Position
	local guiObjects = PlayerGui:GetGuiObjectsAtPosition(position.X, position.Y)
	for _, guiObject in ipairs(guiObjects) do
		if guiObject:IsA("GuiButton") and guiObject.Active and guiObject.Visible then
			return true
		end
	end
	return false
end

local function sanitizeAimDirection(aimDirection: Vector3, fallback: Vector3): Vector3
	return BombTrajectoryClient.SanitizeAimDirection(aimDirection, fallback)
end

local function getThrowOrigin(rootPart: BasePart): Vector3
	return BombTrajectoryClient.GetThrowOrigin(rootPart)
end

local function calculateTrajectoryWithConfig(
	origin: Vector3,
	aimDirection: Vector3,
	launchSpeed: number,
	upwardVelocity: number,
	gravity: number,
	maxFlightSeconds: number
)
	return BombTrajectoryClient.CalculateTrajectoryWithConfig(origin, aimDirection, launchSpeed, upwardVelocity, gravity, maxFlightSeconds)
end

local function calculateTrajectory(origin: Vector3, aimDirection: Vector3)
	return BombTrajectoryClient.CalculateTrajectory(origin, aimDirection)
end

local function getProjectileLaunchVelocity(aimDirection: Vector3): Vector3
	local direction = if typeof(aimDirection) == "Vector3" and aimDirection.Magnitude > 0.05
		then aimDirection.Unit
		else Vector3.zAxis
	return direction * BombConfig.ProjectileLaunchSpeed + Vector3.yAxis * BombConfig.ProjectileUpwardVelocity
end

local function getPlayerBombSkinId(player: Player?): string
	if not player then
		return BombSkinConfig.DefaultSkinId
	end

	local skinId = BombSkinConfig.NormalizeSkinId(player:GetAttribute(BombSkinConfig.AttributeName))
	return if skinId ~= "" then skinId else BombSkinConfig.DefaultSkinId
end

local function createBombVisualInstance(skinId: any, name: string?, effectState, visualScale: number?): (Instance, BasePart?)
	local instance, rootPart = BombVisualUtil.CreateBombVisual(skinId, name or BombConfig.RuntimeBombName, {
		anchored = false,
		canCollide = false,
		canQuery = false,
		massless = true,
		effectState = effectState,
		visualScale = visualScale,
	})
	return instance, rootPart
end

local function getRightGripAttachment(character: Model?): Attachment?
	if not character then
		return nil
	end

	local rightHand = character:FindFirstChild("RightHand")
	local rightHandGrip = rightHand and rightHand:FindFirstChild("RightGripAttachment")
	if rightHandGrip and rightHandGrip:IsA("Attachment") then
		return rightHandGrip
	end

	local rightArm = character:FindFirstChild("Right Arm")
	local rightArmGrip = rightArm and rightArm:FindFirstChild("RightGripAttachment")
	if rightArmGrip and rightArmGrip:IsA("Attachment") then
		return rightArmGrip
	end

	local fallbackGrip = character:FindFirstChild("RightGripAttachment", true)
	return if fallbackGrip and fallbackGrip:IsA("Attachment") then fallbackGrip else nil
end

local function getHeldGripOffset(): CFrame
	return if typeof(BombConfig.HeldGripOffset) == "CFrame" then BombConfig.HeldGripOffset else CFrame.new()
end

local function getBaseParts(instance: Instance): { BasePart }
	local parts: { BasePart } = {}
	if instance:IsA("BasePart") then
		table.insert(parts, instance)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function getInstanceByPath(path: any): Instance?
	if typeof(path) ~= "table" then
		return nil
	end

	local current: Instance? = ReplicatedStorage
	for _, name in ipairs(path) do
		if typeof(name) ~= "string" or name == "" or not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getFirstBasePart(instance: Instance?): BasePart?
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function isDescendantOfNamedAttachment(instance: Instance, attachmentName: any): boolean
	if typeof(attachmentName) ~= "string" or attachmentName == "" then
		return false
	end

	local current = instance.Parent
	while current do
		if current:IsA("Attachment") and current.Name == attachmentName then
			return true
		end
		current = current.Parent
	end
	return false
end

local function setOverlayEffectsEnabled(instance: Instance, enabled: boolean, disabledAttachmentName: any?)
	for _, descendant in ipairs(instance:GetDescendants()) do
		local descendantEnabled = enabled and not isDescendantOfNamedAttachment(descendant, disabledAttachmentName)
		if descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Beam")
			or descendant:IsA("PointLight")
			or descendant:IsA("SpotLight")
			or descendant:IsA("SurfaceLight")
		then
			descendant.Enabled = descendantEnabled
		elseif descendant:IsA("Sound") and descendantEnabled then
			descendant:Play()
		end
	end
end

local function pivotOverlayToRoot(overlay: Instance, overlayRoot: BasePart, rootPart: BasePart)
	local targetCFrame = rootPart.CFrame
	if overlay:IsA("Model") then
		overlay:PivotTo(targetCFrame)
		return
	end

	local sourceCFrame = overlayRoot.CFrame
	for _, part in ipairs(getBaseParts(overlay)) do
		local relativeCFrame = sourceCFrame:ToObjectSpace(part.CFrame)
		part.CFrame = targetCFrame * relativeCFrame
	end
end

local function prepareHeldBombVisual(instance: Instance, rootPart: BasePart)
	for _, part in ipairs(getBaseParts(instance)) do
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true

		if part ~= rootPart then
			local weld = Instance.new("WeldConstraint")
			weld.Name = HELD_BOMB_WELD_NAME
			weld.Part0 = rootPart
			weld.Part1 = part
			weld.Parent = rootPart
		end
	end
end

local function isSelfOrDescendantOfInstance(instance: Instance, ancestor: Instance?): boolean
	return ancestor ~= nil and (instance == ancestor or instance:IsDescendantOf(ancestor))
end

local function setVisualLocalTransparency(instance: Instance?, alpha: number)
	if not instance then
		return
	end

	alpha = math.clamp(alpha, 0, 1)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = alpha
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = alpha
		end
	end
end

local function setVisualLocalTransparencyExcept(instance: Instance?, alpha: number, excluded: Instance?)
	if not instance then
		return
	end

	alpha = math.clamp(alpha, 0, 1)
	if instance:IsA("BasePart") and not isSelfOrDescendantOfInstance(instance, excluded) then
		instance.LocalTransparencyModifier = alpha
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and not isSelfOrDescendantOfInstance(descendant, excluded) then
			descendant.LocalTransparencyModifier = alpha
		end
	end
end

local function setReplacementPartHidden(part: BasePart, hidden: boolean)
	if hidden then
		if replacementTransparencyByPart[part] == nil then
			replacementTransparencyByPart[part] = part.Transparency
		end
		part.LocalTransparencyModifier = 1
		part.Transparency = 1
		return
	end

	local originalTransparency = replacementTransparencyByPart[part]
	if originalTransparency ~= nil then
		part.Transparency = originalTransparency
		replacementTransparencyByPart[part] = nil
	end
	part.LocalTransparencyModifier = 0
end

local function setVisualReplacementHiddenExcept(instance: Instance?, hidden: boolean, excluded: Instance?)
	if not instance then
		return
	end

	if instance:IsA("BasePart") and not isSelfOrDescendantOfInstance(instance, excluded) then
		setReplacementPartHidden(instance, hidden)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and not isSelfOrDescendantOfInstance(descendant, excluded) then
			setReplacementPartHidden(descendant, hidden)
		end
	end
end

local function setVisualEffectsEnabledExcept(instance: Instance?, enabled: boolean, excluded: Instance?)
	if not instance then
		return
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if isSelfOrDescendantOfInstance(descendant, excluded) then
			continue
		end

		if descendant:IsA("ParticleEmitter")
			or descendant:IsA("Trail")
			or descendant:IsA("Beam")
			or descendant:IsA("PointLight")
			or descendant:IsA("SpotLight")
			or descendant:IsA("SurfaceLight")
		then
			descendant.Enabled = enabled
		elseif descendant:IsA("Sound") and not enabled then
			descendant:Stop()
		end
	end
end

function BombController:_destroyAbilityVisualOverlay(visual)
	if visual and visual.abilityVisualOverlay then
		if visual.abilityVisualOverlay.Parent then
			visual.abilityVisualOverlay:Destroy()
		end
		visual.abilityVisualOverlay = nil
	end
end

function BombController:_applyAbilityVisualOverlay(visual, assetPath: any, overlayName: string?, disabledAttachmentName: any?)
	if not (visual and visual.instance and visual.rootPart and visual.rootPart.Parent) then
		return
	end
	if visual.abilityVisualOverlay and visual.abilityVisualOverlay.Parent then
		if visual.abilityVisualOverlay:IsDescendantOf(visual.instance) then
			return
		end
		self:_destroyAbilityVisualOverlay(visual)
	end
	if visual.abilityVisualOverlay and visual.abilityVisualOverlay.Parent then
		return
	end

	local template = getInstanceByPath(assetPath)
	if not template then
		local key = if typeof(assetPath) == "table" then table.concat(assetPath, ".") else "unknown"
		if not self._warnedMissingAbilityVisuals[key] then
			self._warnedMissingAbilityVisuals[key] = true
			warn(("[BombController] Missing ability visual template: ReplicatedStorage.%s"):format(key))
		end
		return
	end

	local overlay = template:Clone()
	overlay.Name = if typeof(overlayName) == "string" and overlayName ~= "" then overlayName else ABILITY_VISUAL_OVERLAY_NAME
	local overlayRoot = getFirstBasePart(overlay)
	if not overlayRoot then
		overlay:Destroy()
		return
	end

	pivotOverlayToRoot(overlay, overlayRoot, visual.rootPart)
	for _, part in ipairs(getBaseParts(overlay)) do
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true

		local weld = Instance.new("WeldConstraint")
		weld.Name = ABILITY_VISUAL_OVERLAY_NAME .. "Weld"
		weld.Part0 = visual.rootPart
		weld.Part1 = part
		weld.Parent = visual.rootPart
	end

	setOverlayEffectsEnabled(overlay, true, disabledAttachmentName)
	overlay.Parent = visual.instance
	visual.abilityVisualOverlay = overlay
end

function BombController:_syncAbilityVisualOverlay(visual)
	local visuals = visual and visual.visuals
	if typeof(visuals) == "table" and visuals.freezeBomb == true then
		self:_applyAbilityVisualOverlay(visual, visuals.freezeAssetPath, "FreezeBombVFX")
	elseif typeof(visuals) == "table" and visuals.abilityVisualOverlay == true then
		self:_applyAbilityVisualOverlay(
			visual,
			visuals.abilityVisualAssetPath,
			visuals.abilityVisualName,
			visuals.abilityVisualDisabledAttachmentName
		)
	else
		self:_destroyAbilityVisualOverlay(visual)
	end
end

function BombController:_syncProjectileBaseVisual(visual)
	local visuals = visual and visual.visuals
	local hideBase = typeof(visuals) == "table"
		and visuals.hideBaseVisual == true
	local overlay = if visual then visual.abilityVisualOverlay else nil
	if hideBase then
		if overlay and overlay.Parent then
			setVisualReplacementHiddenExcept(visual.instance, true, overlay)
			setVisualEffectsEnabledExcept(visual.instance, false, overlay)
		else
			setVisualReplacementHiddenExcept(visual.instance, true, nil)
			setVisualEffectsEnabledExcept(visual.instance, false, nil)
		end
	else
		setVisualReplacementHiddenExcept(visual.instance, false, nil)
		setVisualLocalTransparency(visual.instance, 0)
	end
	if visual.highlight then
		visual.highlight.Enabled = not hideBase
	end
end

function BombController:_syncHeldBaseVisual(held)
	local replaceBase = typeof(self._localAbilityHeldVisualOptions) == "table"
		and self._localAbilityHeldVisualOptions.replaceBaseVisual == true
		and held
	local overlay = if held then held.abilityVisualOverlay else nil
	if replaceBase then
		if overlay and overlay.Parent then
			setVisualReplacementHiddenExcept(held.instance, true, overlay)
			setVisualEffectsEnabledExcept(held.instance, false, overlay)
		else
			setVisualReplacementHiddenExcept(held.instance, true, nil)
			setVisualEffectsEnabledExcept(held.instance, false, nil)
		end
	else
		setVisualReplacementHiddenExcept(held and held.instance or nil, false, nil)
		setVisualLocalTransparency(held and held.instance or nil, 0)
	end
	if held and held.highlight then
		held.highlight.Enabled = not replaceBase
	end
end

function BombController:_refreshHeldAbilityVisual(player: Player)
	local held = self._heldBombs[player]
	if not held then
		return
	end
	if player ~= LocalPlayer or typeof(self._localAbilityHeldVisualOptions) ~= "table" then
		self:_destroyAbilityVisualOverlay(held)
		self:_syncHeldBaseVisual(held)
		return
	end

	self:_applyAbilityVisualOverlay(
		held,
		self._localAbilityHeldVisualOptions.assetPath,
		self._localAbilityHeldVisualOptions.name,
		self._localAbilityHeldVisualOptions.disabledAttachmentName
	)

	self:_syncHeldBaseVisual(held)
end

local function getServerTime(): number
	return workspace:GetServerTimeNow()
end

local function getBombCount(): number
	local count = LocalPlayer:GetAttribute(ATTR.Count)
	return if typeof(count) == "number" then count else BombConfig.MaxBombs
end

local function getPlayerBombCount(player: Player): number
	local count = player:GetAttribute(ATTR.Count)
	return if typeof(count) == "number" then count else BombConfig.MaxBombs
end

local function isCooking(): boolean
	return LocalPlayer:GetAttribute(ATTR.Cooking) == true
end

local function isRoundActiveForLocalPlayer(): boolean
	return CombatEligibility.IsClientCombatActive(LocalPlayer, RoundController:Get("state"), RoundStates.Active)
end

local function isServerAnimator(animator: Animator): boolean
	local attributeName = AnimationConfig.ServerAnimatorAttributeName
	return typeof(attributeName) ~= "string" or attributeName == "" or animator:GetAttribute(attributeName) == true
end

local function findServerAnimator(humanoid: Humanoid): Animator?
	for _, child in ipairs(humanoid:GetChildren()) do
		if child:IsA("Animator") and isServerAnimator(child) then
			return child
		end
	end

	return nil
end

local function waitForServerAnimator(character: Model): Animator?
	local deadline = os.clock() + ANIMATOR_LOOKUP_TIMEOUT
	repeat
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local animator = findServerAnimator(humanoid)
			if animator then
				return animator
			end
		end

		task.wait()
	until os.clock() >= deadline or not character.Parent

	return nil
end

local function getBombTrackWeight(name: string): number
	local config = AnimationConfig.BombAnimations[name]
	if config and typeof(config.Weight) == "number" then
		return math.clamp(config.Weight, 0, 1)
	end

	return 1
end

local function getBombAnimationFadeInTime(): number
	local fadeTime = AnimationConfig.BombAnimationFadeInTime
	if typeof(fadeTime) == "number" then
		return math.max(fadeTime, 0)
	end

	return math.max(AnimationConfig.BombAnimationFadeTime or 0, 0)
end

local function getBombAnimationFadeOutTime(): number
	local fadeTime = AnimationConfig.BombAnimationFadeOutTime
	if typeof(fadeTime) == "number" then
		return math.max(fadeTime, 0)
	end

	return math.max(AnimationConfig.BombAnimationFadeTime or 0, 0)
end

local function isBombTrackEnabled(name: string): boolean
	local toggles = AnimationConfig.DebugRiskyTrackEnabled
	return not (typeof(toggles) == "table" and toggles[name] == false)
end

local function readTrackNumber(track: AnimationTrack, propertyName: string): number?
	local ok, value = pcall(function()
		return track[propertyName]
	end)

	return if ok and typeof(value) == "number" then value else nil
end

local function getRootAngles(rootPart: BasePart?): (number, number, number)
	if not rootPart then
		return 0, 0, 0
	end

	local pitch, yaw, roll = rootPart.CFrame:ToOrientation()
	return math.deg(pitch), math.deg(roll), math.deg(yaw)
end

local function formatNumber(value: number?): string
	if typeof(value) ~= "number" then
		return "?"
	end

	return string.format("%.2f", value)
end

local function getTrackSummary(track: AnimationTrack?): string
	if not track then
		return "track=nil"
	end

	return string.format(
		"playing=%s weight=%s target=%s speed=%s priority=%s",
		tostring(track.IsPlaying),
		formatNumber(readTrackNumber(track, "WeightCurrent")),
		formatNumber(readTrackNumber(track, "WeightTarget")),
		formatNumber(readTrackNumber(track, "Speed")),
		track.Priority.Name
	)
end

local function getTrajectoryLineAsset(): Model?
	local current: Instance? = ReplicatedStorage
	for _, childName in ipairs(TRAJECTORY_VFX_PATH) do
		current = current and current:FindFirstChild(childName)
		if not current then
			return nil
		end
	end

	return if current and current:IsA("Model") then current else nil
end

local function getNamedBasePart(parent: Instance, childName: string): BasePart?
	local child = parent:FindFirstChild(childName)
	return if child and child:IsA("BasePart") then child else nil
end

local function getNamedAttachment(parent: Instance, childName: string): Attachment?
	local child = parent:FindFirstChild(childName)
	return if child and child:IsA("Attachment") then child else nil
end

local function collectTrajectoryPreviewDescendants(model: Model): ({ Beam }, { ParticleEmitter })
	local beams: { Beam } = {}
	local emitters: { ParticleEmitter } = {}

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Beam") then
			table.insert(beams, descendant)
		elseif descendant:IsA("ParticleEmitter") then
			table.insert(emitters, descendant)
		end
	end

	return beams, emitters
end

local function setTrajectoryPreviewEnabled(preview: TrajectoryPreview, enabled: boolean)
	for _, beam in ipairs(preview.beams) do
		beam.Enabled = enabled
	end
	for _, emitter in ipairs(preview.emitters) do
		emitter.Enabled = enabled
	end
end

local function tintTrajectoryPreview(preview: TrajectoryPreview, color: Color3)
	local colorSequence = ColorSequence.new(color)
	for _, beam in ipairs(preview.beams) do
		beam.Color = colorSequence
	end
	for _, emitter in ipairs(preview.emitters) do
		emitter.Color = colorSequence
	end
end

local function getUnitOrFallback(vector: Vector3, fallback: Vector3): Vector3
	if vector.Magnitude > BEAM_CURVE_EPSILON then
		return vector.Unit
	end
	if fallback.Magnitude > BEAM_CURVE_EPSILON then
		return fallback.Unit
	end
	return Vector3.xAxis
end

local function cframeFromRightVector(position: Vector3, rightVector: Vector3): CFrame
	local right = getUnitOrFallback(rightVector, Vector3.xAxis)
	local upReference = if math.abs(right:Dot(Vector3.yAxis)) < 0.95 then Vector3.yAxis else Vector3.zAxis
	local back = right:Cross(upReference)
	if back.Magnitude <= BEAM_CURVE_EPSILON then
		back = Vector3.zAxis
	else
		back = back.Unit
	end
	local up = back:Cross(right).Unit

	return CFrame.fromMatrix(position, right, up, back)
end

local function findPreviewTrajectoryHit(path: BombTrajectory.Path, maxPreviewTime: number): (RaycastResult?, number)
	return BombTrajectoryClient.FindPreviewTrajectoryHit(path, maxPreviewTime, LocalPlayer.Character)
end

function BombController:_getPreviewFolder(): Folder
	if self._previewFolder and self._previewFolder.Parent then
		return self._previewFolder
	end

	local folder = Instance.new("Folder")
	folder.Name = PREVIEW_FOLDER_NAME
	folder.Parent = workspace
	self._previewFolder = folder
	return folder
end

function BombController:_warnMissingTrajectoryPreview(reason: string)
	if self._warnedMissingTrajectoryPreview then
		return
	end

	self._warnedMissingTrajectoryPreview = true
	warn("[BombController] Missing or malformed trajectory preview VFX: " .. reason)
end

local warnedCustomTrajectorySkins: { [string]: boolean } = {}

local function warnMalformedCustomTrajectory(skinId: string, reason: string)
	if warnedCustomTrajectorySkins[skinId] then
		return
	end

	warnedCustomTrajectorySkins[skinId] = true
	warn(("[BombController] Bomb skin %s has a malformed trajectory Beam asset (%s); using the default"):format(skinId, reason))
end

local function normalizeTrajectoryTemplateClone(clone: Instance): (Model?, string)
	if clone:IsA("Model") then
		return clone, ""
	end

	if clone:IsA("BasePart") then
		local startAttachment = getNamedAttachment(clone, "Start")
		local endAttachment = getNamedAttachment(clone, "End")
		if not (startAttachment and endAttachment) then
			clone:Destroy()
			return nil, "expected Start and End attachments on the Beam part"
		end

		local model = Instance.new("Model")
		model.Name = clone.Name

		local startPart = Instance.new("Part")
		startPart.Name = "Start"
		startPart.Size = Vector3.one
		startAttachment.Parent = startPart
		startPart.Parent = model

		local endPart = Instance.new("Part")
		endPart.Name = "End"
		endPart.Size = Vector3.one
		endAttachment.Parent = endPart
		endPart.Parent = model

		clone:Destroy()
		return model, ""
	end

	clone:Destroy()
	return nil, "expected a Model or BasePart"
end

local function assembleTrajectoryPreview(clone: Model, custom: boolean): (TrajectoryPreview?, string)
	local startPart = getNamedBasePart(clone, "Start")
	local endPart = getNamedBasePart(clone, "End")
	if not (startPart and endPart) then
		clone:Destroy()
		return nil, "expected Start and End BasePart children"
	end

	local startAttachment = getNamedAttachment(startPart, "Start")
	local endAttachment = getNamedAttachment(endPart, "End")
	if not (startAttachment and endAttachment) then
		clone:Destroy()
		return nil, "expected Start.Start and End.End attachments"
	end

	local beams, emitters = collectTrajectoryPreviewDescendants(clone)
	if #beams == 0 then
		clone:Destroy()
		return nil, "expected at least one Beam descendant"
	end

	for _, part in ipairs({ startPart, endPart }) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
	end

	startAttachment.CFrame = CFrame.new()
	endAttachment.CFrame = CFrame.new()

	for _, beam in ipairs(beams) do
		beam.Attachment0 = endAttachment
		beam.Attachment1 = startAttachment
	end

	local preview: TrajectoryPreview = {
		model = clone,
		startPart = startPart,
		endPart = endPart,
		startAttachment = startAttachment,
		endAttachment = endAttachment,
		beams = beams,
		emitters = emitters,
		custom = custom,
	}

	return preview, ""
end

function BombController:_createTrajectoryPreview(name: string): TrajectoryPreview?
	local preview: TrajectoryPreview?

	local skinId = getPlayerBombSkinId(LocalPlayer)
	local customTemplate = BombVisualUtil.GetSkinTrajectoryBeamTemplate(skinId)
	if customTemplate then
		local clone, normalizeReason = normalizeTrajectoryTemplateClone(customTemplate:Clone())
		if clone then
			clone.Name = name
			local assembled, assembleReason = assembleTrajectoryPreview(clone, true)
			if assembled then
				preview = assembled
			else
				warnMalformedCustomTrajectory(skinId, assembleReason)
			end
		else
			warnMalformedCustomTrajectory(skinId, normalizeReason)
		end
	end

	if not preview then
		local template = getTrajectoryLineAsset()
		if not template then
			self:_warnMissingTrajectoryPreview("ReplicatedStorage.Assets.VFX.Trajectory.TrajectoryLine was not found")
			return nil
		end

		local clone = template:Clone()
		clone.Name = name
		local assembled, assembleReason = assembleTrajectoryPreview(clone, false)
		if not assembled then
			self:_warnMissingTrajectoryPreview(assembleReason)
			return nil
		end
		preview = assembled
	end

	setTrajectoryPreviewEnabled(preview, false)
	preview.model.Parent = self:_getPreviewFolder()

	return preview
end

function BombController:_destroyTrajectoryPreviews()
	if self._trajectoryPreview then
		self._trajectoryPreview.model:Destroy()
		self._trajectoryPreview = nil
	end

	for _, preview in pairs(self._extraTrajectoryPreviews) do
		preview.model:Destroy()
	end
	table.clear(self._extraTrajectoryPreviews)
end

function BombController:_refreshTrajectoryPreviewSkin()
	local skinId = getPlayerBombSkinId(LocalPlayer)
	if self._trajectoryPreviewSkinId == skinId then
		return
	end

	self._trajectoryPreviewSkinId = skinId
	self:_destroyTrajectoryPreviews()
end

function BombController:_ensureTrajectoryPreview(): TrajectoryPreview?
	self:_refreshTrajectoryPreviewSkin()

	if self._trajectoryPreview and self._trajectoryPreview.model.Parent then
		return self._trajectoryPreview
	end

	self._trajectoryPreview = self:_createTrajectoryPreview(TRAJECTORY_PREVIEW_NAME)
	return self._trajectoryPreview
end

function BombController:_ensureTrajectoryPreviewAt(index: number): TrajectoryPreview?
	if index <= 1 then
		return self:_ensureTrajectoryPreview()
	end

	self:_refreshTrajectoryPreviewSkin()

	local existing = self._extraTrajectoryPreviews[index - 1]
	if existing and existing.model.Parent then
		return existing
	end

	local preview = self:_createTrajectoryPreview(TRAJECTORY_PREVIEW_NAME .. tostring(index))
	self._extraTrajectoryPreviews[index - 1] = preview
	return preview
end

function BombController:_hideExtraTrajectoryPreviews(startIndex: number?)
	local first = math.max(startIndex or 1, 1)
	for index = first, #self._extraTrajectoryPreviews do
		local preview = self._extraTrajectoryPreviews[index]
		if preview then
			setTrajectoryPreviewEnabled(preview, false)
		end
	end
end

function BombController:_destroyHeldBomb(player: Player)
	local held = self._heldBombs[player]
	if held then
		self:_stopBombPulse(held)
		self:_destroyAbilityVisualOverlay(held)
	end
	if held and held.instance.Parent then
		held.instance:Destroy()
	end
	self._heldBombs[player] = nil

	local character = player.Character
	if not character then
		return
	end

	for _, child in ipairs(character:GetChildren()) do
		if child.Name == HELD_BOMB_VISUAL_NAME then
			child:Destroy()
		end
	end
end

function BombController:_hideHeldBomb(player: Player)
	self._heldBombWanted[player] = nil
	self._heldBombSkinIds[player] = nil
	self._heldBombVisualScales[player] = nil
	self._heldBombPulseTimes[player] = nil
	self:_destroyHeldBomb(player)
end

function BombController:_ensureHeldBomb(player: Player, attempt: number)
	if self._heldBombWanted[player] ~= true or player.Parent ~= Players then
		return
	end

	local held = self._heldBombs[player]
	local skinId = self._heldBombSkinIds[player] or getPlayerBombSkinId(player)
	local visualScale = math.max(tonumber(self._heldBombVisualScales[player]) or BombConfig.HeldVisualScale, 0.05)
	if held and held.instance.Parent and held.skinId == skinId and math.abs((held.visualScale or BombConfig.HeldVisualScale) - visualScale) <= 0.075 then
		self:_refreshHeldAbilityVisual(player)
		self:_syncHeldBaseVisual(held)
		return
	end
	self:_destroyHeldBomb(player)

	local character = player.Character
	local gripAttachment = getRightGripAttachment(character)
	if not (character and gripAttachment) then
		if attempt < HELD_BOMB_ATTACH_MAX_ATTEMPTS then
			task.delay(HELD_BOMB_ATTACH_RETRY_SECONDS, function()
				self:_ensureHeldBomb(player, attempt + 1)
			end)
		end
		return
	end

	local instance, rootPart = createBombVisualInstance(skinId, HELD_BOMB_VISUAL_NAME, {
		vfx = true,
		fuseSpark = false,
		trail = false,
	}, visualScale)
	if not rootPart then
		instance:Destroy()
		return
	end

	instance.Name = HELD_BOMB_VISUAL_NAME
	if instance:IsA("Model") then
		instance.PrimaryPart = rootPart
	end

	prepareHeldBombVisual(instance, rootPart)

	local gripOffset = getHeldGripOffset()
	local bombAttachment = Instance.new("Attachment")
	bombAttachment.Name = HELD_BOMB_GRIP_ATTACHMENT_NAME
	bombAttachment.CFrame = gripOffset
	bombAttachment.Parent = rootPart

	local rootCFrame = gripAttachment.WorldCFrame * gripOffset:Inverse()
	if instance:IsA("Model") then
		instance:PivotTo(rootCFrame)
	elseif instance:IsA("BasePart") then
		instance.CFrame = rootCFrame
	end
	instance.Parent = character

	local constraint = Instance.new("RigidConstraint")
	constraint.Name = HELD_BOMB_CONSTRAINT_NAME
	constraint.Attachment0 = gripAttachment
	constraint.Attachment1 = bombAttachment
	constraint.Parent = rootPart

	local held = {
		instance = instance,
		rootPart = rootPart,
		skinId = skinId,
		visualScale = visualScale,
		highlight = nil,
		pulseConnection = nil,
		fuseStartedAt = nil,
		fuseEndsAt = nil,
		abilityVisualOverlay = nil,
	}
	self._heldBombs[player] = held
	self:_refreshHeldAbilityVisual(player)

	local pulseTimes = self._heldBombPulseTimes[player]
	if pulseTimes then
		self:_startBombPulse(held, instance, pulseTimes.fuseStartedAt, pulseTimes.fuseEndsAt)
		self:_syncHeldBaseVisual(held)
	end
end

function BombController:_showHeldBomb(player: Player, skinId: any?)
	self._heldBombWanted[player] = true
	local resolvedSkinId = BombSkinConfig.NormalizeSkinId(skinId)
	self._heldBombSkinIds[player] = if resolvedSkinId ~= "" then resolvedSkinId else getPlayerBombSkinId(player)
	self:_ensureHeldBomb(player, 0)
end

function BombController:_setHeldBombEffects(player: Player, fuseSpark: boolean, trail: boolean)
	local held = self._heldBombs[player]
	if not held then
		return
	end

	BombVisualUtil.SetEffectState(held.instance, {
		vfx = true,
		fuseSpark = fuseSpark,
		trail = trail,
	})
	self:_syncHeldBaseVisual(held)
end

function BombController:SetLocalHeldBombVisualScale(scale: number)
	local visualScale = math.max(tonumber(scale) or 1, 0.05) * BombConfig.HeldVisualScale
	self._heldBombVisualScales[LocalPlayer] = visualScale
	if self._heldBombWanted[LocalPlayer] == true then
		self:_ensureHeldBomb(LocalPlayer, 0)
	end
end

function BombController:ResetLocalHeldBombVisualScale()
	self._heldBombVisualScales[LocalPlayer] = nil
	if self._heldBombWanted[LocalPlayer] == true then
		self:_ensureHeldBomb(LocalPlayer, 0)
	end
end

function BombController:SetLocalAbilityHeldVisual(options)
	self._localAbilityHeldVisualOptions = if typeof(options) == "table" then options else nil
	self:_refreshHeldAbilityVisual(LocalPlayer)
end

function BombController:ClearLocalAbilityHeldVisual()
	self._localAbilityHeldVisualOptions = nil
	self:_refreshHeldAbilityVisual(LocalPlayer)
end

function BombController:_destroyHipBomb(player: Player)
	local visual = self._hipBombs[player]
	if visual then
		visual:Destroy()
	end
	self._hipBombs[player] = nil
	if not visual then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant.Name == HIP_BOMB_VISUAL_NAME or (descendant.Name == HIP_BOMB_MOTOR_NAME and descendant:IsA("Motor6D")) then
			descendant:Destroy()
		end
	end
end

function BombController:_isHipBombSuppressed(player: Player): boolean
	if self._heldBombWanted[player] == true then
		return true
	end

	return player == LocalPlayer and (self._holding or self._releasePending or isCooking())
end

function BombController:_shouldShowHipBomb(player: Player): boolean
	local hipConfig = BombConfig.HipCarry
	if hipConfig and hipConfig.Enabled == false then
		return false
	end
	if player.Parent ~= Players then
		return false
	end
	if not CombatEligibility.IsClientCombatActive(player, RoundController:Get("state"), RoundStates.Active) then
		return false
	end
	if getPlayerBombCount(player) <= 0 then
		return false
	end
	if self:_isHipBombSuppressed(player) then
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return character ~= nil and humanoid ~= nil and humanoid.Health > 0
end

function BombController:_getHipSwayState(player: Player)
	local character = player.Character
	if not character then
		return nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (rootPart and rootPart:IsA("BasePart")) then
		return nil
	end

	return {
		cframe = rootPart.CFrame,
		linearVelocity = rootPart.AssemblyLinearVelocity,
		grounded = character:GetAttribute("Movement_Grounded") ~= false,
		sprinting = character:GetAttribute("Movement_Sprinting") == true,
		sliding = character:GetAttribute("Movement_Sliding") == true,
		landingRecoveryAlpha = character:GetAttribute("Movement_LandingRecoveryAlpha"),
	}
end

function BombController:_stepHipBombs(deltaTime: number)
	local activePlayers = {}

	for _, player in ipairs(Players:GetPlayers()) do
		activePlayers[player] = true
		if not self:_shouldShowHipBomb(player) then
			self:_destroyHipBomb(player)
			continue
		end

		local visual = self._hipBombs[player]
		local skinId = getPlayerBombSkinId(player)
		if visual and visual.skinId ~= skinId then
			self:_destroyHipBomb(player)
			visual = nil
		end
		if not visual then
			local character = player.Character
			if character then
				visual = HipBombVisual.new(character, nil, {
					skinId = skinId,
				})
				self._hipBombs[player] = visual
			end
		end

		if visual then
			local state = self:_getHipSwayState(player)
			if not state or not visual:Step(deltaTime, state) then
				self:_destroyHipBomb(player)
			else
				visual:SetVisible(true)
			end
		end
	end

	for player in pairs(self._hipBombs) do
		if not activePlayers[player] then
			self:_destroyHipBomb(player)
		end
	end
end

function BombController:_startHeldBombPulse(player: Player, startedAt: number?, fuseSeconds: number?)
	local fuseStartedAt = if typeof(startedAt) == "number" then startedAt else getServerTime()
	local duration = if typeof(fuseSeconds) == "number" then math.max(fuseSeconds, 0.001) else BombConfig.FuseSeconds
	local fuseEndsAt = fuseStartedAt + duration

	self._heldBombPulseTimes[player] = {
		fuseStartedAt = fuseStartedAt,
		fuseEndsAt = fuseEndsAt,
	}

	local held = self._heldBombs[player]
	if held and held.instance.Parent then
		self:_startBombPulse(held, held.instance, fuseStartedAt, fuseEndsAt)
		self:_setHeldBombEffects(player, true, false)
		self:_syncHeldBaseVisual(held)
	end
end

function BombController:_startPreview()
	if self._previewing then
		return
	end

	self._previewing = true
	self:_ensureTrajectoryPreview()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function()
		local token = RuntimeProfiler.Begin("Client/BombController/Preview")
		self:_updatePreview()
		RuntimeProfiler.End("Client/BombController/Preview", token)
	end)
end

function BombController:_stopPreview()
	if not self._previewing then
		return
	end

	self._previewing = false
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	if self._trajectoryPreview then
		setTrajectoryPreviewEnabled(self._trajectoryPreview, false)
	end
	self:_hideExtraTrajectoryPreviews(1)
end

function BombController:_disconnectAnimationConnections()
	for _, connection in ipairs(self._animationConnections) do
		connection:Disconnect()
	end
	self._animationConnections = {}
end

function BombController:_disconnectReleaseMarker()
	if self._releaseMarkerConnection then
		self._releaseMarkerConnection:Disconnect()
		self._releaseMarkerConnection = nil
	end
end

function BombController:_stopBombTracks(fadeTime: number?)
	local stopFadeTime = if typeof(fadeTime) == "number" then math.max(fadeTime, 0) else getBombAnimationFadeOutTime()
	for _, track in pairs(self._bombTracks) do
		if track.IsPlaying then
			track:Stop(stopFadeTime)
		end
	end
end

function BombController:_clearBombAnimationState()
	self._holding = false
	self._releasePending = false
	self._releaseFallbackSerial += 1
	self._abilityThrowActive = false
	self._abilityReleaseCallback = nil
	self:_disconnectReleaseMarker()
	self:_disconnectAnimationConnections()
	self:_stopBombTracks()
	self:_hideHeldBomb(LocalPlayer)
end

function BombController:_canBeginBombHold(ignoreHolding: boolean?): boolean
	if not self._started then
		return false
	end
	if self._primaryBombInputSuppressed and not ignoreHolding then
		return false
	end
	if self._beginRemote == nil or self._releaseRemote == nil then
		return false
	end
	if not ignoreHolding and (self._holding or self._releasePending or isCooking()) then
		return false
	end
	if getBombCount() <= 0 then
		return false
	end
	if not isRoundActiveForLocalPlayer() then
		return false
	end

	local _, humanoid, rootPart = getCharacterParts()
	return humanoid ~= nil and humanoid.Health > 0 and rootPart ~= nil
end

function BombController:_cancelHold()
	if not self._holding then
		return
	end

	self:_clearBombAnimationState()
	self:_stopPreview()
	self.HoldReleased:Fire()
end

function BombController:_cancelHoldIfInvalid()
	if not self._holding then
		return
	end

	if self._abilityThrowActive then
		local _, humanoid, rootPart = getCharacterParts()
		if not (self._started and isRoundActiveForLocalPlayer() and humanoid and humanoid.Health > 0 and rootPart) then
			self:_cancelHold()
		end
	elseif not self:_canBeginBombHold(true) then
		self:_cancelHold()
	end
end

function BombController:_destroyBombAnimations()
	self._animationLoadSerial += 1
	self:_clearBombAnimationState()

	for _, animation in ipairs(self._animationObjects) do
		animation:Destroy()
	end

	self._animationObjects = {}
	self._bombTracks = {}
	self._animator = nil
	self._lastDebugLogTimes = {}
end

function BombController:_bindBombAnimations(character: Model, animator: Animator?, serial: number): boolean
	if self._animationLoadSerial ~= serial or self._character ~= character or LocalPlayer.Character ~= character then
		return false
	end
	if not (animator and character.Parent and animator.Parent and animator.Parent:IsA("Humanoid")) then
		return false
	end

	self._animator = animator

	for name, config in pairs(AnimationConfig.BombAnimations) do
		if self._animationLoadSerial ~= serial or self._character ~= character or LocalPlayer.Character ~= character then
			return false
		end

		local animation = Instance.new("Animation")
		animation.Name = "Bomb" .. name
		animation.AnimationId = config.AnimationId
		animation.Parent = script
		table.insert(self._animationObjects, animation)

		local track = animator:LoadAnimation(animation)
		track.Looped = config.Looped == true
		track.Priority = config.Priority
		self._bombTracks[name] = track
	end

	return true
end

function BombController:_disconnectStateConnections()
	for _, connection in ipairs(self._stateConnections) do
		connection:Disconnect()
	end
	self._stateConnections = {}
end

function BombController:_bindInvalidStateSignals()
	self:_disconnectStateConnections()

	table.insert(self._stateConnections, LocalPlayer:GetAttributeChangedSignal(ATTR.Count):Connect(function()
		self:_cancelHoldIfInvalid()
	end))
	table.insert(self._stateConnections, LocalPlayer:GetAttributeChangedSignal(ROUND_ALIVE_ATTR):Connect(function()
		self:_cancelHoldIfInvalid()
	end))
	table.insert(self._stateConnections, LocalPlayer:GetAttributeChangedSignal(CombatEligibility.PracticeRangeActiveAttribute):Connect(function()
		self:_cancelHoldIfInvalid()
	end))
	table.insert(self._stateConnections, LocalPlayer:GetAttributeChangedSignal(CombatEligibility.AFKAttribute):Connect(function()
		self:_cancelHoldIfInvalid()
	end))
	table.insert(self._stateConnections, RoundController.StateReceived:Connect(function()
		self:_cancelHoldIfInvalid()
	end))
	table.insert(self._stateConnections, RoundController.StateUpdated:Connect(function(key: string)
		if key == "state" then
			self:_cancelHoldIfInvalid()
		end
	end))
end

function BombController:_loadBombAnimations(character: Model)
	self:_destroyBombAnimations()
	self._character = character
	local serial = self._animationLoadSerial

	task.spawn(function()
		while self._animationLoadSerial == serial and self._character == character and LocalPlayer.Character == character do
			if not character.Parent then
				return
			end

			local animator = waitForServerAnimator(character)
			if self:_bindBombAnimations(character, animator, serial) then
				return
			end
			if self._animationLoadSerial ~= serial or self._character ~= character or LocalPlayer.Character ~= character then
				return
			end
			if not character.Parent then
				return
			end

			warn("[BombController] Waiting for server-created Animator for character:", character:GetFullName())
			task.wait(ANIMATOR_RETRY_SECONDS)
		end
	end)
end

function BombController:_setDebugAttributes(eventName: string, trackName: string?, pitch: number, roll: number)
	local character = LocalPlayer.Character
	if not character then
		return
	end

	character:SetAttribute("Animation_DebugLastEvent", eventName)
	character:SetAttribute("Animation_DebugLastRootPitch", pitch)
	character:SetAttribute("Animation_DebugLastRootRoll", roll)
	character:SetAttribute("Animation_DebugLastTrack", trackName or "")
end

function BombController:_logDebug(eventName: string, trackName: string?, force: boolean?)
	if not AnimationConfig.DebugTransitionsEnabled then
		return
	end

	local now = os.clock()
	local key = eventName .. ":" .. (trackName or "")
	local cooldown = AnimationConfig.DebugLogCooldownSeconds or 0
	if not force and now - (self._lastDebugLogTimes[key] or -math.huge) < cooldown then
		return
	end
	self._lastDebugLogTimes[key] = now

	local rootPart = getRootPart()
	local pitch, roll, yaw = getRootAngles(rootPart)
	local velocityY = if rootPart then rootPart.AssemblyLinearVelocity.Y else 0
	local angularVelocity = if rootPart then rootPart.AssemblyAngularVelocity.Magnitude else 0
	local track = if trackName then self._bombTracks[trackName] else nil
	self:_setDebugAttributes(eventName, trackName, pitch, roll)

	warn(string.format(
		"[AnimationDebug] event=%s track=%s holding=%s cooking=%s releasePending=%s pitch=%.1f roll=%.1f yaw=%.1f velY=%.1f angVel=%.2f focus={%s}",
		eventName,
		trackName or "",
		tostring(self._holding),
		tostring(isCooking()),
		tostring(self._releasePending),
		pitch,
		roll,
		yaw,
		velocityY,
		angularVelocity,
		getTrackSummary(track)
	))
end

function BombController:_playTrack(name: string): AnimationTrack?
	local track = self._bombTracks[name]
	if not track then
		return nil
	end

	if not isBombTrackEnabled(name) then
		self:_logDebug("bomb-skip-disabled", name, true)
		return nil
	end

	if track.IsPlaying then
		track:Stop(getBombAnimationFadeOutTime())
	end

	self:_logDebug("bomb-play-before", name, true)
	track:Play(getBombAnimationFadeInTime(), getBombTrackWeight(name), 1)
	track:AdjustSpeed(1)
	self:_logDebug("bomb-play-after", name, true)
	return track
end

function BombController:_connectThrowMarker(track: AnimationTrack)
	self:_disconnectReleaseMarker()
	self._releaseMarkerConnection = track:GetMarkerReachedSignal(AnimationConfig.BombThrowMarkerName):Connect(function()
		self:_logDebug("bomb-throw-marker", "Throw", true)
		self:_fireReleaseFromAnimation()
	end)
end

function BombController:_playThrow()
	self._releasePending = false
	self._releaseFallbackSerial += 1
	self:_disconnectReleaseMarker()
	self:_disconnectAnimationConnections()

	local throwTrack = self:_playTrack("Throw")
	if not throwTrack then
		return
	end

	self:_connectThrowMarker(throwTrack)

	local holdConnection = throwTrack.KeyframeReached:Connect(function(keyframeName: string)
		if keyframeName == AnimationConfig.BombHoldKeyframeName and self._holding and not self._releasePending then
			self:_logDebug("bomb-hold-pause", "Throw", true)
			throwTrack:AdjustSpeed(0)
		end
	end)
	table.insert(self._animationConnections, holdConnection)
end

function BombController:_createPredictedProjectileId(): string
	self._predictedProjectileSerial += 1
	return "Client_" .. tostring(LocalPlayer.UserId) .. "_" .. tostring(self._predictedProjectileSerial)
end

function BombController:_playPredictedLocalThrow(rootPart: BasePart, aimDirection: Vector3): string
	local projectileId = self:_createPredictedProjectileId()
	local currentTime = getServerTime()
	local cookStartedAt = LocalPlayer:GetAttribute(ATTR.CookStartedAt)
	local remainingFuse = BombConfig.FuseSeconds
	local fuseStartedAt = currentTime
	if typeof(cookStartedAt) == "number" and cookStartedAt > 0 then
		fuseStartedAt = cookStartedAt
		remainingFuse = math.max(BombConfig.FuseSeconds - (currentTime - cookStartedAt), 0.05)
	end

	self:_playThrowEffect({
		player = LocalPlayer,
		projectileId = projectileId,
		customProjectile = true,
		bombSkinId = getPlayerBombSkinId(LocalPlayer),
		origin = getThrowOrigin(rootPart),
		position = getThrowOrigin(rootPart),
		initialVelocity = getProjectileLaunchVelocity(aimDirection),
		velocity = getProjectileLaunchVelocity(aimDirection),
		acceleration = Vector3.new(0, -(workspace.Gravity * BombConfig.ProjectileGravityScale), 0),
		startedAt = currentTime,
		fuseStartedAt = fuseStartedAt,
		remainingFuse = remainingFuse,
	})
	RuntimeProfiler.Count("Client/BombController/ProjectilePredictionStarted")

	return projectileId
end

function BombController:_fireReleaseFromAnimation()
	if not self._releasePending then
		return
	end

	self._releasePending = false
	self._releaseFallbackSerial += 1
	self:_disconnectReleaseMarker()
	self:_stopPreview()

	local abilityReleaseCallback = self._abilityReleaseCallback
	if abilityReleaseCallback then
		abilityReleaseCallback()
	elseif self._releaseRemote then
		local rootPart = getRootPart()
		if rootPart then
			local aimDirection = getMouseAimDirection()
			local clientProjectileId = self:_playPredictedLocalThrow(rootPart, aimDirection)
			self._releaseRemote:FireServer({
				aimDirection = aimDirection,
				clientProjectileId = clientProjectileId,
			})
		else
			self._releaseRemote:FireServer(getAimDirection())
		end
	end
	self.ThrowReleased:Fire()
	CameraController:PlayBombThrowPunch()

	self:_clearBombAnimationState()
end

function BombController:_playRelease()
	local throwTrack = self._bombTracks.Throw
	if throwTrack and not throwTrack.IsPlaying then
		self:_playThrow()
		throwTrack = self._bombTracks.Throw
	end

	self._releasePending = true
	self._releaseFallbackSerial += 1
	local serial = self._releaseFallbackSerial

	if throwTrack then
		self:_logDebug("bomb-release-resume", "Throw", true)
		throwTrack:AdjustSpeed(1)
	end

	task.delay(AnimationConfig.BombReleaseFallbackSeconds, function()
		if serial == self._releaseFallbackSerial and self._releasePending then
			self:_logDebug("bomb-release-fallback", "Throw", true)
			self:_fireReleaseFromAnimation()
		end
	end)
end

function BombController:_showTrajectoryPreview(
	trajectory: BombTrajectory.Path,
	maxPreviewTime: number,
	color: Color3,
	previewIndex: number?
): boolean
	local index = math.max(math.floor(previewIndex or 1), 1)
	maxPreviewTime = math.min(maxPreviewTime, trajectory.duration)
	if maxPreviewTime <= 0 then
		local existing = if index <= 1 then self._trajectoryPreview else self._extraTrajectoryPreviews[index - 1]
		if existing then
			setTrajectoryPreviewEnabled(existing, false)
		end
		return false
	end

	local preview = self:_ensureTrajectoryPreviewAt(index)
	if not preview then
		return false
	end

	local origin = trajectory.origin
	local hit, endElapsed = findPreviewTrajectoryHit(trajectory, maxPreviewTime)
	local endAlpha = math.clamp(endElapsed / trajectory.duration, 0, 1)
	local endPosition = if hit then hit.Position else BombTrajectory.Evaluate(trajectory, endAlpha)
	local startVelocity = BombTrajectory.GetVelocity(trajectory, 0)
	local endVelocity = BombTrajectory.GetVelocity(trajectory, endAlpha)
	local reversePathDirection = origin - endPosition

	preview.startPart.CFrame = cframeFromRightVector(origin, getUnitOrFallback(-startVelocity, reversePathDirection))
	preview.endPart.CFrame = cframeFromRightVector(endPosition, getUnitOrFallback(-endVelocity, reversePathDirection))

	local startCurveSize = startVelocity.Magnitude * endElapsed / 3
	local endCurveSize = endVelocity.Magnitude * endElapsed / 3
	for _, beam in ipairs(preview.beams) do
		beam.CurveSize0 = endCurveSize
		beam.CurveSize1 = startCurveSize
	end

	if not preview.custom then
		tintTrajectoryPreview(preview, color)
	end
	setTrajectoryPreviewEnabled(preview, true)
	return true
end

function BombController:_updatePreview()
	if not self._holding and not isCooking() then
		self:_stopPreview()
		return
	end

	local rootPart = getRootPart()
	if not rootPart then
		self:_cancelHoldIfInvalid()
		self:_stopPreview()
		return
	end

	local cookStartedAt = LocalPlayer:GetAttribute(ATTR.CookStartedAt)
	local elapsed = if typeof(cookStartedAt) == "number" and cookStartedAt > 0 then getServerTime() - cookStartedAt else 0
	local remaining = math.max(BombConfig.FuseSeconds - elapsed, 0)
	if remaining <= 0 then
		self:_stopPreview()
		return
	end

	local origin = getThrowOrigin(rootPart)
	local trajectory = calculateTrajectory(origin, getMouseAimDirection())
	local maxPreviewTime = math.min(remaining, trajectory.duration, BombConfig.PreviewMaxSeconds)
	if maxPreviewTime <= 0 then
		self:_stopPreview()
		return
	end

	local dangerAlpha = 1 - math.clamp(remaining / BombConfig.FuseSeconds, 0, 1)
	local color = BombConfig.PreviewColor:Lerp(BombConfig.PreviewDangerColor, dangerAlpha)
	self:_showTrajectoryPreview(trajectory, maxPreviewTime, color)
end

function BombController:_requestBegin()
	if not self:_canBeginBombHold(false) then
		return false
	end

	self._holding = true
	self:_startPreview()
	self:_playThrow()

	if self._beginRemote then
		self._beginRemote:FireServer()
	end

	self.HoldStarted:Fire()
	return true
end

function BombController:_requestRelease()
	if not self._holding then
		return false
	end

	self._holding = false
	self:_setHeldBombEffects(LocalPlayer, true, false)
	self:_playRelease()
	self.HoldReleased:Fire()
	return true
end

function BombController:GetThrowAimDirection(): Vector3
	return getMouseAimDirection()
end

function BombController:GetThrowOrigin(): Vector3?
	local rootPart = getRootPart()
	return if rootPart then getThrowOrigin(rootPart) else nil
end

function BombController:ShowAbilityTrajectoryPreview(options: AbilityTrajectoryPreviewOptions?): boolean
	local rootPart = getRootPart()
	if not rootPart then
		self:HideAbilityTrajectoryPreview()
		return false
	end

	options = options or {}
	local origin = getThrowOrigin(rootPart)
	local launchSpeed = if typeof(options.launchSpeed) == "number"
		then math.max(options.launchSpeed, 0.001)
		else BombConfig.ProjectileLaunchSpeed
	local upwardVelocity = if typeof(options.upwardVelocity) == "number"
		then math.max(options.upwardVelocity, 0)
		else BombConfig.ProjectileUpwardVelocity
	local gravity = if typeof(options.gravity) == "number"
		then math.max(options.gravity, 0.001)
		else workspace.Gravity * BombConfig.ProjectileGravityScale
	local maxFlightSeconds = if typeof(options.maxFlightSeconds) == "number"
		then math.max(options.maxFlightSeconds, 0.001)
		else BombConfig.ProjectileMaxFlightSeconds
	local color = if typeof(options.color) == "Color3" then options.color else BombConfig.PreviewColor

	local aimDirections = {}
	if typeof(options.aimDirections) == "table" then
		for _, aimDirection in ipairs(options.aimDirections) do
			if typeof(aimDirection) == "Vector3" and aimDirection.Magnitude > 0.05 then
				table.insert(aimDirections, sanitizeAimDirection(aimDirection, getMouseAimDirection()))
			end
		end
	elseif typeof(options.aimDirection) == "Vector3" and options.aimDirection.Magnitude > 0.05 then
		table.insert(aimDirections, sanitizeAimDirection(options.aimDirection, getMouseAimDirection()))
	end
	if #aimDirections == 0 then
		table.insert(aimDirections, getMouseAimDirection())
	end

	local anyShown = false
	for index, aimDirection in ipairs(aimDirections) do
		local trajectory = calculateTrajectoryWithConfig(
			origin,
			aimDirection,
			launchSpeed,
			upwardVelocity,
			gravity,
			maxFlightSeconds
		)
		local maxPreviewTime = if typeof(options.maxPreviewTime) == "number"
			then math.min(math.max(options.maxPreviewTime, 0), trajectory.duration)
			else math.min(trajectory.duration, BombConfig.PreviewMaxSeconds)
		anyShown = self:_showTrajectoryPreview(trajectory, maxPreviewTime, color, index) or anyShown
	end
	self:_hideExtraTrajectoryPreviews(#aimDirections)

	return anyShown
end

function BombController:HideAbilityTrajectoryPreview()
	if self._previewing then
		return
	end
	if self._trajectoryPreview then
		setTrajectoryPreviewEnabled(self._trajectoryPreview, false)
	end
	self:_hideExtraTrajectoryPreviews(1)
end

function BombController:_canBeginAbilityThrowHold(): boolean
	if not self._started then
		return false
	end
	if self._holding or self._releasePending or isCooking() then
		return false
	end
	if not isRoundActiveForLocalPlayer() then
		return false
	end

	local _, humanoid, rootPart = getCharacterParts()
	return humanoid ~= nil and humanoid.Health > 0 and rootPart ~= nil
end

function BombController:SetPrimaryBombInputSuppressed(suppressed: boolean)
	self._primaryBombInputSuppressed = suppressed == true
end

function BombController:BeginAbilityThrowHold(): boolean
	if not self:_canBeginAbilityThrowHold() then
		return false
	end

	self._holding = true
	self._abilityThrowActive = true
	self._abilityReleaseCallback = nil
	self:_showHeldBomb(LocalPlayer, nil)
	self:_setHeldBombEffects(LocalPlayer, false, false)
	self:_playThrow()
	self.HoldStarted:Fire()
	return true
end

function BombController:ReleaseAbilityThrowHold(releaseCallback: () -> ()): boolean
	if not (self._abilityThrowActive and self._holding) then
		return false
	end

	self._holding = false
	self._abilityReleaseCallback = releaseCallback
	self:_setHeldBombEffects(LocalPlayer, true, false)
	self:_playRelease()
	self.HoldReleased:Fire()
	return true
end

function BombController:CancelAbilityThrowHold(): boolean
	if not self._abilityThrowActive then
		return false
	end

	self:ResetLocalHeldBombVisualScale()
	self:_clearBombAnimationState()
	self:_stopPreview()
	self.HoldReleased:Fire()
	return true
end

function BombController:BeginBombHold(): boolean
	return self:_requestBegin()
end

function BombController:ReleaseBombHold(): boolean
	return self:_requestRelease()
end

function BombController:IsHoldingBomb(): boolean
	return self._holding == true
end

function BombController:_handleAction(_actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
	if self._primaryBombInputSuppressed then
		return Enum.ContextActionResult.Sink
	end
	if inputState == Enum.UserInputState.Begin and isPrimaryBombInputOverGui(inputObject) then
		return Enum.ContextActionResult.Pass
	end

	if inputState == Enum.UserInputState.Begin then
		self:BeginBombHold()
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		self:ReleaseBombHold()
	end

	return Enum.ContextActionResult.Sink
end

function BombController:_getEmitModule()
	if self._emitModule then
		return self._emitModule
	end

	local packages = ReplicatedStorage:WaitForChild("Packages", 10)
	local moduleScript = packages and packages:WaitForChild("EmitModule", 10)
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		if not self._warnedMissingEmitModule then
			self._warnedMissingEmitModule = true
			warn("[BombController] Missing ReplicatedStorage.Packages.EmitModule")
		end
		return nil
	end

	local ok, emitModule = pcall(require, moduleScript)
	if not ok then
		if not self._warnedMissingEmitModule then
			self._warnedMissingEmitModule = true
			warn("[BombController] Failed to require EmitModule: " .. tostring(emitModule))
		end
		return nil
	end

	self._emitModule = emitModule
	return emitModule
end

function BombController:_ensureEmitModuleInitialized(emitModule): boolean
	if self._emitModuleInitialized then
		return true
	end
	if type(emitModule.init) ~= "function" then
		self._emitModuleInitialized = true
		return true
	end

	local ok, err = pcall(function()
		emitModule.init()
	end)
	if not ok then
		warn("[BombController] Failed to initialize EmitModule: " .. tostring(err))
		return false
	end

	self._emitModuleInitialized = true
	return true
end

function BombController:_getExplosionVfxFolder(): Folder
	local existing = workspace:FindFirstChild(EXPLOSION_VFX_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = EXPLOSION_VFX_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

function BombController:_playExplosionEffect(position: Vector3, skinId: any, visualScale: number?, assetPath: any?)
	local emitModule = self:_getEmitModule()
	if emitModule and not self:_ensureEmitModuleInitialized(emitModule) then
		emitModule = nil
	end

	local result = BombVisualUtil.PlayExplosionEffect({
		parent = self:_getExplosionVfxFolder(),
		position = position,
		skinId = skinId,
		assetPath = assetPath,
		emitModule = emitModule,
		name = "BombExplosionVFX",
		cleanupSeconds = EXPLOSION_VFX_CLEANUP_SECONDS,
		visualScale = visualScale,
		warnPrefix = "[BombController]",
	})
	if not result.template and not self._warnedMissingExplosionVfx then
		self._warnedMissingExplosionVfx = true
		warn("[BombController] Missing bomb explosion VFX template and default fallback")
	end
	if emitModule and not result.emitted then
		if not self._warnedMissingExplosionVfx then
			self._warnedMissingExplosionVfx = true
			warn("[BombController] Bomb explosion VFX was not emitted")
		end
	end
end

function BombController:_getProjectileVisualFolder(): Folder
	if self._projectileVisualFolder and self._projectileVisualFolder.Parent then
		return self._projectileVisualFolder
	end

	local folder = Instance.new("Folder")
	folder.Name = PROJECTILE_VISUAL_FOLDER_NAME
	folder.Parent = workspace
	self._projectileVisualFolder = folder
	return folder
end

function BombController:_setProjectileVisualCFrame(visual, position: Vector3, tangent: Vector3, spin: number)
	if tangent.Magnitude < 0.05 then
		tangent = Vector3.zAxis
	else
		tangent = tangent.Unit
	end
	local cframe = CFrame.lookAt(position, position + tangent) * CFrame.Angles(spin, spin * 0.35, 0)
	if visual.instance:IsA("Model") then
		visual.instance:PivotTo(cframe)
	else
		visual.rootPart.CFrame = cframe
	end
end

local function smoothstep(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * (3 - 2 * alpha)
end

local function setInstanceLocalTransparency(instance: Instance?, alpha: number)
	if not instance then
		return
	end

	alpha = math.clamp(alpha, 0, 1)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = alpha
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = alpha
		end
	end
end

local function pivotInstanceToCFrame(instance: Instance, rootPart: BasePart, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	else
		rootPart.CFrame = cframe
	end
end

local function getVisualNumber(visual, key: string, fallback: number): number
	local visuals = visual and visual.visuals
	local value = if typeof(visuals) == "table" then visuals[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getVisualColor(visual, key: string, fallback: Color3): Color3
	local visuals = visual and visual.visuals
	local value = if typeof(visuals) == "table" then visuals[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

local function getProjectileSpinSpeed(visual): number
	local fallback = BombConfig.VisualSpinRadiansPerSecond
	if visual and visual.burrowing == true then
		return getVisualNumber(visual, "burrowSpinRadiansPerSecond", fallback * 2.4)
	end
	return getVisualNumber(visual, "spinRadiansPerSecond", fallback)
end

local function getProjectileVisualTimeScale(visual): number
	local timeScale = if visual and typeof(visual.timeScale) == "number" then visual.timeScale else 1
	return math.clamp(timeScale, 0.005, 1)
end

local function updateProjectileVisualTimeScale(visual, deltaTime: number): number
	local currentTimeScale = getProjectileVisualTimeScale(visual)
	local targetTimeScale = math.clamp(
		if visual and typeof(visual.targetTimeScale) == "number" then visual.targetTimeScale else 1,
		0.005,
		1
	)
	local rate = if targetTimeScale < currentTimeScale then PROJECTILE_TIME_SCALE_ENTER_RATE else PROJECTILE_TIME_SCALE_EXIT_RATE
	local alpha = 1 - math.exp(-rate * math.max(deltaTime, 0))
	local nextTimeScale = currentTimeScale + (targetTimeScale - currentTimeScale) * math.clamp(alpha, 0, 1)
	if math.abs(nextTimeScale - targetTimeScale) < 0.001 then
		nextTimeScale = targetTimeScale
	end
	visual.timeScale = math.clamp(nextTimeScale, 0.005, 1)
	return visual.timeScale
end

function BombController:_getBombPulseProgress(visual): (number, number)
	local fuseStartedAt = visual.fuseStartedAt or getServerTime()
	local fuseEndsAt = visual.fuseEndsAt or (fuseStartedAt + BombConfig.FuseSeconds)
	local fuseDuration = math.max(fuseEndsAt - fuseStartedAt, 0.001)
	local elapsed = math.clamp(getServerTime() - fuseStartedAt, 0, fuseDuration)
	return elapsed / fuseDuration, elapsed
end

function BombController:_getBombPulseColor(visual, fuseProgress: number?, elapsed: number?): Color3
	local progress = if typeof(fuseProgress) == "number" then math.clamp(fuseProgress, 0, 1) else 0
	local pulseElapsed = if typeof(elapsed) == "number" then math.max(elapsed, 0) else 0
	local startHz = math.max(BombConfig.PulseStartHz, 0.01)
	local endHz = math.max(BombConfig.PulseEndHz, startHz)
	local cycles = (startHz * pulseElapsed) + (0.5 * (endHz - startHz) * progress * pulseElapsed)
	local alpha = (1 - math.cos(cycles * math.pi * 2)) * 0.5
	local baseColor = getVisualColor(visual, "highlightColor", BombConfig.PulseWhite)
	return baseColor:Lerp(BombConfig.PulseRed, alpha)
end

function BombController:_updateBombPulse(visual)
	local highlight = visual.highlight
	if not (highlight and highlight.Parent) then
		return
	end

	if visual.frozen == true then
		highlight.FillColor = FROZEN_BOMB_COLOR
		highlight.OutlineColor = FROZEN_BOMB_COLOR
		highlight.FillTransparency = FROZEN_BOMB_FILL_TRANSPARENCY
		highlight.OutlineTransparency = FROZEN_BOMB_OUTLINE_TRANSPARENCY
		return
	end

	local fuseProgress, elapsed = self:_getBombPulseProgress(visual)
	local color = self:_getBombPulseColor(visual, fuseProgress, elapsed)
	local fillStart = getVisualNumber(visual, "highlightFillTransparency", BombConfig.PulseStartFillTransparency)
	local outlineStart = getVisualNumber(visual, "highlightOutlineTransparency", BombConfig.PulseStartOutlineTransparency)
	local fillTransparency = fillStart
		+ ((BombConfig.PulseEndFillTransparency - BombConfig.PulseStartFillTransparency) * fuseProgress)
	local outlineTransparency = outlineStart
		+ ((BombConfig.PulseEndOutlineTransparency - BombConfig.PulseStartOutlineTransparency) * fuseProgress)

	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = math.clamp(fillTransparency, 0, 1)
	highlight.OutlineTransparency = math.clamp(outlineTransparency, 0, 1)
end

function BombController:_stopBombPulse(visual)
	if visual.pulseConnection then
		visual.pulseConnection:Disconnect()
		visual.pulseConnection = nil
	end
	if visual.highlight and visual.highlight.Parent then
		visual.highlight:Destroy()
	end
	visual.highlight = nil
end

function BombController:_startBombPulse(visual, adornee: Instance, fuseStartedAt: number, fuseEndsAt: number)
	self:_stopBombPulse(visual)

	local highlight = Instance.new("Highlight")
	highlight.Name = "BombFuseHighlight"
	highlight.Adornee = adornee
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillTransparency = BombConfig.PulseStartFillTransparency
	highlight.OutlineTransparency = BombConfig.PulseStartOutlineTransparency
	highlight.Parent = adornee

	visual.highlight = highlight
	visual.fuseStartedAt = fuseStartedAt
	visual.fuseEndsAt = fuseEndsAt
	self:_updateBombPulse(visual)

	visual.pulseConnection = RunService.RenderStepped:Connect(function()
		local token = RuntimeProfiler.Begin("Client/BombController/BombPulse")
		self:_updateBombPulse(visual)
		RuntimeProfiler.End("Client/BombController/BombPulse", token)
	end)
end

function BombController:_findPhysicalProjectile(projectileId: string, physicalProjectile: any): (Instance?, BasePart?)
	if typeof(physicalProjectile) == "Instance" then
		local rootPart = BombVisualUtil.GetRootPart(physicalProjectile)
		if rootPart then
			return physicalProjectile, rootPart
		end
	end

	local folder = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	local projectile = folder and folder:FindFirstChild("BombProjectile_" .. projectileId)
	if projectile then
		local rootPart = BombVisualUtil.GetRootPart(projectile)
		if rootPart then
			return projectile, rootPart
		end
	end

	return nil, nil
end

function BombController:_transferProjectilePulseToPhysical(projectileId: string, physicalProjectile: any): boolean
	local visual = self._projectileVisuals[projectileId]
	if not visual then
		return false
	end

	local projectile, rootPart = self:_findPhysicalProjectile(projectileId, physicalProjectile)
	if not (projectile and rootPart) then
		return false
	end

	if visual.instance == projectile and visual.ownsInstance == false then
		return true
	end

	if visual.handoffConnection then
		return true
	end

	local airborneInstance = visual.instance
	local airborneRootPart = visual.rootPart
	if not (visual.ownsInstance and airborneInstance and airborneInstance.Parent and airborneRootPart and airborneRootPart.Parent) then
		visual.instance = projectile
		visual.rootPart = rootPart
		visual.path = nil
		visual.ownsInstance = false
		self:_syncAbilityVisualOverlay(visual)
		setInstanceLocalTransparency(projectile, 0)
		self:_syncProjectileBaseVisual(visual)
		BombVisualUtil.SetEffectState(projectile, {
			vfx = true,
			fuseSpark = true,
			trail = true,
		})
		self:_startBombPulse(
			visual,
			projectile,
			visual.fuseStartedAt or getServerTime(),
			visual.fuseEndsAt or (getServerTime() + BombConfig.ProjectileLifetimePadding)
		)
		self:_syncProjectileBaseVisual(visual)
		return true
	end

	visual.handoffPhysical = projectile
	RuntimeProfiler.Count("Client/BombController/ProjectilePhysicalHandoffStarted")
	setInstanceLocalTransparency(projectile, 1)
	BombVisualUtil.SetEffectState(projectile, {
		vfx = false,
		fuseSpark = false,
		trail = false,
	})

	local startCFrame = airborneRootPart.CFrame
	local elapsed = 0
	local duration = PROJECTILE_PHYSICAL_HANDOFF_SECONDS
	visual.handoffConnection = RunService.RenderStepped:Connect(function(deltaTime)
		if not (projectile.Parent and rootPart.Parent and airborneInstance.Parent and airborneRootPart.Parent) then
			if visual.handoffConnection then
				visual.handoffConnection:Disconnect()
				visual.handoffConnection = nil
			end
			setInstanceLocalTransparency(projectile, 0)
			visual.handoffPhysical = nil
			RuntimeProfiler.Count("Client/BombController/ProjectilePhysicalHandoffFailed")
			return
		end

		elapsed += math.max(deltaTime, 0)
		local alpha = smoothstep(elapsed / duration)
		local physicalCFrame = rootPart.CFrame
		local blendedCFrame = startCFrame:Lerp(physicalCFrame, alpha)
		pivotInstanceToCFrame(airborneInstance, airborneRootPart, blendedCFrame)
		setInstanceLocalTransparency(airborneInstance, alpha)
		setInstanceLocalTransparency(projectile, 1 - alpha)

		if alpha >= 1 or elapsed >= PROJECTILE_PHYSICAL_HANDOFF_MAX_SECONDS then
			if visual.handoffConnection then
				visual.handoffConnection:Disconnect()
				visual.handoffConnection = nil
			end
			if visual.connection then
				visual.connection:Disconnect()
				visual.connection = nil
			end

			BombVisualUtil.SetEffectState(projectile, {
				vfx = true,
				fuseSpark = true,
				trail = true,
			})
			if airborneInstance.Parent then
				airborneInstance:Destroy()
			end

			visual.instance = projectile
			visual.rootPart = rootPart
			visual.path = nil
			visual.ownsInstance = false
			self:_syncAbilityVisualOverlay(visual)
			self:_startBombPulse(
				visual,
				projectile,
				visual.fuseStartedAt or getServerTime(),
				visual.fuseEndsAt or (getServerTime() + BombConfig.ProjectileLifetimePadding)
			)
			visual.handoffPhysical = nil
			visual.position = rootPart.Position
			visual.velocity = rootPart.AssemblyLinearVelocity
			visual.targetPosition = visual.position
			visual.targetVelocity = visual.velocity
			RuntimeProfiler.Count("Client/BombController/ProjectilePhysicalHandoffCompleted")
			self:_syncProjectileBaseVisual(visual)
		end
	end)

	local skinId = BombSkinConfig.NormalizeSkinId(projectile:GetAttribute("BombSkinId"))
	if skinId ~= "" then
		visual.skinId = skinId
	end
	return true
end

function BombController:_retryTransferProjectilePulseToPhysical(projectileId: string, physicalProjectile: any)
	task.delay(0.08, function()
		local visual = self._projectileVisuals[projectileId]
		if not visual or not visual.ownsInstance then
			return
		end

		self:_transferProjectilePulseToPhysical(projectileId, physicalProjectile)
	end)
end

function BombController:_createProjectileVisual(projectileId: string, skinId: any, visualScale: number?)
	local resolvedSkinId = BombSkinConfig.NormalizeSkinId(skinId)
	if resolvedSkinId == "" then
		resolvedSkinId = BombSkinConfig.DefaultSkinId
	end
	local resolvedVisualScale = math.max(tonumber(visualScale) or BombConfig.ProjectileVisualScale, 0.05)
	local instance, rootPart = createBombVisualInstance(resolvedSkinId, "BombProjectile_" .. projectileId, {
		vfx = true,
		fuseSpark = true,
		trail = true,
	}, resolvedVisualScale)

	if not rootPart then
		instance:Destroy()
		return nil
	end

	instance.Name = "BombProjectile_" .. projectileId
	if instance:IsA("Model") then
		instance.PrimaryPart = rootPart
	end

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

	instance.Parent = self:_getProjectileVisualFolder()
	return {
		instance = instance,
		rootPart = rootPart,
		connection = nil,
		path = nil,
		customProjectile = false,
		position = nil,
		velocity = nil,
		targetPosition = nil,
		targetVelocity = nil,
		acceleration = nil,
		settled = false,
		spin = 0,
		spinLocked = false,
		ownsInstance = true,
		skinId = resolvedSkinId,
		highlight = nil,
		pulseConnection = nil,
		handoffConnection = nil,
		handoffPhysical = nil,
		fuseStartedAt = nil,
		fuseEndsAt = nil,
		abilityVisualOverlay = nil,
		frozen = false,
		frozenUntil = nil,
		visuals = nil,
		visualScale = resolvedVisualScale,
		burrowing = false,
		timeScale = 1,
		targetTimeScale = 1,
	}
end

function BombController:_destroyProjectileVisual(projectileId: string)
	local visual = self._projectileVisuals[projectileId]
	if not visual then
		return
	end

	if visual.connection then
		visual.connection:Disconnect()
	end
	if visual.handoffConnection then
		visual.handoffConnection:Disconnect()
	end
	if visual.handoffPhysical then
		setInstanceLocalTransparency(visual.handoffPhysical, 0)
		BombVisualUtil.SetEffectState(visual.handoffPhysical, {
			vfx = true,
			fuseSpark = true,
			trail = true,
		})
	end
	self:_stopBombPulse(visual)
	self:_destroyAbilityVisualOverlay(visual)
	if visual.ownsInstance and visual.instance.Parent then
		visual.instance:Destroy()
	end
	self._projectileVisuals[projectileId] = nil
end

function BombController:_playThrowEffect(payload)
	if typeof(payload) ~= "table" then
		return
	end

	local projectileId = payload.projectileId
	if typeof(projectileId) ~= "string" then
		return
	end

	local customProjectile = payload.customProjectile == true
	local path = if customProjectile then nil else BombTrajectory.FromPayload(payload)
	if not customProjectile and not path then
		return
	end
	local startPosition = if typeof(payload.position) == "Vector3" then payload.position else payload.origin
	if customProjectile and typeof(startPosition) ~= "Vector3" then
		return
	end

	local visual = self._projectileVisuals[projectileId]
	local reusePredictedVisual = customProjectile
		and visual ~= nil
		and visual.ownsInstance == true
		and visual.customProjectile == true
		and visual.handoffConnection == nil
	if not reusePredictedVisual then
		self:_destroyProjectileVisual(projectileId)
		visual = self:_createProjectileVisual(projectileId, payload.bombSkinId, payload.visualScale)
		if not visual then
			return
		end
		self._projectileVisuals[projectileId] = visual
	else
		RuntimeProfiler.Count("Client/BombController/ProjectilePredictionReconciled")
	end

	visual.path = path
	visual.customProjectile = customProjectile
	visual.visuals = if typeof(payload.visuals) == "table" then payload.visuals else nil
	visual.visualScale = if typeof(payload.visualScale) == "number" then math.max(payload.visualScale, 0.05) else visual.visualScale
	self:_syncAbilityVisualOverlay(visual)
	self:_syncProjectileBaseVisual(visual)
	if customProjectile then
		local velocity = if typeof(payload.velocity) == "Vector3" then payload.velocity else payload.initialVelocity
		local acceleration = if typeof(payload.acceleration) == "Vector3" then payload.acceleration else Vector3.new(0, -workspace.Gravity, 0)
		local resolvedVelocity = if typeof(velocity) == "Vector3" then velocity else Vector3.zero
		if reusePredictedVisual then
			visual.targetPosition = startPosition
			visual.targetVelocity = resolvedVelocity
		else
			visual.position = startPosition
			visual.velocity = resolvedVelocity
			visual.targetPosition = visual.position
			visual.targetVelocity = visual.velocity
		end
		visual.acceleration = acceleration
		visual.settled = false
	end

	local startedAt = if typeof(payload.startedAt) == "number" then payload.startedAt else getServerTime()
	local lifetime = if typeof(payload.remainingFuse) == "number" then payload.remainingFuse else BombConfig.FuseSeconds
	local fuseStartedAt = if typeof(payload.fuseStartedAt) == "number" then payload.fuseStartedAt else startedAt
	local fuseEndsAt = startedAt + lifetime
	self:_startBombPulse(visual, visual.instance, fuseStartedAt, fuseEndsAt)
	self:_syncProjectileBaseVisual(visual)
	local rootPart = visual.rootPart

	if visual.connection then
		return
	end

	visual.connection = RunService.RenderStepped:Connect(function(deltaTime)
		local token = RuntimeProfiler.Begin("Client/BombController/ProjectileVisual")
		local visualTimeScale = updateProjectileVisualTimeScale(visual, deltaTime)
		if not visual.spinLocked then
			visual.spin += deltaTime * getProjectileSpinSpeed(visual) * visualTimeScale
		end
		if visual.customProjectile then
			local position = visual.position or visual.targetPosition or rootPart.Position
			local velocity = visual.velocity or visual.targetVelocity or Vector3.zero
			if visual.settled then
				position = visual.targetPosition or position
				velocity = Vector3.zero
			else
				local acceleration = visual.acceleration or Vector3.zero
				local motionDt = deltaTime * visualTimeScale
				velocity += acceleration * motionDt
				position += velocity * motionDt

				local correctionScale = math.clamp(0.15 + visualTimeScale * 0.85, 0.15, 1)
				local positionAlpha = 1 - math.exp(-18 * deltaTime * correctionScale)
				local velocityAlpha = 1 - math.exp(-14 * deltaTime * correctionScale)
				if typeof(visual.targetPosition) == "Vector3" then
					position = position:Lerp(visual.targetPosition, positionAlpha)
				end
				if typeof(visual.targetVelocity) == "Vector3" then
					velocity = velocity:Lerp(visual.targetVelocity, velocityAlpha)
				end
			end

			visual.position = position
			visual.velocity = velocity
			if not visual.handoffConnection then
				local tangent = if velocity.Magnitude > 0.05 then velocity else visual.targetVelocity or Vector3.zAxis
				self:_setProjectileVisualCFrame(visual, position, tangent, visual.spin)
			end
		elseif path then
			local alpha = math.clamp((getServerTime() - startedAt) / path.duration, 0, 1)
			local position = BombTrajectory.Evaluate(path, alpha)
			local tangent = BombTrajectory.GetTangent(path, alpha)
			self:_setProjectileVisualCFrame(visual, position, tangent, visual.spin)
		end
		RuntimeProfiler.End("Client/BombController/ProjectileVisual", token)
	end)

	local cleanupDelay = lifetime + BombConfig.ProjectileLifetimePadding + (if customProjectile then 10 else 0)
	task.delay(cleanupDelay, function()
		self:_destroyProjectileVisual(projectileId)
	end)
end

function BombController:_playImpactEffect(position: Vector3)
	local part = Instance.new("Part")
	part.Name = "BombImpactEffect"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.45, 0.45, 0.45)
	part.CFrame = CFrame.new(position)
	part.Material = Enum.Material.Neon
	part.Color = BombConfig.PreviewColor
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 0.15
	part.Parent = workspace

	local tween = TweenService:Create(part, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(3, 3, 3),
		Transparency = 1,
	})
	tween.Completed:Connect(function()
		part:Destroy()
	end)
	tween:Play()
end

function BombController:_playDrillPulse(position: Vector3, radius: number?, color: Color3?, duration: number?)
	local part = Instance.new("Part")
	part.Name = "DrillBombPulse"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.35, 0.35, 0.35)
	part.CFrame = CFrame.new(position)
	part.Material = Enum.Material.Neon
	part.Color = color or Color3.fromRGB(255, 207, 84)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 0.2
	part.Parent = workspace

	local finalRadius = math.max(radius or 4, 0.5)
	local tween = TweenService:Create(part, TweenInfo.new(duration or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(finalRadius, finalRadius, finalRadius),
		Transparency = 1,
	})
	tween.Completed:Connect(function()
		part:Destroy()
	end)
	tween:Play()
end

function BombController:_playDrillTrail(fromPosition: Vector3, toPosition: Vector3, radius: number?, color: Color3?)
	local delta = toPosition - fromPosition
	local distance = delta.Magnitude
	if distance <= 0.05 then
		self:_playDrillPulse(toPosition, radius, color, 0.12)
		return
	end

	local part = Instance.new("Part")
	part.Name = "DrillBombTrail"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(math.max(radius or 1.8, 0.2), distance, math.max(radius or 1.8, 0.2))
	part.CFrame = CFrame.lookAt(fromPosition + delta * 0.5, toPosition) * CFrame.Angles(math.pi / 2, 0, 0)
	part.Material = Enum.Material.Neon
	part.Color = color or Color3.fromRGB(255, 207, 84)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 0.58
	part.Parent = workspace

	local tween = TweenService:Create(part, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(part.Size.X * 1.6, part.Size.Y, part.Size.Z * 1.6),
		Transparency = 1,
	})
	tween.Completed:Connect(function()
		part:Destroy()
	end)
	tween:Play()
end

function BombController:_handleProjectileSnapshot(payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end
	if payload.customProjectile ~= true then
		return
	end
	if typeof(payload.position) ~= "Vector3" then
		return
	end

	local projectileId = payload.projectileId
	local visual = self._projectileVisuals[projectileId]
	if not visual then
		self:_playThrowEffect({
			player = payload.player,
			projectileId = projectileId,
			customProjectile = true,
			position = payload.position,
			velocity = if typeof(payload.velocity) == "Vector3" then payload.velocity else Vector3.zero,
			acceleration = Vector3.new(0, -workspace.Gravity, 0),
			startedAt = if typeof(payload.serverTime) == "number" then payload.serverTime else getServerTime(),
			fuseStartedAt = if typeof(payload.serverTime) == "number" then payload.serverTime else getServerTime(),
			remainingFuse = if typeof(payload.remainingFuse) == "number" then payload.remainingFuse else BombConfig.FuseSeconds,
			bombSkinId = payload.bombSkinId,
			visuals = payload.visuals,
		})
		visual = self._projectileVisuals[projectileId]
		if not visual then
			return
		end
	end

	if payload.physicalProjectile then
		if self:_transferProjectilePulseToPhysical(projectileId, payload.physicalProjectile) then
			return
		end
		self:_retryTransferProjectilePulseToPhysical(projectileId, payload.physicalProjectile)
	end

	visual.customProjectile = true
	if typeof(payload.visuals) == "table" then
		visual.visuals = payload.visuals
		self:_syncAbilityVisualOverlay(visual)
		self:_syncProjectileBaseVisual(visual)
	end
	local wasFrozen = visual.frozen == true
	local frozen = payload.frozen == true
	local timeScale = math.clamp(if typeof(payload.timeScale) == "number" then payload.timeScale else 1, 0.005, 1)
	visual.burrowing = payload.burrowing == true
	visual.frozen = frozen
	visual.frozenUntil = if typeof(payload.frozenUntil) == "number" then payload.frozenUntil else nil
	visual.targetTimeScale = timeScale
	visual.targetPosition = payload.position
	visual.targetVelocity = if frozen then Vector3.zero elseif typeof(payload.velocity) == "Vector3" then payload.velocity else Vector3.zero
	if payload.attached == true then
		visual.spinLocked = true
	elseif frozen then
		visual.spinLocked = true
	elseif wasFrozen then
		visual.spinLocked = false
	end
	if typeof(payload.acceleration) == "Vector3" then
		visual.acceleration = if frozen then Vector3.zero else payload.acceleration
	end
	visual.settled = frozen or payload.settled == true
	if visual.position == nil or visual.settled or frozen then
		visual.position = payload.position
	end
	if visual.velocity == nil or visual.settled or frozen then
		visual.velocity = visual.targetVelocity
	end
	if wasFrozen and not frozen and typeof(payload.serverTime) == "number" and typeof(payload.remainingFuse) == "number" then
		visual.fuseStartedAt = payload.serverTime
		visual.fuseEndsAt = payload.serverTime + math.max(payload.remainingFuse, 0)
	end
	self:_updateBombPulse(visual)
end

function BombController:_handleProjectileAttach(payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end
	if payload.customProjectile ~= true or typeof(payload.position) ~= "Vector3" then
		return
	end

	local projectileId = payload.projectileId
	local visual = self._projectileVisuals[projectileId]
	if not visual then
		self:_playThrowEffect({
			player = payload.player,
			projectileId = projectileId,
			customProjectile = true,
			position = payload.position,
			velocity = Vector3.zero,
			acceleration = Vector3.zero,
			startedAt = if typeof(payload.serverTime) == "number" then payload.serverTime else getServerTime(),
			fuseStartedAt = if typeof(payload.serverTime) == "number" then payload.serverTime else getServerTime(),
			remainingFuse = if typeof(payload.remainingFuse) == "number" then payload.remainingFuse else BombConfig.FuseSeconds,
			bombSkinId = payload.bombSkinId,
			visuals = payload.visuals,
		})
		visual = self._projectileVisuals[projectileId]
		if not visual then
			return
		end
	end

	visual.customProjectile = true
	if typeof(payload.visuals) == "table" then
		visual.visuals = payload.visuals
		self:_syncAbilityVisualOverlay(visual)
		self:_syncProjectileBaseVisual(visual)
	end
	visual.targetPosition = payload.position
	visual.targetVelocity = Vector3.zero
	visual.position = payload.position
	visual.velocity = Vector3.zero
	visual.acceleration = Vector3.zero
	visual.settled = true
	visual.spinLocked = true
	self:_setProjectileVisualCFrame(visual, payload.position, if typeof(payload.normal) == "Vector3" then payload.normal else Vector3.yAxis, visual.spin)
	self:_playImpactEffect(payload.position)
end

function BombController:_handleProjectileSettle(payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end
	if payload.customProjectile ~= true or typeof(payload.position) ~= "Vector3" then
		return
	end

	local visual = self._projectileVisuals[payload.projectileId]
	if visual then
		visual.customProjectile = true
		visual.targetPosition = payload.position
		visual.targetVelocity = Vector3.zero
		visual.position = payload.position
		visual.velocity = Vector3.zero
		visual.settled = true
	end
end

function BombController:_handleProjectileDestroy(payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end

	self:_destroyProjectileVisual(payload.projectileId)
end

function BombController:_handleProjectileImpact(payload)
	if typeof(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local projectileId = payload.projectileId
	if typeof(projectileId) == "string" then
		if payload.customProjectile == true then
			if payload.physicalProjectile then
				if self:_transferProjectilePulseToPhysical(projectileId, payload.physicalProjectile) then
					self:_playImpactEffect(payload.position)
					return
				end
				self:_retryTransferProjectilePulseToPhysical(projectileId, payload.physicalProjectile)
			end

			local visual = self._projectileVisuals[projectileId]
			if visual then
				local projectilePosition = if typeof(payload.projectilePosition) == "Vector3"
					then payload.projectilePosition
					else payload.position
				local postImpactVelocity = if typeof(payload.postImpactVelocity) == "Vector3"
					then payload.postImpactVelocity
					else payload.impactVelocity
				visual.targetPosition = projectilePosition
				visual.position = projectilePosition
				visual.targetVelocity = if typeof(postImpactVelocity) == "Vector3"
					then postImpactVelocity
					else visual.targetVelocity
				if typeof(payload.acceleration) == "Vector3" then
					visual.acceleration = payload.acceleration
				end
			end
			self:_playImpactEffect(payload.position)
			return
		end

		local transferred = self:_transferProjectilePulseToPhysical(projectileId, payload.physicalProjectile)
		if not transferred then
			self:_destroyProjectileVisual(projectileId)
		end
	end

	self:_playImpactEffect(payload.position)
end

function BombController:_handleProjectileBurrowStart(payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local visual = self._projectileVisuals[payload.projectileId]
	local color = getVisualColor(visual, "highlightColor", Color3.fromRGB(255, 207, 84))
	if visual then
		visual.burrowing = true
		visual.spinLocked = false
		if typeof(payload.direction) == "Vector3" and payload.direction.Magnitude > 0.05 then
			visual.targetVelocity = payload.direction.Unit * math.max(tonumber(payload.speed) or 60, 1)
		end
	end
	self:_playDrillPulse(payload.position, (tonumber(payload.radius) or 4.5) * 1.8, color, 0.18)
end

function BombController:_handleProjectileBurrowStep(payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local visual = self._projectileVisuals[payload.projectileId]
	local color = getVisualColor(visual, "highlightColor", Color3.fromRGB(255, 207, 84))
	if visual then
		visual.burrowing = true
		visual.targetPosition = payload.position
		if typeof(payload.direction) == "Vector3" and payload.direction.Magnitude > 0.05 then
			visual.targetVelocity = payload.direction.Unit * math.max(tonumber(payload.speed) or 60, 1)
		end
	end

	local lastPosition = if typeof(payload.lastPosition) == "Vector3" then payload.lastPosition else payload.position
	self:_playDrillTrail(lastPosition, payload.position, tonumber(payload.radius) or 2.4, color)
end

function BombController:_handleProjectileBurrowEnd(payload)
	if typeof(payload) ~= "table" or typeof(payload.projectileId) ~= "string" then
		return
	end

	local visual = self._projectileVisuals[payload.projectileId]
	if visual then
		visual.burrowing = false
	end
	if typeof(payload.position) == "Vector3" then
		local color = getVisualColor(visual, "highlightColor", Color3.fromRGB(255, 207, 84))
		self:_playDrillPulse(payload.position, 5.5, color, 0.14)
	end
end

function BombController:_playTerrainDebris(payloads)
	if typeof(payloads) ~= "table" then
		return
	end

	for _, payload in ipairs(payloads) do
		VoxelDebris.spawnPayload(payload)
	end
end

local function getPayloadPlayer(payload): Player?
	if typeof(payload) ~= "table" then
		return nil
	end

	local player = payload.player
	return if typeof(player) == "Instance" and player:IsA("Player") then player else nil
end

local function getPlayerByUserId(userId: any): Player?
	if typeof(userId) ~= "number" then
		return nil
	end

	return Players:GetPlayerByUserId(userId)
end

function BombController:_playHitFlashForPlayer(player: Player)
	local character = player.Character
	if not character then
		return
	end

	local existing = character:FindFirstChild(HIT_FLASH_HIGHLIGHT_NAME)
	if existing then
		existing:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = HIT_FLASH_HIGHLIGHT_NAME
	highlight.Adornee = character
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = HIT_FLASH_COLOR
	highlight.OutlineColor = HIT_FLASH_COLOR
	highlight.FillTransparency = HIT_FLASH_FILL_TRANSPARENCY
	highlight.OutlineTransparency = HIT_FLASH_OUTLINE_TRANSPARENCY
	highlight.Parent = character

	local tween = TweenService:Create(highlight, TweenInfo.new(HIT_FLASH_FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	})
	tween.Completed:Connect(function()
		if highlight.Parent then
			highlight:Destroy()
		end
	end)
	tween:Play()

	task.delay(HIT_FLASH_CLEANUP_SECONDS, function()
		if highlight.Parent then
			highlight:Destroy()
		end
	end)
end

function BombController:_playHitFlashes(hitUserIds)
	if typeof(hitUserIds) ~= "table" then
		return
	end

	for _, userId in ipairs(hitUserIds) do
		local player = getPlayerByUserId(userId)
		if player then
			self:_playHitFlashForPlayer(player)
		end
	end
end

function BombController:_bindEffects()
	if self._effectConnection then
		self._effectConnection:Disconnect()
	end
	if not self._effectRemote then
		return
	end

	self._effectConnection = self._effectRemote.OnClientEvent:Connect(function(effectName: string, payload)
		local token = RuntimeProfiler.Begin("Client/BombController/EffectRemote")
		RuntimeProfiler.Count("Client/BombController/Effects")
		if typeof(effectName) == "string" and effectName ~= "" then
			RuntimeProfiler.Count("Client/BombController/Effect/" .. effectName)
		end
		RuntimeProfiler.Count("Client/BombController/EffectPayloadWeight", RuntimeProfiler.EstimatePayloadWeight(payload, 128))
		local payloadPlayer = getPayloadPlayer(payload)
		if effectName == "Hold" and payloadPlayer then
			self:_showHeldBomb(payloadPlayer, if typeof(payload) == "table" then payload.bombSkinId else nil)
		elseif effectName == "HoldEnd" and payloadPlayer then
			self:_hideHeldBomb(payloadPlayer)
		elseif effectName == "Throw" and typeof(payload) == "table" then
			if payloadPlayer then
				self:_hideHeldBomb(payloadPlayer)
			end
			self:_playThrowEffect(payload)
		elseif effectName == "ProjectileSnapshot" and typeof(payload) == "table" then
			self:_handleProjectileSnapshot(payload)
		elseif effectName == "ProjectileAttach" and typeof(payload) == "table" then
			self:_handleProjectileAttach(payload)
		elseif effectName == "Impact" and typeof(payload) == "table" then
			self:_handleProjectileImpact(payload)
		elseif effectName == "Settle" and typeof(payload) == "table" then
			self:_handleProjectileSettle(payload)
		elseif effectName == "ProjectileDestroy" and typeof(payload) == "table" then
			self:_handleProjectileDestroy(payload)
		elseif effectName == "ProjectileBurrowStart" and typeof(payload) == "table" then
			self:_handleProjectileBurrowStart(payload)
		elseif effectName == "ProjectileBurrowStep" and typeof(payload) == "table" then
			self:_handleProjectileBurrowStep(payload)
		elseif effectName == "ProjectileBurrowEnd" and typeof(payload) == "table" then
			self:_handleProjectileBurrowEnd(payload)
		elseif effectName == "Explode" and typeof(payload) == "table" and typeof(payload.position) == "Vector3" then
			if payloadPlayer and payload.source == "InHand" then
				self:_hideHeldBomb(payloadPlayer)
			end
			if typeof(payload.projectileId) == "string" then
				self:_destroyProjectileVisual(payload.projectileId)
			end
			if payload.player == LocalPlayer then
				applyOwnerClientExplosionLaunch(payload.position)
				CameraController:PlayLocalBombExplosionShake()
			end
			self:_playHitFlashes(payload.hitUserIds)
			local explosionVfxAssetPath = if typeof(payload.explosionVfxAssetPath) == "table"
				then payload.explosionVfxAssetPath
				else nil
			if explosionVfxAssetPath then
				self:_playExplosionEffect(payload.position, payload.bombSkinId, payload.explosionVisualScale, explosionVfxAssetPath)
			elseif payload.suppressDefaultExplosionVfx ~= true then
				self:_playExplosionEffect(payload.position, payload.bombSkinId, payload.explosionVisualScale)
			end
		elseif effectName == "TerrainDebris" and typeof(payload) == "table" then
			self:_playTerrainDebris(payload.payloads)
		elseif effectName == "Cook" and typeof(payload) == "table" then
			if payloadPlayer then
				local skinId = BombSkinConfig.NormalizeSkinId(payload.bombSkinId)
				if skinId ~= "" then
					self._heldBombSkinIds[payloadPlayer] = skinId
					self:_ensureHeldBomb(payloadPlayer, 0)
				end
				self:_startHeldBombPulse(payloadPlayer, payload.startedAt, payload.fuseSeconds)
			end
			if payload.player == LocalPlayer then
				self:_startPreview()
			end
		end
		RuntimeProfiler.End("Client/BombController/EffectRemote", token)
	end)
end

function BombController:_bindCharacter(character: Model?)
	self:_stopPreview()
	self._holding = false

	if self._cookingConnection then
		self._cookingConnection:Disconnect()
	end
	if self._humanoidConnection then
		self._humanoidConnection:Disconnect()
		self._humanoidConnection = nil
	end

	self._cookingConnection = LocalPlayer:GetAttributeChangedSignal(ATTR.Cooking):Connect(function()
		if not isCooking() then
			self:_clearBombAnimationState()
			self:_stopPreview()
		end
	end)

	if not character then
		self:_destroyBombAnimations()
		return
	end

	self:_loadBombAnimations(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		self._humanoidConnection = humanoid.HealthChanged:Connect(function()
			self:_cancelHoldIfInvalid()
		end)
	end
	task.defer(function()
		if not isCooking() then
			self:_stopPreview()
		end
	end)
end

function BombController:OnStart()
	self._beginRemote = getRemote(BEGIN_REMOTE_NAME)
	self._releaseRemote = getRemote(RELEASE_REMOTE_NAME)
	self._effectRemote = getRemote(EFFECT_REMOTE_NAME)
	self._started = true
	self:_bindEffects()
	self:_bindInvalidStateSignals()

	ContextActionService:UnbindAction(BOMB_ACTION_NAME)
	ContextActionService:BindAction(
		BOMB_ACTION_NAME,
		function(...)
			return self:_handleAction(...)
		end,
		false,
		Enum.UserInputType.MouseButton1,
		Enum.KeyCode.ButtonR2
	)

	if self._characterConnection then
		self._characterConnection:Disconnect()
	end
	if self._characterRemovingConnection then
		self._characterRemovingConnection:Disconnect()
	end
	if self._playerRemovingConnection then
		self._playerRemovingConnection:Disconnect()
	end
	if self._hipBombConnection then
		self._hipBombConnection:Disconnect()
		self._hipBombConnection = nil
	end

	self._characterConnection = LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)
	self._characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(function()
		self:_cancelHold()
		self:_destroyHipBomb(LocalPlayer)
	end)
	self._playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
		self:_hideHeldBomb(player)
		self:_destroyHipBomb(player)
	end)
	self._hipBombConnection = RunService.Heartbeat:Connect(function(deltaTime)
		local token = RuntimeProfiler.Begin("Client/BombController/HipBombHeartbeat")
		self:_stepHipBombs(deltaTime)
		RuntimeProfiler.End("Client/BombController/HipBombHeartbeat", token)
	end)
	self:_bindCharacter(LocalPlayer.Character)
end

return BombController
