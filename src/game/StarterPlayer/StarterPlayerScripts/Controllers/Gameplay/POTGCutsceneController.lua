local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local REMOTES_FOLDER_NAME = "Remotes"
local CAMERA_SPECTATING_ATTR = "Camera_Spectating"
local CUTSCENE_FOLDER_NAME = "_LocalCutscenes"
local OVERLAY_GUI_NAME = "POTGCutsceneFade"
local RENDER_STEP_NAME = "BombBattlesPOTGCutscene"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 20
local CAMERA_RIG_ANIMATION_ID = "rbxassetid://109489630009202"
local CHARACTER_RIG_ANIMATION_ID = "rbxassetid://77997378080732"
local FALLBACK_DURATION_SECONDS = 10
local FADE_TO_BLACK_SECONDS = 0.28
local FADE_FROM_BLACK_SECONDS = 0.38
local BLACK_HOLD_SECONDS = 0.08
local OVERLAY_DISPLAY_ORDER = 2000

type Controls = {
	Disable: ((Controls) -> ())?,
	Enable: ((Controls) -> ())?,
}

type SavedCameraState = {
	cameraType: Enum.CameraType,
	cameraSubject: Instance?,
	cframe: CFrame,
	focus: CFrame,
	fieldOfView: number,
	mouseBehavior: Enum.MouseBehavior,
	mouseIconEnabled: boolean,
	wasSpectating: boolean,
	controls: Controls?,
	controlsDisabled: boolean,
}

type ActiveCutscene = {
	clone: Model,
	cameraBone: BasePart,
	savedCamera: SavedCameraState,
	overlayGui: ScreenGui,
	overlayFrame: Frame,
	fadeTween: Tween?,
	connections: { RBXScriptConnection },
	tracks: { AnimationTrack },
	endAt: number,
	durationSeconds: number,
	endedTracks: { [AnimationTrack]: boolean },
	playbackStarted: boolean,
	finishing: boolean,
	completed: boolean,
}

local POTGCutsceneController = {}

POTGCutsceneController._remote = nil :: RemoteEvent?
POTGCutsceneController._remoteConnection = nil :: RBXScriptConnection?
POTGCutsceneController._characterRemovingConnection = nil :: RBXScriptConnection?
POTGCutsceneController._active = nil :: ActiveCutscene?
POTGCutsceneController._restoreSerial = 0

local function getRemotesFolder(): Folder?
	local folder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	return if folder and folder:IsA("Folder") then folder else nil
end

local function getRemote(): RemoteEvent?
	local folder = getRemotesFolder()
	if not folder then
		return nil
	end

	local remote = folder:WaitForChild(AdminConfig.POTGCutsceneRemoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
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

local function getCutsceneTemplate(): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local cutscenes = assets and assets:FindFirstChild("Cutscenes")
	local template = cutscenes and cutscenes:FindFirstChild("POTGCutscene")
	return if template and template:IsA("Model") then template else nil
end

local function getCutsceneFolder(): Folder
	local existing = workspace:FindFirstChild(CUTSCENE_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = CUTSCENE_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function createOverlay(): (ScreenGui, Frame)
	local existing = PlayerGui:FindFirstChild(OVERLAY_GUI_NAME)
	if existing then
		existing:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = OVERLAY_GUI_NAME
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = OVERLAY_DISPLAY_ORDER
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = PlayerGui

	local frame = Instance.new("Frame")
	frame.Name = "Black"
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Visible = true
	frame.ZIndex = 1
	frame.Parent = screenGui

	return screenGui, frame
end

local function findRequiredDescendant(root: Instance, name: string, className: string): Instance?
	local descendant = root:FindFirstChild(name, true)
	if descendant and descendant.ClassName == className then
		return descendant
	end
	return nil
end

local function getAnimator(root: Instance, path: { string }): Animator?
	local current: Instance? = root
	for _, name in ipairs(path) do
		current = current and current:FindFirstChild(name)
	end
	return if current and current:IsA("Animator") then current else nil
end

local function loadTrack(animator: Animator, animationId: string, name: string): AnimationTrack?
	local animation = Instance.new("Animation")
	animation.Name = name
	animation.AnimationId = animationId

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()

	if ok and track then
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = false
		return track
	end

	warn(("[POTGCutsceneController] Failed to load %s animation: %s"):format(name, tostring(track)))
	return nil
end

local function saveCameraState(camera: Camera): SavedCameraState
	local controls = getControls()
	local controlsDisabled = false
	if controls and type(controls.Disable) == "function" then
		local ok = pcall(function()
			controls:Disable()
		end)
		controlsDisabled = ok
	end

	return {
		cameraType = camera.CameraType,
		cameraSubject = camera.CameraSubject,
		cframe = camera.CFrame,
		focus = camera.Focus,
		fieldOfView = camera.FieldOfView,
		mouseBehavior = UserInputService.MouseBehavior,
		mouseIconEnabled = UserInputService.MouseIconEnabled,
		wasSpectating = LocalPlayer:GetAttribute(CAMERA_SPECTATING_ATTR) == true,
		controls = controls,
		controlsDisabled = controlsDisabled,
	}
end

local function restoreControls(savedCamera: SavedCameraState)
	local controls = savedCamera.controls
	if savedCamera.controlsDisabled and controls and type(controls.Enable) == "function" then
		pcall(function()
			controls:Enable()
		end)
	end
end

local function disconnectConnections(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function stopTracks(tracks: { AnimationTrack })
	for _, track in ipairs(tracks) do
		pcall(function()
			track:Stop(0)
			track:Destroy()
		end)
	end
end

function POTGCutsceneController:_restoreCamera(active: ActiveCutscene)
	local camera = workspace.CurrentCamera
	local saved = active.savedCamera
	self._restoreSerial += 1

	local function restoreInputAndState()
		restoreControls(saved)
		UserInputService.MouseBehavior = saved.mouseBehavior
		UserInputService.MouseIconEnabled = saved.mouseIconEnabled
		LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, saved.wasSpectating)
	end

	if not camera then
		restoreInputAndState()
		return
	end

	local subject = saved.cameraSubject
	if not (subject and subject.Parent) then
		local character = LocalPlayer.Character
		subject = character and character:FindFirstChildOfClass("Humanoid") or nil
	end

	local function finishRestore()
		restoreInputAndState()
		if subject then
			camera.CameraSubject = subject
		end
		camera.CameraType = saved.cameraType
		camera.FieldOfView = saved.fieldOfView
	end

	camera.CFrame = saved.cframe
	camera.Focus = saved.focus
	finishRestore()
end

function POTGCutsceneController:_cancelFade(active: ActiveCutscene)
	if active.fadeTween then
		active.fadeTween:Cancel()
		active.fadeTween = nil
	end
end

function POTGCutsceneController:_startFade(active: ActiveCutscene, transparency: number, duration: number): Tween?
	if active.completed or self._active ~= active or not active.overlayFrame.Parent then
		return nil
	end

	self:_cancelFade(active)
	active.overlayFrame.Visible = true

	local tween = TweenService:Create(
		active.overlayFrame,
		TweenInfo.new(math.max(duration, 0.01), Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ BackgroundTransparency = math.clamp(transparency, 0, 1) }
	)
	active.fadeTween = tween
	tween:Play()
	return tween
end

function POTGCutsceneController:_waitForFade(active: ActiveCutscene, tween: Tween?): boolean
	if not tween then
		return false
	end

	local playbackState = tween.Completed:Wait()
	if active.fadeTween == tween then
		active.fadeTween = nil
	end

	return playbackState == Enum.PlaybackState.Completed and self._active == active and not active.completed
end

function POTGCutsceneController:_destroyOverlay(active: ActiveCutscene)
	self:_cancelFade(active)
	if active.overlayGui.Parent then
		active.overlayGui:Destroy()
	end
end

function POTGCutsceneController:_unbindCamera()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
end

function POTGCutsceneController:_cleanup(active: ActiveCutscene, restoreCamera: boolean, destroyOverlay: boolean)
	self:_unbindCamera()
	disconnectConnections(active.connections)
	stopTracks(active.tracks)

	if restoreCamera then
		self:_restoreCamera(active)
	end
	if active.clone.Parent then
		active.clone:Destroy()
	end
	if destroyOverlay then
		self:_destroyOverlay(active)
	end
end

function POTGCutsceneController:_finish(active: ActiveCutscene, fadeOut: boolean)
	if active.completed then
		return
	end

	if not fadeOut then
		active.completed = true
		if self._active == active then
			self._active = nil
		end
		self:_cleanup(active, true, true)
		return
	end

	if active.finishing then
		return
	end
	active.finishing = true

	task.spawn(function()
		local toBlack = self:_startFade(active, 0, FADE_TO_BLACK_SECONDS)
		self:_waitForFade(active, toBlack)
		if self._active ~= active or active.completed then
			return
		end

		self:_cleanup(active, true, false)
		task.wait(BLACK_HOLD_SECONDS)
		if self._active ~= active or active.completed then
			return
		end

		local fromBlack = self:_startFade(active, 1, FADE_FROM_BLACK_SECONDS)
		self:_waitForFade(active, fromBlack)

		active.completed = true
		if self._active == active then
			self._active = nil
		end
		self:_destroyOverlay(active)
	end)
end

function POTGCutsceneController:_cancelActive()
	local active = self._active
	if active then
		self:_finish(active, false)
	end
end

function POTGCutsceneController:_beginPlayback(active: ActiveCutscene)
	if self._active ~= active or active.completed or active.finishing or active.playbackStarted then
		return
	end

	local camera = workspace.CurrentCamera
	if not (camera and active.cameraBone.Parent) then
		self:_finish(active, false)
		return
	end

	active.playbackStarted = true
	active.endAt = os.clock() + active.durationSeconds

	LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, true)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = active.cameraBone.CFrame
	camera.Focus = active.cameraBone.CFrame

	self:_unbindCamera()
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function()
		if self._active ~= active then
			return
		end
		if not active.finishing and os.clock() >= active.endAt then
			self:_finish(active, true)
			return
		end
		local currentCamera = workspace.CurrentCamera
		if currentCamera and active.cameraBone.Parent then
			currentCamera.CameraType = Enum.CameraType.Scriptable
			currentCamera.CFrame = active.cameraBone.CFrame
			currentCamera.Focus = active.cameraBone.CFrame
		else
			self:_finish(active, false)
		end
	end)

	for _, track in ipairs(active.tracks) do
		track:Play(0)
	end
end

function POTGCutsceneController:_play()
	self:_cancelActive()
	self._restoreSerial += 1

	local template = getCutsceneTemplate()
	local camera = workspace.CurrentCamera
	if not template or not camera then
		warn("[POTGCutsceneController] Missing POTGCutscene template or CurrentCamera")
		return
	end

	local clone = template:Clone()
	clone.Name = "POTGCutscene_Local"
	clone.Parent = getCutsceneFolder()

	local cameraBone = findRequiredDescendant(clone, "cameraBone", "MeshPart")
	local camRigAnimator = getAnimator(clone, { "CamRig", "AnimationController", "Animator" })
	local characterAnimator = getAnimator(clone, { "CharacterRig", "Humanoid", "Animator" })
	if not (cameraBone and camRigAnimator and characterAnimator) then
		warn("[POTGCutsceneController] POTGCutscene is missing required rig instances")
		clone:Destroy()
		return
	end

	local camTrack = loadTrack(camRigAnimator, CAMERA_RIG_ANIMATION_ID, "POTGCameraRig")
	local characterTrack = loadTrack(characterAnimator, CHARACTER_RIG_ANIMATION_ID, "POTGCharacterRig")
	local tracks = {}
	if camTrack then
		table.insert(tracks, camTrack)
	end
	if characterTrack then
		table.insert(tracks, characterTrack)
	end
	if #tracks == 0 then
		warn("[POTGCutsceneController] No POTG cutscene animations loaded")
		clone:Destroy()
		return
	end

	local overlayGui, overlayFrame = createOverlay()
	local savedCamera = saveCameraState(camera)

	local longestTrackLength = 0
	for _, track in ipairs(tracks) do
		if track.Length > longestTrackLength then
			longestTrackLength = track.Length
		end
	end

	local active: ActiveCutscene = {
		clone = clone,
		cameraBone = cameraBone :: BasePart,
		savedCamera = savedCamera,
		overlayGui = overlayGui,
		overlayFrame = overlayFrame,
		fadeTween = nil,
		connections = {},
		tracks = tracks,
		endAt = math.huge,
		durationSeconds = if longestTrackLength > 0 then longestTrackLength + 0.5 else FALLBACK_DURATION_SECONDS,
		endedTracks = {},
		playbackStarted = false,
		finishing = false,
		completed = false,
	}
	self._active = active

	local function markTrackEnded(track: AnimationTrack)
		if active.completed or active.finishing then
			return
		end
		active.endedTracks[track] = true
		local endedCount = 0
		for _, activeTrack in ipairs(active.tracks) do
			if active.endedTracks[activeTrack] then
				endedCount += 1
			end
		end
		if endedCount >= #active.tracks then
			self:_finish(active, true)
		end
	end

	for _, track in ipairs(tracks) do
		table.insert(active.connections, track.Stopped:Connect(function()
			markTrackEnded(track)
		end))
	end

	task.spawn(function()
		local toBlack = self:_startFade(active, 0, FADE_TO_BLACK_SECONDS)
		self:_waitForFade(active, toBlack)
		if self._active ~= active or active.completed then
			return
		end

		task.wait(BLACK_HOLD_SECONDS)
		if self._active ~= active or active.completed then
			return
		end

		self:_beginPlayback(active)
		local fromBlack = self:_startFade(active, 1, FADE_FROM_BLACK_SECONDS)
		self:_waitForFade(active, fromBlack)
	end)
end

function POTGCutsceneController:OnStart()
	if self._remoteConnection then
		self._remoteConnection:Disconnect()
		self._remoteConnection = nil
	end
	if self._characterRemovingConnection then
		self._characterRemovingConnection:Disconnect()
		self._characterRemovingConnection = nil
	end

	self._remote = getRemote()
	if self._remote then
		self._remoteConnection = self._remote.OnClientEvent:Connect(function()
			self:_play()
		end)
	end

	self._characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(function()
		self:_cancelActive()
	end)
end

return POTGCutsceneController
