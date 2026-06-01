local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)

local LocalPlayer = Players.LocalPlayer
local REMOTES_FOLDER_NAME = "Remotes"
local BEGIN_REMOTE_NAME = "BeginBombCook"
local RELEASE_REMOTE_NAME = "ReleaseBombCook"
local EFFECT_REMOTE_NAME = "BombEffect"
local BOMB_ACTION_NAME = "BombBattlesPrimaryBomb"
local PREVIEW_FOLDER_NAME = "BombPreview"
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
BombController._chargeSerial = 0

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
	self._chargeSerial += 1
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

function BombController:_playTrack(name: string): AnimationTrack?
	local track = self._bombTracks[name]
	if not track then
		return nil
	end

	if track.IsPlaying then
		track:Stop(0)
	end

	track:Play(AnimationConfig.BombAnimationFadeTime, 1, 1)
	return track
end

function BombController:_playHold()
	local holdTrack = self._bombTracks.Hold
	if not holdTrack then
		return
	end

	if not holdTrack.IsPlaying then
		holdTrack:Play(AnimationConfig.BombAnimationFadeTime, 1, 1)
	end
	holdTrack:AdjustWeight(1, AnimationConfig.BombAnimationFadeTime)
end

function BombController:_playCharge()
	self._chargeSerial += 1
	local serial = self._chargeSerial
	local chargeTrack = self:_playTrack("Charge")
	if not chargeTrack then
		self:_playHold()
		return
	end

	local connection: RBXScriptConnection?
	connection = chargeTrack.Ended:Connect(function()
		if connection then
			connection:Disconnect()
		end
		if serial == self._chargeSerial and self._holding and isCooking() and not self._releasePending then
			self:_playHold()
		end
	end)
	table.insert(self._animationConnections, connection)
end

function BombController:_fireReleaseFromAnimation()
	if not self._releasePending then
		return
	end
	if not isCooking() then
		self:_clearBombAnimationState()
		self:_stopPreview()
		return
	end

	self._releasePending = false
	self._releaseFallbackSerial += 1
	self:_disconnectReleaseMarker()
	self:_stopPreview()

	if self._releaseRemote then
		self._releaseRemote:FireServer(getAimDirection())
	end
end

function BombController:_playRelease()
	self._releasePending = true
	self._releaseFallbackSerial += 1
	local serial = self._releaseFallbackSerial
	self:_disconnectReleaseMarker()

	local chargeTrack = self._bombTracks.Charge
	if chargeTrack and chargeTrack.IsPlaying then
		chargeTrack:Stop(AnimationConfig.BombAnimationFadeTime)
	end
	local holdTrack = self._bombTracks.Hold
	if holdTrack and holdTrack.IsPlaying then
		holdTrack:Stop(AnimationConfig.BombAnimationFadeTime)
	end

	local releaseTrack = self:_playTrack("Release")
	if releaseTrack then
		self._releaseMarkerConnection = releaseTrack:GetMarkerReachedSignal(AnimationConfig.BombThrowMarkerName):Connect(function()
			self:_fireReleaseFromAnimation()
		end)
	end

	task.delay(AnimationConfig.BombReleaseFallbackSeconds, function()
		if serial == self._releaseFallbackSerial and self._releasePending then
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

	local origin = rootPart.CFrame:PointToWorldSpace(BombConfig.ThrowOffset)
	local velocity = (getAimDirection() * BombConfig.ThrowSpeed)
		+ Vector3.yAxis * BombConfig.ThrowUpBoost
		+ rootPart.AssemblyLinearVelocity * BombConfig.InheritedVelocityScale
	local maxPreviewTime = math.min(remaining, BombConfig.PreviewMaxSeconds)
	local dangerAlpha = 1 - math.clamp(remaining / BombConfig.FuseSeconds, 0, 1)
	local color = BombConfig.PreviewColor:Lerp(BombConfig.PreviewDangerColor, dangerAlpha)

	for index, point in ipairs(self._previewPoints) do
		local alpha = index / #self._previewPoints
		local t = math.min(alpha * maxPreviewTime, remaining)
		local gravityOffset = Vector3.new(0, -0.5 * workspace.Gravity * t * t, 0)
		point.Position = origin + velocity * t + gravityOffset
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
	self:_playCharge()

	if self._beginRemote then
		self._beginRemote:FireServer()
	end

	task.delay(0.25, function()
		if self._holding and not isCooking() then
			self:_clearBombAnimationState()
			self:_stopPreview()
		end
	end)
end

function BombController:_requestRelease()
	if not self._holding then
		return
	end

	self._holding = false
	if isCooking() then
		self:_playRelease()
	else
		self:_clearBombAnimationState()
		self:_stopPreview()
	end
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

function BombController:_bindEffects()
	if self._effectConnection then
		self._effectConnection:Disconnect()
	end
	if not self._effectRemote then
		return
	end

	self._effectConnection = self._effectRemote.OnClientEvent:Connect(function(effectName: string, payload)
		if effectName == "Explode" and typeof(payload) == "table" and typeof(payload.position) == "Vector3" then
			self:_playExplosionEffect(payload.position, payload.outerRadius or BombConfig.OuterRadius)
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
