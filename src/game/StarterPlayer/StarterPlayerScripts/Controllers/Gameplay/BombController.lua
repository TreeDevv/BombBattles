local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)
local VoxelDebris = require(ReplicatedStorage.Packages.VoxManager.Voxelizer.Debris)

local LocalPlayer = Players.LocalPlayer
local REMOTES_FOLDER_NAME = "Remotes"
local BEGIN_REMOTE_NAME = "BeginBombCook"
local RELEASE_REMOTE_NAME = "ReleaseBombCook"
local EFFECT_REMOTE_NAME = "BombEffect"
local BOMB_ACTION_NAME = "BombBattlesPrimaryBomb"
local PREVIEW_FOLDER_NAME = "BombPreview"
local PROJECTILE_VISUAL_FOLDER_NAME = "BombProjectileVisuals"
local RENDER_STEP_NAME = "BombBattlesBombPreview"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2
local ATTR = BombConfig.Attributes

local BombController = {}

BombController._beginRemote = nil :: RemoteEvent?
BombController._releaseRemote = nil :: RemoteEvent?
BombController._effectRemote = nil :: RemoteEvent?
BombController._effectConnection = nil :: RBXScriptConnection?
BombController._characterConnection = nil :: RBXScriptConnection?
BombController._cookingConnection = nil :: RBXScriptConnection?
BombController._character = nil :: Model?
BombController._animator = nil :: Animator?
BombController._bombTracks = {} :: { [string]: AnimationTrack }
BombController._animationObjects = {} :: { Animation }
BombController._animationConnections = {} :: { RBXScriptConnection }
BombController._releaseMarkerConnection = nil :: RBXScriptConnection?
BombController._previewFolder = nil :: Folder?
BombController._previewPoints = {} :: { BasePart }
BombController._holding = false
BombController._previewing = false
BombController._releasePending = false
BombController._releaseFallbackSerial = 0
BombController._lastDebugLogTimes = {} :: { [string]: number }
BombController._projectileVisualFolder = nil :: Folder?
BombController._projectileVisuals = {} :: {
	[string]: {
		instance: Instance,
		rootPart: BasePart,
		connection: RBXScriptConnection?,
		path: any,
		spin: number,
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

local function getRootPart(): BasePart?
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

local function getAimDirection(): Vector3
	local camera = workspace.CurrentCamera
	local direction = if camera then camera.CFrame.LookVector else Vector3.new(0, 0.1, -1)
	direction = Vector3.new(direction.X, math.clamp(direction.Y, BombConfig.MinAimY, BombConfig.MaxAimY), direction.Z)
	if direction.Magnitude < 0.05 then
		return Vector3.new(0, 0.15, -1).Unit
	end

	return direction.Unit
end

local function getThrowOrigin(rootPart: BasePart): Vector3
	return rootPart.CFrame:PointToWorldSpace(BombConfig.ThrowOffset)
end

local function getRaycastFilterInstances(): { Instance }
	local filters = {}
	local character = LocalPlayer.Character
	if character then
		table.insert(filters, character)
	end
	if BombController._previewFolder and BombController._previewFolder.Parent then
		table.insert(filters, BombController._previewFolder)
	end
	if BombController._projectileVisualFolder and BombController._projectileVisualFolder.Parent then
		table.insert(filters, BombController._projectileVisualFolder)
	end

	local projectileFolder = workspace:FindFirstChild(BombConfig.ProjectileFolderName)
	if projectileFolder then
		table.insert(filters, projectileFolder)
	end

	return filters
end

local function getMouseTargetPosition(origin: Vector3): (Vector3, boolean)
	local camera = workspace.CurrentCamera
	if not camera then
		return origin + getAimDirection() * BombConfig.NoHitFallbackDistance, false
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = getRaycastFilterInstances()
	raycastParams.IgnoreWater = true

	local result = workspace:Raycast(ray.Origin, ray.Direction * BombConfig.MouseRaycastDistance, raycastParams)
	if result then
		return result.Position, true
	end

	return origin + ray.Direction * BombConfig.NoHitFallbackDistance, false
end

local function resolveLandingTarget(origin: Vector3, targetPosition: Vector3, useDirectTarget: boolean): Vector3
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = getRaycastFilterInstances()
	raycastParams.IgnoreWater = true
	raycastParams.RespectCanCollide = true

	local resolvedTargetPosition = BombTrajectory.ResolveLandingTarget(
		origin,
		targetPosition,
		useDirectTarget,
		BombConfig.LandingResolveUp,
		BombConfig.LandingResolveDown,
		BombConfig.NoHitFallbackDistance,
		function(rayOrigin: Vector3, rayDirection: Vector3)
			return workspace:Raycast(rayOrigin, rayDirection, raycastParams)
		end
	)
	return resolvedTargetPosition
end

local function calculateTrajectory(origin: Vector3, targetPosition: Vector3, useDirectTarget: boolean?)
	local resolvedTargetPosition = resolveLandingTarget(origin, targetPosition, useDirectTarget == true)
	return BombTrajectory.CreatePath(
		origin,
		resolvedTargetPosition,
		BombConfig.TravelSpeed,
		BombConfig.ArcHeightMin,
		BombConfig.ArcHeightPerStud,
		BombConfig.ArcHeightMax
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

local function getAnimator(character: Model): Animator?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

local function getBombTrackWeight(name: string): number
	local config = AnimationConfig.BombAnimations[name]
	if config and typeof(config.Weight) == "number" then
		return math.clamp(config.Weight, 0, 1)
	end

	return 1
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

local function createPreviewPoint(index: number): BasePart
	local part = Instance.new("Part")
	part.Name = "Point" .. index
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(BombConfig.PreviewPointSize, BombConfig.PreviewPointSize, BombConfig.PreviewPointSize)
	part.Material = Enum.Material.Neon
	part.Color = BombConfig.PreviewColor
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 0.25
	return part
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

function BombController:_ensurePreviewPoints()
	local folder = self:_getPreviewFolder()

	for index = #self._previewPoints + 1, BombConfig.PreviewPoints do
		local point = createPreviewPoint(index)
		point.Parent = folder
		self._previewPoints[index] = point
	end
end

function BombController:_setPreviewVisible(visible: boolean)
	self:_ensurePreviewPoints()
	for _, point in ipairs(self._previewPoints) do
		point.Transparency = if visible then point.Transparency else 1
	end
end

function BombController:_startPreview()
	if self._previewing then
		return
	end

	self._previewing = true
	self:_ensurePreviewPoints()
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
	for _, point in ipairs(self._previewPoints) do
		point.Transparency = 1
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
	local stopFadeTime = fadeTime or AnimationConfig.BombAnimationFadeTime
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

function BombController:_loadBombAnimations(character: Model)
	self:_destroyBombAnimations()

	local animator = getAnimator(character)
	if not animator then
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
		track:Stop(0)
	end

	self:_logDebug("bomb-play-before", name, true)
	track:Play(AnimationConfig.BombAnimationFadeTime, getBombTrackWeight(name), 1)
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
			local origin = getThrowOrigin(rootPart)
			local targetPosition, targetHit = getMouseTargetPosition(origin)
			self._releaseRemote:FireServer({
				targetPosition = targetPosition,
				targetHit = targetHit,
				aimDirection = getAimDirection(),
			})
		else
			self._releaseRemote:FireServer(getAimDirection())
		end
	end

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

	self:_ensurePreviewPoints()

	local origin = getThrowOrigin(rootPart)
	local targetPosition, targetHit = getMouseTargetPosition(origin)
	local trajectory = calculateTrajectory(origin, targetPosition, targetHit)
	local maxPreviewTime = math.min(remaining, trajectory.duration)
	local dangerAlpha = 1 - math.clamp(remaining / BombConfig.FuseSeconds, 0, 1)
	local color = BombConfig.PreviewColor:Lerp(BombConfig.PreviewDangerColor, dangerAlpha)

	for index, point in ipairs(self._previewPoints) do
		local alpha = index / #self._previewPoints
		local t = math.min(alpha * maxPreviewTime, remaining)
		point.Position = BombTrajectory.Evaluate(trajectory, t / trajectory.duration)
		point.Color = color
		point.Transparency = 0.2 + alpha * 0.45
	end
end

function BombController:_requestBegin()
	if self._holding or getBombCount() <= 0 then
		return
	end

	self._holding = true
	self:_startPreview()
	self:_playThrow()

	if self._beginRemote then
		self._beginRemote:FireServer()
	end
end

function BombController:_requestRelease()
	if not self._holding then
		return
	end

	self._holding = false
	self:_playRelease()
end

function BombController:_handleAction(_actionName: string, inputState: Enum.UserInputState, _inputObject: InputObject)
	if inputState == Enum.UserInputState.Begin then
		self:_requestBegin()
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		self:_requestRelease()
	end

	return Enum.ContextActionResult.Sink
end

function BombController:_playExplosionEffect(position: Vector3, radius: number)
	local part = Instance.new("Part")
	part.Name = "BombExplosionEffect"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(1, 1, 1)
	part.CFrame = CFrame.new(position)
	part.Material = Enum.Material.Neon
	part.Color = BombConfig.PreviewDangerColor
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 0.25
	part.Parent = workspace

	local tween = TweenService:Create(part, TweenInfo.new(BombConfig.ExplosionEffectSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(radius * 2, radius * 2, radius * 2),
		Transparency = 1,
	})
	tween.Completed:Connect(function()
		part:Destroy()
	end)
	tween:Play()
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
	local cframe = CFrame.lookAt(position, position + tangent) * CFrame.Angles(spin, spin * 0.35, 0)
	if visual.instance:IsA("Model") then
		visual.instance:PivotTo(cframe)
	else
		visual.rootPart.CFrame = cframe
	end
end

function BombController:_createProjectileVisual(projectileId: string)
	local asset = getBombAsset()
	local instance: Instance
	local rootPart: BasePart?

	if asset then
		instance = asset:Clone()
		rootPart = getFirstBasePart(instance)
	else
		local part = Instance.new("Part")
		part.Name = BombConfig.RuntimeBombName
		part.Shape = Enum.PartType.Ball
		part.Size = BombConfig.RuntimeBombSize
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(45, 45, 45)
		instance = part
		rootPart = part
	end

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
		spin = 0,
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
	if visual.instance.Parent then
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

	local path = BombTrajectory.FromPayload(payload)
	if not path then
		return
	end

	self:_destroyProjectileVisual(projectileId)
	local visual = self:_createProjectileVisual(projectileId)
	if not visual then
		return
	end
	visual.path = path
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
	visual.connection = RunService.RenderStepped:Connect(function(deltaTime)
		visual.spin += deltaTime * BombConfig.VisualSpinRadiansPerSecond
		local alpha = math.clamp((getServerTime() - startedAt) / path.duration, 0, 1)
		local position = BombTrajectory.Evaluate(path, alpha)
		local tangent = BombTrajectory.GetTangent(path, alpha)
		self:_setProjectileVisualCFrame(visual, position, tangent, visual.spin)
	end)

	task.delay(lifetime + BombConfig.ProjectileLifetimePadding, function()
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

function BombController:_handleProjectileImpact(payload)
	if typeof(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local projectileId = payload.projectileId
	if typeof(projectileId) == "string" then
		self:_destroyProjectileVisual(projectileId)
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

function BombController:_bindEffects()
	if self._effectConnection then
		self._effectConnection:Disconnect()
	end
	if not self._effectRemote then
		return
	end

	self._effectConnection = self._effectRemote.OnClientEvent:Connect(function(effectName: string, payload)
		if effectName == "Throw" and typeof(payload) == "table" then
			self:_playThrowEffect(payload)
		elseif effectName == "Impact" and typeof(payload) == "table" then
			self:_handleProjectileImpact(payload)
		elseif effectName == "Explode" and typeof(payload) == "table" and typeof(payload.position) == "Vector3" then
			if typeof(payload.projectileId) == "string" then
				self:_destroyProjectileVisual(payload.projectileId)
			end
			self:_playExplosionEffect(payload.position, payload.outerRadius or BombConfig.OuterRadius)
		elseif effectName == "TerrainDebris" and typeof(payload) == "table" then
			self:_playTerrainDebris(payload.payloads)
		elseif effectName == "Cook" and typeof(payload) == "table" and payload.player == LocalPlayer then
			self:_startPreview()
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

	self._cookingConnection = LocalPlayer:GetAttributeChangedSignal(ATTR.Cooking):Connect(function()
		if not isCooking() then
			self:_clearBombAnimationState()
			self:_stopPreview()
		end
	end)

	if character then
		self:_loadBombAnimations(character)
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
	self:_bindEffects()

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

	self._characterConnection = LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)
	self:_bindCharacter(LocalPlayer.Character)
end

return BombController
