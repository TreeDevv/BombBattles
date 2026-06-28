local Lighting = game:GetService("Lighting")
local ContentProvider = game:GetService("ContentProvider")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local POTGCutsceneConfig = require(ReplicatedStorage.Shared.Config.POTGCutsceneConfig)
local RoundEndFlowConfig = require(ReplicatedStorage.Shared.Config.RoundEndFlowConfig)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local ScreenEffects = require(ReplicatedStorage.Shared.UI.ScreenEffects)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local SoundUtil = require(ReplicatedStorage.Shared.Audio.SoundUtil)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local REMOTES_FOLDER_NAME = "Remotes"
local CAMERA_SPECTATING_ATTR = "Camera_Spectating"
local CUTSCENE_FOLDER_NAME = "_LocalCutscenes"
local OVERLAY_GUI_NAME = "POTGCutsceneFade"
local RENDER_STEP_NAME = "BombBattlesPOTGCutscene"
local RENDER_PRIORITY = Enum.RenderPriority.Last.Value
local FALLBACK_DURATION_SECONDS = 10
local FADE_TO_BLACK_SECONDS = 0.28
local FADE_FROM_BLACK_SECONDS = 0.38
local BLACK_HOLD_SECONDS = 0.08
local OVERLAY_DISPLAY_ORDER = 2000
local DEBUG_CUTSCENE = RunService:IsStudio()
local CUTSCENE_DOF_NAME = "_LocalPOTGHighlightDOF"
local EMIT_WARN_PREFIX = "[POTGHighlightIntro]"
local VFX_HANDLER_NAME = "VFXHandler"
local REMOTE_WAIT_SECONDS = 10
local TRACK_HOLD_LEAD_SECONDS = 1 / 30
local TRACK_FINAL_POSE_OFFSET_SECONDS = 1 / 240
local PREPARED_HIGHLIGHT_INTROS_FOLDER_NAME = "PreparedHighlightIntros"
local CUTSCENE_TRACKS_FOLDER_NAME = "CutsceneTracks"
local CUTSCENE_SOUND_FALLBACKS = table.freeze({
	HollowPurple = "BB Gojo Cutscene",
})
local moonVFXModule: any? = nil
local moonVFXModuleInitialized = false
local checkedForMoonVFXModule = false
local prewarmedAnimationIds: { [string]: boolean } = {}

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

type TrackHoldRecord = {
	track: AnimationTrack,
	name: string,
	length: number,
	held: boolean,
}

type ActiveCutscene = {
	clone: Model,
	cutsceneSpec: any,
	cameraBone: BasePart,
	placementAnchor: BasePart?,
	dofEffect: DepthOfFieldEffect?,
	motionSourcePivot: CFrame,
	motionTargetPivot: CFrame,
	motionTargetPivotPart: BasePart?,
	motionRecords: { any },
	savedCamera: SavedCameraState,
	overlayGui: ScreenGui,
	overlayFrame: Frame,
	fadeTween: Tween?,
	connections: { RBXScriptConnection },
	tracks: { AnimationTrack },
	activeSounds: { Sound },
	heldTracks: { TrackHoldRecord },
	cameraTrackHold: TrackHoldRecord?,
	cameraHoldCFrame: CFrame?,
	endAt: number,
	durationSeconds: number,
	playbackStartedAt: number,
	playbackStarted: boolean,
	finishing: boolean,
	completed: boolean,
	holdBlackOnFinish: boolean,
	completionReported: boolean,
	roundId: number?,
	completionRemote: RemoteEvent?,
	isRoundIntro: boolean,
	isPreview: boolean,
	revealAfterPreviewCallback: boolean,
	previewOnComplete: ((string) -> ())?,
}

local POTGCutsceneController = {}
local debugCutscene

POTGCutsceneController._remote = nil :: RemoteEvent?
POTGCutsceneController._remoteConnection = nil :: RBXScriptConnection?
POTGCutsceneController._roundIntroRemote = nil :: RemoteEvent?
POTGCutsceneController._roundIntroConnection = nil :: RBXScriptConnection?
POTGCutsceneController._roundIntroCompleteRemote = nil :: RemoteEvent?
POTGCutsceneController._characterRemovingConnection = nil :: RBXScriptConnection?
POTGCutsceneController._active = nil :: ActiveCutscene?
POTGCutsceneController._restoreSerial = 0
POTGCutsceneController._roundIntroActive = false
POTGCutsceneController._afterRoundIntroCallbacks = {}
POTGCutsceneController.RoundIntroStarted = Signal.new()
POTGCutsceneController.RoundIntroCompleted = Signal.new()

local function getRemotesFolder(): Folder?
	local folder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, REMOTE_WAIT_SECONDS)
	return if folder and folder:IsA("Folder") then folder else nil
end

local function getRemote(): RemoteEvent?
	local folder = getRemotesFolder()
	if not folder then
		return nil
	end

	local remote = folder:WaitForChild(AdminConfig.POTGCutsceneRemoteName, REMOTE_WAIT_SECONDS)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getRoundIntroRemote(): RemoteEvent?
	local folder = getRemotesFolder()
	if not folder then
		return nil
	end

	local remote = folder:WaitForChild(RoundEndFlowConfig.Remotes.POTGIntro, REMOTE_WAIT_SECONDS)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getRoundIntroCompleteRemote(): RemoteEvent?
	local folder = getRemotesFolder()
	if not folder then
		return nil
	end

	local remote = folder:WaitForChild(RoundEndFlowConfig.Remotes.POTGIntroComplete, REMOTE_WAIT_SECONDS)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getConfiguredDuration(value: any, fallback: number): number
	if typeof(value) == "number" and value == value then
		return math.max(value, 0)
	end
	return fallback
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

local function getPreparedCutsceneTemplate(payload): Instance?
	if
		typeof(payload) ~= "table"
		or payload.appearanceAppliedOnServer ~= true
		or typeof(payload.preparedHighlightIntroName) ~= "string"
		or payload.preparedHighlightIntroName == ""
	then
		return nil
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		assets = ReplicatedStorage:WaitForChild("Assets", REMOTE_WAIT_SECONDS)
	end
	local preparedFolder = assets and assets:FindFirstChild(PREPARED_HIGHLIGHT_INTROS_FOLDER_NAME)
	if not preparedFolder and assets then
		preparedFolder = assets:WaitForChild(PREPARED_HIGHLIGHT_INTROS_FOLDER_NAME, REMOTE_WAIT_SECONDS)
	end
	if not preparedFolder then
		warn(("[POTGCutsceneController] Missing prepared highlight intro folder for %s"):format(
			payload.preparedHighlightIntroName
		))
		return nil
	end

	local template = preparedFolder:FindFirstChild(payload.preparedHighlightIntroName)
	if not template then
		template = preparedFolder:WaitForChild(payload.preparedHighlightIntroName, REMOTE_WAIT_SECONDS)
	end
	if template and (template:IsA("Folder") or template:IsA("Model")) then
		return template
	end

	warn(("[POTGCutsceneController] Missing prepared highlight intro template %s"):format(
		payload.preparedHighlightIntroName
	))
	return nil
end

local function getCutsceneTemplate(cutsceneSpec, payload): (Instance?, boolean)
	local preparedTemplate = getPreparedCutsceneTemplate(payload)
	if preparedTemplate then
		return preparedTemplate, true
	end

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local cutscenes = assets and assets:FindFirstChild("Cutscenes")
	local replicatedTemplate = cutscenes and cutscenes:FindFirstChild(cutsceneSpec.replicatedAssetName)
	if replicatedTemplate and (replicatedTemplate:IsA("Folder") or replicatedTemplate:IsA("Model")) then
		return replicatedTemplate, false
	end

	local highlightIntros = workspace:FindFirstChild("HighlightIntros")
	local template = highlightIntros and highlightIntros:FindFirstChild(cutsceneSpec.assetFolderName)
	return if template and (template:IsA("Folder") or template:IsA("Model")) then template else nil, false
end

local function findCameraPartInRig(cameraRig: Instance?, cutsceneSpec): BasePart?
	if not cameraRig then
		return nil
	end

	local cameraBone = cameraRig:FindFirstChild(cutsceneSpec.cameraBoneName, true)
	if cameraBone and cameraBone:IsA("BasePart") then
		return cameraBone
	end

	local rootPart = cameraRig:FindFirstChild("RootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end

	local fallback = cameraRig:FindFirstChildWhichIsA("BasePart", true)
	return if fallback and fallback:IsA("BasePart") then fallback else nil
end

local function validateHighlightIntroTemplate(template: Instance, cutsceneSpec): boolean
	local characterRig = template:FindFirstChild(cutsceneSpec.characterRigName)
	local cameraRig = template:FindFirstChild(cutsceneSpec.cameraRigName)
	local missing = {}

	if not characterRig then
		table.insert(missing, tostring(cutsceneSpec.characterRigName))
	elseif not characterRig:FindFirstChild("Humanoid", true) then
		table.insert(missing, tostring(cutsceneSpec.characterRigName) .. ".Humanoid")
	end

	if not cameraRig then
		table.insert(missing, tostring(cutsceneSpec.cameraRigName))
	else
		if not findCameraPartInRig(cameraRig, cutsceneSpec) then
			table.insert(missing, tostring(cutsceneSpec.cameraRigName) .. "." .. tostring(cutsceneSpec.cameraBoneName))
		end
		if
			not cameraRig:FindFirstChildOfClass("AnimationController")
			and not cameraRig:FindFirstChild("AnimationController", true)
		then
			table.insert(missing, tostring(cutsceneSpec.cameraRigName) .. ".AnimationController")
		end
	end

	for _, event in ipairs(cutsceneSpec.events or {}) do
		if
			(event.type == "Emit" or event.type == "Code")
			and typeof(event.effectName) == "string"
			and not template:FindFirstChild(event.effectName, true)
		then
			warn(("[POTGCutsceneController] Cutscene %s is missing optional effect %s"):format(
				tostring(cutsceneSpec.id),
				event.effectName
			))
		end
	end

	if #missing > 0 then
		warn(("[POTGCutsceneController] Cutscene %s is missing required template parts: %s"):format(
			tostring(cutsceneSpec.id),
			table.concat(missing, ", ")
		))
		return false
	end

	return true
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

local function forceNonLoopingCutsceneAnimations(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("KeyframeSequence") then
			descendant.Loop = false
		end
	end
end

local function cloneCutsceneTemplate(template: Instance): Model
	local templateClone = template:Clone()
	local clone
	if templateClone:IsA("Model") then
		clone = templateClone
	else
		clone = Instance.new("Model")
		for _, child in ipairs(templateClone:GetChildren()) do
			child.Parent = clone
		end
		templateClone:Destroy()
	end
	clone.Name = "POTGHighlightIntro_Local"
	return clone
end

local function getHumanoidRigAncestor(root: Model, descendant: Instance): Model?
	local current = descendant.Parent
	while current and current ~= root.Parent do
		if current:IsA("Model") and current:FindFirstChildOfClass("Humanoid") then
			return current
		end
		if current == root then
			break
		end
		current = current.Parent
	end
	return nil
end

local function getHumanoidRigRootPart(rig: Model): BasePart?
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	local humanoidRoot = humanoid and humanoid.RootPart
	if humanoidRoot and humanoidRoot:IsA("BasePart") then
		return humanoidRoot
	end

	local namedRoot = rig:FindFirstChild("HumanoidRootPart") or rig:FindFirstChild("RootPart")
	if namedRoot and namedRoot:IsA("BasePart") then
		return namedRoot
	end

	return if rig.PrimaryPart and rig.PrimaryPart:IsA("BasePart") then rig.PrimaryPart else nil
end

local function getJointDrivenExternalParts(root: Model): { [BasePart]: boolean }
	local drivenParts = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if not descendant:IsA("JointInstance") then
			continue
		end

		local part0 = descendant.Part0
		local part1 = descendant.Part1
		if not (part0 and part1 and part0:IsDescendantOf(root) and part1:IsDescendantOf(root)) then
			continue
		end

		local rig0 = getHumanoidRigAncestor(root, part0)
		local rig1 = getHumanoidRigAncestor(root, part1)
		if rig0 and rig0 ~= rig1 and not rig1 then
			drivenParts[part1] = true
		elseif rig1 and rig1 ~= rig0 and not rig0 then
			drivenParts[part0] = true
		end
	end
	return drivenParts
end

local function prepCutsceneClone(root: Model)
	local jointDrivenExternalParts = getJointDrivenExternalParts(root)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local humanoidRig = getHumanoidRigAncestor(root, descendant)
			local humanoidRigRoot = if humanoidRig then getHumanoidRigRootPart(humanoidRig) else nil
			local shouldAnchor = if humanoidRig then descendant == humanoidRigRoot else not jointDrivenExternalParts[descendant]
			descendant.Anchored = shouldAnchor
			descendant.Massless = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		elseif descendant:IsA("Sound") then
			descendant.Looped = false
			descendant:Stop()
		end
	end
end

local function hideRuntimeHelperPart(part: BasePart)
	part.Transparency = 1
	part.LocalTransparencyModifier = 1
	part.CastShadow = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

local function hideCameraRigVisuals(root: Model, cutsceneSpec)
	local cameraRig = root:FindFirstChild(cutsceneSpec.cameraRigName)
	if not cameraRig then
		return
	end

	for _, descendant in ipairs(cameraRig:GetDescendants()) do
		if descendant:IsA("BasePart") then
			hideRuntimeHelperPart(descendant)
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = 1
		end
	end
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function getCandidateUserId(payload): number?
	if typeof(payload) ~= "table" or not isFiniteNumber(payload.potgPlayerUserId) then
		return nil
	end

	local userId = math.floor(payload.potgPlayerUserId)
	return if userId ~= 0 then userId else nil
end

local function getCharacterRig(root: Instance, cutsceneSpec): Model?
	local rig = root:FindFirstChild(cutsceneSpec.characterRigName)
	if rig and rig:IsA("Model") then
		return rig
	end

	rig = root:FindFirstChild("CharacterRig")
	return if rig and rig:IsA("Model") then rig else nil
end

local function captureAuthoredBombMotor(root: Model, cutsceneSpec)
	local rig = getCharacterRig(root, cutsceneSpec)
	local rightArm = rig and rig:FindFirstChild("Right Arm")
	local bombMotor = rightArm and rightArm:FindFirstChild("Bomb")
	if not (bombMotor and bombMotor:IsA("Motor6D")) then
		return nil
	end

	return {
		c0 = bombMotor.C0,
		c1 = bombMotor.C1,
		name = bombMotor.Name,
	}
end

local function restoreAuthoredBombMotor(root: Model, cutsceneSpec, snapshot)
	if not snapshot then
		return
	end

	local rig = getCharacterRig(root, cutsceneSpec)
	local rightArm = rig and rig:FindFirstChild("Right Arm")
	local bomb = root:FindFirstChild("Bomb")
	if not (rightArm and rightArm:IsA("BasePart") and bomb and bomb:IsA("BasePart")) then
		return
	end

	local bombMotor = rightArm:FindFirstChild(snapshot.name)
	if not (bombMotor and bombMotor:IsA("Motor6D")) then
		bombMotor = Instance.new("Motor6D")
		bombMotor.Name = snapshot.name
		bombMotor.Parent = rightArm
	end
	bombMotor.Part0 = rightArm
	bombMotor.Part1 = bomb
	bombMotor.C0 = snapshot.c0
	bombMotor.C1 = snapshot.c1
end

local function getRelativePath(root: Instance, descendant: Instance): { string }?
	if descendant == root then
		return {}
	end
	if not descendant:IsDescendantOf(root) then
		return nil
	end

	local path = {}
	local current: Instance? = descendant
	while current and current ~= root do
		table.insert(path, 1, current.Name)
		current = current.Parent
	end
	return path
end

local function findByRelativePath(root: Instance, path: { string }?): Instance?
	if not path then
		return nil
	end

	local current: Instance? = root
	for _, name in ipairs(path) do
		current = current and current:FindFirstChild(name) or nil
		if not current then
			return nil
		end
	end
	return current
end

local function captureAuthoredExternalRigJoints(root: Model, cutsceneSpec)
	local rig = getCharacterRig(root, cutsceneSpec)
	if not rig then
		return {}
	end

	local snapshots = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if not descendant:IsA("JointInstance") then
			continue
		end

		local part0 = descendant.Part0
		local part1 = descendant.Part1
		if not (part0 and part1 and part0:IsDescendantOf(root) and part1:IsDescendantOf(root)) then
			continue
		end

		local part0InRig = part0:IsDescendantOf(rig)
		local part1InRig = part1:IsDescendantOf(rig)
		if part0InRig == part1InRig then
			continue
		end

		table.insert(snapshots, {
			className = descendant.ClassName,
			name = descendant.Name,
			parentPath = getRelativePath(root, descendant.Parent),
			part0Path = getRelativePath(root, part0),
			part1Path = getRelativePath(root, part1),
			c0 = descendant.C0,
			c1 = descendant.C1,
		})
	end

	return snapshots
end

local function restoreAuthoredExternalRigJoints(root: Model, snapshots)
	for _, snapshot in ipairs(snapshots or {}) do
		local parent = findByRelativePath(root, snapshot.parentPath)
		local part0 = findByRelativePath(root, snapshot.part0Path)
		local part1 = findByRelativePath(root, snapshot.part1Path)
		if not (parent and part0 and part0:IsA("BasePart") and part1 and part1:IsA("BasePart")) then
			continue
		end

		local joint: JointInstance? = nil
		local existing = parent:FindFirstChild(snapshot.name)
		if existing and existing:IsA("JointInstance") and existing.ClassName == snapshot.className then
			joint = existing
		end

		if not joint then
			local ok, created = pcall(function()
				return Instance.new(snapshot.className)
			end)
			if not (ok and created and created:IsA("JointInstance")) then
				continue
			end
			joint = created
			joint.Name = snapshot.name
			joint.Parent = parent
		end

		joint.Part0 = part0
		joint.Part1 = part1
		joint.C0 = snapshot.c0
		joint.C1 = snapshot.c1
	end
end

local function getHumanoidDescriptionForUserId(userId: number): HumanoidDescription?
	local okDescription, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
	if okDescription and description then
		return description
	end

	local asyncError = description
	local okPlayer, player = pcall(function()
		return Players:GetPlayerByUserId(userId)
	end)
	if not okPlayer then
		player = nil
	end

	local character = player and player.Character
	local liveHumanoid = character and character:FindFirstChildOfClass("Humanoid")
	if liveHumanoid then
		local ok, description = pcall(function()
			return liveHumanoid:GetAppliedDescription()
		end)
		if ok and description then
			return description
		end
	end

	warn(("[POTGCutsceneController] Failed to get HumanoidDescription for userId %s: %s"):format(
		tostring(userId),
		tostring(asyncError)
	))
	return nil
end

local function getDescriptionAccessoryCount(description: HumanoidDescription): number?
	local ok, accessories = pcall(function()
		return description:GetAccessories(true)
	end)
	if not ok or typeof(accessories) ~= "table" then
		return nil
	end
	return #accessories
end

local function getAppliedAccessoryCount(humanoid: Humanoid): number?
	local ok, accessories = pcall(function()
		return humanoid:GetAccessories()
	end)
	if not ok or typeof(accessories) ~= "table" then
		return nil
	end
	return #accessories
end

local function getAccessoryHandle(accessory: Accessory): BasePart?
	local handle = accessory:FindFirstChild("Handle")
	return if handle and handle:IsA("BasePart") then handle else nil
end

local function getHandleAttachment(handle: BasePart): Attachment?
	local hairAttachment = handle:FindFirstChild("HairAttachment")
	if hairAttachment and hairAttachment:IsA("Attachment") then
		return hairAttachment
	end

	for _, child in ipairs(handle:GetChildren()) do
		if child:IsA("Attachment") then
			return child
		end
	end

	return nil
end

local function getRigAttachment(rig: Model, accessory: Accessory, handleAttachment: Attachment): Attachment?
	if accessory.AccessoryType == Enum.AccessoryType.Hair or handleAttachment.Name == "HairAttachment" then
		local head = rig:FindFirstChild("Head")
		local headHairAttachment = head and head:FindFirstChild("HairAttachment")
		if headHairAttachment and headHairAttachment:IsA("Attachment") then
			return headHairAttachment
		end
	end

	for _, descendant in ipairs(rig:GetDescendants()) do
		if descendant == handleAttachment or not descendant:IsA("Attachment") or descendant.Name ~= handleAttachment.Name then
			continue
		end

		local parent = descendant.Parent
		if parent and parent:IsA("BasePart") and not parent:FindFirstAncestorOfClass("Accessory") then
			return descendant
		end
	end

	return nil
end

local function isValidAccessoryWeld(weld: Instance?, handle: BasePart, targetPart: BasePart): boolean
	if not (weld and weld:IsA("Weld")) then
		return false
	end

	local part0 = weld.Part0
	local part1 = weld.Part1
	if not (part0 and part1) then
		return false
	end

	local otherPart = if part0 == handle then part1 elseif part1 == handle then part0 else nil
	return otherPart == targetPart
end

local function repairAccessoryWeld(rig: Model, accessory: Accessory): boolean
	local handle = getAccessoryHandle(accessory)
	if not handle then
		return false
	end

	local handleAttachment = getHandleAttachment(handle)
	if not handleAttachment then
		return false
	end

	local rigAttachment = getRigAttachment(rig, accessory, handleAttachment)
	if not (rigAttachment and rigAttachment.Parent and rigAttachment.Parent:IsA("BasePart")) then
		return false
	end
	local targetPart = rigAttachment.Parent

	local existingWeld = handle:FindFirstChild("AccessoryWeld")
	if isValidAccessoryWeld(existingWeld, handle, targetPart) then
		return false
	end

	if existingWeld then
		existingWeld:Destroy()
	end

	local weld = Instance.new("Weld")
	weld.Name = "AccessoryWeld"
	weld.Part0 = handle
	weld.Part1 = targetPart
	weld.C0 = handleAttachment.CFrame
	weld.C1 = rigAttachment.CFrame
	weld.Parent = handle
	return true
end

local function repairCandidateAccessoryWelds(rig: Model, humanoid: Humanoid, userId: number)
	local ok, accessories = pcall(function()
		return humanoid:GetAccessories()
	end)
	if not ok or typeof(accessories) ~= "table" then
		return
	end

	for _, accessory in ipairs(accessories) do
		if accessory:IsA("Accessory") then
			local repaired = repairAccessoryWeld(rig, accessory)
			if repaired and DEBUG_CUTSCENE then
				debugCutscene(
					"Repaired candidate accessory weld",
					"userId",
					tostring(userId),
					"accessory",
					accessory.Name,
					"type",
					tostring(accessory.AccessoryType)
				)
			end
		end
	end
end

local function rebuildHumanoidAccessoryAttachments(humanoid: Humanoid)
	local ok, err = pcall(function()
		humanoid:BuildRigFromAttachments()
	end)
	if not ok then
		warn(("[POTGCutsceneController] Failed to rebuild candidate accessory attachments: %s"):format(
			tostring(err)
		))
	end
end

local function debugCandidateAccessoryApply(userId: number, description: HumanoidDescription, humanoid: Humanoid)
	if not DEBUG_CUTSCENE then
		return
	end

	debugCutscene(
		"Candidate accessory apply",
		"userId",
		tostring(userId),
		"requested",
		tostring(getDescriptionAccessoryCount(description)),
		"applied",
		tostring(getAppliedAccessoryCount(humanoid))
	)
end

local function applyCandidateAppearanceToAuthoredRig(root: Model, cutsceneSpec, payload, serverPreparedTemplate: boolean?): Animator?
	local userId = getCandidateUserId(payload)
	local rig = getCharacterRig(root, cutsceneSpec)
	if not rig then
		return nil
	end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	if serverPreparedTemplate == true then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
		debugCutscene("Using server-applied candidate appearance", "userId", tostring(userId))
		return animator
	end

	if userId then
		local description = getHumanoidDescriptionForUserId(userId)
		if description then
			local bombMotorSnapshot = captureAuthoredBombMotor(root, cutsceneSpec)
			local externalJointSnapshots = captureAuthoredExternalRigJoints(root, cutsceneSpec)
			local ok, err = pcall(function()
				humanoid:ApplyDescriptionResetAsync(description)
			end)
			if ok then
				rebuildHumanoidAccessoryAttachments(humanoid)
				RunService.Heartbeat:Wait()
				repairCandidateAccessoryWelds(rig, humanoid, userId)
				debugCandidateAccessoryApply(userId, description, humanoid)
			end
			restoreAuthoredBombMotor(root, cutsceneSpec, bombMotorSnapshot)
			restoreAuthoredExternalRigJoints(root, externalJointSnapshots)
			description:Destroy()
			if ok then
				debugCutscene("Applied candidate appearance", "userId", tostring(userId))
			else
				warn(("[POTGCutsceneController] Failed to apply candidate appearance for userId %s: %s"):format(
					tostring(userId),
					tostring(err)
				))
			end
		end
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

local function getCutscenePivotPart(root: Model, cutsceneSpec): BasePart?
	local pivot = root:FindFirstChild(cutsceneSpec.pivotPartName)
	return if pivot and pivot:IsA("BasePart") then pivot else nil
end

local function getCutscenePlacementAnchor(root: Model, cutsceneSpec, cameraBone: BasePart?): BasePart?
	return getCutscenePivotPart(root, cutsceneSpec) or cameraBone
end

local function pivotCutsceneToTarget(root: Model, cutsceneSpec, targetCFrame: CFrame, cameraBone: BasePart?): BasePart?
	local anchorPart = getCutscenePlacementAnchor(root, cutsceneSpec, cameraBone)
	if not anchorPart then
		if DEBUG_CUTSCENE then
			warn(("[POTGCutsceneController] Cutscene %s is missing %s and %s anchor parts; using model pivot fallback"):format(
				tostring(cutsceneSpec.id),
				tostring(cutsceneSpec.pivotPartName),
				tostring(cutsceneSpec.cameraBoneName)
			))
		end
		root:PivotTo(targetCFrame)
		return nil
	end

	local modelPivot = root:GetPivot()
	local targetModelPivot = targetCFrame * anchorPart.CFrame:Inverse() * modelPivot
	root:PivotTo(targetModelPivot)
	return anchorPart
end

local function getMotionSourcePivot(root: Model, cutsceneSpec): CFrame
	local configuredPivot = cutsceneSpec.motionSourcePivotCFrame
	if typeof(configuredPivot) == "CFrame" then
		return configuredPivot
	end

	local pivotPart = getCutscenePivotPart(root, cutsceneSpec)
	return if pivotPart then pivotPart.CFrame else root:GetPivot()
end

local function getMotionTargetPivot(root: Model, cutsceneSpec, placementAnchor: BasePart?): CFrame
	if placementAnchor and placementAnchor.Parent then
		return placementAnchor.CFrame
	end

	local pivotPart = getCutscenePivotPart(root, cutsceneSpec)
	return if pivotPart then pivotPart.CFrame else root:GetPivot()
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
	if descendant and descendant:IsA(className) then
		return descendant
	end
	return nil
end

local function getCameraPart(root: Model, cutsceneSpec): BasePart?
	local cameraBone = findRequiredDescendant(root, cutsceneSpec.cameraBoneName, "BasePart")
	if cameraBone and cameraBone:IsA("BasePart") then
		return cameraBone
	end

	local cameraRig = root:FindFirstChild(cutsceneSpec.cameraRigName)
	local rootPart = cameraRig and cameraRig:FindFirstChild("RootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end

	local fallback = cameraRig and cameraRig:FindFirstChildWhichIsA("BasePart", true)
	return if fallback and fallback:IsA("BasePart") then fallback else nil
end

local function getAnimationControllerAnimatorFromRig(root: Instance, rigName: string): Animator?
	local rig = root:FindFirstChild(rigName)
	if not rig then
		return nil
	end

	local animationController = rig:FindFirstChildOfClass("AnimationController")
	if not animationController then
		animationController = rig:FindFirstChild("AnimationController", true)
	end
	if not (animationController and animationController:IsA("AnimationController")) then
		return nil
	end

	local animator = animationController:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = animationController
	end
	return animator
end

local function getHumanoidAnimatorFromRig(root: Instance, rigName: string): Animator?
	local rig = root:FindFirstChild(rigName)
	if not (rig and rig:IsA("Model")) then
		return nil
	end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

local function findKeyframeSequence(root: Instance, rigName: string, animationSource): KeyframeSequence?
	local sequenceName = animationSource and animationSource.keyframeSequenceName
	if typeof(sequenceName) ~= "string" or sequenceName == "" then
		return nil
	end

	local rig = root:FindFirstChild(rigName)
	local animSaves = rig and rig:FindFirstChild("AnimSaves")
	local sequence = animSaves and animSaves:FindFirstChild(sequenceName)
	if sequence and sequence:IsA("KeyframeSequence") then
		return sequence
	end

	sequence = root:FindFirstChild(sequenceName, true)
	return if sequence and sequence:IsA("KeyframeSequence") then sequence else nil
end

local function createAnimationFromSource(root: Instance, rigName: string, animationSource, name: string): (Animation?, string?)
	if typeof(animationSource) ~= "table" then
		return nil, nil
	end

	if animationSource.type == POTGCutsceneConfig.AnimationSourceTypes.AnimationId then
		local animationId = animationSource.animationId
		if typeof(animationId) ~= "string" or animationId == "" then
			return nil, nil
		end

		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = animationId
		return animation, animationId
	end

	if animationSource.type == POTGCutsceneConfig.AnimationSourceTypes.KeyframeSequence then
		local sequence = findKeyframeSequence(root, rigName, animationSource)
		if not sequence then
			return nil, nil
		end

		local sequenceClone = sequence:Clone()
		sequenceClone.Loop = false
		local ok, registeredId = pcall(function()
			return KeyframeSequenceProvider:RegisterKeyframeSequence(sequenceClone)
		end)
		sequenceClone:Destroy()
		if not ok or typeof(registeredId) ~= "string" or registeredId == "" then
			warn(("[POTGCutsceneController] Failed to register %s keyframe sequence: %s"):format(
				name,
				tostring(registeredId)
			))
			return nil, nil
		end

		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = registeredId
		return animation, registeredId
	end

	return nil, nil
end

local function prewarmAnimationId(animationId: string)
	if animationId == "" or prewarmedAnimationIds[animationId] then
		return
	end
	prewarmedAnimationIds[animationId] = true

	task.spawn(function()
		local animation = Instance.new("Animation")
		animation.Name = "POTGCutscenePrewarm"
		animation.AnimationId = animationId

		local ok, err = pcall(function()
			ContentProvider:PreloadAsync({ animation })
		end)
		animation:Destroy()

		if not ok then
			warn(("[POTGCutsceneController] Failed to prewarm animation %s: %s"):format(
				animationId,
				tostring(err)
			))
		end
	end)
end

local function prewarmConfiguredAnimations()
	for _, cutsceneSpec in pairs(POTGCutsceneConfig.Cutscenes or {}) do
		for _, animationSource in ipairs({
			cutsceneSpec.cameraAnimation,
			cutsceneSpec.characterAnimation,
		}) do
			if
				typeof(animationSource) == "table"
				and animationSource.type == POTGCutsceneConfig.AnimationSourceTypes.AnimationId
				and typeof(animationSource.animationId) == "string"
			then
				prewarmAnimationId(animationSource.animationId)
			end
		end
	end
end

local function loadTrack(
	root: Instance,
	animator: Animator,
	rigName: string,
	animationSource,
	name: string
): AnimationTrack?
	local animation, sourceId = createAnimationFromSource(root, rigName, animationSource, name)
	if not animation then
		warn(("[POTGCutsceneController] Missing %s animation source for rig %s"):format(name, rigName))
		return nil
	end

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()

	if ok and track then
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = false
		return track
	end

	warn(("[POTGCutsceneController] Failed to load %s animation id=%s: %s"):format(
		name,
		tostring(sourceId),
		tostring(track)
	))
	return nil
end

local function getCFrameValue(value: any): CFrame?
	return if typeof(value) == "CFrame" then value else nil
end

local function getPreviewCompletionCallback(payload): ((string) -> ())?
	if typeof(payload) == "table" and payload.preview == true and type(payload.onComplete) == "function" then
		return payload.onComplete
	end
	return nil
end

debugCutscene = function(message: string, ...)
	if DEBUG_CUTSCENE then
		print("[POTGCutsceneController] " .. message, ...)
	end
end

local function formatVector(vector: Vector3): string
	return string.format("(%.2f, %.2f, %.2f)", vector.X, vector.Y, vector.Z)
end

local function primeCutsceneTracks(tracks: { AnimationTrack })
	for _, track in ipairs(tracks) do
		track.Looped = false
		local ok, err = pcall(function()
			track:Play(0, 1, 0)
			track.TimePosition = 0
			track:AdjustSpeed(0)
		end)
		if not ok then
			warn(("[POTGCutsceneController] Failed to prime animation track %s: %s"):format(track.Name, tostring(err)))
		end
	end

	RunService.Heartbeat:Wait()

	for _, track in ipairs(tracks) do
		pcall(function()
			track.TimePosition = 0
			track:AdjustSpeed(0)
		end)
	end
end

local function resumeCutsceneTracks(tracks: { AnimationTrack })
	for _, track in ipairs(tracks) do
		track.Looped = false
		local ok, err = pcall(function()
			track.TimePosition = 0
			if track.IsPlaying then
				track:AdjustSpeed(1)
			else
				track:Play(0, 1, 1)
			end
			track.Looped = false
		end)
		if not ok then
			warn(("[POTGCutsceneController] Failed to resume animation track %s: %s"):format(track.Name, tostring(err)))
		end
	end
end

local function getTrackHoldLength(record: TrackHoldRecord): number
	if record.length <= 0 and record.track.Length > 0 then
		record.length = record.track.Length
	end
	return record.length
end

local function buildTrackHoldRecords(tracks: { AnimationTrack }): { TrackHoldRecord }
	local records = {}
	for index, track in ipairs(tracks) do
		table.insert(records, {
			track = track,
			name = if track.Name ~= "" then track.Name else "Track" .. tostring(index),
			length = math.max(track.Length, 0),
			held = false,
		})
	end
	return records
end

local function getTrackHoldRecord(records: { TrackHoldRecord }, track: AnimationTrack): TrackHoldRecord?
	for _, record in ipairs(records) do
		if record.track == track then
			return record
		end
	end
	return nil
end

local function getLongestTrackHoldLength(records: { TrackHoldRecord }): number
	local longest = 0
	for _, record in ipairs(records) do
		longest = math.max(longest, getTrackHoldLength(record))
	end
	return longest
end

local function debugCutscenePlacement(
	root: Model,
	cutsceneSpec,
	cameraBone: BasePart,
	placementAnchor: BasePart?,
	tracks: { AnimationTrack },
	label: string?
)
	if not DEBUG_CUTSCENE then
		return
	end

	local rig = getCharacterRig(root, cutsceneSpec)
	local head = rig and rig:FindFirstChild("Head")
	local anchorName = if placementAnchor then placementAnchor:GetFullName() else "nil"
	debugCutscene(label or "Placement", "anchor", anchorName)

	if head and head:IsA("BasePart") then
		local offset = head.Position - cameraBone.Position
		debugCutscene(
			"Head relative to camera",
			"forward",
			string.format("%.2f", offset:Dot(cameraBone.CFrame.LookVector)),
			"right",
			string.format("%.2f", offset:Dot(cameraBone.CFrame.RightVector)),
			"up",
			string.format("%.2f", offset:Dot(cameraBone.CFrame.UpVector)),
			"worldOffset",
			formatVector(offset)
		)
	else
		debugCutscene("Head relative to camera unavailable")
	end

	for _, track in ipairs(tracks) do
		debugCutscene(
			"Track",
			track.Name,
			"length",
			string.format("%.3f", track.Length),
			"isPlaying",
			tostring(track.IsPlaying),
			"time",
			string.format("%.3f", track.TimePosition)
		)
	end
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

local function stopCutsceneSounds(sounds: { Sound })
	for _, sound in ipairs(sounds) do
		pcall(function()
			sound:Stop()
			sound:Destroy()
		end)
	end
	table.clear(sounds)
end

local function getCutsceneTrackSound(soundName: any): Sound?
	if typeof(soundName) ~= "string" or soundName == "" then
		return nil
	end

	local tracksFolder = workspace:FindFirstChild(CUTSCENE_TRACKS_FOLDER_NAME)
	local source = tracksFolder and tracksFolder:FindFirstChild(soundName)
	if source and source:IsA("Sound") then
		return source
	end

	local fallbackName = CUTSCENE_SOUND_FALLBACKS[soundName]
	local fallback = SoundUtil.Resolve(fallbackName or soundName)
	return if fallback and fallback:IsA("Sound") then fallback else nil
end

local function playCutsceneSound(active: ActiveCutscene, soundName: any)
	local source = getCutsceneTrackSound(soundName)
	if not source then
		warn(("[POTGCutsceneController] Missing cutscene sound %s.%s"):format(
			CUTSCENE_TRACKS_FOLDER_NAME,
			tostring(soundName)
		))
		return
	end

	local sound = source:Clone()
	sound.Name = "POTGHighlightIntroSound_" .. source.Name
	sound.Looped = false
	sound.TimePosition = 0
	sound.PlayOnRemove = false
	sound.Parent = SoundService
	table.insert(active.activeSounds, sound)

	local endedConnection: RBXScriptConnection? = nil
	endedConnection = sound.Ended:Connect(function()
		if endedConnection then
			endedConnection:Disconnect()
		end
		if sound.Parent then
			sound:Destroy()
		end
	end)
	table.insert(active.connections, endedConnection)

	local ok, err = pcall(function()
		sound:Play()
	end)
	if not ok then
		warn(("[POTGCutsceneController] Failed to play cutscene sound %s: %s"):format(source.Name, tostring(err)))
		sound:Destroy()
	end
end

local function getTimelineValue(keys, elapsed: number): number
	local firstKey = keys[1]
	if not firstKey then
		return 0
	end
	if elapsed <= firstKey.time then
		return firstKey.value
	end

	for index = 2, #keys do
		local previousKey = keys[index - 1]
		local nextKey = keys[index]
		if elapsed < nextKey.time then
			if previousKey.easingStyle == "Constant" then
				return previousKey.value
			end

			local duration = math.max(nextKey.time - previousKey.time, 0.001)
			local alpha = math.clamp((elapsed - previousKey.time) / duration, 0, 1)
			if previousKey.easingStyle then
				alpha = TweenService:GetValue(
					alpha,
					previousKey.easingStyle,
					previousKey.easingDirection or Enum.EasingDirection.Out
				)
			end
			return previousKey.value + (nextKey.value - previousKey.value) * alpha
		end
	end

	return keys[#keys].value
end

local function resolveCutscenePath(root: Instance, path: string): Instance?
	local current: Instance? = root
	for pathSegment in string.gmatch(path, "[^%.]+") do
		current = current and current:FindFirstChild(pathSegment)
		if not current then
			return nil
		end
	end
	return current
end

local function getCFrameTrackAlpha(previousKey, nextKey, elapsed: number): number
	if previousKey.easingStyle == "Constant" then
		return 0
	end

	local duration = math.max(nextKey.time - previousKey.time, 0.001)
	local alpha = math.clamp((elapsed - previousKey.time) / duration, 0, 1)
	if not previousKey.easingStyle then
		return alpha
	end

	return TweenService:GetValue(alpha, previousKey.easingStyle, previousKey.easingDirection or Enum.EasingDirection.Out)
end

local function getMotionTrackCFrame(keys, elapsed: number): CFrame?
	local firstKey = keys[1]
	if not firstKey then
		return nil
	end
	if elapsed <= firstKey.time then
		return firstKey.cframe
	end

	for index = 2, #keys do
		local previousKey = keys[index - 1]
		local nextKey = keys[index]
		if elapsed < nextKey.time then
			local alpha = getCFrameTrackAlpha(previousKey, nextKey, elapsed)
			return previousKey.cframe:Lerp(nextKey.cframe, alpha)
		end
	end

	return keys[#keys].cframe
end

local function getLastMotionKeyTime(keys): number
	local lastKey = keys[#keys]
	return if lastKey and isFiniteNumber(lastKey.time) then lastKey.time else 0
end

local function buildMotionRecords(root: Model, cutsceneSpec): { any }
	local records = {}
	for _, track in ipairs(cutsceneSpec.motionTracks or {}) do
		if typeof(track.path) ~= "string" or typeof(track.keys) ~= "table" then
			continue
		end

		local target = resolveCutscenePath(root, track.path)
		if not target then
			if DEBUG_CUTSCENE then
				warn(("[POTGCutsceneController] Cutscene %s is missing motion target %s"):format(
					tostring(cutsceneSpec.id),
					tostring(track.path)
				))
			end
			continue
		end

		if track.apply == "LocalCFrame" and not (target:IsA("Attachment") or target:IsA("BasePart")) then
			if DEBUG_CUTSCENE then
				warn(("[POTGCutsceneController] Motion target %s expected Attachment or BasePart for LocalCFrame, got %s"):format(
					tostring(track.path),
					target.ClassName
				))
			end
			continue
		end

		if track.apply ~= "LocalCFrame" and not (target:IsA("BasePart") or target:IsA("Model") or target:IsA("Attachment")) then
			if DEBUG_CUTSCENE then
				warn(("[POTGCutsceneController] Motion target %s cannot receive WorldCFrame, got %s"):format(
					tostring(track.path),
					target.ClassName
				))
			end
			continue
		end

		table.insert(records, {
			path = track.path,
			target = target,
			apply = track.apply,
			depth = select(2, track.path:gsub("%.", ".")),
			keys = track.keys,
			sourceWorldPivotCFrame = if typeof(track.sourceWorldPivotCFrame) == "CFrame"
				then track.sourceWorldPivotCFrame
				else nil,
			targetWorldPivotCFrame = nil,
			lastKeyTime = getLastMotionKeyTime(track.keys),
			holdFinalWorldCFrame = track.apply ~= "LocalCFrame" and track.holdFinalWorldCFrame ~= false,
			finalWorldCFrame = nil,
		})
	end
	table.sort(records, function(a, b)
		return a.depth < b.depth
	end)
	return records
end

local function applyWorldCFrameToMotionTarget(target: Instance, worldCFrame: CFrame)
	if target:IsA("BasePart") then
		target.CFrame = worldCFrame
		target.Anchored = true
		target.AssemblyLinearVelocity = Vector3.zero
		target.AssemblyAngularVelocity = Vector3.zero
	elseif target:IsA("Model") then
		target:PivotTo(worldCFrame)
	elseif target:IsA("Attachment") then
		target.WorldCFrame = worldCFrame
	end
end

local function getMotionTargetWorldCFrame(target: Instance): CFrame?
	if target:IsA("BasePart") then
		return target.CFrame
	elseif target:IsA("Model") then
		return target:GetPivot()
	elseif target:IsA("Attachment") then
		return target.WorldCFrame
	end
	return nil
end

local function getActiveMotionTargetPivot(active: ActiveCutscene): CFrame
	local pivotPart = active.motionTargetPivotPart
	return if pivotPart and pivotPart.Parent then pivotPart.CFrame else active.motionTargetPivot
end

local function getRecordTargetWorldPivot(active: ActiveCutscene, record): CFrame
	local targetPivot = record.targetWorldPivotCFrame
	return if typeof(targetPivot) == "CFrame" then targetPivot else getActiveMotionTargetPivot(active)
end

local function getRecordSourceWorldPivot(active: ActiveCutscene, record): CFrame
	local sourcePivot = record.sourceWorldPivotCFrame
	return if typeof(sourcePivot) == "CFrame" then sourcePivot else active.motionSourcePivot
end

local function getWorldMotionCFrame(active: ActiveCutscene, record, sourceCFrame: CFrame): CFrame
	local sourcePivot = getRecordSourceWorldPivot(active, record)
	local targetPivot = getRecordTargetWorldPivot(active, record)
	return targetPivot * sourcePivot:ToObjectSpace(sourceCFrame)
end

local function initializeMotionRecordWorldPivots(active: ActiveCutscene)
	for _, record in ipairs(active.motionRecords) do
		if record.apply == "LocalCFrame" then
			continue
		end
		if not record.sourceWorldPivotCFrame then
			continue
		end

		local target = record.target
		if target and target.Parent then
			record.targetWorldPivotCFrame = getMotionTargetWorldCFrame(target)
		end
	end
end

local function applyCutsceneMotion(active: ActiveCutscene, elapsed: number, useFinalHold: boolean?)
	local shouldUseFinalHold = useFinalHold ~= false
	for _, record in ipairs(active.motionRecords) do
		local target = record.target
		if not (target and target.Parent) then
			continue
		end

		if
			shouldUseFinalHold
			and record.holdFinalWorldCFrame
			and record.finalWorldCFrame
			and elapsed > record.lastKeyTime
		then
			applyWorldCFrameToMotionTarget(target, record.finalWorldCFrame)
			continue
		end

		local sourceCFrame = getMotionTrackCFrame(record.keys, elapsed)
		if not sourceCFrame then
			continue
		end

		if record.apply == "LocalCFrame" then
			if target:IsA("Attachment") then
				target.CFrame = sourceCFrame
			elseif target:IsA("BasePart") then
				target.Anchored = true
				target.AssemblyLinearVelocity = Vector3.zero
				target.AssemblyAngularVelocity = Vector3.zero

				local parent = target.Parent
				if parent and parent:IsA("BasePart") then
					target.CFrame = parent.CFrame * sourceCFrame
				elseif parent and parent:IsA("Attachment") then
					target.CFrame = parent.WorldCFrame * sourceCFrame
				else
					target.CFrame = getWorldMotionCFrame(active, record, sourceCFrame)
				end
			end
			continue
		end

		local worldCFrame = getWorldMotionCFrame(active, record, sourceCFrame)
		applyWorldCFrameToMotionTarget(target, worldCFrame)
	end
end

local function initializeFinalMotionHolds(active: ActiveCutscene)
	for _, record in ipairs(active.motionRecords) do
		if not record.holdFinalWorldCFrame then
			continue
		end

		applyCutsceneMotion(active, record.lastKeyTime, false)
		local target = record.target
		if target and target.Parent then
			record.finalWorldCFrame = getMotionTargetWorldCFrame(target)
		end
	end

	applyCutsceneMotion(active, 0, false)
end

local function createCutsceneDOF(cutsceneSpec): DepthOfFieldEffect?
	local existing = Lighting:FindFirstChild(CUTSCENE_DOF_NAME)
	if existing then
		existing:Destroy()
	end

	local dofConfig = cutsceneSpec.dof
	if not dofConfig or dofConfig.enabled == false then
		return nil
	end

	local dof = Instance.new("DepthOfFieldEffect")
	dof.Name = CUTSCENE_DOF_NAME
	dof.Enabled = true
	dof.FarIntensity = dofConfig.farIntensity or 0
	dof.FocusDistance = dofConfig.focusDistance or 0
	dof.InFocusRadius = if dofConfig.inFocusRadiusKeys and dofConfig.inFocusRadiusKeys[1]
		then dofConfig.inFocusRadiusKeys[1].value
		else 0
	dof.NearIntensity = dofConfig.nearIntensity or 0
	dof.Parent = Lighting
	return dof
end

local function isActivePlayback(controller, active: ActiveCutscene): boolean
	return controller._active == active and active.playbackStarted and not active.finishing and not active.completed
end

local function updateCutsceneProperties(active: ActiveCutscene, camera: Camera, elapsed: number)
	local cutsceneSpec = active.cutsceneSpec
	camera.FieldOfView = getTimelineValue(cutsceneSpec.cameraFovKeys or {}, elapsed)

	local dof = active.dofEffect
	local dofConfig = cutsceneSpec.dof
	if dof and dof.Parent and dofConfig and dofConfig.enabled ~= false then
		dof.Enabled = true
		dof.FarIntensity = dofConfig.farIntensity or 0
		dof.FocusDistance = dofConfig.focusDistance or 0
		dof.NearIntensity = dofConfig.nearIntensity or 0
		dof.InFocusRadius = getTimelineValue(dofConfig.inFocusRadiusKeys or {}, elapsed)
	end
end

local function getCameraBoneMotor(cameraBone: BasePart): Motor6D?
	local preferred = cameraBone:FindFirstChild("cameraMotor6D")
	if preferred and preferred:IsA("Motor6D") and preferred.Part0 and preferred.Part1 == cameraBone then
		return preferred
	end

	local rig = cameraBone.Parent
	if rig then
		for _, descendant in ipairs(rig:GetDescendants()) do
			if descendant:IsA("Motor6D") and descendant.Part0 and descendant.Part1 == cameraBone then
				return descendant
			end
		end
	end

	return nil
end

local function getAnimatedCameraBoneCFrame(cameraBone: BasePart): CFrame
	local motor = getCameraBoneMotor(cameraBone)
	if motor and motor.Part0 then
		return motor.Part0.CFrame * motor.C0 * motor.Transform * motor.C1:Inverse()
	end

	return cameraBone.CFrame
end

local function holdTrackAtFinalPose(active: ActiveCutscene, record: TrackHoldRecord)
	if record.held then
		return
	end

	local track = record.track
	local trackLength = getTrackHoldLength(record)
	if track and trackLength > 0 then
		pcall(function()
			track.TimePosition = math.max(trackLength - TRACK_FINAL_POSE_OFFSET_SECONDS, 0)
			track:AdjustSpeed(0)
		end)
	end
	record.held = true

	debugCutscene(
		"Animation track held",
		"cutsceneId",
		tostring(active.cutsceneSpec.id),
		"track",
		record.name,
		"trackLength",
		string.format("%.3f", trackLength)
	)
end

local function holdExpiredCutsceneTracks(active: ActiveCutscene, elapsed: number)
	for _, record in ipairs(active.heldTracks) do
		local trackLength = getTrackHoldLength(record)
		if trackLength > 0 and elapsed >= math.max(trackLength - TRACK_HOLD_LEAD_SECONDS, 0) then
			holdTrackAtFinalPose(active, record)
		end
	end
end

local function attachCameraToCameraBone(active: ActiveCutscene, camera: Camera, elapsed: number)
	local cameraTrackHold = active.cameraTrackHold
	local cameraTrackLength = if cameraTrackHold then getTrackHoldLength(cameraTrackHold) else 0
	local shouldHoldCamera = if cameraTrackHold
		then cameraTrackHold.held or (cameraTrackLength > 0 and elapsed >= math.max(cameraTrackLength - TRACK_HOLD_LEAD_SECONDS, 0))
		else false
	local cameraCFrame
	if shouldHoldCamera then
		cameraCFrame = active.cameraHoldCFrame or getAnimatedCameraBoneCFrame(active.cameraBone)
		active.cameraHoldCFrame = cameraCFrame
	else
		cameraCFrame = getAnimatedCameraBoneCFrame(active.cameraBone)
		active.cameraHoldCFrame = cameraCFrame
	end

	LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, true)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = cameraCFrame
	camera.Focus = cameraCFrame
	updateCutsceneProperties(active, camera, elapsed)
end

local getMoonVFXModule
local invokeVFXMethod

local function emitCutsceneEffect(active: ActiveCutscene, effectName: string): boolean
	local effect = active.clone:FindFirstChild(effectName) or active.clone:FindFirstChild(effectName, true)
	if not effect then
		warn(("[POTGCutsceneController] Missing highlight intro effect %s"):format(effectName))
		return false
	end

	local handler = getMoonVFXModule()
	if type(invokeVFXMethod) == "function" and invokeVFXMethod(handler, "Emit", effect) then
		return true
	end

	return EmitService.Emit(effect, EMIT_WARN_PREFIX, 10)
end

local function parseCodePathTokens(rawPath: string): { string }
	local tokens = {}
	local index = 1
	local length = #rawPath

	while index <= length do
		local char = rawPath:sub(index, index)
		if char == "." or char == " " or char == "\t" or char == "\n" or char == "\r" then
			index += 1
			continue
		end

		if char == "[" then
			local nextChar = rawPath:sub(index + 1, index + 1)
			if nextChar == "'" or nextChar == '"' then
				local close = rawPath:find(nextChar, index + 2, true)
				if close then
					table.insert(tokens, rawPath:sub(index + 2, close - 1))
					index = close + 1
					if rawPath:sub(index, index) == "]" then
						index += 1
					end
					continue
				end
			else
				local close = rawPath:find("]", index + 1, true)
				if close then
					local token = rawPath:sub(index + 1, close - 1):gsub("^%s*(.-)%s*$", "%1")
					if token ~= "" then
						table.insert(tokens, token)
					end
					index = close + 1
					continue
				end
			end
		end

		if char:match("[%w_]") then
			local token = rawPath:match("^([%w_]+)", index)
			if token then
				table.insert(tokens, token)
				index += #token
				continue
			end
		end

		index += 1
	end

	return tokens
end

local function isEmitCapableInstance(instance: Instance): boolean
	if instance:IsA("ParticleEmitter")
		or instance:IsA("Beam")
		or instance:IsA("Trail")
		or instance:IsA("Fire")
		or instance:IsA("Smoke")
		or instance:IsA("Sparkles")
		or instance:IsA("PointLight")
		or instance:IsA("SpotLight")
		or instance:IsA("SurfaceLight")
	then
		return true
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter")
			or descendant:IsA("Beam")
			or descendant:IsA("Trail")
			or descendant:IsA("Fire")
			or descendant:IsA("Smoke")
			or descendant:IsA("Sparkles")
			or descendant:IsA("PointLight")
			or descendant:IsA("SpotLight")
			or descendant:IsA("SurfaceLight")
		then
			return true
		end
	end
	return false
end

local function pathSuffixMatches(instance: Instance, root: Instance, suffixTokens: { string }): boolean
	local current: Instance? = instance
	local index = #suffixTokens
	while current and current ~= root and index > 0 do
		if current.Name ~= suffixTokens[index] then
			return false
		end
		index -= 1
		current = current.Parent
	end
	return current == root and index == 0
end

local function getInstanceHierarchyDepth(instance: Instance): number
	local depth = 0
	while instance do
		depth += 1
		instance = instance.Parent
	end
	return depth
end

local function parseEmitTargetFromCode(
	active: ActiveCutscene,
	code: string,
	expectedEffectName: string?
): Instance?
	local arg = code:match("EmitModule%s*:%s*Emit%s*%((.-)%)")
	if not arg then
		return nil
	end

	local tokens = parseCodePathTokens(arg)
	if #tokens == 0 then
		return nil
	end

	local normalizedExpected = if typeof(expectedEffectName) == "string" then expectedEffectName else nil
	local expectedCandidate: Instance? = nil
	if normalizedExpected then
		local expected = active.clone:FindFirstChild(normalizedExpected, true)
		if expected and isEmitCapableInstance(expected) then
			return expected
		end
		expectedCandidate = expected
	end

	local ignoredPrefixes = {
		game = true,
		Game = true,
		workspace = true,
		Workspace = true,
		ReplicatedStorage = true,
		replicatedstorage = true,
		HighlightIntros = true,
		highlightIntros = true,
	}

	for start = 1, #tokens do
		if ignoredPrefixes[tokens[start]] then
			continue
		end

		local pathTokens = {}
		for index = start, #tokens do
			pathTokens[#pathTokens + 1] = tokens[index]
		end

		local path = table.concat(pathTokens, ".")
		local target = resolveCutscenePath(active.clone, path)
		if target then
			return target
		end

		local candidates = {}
		for _, candidate in ipairs(active.clone:GetDescendants()) do
			if candidate.Name == pathTokens[#pathTokens] and pathSuffixMatches(candidate, active.clone, pathTokens) then
				candidates[#candidates + 1] = candidate
			end
		end

		if #candidates > 0 then
			table.sort(candidates, function(a, b)
				local aScore = (isEmitCapableInstance(a) and 8 or 0)
					+ (a.Name == normalizedExpected and 4 or 0)
					- (getInstanceHierarchyDepth(a) * 0.01)
				local bScore = (isEmitCapableInstance(b) and 8 or 0)
					+ (b.Name == normalizedExpected and 4 or 0)
					- (getInstanceHierarchyDepth(b) * 0.01)
				return aScore > bScore
			end)
			return candidates[1]
		end
	end

	return active.clone:FindFirstChild(tokens[#tokens], true)
		or expectedCandidate
		or active.clone:FindFirstChild(normalizedExpected or "", true)
		or active.clone:FindFirstChild(arg, true)
end

local function parseImpactFramesFromCode(code: string): (number?, Color3?)
	local framesText = code:match("ImpactFrames%s*%(%s*([%d%.]+)")
	if not framesText then
		return nil, nil
	end

	local frames = tonumber(framesText)
	if not frames then
		return nil, nil
	end

	local r, g, b = code:match("Color3%.fromRGB%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)")
	if not r then
		return frames, nil
	end

	return frames, Color3.fromRGB(tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0)
end

function getMoonVFXModule(): any?
	if checkedForMoonVFXModule then
		return moonVFXModule
	end
	checkedForMoonVFXModule = true

	local moonModule = ReplicatedStorage:FindFirstChild(VFX_HANDLER_NAME)
		or ReplicatedStorage:FindFirstChild(VFX_HANDLER_NAME, true)
	if not moonModule or not moonModule:IsA("ModuleScript") then
		return nil
	end

	local ok, module = pcall(function()
		return require(moonModule)
	end)
	if not ok or typeof(module) ~= "table" then
		warn(EMIT_WARN_PREFIX .. " Failed to require " .. VFX_HANDLER_NAME .. ": " .. tostring(module))
		return nil
	end

	moonVFXModule = module
	moonVFXModuleInitialized = false

	return moonVFXModule
end

local function initializeMoonVFXModule(module: any): boolean
	if not module then
		return false
	end

	local initMethods = { "Init", "init" }
	for _, methodName in ipairs(initMethods) do
		local method = module[methodName]
		if type(method) ~= "function" then
			continue
		end

		local ok = pcall(function()
			method(module)
		end)
		if ok then
			return true
		end

		ok = pcall(method)
		if ok then
			return true
		end
	end

	return false
end

local function ensureMoonVFXInitialized(): boolean
	if moonVFXModuleInitialized then
		return true
	end

	local module = getMoonVFXModule()
	if not module then
		return false
	end

	moonVFXModuleInitialized = initializeMoonVFXModule(module)
	return moonVFXModuleInitialized
end

function invokeVFXMethod(module: any, methodName: string, ...): boolean
	if module == moonVFXModule and not moonVFXModuleInitialized then
		ensureMoonVFXInitialized()
	end

	local methodNames = {
		methodName,
		string.lower(methodName),
		string.gsub(methodName, "^%u", string.lower),
	}

	for _, candidate in ipairs(methodNames) do
		local method = module and module[candidate]
		if type(method) ~= "function" then
			continue
		end

		local args = table.pack(...)
		local function invoke()
			return method(module, table.unpack(args, 1, args.n))
		end
		local function invokeNoSelf()
			return method(table.unpack(args, 1, args.n))
		end

		local ok, result = pcall(invoke)
		if ok and result ~= false then
			return true
		end
		ok, result = pcall(invokeNoSelf)
		if ok and result ~= false then
			return true
		end
	end

	return false
end

local function runMoonCodeEvent(active: ActiveCutscene, code: string, expectedEffectName: string?)
	local target = parseEmitTargetFromCode(active, code, expectedEffectName)
	if target then
		if invokeVFXMethod(getMoonVFXModule(), "Emit", target) then
			return true
		end

		if EmitService.Emit(target, EMIT_WARN_PREFIX, 10) then
			return true
		end

		return false
	end

	local frames, color = parseImpactFramesFromCode(code)
	if frames then
		if invokeVFXMethod(getMoonVFXModule(), "ImpactFrames", frames, color) then
			return true
		end
		ScreenEffects.ImpactFrames(frames, color)
		return true
	end

	return false
end

local function runCutsceneEvent(active: ActiveCutscene, event)
	if event.type == "Sound" then
		playCutsceneSound(active, event.soundName)
		return
	end

	if event.type == "Code" and typeof(event.code) == "string" then
		if runMoonCodeEvent(active, event.code, typeof(event.effectName) == "string" and event.effectName or nil) then
			return
		end

		if event.effectName then
			emitCutsceneEffect(active, event.effectName)
			return
		end

		if event.frames or event.color then
			local frames = if isFiniteNumber(event.frames) then math.max(math.floor(event.frames), 1) else 1
			local color = if typeof(event.color) == "Color3" then event.color else Color3.new(1, 1, 1)
			ScreenEffects.ImpactFrames(frames, color)
			return
		end
	end

	if event.type == "ImpactFrames" then
		local frames = if isFiniteNumber(event.frames) then math.max(math.floor(event.frames), 1) else 1
		local color = if typeof(event.color) == "Color3" then event.color else Color3.new(1, 1, 1)
		ScreenEffects.ImpactFrames(frames, color)
		return
	end

	if event.type == "Emit" or event.effectName then
		emitCutsceneEffect(active, event.effectName)
	end
end

local function warnMissingCutsceneRequirements(
	cutsceneSpec,
	clone: Model,
	cameraBone: Instance?,
	camRigAnimator: Animator?,
	characterAnimator: Animator?
)
	local children = {}
	for _, child in ipairs(clone:GetChildren()) do
		table.insert(children, child.Name .. ":" .. child.ClassName)
	end
	table.sort(children)

	warn(
		("[POTGCutsceneController] Cutscene %s is missing required rig instances cameraBone=%s camRigAnimator=%s characterAnimator=%s children={%s}"):format(
			tostring(cutsceneSpec.id),
			tostring(cameraBone ~= nil),
			tostring(camRigAnimator ~= nil),
			tostring(characterAnimator ~= nil),
			table.concat(children, ", ")
		)
	)
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
	stopCutsceneSounds(active.activeSounds)
	if active.dofEffect and active.dofEffect.Parent then
		active.dofEffect:Destroy()
	end

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

function POTGCutsceneController:_flushAfterRoundIntro()
	local callbacks = self._afterRoundIntroCallbacks
	self._afterRoundIntroCallbacks = {}
	for _, callback in ipairs(callbacks) do
		task.defer(callback)
	end
end

function POTGCutsceneController:_completeRoundIntro(roundId: number?, reason: string)
	if not self._roundIntroActive then
		return
	end

	self._roundIntroActive = false
	self.RoundIntroCompleted:Fire({
		roundId = roundId,
		reason = reason,
	})
	self:_flushAfterRoundIntro()
end

function POTGCutsceneController:_completePreview(active: ActiveCutscene, reason: string, deferCallback: boolean?)
	local callback = active.previewOnComplete
	if not callback then
		return
	end

	active.previewOnComplete = nil
	if deferCallback == false then
		local ok, err = pcall(function()
			callback(reason)
		end)
		if not ok then
			warn(("[POTGCutsceneController] Preview completion callback failed: %s"):format(tostring(err)))
		end
		return
	end

	task.defer(function()
		callback(reason)
	end)
end

function POTGCutsceneController:_reportCompletion(active: ActiveCutscene, reason: string)
	if active.completionReported or not active.roundId then
		return
	end

	active.completionReported = true
	local remote = active.completionRemote
	if remote and remote.Parent then
		remote:FireServer({
			roundId = active.roundId,
			reason = reason,
		})
	end

	if active.isRoundIntro then
		self:_completeRoundIntro(active.roundId, reason)
	end
end

function POTGCutsceneController:_reportPayloadCompletion(payload, reason: string)
	if typeof(payload) ~= "table" or typeof(payload.roundId) ~= "number" then
		return
	end

	local remote = self._roundIntroCompleteRemote or getRoundIntroCompleteRemote()
	self._roundIntroCompleteRemote = remote
	if remote then
		remote:FireServer({
			roundId = payload.roundId,
			reason = reason,
		})
	end

	self:_completeRoundIntro(payload.roundId, reason)
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
		self:_reportCompletion(active, "Canceled")
		self:_completePreview(active, "Canceled")
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

		if active.holdBlackOnFinish then
			ScreenEffects.HoldBlack()
			active.completed = true
			if self._active == active then
				self._active = nil
			end
			self:_destroyOverlay(active)
			debugCutscene("Finished", "roundId", tostring(active.roundId), "reason", "Completed")
			self:_reportCompletion(active, "Completed")
			self:_completePreview(active, "Completed")
			return
		end

		if active.revealAfterPreviewCallback then
			self:_completePreview(active, "Completed", false)
		end

		local fromBlack = self:_startFade(active, 1, FADE_FROM_BLACK_SECONDS)
		self:_waitForFade(active, fromBlack)

		active.completed = true
		if self._active == active then
			self._active = nil
		end
		self:_destroyOverlay(active)
		debugCutscene("Finished", "roundId", tostring(active.roundId), "reason", "Completed")
		self:_reportCompletion(active, "Completed")
		self:_completePreview(active, "Completed")
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
	active.playbackStartedAt = os.clock()
	active.endAt = os.clock() + active.durationSeconds
	debugCutscene(
		"Started",
		"roundId",
		tostring(active.roundId),
		"duration",
		string.format("%.2f", active.durationSeconds)
	)

	applyCutsceneMotion(active, 0)
	attachCameraToCameraBone(active, camera, 0)

	self:_unbindCamera()
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function()
		local token = RuntimeProfiler.Begin("Client/POTGCutsceneController/Render")
		if self._active ~= active then
			RuntimeProfiler.End("Client/POTGCutsceneController/Render", token)
			return
		end
		if not active.finishing and os.clock() >= active.endAt then
			self:_finish(active, true)
			RuntimeProfiler.End("Client/POTGCutsceneController/Render", token)
			return
		end
		local currentCamera = workspace.CurrentCamera
		if currentCamera and active.cameraBone.Parent then
			local elapsed = math.max(os.clock() - active.playbackStartedAt, 0)
			holdExpiredCutsceneTracks(active, elapsed)
			applyCutsceneMotion(active, elapsed)
			attachCameraToCameraBone(active, currentCamera, elapsed)
		else
			self:_finish(active, false)
		end
		RuntimeProfiler.End("Client/POTGCutsceneController/Render", token)
	end)

	resumeCutsceneTracks(active.tracks)
	if DEBUG_CUTSCENE then
		task.delay(0.1, function()
			if self._active == active and active.playbackStarted and not active.completed and active.cameraBone.Parent then
				debugCutscenePlacement(
					active.clone,
					active.cutsceneSpec,
					active.cameraBone,
					active.placementAnchor,
					active.tracks,
					"Post-start placement"
				)
			end
		end)
	end

	for _, event in ipairs(active.cutsceneSpec.events or {}) do
		local delaySeconds = math.max(event.time, 0)
		task.delay(delaySeconds, function()
			if isActivePlayback(self, active) then
				runCutsceneEvent(active, event)
			end
		end)
	end
end

function POTGCutsceneController:_play(payload)
	self:_cancelActive()
	self._restoreSerial += 1
	local restoreSerial = self._restoreSerial

	local isRoundIntro = typeof(payload) == "table" and payload.type == "POTGIntro"
	local isPreview = typeof(payload) == "table" and payload.preview == true
	local previewOnComplete = getPreviewCompletionCallback(payload)
	local function completePreview(reason: string)
		if previewOnComplete then
			local callback = previewOnComplete
			previewOnComplete = nil
			task.defer(function()
				callback(reason)
			end)
		end
	end
	local cutsceneSpec = POTGCutsceneConfig.GetCutscene(
		if typeof(payload) == "table" then payload.cutsceneId else POTGCutsceneConfig.DefaultCutsceneId
	)
	local template, serverPreparedTemplate = getCutsceneTemplate(cutsceneSpec, payload)
	local camera = workspace.CurrentCamera
	if not template or not camera then
		warn(("[POTGCutsceneController] Missing cutscene template %s or CurrentCamera"):format(
			tostring(cutsceneSpec and cutsceneSpec.id)
		))
		if isRoundIntro then
			self:_reportPayloadCompletion(payload, "Unavailable")
		end
		completePreview("Unavailable")
		return
	end

	if not validateHighlightIntroTemplate(template, cutsceneSpec) then
		if isRoundIntro then
			self:_reportPayloadCompletion(payload, "InvalidTemplate")
		end
		completePreview("InvalidTemplate")
		return
	end

	local clone = cloneCutsceneTemplate(template)
	forceNonLoopingCutsceneAnimations(clone)
	clone.Parent = getCutsceneFolder()

	local cameraBone = getCameraPart(clone, cutsceneSpec)
	local camRigAnimator = getAnimationControllerAnimatorFromRig(clone, cutsceneSpec.cameraRigName)
	local shouldApplyCandidateAppearance = isRoundIntro or (isPreview and getCandidateUserId(payload) ~= nil)
	local characterAnimator = if shouldApplyCandidateAppearance
		then applyCandidateAppearanceToAuthoredRig(clone, cutsceneSpec, payload, serverPreparedTemplate)
		else nil
	characterAnimator = characterAnimator or getHumanoidAnimatorFromRig(clone, cutsceneSpec.characterRigName)
	if not (cameraBone and camRigAnimator and characterAnimator) then
		warnMissingCutsceneRequirements(cutsceneSpec, clone, cameraBone, camRigAnimator, characterAnimator)
		clone:Destroy()
		if isRoundIntro then
			self:_reportPayloadCompletion(payload, "InvalidTemplate")
		end
		completePreview("InvalidTemplate")
		return
	end

	prepCutsceneClone(clone)
	hideCameraRigVisuals(clone, cutsceneSpec)
	local targetCameraCFrame = if isRoundIntro or isPreview then getCFrameValue(payload.cameraCFrame) else nil

	local camTrack = loadTrack(
		clone,
		camRigAnimator,
		cutsceneSpec.cameraRigName,
		cutsceneSpec.cameraAnimation,
		cutsceneSpec.id .. "CameraRig"
	)
	local characterTrack =
		loadTrack(
			clone,
			characterAnimator,
			cutsceneSpec.characterRigName,
			cutsceneSpec.characterAnimation,
			cutsceneSpec.id .. "CharacterRig"
		)
	if not camTrack then
		warn(("[POTGCutsceneController] No %s camera animation loaded with usable length"):format(
			tostring(cutsceneSpec.id)
		))
		if characterTrack then
			pcall(function()
				characterTrack:Destroy()
			end)
		end
		clone:Destroy()
		if isRoundIntro then
			self:_reportPayloadCompletion(payload, "NoCameraTrackLength")
		end
		completePreview("NoCameraTrackLength")
		return
	end
	if not characterTrack then
		warn(("[POTGCutsceneController] No %s character animation loaded with usable length"):format(
			tostring(cutsceneSpec.id)
		))
		pcall(function()
			camTrack:Destroy()
		end)
		clone:Destroy()
		if isRoundIntro then
			self:_reportPayloadCompletion(payload, "NoCharacterTrackLength")
		end
		completePreview("NoCharacterTrackLength")
		return
	end

	local tracks = {}
	table.insert(tracks, camTrack)
	table.insert(tracks, characterTrack)
	primeCutsceneTracks(tracks)
	local heldTracks = buildTrackHoldRecords(tracks)
	local cameraTrackHold = getTrackHoldRecord(heldTracks, camTrack)

	local motionSourcePivot = getMotionSourcePivot(clone, cutsceneSpec)
	local placementAnchor: BasePart? = nil
	if targetCameraCFrame then
		placementAnchor = pivotCutsceneToTarget(clone, cutsceneSpec, targetCameraCFrame, cameraBone)
	end
	local motionTargetPivotPart = getCutscenePivotPart(clone, cutsceneSpec)
	local motionTargetPivot = getMotionTargetPivot(clone, cutsceneSpec, placementAnchor)
	local motionRecords = buildMotionRecords(clone, cutsceneSpec)
	debugCutscenePlacement(clone, cutsceneSpec, cameraBone, placementAnchor, tracks, "Frame-0 placement")

	local overlayGui, overlayFrame = createOverlay()
	local savedCamera = saveCameraState(camera)
	local dofEffect = createCutsceneDOF(cutsceneSpec)
	local completionRemote = if isRoundIntro then self._roundIntroCompleteRemote or getRoundIntroCompleteRemote() else nil
	self._roundIntroCompleteRemote = completionRemote or self._roundIntroCompleteRemote

	local cameraTrackLength = if cameraTrackHold then getTrackHoldLength(cameraTrackHold) else math.max(camTrack.Length, 0)
	local longestTrackLength = getLongestTrackHoldLength(heldTracks)
	local durationSeconds = if cutsceneSpec.durationSeconds > 0
		then cutsceneSpec.durationSeconds
		elseif longestTrackLength > 0
		then longestTrackLength + 0.5
		else FALLBACK_DURATION_SECONDS
	debugCutscene(
		"Prepared",
		"roundId",
		tostring(if isRoundIntro and typeof(payload.roundId) == "number" then payload.roundId else nil),
		"duration",
		string.format("%.2f", durationSeconds),
		"cameraTrackLength",
		string.format("%.2f", cameraTrackLength),
		"longestTrackLength",
		string.format("%.2f", longestTrackLength),
		"cutsceneId",
		tostring(cutsceneSpec.id)
	)

	local active: ActiveCutscene = {
		clone = clone,
		cutsceneSpec = cutsceneSpec,
		cameraBone = cameraBone :: BasePart,
		placementAnchor = placementAnchor,
		dofEffect = dofEffect,
		motionSourcePivot = motionSourcePivot,
		motionTargetPivot = motionTargetPivot,
		motionTargetPivotPart = motionTargetPivotPart,
		motionRecords = motionRecords,
		savedCamera = savedCamera,
		overlayGui = overlayGui,
		overlayFrame = overlayFrame,
		fadeTween = nil,
		connections = {},
		tracks = tracks,
		activeSounds = {},
		heldTracks = heldTracks,
		cameraTrackHold = cameraTrackHold,
		cameraHoldCFrame = nil,
		endAt = math.huge,
		durationSeconds = durationSeconds,
		playbackStartedAt = 0,
		playbackStarted = false,
		finishing = false,
		completed = false,
		holdBlackOnFinish = isRoundIntro,
		completionReported = false,
		roundId = if isRoundIntro and typeof(payload.roundId) == "number" then payload.roundId else nil,
		completionRemote = completionRemote,
		isRoundIntro = isRoundIntro,
		isPreview = isPreview,
		revealAfterPreviewCallback = typeof(payload) == "table" and payload.revealAfterPreviewCallback == true,
		previewOnComplete = previewOnComplete,
	}
	previewOnComplete = nil
	initializeMotionRecordWorldPivots(active)
	initializeFinalMotionHolds(active)
	local preparedCamera = workspace.CurrentCamera
	if preparedCamera and active.cameraBone.Parent then
		applyCutsceneMotion(active, 0)
		attachCameraToCameraBone(active, preparedCamera, 0)
	end
	self._active = active
	if isRoundIntro then
		self._roundIntroActive = true
		self._afterRoundIntroCallbacks = {}
		self.RoundIntroStarted:Fire({
			roundId = active.roundId,
		})

		local timeoutSeconds = getConfiguredDuration(payload.introTimeoutSeconds, RoundEndFlowConfig.POTGIntroClientTimeoutSeconds or 4)
		if timeoutSeconds > 0 then
			task.delay(timeoutSeconds, function()
				if self._restoreSerial ~= restoreSerial or self._active ~= active or active.completed then
					return
				end

				debugCutscene("TimedOut", "roundId", tostring(active.roundId), "timeout", string.format("%.2f", timeoutSeconds))
				self:_finish(active, false)
			end)
		end
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

function POTGCutsceneController:PlayPreview(
	cutsceneId: any,
	onComplete: ((string) -> ())?,
	options: { [string]: any }?
): boolean
	if self:IsRoundIntroActive() then
		return false
	end

	local payload = {
		cutsceneId = cutsceneId,
		preview = true,
		onComplete = onComplete,
	}
	if typeof(options) == "table" then
		if typeof(options.cameraCFrame) == "CFrame" then
			payload.cameraCFrame = options.cameraCFrame
		end
		if isFiniteNumber(options.potgPlayerUserId) then
			payload.potgPlayerUserId = math.floor(options.potgPlayerUserId)
		elseif isFiniteNumber(options.userId) then
			payload.potgPlayerUserId = math.floor(options.userId)
		end
		if options.revealAfterPreviewCallback == true then
			payload.revealAfterPreviewCallback = true
		end
	end

	self:_play(payload)

	return self._active ~= nil and self._active.isPreview == true
end

function POTGCutsceneController:CancelPreview()
	local active = self._active
	if active and active.isPreview == true then
		self:_finish(active, false)
	end
end

function POTGCutsceneController:IsRoundIntroActive(): boolean
	return self._roundIntroActive == true
end

function POTGCutsceneController:QueueAfterRoundIntro(callback)
	if type(callback) ~= "function" then
		return false
	end
	if not self:IsRoundIntroActive() then
		return false
	end

	table.insert(self._afterRoundIntroCallbacks, callback)
	return true
end

function POTGCutsceneController:OnStart()
	if self._remoteConnection then
		self._remoteConnection:Disconnect()
		self._remoteConnection = nil
	end
	if self._roundIntroConnection then
		self._roundIntroConnection:Disconnect()
		self._roundIntroConnection = nil
	end
	if self._characterRemovingConnection then
		self._characterRemovingConnection:Disconnect()
		self._characterRemovingConnection = nil
	end

	prewarmConfiguredAnimations()

	self._remote = getRemote()
	if self._remote then
		self._remoteConnection = self._remote.OnClientEvent:Connect(function()
			self:_play(nil)
		end)
	end

	self._roundIntroCompleteRemote = getRoundIntroCompleteRemote()
	self._roundIntroRemote = getRoundIntroRemote()
	if self._roundIntroRemote then
		self._roundIntroConnection = self._roundIntroRemote.OnClientEvent:Connect(function(payload)
			self:_play(payload)
		end)
	end

	self._characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(function()
		self:_cancelActive()
	end)
end

return POTGCutsceneController
