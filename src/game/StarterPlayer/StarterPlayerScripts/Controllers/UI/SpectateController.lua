local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local ScreenEffects = require(ReplicatedStorage.Shared.UI.ScreenEffects)
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ROUND_ALIVE_ATTR = "RoundAlive"
local CAMERA_SPECTATING_ATTR = "Camera_Spectating"
local DEATH_BODY_FOLLOW_SECONDS = 1
local DEATH_FADE_IN_SECONDS = 0.25
local DEATH_FADE_OUT_SECONDS = 0.25
local REPLAY_BLACK_UNCOVER_DELAY_SECONDS = 0.12
local KILL_REPLAY_REQUEST_DELAY_SECONDS = DEATH_BODY_FOLLOW_SECONDS + DEATH_FADE_IN_SECONDS
local KILL_REPLAY_REQUEST_RETRY_SECONDS = 1
local KILL_REPLAY_REQUEST_MAX_ATTEMPTS = 3
local KILL_REPLAY_FALLBACK_SECONDS = 2.75
local TARGET_CHECK_INTERVAL = 0.2
local HIDDEN_BOTTOM_MARGIN_SCALE = 0.02
local HEALTHBAR_SHOW_TWEEN = TweenInfo.new(0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local HEALTHBAR_HIDE_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
local CAMERA_TRANSITION_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local CAMERA_DISTANCE = 12
local CAMERA_HEIGHT = 5
local CAMERA_FOCUS_HEIGHT = 2.2
local CAMERA_FOV = 70
local DEATH_CAMERA_DISTANCE = 13
local DEATH_CAMERA_HEIGHT = 5.5
local DEATH_CAMERA_FOCUS_HEIGHT = 2
local DEATH_CAMERA_RESPONSIVENESS = 8
local LOCAL_CAMERA_RESTORE_RETRY_SECONDS = 0.1
local LOCAL_CAMERA_RESTORE_MAX_ATTEMPTS = 20
local EMPTY_HEALTH_OFFSET = -0.5
local FULL_HEALTH_OFFSET = 0.5
local DEBUG_SPECTATE_REPLAY = false

type HealthBarBinding = {
	root: Frame,
	healthLabel: TextLabel?,
	gradient: UIGradient?,
	humanoid: Humanoid?,
	connections: { RBXScriptConnection },
}

local ReplayClient = nil

do
	local replayFolder = script.Parent:WaitForChild("Replay", 10)
	local replayModule = replayFolder and replayFolder:WaitForChild("ReplayClient", 10)
	if replayModule and replayModule:IsA("ModuleScript") then
		local ok, loadedReplayClient = pcall(require, replayModule)
		if ok then
			ReplayClient = loadedReplayClient
		end
	end
end

local SpectateController = {}

SpectateController._connections = {} :: { RBXScriptConnection }
SpectateController._hudConnections = {} :: { RBXScriptConnection }
SpectateController._playerConnections = {} :: { [Player]: { RBXScriptConnection } }
SpectateController._hud = nil :: ScreenGui?
SpectateController._spectate = nil :: Frame?
SpectateController._leftButton = nil :: GuiButton?
SpectateController._rightButton = nil :: GuiButton?
SpectateController._playerLabel = nil :: TextLabel?
SpectateController._localHealthBar = nil :: HealthBarBinding?
SpectateController._spectateHealthBar = nil :: HealthBarBinding?
SpectateController._localHealthBarNativePosition = nil :: UDim2?
SpectateController._localHealthBarHiddenPosition = nil :: UDim2?
SpectateController._localHealthBarShown = true
SpectateController._localHealthBarTween = nil :: Tween?
SpectateController._localCharacterBindSerial = 0
SpectateController._spectating = false
SpectateController._waitingForKillReplay = false
SpectateController._deathSerial = 0
SpectateController._killReplayRequestSerial = 0
SpectateController._targetSyncSerial = 0
SpectateController._targetCheckAccumulator = 0
SpectateController._targetPlayer = nil :: Player?
SpectateController._transitionTween = nil :: Tween?
SpectateController._transitionSerial = 0
SpectateController._deathBodyFollowConnection = nil :: RBXScriptConnection?
SpectateController._deathCameraState = nil :: any?
SpectateController._cameraRestoreSerial = 0

local function debugSpectateReplay(message: string, ...)
	if DEBUG_SPECTATE_REPLAY then
		warn("[SpectateController] " .. message, ...)
	end
end

local function getReplayType(payload): string?
	return if typeof(payload) == "table" and typeof(payload.type) == "string" then payload.type else nil
end

local function getReplayVictimUserId(payload): number?
	local victimUserId = if typeof(payload) == "table" then payload.victimUserId else nil
	return if typeof(victimUserId) == "number" then math.floor(victimUserId) else nil
end

local function isLocalKillReplay(payload): boolean
	local victimUserId = getReplayVictimUserId(payload)
	return victimUserId == nil or victimUserId == LocalPlayer.UserId
end

local function findTextLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findGuiButton(parent: Instance?, name: string): GuiButton?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("GuiButton") then child else nil
end

local function getHumanoid(player: Player?): Humanoid?
	local character = player and player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function getRootPart(player: Player?): BasePart?
	local character = player and player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

local function getCharacterPart(character: Model?, partNames: { string }): BasePart?
	if not character then
		return nil
	end

	for _, partName in ipairs(partNames) do
		local part = character:FindFirstChild(partName)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function getDeathFollowPart(character: Model?): BasePart?
	return getCharacterPart(character, {
		"HumanoidRootPart",
		"UpperTorso",
		"Torso",
		"Head",
	})
end

local function getHorizontalDirection(vector: Vector3, fallback: Vector3): Vector3
	local flat = Vector3.new(vector.X, 0, vector.Z)
	if flat.Magnitude > 0.05 then
		return flat.Unit
	end

	local fallbackFlat = Vector3.new(fallback.X, 0, fallback.Z)
	if fallbackFlat.Magnitude > 0.05 then
		return fallbackFlat.Unit
	end

	return Vector3.new(0, 0, -1)
end

local function captureCameraState()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	return {
		cameraType = camera.CameraType,
		cameraSubject = camera.CameraSubject,
		cframe = camera.CFrame,
		focus = camera.Focus,
		fieldOfView = camera.FieldOfView,
	}
end

local function restoreCameraState(state)
	local camera = workspace.CurrentCamera
	if not (camera and state) then
		return
	end

	local subject = state.cameraSubject
	if not (subject and subject.Parent) then
		subject = getHumanoid(LocalPlayer)
	end

	if subject then
		camera.CameraSubject = subject
	end
	camera.CameraType = state.cameraType or Enum.CameraType.Custom
	camera.CFrame = state.cframe or camera.CFrame
	camera.Focus = state.focus or camera.Focus
	if typeof(state.fieldOfView) == "number" then
		camera.FieldOfView = state.fieldOfView
	end
end

local function getHiddenBottomPosition(guiObject: GuiObject): UDim2
	local position = guiObject.Position
	local size = guiObject.Size
	return UDim2.new(
		position.X.Scale,
		position.X.Offset,
		1 + size.Y.Scale + HIDDEN_BOTTOM_MARGIN_SCALE,
		size.Y.Offset
	)
end

local function getHealthOffset(progress: number): Vector2
	progress = math.clamp(progress, 0, 1)
	return Vector2.new(EMPTY_HEALTH_OFFSET + ((FULL_HEALTH_OFFSET - EMPTY_HEALTH_OFFSET) * progress), 0)
end

local function disconnectHealthBar(binding: HealthBarBinding?)
	if not binding then
		return
	end

	for _, connection in ipairs(binding.connections) do
		connection:Disconnect()
	end
	binding.connections = {}
	binding.humanoid = nil
end

local function updateHealthBar(binding: HealthBarBinding?)
	if not binding then
		return
	end

	local humanoid = binding.humanoid
	local progress = 0
	local healthText = "0"

	if humanoid and humanoid.Parent then
		local maxHealth = math.max(humanoid.MaxHealth, 1)
		local health = math.clamp(humanoid.Health, 0, maxHealth)
		progress = health / maxHealth
		healthText = tostring(math.max(0, math.floor(health + 0.5)))
	end

	if binding.healthLabel then
		binding.healthLabel.Text = healthText
	end
	if binding.gradient then
		binding.gradient.Enabled = true
		binding.gradient.Offset = getHealthOffset(progress)
	end
end

local function setHealthBarHumanoid(binding: HealthBarBinding?, humanoid: Humanoid?)
	if not binding or binding.humanoid == humanoid then
		updateHealthBar(binding)
		return
	end

	disconnectHealthBar(binding)
	binding.humanoid = humanoid

	if humanoid then
		table.insert(binding.connections, humanoid.HealthChanged:Connect(function()
			updateHealthBar(binding)
		end))
		table.insert(binding.connections, humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(function()
			updateHealthBar(binding)
		end))
	end

	updateHealthBar(binding)
end

local function buildHealthBarBinding(root: Instance?): HealthBarBinding?
	if not (root and root:IsA("Frame")) then
		return nil
	end

	local healthLabel = findTextLabel(root, "Health")
	local back = root:FindFirstChild("Back")
	local fill = back and back:FindFirstChild("Fill")
	local gradient = fill and fill:FindFirstChildWhichIsA("UIGradient")

	return {
		root = root,
		healthLabel = healthLabel,
		gradient = if gradient and gradient:IsA("UIGradient") then gradient else nil,
		humanoid = nil,
		connections = {},
	}
end

local function isRoundActive(): boolean
	local state = RoundController:GetState()
	return state ~= nil and state.state == RoundStates.Active
end

function SpectateController:_isSpectateAllowed(): boolean
	return isRoundActive() and LocalPlayer:GetAttribute(ROUND_ALIVE_ATTR) == false
end

function SpectateController:_isValidTarget(player: Player?): boolean
	if not player or player == LocalPlayer or player.Parent ~= Players then
		return false
	end
	if player:GetAttribute(ROUND_ALIVE_ATTR) ~= true then
		return false
	end

	local humanoid = getHumanoid(player)
	return humanoid ~= nil and humanoid.Health > 0
end

function SpectateController:_getTargets(): { Player }
	local targets = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if self:_isValidTarget(player) then
			table.insert(targets, player)
		end
	end

	table.sort(targets, function(left, right)
		if left.UserId == right.UserId then
			return left.Name < right.Name
		end
		return left.UserId < right.UserId
	end)

	return targets
end

function SpectateController:_findTargetIndex(targets: { Player }, player: Player?): number?
	if not player then
		return nil
	end
	for index, target in ipairs(targets) do
		if target == player then
			return index
		end
	end
	return nil
end

function SpectateController:_disconnectHudConnections()
	for _, connection in ipairs(self._hudConnections) do
		connection:Disconnect()
	end
	self._hudConnections = {}
end

function SpectateController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function SpectateController:_cancelLocalHealthBarTween()
	if self._localHealthBarTween then
		local tween = self._localHealthBarTween
		self._localHealthBarTween = nil
		tween:Cancel()
	end
end

function SpectateController:_setLocalHealthBarVisible(visible: boolean, instant: boolean?)
	local binding = self._localHealthBar
	local healthBar = binding and binding.root
	if not (healthBar and self._localHealthBarNativePosition and self._localHealthBarHiddenPosition) then
		return
	end
	if self._localHealthBarShown == visible and healthBar.Visible == visible and not instant then
		return
	end

	self._localHealthBarShown = visible
	self:_cancelLocalHealthBarTween()

	local targetPosition = if visible then self._localHealthBarNativePosition else self._localHealthBarHiddenPosition
	if visible then
		healthBar.Visible = true
	end

	if instant then
		healthBar.Position = targetPosition
		healthBar.Visible = visible
		return
	end

	local tweenInfo = if visible then HEALTHBAR_SHOW_TWEEN else HEALTHBAR_HIDE_TWEEN
	local tween = TweenService:Create(healthBar, tweenInfo, { Position = targetPosition })
	self._localHealthBarTween = tween
	tween:Play()
	tween.Completed:Once(function(playbackState)
		if self._localHealthBarTween == tween then
			self._localHealthBarTween = nil
		end
		if
			playbackState == Enum.PlaybackState.Completed
			and self._localHealthBar == binding
			and not visible
			and not self._localHealthBarShown
		then
			healthBar.Visible = false
		end
	end)
end

function SpectateController:_cancelCameraTransition()
	self._transitionSerial += 1
	if self._transitionTween then
		self._transitionTween:Cancel()
		self._transitionTween = nil
	end
end

function SpectateController:_stopDeathBodyFollow(restoreCamera: boolean?)
	if self._deathBodyFollowConnection then
		self._deathBodyFollowConnection:Disconnect()
		self._deathBodyFollowConnection = nil
	end

	local cameraState = self._deathCameraState
	self._deathCameraState = nil
	if restoreCamera and cameraState then
		restoreCameraState(cameraState)
	end
end

function SpectateController:_startDeathBodyFollow(serial: number)
	self:_stopDeathBodyFollow(false)
	self:_cancelCameraTransition()

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	self._deathCameraState = captureCameraState()
	LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, true)
	camera.CameraType = Enum.CameraType.Scriptable

	self._deathBodyFollowConnection = RunService.RenderStepped:Connect(function(deltaTime)
		if serial ~= self._deathSerial or not self:_isSpectateAllowed() or self:_isKillReplayActive() then
			return
		end

		local activeCamera = workspace.CurrentCamera
		local character = LocalPlayer.Character
		local followPart = getDeathFollowPart(character)
		if not (activeCamera and followPart and followPart.Parent) then
			return
		end

		activeCamera.CameraType = Enum.CameraType.Scriptable

		local velocity = followPart.AssemblyLinearVelocity
		local direction = getHorizontalDirection(velocity, activeCamera.CFrame.LookVector)
		local focus = followPart.Position + Vector3.new(0, DEATH_CAMERA_FOCUS_HEIGHT, 0)
		local cameraPosition = focus - direction * DEATH_CAMERA_DISTANCE + Vector3.new(0, DEATH_CAMERA_HEIGHT, 0)
		local targetCFrame = CFrame.lookAt(cameraPosition, focus)
		local alpha = math.clamp(
			1 - math.exp(-DEATH_CAMERA_RESPONSIVENESS * math.min(deltaTime, 0.1)),
			0,
			1
		)

		activeCamera.CFrame = activeCamera.CFrame:Lerp(targetCFrame, alpha)
		activeCamera.Focus = CFrame.new(focus)
		activeCamera.FieldOfView = activeCamera.FieldOfView + (CAMERA_FOV - activeCamera.FieldOfView) * alpha
	end)
end

function SpectateController:_applyTargetCamera(player: Player, smooth: boolean)
	local camera = workspace.CurrentCamera
	local humanoid = getHumanoid(player)
	if not (camera and humanoid) then
		return
	end

	self:_stopDeathBodyFollow(false)
	self:_cancelCameraTransition()
	LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, true)

	local rootPart = getRootPart(player)
	if not smooth or not rootPart then
		camera.CameraSubject = humanoid
		camera.CameraType = Enum.CameraType.Custom
		return
	end

	local focus = rootPart.Position + Vector3.new(0, CAMERA_FOCUS_HEIGHT, 0)
	local lookVector = rootPart.CFrame.LookVector
	if lookVector.Magnitude < 0.001 then
		lookVector = Vector3.new(0, 0, -1)
	end

	local cameraPosition = focus - lookVector.Unit * CAMERA_DISTANCE + Vector3.new(0, CAMERA_HEIGHT, 0)
	local targetCFrame = CFrame.lookAt(cameraPosition, focus)
	local serial = self._transitionSerial

	camera.CameraType = Enum.CameraType.Scriptable
	self._transitionTween = TweenService:Create(camera, CAMERA_TRANSITION_TWEEN, {
		CFrame = targetCFrame,
		Focus = CFrame.new(focus),
		FieldOfView = CAMERA_FOV,
	})
	self._transitionTween:Play()
	self._transitionTween.Completed:Once(function()
		if self._transitionSerial ~= serial then
			return
		end
		self._transitionTween = nil

		if self._spectating and self._targetPlayer == player and self:_isValidTarget(player) then
			local targetHumanoid = getHumanoid(player)
			if targetHumanoid and camera.Parent then
				camera.CameraSubject = targetHumanoid
				camera.CameraType = Enum.CameraType.Custom
			end
		end
	end)
end

function SpectateController:_restoreLocalCamera()
	self._cameraRestoreSerial += 1
	local serial = self._cameraRestoreSerial

	self:_stopDeathBodyFollow(false)
	self:_cancelCameraTransition()
	LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, false)

	local function apply(attempt: number)
		if serial ~= self._cameraRestoreSerial then
			return
		end

		LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, false)

		local camera = workspace.CurrentCamera
		local character = LocalPlayer.Character
		local humanoid = getHumanoid(LocalPlayer)
		local rootPart = getRootPart(LocalPlayer)
		if camera and humanoid then
			camera.CameraSubject = humanoid
			camera.CameraType = Enum.CameraType.Custom
			if rootPart then
				camera.Focus = CFrame.new(rootPart.Position)
			end
			debugSpectateReplay("Restored local camera", "attempt", attempt, "character", if character then character.Name else "nil")
			return
		end

		if attempt >= LOCAL_CAMERA_RESTORE_MAX_ATTEMPTS then
			debugSpectateReplay("Local camera restore gave up", "attempt", attempt, "character", if character then character.Name else "nil")
			return
		end

		task.delay(LOCAL_CAMERA_RESTORE_RETRY_SECONDS, function()
			apply(attempt + 1)
		end)
	end

	apply(1)
end

function SpectateController:_setTarget(player: Player?, smooth: boolean)
	if not player or not self:_isValidTarget(player) then
		setHealthBarHumanoid(self._spectateHealthBar, nil)
		if self._playerLabel then
			self._playerLabel.Text = "NO PLAYERS"
		end
		self._targetPlayer = nil
		return
	end

	self._targetPlayer = player
	if self._playerLabel then
		self._playerLabel.Text = player.DisplayName ~= "" and player.DisplayName or player.Name
	end

	setHealthBarHumanoid(self._spectateHealthBar, getHumanoid(player))
	self:_applyTargetCamera(player, smooth)
end

function SpectateController:_hideSpectate(instant: boolean?)
	self:_stopDeathBodyFollow(false)
	ScreenEffects.ClearBlack(DEATH_FADE_OUT_SECONDS)
	self._waitingForKillReplay = false
	self._spectating = false
	self._targetPlayer = nil
	setHealthBarHumanoid(self._spectateHealthBar, nil)

	if self._spectate then
		self._spectate.Visible = false
	end

	self:_setLocalHealthBarVisible(true, instant)
	self:_restoreLocalCamera()
end

function SpectateController:_suspendSpectateForKillReplay()
	debugSpectateReplay("Suspend spectate for local KillReplay")
	self:_stopDeathBodyFollow(false)
	self._waitingForKillReplay = true
	self._spectating = false
	self._targetPlayer = nil
	setHealthBarHumanoid(self._spectateHealthBar, nil)
	self:_cancelCameraTransition()
	LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, true)

	if self._spectate then
		self._spectate.Visible = false
	end
	self:_setLocalHealthBarVisible(false, false)
end

function SpectateController:_handleLocalKillReplayEnded()
	self:_stopDeathBodyFollow(false)
	ScreenEffects.FadeFromBlack(DEATH_FADE_OUT_SECONDS)
	self._waitingForKillReplay = false
	debugSpectateReplay("Local KillReplay ended", "spectateAllowed", self:_isSpectateAllowed())
	if self:_isSpectateAllowed() then
		self:_showSpectate(true)
		return
	end

	self._spectating = false
	self._targetPlayer = nil
	setHealthBarHumanoid(self._spectateHealthBar, nil)
	if self._spectate then
		self._spectate.Visible = false
	end
	self:_setLocalHealthBarVisible(true, false)
	LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, false)
end

function SpectateController:_showSpectate(smoothCamera: boolean)
	if not self:_isSpectateAllowed() then
		self:_hideSpectate(true)
		return
	end

	local targets = self:_getTargets()
	if #targets == 0 then
		self:_hideSpectate(false)
		return
	end

	self:_stopDeathBodyFollow(false)
	ScreenEffects.FadeFromBlack(DEATH_FADE_OUT_SECONDS)

	local target = if self:_isValidTarget(self._targetPlayer) then self._targetPlayer else targets[1]
	self._spectating = true
	self._waitingForKillReplay = false
	LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, true)

	if self._spectate then
		self._spectate.Visible = true
	end
	self:_setLocalHealthBarVisible(false, false)
	self:_setTarget(target, smoothCamera)
end

function SpectateController:_cycleTarget(direction: number)
	if not self._spectating then
		return
	end

	local targets = self:_getTargets()
	if #targets == 0 then
		self:_hideSpectate(false)
		return
	end

	local currentIndex = self:_findTargetIndex(targets, self._targetPlayer) or 1
	local nextIndex = ((currentIndex - 1 + direction) % #targets) + 1
	self:_setTarget(targets[nextIndex], true)
end

function SpectateController:_isKillReplayActive(): boolean
	if not (ReplayClient and type(ReplayClient.GetActiveReplayDebugInfo) == "function") then
		return false
	end

	local debugInfo = ReplayClient:GetActiveReplayDebugInfo()
	return typeof(debugInfo) == "table" and debugInfo.replayType == "KillReplay"
end

function SpectateController:_scheduleKillReplayRequest()
	local serial = self._deathSerial
	if self._killReplayRequestSerial == serial then
		return
	end
	self._killReplayRequestSerial = serial
	debugSpectateReplay(
		"Scheduled KillReplay request",
		"serial",
		serial,
		"delay",
		KILL_REPLAY_REQUEST_DELAY_SECONDS,
		"maxAttempts",
		KILL_REPLAY_REQUEST_MAX_ATTEMPTS
	)

	local function requestAttempt(attempt: number)
		if serial ~= self._deathSerial then
			debugSpectateReplay("KillReplay request skipped; stale serial", "serial", serial, "current", self._deathSerial)
			return
		end
		if not self:_isSpectateAllowed() or self._waitingForKillReplay or self._spectating or self:_isKillReplayActive() then
			debugSpectateReplay(
				"KillReplay request skipped",
				"spectateAllowed",
				self:_isSpectateAllowed(),
				"waitingForKillReplay",
				self._waitingForKillReplay,
				"spectating",
				self._spectating,
				"killReplayActive",
				self:_isKillReplayActive()
			)
			return
		end
		if not (ReplayClient and type(ReplayClient.RequestKillReplay) == "function") then
			debugSpectateReplay("KillReplay request skipped; ReplayClient request unavailable")
		else
			local reason = if attempt <= 1 then "DeadNoReplay" else "DeadNoReplayRetry" .. tostring(attempt)
			RuntimeProfiler.Count("Client/Spectate/KillReplayRequestAttempts")
			local requested = ReplayClient:RequestKillReplay(reason)
			debugSpectateReplay("KillReplay request result", requested, "attempt", attempt)
		end

		if attempt >= KILL_REPLAY_REQUEST_MAX_ATTEMPTS then
			RuntimeProfiler.Count("Client/Spectate/KillReplayRequestGiveUp")
			debugSpectateReplay("KillReplay request attempts exhausted", "serial", serial)
			return
		end

		task.delay(KILL_REPLAY_REQUEST_RETRY_SECONDS, function()
			requestAttempt(attempt + 1)
		end)
	end

	task.delay(DEATH_BODY_FOLLOW_SECONDS, function()
		if serial ~= self._deathSerial then
			debugSpectateReplay("KillReplay fade skipped; stale serial", "serial", serial, "current", self._deathSerial)
			return
		end
		if not self:_isSpectateAllowed() or self._waitingForKillReplay or self._spectating or self:_isKillReplayActive() then
			debugSpectateReplay("KillReplay fade skipped; state changed")
			return
		end

		ScreenEffects.FadeToBlack(DEATH_FADE_IN_SECONDS)
		task.delay(DEATH_FADE_IN_SECONDS, function()
			if serial ~= self._deathSerial then
				debugSpectateReplay("KillReplay request skipped after fade; stale serial", "serial", serial, "current", self._deathSerial)
				return
			end
			if not self:_isSpectateAllowed() or self._waitingForKillReplay or self._spectating or self:_isKillReplayActive() then
				debugSpectateReplay("KillReplay request skipped after fade; state changed")
				return
			end

			ScreenEffects.HoldBlack()
			requestAttempt(1)
		end)
	end)
end

function SpectateController:_scheduleFallbackShow()
	local serial = self._deathSerial
	debugSpectateReplay("Scheduled spectate fallback", "serial", serial, "delay", KILL_REPLAY_FALLBACK_SECONDS)

	task.delay(KILL_REPLAY_FALLBACK_SECONDS, function()
		if serial ~= self._deathSerial then
			debugSpectateReplay("Fallback skipped; stale serial", "serial", serial, "current", self._deathSerial)
			return
		end
		if self:_isSpectateAllowed() and not self._waitingForKillReplay and not self:_isKillReplayActive() then
			debugSpectateReplay("Fallback showing spectate")
			ScreenEffects.FadeFromBlack(DEATH_FADE_OUT_SECONDS)
			self:_showSpectate(true)
		else
			debugSpectateReplay(
				"Fallback skipped",
				"spectateAllowed",
				self:_isSpectateAllowed(),
				"waitingForKillReplay",
				self._waitingForKillReplay,
				"killReplayActive",
				self:_isKillReplayActive()
			)
		end
	end)
end

function SpectateController:_startDeathReplayTransition()
	if self._deathBodyFollowConnection or self._waitingForKillReplay or self._spectating then
		return
	end

	self._deathSerial += 1
	local serial = self._deathSerial

	self._waitingForKillReplay = false
	self._spectating = false
	self._targetPlayer = nil
	setHealthBarHumanoid(self._spectateHealthBar, nil)
	self:_cancelCameraTransition()

	if self._spectate then
		self._spectate.Visible = false
	end
	self:_setLocalHealthBarVisible(false, false)
	ScreenEffects.ClearBlack()
	self:_startDeathBodyFollow(serial)
	self:_scheduleFallbackShow()
	self:_scheduleKillReplayRequest()
end

function SpectateController:_clearDeathReplayTransitionForRespawn()
	self._deathSerial += 1
	self._waitingForKillReplay = false
	self._spectating = false
	self._targetPlayer = nil
	setHealthBarHumanoid(self._spectateHealthBar, nil)
	self:_stopDeathBodyFollow(false)
	self:_cancelCameraTransition()

	if self:_isKillReplayActive() and ReplayClient and type(ReplayClient.CancelReplay) == "function" then
		pcall(function()
			ReplayClient:CancelReplay("Respawned")
		end)
	end

	if self._spectate then
		self._spectate.Visible = false
	end
	ScreenEffects.FadeFromBlack(DEATH_FADE_OUT_SECONDS)
	self:_setLocalHealthBarVisible(true, false)
	self:_restoreLocalCamera()
end

function SpectateController:_handleLocalAliveChanged()
	debugSpectateReplay(
		"Local alive changed",
		"roundAlive",
		LocalPlayer:GetAttribute(ROUND_ALIVE_ATTR),
		"killReplayActive",
		self:_isKillReplayActive(),
		"spectateAllowed",
		self:_isSpectateAllowed()
	)
	if LocalPlayer:GetAttribute(ROUND_ALIVE_ATTR) == true then
		self:_clearDeathReplayTransitionForRespawn()
		return
	end

	if self:_isKillReplayActive() then
		self:_suspendSpectateForKillReplay()
		return
	end

	if self:_isSpectateAllowed() then
		self:_startDeathReplayTransition()
		return
	end

	self._deathSerial += 1
	self:_hideSpectate(false)
end

function SpectateController:_syncTargetValidity(smoothCamera: boolean)
	if self._spectating and not self:_isSpectateAllowed() then
		self:_hideSpectate(false)
		return
	end
	if not self._spectating then
		return
	end
	if self:_isValidTarget(self._targetPlayer) then
		return
	end

	local targets = self:_getTargets()
	if #targets == 0 then
		self:_hideSpectate(false)
		return
	end

	self:_setTarget(targets[1], smoothCamera)
end

function SpectateController:_deferTargetSync()
	self._targetSyncSerial += 1
	local serial = self._targetSyncSerial

	task.defer(function()
		if serial == self._targetSyncSerial then
			self:_syncTargetValidity(true)
		end
	end)
end

function SpectateController:_bindLocalCharacter(character: Model?)
	self._localCharacterBindSerial += 1
	local serial = self._localCharacterBindSerial

	if not character then
		setHealthBarHumanoid(self._localHealthBar, nil)
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		setHealthBarHumanoid(self._localHealthBar, humanoid)
		return
	end

	setHealthBarHumanoid(self._localHealthBar, nil)
	task.spawn(function()
		local child = character:WaitForChild("Humanoid", 5)
		if serial ~= self._localCharacterBindSerial then
			return
		end

		local resolvedHumanoid = if child and child:IsA("Humanoid") then child else character:FindFirstChildOfClass("Humanoid")
		setHealthBarHumanoid(self._localHealthBar, resolvedHumanoid)
	end)
end

function SpectateController:_trackPlayer(player: Player)
	if self._playerConnections[player] then
		return
	end

	self._playerConnections[player] = {
		player:GetAttributeChangedSignal(ROUND_ALIVE_ATTR):Connect(function()
			if player == LocalPlayer then
				self:_handleLocalAliveChanged()
			end
			self:_deferTargetSync()
		end),
		player.CharacterAdded:Connect(function(character)
			if player == LocalPlayer then
				if LocalPlayer:GetAttribute(ROUND_ALIVE_ATTR) == true then
					self:_clearDeathReplayTransitionForRespawn()
				end
				task.defer(function()
					self:_bindLocalCharacter(character)
					self:_handleLocalAliveChanged()
				end)
			end
			self:_deferTargetSync()
		end),
		player.CharacterRemoving:Connect(function()
			if player == LocalPlayer then
				self:_bindLocalCharacter(nil)
			end
			self:_deferTargetSync()
		end),
	}
end

function SpectateController:_untrackPlayer(player: Player)
	local connections = self._playerConnections[player]
	if not connections then
		return
	end

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	self._playerConnections[player] = nil
	self:_deferTargetSync()
end

function SpectateController:_bindReplaySignals()
	if not ReplayClient then
		debugSpectateReplay("ReplayClient unavailable; replay signals not bound")
		return
	end

	if ReplayClient.ReplayStarted and type(ReplayClient.ReplayStarted.Connect) == "function" then
		self:_trackConnection(ReplayClient.ReplayStarted:Connect(function(payload)
			debugSpectateReplay("ReplayStarted", getReplayType(payload), "victim", tostring(getReplayVictimUserId(payload)))
			if getReplayType(payload) == "KillReplay" and isLocalKillReplay(payload) then
				local serial = self._deathSerial
				self:_suspendSpectateForKillReplay()
				task.delay(REPLAY_BLACK_UNCOVER_DELAY_SECONDS, function()
					if serial == self._deathSerial and self:_isKillReplayActive() then
						ScreenEffects.FadeFromBlack(DEATH_FADE_OUT_SECONDS)
					end
				end)
			end
		end))
	else
		debugSpectateReplay("ReplayStarted signal unavailable")
	end

	if ReplayClient.ReplayEnded and type(ReplayClient.ReplayEnded.Connect) == "function" then
		self:_trackConnection(ReplayClient.ReplayEnded:Connect(function(payload)
			debugSpectateReplay("ReplayEnded", getReplayType(payload), "victim", tostring(getReplayVictimUserId(payload)))
			if getReplayType(payload) ~= "KillReplay" or not isLocalKillReplay(payload) then
				return
			end

			self._waitingForKillReplay = false
			self:_handleLocalKillReplayEnded()
		end))
	else
		debugSpectateReplay("ReplayEnded signal unavailable")
	end
end

function SpectateController:_bindHud(hud: Instance?)
	self:_disconnectHudConnections()
	disconnectHealthBar(self._localHealthBar)
	disconnectHealthBar(self._spectateHealthBar)
	self:_cancelLocalHealthBarTween()

	self._hud = nil
	self._spectate = nil
	self._leftButton = nil
	self._rightButton = nil
	self._playerLabel = nil
	self._localHealthBar = nil
	self._spectateHealthBar = nil
	self._localHealthBarNativePosition = nil
	self._localHealthBarHiddenPosition = nil
	self._localHealthBarShown = true

	if not (hud and hud:IsA("ScreenGui")) then
		return
	end

	self._hud = hud

	local localHealthBar = hud:FindFirstChild("HealthBar")
	if localHealthBar and localHealthBar:IsA("Frame") then
		self._localHealthBar = buildHealthBarBinding(localHealthBar)
		self._localHealthBarNativePosition = localHealthBar.Position
		self._localHealthBarHiddenPosition = getHiddenBottomPosition(localHealthBar)
		self._localHealthBarShown = localHealthBar.Visible
	end

	local spectate = hud:FindFirstChild("Spectate")
	if spectate and spectate:IsA("Frame") then
		self._spectate = spectate
		spectate.Visible = false

		table.insert(self._hudConnections, spectate:GetPropertyChangedSignal("Visible"):Connect(function()
			self:_setLocalHealthBarVisible(not spectate.Visible, false)
		end))

		local panel = spectate:FindFirstChild("Frame")
		self._leftButton = findGuiButton(panel, "LeftButton")
		self._rightButton = findGuiButton(panel, "RightButton")
		self._playerLabel = findTextLabel(panel, "PlayerSpectating")
		self._spectateHealthBar = buildHealthBarBinding(spectate:FindFirstChild("HealthBar"))

		if self._leftButton then
			table.insert(self._hudConnections, self._leftButton.Activated:Connect(function()
				self:_cycleTarget(-1)
			end))
		end
		if self._rightButton then
			table.insert(self._hudConnections, self._rightButton.Activated:Connect(function()
				self:_cycleTarget(1)
			end))
		end
	end

	self:_bindLocalCharacter(LocalPlayer.Character)
	self:_setLocalHealthBarVisible(not self._spectating, true)
	self:_handleLocalAliveChanged()
end

function SpectateController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild("HUD"))
end

function SpectateController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}

	self:_disconnectHudConnections()
	for player, connections in pairs(self._playerConnections) do
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		self._playerConnections[player] = nil
	end

	disconnectHealthBar(self._localHealthBar)
	disconnectHealthBar(self._spectateHealthBar)
	self:_cancelLocalHealthBarTween()
	self:_cancelCameraTransition()
	self:_stopDeathBodyFollow(false)
	ScreenEffects.ClearBlack()
end

function SpectateController:OnStart()
	self:_disconnectAll()
	LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, false)

	for _, player in ipairs(Players:GetPlayers()) do
		self:_trackPlayer(player)
	end

	self:_trackConnection(Players.PlayerAdded:Connect(function(player)
		self:_trackPlayer(player)
		self:_deferTargetSync()
	end))
	self:_trackConnection(Players.PlayerRemoving:Connect(function(player)
		self:_untrackPlayer(player)
	end))
	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" then
			task.defer(function()
				self:_bindHud(child)
			end)
		end
	end))
	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self:_handleLocalAliveChanged()
		self:_deferTargetSync()
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "state" or key == "roundId" then
			self:_handleLocalAliveChanged()
			self:_deferTargetSync()
		end
	end))
	self:_trackConnection(RunService.RenderStepped:Connect(function(deltaTime)
		self._targetCheckAccumulator += deltaTime
		if self._targetCheckAccumulator >= TARGET_CHECK_INTERVAL then
			self._targetCheckAccumulator = 0
			self:_syncTargetValidity(true)
		end
	end))

	self:_bindReplaySignals()
	self:_bindCurrentHud()
end

return SpectateController
