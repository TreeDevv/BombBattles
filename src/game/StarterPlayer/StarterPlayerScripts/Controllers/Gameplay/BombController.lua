local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local VoxelDebris = require(ReplicatedStorage.Packages.VoxManager.Voxelizer.Debris)

local LocalPlayer = Players.LocalPlayer
local RoundController = require(script.Parent:WaitForChild("RoundController"))
local CameraController = require(script.Parent:WaitForChild("CameraController"))
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
local HELD_BOMB_ATTACH_RETRY_SECONDS = 0.1
local HELD_BOMB_ATTACH_MAX_ATTEMPTS = 5
local ANIMATOR_LOOKUP_TIMEOUT = 5
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
local MIN_AIM_HORIZONTAL = 0.08
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
BombController._characterConnection = nil :: RBXScriptConnection?
BombController._characterRemovingConnection = nil :: RBXScriptConnection?
BombController._playerRemovingConnection = nil :: RBXScriptConnection?
BombController._cookingConnection = nil :: RBXScriptConnection?
BombController._humanoidConnection = nil :: RBXScriptConnection?
BombController._stateConnections = {} :: { RBXScriptConnection }
BombController._character = nil :: Model?
BombController._animator = nil :: Animator?
BombController._bombTracks = {} :: { [string]: AnimationTrack }
BombController._animationObjects = {} :: { Animation }
BombController._animationConnections = {} :: { RBXScriptConnection }
BombController._releaseMarkerConnection = nil :: RBXScriptConnection?
BombController._previewFolder = nil :: Folder?
BombController._trajectoryPreview = nil :: TrajectoryPreview?
BombController._warnedMissingTrajectoryPreview = false
BombController._holding = false
BombController._previewing = false
BombController._releasePending = false
BombController._releaseFallbackSerial = 0
BombController._started = false
BombController._lastDebugLogTimes = {} :: { [string]: number }
BombController._heldBombs = {} :: {
	[Player]: {
		instance: Instance,
		rootPart: BasePart,
		highlight: Highlight?,
		pulseConnection: RBXScriptConnection?,
		fuseStartedAt: number?,
		fuseEndsAt: number?,
	},
}
BombController._heldBombWanted = {} :: { [Player]: boolean }
BombController._heldBombPulseTimes = {} :: {
	[Player]: {
		fuseStartedAt: number,
		fuseEndsAt: number,
	},
}
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
		ownsInstance: boolean,
		highlight: Highlight?,
		pulseConnection: RBXScriptConnection?,
		fuseStartedAt: number?,
		fuseEndsAt: number?,
	},
}

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

local function getHorizontalDirection(direction: Vector3?): Vector3?
	if typeof(direction) ~= "Vector3" then
		return nil
	end

	local horizontal = Vector3.new(direction.X, 0, direction.Z)
	if horizontal.Magnitude <= MIN_AIM_HORIZONTAL then
		return nil
	end

	return horizontal.Unit
end

local function getFallbackAimDirection(): Vector3
	local rootPart = getRootPart()
	local horizontal = if rootPart then getHorizontalDirection(rootPart.CFrame.LookVector) else nil
	return horizontal or Vector3.new(0, 0, -1)
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

local function sanitizeAimDirection(direction: Vector3, fallback: Vector3): Vector3
	local horizontal = getHorizontalDirection(direction)
	if not horizontal then
		horizontal = getHorizontalDirection(fallback) or Vector3.new(0, 0, -1)
		direction = Vector3.new(horizontal.X, direction.Y, horizontal.Z)
	end

	direction = Vector3.new(direction.X, math.clamp(direction.Y, BombConfig.MinAimY, BombConfig.MaxAimY), direction.Z)
	if direction.Magnitude < 0.05 then
		return Vector3.new(horizontal.X, 0.15, horizontal.Z).Unit
	end

	return direction.Unit
end

local function getAimDirection(): Vector3
	local camera = workspace.CurrentCamera
	local direction = if camera then camera.CFrame.LookVector else Vector3.new(0, 0.1, -1)
	return sanitizeAimDirection(direction, getFallbackAimDirection())
end

local function getMouseAimDirection(): Vector3
	local camera = workspace.CurrentCamera
	if not camera then
		return getAimDirection()
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	return sanitizeAimDirection(ray.Direction, getFallbackAimDirection())
end

local function getThrowOrigin(rootPart: BasePart): Vector3
	return rootPart.CFrame:PointToWorldSpace(BombConfig.ThrowOffset)
end

local function calculateTrajectory(origin: Vector3, aimDirection: Vector3)
	return BombTrajectory.CreatePath(
		origin,
		aimDirection,
		BombConfig.ProjectileLaunchSpeed,
		BombConfig.ProjectileUpwardVelocity,
		workspace.Gravity * BombConfig.ProjectileGravityScale,
		BombConfig.ProjectileMaxFlightSeconds
	)
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

local function getBombAsset(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local bombs = assets and assets:FindFirstChild("Bombs")
	if not bombs then
		return nil
	end

	return bombs:FindFirstChild(BombConfig.RuntimeBombName) or bombs:FindFirstChildWhichIsA("Model") or bombs:FindFirstChildWhichIsA("BasePart")
end

local function createBombVisualInstance(): (Instance, BasePart?)
	local asset = getBombAsset()
	if asset then
		local instance = asset:Clone()
		return instance, getFirstBasePart(instance)
	end

	local part = Instance.new("Part")
	part.Name = BombConfig.RuntimeBombName
	part.Shape = Enum.PartType.Ball
	part.Size = BombConfig.RuntimeBombSize
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(45, 45, 45)
	return part, part
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

local function getServerTime(): number
	return workspace:GetServerTimeNow()
end

local function getBombCount(): number
	local count = LocalPlayer:GetAttribute(ATTR.Count)
	return if typeof(count) == "number" then count else BombConfig.MaxBombs
end

local function isCooking(): boolean
	return LocalPlayer:GetAttribute(ATTR.Cooking) == true
end

local function isRoundActiveForLocalPlayer(): boolean
	return RoundController:Get("state") == RoundStates.Active and LocalPlayer:GetAttribute(ROUND_ALIVE_ATTR) == true
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
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	local deadline = os.clock() + ANIMATOR_LOOKUP_TIMEOUT
	repeat
		local animator = findServerAnimator(humanoid)
		if animator then
			return animator
		end

		task.wait()
	until os.clock() >= deadline or not humanoid.Parent

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

local function createPreviewSweepParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = LocalPlayer.Character
	params.FilterDescendantsInstances = if character then { character } else {}
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return params
end

local function sweepPreviewSegment(fromPosition: Vector3, toPosition: Vector3, params: RaycastParams): RaycastResult?
	local direction = toPosition - fromPosition
	if direction.Magnitude <= 0.001 then
		return nil
	end

	local spherecastOk, spherecastResult = pcall(function()
		return workspace:Spherecast(fromPosition, BombConfig.SweepRadius, direction, params)
	end)
	if spherecastOk then
		return spherecastResult
	end

	return workspace:Raycast(fromPosition, direction, params)
end

local function findPreviewTrajectoryHit(path: BombTrajectory.Path, maxPreviewTime: number): (RaycastResult?, number)
	local stepSeconds = if typeof(BombConfig.PreviewStepSeconds) == "number"
		then math.max(BombConfig.PreviewStepSeconds, 1 / 60)
		else 0.08
	local segmentCount = math.max(1, math.ceil(maxPreviewTime / stepSeconds))
	local params = createPreviewSweepParams()

	local previousElapsed = 0
	local previousPosition = BombTrajectory.Evaluate(path, 0)

	for index = 1, segmentCount do
		local elapsed = maxPreviewTime * (index / segmentCount)
		local position = BombTrajectory.Evaluate(path, elapsed / path.duration)
		local hit = sweepPreviewSegment(previousPosition, position, params)
		if hit then
			local segmentLength = (position - previousPosition).Magnitude
			local segmentAlpha = if segmentLength > 0.001
				then math.clamp(hit.Distance / segmentLength, 0, 1)
				else 0
			return hit, previousElapsed + (elapsed - previousElapsed) * segmentAlpha
		end

		previousElapsed = elapsed
		previousPosition = position
	end

	return nil, maxPreviewTime
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

function BombController:_ensureTrajectoryPreview(): TrajectoryPreview?
	if self._trajectoryPreview and self._trajectoryPreview.model.Parent then
		return self._trajectoryPreview
	end

	self._trajectoryPreview = nil

	local template = getTrajectoryLineAsset()
	if not template then
		self:_warnMissingTrajectoryPreview("ReplicatedStorage.Assets.VFX.Trajectory.TrajectoryLine was not found")
		return nil
	end

	local clone = template:Clone()
	clone.Name = TRAJECTORY_PREVIEW_NAME

	local startPart = getNamedBasePart(clone, "Start")
	local endPart = getNamedBasePart(clone, "End")
	if not (startPart and endPart) then
		clone:Destroy()
		self:_warnMissingTrajectoryPreview("expected Start and End BasePart children")
		return nil
	end

	local startAttachment = getNamedAttachment(startPart, "Start")
	local endAttachment = getNamedAttachment(endPart, "End")
	if not (startAttachment and endAttachment) then
		clone:Destroy()
		self:_warnMissingTrajectoryPreview("expected Start.Start and End.End attachments")
		return nil
	end

	local beams, emitters = collectTrajectoryPreviewDescendants(clone)
	if #beams == 0 then
		clone:Destroy()
		self:_warnMissingTrajectoryPreview("expected at least one Beam descendant")
		return nil
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
	}

	setTrajectoryPreviewEnabled(preview, false)
	clone.Parent = self:_getPreviewFolder()
	self._trajectoryPreview = preview

	return preview
end

function BombController:_destroyHeldBomb(player: Player)
	local held = self._heldBombs[player]
	if held then
		self:_stopBombPulse(held)
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
	self._heldBombPulseTimes[player] = nil
	self:_destroyHeldBomb(player)
end

function BombController:_ensureHeldBomb(player: Player, attempt: number)
	if self._heldBombWanted[player] ~= true or player.Parent ~= Players then
		return
	end

	local held = self._heldBombs[player]
	if held and held.instance.Parent then
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

	local instance, rootPart = createBombVisualInstance()
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
		highlight = nil,
		pulseConnection = nil,
		fuseStartedAt = nil,
		fuseEndsAt = nil,
	}
	self._heldBombs[player] = held

	local pulseTimes = self._heldBombPulseTimes[player]
	if pulseTimes then
		self:_startBombPulse(held, instance, pulseTimes.fuseStartedAt, pulseTimes.fuseEndsAt)
	end
end

function BombController:_showHeldBomb(player: Player)
	self._heldBombWanted[player] = true
	self:_ensureHeldBomb(player, 0)
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
		self:_updatePreview()
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
	self:_disconnectReleaseMarker()
	self:_disconnectAnimationConnections()
	self:_stopBombTracks()
	self:_hideHeldBomb(LocalPlayer)
end

function BombController:_canBeginBombHold(ignoreHolding: boolean?): boolean
	if not self._started then
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
	if self._holding and not self:_canBeginBombHold(true) then
		self:_cancelHold()
	end
end

function BombController:_destroyBombAnimations()
	self:_clearBombAnimationState()

	for _, animation in ipairs(self._animationObjects) do
		animation:Destroy()
	end

	self._animationObjects = {}
	self._bombTracks = {}
	self._animator = nil
	self._lastDebugLogTimes = {}
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

	local animator = waitForServerAnimator(character)
	if not animator then
		warn("[BombController] Missing server-created Animator for character:", character:GetFullName())
		return
	end

	self._character = character
	self._animator = animator

	for name, config in pairs(AnimationConfig.BombAnimations) do
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

function BombController:_fireReleaseFromAnimation()
	if not self._releasePending then
		return
	end

	self._releasePending = false
	self._releaseFallbackSerial += 1
	self:_disconnectReleaseMarker()
	self:_stopPreview()

	if self._releaseRemote then
		local rootPart = getRootPart()
		if rootPart then
			self._releaseRemote:FireServer({
				aimDirection = getMouseAimDirection(),
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

	local preview = self:_ensureTrajectoryPreview()
	if not preview then
		return
	end

	local dangerAlpha = 1 - math.clamp(remaining / BombConfig.FuseSeconds, 0, 1)
	local color = BombConfig.PreviewColor:Lerp(BombConfig.PreviewDangerColor, dangerAlpha)
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

	tintTrajectoryPreview(preview, color)
	setTrajectoryPreviewEnabled(preview, true)
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
	self:_playRelease()
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

function BombController:_handleAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		self:BeginBombHold()
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		self:ReleaseBombHold()
	end

	return Enum.ContextActionResult.Sink
end

function BombController:_getExplosionVfxTemplate(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local vfx = assets and assets:FindFirstChild("VFX")
	local explosion = vfx and vfx:FindFirstChild("Explosion")
	local template = explosion and explosion:FindFirstChild("Default")
	if not template and not self._warnedMissingExplosionVfx then
		self._warnedMissingExplosionVfx = true
		warn("[BombController] Missing ReplicatedStorage.Assets.VFX.Explosion.Default")
	end

	return template
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

function BombController:_placeExplosionVfx(instance: Instance, position: Vector3)
	local cframe = CFrame.new(position)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
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
end

function BombController:_playExplosionEffect(position: Vector3)
	local template = self:_getExplosionVfxTemplate()
	local emitModule = self:_getEmitModule()
	if not (template and emitModule and self:_ensureEmitModuleInitialized(emitModule)) then
		return
	end

	local clone = template:Clone()
	clone.Name = "BombExplosionVFX"
	self:_placeExplosionVfx(clone, position)
	clone.Parent = self:_getExplosionVfxFolder()

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
			warn("[BombController] Explosion VFX emit failed: " .. tostring(err))
		end)
	else
		if not ok then
			warn("[BombController] Explosion VFX emit failed: " .. tostring(env))
		end
		task.delay(EXPLOSION_VFX_CLEANUP_SECONDS, cleanup)
	end

	task.delay(EXPLOSION_VFX_CLEANUP_SECONDS, cleanup)
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
	return BombConfig.PulseWhite:Lerp(BombConfig.PulseRed, alpha)
end

function BombController:_updateBombPulse(visual)
	local highlight = visual.highlight
	if not (highlight and highlight.Parent) then
		return
	end

	local fuseProgress, elapsed = self:_getBombPulseProgress(visual)
	local color = self:_getBombPulseColor(visual, fuseProgress, elapsed)
	local fillTransparency = BombConfig.PulseStartFillTransparency
		+ ((BombConfig.PulseEndFillTransparency - BombConfig.PulseStartFillTransparency) * fuseProgress)
	local outlineTransparency = BombConfig.PulseStartOutlineTransparency
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
		self:_updateBombPulse(visual)
	end)
end

function BombController:_findPhysicalProjectile(projectileId: string, physicalProjectile: any): (Instance?, BasePart?)
	if typeof(physicalProjectile) == "Instance" then
		local rootPart = getFirstBasePart(physicalProjectile)
		if rootPart then
			return physicalProjectile, rootPart
		end
	end

	local folder = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	local projectile = folder and folder:FindFirstChild("BombProjectile_" .. projectileId)
	if projectile then
		local rootPart = getFirstBasePart(projectile)
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

	if visual.connection then
		visual.connection:Disconnect()
		visual.connection = nil
	end

	local airborneInstance = visual.instance
	self:_startBombPulse(
		visual,
		projectile,
		visual.fuseStartedAt or getServerTime(),
		visual.fuseEndsAt or (getServerTime() + BombConfig.ProjectileLifetimePadding)
	)
	if visual.ownsInstance and airborneInstance and airborneInstance.Parent then
		airborneInstance:Destroy()
	end

	visual.instance = projectile
	visual.rootPart = rootPart
	visual.path = nil
	visual.ownsInstance = false
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

function BombController:_createProjectileVisual(projectileId: string)
	local instance, rootPart = createBombVisualInstance()

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
		ownsInstance = true,
		highlight = nil,
		pulseConnection = nil,
		fuseStartedAt = nil,
		fuseEndsAt = nil,
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
	self:_stopBombPulse(visual)
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

	self:_destroyProjectileVisual(projectileId)
	local visual = self:_createProjectileVisual(projectileId)
	if not visual then
		return
	end
	visual.path = path
	visual.customProjectile = customProjectile
	if customProjectile then
		local velocity = if typeof(payload.velocity) == "Vector3" then payload.velocity else payload.initialVelocity
		local acceleration = if typeof(payload.acceleration) == "Vector3" then payload.acceleration else Vector3.new(0, -workspace.Gravity, 0)
		visual.position = startPosition
		visual.velocity = if typeof(velocity) == "Vector3" then velocity else Vector3.zero
		visual.targetPosition = visual.position
		visual.targetVelocity = visual.velocity
		visual.acceleration = acceleration
		visual.settled = false
	end
	self._projectileVisuals[projectileId] = visual

	local rootPart = visual.rootPart
	local attachment0 = Instance.new("Attachment")
	attachment0.Name = "BombThrowTrailAttachment0"
	attachment0.Position = Vector3.new(0, rootPart.Size.Y * 0.35, 0)
	attachment0.Parent = rootPart

	local attachment1 = Instance.new("Attachment")
	attachment1.Name = "BombThrowTrailAttachment1"
	attachment1.Position = Vector3.new(0, -rootPart.Size.Y * 0.35, 0)
	attachment1.Parent = rootPart

	local trail = Instance.new("Trail")
	trail.Name = "BombThrowTrail"
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1
	trail.Color = ColorSequence.new(BombConfig.PreviewColor, BombConfig.PreviewDangerColor)
	trail.LightEmission = 0.35
	trail.Lifetime = 0.22
	trail.MinLength = 0.08
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Parent = rootPart

	local light = Instance.new("PointLight")
	light.Name = "BombThrowGlow"
	light.Color = BombConfig.PreviewColor
	light.Brightness = 1.3
	light.Range = 9
	light.Parent = rootPart

	local startedAt = if typeof(payload.startedAt) == "number" then payload.startedAt else getServerTime()
	local lifetime = if typeof(payload.remainingFuse) == "number" then payload.remainingFuse else BombConfig.FuseSeconds
	local fuseStartedAt = if typeof(payload.fuseStartedAt) == "number" then payload.fuseStartedAt else startedAt
	local fuseEndsAt = startedAt + lifetime
	self:_startBombPulse(visual, visual.instance, fuseStartedAt, fuseEndsAt)

	visual.connection = RunService.RenderStepped:Connect(function(deltaTime)
		visual.spin += deltaTime * BombConfig.VisualSpinRadiansPerSecond
		if visual.customProjectile then
			local position = visual.position or visual.targetPosition or rootPart.Position
			local velocity = visual.velocity or visual.targetVelocity or Vector3.zero
			if visual.settled then
				position = visual.targetPosition or position
				velocity = Vector3.zero
			else
				local acceleration = visual.acceleration or Vector3.zero
				velocity += acceleration * deltaTime
				position += velocity * deltaTime

				local positionAlpha = 1 - math.exp(-18 * deltaTime)
				local velocityAlpha = 1 - math.exp(-14 * deltaTime)
				if typeof(visual.targetPosition) == "Vector3" then
					position = position:Lerp(visual.targetPosition, positionAlpha)
				end
				if typeof(visual.targetVelocity) == "Vector3" then
					velocity = velocity:Lerp(visual.targetVelocity, velocityAlpha)
				end
			end

			visual.position = position
			visual.velocity = velocity
			local tangent = if velocity.Magnitude > 0.05 then velocity else visual.targetVelocity or Vector3.zAxis
			self:_setProjectileVisualCFrame(visual, position, tangent, visual.spin)
		elseif path then
			local alpha = math.clamp((getServerTime() - startedAt) / path.duration, 0, 1)
			local position = BombTrajectory.Evaluate(path, alpha)
			local tangent = BombTrajectory.GetTangent(path, alpha)
			self:_setProjectileVisualCFrame(visual, position, tangent, visual.spin)
		end
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
	visual.targetPosition = payload.position
	visual.targetVelocity = if typeof(payload.velocity) == "Vector3" then payload.velocity else Vector3.zero
	if typeof(payload.acceleration) == "Vector3" then
		visual.acceleration = payload.acceleration
	end
	visual.settled = payload.settled == true
	if visual.position == nil or visual.settled then
		visual.position = payload.position
	end
	if visual.velocity == nil or visual.settled then
		visual.velocity = visual.targetVelocity
	end
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
		local payloadPlayer = getPayloadPlayer(payload)
		if effectName == "Hold" and payloadPlayer then
			self:_showHeldBomb(payloadPlayer)
		elseif effectName == "HoldEnd" and payloadPlayer then
			self:_hideHeldBomb(payloadPlayer)
		elseif effectName == "Throw" and typeof(payload) == "table" then
			if payloadPlayer then
				self:_hideHeldBomb(payloadPlayer)
			end
			self:_playThrowEffect(payload)
		elseif effectName == "ProjectileSnapshot" and typeof(payload) == "table" then
			self:_handleProjectileSnapshot(payload)
		elseif effectName == "Impact" and typeof(payload) == "table" then
			self:_handleProjectileImpact(payload)
		elseif effectName == "Settle" and typeof(payload) == "table" then
			self:_handleProjectileSettle(payload)
		elseif effectName == "ProjectileDestroy" and typeof(payload) == "table" then
			self:_handleProjectileDestroy(payload)
		elseif effectName == "Explode" and typeof(payload) == "table" and typeof(payload.position) == "Vector3" then
			if payloadPlayer and payload.source == "InHand" then
				self:_hideHeldBomb(payloadPlayer)
			end
			if typeof(payload.projectileId) == "string" then
				self:_destroyProjectileVisual(payload.projectileId)
			end
			if payload.player == LocalPlayer then
				applyOwnerClientExplosionLaunch(payload.position)
			end
			CameraController:PlayExplosionShake(
				payload.position,
				if typeof(payload.outerRadius) == "number" then payload.outerRadius else BombConfig.OuterRadius
			)
			self:_playHitFlashes(payload.hitUserIds)
			self:_playExplosionEffect(payload.position)
		elseif effectName == "TerrainDebris" and typeof(payload) == "table" then
			self:_playTerrainDebris(payload.payloads)
		elseif effectName == "Cook" and typeof(payload) == "table" then
			if payloadPlayer then
				self:_startHeldBombPulse(payloadPlayer, payload.startedAt, payload.fuseSeconds)
			end
			if payload.player == LocalPlayer then
				self:_startPreview()
			end
		end
	end)
end

function BombController:_bindCharacter(character: Model?)
	self:_stopPreview()
	self._holding = false
	self:_destroyBombAnimations()

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

	if character then
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

	self._characterConnection = LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)
	self._characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(function()
		self:_cancelHold()
	end)
	self._playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
		self:_hideHeldBomb(player)
	end)
	self:_bindCharacter(LocalPlayer.Character)
end

return BombController
