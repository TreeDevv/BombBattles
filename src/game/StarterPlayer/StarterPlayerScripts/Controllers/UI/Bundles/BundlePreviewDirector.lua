local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)
local BundleCatalog = require(ReplicatedStorage.Shared.Config.BundleCatalog)
local EmoteConfig = require(ReplicatedStorage.Shared.Emotes.EmoteConfig)
local EmoteEffect = require(ReplicatedStorage.Shared.Emotes.EmoteEffect)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundEndFlowConfig = require(ReplicatedStorage.Shared.Config.RoundEndFlowConfig)
local POTGCutsceneController = require(script.Parent.Parent:WaitForChild("POTGCutsceneController"))

local LocalPlayer = Players.LocalPlayer

local STAGE_SOURCE_PATH = { "Assets", "Staging" }
local STAGE_CLONE_NAME = "BundlePreviewStage"
local ACTIVE_SCENE_NAME = "ActiveScene"
local SOCKETS_NAME = "Sockets"
local CAMERA_MARKERS_NAME = "CameraMarkers"
local TEXT_GRADIENT_TEMPLATES_NAME = "TextGradientTemplates"
local RUNTIME_HEADER_GRADIENT_ATTRIBUTE = "BundlePreviewRuntimeHeaderGradient"
local CAMERA_BIND_NAME = "BundlePreviewCamera"
local HIDDEN_TRANSPARENCY = 1
local PREVIEW_FIELD_OF_VIEW = 58
local CAMERA_ENTER_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local CAMERA_EXIT_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local CAMERA_PREVIEW_TWEEN = TweenInfo.new(0.62, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)
local DEFAULT_LOOP_DELAY = 4
local DEBUG_CAMERA_TARGET = false
local CAMERA_TARGET_EPSILON = 2
local CAMERA_SNAP_FALLBACK_DELAY = 0.08
local FAT_GUY_ROTATION = CFrame.Angles(0, 0, math.rad(90))
local FAT_GUY_CENTER_ATTACHMENT_NAME = "Center"
local DEFAULT_FALLING_CHARACTER_SCALE = 0.82
local DEFAULT_FALLING_PREVIEW_SCALE_MULTIPLIER = 0.1
local DEFAULT_INFINITY_PREVIEW_BUBBLE_SCALE_MULTIPLIER = 0.18
local WIDE_CAMERA_PRESET = "Wide"
local SINGLE_PEDESTAL_SOCKET = "SinglePedastal"
local SINGLE_PEDESTAL_CAMERA_PRESET = "SinglePedastal"
local NORMAL_DISPLAY_SOCKET_NAMES = table.freeze({ "LeftDisplay", "CenterActor", "RightDisplay" })
local DISPLAY_SOCKET_NAMES = table.freeze({ "LeftDisplay", "CenterActor", "RightDisplay", SINGLE_PEDESTAL_SOCKET })
local SINGLE_PEDESTAL_NAMES = table.freeze({ "Single", "SinglePedastal", "SinglePedestal" })
local SINGLE_PEDESTAL_CAMERA_NAMES = table.freeze({
	"SinglePedastal",
	"SinglePedestal",
	"SinglePedastalCamera",
	"SinglePedestalCamera",
})
local SINGLE_PEDESTAL_CAMERA_ATTACHMENT_NAMES = table.freeze({
	"Camera",
	"CameraAttachment",
	"CameraMarker",
	"SinglePedastalCamera",
	"SinglePedestalCamera",
})
local PREVIEW_FLASH_NAME_PATTERNS = table.freeze({
	"flash",
	"flashed",
})
local PREVIEW_RANDOM = Random.new()
local warnedMissingHighlightIntroAttachment = false

local REAL_PRESENTERS = table.freeze({
	StaticModelPresenter = true,
	AbilityCastPresenter = true,
	BundleOverviewPresenter = true,
	AbilityAuraPresenter = true,
	EmotePresenter = true,
	HighlightIntroPresenter = true,
})

local REAL_PRESETS = table.freeze({
	PackOverview = true,
	SingleDisplay = true,
	EffectArena = true,
	FullScreen = true,
})

local INFINITY_BODY_PART_TARGETS = table.freeze({
	Head = { "Head" },
	Torso = { "Torso", "UpperTorso", "LowerTorso" },
	["Left Arm"] = { "Left Arm", "LeftUpperArm", "LeftLowerArm", "LeftHand" },
	["Right Arm"] = { "Right Arm", "RightUpperArm", "RightLowerArm", "RightHand" },
	["Left Leg"] = { "Left Leg", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" },
	["Right Leg"] = { "Right Leg", "RightUpperLeg", "RightLowerLeg", "RightFoot" },
	HumanoidRootPart = { "HumanoidRootPart" },
})

local function normalizeSocketName(socketName: any): any
	if socketName == "SinglePedestal" then
		return SINGLE_PEDESTAL_SOCKET
	end
	return socketName
end

local function getByPath(root: Instance, path: { string }): Instance?
	local current: Instance? = root
	for _, name in ipairs(path) do
		current = current and current:FindFirstChild(name) or nil
		if not current then
			return nil
		end
	end
	return current
end

local function getReplicatedAsset(path: { string }?): Instance?
	if typeof(path) ~= "table" then
		return nil
	end
	return getByPath(ReplicatedStorage, path)
end

local function findNamedAttachment(root: Instance?, attachmentName: string): Attachment?
	if not root then
		return nil
	end

	local attachment = root:FindFirstChild(attachmentName, true)
	return if attachment and attachment:IsA("Attachment") then attachment else nil
end

local function getMapTemplateFolder(): Instance?
	if typeof(RoundConfig.MapsFolderPath) ~= "table" then
		return nil
	end
	return getByPath(ReplicatedStorage, RoundConfig.MapsFolderPath)
end

local function getPivot(instance: Instance): CFrame
	if instance:IsA("Model") then
		return instance:GetPivot()
	elseif instance:IsA("BasePart") then
		return instance.CFrame
	elseif instance:IsA("Attachment") then
		return instance.WorldCFrame
	end
	return CFrame.new()
end

local function pivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	elseif instance:IsA("Attachment") then
		instance.WorldCFrame = cframe
	end
end

local function prepareLocalVisual(instance: Instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant.Disabled = true
		end
	end

	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = false
	end
end

local function setModelVisible(instance: Instance?, visible: boolean)
	if not instance then
		return
	end
	local transparency = if visible then 0 else HIDDEN_TRANSPARENCY
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Transparency = transparency
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = transparency
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = visible
		end
	end
	if instance:IsA("BasePart") then
		instance.Transparency = transparency
	elseif instance:IsA("Decal") or instance:IsA("Texture") then
		instance.Transparency = transparency
	end
end

local function scaleVisual(instance: Instance, scale: number?)
	local resolvedScale = tonumber(scale) or 1
	if resolvedScale == 1 then
		return
	end

	if instance:IsA("Model") then
		instance:ScaleTo(resolvedScale)
	elseif instance:IsA("BasePart") then
		instance.Size *= resolvedScale
		for _, descendant in ipairs(instance:GetDescendants()) do
			if descendant:IsA("Attachment") then
				descendant.Position *= resolvedScale
			end
		end
	end
end

local function scaledVector(vector: Vector3, scale: number): Vector3
	return Vector3.new(
		math.max(vector.X * scale, 0.01),
		math.max(vector.Y * scale, 0.01),
		math.max(vector.Z * scale, 0.01)
	)
end

local function getBoundingBox(instance: Instance): (CFrame, Vector3)
	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	elseif instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	end
	return getPivot(instance), Vector3.zero
end

local function getDefinitionNumber(definition: { [string]: any }?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
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

local function getPrimaryPart(root: Instance): BasePart?
	if root:IsA("BasePart") then
		return root
	end
	if root:IsA("Model") and root.PrimaryPart then
		return root.PrimaryPart
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

local function getInfinityTargetParts(character: Model, sourcePartName: string): { BasePart }
	local targets = {}
	local targetNames = INFINITY_BODY_PART_TARGETS[sourcePartName]
	if not targetNames then
		return targets
	end

	for _, targetName in ipairs(targetNames) do
		local target = character:FindFirstChild(targetName)
		if target and target:IsA("BasePart") then
			table.insert(targets, target)
		end
	end

	return targets
end

local function shouldCloneInfinityRigChild(child: Instance): boolean
	return child:IsA("ParticleEmitter")
		or child:IsA("Attachment")
		or child:IsA("Beam")
		or child:IsA("Trail")
		or child:IsA("PointLight")
		or child:IsA("SpotLight")
		or child:IsA("SurfaceLight")
end

local function enableEffectDescendants(root: Instance)
	if root:IsA("ParticleEmitter") or root:IsA("Beam") or root:IsA("Trail") then
		root.Enabled = true
	elseif root:IsA("PointLight") or root:IsA("SpotLight") or root:IsA("SurfaceLight") then
		(root :: any).Enabled = true
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = true
		elseif descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
			(descendant :: any).Enabled = true
		end
	end
end

local function cloneInfinityRigEffects(sourceRig: Model, character: Model, cleanup)
	for sourcePartName in pairs(INFINITY_BODY_PART_TARGETS) do
		local sourcePart = sourceRig:FindFirstChild(sourcePartName)
		if not (sourcePart and sourcePart:IsA("BasePart")) then
			continue
		end

		for _, child in ipairs(sourcePart:GetChildren()) do
			if not shouldCloneInfinityRigChild(child) then
				continue
			end

			for _, target in ipairs(getInfinityTargetParts(character, sourcePartName)) do
				local clone = child:Clone()
				clone.Name = "InfinityPreview_" .. child.Name
				clone.Parent = target
				enableEffectDescendants(clone)
				cleanup:AddInstance(clone)
			end
		end
	end
end

local function getInfinityBubbleScaleFactor(clone: Instance, definition: { [string]: any }?, multiplier: number): number
	local radius = math.max(getDefinitionNumber(definition, "radius", 20), 0.1)
	local maxDimension = 0
	for _, part in ipairs(getBaseParts(clone)) do
		maxDimension = math.max(maxDimension, part.Size.X, part.Size.Y, part.Size.Z)
	end
	if maxDimension <= 0 then
		return 1
	end
	return ((radius * 2) / maxDimension) * multiplier
end

local function attachInfinityBubbleToActor(
	bubble: Instance,
	actor: Model,
	definition: { [string]: any }?,
	scaleMultiplier: number
): boolean
	local rootPart = actor:FindFirstChild("HumanoidRootPart")
	local primaryPart = getPrimaryPart(bubble)
	if not (rootPart and rootPart:IsA("BasePart") and primaryPart) then
		return false
	end

	pivotTo(bubble, rootPart.CFrame)
	local color = definition and definition.visualColor
	local resolvedColor = if typeof(color) == "Color3" then color else Color3.fromRGB(65, 235, 255)
	local finalTransparency = math.clamp(getDefinitionNumber(definition, "visualTransparency", 0.82), 0, 1)
	local scale = getInfinityBubbleScaleFactor(bubble, definition, scaleMultiplier)
	for _, part in ipairs(getBaseParts(bubble)) do
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.Color = resolvedColor
		part.Transparency = finalTransparency
		part.Size = scaledVector(part.Size, scale)
		for _, child in ipairs(part:GetChildren()) do
			if child:IsA("SpecialMesh") then
				child.Scale = scaledVector(child.Scale, scale)
			end
		end
	end

	local weld = Instance.new("WeldConstraint")
	weld.Name = "InfinityPreviewBubbleRootWeld"
	weld.Part0 = rootPart
	weld.Part1 = primaryPart
	weld.Parent = primaryPart
	return true
end

local function getGiantBottomOffset(giant: Instance): number
	local boundsCFrame, boundsSize = getBoundingBox(giant)
	local pivot = getPivot(giant)
	return math.max(pivot.Position.Y - (boundsCFrame.Position.Y - boundsSize.Y * 0.5), 0)
end

local function getFatGuyCenterLocalOffset(giant: Instance): Vector3?
	local center = giant:FindFirstChild(FAT_GUY_CENTER_ATTACHMENT_NAME, true)
	if center and center:IsA("Attachment") then
		return getPivot(giant):PointToObjectSpace(center.WorldPosition)
	end
	return nil
end

local function setFatGuyPreviewPose(giant: Instance, position: Vector3, height: number)
	local centerLocalOffset = getFatGuyCenterLocalOffset(giant)
	if centerLocalOffset then
		local targetCenter = position + Vector3.yAxis * height
		local pivotPosition = targetCenter - FAT_GUY_ROTATION:VectorToWorldSpace(centerLocalOffset)
		pivotTo(giant, CFrame.new(pivotPosition) * FAT_GUY_ROTATION)
		return
	end

	local bottomOffset = getGiantBottomOffset(giant)
	pivotTo(giant, CFrame.new(position + Vector3.yAxis * (height + bottomOffset)) * FAT_GUY_ROTATION)
end

local function getRigRootPart(rig: Model): BasePart?
	local rootPart = rig:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return rig.PrimaryPart
end

local function pivotRigRootToCFrame(rig: Model, targetRootCFrame: CFrame)
	local rootPart = getRigRootPart(rig)
	if not rootPart then
		rig:PivotTo(targetRootCFrame)
		return
	end

	local pivotToRoot = rig:GetPivot():ToObjectSpace(rootPart.CFrame)
	rig:PivotTo(targetRootCFrame * pivotToRoot:Inverse())
end

local function getGroundedCFrame(instance: Instance, targetCFrame: CFrame, yOffset: number?): CFrame
	pivotTo(instance, targetCFrame)

	local boundsCFrame, boundsSize = getBoundingBox(instance)
	local pivot = getPivot(instance)
	local bottomY = boundsCFrame.Position.Y - (boundsSize.Y * 0.5)
	local groundOffset = math.max(0, pivot.Position.Y - bottomY)

	return targetCFrame * CFrame.new(0, groundOffset + (tonumber(yOffset) or 0), 0)
end

local function scaleNumberSequence(sequence: NumberSequence, scale: number): NumberSequence
	local keypoints = {}
	for _, keypoint in ipairs(sequence.Keypoints) do
		table.insert(
			keypoints,
			NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value * scale, keypoint.Envelope * scale)
		)
	end
	return NumberSequence.new(keypoints)
end

local function scaleEffects(instance: Instance, scale: number?)
	local resolvedScale = tonumber(scale) or 1
	if resolvedScale == 1 then
		return
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Size = scaleNumberSequence(descendant.Size, resolvedScale)
			descendant.Speed =
				NumberRange.new(descendant.Speed.Min * resolvedScale, descendant.Speed.Max * resolvedScale)
		elseif descendant:IsA("Beam") then
			descendant.Width0 *= resolvedScale
			descendant.Width1 *= resolvedScale
		elseif descendant:IsA("Trail") then
			descendant.WidthScale = scaleNumberSequence(descendant.WidthScale, resolvedScale)
		end
	end
end

local function isPreviewFlashVisual(instance: Instance): boolean
	local name = string.lower(instance.Name)
	for _, pattern in ipairs(PREVIEW_FLASH_NAME_PATTERNS) do
		if string.find(name, pattern, 1, true) then
			return true
		end
	end
	return false
end

local function sanitizePreviewVfx(instance: Instance, options: { [string]: any }?)
	local lightBrightnessScale = tonumber(options and options.LightBrightnessScale) or 0.2
	local maxEmitterBrightness = tonumber(options and options.MaxEmitterBrightness) or 0.8
	local maxLightBrightness = tonumber(options and options.MaxLightBrightness) or 0.35
	local maxLightRange = tonumber(options and options.MaxLightRange) or 6

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			if isPreviewFlashVisual(descendant) or isPreviewFlashVisual(descendant.Parent or descendant) then
				descendant.Enabled = false
				descendant.Rate = 0
				descendant:SetAttribute("EmitCount", 0)
			else
				descendant.LightEmission = math.min(descendant.LightEmission, 0.65)
				descendant.Brightness = math.min(descendant.Brightness, maxEmitterBrightness)
			end
		elseif descendant:IsA("Light") then
			descendant.Brightness = math.min(descendant.Brightness * lightBrightnessScale, maxLightBrightness)
			descendant.Range = math.min(descendant.Range, maxLightRange)
		end
	end
end

local function findFirstDescendant(root: Instance?, name: string, className: string?): Instance?
	if not root then
		return nil
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name and (not className or descendant.ClassName == className) then
			return descendant
		end
	end
	return nil
end

local function getSocketCFrameFromPart(part: Instance?, yOffset: number): CFrame?
	if part and part:IsA("BasePart") then
		return part.CFrame * CFrame.new(0, yOffset, 0)
	end
	if part and part:IsA("Model") then
		return part:GetPivot() * CFrame.new(0, yOffset, 0)
	end
	return nil
end

local function findFirstByNames(root: Instance?, names: { string }, recursive: boolean?): Instance?
	if not root then
		return nil
	end

	for _, name in ipairs(names) do
		local child = root:FindFirstChild(name, recursive == true)
		if child then
			return child
		end
	end

	return nil
end

local function getCameraMarkerCFrame(marker: Instance?): CFrame?
	if not marker then
		return nil
	end
	if marker:IsA("Camera") or marker:IsA("BasePart") then
		return marker.CFrame
	elseif marker:IsA("Attachment") then
		return marker.WorldCFrame
	elseif marker:IsA("Model") then
		return marker:GetPivot()
	end
	return nil
end

local function findCameraMarkerIn(root: Instance?): Instance?
	if not root then
		return nil
	end

	local named = findFirstByNames(root, SINGLE_PEDESTAL_CAMERA_ATTACHMENT_NAMES, true)
	if named and (named:IsA("Attachment") or named:IsA("BasePart") or named:IsA("Camera") or named:IsA("Model")) then
		return named
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		local lowerName = string.lower(descendant.Name)
		if
			string.find(lowerName, "camera", 1, true)
			and (
				descendant:IsA("Attachment")
				or descendant:IsA("BasePart")
				or descendant:IsA("Camera")
				or descendant:IsA("Model")
			)
		then
			return descendant
		end
	end

	return nil
end

local function getSlotTitle(slot): string
	if typeof(slot) ~= "table" then
		return ""
	end

	local recipe = BundleCatalog.GetPreviewRecipe(slot.PreviewId)
	if recipe and typeof(recipe.Title) == "string" and recipe.Title ~= "" then
		return recipe.Title
	end

	local item = BundleCatalog.GetItem(slot.ItemId)
	if item and typeof(item.DisplayName) == "string" then
		return string.upper(item.DisplayName)
	end

	return ""
end

local function getRecipeTextGradientTemplateId(recipe): string?
	if typeof(recipe) ~= "table" then
		return nil
	end
	local templateId = recipe.TextGradientTemplateId
	return if typeof(templateId) == "string" and templateId ~= "" then templateId else nil
end

local function getSlotTextGradientTemplateId(slot, fallbackTemplateId: string?): string?
	if typeof(slot) ~= "table" then
		return fallbackTemplateId
	end

	local templateId = slot.TextGradientTemplateId
	if typeof(templateId) == "string" and templateId ~= "" then
		return templateId
	end

	local recipe = BundleCatalog.GetPreviewRecipe(slot.PreviewId)
	return getRecipeTextGradientTemplateId(recipe) or fallbackTemplateId
end

local function makeCleanup()
	local cleanup = {
		_connections = {},
		_instances = {},
		_tasks = {},
		_cancelled = false,
	}

	function cleanup:AddConnection(connection: RBXScriptConnection?)
		if connection then
			table.insert(self._connections, connection)
		end
	end

	function cleanup:AddInstance(instance: Instance?)
		if instance then
			table.insert(self._instances, instance)
		end
	end

	function cleanup:AddTask(callback: (() -> ())?)
		if type(callback) == "function" then
			table.insert(self._tasks, callback)
		end
	end

	function cleanup:IsCancelled(): boolean
		return self._cancelled
	end

	function cleanup:Destroy()
		if self._cancelled then
			return
		end
		self._cancelled = true

		for _, connection in ipairs(self._connections) do
			connection:Disconnect()
		end
		table.clear(self._connections)

		for _, callback in ipairs(self._tasks) do
			pcall(callback)
		end
		table.clear(self._tasks)

		for _, instance in ipairs(self._instances) do
			if instance and instance.Parent then
				instance:Destroy()
			end
		end
		table.clear(self._instances)
	end

	return cleanup
end

local BundlePreviewDirector = {}
BundlePreviewDirector.__index = BundlePreviewDirector

function BundlePreviewDirector.new()
	return setmetatable({
		_stage = nil,
		_activeScene = nil,
		_sockets = {},
		_cameraMarkers = {},
		_laneCleanups = {},
		_sceneCleanup = nil,
		_cameraState = nil,
		_cameraCFrame = nil,
		_cameraFov = PREVIEW_FIELD_OF_VIEW,
		_cameraPreset = WIDE_CAMERA_PRESET,
		_cameraTween = nil,
		_cameraTweenValue = nil,
		_cameraTweenConnection = nil,
		_cameraGuardConnections = {},
		_applyingCameraFrame = false,
		_cameraTransitionSerial = 0,
		_actor = nil,
		_description = nil,
		_running = false,
		_requestSerial = 0,
		_fullscreenPreviewActive = false,
	}, BundlePreviewDirector)
end

function BundlePreviewDirector:_getStageSource(): Instance?
	return getReplicatedAsset(STAGE_SOURCE_PATH)
end

function BundlePreviewDirector:_ensureFolder(parent: Instance, name: string): Folder
	local folder = parent:FindFirstChild(name)
	if folder and folder:IsA("Folder") then
		return folder
	end
	if folder then
		folder:Destroy()
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = parent
	return created
end

function BundlePreviewDirector:_hideAuthoredDisplayObjects()
	local stage = self._stage
	if not stage then
		return
	end

	local pedestals = stage:FindFirstChild("Pedastals")
	local left = pedestals and pedestals:FindFirstChild("Left")
	local center = pedestals and pedestals:FindFirstChild("Center")
	local right = pedestals and pedestals:FindFirstChild("Right")

	for _, pedestal in ipairs({ left, right }) do
		if pedestal then
			local bomb = pedestal:FindFirstChild("Bomb")
			if bomb then
				bomb:Destroy()
			end
		end
	end

	local authoredRig = center and center:FindFirstChild("Rig")
	setModelVisible(authoredRig, false)
end

function BundlePreviewDirector:_hideAuthoredRig()
	local stage = self._stage
	if not stage then
		return
	end

	local pedestals = stage:FindFirstChild("Pedastals")
	local center = pedestals and pedestals:FindFirstChild("Center")
	local authoredRig = center and center:FindFirstChild("Rig")
	setModelVisible(authoredRig, false)
end

function BundlePreviewDirector:_getPedestalBaseCFrame(socketName: string): CFrame?
	local pedestal = self:_getPedestalForSocket(socketName)
	if not pedestal then
		return nil
	end

	local boundsCFrame, boundsSize = getBoundingBox(pedestal)
	return CFrame.new(boundsCFrame.Position + Vector3.new(0, boundsSize.Y * 0.5, 0))
end

function BundlePreviewDirector:_buildSockets()
	local stage = self._stage
	if not stage then
		return
	end

	local authoredSockets = stage:FindFirstChild(SOCKETS_NAME)
	local authoredCameraMarkers = stage:FindFirstChild(CAMERA_MARKERS_NAME)

	local pedestals = stage:FindFirstChild("Pedastals")
	local left = pedestals and pedestals:FindFirstChild("Left")
	local center = pedestals and pedestals:FindFirstChild("Center")
	local right = pedestals and pedestals:FindFirstChild("Right")
	local single = findFirstByNames(pedestals, SINGLE_PEDESTAL_NAMES, false)
		or findFirstByNames(stage, SINGLE_PEDESTAL_NAMES, true)
	local stageCamera = stage:FindFirstChild("StagingCamera")

	local leftOrigin = findFirstDescendant(left, "BombOrigin", "Attachment")
	local rightOrigin = findFirstDescendant(right, "BombOrigin", "Attachment")
	local singleOrigin = findFirstDescendant(single, "BombOrigin", "Attachment")
	local wideCameraMarker = authoredCameraMarkers and authoredCameraMarkers:FindFirstChild(WIDE_CAMERA_PRESET)
	local singleCameraMarker = findFirstByNames(authoredCameraMarkers, SINGLE_PEDESTAL_CAMERA_NAMES, false)
		or findCameraMarkerIn(single)
	local centerRig = center and center:FindFirstChild("Rig")
	local centerRigCFrame = centerRig and getPivot(centerRig)
	local centerRigRoot = centerRig and centerRig:IsA("Model") and getRigRootPart(centerRig) or nil
	local centerRigRootCFrame = centerRigRoot and centerRigRoot.CFrame or nil
	local singleSocketCFrame = (singleOrigin and getPivot(singleOrigin))
		or getSocketCFrameFromPart(single, 4)
		or getSocketCFrameFromPart(right, 4)
		or getPivot(stage)

	self._cameraMarkers = {
		Wide = getCameraMarkerCFrame(wideCameraMarker) or (stageCamera and getPivot(stageCamera)) or nil,
		SinglePedastal = getCameraMarkerCFrame(singleCameraMarker),
	}

	self._sockets = {
		LeftDisplay = getSocketCFrameFromPart(authoredSockets and authoredSockets:FindFirstChild("LeftDisplay"), 0)
			or (leftOrigin and getPivot(leftOrigin))
			or getSocketCFrameFromPart(left, 4)
			or getPivot(stage),
		CenterActor = centerRigCFrame or getSocketCFrameFromPart(
			authoredSockets and authoredSockets:FindFirstChild("CenterActor"),
			0
		) or getSocketCFrameFromPart(center, 4.1) or getPivot(stage),
		RightDisplay = getSocketCFrameFromPart(authoredSockets and authoredSockets:FindFirstChild("RightDisplay"), 0)
			or (rightOrigin and getPivot(rightOrigin))
			or getSocketCFrameFromPart(right, 4)
			or getPivot(stage),
		EffectOrigin = getSocketCFrameFromPart(authoredSockets and authoredSockets:FindFirstChild("EffectOrigin"), 0)
			or (leftOrigin and getPivot(leftOrigin))
			or getSocketCFrameFromPart(left, 4)
			or getPivot(stage),
		ProjectileOrigin = getSocketCFrameFromPart(
			authoredSockets and authoredSockets:FindFirstChild("ProjectileOrigin"),
			0
		) or getSocketCFrameFromPart(center, 5.5) or getPivot(stage),
		ProjectileTarget = getSocketCFrameFromPart(
			authoredSockets and authoredSockets:FindFirstChild("ProjectileTarget"),
			0
		) or (leftOrigin and getPivot(leftOrigin)) or getPivot(stage),
		CameraFocus = (centerRigCFrame and centerRigCFrame * CFrame.new(0, 2.8, 0)) or getSocketCFrameFromPart(
			authoredSockets and authoredSockets:FindFirstChild("CameraFocus"),
			0
		) or getSocketCFrameFromPart(center, 4.5) or getPivot(stage),
		SinglePedastal = singleSocketCFrame,
		AuthoredActorRoot = centerRigRootCFrame,
	}
end

function BundlePreviewDirector:_setPedestalVisible(socketName: string, visible: boolean)
	socketName = normalizeSocketName(socketName)
	local stage = self._stage
	if not stage then
		return
	end
	local pedestals = stage:FindFirstChild("Pedastals")
	if not pedestals then
		return
	end

	local pedestalName = nil
	if socketName == "LeftDisplay" then
		pedestalName = "Left"
	elseif socketName == "CenterActor" then
		pedestalName = "Center"
	elseif socketName == "RightDisplay" then
		pedestalName = "Right"
	elseif socketName == SINGLE_PEDESTAL_SOCKET then
		pedestalName = SINGLE_PEDESTAL_SOCKET
	end

	local pedestal = if socketName == SINGLE_PEDESTAL_SOCKET
		then findFirstByNames(pedestals, SINGLE_PEDESTAL_NAMES, false)
		else pedestalName and pedestals:FindFirstChild(pedestalName) or nil
	setModelVisible(pedestal, visible)
	if socketName == "CenterActor" then
		self:_hideAuthoredRig()
	end
end

function BundlePreviewDirector:_getPedestalForSocket(socketName: string): Instance?
	socketName = normalizeSocketName(socketName)
	local stage = self._stage
	if not stage then
		return nil
	end
	local pedestals = stage:FindFirstChild("Pedastals")
	if not pedestals then
		return nil
	end

	if socketName == "LeftDisplay" then
		return pedestals:FindFirstChild("Left")
	elseif socketName == "CenterActor" then
		return pedestals:FindFirstChild("Center")
	elseif socketName == "RightDisplay" then
		return pedestals:FindFirstChild("Right")
	elseif socketName == SINGLE_PEDESTAL_SOCKET then
		return findFirstByNames(pedestals, SINGLE_PEDESTAL_NAMES, false)
	end
	return nil
end

function BundlePreviewDirector:_getTextGradientTemplate(templateId: string?): UIGradient?
	local stage = self._stage
	if typeof(templateId) ~= "string" or templateId == "" or not stage then
		return nil
	end

	local templates = stage:FindFirstChild(TEXT_GRADIENT_TEMPLATES_NAME)
	local template = templates and templates:FindFirstChild(templateId)
	return if template and template:IsA("UIGradient") then template else nil
end

function BundlePreviewDirector:_applyHeaderTextGradient(header: TextLabel, templateId: string?)
	local template = self:_getTextGradientTemplate(templateId)
	for _, child in ipairs(header:GetChildren()) do
		if
			child:IsA("UIGradient")
			and (template ~= nil or child:GetAttribute(RUNTIME_HEADER_GRADIENT_ATTRIBUTE) == true)
		then
			child:Destroy()
		end
	end

	if not template then
		return
	end

	local gradient = template:Clone()
	gradient.Name = template.Name
	gradient:SetAttribute(RUNTIME_HEADER_GRADIENT_ATTRIBUTE, true)
	gradient.Parent = header
end

function BundlePreviewDirector:_setPedestalHeader(
	socketName: string,
	title: string?,
	visible: boolean,
	textGradientTemplateId: string?
)
	local pedestal = self:_getPedestalForSocket(socketName)
	if not pedestal then
		return
	end

	local headerHolder = pedestal:FindFirstChild("HeaderHolder", true)
	local billboard = headerHolder and headerHolder:FindFirstChildWhichIsA("BillboardGui", true)
	if billboard then
		billboard.Enabled = visible and typeof(title) == "string" and title ~= ""
		local header = billboard:FindFirstChild("Header", true)
		if header and header:IsA("TextLabel") and typeof(title) == "string" and title ~= "" then
			header.Text = title
			self:_applyHeaderTextGradient(header, textGradientTemplateId)
		end
	end
end

function BundlePreviewDirector:_setPedestalsForSlots(
	slots: { any }?,
	preserveOthers: boolean?,
	fallbackTextGradientTemplateId: string?
)
	local visibleBySocket = {}
	local titleBySocket = {}
	local textGradientBySocket = {}
	for _, slot in ipairs(slots or {}) do
		if typeof(slot) == "table" and typeof(slot.Socket) == "string" then
			local socketName = normalizeSocketName(slot.Socket)
			visibleBySocket[socketName] = true
			titleBySocket[socketName] = getSlotTitle(slot)
			textGradientBySocket[socketName] = getSlotTextGradientTemplateId(slot, fallbackTextGradientTemplateId)
		end
	end
	local socketNames = if preserveOthers then NORMAL_DISPLAY_SOCKET_NAMES else DISPLAY_SOCKET_NAMES
	for _, socketName in ipairs(socketNames) do
		self:_setPedestalVisible(socketName, visibleBySocket[socketName] == true)
		self:_setPedestalHeader(
			socketName,
			titleBySocket[socketName],
			visibleBySocket[socketName] == true,
			textGradientBySocket[socketName] or fallbackTextGradientTemplateId
		)
	end
	self:_hideAuthoredDisplayObjects()
end

function BundlePreviewDirector:_setPedestalsForSockets(
	socketNames: { string }?,
	titleBySocket: { [string]: string }?,
	textGradientBySocket: { [string]: string? }?,
	preserveOthers: boolean?
)
	local visibleBySocket = {}
	for _, socketName in ipairs(socketNames or {}) do
		if typeof(socketName) == "string" then
			visibleBySocket[normalizeSocketName(socketName)] = true
		end
	end
	local socketsToUpdate = if preserveOthers then socketNames or {} else DISPLAY_SOCKET_NAMES
	for _, socketName in ipairs(socketsToUpdate) do
		socketName = normalizeSocketName(socketName)
		local title = titleBySocket and (titleBySocket[socketName] or titleBySocket.SinglePedestal) or nil
		local textGradientTemplateId = textGradientBySocket
				and (textGradientBySocket[socketName] or textGradientBySocket.SinglePedestal)
			or nil
		self:_setPedestalVisible(socketName, visibleBySocket[socketName] == true)
		self:_setPedestalHeader(socketName, title, visibleBySocket[socketName] == true, textGradientTemplateId)
	end
	self:_hideAuthoredDisplayObjects()
end

function BundlePreviewDirector:_saveCamera()
	if self._cameraState then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	self._cameraState = {
		CameraType = camera.CameraType,
		CameraSubject = camera.CameraSubject,
		CFrame = camera.CFrame,
		FieldOfView = camera.FieldOfView,
	}
end

function BundlePreviewDirector:_computeCameraCFrame(cameraPreset: string?): CFrame?
	local preset = cameraPreset or self._cameraPreset or WIDE_CAMERA_PRESET
	local cameraCFrame = nil
	local focus = nil

	if preset == SINGLE_PEDESTAL_CAMERA_PRESET then
		cameraCFrame = self._cameraMarkers.SinglePedastal
		focus = self._sockets.SinglePedastal
		if not cameraCFrame and focus then
			warn("[BundlesPreview] Missing CameraMarkers.SinglePedastal; using single pedestal fallback camera")
			cameraCFrame =
				CFrame.lookAt(focus.Position + Vector3.new(0, 5.25, 15), focus.Position + Vector3.new(0, 1.2, 0))
		end
	else
		cameraCFrame = self._cameraMarkers.Wide
		focus = self._sockets.CameraFocus
		if not cameraCFrame and focus then
			warn("[BundlesPreview] Missing CameraMarkers.Wide; using wide fallback camera")
			cameraCFrame = CFrame.lookAt(focus.Position + Vector3.new(0, 8, 32), focus.Position)
		end
	end

	return cameraCFrame
end

function BundlePreviewDirector:_debugCameraTarget(previewId: string?, cameraPreset: string, targetCFrame: CFrame?)
	local stage = self._stage
	if not (DEBUG_CAMERA_TARGET or (stage and stage:GetAttribute("BundlePreviewDebugCamera") == true)) then
		return
	end
	local source = if cameraPreset == SINGLE_PEDESTAL_CAMERA_PRESET
		then "CameraMarkers.SinglePedastal"
		else "CameraMarkers." .. tostring(cameraPreset)
	warn(
		("[BundlesPreview] Camera target preview=%s preset=%s source=%s position=%s"):format(
			tostring(previewId),
			tostring(cameraPreset),
			source,
			targetCFrame and tostring(targetCFrame.Position) or "nil"
		)
	)
end

function BundlePreviewDirector:_applyCameraFrame()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local cameraCFrame = self._cameraCFrame or self:_computeCameraCFrame()
	if not cameraCFrame then
		return
	end

	self._applyingCameraFrame = true
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = cameraCFrame
	camera.FieldOfView = self._cameraFov or PREVIEW_FIELD_OF_VIEW
	self._applyingCameraFrame = false
end

function BundlePreviewDirector:_disconnectCameraGuard()
	for _, connection in ipairs(self._cameraGuardConnections) do
		connection:Disconnect()
	end
	table.clear(self._cameraGuardConnections)
end

function BundlePreviewDirector:_bindCameraGuard()
	self:_disconnectCameraGuard()

	local function enforce()
		if self._applyingCameraFrame or not self._running then
			return
		end
		self:_applyCameraFrame()
	end

	local function bindCamera(camera: Camera?)
		if not camera then
			return
		end
		table.insert(self._cameraGuardConnections, camera:GetPropertyChangedSignal("CameraType"):Connect(enforce))
		table.insert(self._cameraGuardConnections, camera:GetPropertyChangedSignal("CameraSubject"):Connect(enforce))
	end

	bindCamera(Workspace.CurrentCamera)
	table.insert(
		self._cameraGuardConnections,
		Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			self:_bindCameraGuard()
			enforce()
		end)
	)
end

function BundlePreviewDirector:_cancelCameraTween()
	if self._cameraTween then
		self._cameraTween:Cancel()
		self._cameraTween = nil
	end
	if self._cameraTweenConnection then
		self._cameraTweenConnection:Disconnect()
		self._cameraTweenConnection = nil
	end
	if self._cameraTweenValue then
		self._cameraTweenValue:Destroy()
		self._cameraTweenValue = nil
	end
end

function BundlePreviewDirector:_tweenCamera(
	startCFrame: CFrame,
	startFov: number,
	targetCFrame: CFrame,
	targetFov: number,
	tweenInfo: TweenInfo,
	onComplete: (() -> ())?
)
	self:_cancelCameraTween()
	self._cameraTransitionSerial += 1
	local serial = self._cameraTransitionSerial

	local progress = Instance.new("NumberValue")
	progress.Value = 0
	self._cameraTweenValue = progress
	self._cameraCFrame = startCFrame
	self._cameraFov = startFov
	self:_applyCameraFrame()

	self._cameraTweenConnection = progress:GetPropertyChangedSignal("Value"):Connect(function()
		local alpha = progress.Value
		self._cameraCFrame = startCFrame:Lerp(targetCFrame, alpha)
		self._cameraFov = startFov + ((targetFov - startFov) * alpha)
		self:_applyCameraFrame()
	end)

	local tween = TweenService:Create(progress, tweenInfo, {
		Value = 1,
	})
	self._cameraTween = tween
	tween:Play()
	tween.Completed:Once(function(playbackState)
		if self._cameraTransitionSerial ~= serial or self._cameraTween ~= tween then
			return
		end

		self:_cancelCameraTween()
		if playbackState == Enum.PlaybackState.Completed then
			self._cameraCFrame = targetCFrame
			self._cameraFov = targetFov
			self:_applyCameraFrame()
			if onComplete then
				onComplete()
			end
		end
	end)
end

function BundlePreviewDirector:_bindCamera()
	RunService:UnbindFromRenderStep(CAMERA_BIND_NAME)
	self:_bindCameraGuard()
	RunService:BindToRenderStep(CAMERA_BIND_NAME, Enum.RenderPriority.Camera.Value + 50, function()
		if self._running then
			self:_applyCameraFrame()
		end
	end)
end

function BundlePreviewDirector:_applyCamera(smooth: boolean?, cameraPreset: string?)
	if cameraPreset then
		self._cameraPreset = cameraPreset
	end
	local targetCFrame = self:_computeCameraCFrame()
	if not targetCFrame then
		return
	end

	local camera = Workspace.CurrentCamera
	if smooth and camera then
		camera.CameraType = Enum.CameraType.Scriptable
		self:_bindCamera()
		self:_tweenCamera(camera.CFrame, camera.FieldOfView, targetCFrame, PREVIEW_FIELD_OF_VIEW, CAMERA_ENTER_TWEEN)
		return
	end

	self:_cancelCameraTween()
	self._cameraCFrame = targetCFrame
	self._cameraFov = PREVIEW_FIELD_OF_VIEW
	self:_applyCameraFrame()
	self:_bindCamera()
end

function BundlePreviewDirector:_transitionCameraToPreset(
	cameraPreset: string,
	tweenInfo: TweenInfo?,
	onComplete: (() -> ())?,
	previewId: string?,
	instant: boolean?
)
	local resolvedTweenInfo = tweenInfo or CAMERA_PREVIEW_TWEEN
	local targetCFrame = self:_computeCameraCFrame(cameraPreset)
	self:_debugCameraTarget(previewId, cameraPreset, targetCFrame)
	if not targetCFrame then
		if onComplete then
			onComplete()
		end
		return
	end

	local camera = Workspace.CurrentCamera
	self._cameraPreset = cameraPreset
	if instant then
		if camera then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		self:_cancelCameraTween()
		self._cameraCFrame = targetCFrame
		self._cameraFov = PREVIEW_FIELD_OF_VIEW
		self:_applyCameraFrame()
		self:_bindCamera()
		if onComplete then
			onComplete()
		end
		return
	end

	local startCFrame = self._cameraCFrame or (camera and camera.CFrame) or targetCFrame
	local startFov = self._cameraFov or (camera and camera.FieldOfView) or PREVIEW_FIELD_OF_VIEW
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	self:_bindCamera()
	self:_tweenCamera(startCFrame, startFov, targetCFrame, PREVIEW_FIELD_OF_VIEW, resolvedTweenInfo, onComplete)

	local transitionSerial = self._cameraTransitionSerial
	if cameraPreset == SINGLE_PEDESTAL_CAMERA_PRESET then
		task.delay(resolvedTweenInfo.Time + CAMERA_SNAP_FALLBACK_DELAY, function()
			if
				self._cameraTransitionSerial ~= transitionSerial
				or self._cameraPreset ~= cameraPreset
				or not self._running
			then
				return
			end

			local currentCamera = Workspace.CurrentCamera
			if not currentCamera then
				return
			end

			local distance = (currentCamera.CFrame.Position - targetCFrame.Position).Magnitude
			if distance <= CAMERA_TARGET_EPSILON then
				return
			end

			warn(
				("[BundlesPreview] Camera tween missed %s for %s by %.2f studs; snapping to marker"):format(
					SINGLE_PEDESTAL_CAMERA_PRESET,
					tostring(previewId),
					distance
				)
			)
			self._cameraCFrame = targetCFrame
			self._cameraFov = PREVIEW_FIELD_OF_VIEW
			self:_applyCameraFrame()
		end)
	end
end

function BundlePreviewDirector:_restoreCamera(smooth: boolean?, onComplete: (() -> ())?)
	local state = self._cameraState
	local camera = Workspace.CurrentCamera
	self._cameraState = nil
	if not (state and camera) then
		self:_cancelCameraTween()
		RunService:UnbindFromRenderStep(CAMERA_BIND_NAME)
		self._cameraCFrame = nil
		self._cameraFov = PREVIEW_FIELD_OF_VIEW
		if onComplete then
			onComplete()
		end
		return
	end

	local function finishRestore()
		self:_cancelCameraTween()
		self:_disconnectCameraGuard()
		RunService:UnbindFromRenderStep(CAMERA_BIND_NAME)
		self._cameraCFrame = nil
		self._cameraFov = PREVIEW_FIELD_OF_VIEW
		if camera.Parent then
			camera.CameraType = state.CameraType
			camera.CameraSubject = state.CameraSubject
			camera.CFrame = state.CFrame
			camera.FieldOfView = state.FieldOfView
		end
		if onComplete then
			onComplete()
		end
	end

	if smooth then
		local startCFrame = camera.CFrame
		local startFov = camera.FieldOfView
		camera.CameraType = Enum.CameraType.Scriptable
		self:_tweenCamera(startCFrame, startFov, state.CFrame, state.FieldOfView, CAMERA_EXIT_TWEEN, finishRestore)
	else
		finishRestore()
	end
end

function BundlePreviewDirector:_createStage(instantCamera: boolean?)
	local source = self:_getStageSource()
	if not source then
		warn("[BundlesPreview] Missing ReplicatedStorage.Assets.Staging")
		return false
	end

	local stage = source:Clone()
	stage.Name = STAGE_CLONE_NAME
	stage.Parent = Workspace
	prepareLocalVisual(stage)

	self._stage = stage
	self._activeScene = self:_ensureFolder(stage, ACTIVE_SCENE_NAME)
	self:_ensureFolder(stage, SOCKETS_NAME)
	self:_ensureFolder(stage, CAMERA_MARKERS_NAME)
	self:_saveCamera()
	self:_buildSockets()
	self:_hideAuthoredDisplayObjects()
	self:_applyCamera(not instantCamera)

	return true
end

function BundlePreviewDirector:Start(options: { [string]: any }?)
	if self._running then
		return true
	end
	self._running = true
	return self:_createStage(typeof(options) == "table" and options.InstantCamera == true)
end

function BundlePreviewDirector:_clearLane(socketName: string)
	local cleanup = self._laneCleanups[socketName]
	if cleanup then
		cleanup:Destroy()
		self._laneCleanups[socketName] = nil
	end

	local activeScene = self._activeScene
	if activeScene then
		local lane = activeScene:FindFirstChild(socketName)
		if lane then
			lane:Destroy()
		end
	end
end

function BundlePreviewDirector:_clearAll()
	if self._sceneCleanup then
		self._sceneCleanup:Destroy()
		self._sceneCleanup = nil
	end

	for socketName in pairs(self._laneCleanups) do
		self:_clearLane(socketName)
	end

	local activeScene = self._activeScene
	if activeScene then
		activeScene:ClearAllChildren()
	end
	self._actor = nil
end

function BundlePreviewDirector:_clearAllExceptLane(keepSocketName: string)
	if self._sceneCleanup then
		self._sceneCleanup:Destroy()
		self._sceneCleanup = nil
	end

	for socketName in pairs(self._laneCleanups) do
		if socketName ~= keepSocketName then
			self:_clearLane(socketName)
		end
	end

	local activeScene = self._activeScene
	if activeScene then
		for _, child in ipairs(activeScene:GetChildren()) do
			if child.Name ~= keepSocketName then
				child:Destroy()
			end
		end
	end
	self._actor = nil
end

function BundlePreviewDirector:_clearLanes()
	for socketName in pairs(self._laneCleanups) do
		self:_clearLane(socketName)
	end
end

function BundlePreviewDirector:_getLaneFolder(socketName: string): Folder?
	local activeScene = self._activeScene
	if not activeScene then
		return nil
	end
	local lane = activeScene:FindFirstChild(socketName)
	if lane and lane:IsA("Folder") then
		lane:ClearAllChildren()
		return lane
	end
	if lane then
		lane:Destroy()
	end
	local created = Instance.new("Folder")
	created.Name = socketName
	created.Parent = activeScene
	return created
end

function BundlePreviewDirector:_cloneAsset(path: { string }?, name: string): Instance?
	local asset = getReplicatedAsset(path)
	if not asset then
		warn(("[BundlesPreview] Missing asset for %s"):format(name))
		return nil
	end
	local clone = asset:Clone()
	clone.Name = name
	prepareLocalVisual(clone)
	return clone
end

function BundlePreviewDirector:_playStaticModel(recipe, parent: Instance, cleanup, socketOverride: string?)
	local config = recipe.Config or {}
	local socketName = normalizeSocketName(socketOverride or config.Socket or "RightDisplay")
	local socketCFrame = self._sockets[socketName] or self._sockets.RightDisplay or CFrame.new()
	if config.UsePedestalAttachment == true then
		socketCFrame = self:_getPedestalAttachmentCFrame(socketName, config.AttachmentName or "BombOrigin")
			or socketCFrame
	end
	local clone = self:_cloneAsset(config.AssetPath, recipe.Id or "StaticPreview")
	if not clone then
		return
	end

	scaleVisual(clone, config.Scale)
	clone.Parent = parent
	if config.Grounded == false then
		pivotTo(clone, socketCFrame * CFrame.new(0, tonumber(config.VerticalOffset) or 0, 0))
	else
		pivotTo(clone, getGroundedCFrame(clone, socketCFrame, config.VerticalOffset))
	end
	cleanup:AddInstance(clone)

	local rotationSpeed = tonumber(config.RotationSpeed) or 0.45
	local baseCFrame = getPivot(clone)
	local elapsed = 0
	cleanup:AddConnection(RunService.RenderStepped:Connect(function(deltaTime)
		if cleanup:IsCancelled() or not clone.Parent then
			return
		end
		elapsed += deltaTime
		pivotTo(clone, baseCFrame * CFrame.Angles(0, elapsed * rotationSpeed, 0))
	end))
end

function BundlePreviewDirector:_getPedestalAttachmentCFrame(socketName: string, attachmentName: string): CFrame?
	local pedestal = self:_getPedestalForSocket(socketName)
	local attachment = findFirstDescendant(pedestal, attachmentName, "Attachment")
	return if attachment then getPivot(attachment) else nil
end

function BundlePreviewDirector:_emitImpactAsset(config, folder: Instance, position: Vector3, cleanup)
	local impact = self:_cloneAsset(config.ImpactAssetPath, "FatBombImpactPreview")
	if not impact then
		return
	end

	local impactScale = tonumber(config.ImpactVfxScale) or tonumber(config.VisualScale) or 1
	scaleVisual(impact, impactScale)
	scaleEffects(impact, impactScale)
	sanitizePreviewVfx(impact, {
		LightBrightnessScale = 0.15,
		MaxEmitterBrightness = 0.7,
		MaxLightBrightness = 0.25,
		MaxLightRange = 5,
	})
	impact.Parent = folder
	pivotTo(impact, CFrame.new(position))
	cleanup:AddInstance(impact)

	for _, descendant in ipairs(impact:GetDescendants()) do
		if descendant:IsA("Sound") and descendant.SoundId ~= "" then
			descendant.Looped = false
			descendant.TimePosition = 0
			descendant:Play()
		end
	end

	EmitService.Emit(impact, "[BundlesPreview]")
end

function BundlePreviewDirector:_playAbilityCast(recipe, parent: Instance, cleanup, socketOverride: string?)
	local config = recipe.Config or {}
	local socketName = normalizeSocketName(socketOverride or config.Socket or "LeftDisplay")
	local socketCFrame = self._sockets[socketName] or self._sockets.LeftDisplay or CFrame.new()
	if config.LandOnPedestalBase == true then
		socketCFrame = self:_getPedestalBaseCFrame(socketName) or socketCFrame
	end
	local basePosition = socketCFrame.Position + Vector3.new(0, tonumber(config.ImpactHeightOffset) or 0.2, 0)
	local loopDelay = math.max(tonumber(config.LoopDelay) or DEFAULT_LOOP_DELAY, 1.5)
	local flareScale = tonumber(config.FlareScale) or tonumber(config.VisualScale) or 1
	local definition = AbilityConfig.GetDefinition(config.AbilityId or "FatBomb")
	local gameplayFallingScale =
		getDefinitionNumber(definition, "fallingCharacterScale", DEFAULT_FALLING_CHARACTER_SCALE)
	local previewScaleMultiplier = tonumber(config.FallingPreviewScaleMultiplier)
		or DEFAULT_FALLING_PREVIEW_SCALE_MULTIPLIER
	local fallingScale = tonumber(config.FallingScale)
		or tonumber(config.VisualScale)
		or (gameplayFallingScale * previewScaleMultiplier)
	local radius = math.max(tonumber(definition and definition.radius) or 18, 10)

	local function playOnce()
		if cleanup:IsCancelled() or not parent.Parent then
			return
		end

		parent:ClearAllChildren()

		local flare = self:_cloneAsset(config.FlareAssetPath, "FatBombFlarePreview")
		if flare then
			scaleVisual(flare, flareScale)
			scaleEffects(flare, flareScale)
			sanitizePreviewVfx(flare, {
				LightBrightnessScale = 0.08,
				MaxEmitterBrightness = 0.55,
				MaxLightBrightness = 0.18,
				MaxLightRange = 4,
			})
			flare.Parent = parent
			pivotTo(
				flare,
				CFrame.new(basePosition + Vector3.new(0, 0.35, 0)) * CFrame.Angles(math.rad(-82), 0, math.rad(10))
			)
			cleanup:AddInstance(flare)
			EmitService.Emit(flare, "[BundlesPreview]")
		end

		local giant = self:_cloneAsset(config.FallingAssetPath, "FatBombFallingPreview")
		if giant then
			scaleVisual(giant, fallingScale)
			scaleEffects(giant, fallingScale)
			giant.Parent = parent
			cleanup:AddInstance(giant)

			local startHeight = tonumber(config.FallingStartHeight) or 6
			local endHeight = tonumber(config.FallingEndHeight) or 0
			setFatGuyPreviewPose(giant, basePosition, startHeight)

			local progress = Instance.new("NumberValue")
			progress.Value = startHeight
			cleanup:AddInstance(progress)
			cleanup:AddConnection(progress:GetPropertyChangedSignal("Value"):Connect(function()
				if giant.Parent then
					setFatGuyPreviewPose(giant, basePosition, progress.Value)
				end
			end))
			TweenService:Create(progress, TweenInfo.new(1.1, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
				Value = endHeight,
			}):Play()
		end

		task.delay(1.08, function()
			if cleanup:IsCancelled() or not parent.Parent then
				return
			end
			self:_emitImpactAsset(config, parent, basePosition, cleanup)

			local shockwave = Instance.new("Part")
			shockwave.Name = "FatBombShockwavePreview"
			shockwave.Anchored = true
			shockwave.CanCollide = false
			shockwave.CanTouch = false
			shockwave.CanQuery = false
			shockwave.CastShadow = false
			shockwave.Material = Enum.Material.Neon
			shockwave.Color = Color3.fromRGB(255, 244, 214)
			shockwave.Transparency = 0.42
			shockwave.Shape = Enum.PartType.Cylinder
			shockwave.Size = Vector3.new(0.08, 1.5, 1.5)
			shockwave.CFrame = CFrame.new(basePosition) * CFrame.Angles(0, 0, math.rad(90))
			shockwave.Parent = parent
			cleanup:AddInstance(shockwave)
			TweenService:Create(shockwave, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = Vector3.new(0.08, radius * 0.72, radius * 0.72),
				Transparency = 1,
			}):Play()
		end)
	end

	local function loop()
		if cleanup:IsCancelled() then
			return
		end
		playOnce()
		task.delay(loopDelay, loop)
	end

	loop()
end

function BundlePreviewDirector:_getLocalDescription(): HumanoidDescription?
	if self._description then
		return self._description:Clone()
	end

	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local ok, description = pcall(function()
			return humanoid:GetAppliedDescription()
		end)
		if ok and description then
			self._description = description:Clone()
			return description
		end
	end

	local ok, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(LocalPlayer.UserId)
	end)
	if ok and description then
		self._description = description:Clone()
		return description
	end

	return nil
end

function BundlePreviewDirector:_prepPreviewRig(rig: Model)
	for _, descendant in ipairs(rig:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = 0
			descendant.Anchored = descendant.Name == "HumanoidRootPart"
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
		elseif descendant:IsA("Humanoid") then
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			descendant.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			descendant.BreakJointsOnDeath = false
		elseif descendant:IsA("BaseScript") then
			descendant.Disabled = true
		end
	end
end

function BundlePreviewDirector:_createLocalPlayerActor(): Model?
	local description = self:_getLocalDescription()
	if description then
		local ok, actor = pcall(function()
			return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R6)
		end)
		description:Destroy()
		if ok and actor and actor:IsA("Model") then
			return actor
		end
	end

	local ok, actor = pcall(function()
		return Players:CreateHumanoidModelFromUserIdAsync(LocalPlayer.UserId)
	end)
	if ok and actor and actor:IsA("Model") then
		return actor
	end

	warn("[BundlesPreview] Failed to create local player preview actor")
	return nil
end

function BundlePreviewDirector:_getAnimator(humanoid: Humanoid): Animator
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

function BundlePreviewDirector:_stopHumanoidTracks(humanoid: Humanoid)
	local animator = self:_getAnimator(humanoid)
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		track:Stop(0)
		track:Destroy()
	end
end

function BundlePreviewDirector:_playIdle(humanoid: Humanoid, cleanup)
	local idleConfig = AnimationConfig.Animations.Idle
	if not idleConfig or typeof(idleConfig.AnimationId) ~= "string" or idleConfig.AnimationId == "" then
		return
	end

	self:_stopHumanoidTracks(humanoid)

	local animation = Instance.new("Animation")
	animation.AnimationId = idleConfig.AnimationId
	local ok, track = pcall(function()
		return self:_getAnimator(humanoid):LoadAnimation(animation)
	end)
	animation:Destroy()

	if not ok or not track then
		return
	end

	track.Looped = idleConfig.Looped == true
	track.Priority = idleConfig.Priority or Enum.AnimationPriority.Idle
	track:Play(0.12, idleConfig.Weight or 1, idleConfig.SpeedMultiplier or 1)

	cleanup:AddTask(function()
		track:Stop(0)
		track:Destroy()
	end)
end

function BundlePreviewDirector:_prepareCharacterActor(
	parent: Instance,
	cleanup,
	socketName: string?,
	actorName: string?,
	onReady: ((Model, Humanoid?) -> ())?,
	options: { [string]: any }?
)
	local normalizedSocket = normalizeSocketName(socketName or "CenterActor")
	local socketCFrame = if normalizedSocket == "CenterActor"
		then self._sockets.AuthoredActorRoot or self._sockets.CenterActor or CFrame.new()
		else self._sockets[normalizedSocket] or self._sockets.CenterActor or CFrame.new()
	local actorYawDegrees = if typeof(options) == "table" then tonumber(options.ActorYawDegrees) or 0 else 0
	if actorYawDegrees ~= 0 then
		socketCFrame *= CFrame.Angles(0, math.rad(actorYawDegrees), 0)
	end
	task.spawn(function()
		local actor = self:_createLocalPlayerActor()
		if cleanup:IsCancelled() or not parent.Parent then
			if actor then
				actor:Destroy()
			end
			return
		end
		if not actor then
			return
		end

		actor.Name = actorName or "PreviewActor"
		self:_prepPreviewRig(actor)
		actor.Parent = parent
		pivotRigRootToCFrame(actor, socketCFrame)
		cleanup:AddInstance(actor)

		local humanoid = actor:FindFirstChildOfClass("Humanoid")
		if not cleanup:IsCancelled() and onReady then
			onReady(actor, humanoid)
		end
	end)
end

function BundlePreviewDirector:_prepareActor(parent: Instance, cleanup)
	self:_prepareCharacterActor(parent, cleanup, "CenterActor", "PreviewActor", function(_actor, humanoid)
		if humanoid and not cleanup:IsCancelled() then
			self:_playIdle(humanoid, cleanup)
		end
	end)
end

function BundlePreviewDirector:_playEmoteActor(recipe, parent: Instance, cleanup, socketOverride: string?, options)
	local config = recipe.Config or {}
	local emoteId = if typeof(config.EmoteId) == "string" then config.EmoteId else "Honored One"
	local definition = EmoteConfig.GetDefinition(emoteId)
	local assetFolder = EmoteConfig.GetAssetFolder(emoteId)
	if not (definition and assetFolder) then
		warn(("[BundlesPreview] Missing emote preview assets for %s"):format(tostring(emoteId)))
		return
	end

	local socketName = normalizeSocketName(socketOverride or config.Socket or "CenterActor")
	local actorYawDegrees = config.ActorYawDegrees
	if typeof(options) == "table" and options.ActorYawDegrees ~= nil then
		actorYawDegrees = options.ActorYawDegrees
	end

	self:_prepareCharacterActor(parent, cleanup, socketName, "EmotePreviewActor", function(actor)
		if cleanup:IsCancelled() then
			return
		end

		local runtime = EmoteEffect.CreateRuntime(definition.id, actor, assetFolder)
		cleanup:AddTask(function()
			runtime:Destroy()
		end)

		local behavior = definition.behavior
		local ok, err = pcall(function()
			if behavior and type(behavior.Begin) == "function" then
				behavior:Begin(actor, runtime)
			end
		end)
		if not ok then
			warn(("[BundlesPreview] Failed to play emote preview %s: %s"):format(definition.id, tostring(err)))
			runtime:Destroy()
		end
	end, {
		ActorYawDegrees = actorYawDegrees,
	})
end

function BundlePreviewDirector:_playAbilityAura(recipe, parent: Instance, cleanup, socketOverride: string?)
	local config = recipe.Config or {}
	local abilityId = if typeof(config.AbilityId) == "string" then config.AbilityId else "Infinity"
	local definition = AbilityConfig.GetDefinition(abilityId)
	if not definition then
		warn(("[BundlesPreview] Missing ability definition for aura preview %s"):format(tostring(abilityId)))
		return
	end

	local socketName = normalizeSocketName(socketOverride or config.Socket or "RightDisplay")
	self:_prepareCharacterActor(parent, cleanup, socketName, "InfinityPreviewActor", function(actor, humanoid)
		if cleanup:IsCancelled() then
			return
		end
		if humanoid then
			self:_playIdle(humanoid, cleanup)
		end

		local rigTemplate = getReplicatedAsset(definition.rigEffectsAssetPath)
		if rigTemplate and rigTemplate:IsA("Model") then
			cloneInfinityRigEffects(rigTemplate, actor, cleanup)
		else
			warn("[BundlesPreview] Missing Infinity RigEffects preview asset")
		end

		local bubbleTemplate = getReplicatedAsset(definition.bubbleAssetPath)
		if bubbleTemplate then
			local bubble = bubbleTemplate:Clone()
			bubble.Name = "InfinityPreviewBubble"
			if
				attachInfinityBubbleToActor(
					bubble,
					actor,
					definition,
					tonumber(config.BubbleScaleMultiplier) or DEFAULT_INFINITY_PREVIEW_BUBBLE_SCALE_MULTIPLIER
				)
			then
				bubble.Parent = parent
				cleanup:AddInstance(bubble)
			else
				bubble:Destroy()
			end
		else
			warn("[BundlesPreview] Missing Infinity Bubble preview asset")
		end
	end, {
		ActorYawDegrees = config.ActorYawDegrees,
	})
end

function BundlePreviewDirector:_playBundleOverview(recipe, parent: Instance, cleanup, preservePedestals: boolean?)
	local slots = recipe.Config and recipe.Config.Slots or {}
	self:_setPedestalsForSlots(slots, preservePedestals, getRecipeTextGradientTemplateId(recipe))

	for _, slot in ipairs(slots) do
		if typeof(slot) ~= "table" then
			continue
		end

		local slotParent = parent
		if typeof(slot.Socket) == "string" then
			local folder = Instance.new("Folder")
			folder.Name = slot.Socket
			folder.Parent = parent
			cleanup:AddInstance(folder)
			slotParent = folder
		end

		local mode = slot.Mode
		if mode == "IdleActor" then
			self:_prepareActor(slotParent, cleanup)
		elseif mode == "Emote" then
			local childRecipe = BundleCatalog.GetPreviewRecipe(slot.PreviewId)
			if childRecipe then
				self:_playEmoteActor(childRecipe, slotParent, cleanup, normalizeSocketName(slot.Socket), {
					ActorYawDegrees = slot.ActorYawDegrees,
				})
			end
		elseif mode == "AbilityAura" then
			local childRecipe = BundleCatalog.GetPreviewRecipe(slot.PreviewId)
			if childRecipe then
				self:_playAbilityAura(childRecipe, slotParent, cleanup, normalizeSocketName(slot.Socket))
			end
		elseif mode == "Static" then
			local childRecipe = BundleCatalog.GetPreviewRecipe(slot.PreviewId)
			if childRecipe then
				self:_playStaticModel(childRecipe, slotParent, cleanup, normalizeSocketName(slot.Socket))
			end
		elseif mode == "AbilityCast" then
			local childRecipe = BundleCatalog.GetPreviewRecipe(slot.PreviewId)
			if childRecipe then
				self:_playAbilityCast(childRecipe, slotParent, cleanup, normalizeSocketName(slot.Socket))
			end
		end
	end
end

function BundlePreviewDirector:_playRecipe(
	recipe,
	parent: Instance,
	cleanup,
	socketOverride: string?,
	options: { [string]: any }?
)
	local presenter = recipe.Presenter
	local preset = recipe.StagePreset

	if not REAL_PRESETS[preset] then
		warn(("[BundlesPreview] Unsupported stage preset %s"):format(tostring(preset)))
		return
	end
	if not REAL_PRESENTERS[presenter] then
		warn(("[BundlesPreview] Unsupported presenter %s"):format(tostring(presenter)))
		return
	end

	if presenter == "StaticModelPresenter" then
		self:_playStaticModel(recipe, parent, cleanup, socketOverride)
	elseif presenter == "AbilityCastPresenter" then
		self:_playAbilityCast(recipe, parent, cleanup, socketOverride)
	elseif presenter == "AbilityAuraPresenter" then
		self:_playAbilityAura(recipe, parent, cleanup, socketOverride)
	elseif presenter == "EmotePresenter" then
		self:_playEmoteActor(recipe, parent, cleanup, socketOverride)
	elseif presenter == "BundleOverviewPresenter" then
		self:_playBundleOverview(recipe, parent, cleanup, options and options.PreservePedestals == true)
	end
end

function BundlePreviewDirector:_getLaneSocket(recipe): string
	local config = recipe.Config or {}
	if typeof(config.LaneSocket) == "string" and config.LaneSocket ~= "" then
		return normalizeSocketName(config.LaneSocket)
	end
	return SINGLE_PEDESTAL_SOCKET
end

function BundlePreviewDirector:_getSceneCameraPreset(recipe): string
	local cameraPreset = recipe.CameraPreset
	if typeof(cameraPreset) == "string" and cameraPreset ~= "" then
		return cameraPreset
	end
	return WIDE_CAMERA_PRESET
end

function BundlePreviewDirector:_getLaneCameraPreset(recipe): string
	local config = recipe.Config or {}
	local cameraPreset = config.LaneCameraPreset
	if typeof(cameraPreset) == "string" and cameraPreset ~= "" then
		return cameraPreset
	end
	return SINGLE_PEDESTAL_CAMERA_PRESET
end

function BundlePreviewDirector:_getRandomMapHighlightIntroCFrame(): CFrame?
	local attachmentName = RoundEndFlowConfig.POTGAttachmentName
	if typeof(attachmentName) ~= "string" or attachmentName == "" then
		return nil
	end

	local candidates = {}
	local mapTemplateFolder = getMapTemplateFolder()
	if mapTemplateFolder then
		for _, mapConfig in ipairs(RoundConfig.Maps or {}) do
			if typeof(mapConfig) ~= "table" or typeof(mapConfig.id) ~= "string" then
				continue
			end

			local mapTemplate = mapTemplateFolder:FindFirstChild(mapConfig.id)
			local attachment = findNamedAttachment(mapTemplate, attachmentName)
			if attachment then
				table.insert(candidates, attachment)
			end
		end

		if #candidates == 0 then
			for _, child in ipairs(mapTemplateFolder:GetChildren()) do
				local attachment = findNamedAttachment(child, attachmentName)
				if attachment then
					table.insert(candidates, attachment)
				end
			end
		end
	end

	if #candidates > 0 then
		return candidates[PREVIEW_RANDOM:NextInteger(1, #candidates)].WorldCFrame
	end

	local activeMapName = RoundConfig.ActiveMapName
	local activeMap = if typeof(activeMapName) == "string" then Workspace:FindFirstChild(activeMapName) else nil
	local activeAttachment = findNamedAttachment(activeMap, attachmentName)
	if activeAttachment then
		return activeAttachment.WorldCFrame
	end

	if not warnedMissingHighlightIntroAttachment then
		warn(("[BundlesPreview] No map %s attachment found for highlight intro preview"):format(attachmentName))
		warnedMissingHighlightIntroAttachment = true
	end
	return nil
end

function BundlePreviewDirector:Play(previewId: string, onComplete: ((string) -> ())?, options: { [string]: any }?)
	local recipe = BundleCatalog.GetPreviewRecipe(previewId)
	if not recipe then
		warn(("[BundlesPreview] Unknown preview id %s"):format(tostring(previewId)))
		return
	end

	if recipe.Presenter == "HighlightIntroPresenter" then
		if self._running then
			self:Stop(false)
		end

		local config = recipe.Config or {}
		local cutsceneId = if typeof(config.CutsceneId) == "string" then config.CutsceneId else "HollowPurple"
		self._fullscreenPreviewActive = true
		local started = POTGCutsceneController:PlayPreview(cutsceneId, function(reason)
			self._fullscreenPreviewActive = false
			if onComplete then
				onComplete(reason)
			end
		end, {
			cameraCFrame = self:_getRandomMapHighlightIntroCFrame(),
			potgPlayerUserId = LocalPlayer.UserId,
			revealAfterPreviewCallback = typeof(options) == "table" and options.RevealAfterPreviewCallback == true,
		})
		if not started then
			self._fullscreenPreviewActive = false
		end
		if not started and onComplete then
			onComplete("Unavailable")
		end
		return
	end

	local instantCamera = typeof(options) == "table" and options.InstantCamera == true
	if not self._running and not self:Start({
		InstantCamera = instantCamera,
	}) then
		return
	end

	self._requestSerial += 1
	local requestSerial = self._requestSerial
	local mode = recipe.PreviewMode
	local textGradientTemplateId = getRecipeTextGradientTemplateId(recipe)
	if mode == "Lane" then
		local socketName = self:_getLaneSocket(recipe)
		local cameraPreset = self:_getLaneCameraPreset(recipe)
		self:_clearLane(socketName)
		local lane = self:_getLaneFolder(socketName)
		if not lane then
			return
		end
		local cleanup = makeCleanup()
		self._laneCleanups[socketName] = cleanup
		self:_setPedestalsForSockets({ socketName }, {
			[socketName] = typeof(recipe.Title) == "string" and recipe.Title or "",
		}, {
			[socketName] = textGradientTemplateId,
		}, true)
		self:_playRecipe(recipe, lane, cleanup, socketName)
		self:_transitionCameraToPreset(cameraPreset, CAMERA_PREVIEW_TWEEN, function()
			if self._requestSerial ~= requestSerial then
				return
			end
			self:_clearAllExceptLane(socketName)
			self:_setPedestalsForSockets({ socketName }, {
				[socketName] = typeof(recipe.Title) == "string" and recipe.Title or "",
			}, {
				[socketName] = textGradientTemplateId,
			})
		end, previewId, instantCamera)
		return
	end

	local hadLanePreview = next(self._laneCleanups) ~= nil
	local cameraPreset = self:_getSceneCameraPreset(recipe)
	if self._sceneCleanup then
		self._sceneCleanup:Destroy()
		self._sceneCleanup = nil
	end
	local cleanup = makeCleanup()
	self._sceneCleanup = cleanup
	local activeScene = self._activeScene
	if activeScene then
		self:_playRecipe(recipe, activeScene, cleanup, nil, {
			PreservePedestals = hadLanePreview,
		})
	end
	self:_transitionCameraToPreset(cameraPreset, CAMERA_PREVIEW_TWEEN, function()
		if self._requestSerial ~= requestSerial then
			return
		end
		self:_clearLanes()
		if recipe.Presenter == "BundleOverviewPresenter" then
			self:_setPedestalsForSlots(recipe.Config and recipe.Config.Slots or nil, nil, textGradientTemplateId)
		end
	end, previewId, instantCamera)
end

function BundlePreviewDirector:Stop(smooth: boolean?)
	if self._fullscreenPreviewActive then
		self._fullscreenPreviewActive = false
		POTGCutsceneController:CancelPreview()
	end
	if not self._running then
		return
	end
	self._running = false
	self:_clearAll()
	local stage = self._stage
	self._stage = nil
	self._activeScene = nil
	self._sockets = {}
	self._cameraMarkers = {}
	self:_restoreCamera(smooth, function()
		if stage and stage.Parent then
			stage:Destroy()
		end
	end)
end

return BundlePreviewDirector
