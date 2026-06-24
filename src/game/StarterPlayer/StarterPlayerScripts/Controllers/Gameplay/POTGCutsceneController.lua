local Lighting = game:GetService("Lighting")
local ContentProvider = game:GetService("ContentProvider")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local BombThrowOrigin = require(ReplicatedStorage.Shared.Common.BombThrowOrigin)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local POTGCutsceneConfig = require(ReplicatedStorage.Shared.Config.POTGCutsceneConfig)
local RoundEndFlowConfig = require(ReplicatedStorage.Shared.Config.RoundEndFlowConfig)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local ScreenEffects = require(ReplicatedStorage.Shared.UI.ScreenEffects)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)

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
local TEMPLATE_WAIT_SECONDS = 10
local REQUIRED_DESCENDANT_WAIT_SECONDS = 8
local ANIMATION_LOAD_TIMEOUT_SECONDS = 3
local CUTSCENE_BOMB_VISUAL_NAME = "POTGEquippedBombVisual"
local PLACEHOLDER_BOMB_NAMES = table.freeze({
	Bomb = true,
	RightHandle = true,
	RIghtHandle = true,
	LeftHandle = true,
	Handle = true,
})
local DEFAULT_BOMB_ATTACHMENT_NAMES = table.freeze({
	"BombGripAttachment",
	"RightGripAttachment",
	"LeftGripAttachment",
})
local DEFAULT_BOMB_HANDLE_NAMES = table.freeze({
	"RightHandle",
	"RIghtHandle",
	"LeftHandle",
	"Handle",
	"Bomb",
})

local moonVFXModule: any? = nil
local moonVFXModuleInitialized = false
local checkedForMoonVFXModule = false

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
	cutsceneSpec: any,
	cameraBone: BasePart,
	bombVisual: Instance?,
	bombVisualRoot: BasePart?,
	bombAttachment: Attachment?,
	bombHandle: BasePart?,
	bombGripOffset: CFrame,
	authoredBombPlaceholders: { Instance },
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

local function getRoundIntroRemote(): RemoteEvent?
	local folder = getRemotesFolder()
	if not folder then
		return nil
	end

	local remote = folder:WaitForChild(RoundEndFlowConfig.Remotes.POTGIntro, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getRoundIntroCompleteRemote(): RemoteEvent?
	local folder = getRemotesFolder()
	if not folder then
		return nil
	end

	local remote = folder:WaitForChild(RoundEndFlowConfig.Remotes.POTGIntroComplete, 10)
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

local function getCutsceneTemplate(cutsceneSpec): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local cutscenes = assets and assets:FindFirstChild("Cutscenes")
	local replicatedTemplate = cutscenes and cutscenes:FindFirstChild(cutsceneSpec.replicatedAssetName)
	if not replicatedTemplate and cutscenes then
		replicatedTemplate = cutscenes:WaitForChild(cutsceneSpec.replicatedAssetName, TEMPLATE_WAIT_SECONDS)
	end
	if replicatedTemplate and (replicatedTemplate:IsA("Folder") or replicatedTemplate:IsA("Model")) then
		return replicatedTemplate
	end

	local highlightIntros = workspace:FindFirstChild("HighlightIntros")
	if not highlightIntros then
		highlightIntros = workspace:WaitForChild("HighlightIntros", TEMPLATE_WAIT_SECONDS)
	end
	local template = highlightIntros and highlightIntros:FindFirstChild(cutsceneSpec.assetFolderName)
	if not template and highlightIntros then
		template = highlightIntros:WaitForChild(cutsceneSpec.assetFolderName, TEMPLATE_WAIT_SECONDS)
	end
	return if template and (template:IsA("Folder") or template:IsA("Model")) then template else nil
end

local function waitForDescendant(root: Instance, name: string, className: string, timeoutSeconds: number): Instance?
	local existing = root:FindFirstChild(name, true)
	if existing and existing:IsA(className) then
		return existing
	end

	local deadline = os.clock() + math.max(timeoutSeconds, 0)
	while os.clock() < deadline do
		local remaining = deadline - os.clock()
		local found: Instance? = nil
		local connection = root.DescendantAdded:Connect(function(descendant)
			if not found and descendant.Name == name and descendant:IsA(className) then
				found = descendant
			end
		end)
		while not found and os.clock() < deadline do
			task.wait(math.min(0.1, math.max(deadline - os.clock(), 0)))
		end
		connection:Disconnect()
		if found then
			return found
		end

		existing = root:FindFirstChild(name, true)
		if existing and existing:IsA(className) then
			return existing
		end
		if remaining <= 0 then
			break
		end
	end
	return nil
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

local function waitForCameraPart(cameraRig: Instance, cutsceneSpec, timeoutSeconds: number): BasePart?
	local existing = findCameraPartInRig(cameraRig, cutsceneSpec)
	if existing then
		return existing
	end

	local found: BasePart? = nil
	local connection = cameraRig.DescendantAdded:Connect(function(descendant)
		if not found and descendant:IsA("BasePart") then
			found = findCameraPartInRig(cameraRig, cutsceneSpec) or descendant
		end
	end)
	local deadline = os.clock() + math.max(timeoutSeconds, 0)
	while not found and os.clock() < deadline do
		task.wait(math.min(0.1, math.max(deadline - os.clock(), 0)))
	end
	connection:Disconnect()
	return found or findCameraPartInRig(cameraRig, cutsceneSpec)
end

local function waitForHighlightIntroReady(template: Instance, cutsceneSpec)
	local characterRig = template:FindFirstChild(cutsceneSpec.characterRigName)
	if not characterRig then
		characterRig = template:WaitForChild(cutsceneSpec.characterRigName, TEMPLATE_WAIT_SECONDS)
	end

	local cameraRig = template:FindFirstChild(cutsceneSpec.cameraRigName)
	if not cameraRig then
		cameraRig = template:WaitForChild(cutsceneSpec.cameraRigName, TEMPLATE_WAIT_SECONDS)
	end

	if cameraRig then
		waitForCameraPart(cameraRig, cutsceneSpec, REQUIRED_DESCENDANT_WAIT_SECONDS)
		waitForDescendant(cameraRig, "Animator", "Animator", REQUIRED_DESCENDANT_WAIT_SECONDS)
	end
	if characterRig then
		waitForDescendant(characterRig, "Humanoid", "Humanoid", REQUIRED_DESCENDANT_WAIT_SECONDS)
	end

	for _, event in ipairs(cutsceneSpec.events or {}) do
		if typeof(event.effectName) == "string" and not template:FindFirstChild(event.effectName, true) then
			if event.type == "Emit" or event.type == "Code" then
				local deadline = os.clock() + 2
				while os.clock() < deadline and not template:FindFirstChild(event.effectName, true) do
					task.wait(0.1)
				end
			end
		end
	end
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

local function getConfiguredNameList(value: any, fallback: { string }): { string }
	if typeof(value) ~= "table" then
		return fallback
	end

	local names = {}
	for _, name in ipairs(value) do
		if typeof(name) == "string" and name ~= "" then
			table.insert(names, name)
		end
	end
	return if #names > 0 then names else fallback
end

local function findDescendantByName(root: Instance?, names: { string }, className: string): Instance?
	if not root then
		return nil
	end

	for _, name in ipairs(names) do
		local direct = root:FindFirstChild(name, true)
		if direct and direct:IsA(className) then
			return direct
		end
	end

	return nil
end

local function getBombAttachmentNames(cutsceneSpec): { string }
	return getConfiguredNameList(cutsceneSpec.bombAttachmentNames, DEFAULT_BOMB_ATTACHMENT_NAMES)
end

local function getBombHandleNames(cutsceneSpec): { string }
	return getConfiguredNameList(cutsceneSpec.bombHandleNames, DEFAULT_BOMB_HANDLE_NAMES)
end

local function getPayloadBombSkinId(payload): string
	if typeof(payload) == "table" then
		local payloadSkinId = BombSkinConfig.NormalizeSkinId(payload.bombSkinId)
		if payloadSkinId ~= "" then
			return payloadSkinId
		end
	end

	local userId = getCandidateUserId(payload)
	local player: Player? = nil
	if userId then
		local ok, result = pcall(function()
			return Players:GetPlayerByUserId(userId)
		end)
		if ok and result then
			player = result
		end
	end

	local skinId = BombSkinConfig.NormalizeSkinId(player and player:GetAttribute(BombSkinConfig.AttributeName))
	return if skinId ~= "" then skinId else BombSkinConfig.DefaultSkinId
end

local function resolveBombAttachment(root: Model, cutsceneSpec, characterRig: Model?): Attachment?
	local attachmentNames = getBombAttachmentNames(cutsceneSpec)
	local configured = findDescendantByName(characterRig, attachmentNames, "Attachment")
	if configured and configured:IsA("Attachment") then
		return configured
	end

	configured = findDescendantByName(root, attachmentNames, "Attachment")
	if configured and configured:IsA("Attachment") then
		return configured
	end

	return BombThrowOrigin.GetRightGripAttachment(characterRig)
end

local function resolveBombHandle(root: Model, cutsceneSpec, characterRig: Model?): BasePart?
	local handleNames = getBombHandleNames(cutsceneSpec)
	local configured = findDescendantByName(characterRig, handleNames, "BasePart")
	if configured and configured:IsA("BasePart") then
		return configured
	end

	configured = findDescendantByName(root, handleNames, "BasePart")
	return if configured and configured:IsA("BasePart") then configured else nil
end

local function collectAuthoredBombPlaceholders(root: Model, cutsceneSpec): { Instance }
	local placeholders = {}
	local characterRig = getCharacterRig(root, cutsceneSpec)
	local handleNames = {}
	for _, name in ipairs(getBombHandleNames(cutsceneSpec)) do
		handleNames[name] = true
	end

	local function addPlaceholder(instance: Instance?)
		if instance and not table.find(placeholders, instance) then
			table.insert(placeholders, instance)
		end
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant == characterRig or descendant:IsDescendantOf(characterRig) then
			if descendant:IsA("BasePart") and (handleNames[descendant.Name] or PLACEHOLDER_BOMB_NAMES[descendant.Name]) then
				addPlaceholder(descendant)
			end
		elseif descendant:IsA("BasePart") and PLACEHOLDER_BOMB_NAMES[descendant.Name] then
			addPlaceholder(descendant)
		end
	end

	local topBomb = root:FindFirstChild("Bomb")
	if topBomb and topBomb:IsA("BasePart") then
		addPlaceholder(topBomb)
	end

	return placeholders
end

local function hideAuthoredBombPlaceholders(placeholders: { Instance })
	for _, placeholder in ipairs(placeholders) do
		if placeholder:IsA("BasePart") then
			hideRuntimeHelperPart(placeholder)
		elseif placeholder:IsA("Decal") or placeholder:IsA("Texture") then
			placeholder.Transparency = 1
		end
	end
end

local function createCutsceneBombVisual(root: Model, cutsceneSpec, payload)
	if cutsceneSpec.useRuntimeBombVisual == false then
		return nil, nil, nil, nil, CFrame.new(), {}
	end

	local characterRig = getCharacterRig(root, cutsceneSpec)
	local attachment = resolveBombAttachment(root, cutsceneSpec, characterRig)
	local handle = if attachment then nil else resolveBombHandle(root, cutsceneSpec, characterRig)
	if not (attachment or handle) then
		return nil, nil, nil, nil, CFrame.new(), {}
	end

	local placeholders = collectAuthoredBombPlaceholders(root, cutsceneSpec)
	hideAuthoredBombPlaceholders(placeholders)

	local skinId = getPayloadBombSkinId(payload)
	local visual, rootPart = BombVisualUtil.CreateBombVisual(skinId, CUTSCENE_BOMB_VISUAL_NAME, {
		anchored = true,
		canCollide = false,
		canQuery = false,
		massless = true,
		effectState = {
			vfx = true,
			fuseSpark = false,
			trail = false,
		},
		visualScale = BombConfig.HeldVisualScale,
	})
	visual.Name = CUTSCENE_BOMB_VISUAL_NAME
	visual.Parent = root

	return visual, rootPart, attachment, handle, if typeof(BombConfig.HeldGripOffset) == "CFrame" then BombConfig.HeldGripOffset else CFrame.new(), placeholders
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

	local ok, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
	if ok and description then
		return description
	end

	warn(("[POTGCutsceneController] Failed to get HumanoidDescription for userId %s: %s"):format(
		tostring(userId),
		tostring(description)
	))
	return nil
end

local function applyCandidateAppearanceToAuthoredRig(root: Model, cutsceneSpec, payload): Animator?
	local userId = getCandidateUserId(payload)
	local rig = getCharacterRig(root, cutsceneSpec)
	if not rig then
		return nil
	end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	if userId then
		local description = getHumanoidDescriptionForUserId(userId)
		if description then
			local bombMotorSnapshot = captureAuthoredBombMotor(root, cutsceneSpec)
			local externalJointSnapshots = captureAuthoredExternalRigJoints(root, cutsceneSpec)
			local ok, err = pcall(function()
				humanoid:ApplyDescriptionResetAsync(description)
			end)
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

	if animationSource.type == POTGCutsceneConfig.AnimationSourceTypes.AnimationId then
		local preloadOk, preloadErr = pcall(function()
			ContentProvider:PreloadAsync({ animation })
		end)
		if not preloadOk then
			warn(("[POTGCutsceneController] Failed to preload %s animation %s: %s"):format(
				name,
				tostring(sourceId),
				tostring(preloadErr)
			))
		end
	end

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if ok and track then
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = false
		local deadline = os.clock() + ANIMATION_LOAD_TIMEOUT_SECONDS
		while track.Length <= 0 and os.clock() < deadline do
			RunService.Heartbeat:Wait()
		end
		if track.Length > 0 then
			animation:Destroy()
			return track
		end

		warn(("[POTGCutsceneController] Loaded %s animation with zero length id=%s animator=%s timeout=%.1fs"):format(
			name,
			tostring(sourceId),
			animator:GetFullName(),
			ANIMATION_LOAD_TIMEOUT_SECONDS
		))
		pcall(function()
			track:Destroy()
		end)
		animation:Destroy()
		return nil
	end

	animation:Destroy()
	warn(("[POTGCutsceneController] Failed to load %s animation: %s"):format(name, tostring(track)))
	return nil
end

local function getCFrameValue(value: any): CFrame?
	return if typeof(value) == "CFrame" then value else nil
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
			if not previousKey.easingStyle or previousKey.easingStyle == "Constant" then
				return previousKey.value
			end

			local duration = math.max(nextKey.time - previousKey.time, 0.001)
			local alpha = math.clamp((elapsed - previousKey.time) / duration, 0, 1)
			alpha =
				TweenService:GetValue(alpha, previousKey.easingStyle, previousKey.easingDirection or Enum.EasingDirection.Out)
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
	if not previousKey.easingStyle or previousKey.easingStyle == "Constant" then
		return 0
	end

	local duration = math.max(nextKey.time - previousKey.time, 0.001)
	local alpha = math.clamp((elapsed - previousKey.time) / duration, 0, 1)
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
			holdFinalWorldCFrame = track.holdFinalWorldCFrame ~= false,
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

local function updateCutsceneBombVisual(active: ActiveCutscene)
	local visual = active.bombVisual
	local rootPart = active.bombVisualRoot
	if not (visual and visual.Parent and rootPart and rootPart.Parent) then
		return
	end

	local sourceCFrame: CFrame? = nil
	local attachment = active.bombAttachment
	if attachment and attachment.Parent then
		sourceCFrame = attachment.WorldCFrame
	end

	if not sourceCFrame then
		local handle = active.bombHandle
		if handle and handle.Parent then
			sourceCFrame = handle.CFrame
		end
	end

	if not sourceCFrame then
		return
	end

	local rootCFrame = sourceCFrame * active.bombGripOffset:Inverse()
	if visual:IsA("Model") then
		visual:PivotTo(rootCFrame)
	elseif visual:IsA("BasePart") then
		visual.CFrame = rootCFrame
	else
		rootPart.CFrame = rootCFrame
	end
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
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

local function attachCameraToCameraBone(active: ActiveCutscene, camera: Camera, elapsed: number)
	local cameraCFrame = getAnimatedCameraBoneCFrame(active.cameraBone)
	LocalPlayer:SetAttribute(CAMERA_SPECTATING_ATTR, true)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = cameraCFrame
	camera.Focus = cameraCFrame
	updateCutsceneProperties(active, camera, elapsed)
end

local function emitCutsceneEffect(active: ActiveCutscene, effectName: string): boolean
	local effect = active.clone:FindFirstChild(effectName) or active.clone:FindFirstChild(effectName, true)
	if not effect then
		warn(("[POTGCutsceneController] Missing highlight intro effect %s"):format(effectName))
		return false
	end

	local handler = getMoonVFXModule()
	if invokeVFXMethod(handler, "Emit", effect) then
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

local function getMoonVFXModule(): any?
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

local function invokeVFXMethod(module: any, methodName: string, ...): boolean
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
			return
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
	updateCutsceneBombVisual(active)
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
			applyCutsceneMotion(active, elapsed)
			updateCutsceneBombVisual(active)
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

	local isRoundIntro = typeof(payload) == "table" and payload.type == "POTGIntro"
	local cutsceneSpec = POTGCutsceneConfig.GetCutscene(
		if typeof(payload) == "table" then payload.cutsceneId else POTGCutsceneConfig.DefaultCutsceneId
	)
	local template = getCutsceneTemplate(cutsceneSpec)
	local camera = workspace.CurrentCamera
	if not template or not camera then
		warn(("[POTGCutsceneController] Missing cutscene template %s or CurrentCamera"):format(
			tostring(cutsceneSpec and cutsceneSpec.id)
		))
		if isRoundIntro then
			self:_reportPayloadCompletion(payload, "Unavailable")
		end
		return
	end

	waitForHighlightIntroReady(template, cutsceneSpec)
	local clone = cloneCutsceneTemplate(template)
	forceNonLoopingCutsceneAnimations(clone)
	prepCutsceneClone(clone)
	hideCameraRigVisuals(clone, cutsceneSpec)
	clone.Parent = getCutsceneFolder()

	local cameraBone = getCameraPart(clone, cutsceneSpec)
	local camRigAnimator = getAnimationControllerAnimatorFromRig(clone, cutsceneSpec.cameraRigName)
	local characterAnimator = if isRoundIntro then applyCandidateAppearanceToAuthoredRig(clone, cutsceneSpec, payload) else nil
	characterAnimator = characterAnimator or getHumanoidAnimatorFromRig(clone, cutsceneSpec.characterRigName)
	if not (cameraBone and camRigAnimator and characterAnimator) then
		warnMissingCutsceneRequirements(cutsceneSpec, clone, cameraBone, camRigAnimator, characterAnimator)
		clone:Destroy()
		if isRoundIntro then
			self:_reportPayloadCompletion(payload, "InvalidTemplate")
		end
		return
	end
	prepCutsceneClone(clone)
	hideCameraRigVisuals(clone, cutsceneSpec)
	local targetCameraCFrame = if isRoundIntro then getCFrameValue(payload.cameraCFrame) else nil

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
		return
	end

	local tracks = {}
	table.insert(tracks, camTrack)
	table.insert(tracks, characterTrack)
	primeCutsceneTracks(tracks)

	local motionSourcePivot = getMotionSourcePivot(clone, cutsceneSpec)
	local placementAnchor: BasePart? = nil
	if targetCameraCFrame then
		placementAnchor = pivotCutsceneToTarget(clone, cutsceneSpec, targetCameraCFrame, cameraBone)
	end
	local motionTargetPivotPart = getCutscenePivotPart(clone, cutsceneSpec)
	local motionTargetPivot = getMotionTargetPivot(clone, cutsceneSpec, placementAnchor)
	local motionRecords = buildMotionRecords(clone, cutsceneSpec)
	local bombVisual, bombVisualRoot, bombAttachment, bombHandle, bombGripOffset, authoredBombPlaceholders =
		createCutsceneBombVisual(clone, cutsceneSpec, payload)
	debugCutscenePlacement(clone, cutsceneSpec, cameraBone, placementAnchor, tracks, "Frame-0 placement")

	local overlayGui, overlayFrame = createOverlay()
	local savedCamera = saveCameraState(camera)
	local dofEffect = createCutsceneDOF(cutsceneSpec)
	local completionRemote = if isRoundIntro then self._roundIntroCompleteRemote or getRoundIntroCompleteRemote() else nil
	self._roundIntroCompleteRemote = completionRemote or self._roundIntroCompleteRemote

	local cameraTrackLength = camTrack.Length
	local durationSeconds = if cutsceneSpec.durationSeconds > 0
		then cutsceneSpec.durationSeconds
		elseif cameraTrackLength > 0
		then cameraTrackLength + 0.5
		else FALLBACK_DURATION_SECONDS
	debugCutscene(
		"Prepared",
		"roundId",
		tostring(if isRoundIntro and typeof(payload.roundId) == "number" then payload.roundId else nil),
		"duration",
		string.format("%.2f", durationSeconds),
		"cameraTrackLength",
		string.format("%.2f", cameraTrackLength),
		"cutsceneId",
		tostring(cutsceneSpec.id)
	)

	local active: ActiveCutscene = {
		clone = clone,
		cutsceneSpec = cutsceneSpec,
		cameraBone = cameraBone :: BasePart,
		bombVisual = bombVisual,
		bombVisualRoot = bombVisualRoot,
		bombAttachment = bombAttachment,
		bombHandle = bombHandle,
		bombGripOffset = bombGripOffset,
		authoredBombPlaceholders = authoredBombPlaceholders,
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
	}
	initializeMotionRecordWorldPivots(active)
	initializeFinalMotionHolds(active)
	local preparedCamera = workspace.CurrentCamera
	if preparedCamera and active.cameraBone.Parent then
		applyCutsceneMotion(active, 0)
		updateCutsceneBombVisual(active)
		attachCameraToCameraBone(active, preparedCamera, 0)
	end
	self._active = active
	if isRoundIntro then
		self._roundIntroActive = true
		self._afterRoundIntroCallbacks = {}
		self.RoundIntroStarted:Fire({
			roundId = active.roundId,
		})
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
