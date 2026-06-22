local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)
local BombTrajectoryPreview = require(ReplicatedStorage.Shared.Effects.BombTrajectoryPreview)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local RoundController = require(script.Parent:WaitForChild("RoundController"))
local CameraController = require(script.Parent:WaitForChild("CameraController"))
local BombAnimationRuntime = require(script.Parent:WaitForChild("BombAnimationRuntime"))
local BombExplosionRuntime = require(script.Parent:WaitForChild("BombExplosionRuntime"))
local BombHeldVisualRuntime = require(script.Parent:WaitForChild("BombHeldVisualRuntime"))
local BombHipVisualRuntime = require(script.Parent:WaitForChild("BombHipVisualRuntime"))
local BombProjectileVisualRuntime = require(script.Parent:WaitForChild("BombProjectileVisualRuntime"))
local BombTrajectoryClient = require(script.Parent:WaitForChild("BombTrajectoryClient"))
local REMOTES_FOLDER_NAME = "Remotes"
local BEGIN_REMOTE_NAME = "BeginBombCook"
local RELEASE_REMOTE_NAME = "ReleaseBombCook"
local EFFECT_REMOTE_NAME = "BombEffect"
local BOMB_ACTION_NAME = "BombBattlesPrimaryBomb"
local PROJECTILE_VISUAL_FOLDER_NAME = "BombProjectileVisuals"
local EXPLOSION_VFX_FOLDER_NAME = "BombExplosionVFX"
local HELD_BOMB_ATTACH_RETRY_SECONDS = 0.1
local HELD_BOMB_ATTACH_MAX_ATTEMPTS = 5
local ANIMATOR_LOOKUP_TIMEOUT = 5
local ANIMATOR_RETRY_SECONDS = 0.25
local RENDER_STEP_NAME = "BombBattlesBombPreview"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2
local ROUND_ALIVE_ATTR = "RoundAlive"
local EXPLOSION_VFX_CLEANUP_SECONDS = 8
local ATTR = BombConfig.Attributes

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
BombController._warnedMissingExplosionVfx = false
BombController._explosionVisibilityCache = BombExplosionRuntime.CreateVisibilityCache()
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
BombController._trajectoryPreviewManager = nil :: any?
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
		targetAcceleration: Vector3?,
		targetUpdatedAt: number?,
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

function BombController:_refreshHeldAbilityVisual(player: Player)
	BombHeldVisualRuntime.RefreshAbilityVisual(self, self:_getHeldVisualContext(), player)
end

local function getServerTime(): number
	return workspace:GetServerTimeNow()
end

function BombController:_getHeldVisualContext()
	return {
		players = Players,
		localPlayer = LocalPlayer,
		attachRetrySeconds = HELD_BOMB_ATTACH_RETRY_SECONDS,
		maxAttachAttempts = HELD_BOMB_ATTACH_MAX_ATTEMPTS,
		getPlayerBombSkinId = getPlayerBombSkinId,
		getServerTime = getServerTime,
	}
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

local function findPreviewTrajectoryHit(path: BombTrajectory.Path, maxPreviewTime: number): (RaycastResult?, number)
	return BombTrajectoryClient.FindPreviewTrajectoryHit(path, maxPreviewTime, LocalPlayer.Character)
end

function BombController:_getTrajectoryPreviewManager()
	if not self._trajectoryPreviewManager then
		self._trajectoryPreviewManager = BombTrajectoryPreview.new({
			getSkinId = function()
				return getPlayerBombSkinId(LocalPlayer)
			end,
			findHit = findPreviewTrajectoryHit,
		})
	end
	return self._trajectoryPreviewManager
end

function BombController:_destroyHeldBomb(player: Player)
	BombHeldVisualRuntime.Destroy(self, player)
end

function BombController:_hideHeldBomb(player: Player)
	BombHeldVisualRuntime.Hide(self, player)
end

function BombController:_ensureHeldBomb(player: Player, attempt: number)
	BombHeldVisualRuntime.Ensure(self, self:_getHeldVisualContext(), player, attempt)
end

function BombController:_showHeldBomb(player: Player, skinId: any?)
	BombHeldVisualRuntime.Show(self, self:_getHeldVisualContext(), player, skinId)
end

function BombController:_setHeldBombEffects(player: Player, fuseSpark: boolean, trail: boolean)
	BombHeldVisualRuntime.SetEffects(self, player, fuseSpark, trail)
end

function BombController:SetLocalHeldBombVisualScale(scale: number)
	BombHeldVisualRuntime.SetLocalVisualScale(self, self:_getHeldVisualContext(), scale)
end

function BombController:ResetLocalHeldBombVisualScale()
	BombHeldVisualRuntime.ResetLocalVisualScale(self, self:_getHeldVisualContext())
end

function BombController:SetLocalAbilityHeldVisual(options)
	BombHeldVisualRuntime.SetLocalAbilityVisual(self, self:_getHeldVisualContext(), options)
end

function BombController:ClearLocalAbilityHeldVisual()
	BombHeldVisualRuntime.ClearLocalAbilityVisual(self, self:_getHeldVisualContext())
end

function BombController:_getHipVisualContext()
	return {
		localPlayer = LocalPlayer,
		isCooking = isCooking,
		getRoundState = function()
			return RoundController:Get("state")
		end,
		getPlayerBombCount = getPlayerBombCount,
		getPlayerBombSkinId = getPlayerBombSkinId,
	}
end

function BombController:_destroyHipBomb(player: Player)
	BombHipVisualRuntime.Destroy(self, player)
end

function BombController:_isHipBombSuppressed(player: Player): boolean
	return BombHipVisualRuntime.IsSuppressed(self, self:_getHipVisualContext(), player)
end

function BombController:_shouldShowHipBomb(player: Player): boolean
	return BombHipVisualRuntime.ShouldShow(self, self:_getHipVisualContext(), player)
end

function BombController:_getHipSwayState(player: Player)
	return BombHipVisualRuntime.GetSwayState(player)
end

function BombController:_stepHipBombs(deltaTime: number)
	BombHipVisualRuntime.Step(self, self:_getHipVisualContext(), deltaTime)
end

function BombController:_startHeldBombPulse(player: Player, startedAt: number?, fuseSeconds: number?)
	BombHeldVisualRuntime.StartPulse(self, self:_getHeldVisualContext(), player, startedAt, fuseSeconds)
end

function BombController:_startPreview()
	if self._previewing then
		return
	end

	self._previewing = true
	self:_getTrajectoryPreviewManager():EnsurePrimary()
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
	self:_getTrajectoryPreviewManager():HideAll()
end

function BombController:_getAnimationContext()
	return {
		localPlayer = LocalPlayer,
		animationParent = script,
		animatorLookupTimeout = ANIMATOR_LOOKUP_TIMEOUT,
		animatorRetrySeconds = ANIMATOR_RETRY_SECONDS,
		getRootPart = getRootPart,
		isCooking = isCooking,
		hideHeldBomb = function(player: Player)
			self:_hideHeldBomb(player)
		end,
		fireReleaseFromAnimation = function()
			self:_fireReleaseFromAnimation()
		end,
	}
end

function BombController:_disconnectAnimationConnections()
	BombAnimationRuntime.DisconnectAnimationConnections(self)
end

function BombController:_disconnectReleaseMarker()
	BombAnimationRuntime.DisconnectReleaseMarker(self)
end

function BombController:_stopBombTracks(fadeTime: number?)
	BombAnimationRuntime.StopTracks(self, fadeTime)
end

function BombController:_clearBombAnimationState()
	BombAnimationRuntime.ClearState(self, self:_getAnimationContext())
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
	BombAnimationRuntime.Destroy(self, self:_getAnimationContext())
end

function BombController:_bindBombAnimations(character: Model, animator: Animator?, serial: number): boolean
	return BombAnimationRuntime.Bind(self, self:_getAnimationContext(), character, animator, serial)
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
	BombAnimationRuntime.Load(self, self:_getAnimationContext(), character)
end

function BombController:_setDebugAttributes(eventName: string, trackName: string?, pitch: number, roll: number)
	BombAnimationRuntime.SetDebugAttributes(self:_getAnimationContext(), eventName, trackName, pitch, roll)
end

function BombController:_logDebug(eventName: string, trackName: string?, force: boolean?)
	BombAnimationRuntime.LogDebug(self, self:_getAnimationContext(), eventName, trackName, force)
end

function BombController:_playTrack(name: string): AnimationTrack?
	return BombAnimationRuntime.PlayTrack(self, self:_getAnimationContext(), name)
end

function BombController:_connectThrowMarker(track: AnimationTrack)
	BombAnimationRuntime.ConnectThrowMarker(self, self:_getAnimationContext(), track)
end

function BombController:_playThrow()
	BombAnimationRuntime.PlayThrow(self, self:_getAnimationContext())
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
	BombAnimationRuntime.PlayRelease(self, self:_getAnimationContext())
end

function BombController:_showTrajectoryPreview(
	trajectory: BombTrajectory.Path,
	maxPreviewTime: number,
	color: Color3,
	previewIndex: number?
): boolean
	return self:_getTrajectoryPreviewManager():Show(trajectory, maxPreviewTime, color, previewIndex)
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
	self:_getTrajectoryPreviewManager():HideExtra(#aimDirections)

	return anyShown
end

function BombController:HideAbilityTrajectoryPreview()
	if self._previewing then
		return
	end
	self:_getTrajectoryPreviewManager():HideAll()
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

function BombController:_getExplosionVfxFolder(): Folder
	return BombExplosionRuntime.GetVfxFolder(self:_getExplosionContext())
end

function BombController:_getExplosionContext()
	return {
		localPlayer = LocalPlayer,
		explosionVfxFolderName = EXPLOSION_VFX_FOLDER_NAME,
		projectileVisualFolderName = PROJECTILE_VISUAL_FOLDER_NAME,
		explosionVfxCleanupSeconds = EXPLOSION_VFX_CLEANUP_SECONDS,
		hideHeldBomb = function(player: Player)
			self:_hideHeldBomb(player)
		end,
		destroyProjectileVisual = function(projectileId: string)
			self:_destroyProjectileVisual(projectileId)
		end,
		playLocalExplosionShake = function()
			CameraController:PlayLocalBombExplosionShake()
		end,
	}
end

function BombController:_rememberExplosionVisibility(position: Vector3, decision)
	BombExplosionRuntime.RememberVisibility(self, position, decision)
end

function BombController:_getCachedExplosionVisibility(position: Vector3)
	return BombExplosionRuntime.GetCachedVisibility(self, position)
end

function BombController:_getDebrisVisibilityDecision(payloads)
	return BombExplosionRuntime.GetDebrisVisibilityDecision(self, self:_getExplosionContext(), payloads)
end

function BombController:_playExplosionEffect(position: Vector3, skinId: any, visualScale: number?, assetPath: any?, decision)
	BombExplosionRuntime.PlayEffect(self, self:_getExplosionContext(), position, skinId, visualScale, assetPath, decision)
end

function BombController:_getProjectileVisualFolder(): Folder
	return BombProjectileVisualRuntime.GetFolder(self, self:_getProjectileVisualContext())
end

function BombController:_getProjectileVisualContext()
	return {
		projectileVisualFolderName = PROJECTILE_VISUAL_FOLDER_NAME,
		getServerTime = getServerTime,
	}
end

function BombController:_findPhysicalProjectile(projectileId: string, physicalProjectile: any): (Instance?, BasePart?)
	return BombProjectileVisualRuntime.FindPhysicalProjectile(projectileId, physicalProjectile)
end

function BombController:_transferProjectilePulseToPhysical(projectileId: string, physicalProjectile: any): boolean
	return BombProjectileVisualRuntime.TransferToPhysical(self, self:_getProjectileVisualContext(), projectileId, physicalProjectile)
end

function BombController:_retryTransferProjectilePulseToPhysical(projectileId: string, physicalProjectile: any)
	BombProjectileVisualRuntime.RetryTransferToPhysical(self, self:_getProjectileVisualContext(), projectileId, physicalProjectile)
end

function BombController:_createProjectileVisual(projectileId: string, skinId: any, visualScale: number?)
	return BombProjectileVisualRuntime.Create(self, self:_getProjectileVisualContext(), projectileId, skinId, visualScale)
end

function BombController:_destroyProjectileVisual(projectileId: string)
	BombProjectileVisualRuntime.Destroy(self, projectileId)
end

function BombController:_playThrowEffect(payload)
	BombProjectileVisualRuntime.PlayThrowEffect(self, self:_getProjectileVisualContext(), payload)
end

function BombController:_handleProjectileSnapshot(payload)
	BombProjectileVisualRuntime.HandleSnapshot(self, self:_getProjectileVisualContext(), payload)
end

function BombController:_handleProjectileAttach(payload)
	BombProjectileVisualRuntime.HandleAttach(self, self:_getProjectileVisualContext(), payload)
end

function BombController:_handleProjectileSettle(payload)
	BombProjectileVisualRuntime.HandleSettle(self, payload)
end

function BombController:_handleProjectileDestroy(payload)
	BombProjectileVisualRuntime.HandleDestroy(self, payload)
end

function BombController:_handleProjectileImpact(payload)
	BombProjectileVisualRuntime.HandleImpact(self, self:_getProjectileVisualContext(), payload)
end

function BombController:_handleProjectileBurrowStart(payload)
	BombProjectileVisualRuntime.HandleBurrowStart(self, payload)
end

function BombController:_handleProjectileBurrowStep(payload)
	BombProjectileVisualRuntime.HandleBurrowStep(self, payload)
end

function BombController:_handleProjectileBurrowEnd(payload)
	BombProjectileVisualRuntime.HandleBurrowEnd(self, payload)
end

function BombController:_playTerrainDebris(payloads)
	BombExplosionRuntime.PlayTerrainDebris(self, self:_getExplosionContext(), payloads)
end

local function getPayloadPlayer(payload): Player?
	if typeof(payload) ~= "table" then
		return nil
	end

	local player = payload.player
	return if typeof(player) == "Instance" and player:IsA("Player") then player else nil
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
		elseif effectName == "ProjectileSnapshots" and typeof(payload) == "table" and typeof(payload.snapshots) == "table" then
			for _, snapshot in ipairs(payload.snapshots) do
				self:_handleProjectileSnapshot(snapshot)
			end
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
			BombExplosionRuntime.HandleExplode(self, self:_getExplosionContext(), payload, payloadPlayer)
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
