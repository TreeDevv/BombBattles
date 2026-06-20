local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local SoundUtil = require(ReplicatedStorage.Shared.Audio.SoundUtil)
local CameraController = require(script.Parent.Parent:WaitForChild("CameraController"))
local MovementController = require(script.Parent.Parent:WaitForChild("MovementController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type GrappleVisual = {
	rootAttachment: Attachment?,
	anchorAttachment: Attachment?,
	muzzleProxyPart: BasePart?,
	anchorPart: BasePart?,
	anchorInstance: Instance?,
	beam: Beam?,
	spring: SpringConstraint?,
	tween: Tween?,
	tweens: { Tween },
	followConnection: RBXScriptConnection?,
	pivotConnection: RBXScriptConnection?,
	pivotValue: CFrameValue?,
	targetAttachmentParent: BasePart?,
	anchorFollowsTarget: boolean,
	travelStartedAt: number,
	travelDuration: number,
	destroyed: boolean,
}

type ActivePlayerPull = {
	sessionId: number,
	rootPart: BasePart,
	anchorPosition: Vector3,
	pullTargetPosition: Vector3,
	hitNormal: Vector3?,
	startedAt: number,
	lastStepAt: number,
	startDistance: number,
	maxDuration: number,
	arrivalDistance: number,
	minPullSpeed: number,
	maxPullSpeed: number,
	pullAcceleration: number,
	upwardBias: number,
	steerAcceleration: number,
	maxSteerSpeed: number,
	tangentialRetention: number,
	maxTangentialSpeed: number,
	releaseUpwardVelocity: number,
	releaseForwardVelocity: number,
	releaseMomentumScale: number,
	releaseMaxSpeed: number,
	releaseWallKickSpeed: number,
	releaseWallKickMaxDistance: number,
	releaseWallKickIntoWallDot: number,
	airControlMinAirTime: number,
	maxRange: number,
	connection: RBXScriptConnection?,
	visual: GrappleVisual?,
}

local GrappleHook = {} :: AbilityTypes.ClientBehavior
GrappleHook.HandlesInputState = true

local LocalPlayer = Players.LocalPlayer
local DEBUG_GRAPPLE = false
local VISUAL_FOLDER_NAME = "GrappleHookVisuals"
local SOUND_FIRE = "GrappleHookFire"
local SOUND_LATCH = "GrappleHookLatch"
local SOUND_BOMB = "GrappleHookBomb"
local SOUND_FAIL = "GrappleHookFail"
local SOUND_RELEASE = "GrappleHookRelease"

local activePull: ActivePlayerPull? = nil
local activeServerSessionId: number? = nil
local activeServerSessionKind: string? = nil
local pendingVisuals: { [number]: GrappleVisual } = {}
local remoteVisuals: { [number]: GrappleVisual } = {}
local nextSequence = 0
local jumpConnection: RBXScriptConnection? = nil

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

local function getDefinitionBoolean(definition: AbilityDefinition?, key: string, fallback: boolean): boolean
	local value = if definition then definition[key] else nil
	return if typeof(value) == "boolean" then value else fallback
end

local function clampMagnitude(vector: Vector3, maxMagnitude: number): Vector3
	if maxMagnitude <= 0 then
		return Vector3.zero
	end

	local magnitude = vector.Magnitude
	if magnitude <= maxMagnitude then
		return vector
	end
	return vector.Unit * maxMagnitude
end

local function flattenDirection(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude <= 0.001 then
		return Vector3.zero
	end
	return flat.Unit
end

local function playOptionalSound(soundName: string, parent: Instance?)
	SoundUtil.Play(soundName, parent)
end

local function playSoundDescendants(instance: Instance?)
	if not instance then
		return
	end

	if instance:IsA("Sound") and instance.SoundId ~= "" then
		instance.TimePosition = 0
		instance:Play()
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("Sound") and descendant.SoundId ~= "" then
			descendant.TimePosition = 0
			descendant:Play()
		end
	end
end

local function playVisualSounds(visual: GrappleVisual?)
	if visual and visual.anchorInstance then
		playSoundDescendants(visual.anchorInstance)
	end
end

local function setDebugAttribute(name: string, value: any?)
	LocalPlayer:SetAttribute("GrappleHook_" .. name, value)
end

local function setClientStatus(status: string, reason: string?)
	setDebugAttribute("ClientStatus", status)
	setDebugAttribute("ClientRejectReason", reason or "")
	setDebugAttribute("ClientAt", workspace:GetServerTimeNow())
	if DEBUG_GRAPPLE then
		print("[GrappleHook][Client]", status, reason or "")
	end
end

local function getVisualFolder(): Folder
	local existing = workspace:FindFirstChild(VISUAL_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = VISUAL_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

local function getMuzzlePart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local candidateNames = { "RightHand", "Right Arm", "RightLowerArm", "Torso", "UpperTorso", "HumanoidRootPart" }
	for _, name in ipairs(candidateNames) do
		local child = character:FindFirstChild(name)
		if child and child:IsA("BasePart") then
			return child
		end
	end
	return character:FindFirstChildWhichIsA("BasePart")
end

local function getRootPartFromInstance(instance: Instance?): BasePart?
	if not instance then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		if instance.PrimaryPart and instance.PrimaryPart:IsA("BasePart") then
			return instance.PrimaryPart
		end
		return instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function getByPath(root: Instance, path: { string }): Instance?
	local current: Instance? = root
	for _, name in ipairs(path) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getHookTemplate(definition: AbilityDefinition?): Instance?
	local path = definition and definition.assetPath
	if typeof(path) ~= "table" then
		return nil
	end

	local template = getByPath(ReplicatedStorage, path)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
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

local function pivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function getHookCFrame(position: Vector3, direction: Vector3): CFrame
	if direction.Magnitude < 0.05 then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, position + direction.Unit)
end

local function getMouseRay(): (Vector3?, Vector3?)
	local camera = workspace.CurrentCamera
	if not camera then
		return nil, nil
	end

	local mouseLocation = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)
	if unitRay.Direction.Magnitude < 0.05 then
		return nil, nil
	end

	return unitRay.Origin, unitRay.Direction.Unit
end

local function getPredictionRaycastParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = {}
	if LocalPlayer.Character then
		table.insert(exclude, LocalPlayer.Character)
	end
	local visualFolder = workspace:FindFirstChild(VISUAL_FOLDER_NAME)
	if visualFolder then
		table.insert(exclude, visualFolder)
	end
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = true
	return params
end

local function predictEndpoint(origin: Vector3, direction: Vector3, definition: AbilityDefinition): Vector3
	local maxRange = math.max(getDefinitionNumber(definition, "maxRange", 350), 1)
	local hit = workspace:Raycast(origin, direction * maxRange, getPredictionRaycastParams())
	return if hit then hit.Position else origin + direction * maxRange
end

local function tintVisual(visual: GrappleVisual?, color: Color3, widthScale: number?)
	if not visual then
		return
	end

	if visual.beam and visual.beam.Parent then
		visual.beam.Color = ColorSequence.new(color)
		local scale = math.max(widthScale or 1, 0.05)
		visual.beam.Width0 *= scale
		visual.beam.Width1 *= scale
	end
	if visual.spring and visual.spring.Parent then
		visual.spring.Color = BrickColor.new(color)
	end
	if visual.anchorInstance and visual.anchorInstance.Parent then
		for _, part in ipairs(getBaseParts(visual.anchorInstance)) do
			if part.Material == Enum.Material.Neon or part.Transparency < 0.95 then
				part.Color = color
			end
		end
	elseif visual.anchorPart and visual.anchorPart.Parent then
		visual.anchorPart.Color = color
	end
end

local function spawnImpactPulse(position: Vector3, color: Color3, size: number, duration: number)
	local folder = getVisualFolder()
	local pulse = Instance.new("Part")
	pulse.Name = "GrappleHookImpactPulse"
	pulse.Shape = Enum.PartType.Ball
	pulse.Anchored = true
	pulse.CanCollide = false
	pulse.CanQuery = false
	pulse.CanTouch = false
	pulse.CastShadow = false
	pulse.Material = Enum.Material.Neon
	pulse.Color = color
	pulse.Transparency = 0.24
	pulse.Size = Vector3.new(0.18, 0.18, 0.18)
	pulse.CFrame = CFrame.new(position)
	pulse.Parent = folder

	TweenService:Create(
		pulse,
		TweenInfo.new(math.max(duration, 0.03), Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Size = Vector3.new(size, size, size),
			Transparency = 1,
		}
	):Play()
	task.delay(duration + 0.04, function()
		if pulse.Parent then
			pulse:Destroy()
		end
	end)
end

local function destroyVisual(visual: GrappleVisual?)
	if not visual then
		return
	end
	visual.destroyed = true
	if visual.tween then
		visual.tween:Cancel()
	end
	if visual.followConnection then
		visual.followConnection:Disconnect()
	end
	if visual.pivotConnection then
		visual.pivotConnection:Disconnect()
	end
	if visual.pivotValue then
		visual.pivotValue:Destroy()
	end
	for _, tween in ipairs(visual.tweens) do
		tween:Cancel()
	end
	table.clear(visual.tweens)
	if visual.beam and visual.beam.Parent then
		visual.beam:Destroy()
	end
	if visual.spring and visual.spring.Parent then
		visual.spring:Destroy()
	end
	if visual.rootAttachment and visual.rootAttachment.Parent then
		visual.rootAttachment:Destroy()
	end
	if visual.muzzleProxyPart and visual.muzzleProxyPart.Parent then
		visual.muzzleProxyPart:Destroy()
	end
	if visual.anchorInstance and visual.anchorInstance.Parent then
		visual.anchorInstance:Destroy()
	elseif visual.anchorPart and visual.anchorPart.Parent then
		visual.anchorPart:Destroy()
	end
end

local function playTrackedTween(visual: GrappleVisual, instance: Instance, tweenInfo: TweenInfo, properties: { [string]: any }): Tween
	local tween = TweenService:Create(instance, tweenInfo, properties)
	table.insert(visual.tweens, tween)
	tween.Completed:Connect(function()
		local index = table.find(visual.tweens, tween)
		if index then
			table.remove(visual.tweens, index)
		end
	end)
	tween:Play()
	return tween
end

local function clearPivotTween(visual: GrappleVisual)
	if visual.pivotConnection then
		visual.pivotConnection:Disconnect()
		visual.pivotConnection = nil
	end
	if visual.pivotValue then
		visual.pivotValue:Destroy()
		visual.pivotValue = nil
	end
end

local function tweenAnchorTo(visual: GrappleVisual, targetCFrame: CFrame, tweenInfo: TweenInfo): Tween?
	local anchorInstance = visual.anchorInstance
	if not (anchorInstance and anchorInstance.Parent) then
		return nil
	end

	if visual.tween then
		visual.tween:Cancel()
		visual.tween = nil
	end
	clearPivotTween(visual)

	if anchorInstance:IsA("BasePart") then
		local tween = TweenService:Create(anchorInstance, tweenInfo, {
			CFrame = targetCFrame,
		})
		visual.tween = tween
		tween:Play()
		return tween
	end

	if anchorInstance:IsA("Model") then
		local pivotValue = Instance.new("CFrameValue")
		pivotValue.Value = anchorInstance:GetPivot()
		visual.pivotValue = pivotValue
		visual.pivotConnection = pivotValue:GetPropertyChangedSignal("Value"):Connect(function()
			if anchorInstance.Parent then
				anchorInstance:PivotTo(pivotValue.Value)
			end
		end)

		local tween = TweenService:Create(pivotValue, tweenInfo, {
			Value = targetCFrame,
		})
		visual.tween = tween
		tween.Completed:Connect(function()
			if visual.pivotValue == pivotValue then
				clearPivotTween(visual)
			end
		end)
		tween:Play()
		return tween
	end

	return nil
end

local function beginSpringTautOnLand(visual: GrappleVisual?, definition: AbilityDefinition, onTaut: (() -> ())?)
	if not visual or not visual.spring or not visual.spring.Parent then
		if onTaut then
			onTaut()
		end
		return
	end

	local spring = visual.spring
	spring.Coils = getDefinitionNumber(definition, "springCoilsTravel", 7)
	spring.Radius = getDefinitionNumber(definition, "springRadiusTravel", 0.38)
	spring.Thickness = getDefinitionNumber(definition, "springThicknessTravel", 0.08)
	spring.Damping = getDefinitionNumber(definition, "springDampingTravel", 0)
	spring.Stiffness = getDefinitionNumber(definition, "springStiffnessTravel", 35)

	local function playTautTween()
		if visual.destroyed or not spring.Parent then
			return
		end
		spring.Visible = getDefinitionBoolean(definition, "springVisible", true)
		local duration = math.max(getDefinitionNumber(definition, "springTautTweenSeconds", 0.16), 0.01)
		local tween = playTrackedTween(visual, spring, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Coils = getDefinitionNumber(definition, "springCoilsTaut", 1),
			Radius = getDefinitionNumber(definition, "springRadiusTaut", 0.04),
			Thickness = getDefinitionNumber(definition, "springThicknessTaut", 0.035),
			Damping = getDefinitionNumber(definition, "springDampingTaut", 18),
			Stiffness = getDefinitionNumber(definition, "springStiffnessTaut", 900),
		})
		tween.Completed:Connect(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed and not visual.destroyed and onTaut then
				onTaut()
			end
		end)
	end

	local delaySeconds = math.max(getDefinitionNumber(definition, "springUncoilDelaySeconds", 0), 0)
	if delaySeconds > 0 then
		task.delay(delaySeconds, playTautTween)
	else
		playTautTween()
	end
end

local function createVisual(
	player: Player,
	startPosition: Vector3,
	endPosition: Vector3,
	definition: AbilityDefinition,
	targetAttachmentParent: BasePart?
): GrappleVisual?
	local muzzlePart = getMuzzlePart(player)
	if not muzzlePart then
		return nil
	end

	local folder = getVisualFolder()
	local color = getDefinitionColor(definition, "beamColor", Color3.fromRGB(103, 229, 255))
	local anchorColor = getDefinitionColor(definition, "anchorColor", Color3.fromRGB(133, 245, 255))
	local anchorSize = math.max(getDefinitionNumber(definition, "anchorMarkerSize", 0.62), 0.1)
	local travelDirection = endPosition - startPosition

	local muzzleProxyPart = Instance.new("Part")
	muzzleProxyPart.Name = "GrappleHookMuzzleProxy"
	muzzleProxyPart.Anchored = true
	muzzleProxyPart.CanCollide = false
	muzzleProxyPart.CanQuery = false
	muzzleProxyPart.CanTouch = false
	muzzleProxyPart.CastShadow = false
	muzzleProxyPart.Transparency = 1
	muzzleProxyPart.Size = Vector3.new(0.12, 0.12, 0.12)
	muzzleProxyPart.CFrame = muzzlePart.CFrame
	muzzleProxyPart.Parent = folder

	local rootAttachment = Instance.new("Attachment")
	rootAttachment.Name = "GrappleHookRootAttachment"
	rootAttachment.Parent = muzzleProxyPart

	local anchorPart = nil :: BasePart?
	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Name = "GrappleHookAnchorAttachment"
	local anchorInstance = nil :: Instance?
	local hookTemplate = getHookTemplate(definition)
	if hookTemplate then
		local hookClone = hookTemplate:Clone()
		hookClone.Name = "GrappleHookAnchor"
		anchorPart = getRootPartFromInstance(hookClone)
		if anchorPart then
			for _, part in ipairs(getBaseParts(hookClone)) do
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.CastShadow = false
			end
			pivotTo(hookClone, getHookCFrame(startPosition, travelDirection))
			hookClone.Parent = folder
			anchorInstance = hookClone

			local coilAttachment = hookClone:FindFirstChild("Coil", true)
			if coilAttachment and coilAttachment:IsA("Attachment") then
				anchorAttachment = coilAttachment
			else
				anchorAttachment.Parent = anchorPart
			end
		else
			hookClone:Destroy()
		end
	end

	if anchorInstance then
		-- Cloned hook asset already provides the visible anchor.
	elseif targetAttachmentParent then
		anchorPart = Instance.new("Part")
		anchorPart.Name = "GrappleHookTargetProxy"
		anchorPart.Anchored = true
		anchorPart.CanCollide = false
		anchorPart.CanQuery = false
		anchorPart.CanTouch = false
		anchorPart.CastShadow = false
		anchorPart.Transparency = 1
		anchorPart.Size = Vector3.new(0.12, 0.12, 0.12)
		anchorPart.CFrame = CFrame.new(startPosition)
		anchorPart.Parent = folder
		anchorInstance = anchorPart
		anchorAttachment.Parent = anchorPart
	else
		anchorPart = Instance.new("Part")
		anchorPart.Name = "GrappleHookAnchor"
		anchorPart.Shape = Enum.PartType.Ball
		anchorPart.Anchored = true
		anchorPart.CanCollide = false
		anchorPart.CanQuery = false
		anchorPart.CanTouch = false
		anchorPart.CastShadow = false
		anchorPart.Material = Enum.Material.Neon
		anchorPart.Color = anchorColor
		anchorPart.Transparency = 0.18
		anchorPart.Size = Vector3.new(anchorSize, anchorSize, anchorSize)
		anchorPart.CFrame = CFrame.new(startPosition)
		anchorPart.Parent = folder
		anchorInstance = anchorPart
		anchorAttachment.Parent = anchorPart
	end

	local beam = Instance.new("Beam")
	beam.Name = "GrappleHookBeam"
	beam.Attachment0 = rootAttachment
	beam.Attachment1 = anchorAttachment
	beam.Color = ColorSequence.new(color)
	beam.FaceCamera = true
	beam.Enabled = getDefinitionBoolean(definition, "beamVisible", false)
	beam.LightEmission = 0.65
	beam.LightInfluence = 0
	beam.Width0 = math.max(getDefinitionNumber(definition, "beamWidth", 0.12), 0.02)
	beam.Width1 = beam.Width0
	beam.Parent = folder

	local spring = Instance.new("SpringConstraint")
	spring.Name = "GrappleHookSpring"
	spring.Attachment0 = rootAttachment
	spring.Attachment1 = anchorAttachment
	spring.Visible = if getDefinitionBoolean(definition, "springRevealOnLand", true)
		then false
		else getDefinitionBoolean(definition, "springVisible", true)
	spring.Coils = getDefinitionNumber(definition, "springCoilsTravel", 7)
	spring.Radius = getDefinitionNumber(definition, "springRadiusTravel", 0.38)
	spring.Thickness = getDefinitionNumber(definition, "springThicknessTravel", 0.08)
	spring.Damping = getDefinitionNumber(definition, "springDampingTravel", 0)
	spring.Stiffness = getDefinitionNumber(definition, "springStiffnessTravel", 35)
	spring.Color = BrickColor.new(getDefinitionColor(definition, "springColor", Color3.fromRGB(0, 0, 0)))
	spring.MaxForce = 0
	spring.Parent = folder

	local visual: GrappleVisual = {
		rootAttachment = rootAttachment,
		anchorAttachment = anchorAttachment,
		muzzleProxyPart = muzzleProxyPart,
		anchorPart = anchorPart,
		anchorInstance = anchorInstance,
		beam = beam,
		spring = spring,
		tween = nil,
		tweens = {},
		followConnection = nil,
		pivotConnection = nil,
		pivotValue = nil,
		targetAttachmentParent = targetAttachmentParent,
		anchorFollowsTarget = false,
		travelStartedAt = os.clock(),
		travelDuration = 0,
		destroyed = false,
	}

	visual.followConnection = RunService.RenderStepped:Connect(function()
		if muzzlePart.Parent and muzzleProxyPart.Parent then
			muzzleProxyPart.CFrame = muzzlePart.CFrame
		else
			destroyVisual(visual)
			return
		end
		if targetAttachmentParent and anchorPart and visual.anchorFollowsTarget then
			if targetAttachmentParent.Parent and anchorPart.Parent and anchorInstance and anchorInstance.Parent then
				pivotTo(anchorInstance, targetAttachmentParent.CFrame)
			else
				destroyVisual(visual)
			end
		end
	end)

	if anchorPart then
		local distance = (endPosition - startPosition).Magnitude
		local speed = math.max(getDefinitionNumber(definition, "projectileSpeed", 375), 1)
		local travelTime = math.clamp(distance / speed, 0.04, getDefinitionNumber(definition, "hookTravelMaxSeconds", 0.65))
		visual.travelDuration = travelTime
		tweenAnchorTo(
			visual,
			getHookCFrame(endPosition, travelDirection),
			TweenInfo.new(travelTime, Enum.EasingStyle.Linear)
		)
	end

	return visual
end

local function fadeAndDestroyVisual(visual: GrappleVisual?, fadeSeconds: number?)
	if not visual then
		return
	end

	local duration = math.max(fadeSeconds or 0.12, 0.01)
	if visual.beam and visual.beam.Parent then
		TweenService:Create(visual.beam, TweenInfo.new(duration), {
			Width0 = 0,
			Width1 = 0,
		}):Play()
	end
	if visual.anchorInstance and visual.anchorInstance.Parent then
		for _, part in ipairs(getBaseParts(visual.anchorInstance)) do
			TweenService:Create(part, TweenInfo.new(duration), {
				Transparency = 1,
			}):Play()
		end
	elseif visual.anchorPart and visual.anchorPart.Parent then
		TweenService:Create(visual.anchorPart, TweenInfo.new(duration), {
			Transparency = 1,
		}):Play()
	end
	if visual.spring and visual.spring.Parent then
		playTrackedTween(visual, visual.spring, TweenInfo.new(duration), {
			Radius = 0,
			Thickness = 0,
		})
	end
	task.delay(duration + 0.03, function()
		destroyVisual(visual)
	end)
end

local function trackPendingVisual(sequence: number, visual: GrappleVisual, definition: AbilityDefinition)
	pendingVisuals[sequence] = visual
	local timeoutSeconds = math.max(getDefinitionNumber(definition, "pendingVisualTimeoutSeconds", 1.15), 0.2)
	task.delay(timeoutSeconds, function()
		if pendingVisuals[sequence] ~= visual then
			return
		end

		pendingVisuals[sequence] = nil
		tintVisual(visual, getDefinitionColor(definition, "failColor", Color3.fromRGB(255, 86, 86)), 0.75)
		fadeAndDestroyVisual(visual, getDefinitionNumber(definition, "missVisualDurationSeconds", 0.16))
		setClientStatus("Fail", "TimedOut")
	end)
end

local function finishTravelAndTaut(
	visual: GrappleVisual?,
	anchorPosition: Vector3,
	definition: AbilityDefinition,
	onTaut: (() -> ())?
)
	if not visual then
		if onTaut then
			onTaut()
		end
		return
	end
	if visual.destroyed then
		return
	end

	local function tauten()
		if visual.destroyed then
			return
		end
		visual.anchorFollowsTarget = visual.targetAttachmentParent ~= nil
		beginSpringTautOnLand(visual, definition, onTaut)
	end

	local anchorPart = visual.anchorPart
	if not (anchorPart and anchorPart.Parent) then
		tauten()
		return
	end

	if visual.tween then
		visual.tween:Cancel()
		visual.tween = nil
	end
	clearPivotTween(visual)

	local elapsed = os.clock() - visual.travelStartedAt
	local remainingTravel = math.max(visual.travelDuration - elapsed, 0)
	local direction = anchorPosition - anchorPart.Position
	if remainingTravel <= 0.01 then
		local anchorInstance = visual.anchorInstance or anchorPart
		pivotTo(anchorInstance, getHookCFrame(anchorPosition, direction))
		tauten()
		return
	end

	local tween = tweenAnchorTo(
		visual,
		getHookCFrame(anchorPosition, direction),
		TweenInfo.new(remainingTravel, Enum.EasingStyle.Linear)
	)
	if tween then
		tween.Completed:Connect(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed and not visual.destroyed then
				tauten()
			end
		end)
	else
		tauten()
	end
end

local function applyConfirmedTravelTime(visual: GrappleVisual?, payload)
	if not visual or typeof(payload) ~= "table" then
		return
	end
	local travelTime = payload.travelTime
	if typeof(travelTime) == "number" and travelTime > 0 then
		visual.travelDuration = math.max(travelTime, 0.04)
	end
end

local function getRemainingServerPullDelay(payload): number?
	if typeof(payload) ~= "table" or typeof(payload.pullStartAt) ~= "number" then
		return nil
	end
	return payload.pullStartAt - workspace:GetServerTimeNow()
end

local function getPayloadNormal(payload): Vector3?
	if typeof(payload) ~= "table" or typeof(payload.hitNormal) ~= "Vector3" then
		return nil
	end

	local normal = payload.hitNormal
	if normal.Magnitude < 0.05 then
		return nil
	end
	return normal.Unit
end

local function shouldApplyWallKick(active: ActivePlayerPull, rootPart: BasePart): boolean
	local normal = active.hitNormal
	if not normal then
		return false
	end
	if active.releaseWallKickSpeed <= 0 or active.releaseWallKickMaxDistance <= 0 then
		return false
	end

	local toAnchor = active.anchorPosition - rootPart.Position
	if toAnchor.Magnitude > active.releaseWallKickMaxDistance or toAnchor.Magnitude < 0.05 then
		return false
	end

	local intoWallDot = -toAnchor.Unit:Dot(normal)
	return intoWallDot >= active.releaseWallKickIntoWallDot
end

local function shouldApplyReleaseBoost(reason: string?): boolean
	return reason == "Arrived"
		or reason == "JumpCancel"
		or reason == "ManualCancel"
		or reason == "ClientCancel"
		or reason == "Timeout"
end

local function applyReleaseBoost(active: ActivePlayerPull, reason: string?)
	if reason == "Restart" or not shouldApplyReleaseBoost(reason) then
		return
	end

	local rootPart = active.rootPart
	local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not (rootPart.Parent and humanoid and humanoid.Health > 0) then
		return
	end

	local targetVelocity = math.max(active.releaseUpwardVelocity, 0)
	local currentVelocity = rootPart.AssemblyLinearVelocity
	local upwardDelta = math.max(targetVelocity - currentVelocity.Y, 0)
	local velocityDelta = Vector3.yAxis * upwardDelta
	local currentSpeed = currentVelocity.Magnitude

	if currentSpeed > 0.05 then
		local scaledVelocity = currentVelocity * math.max(active.releaseMomentumScale, 0)
		if scaledVelocity.Magnitude > currentSpeed then
			velocityDelta += clampMagnitude(scaledVelocity, active.releaseMaxSpeed) - currentVelocity
		elseif currentSpeed > active.releaseMaxSpeed then
			velocityDelta += currentVelocity.Unit * (active.releaseMaxSpeed - currentSpeed)
		end
	end

	local forwardDirection = active.pullTargetPosition - rootPart.Position
	if forwardDirection.Magnitude > 0.05 and active.releaseForwardVelocity > 0 then
		forwardDirection = forwardDirection.Unit
		local forwardDelta = math.max(active.releaseForwardVelocity - currentVelocity:Dot(forwardDirection), 0)
		velocityDelta += forwardDirection * forwardDelta
	end

	local normal = active.hitNormal
	if normal and shouldApplyWallKick(active, rootPart) then
		local outwardDelta = math.max(active.releaseWallKickSpeed - currentVelocity:Dot(normal), 0)
		velocityDelta += normal * outwardDelta
	end

	if velocityDelta.Magnitude > 0 then
		rootPart:ApplyImpulse(velocityDelta * rootPart.AssemblyMass)
		MovementController:RecordExternalAirControlLaunch("GrappleHook", active.airControlMinAirTime)
	end
end

local function cancelActivePull(sendCancel: boolean, reason: string?)
	local active = activePull
	activePull = nil
	setDebugAttribute("Active", false)
	setDebugAttribute("ActiveKind", "")

	if active then
		if active.connection then
			active.connection:Disconnect()
		end
		applyReleaseBoost(active, reason)
		fadeAndDestroyVisual(active.visual)
		if sendCancel then
			-- AbilityController is not globally stored in the behavior; cancellation is sent from callers.
		end
	end
	setClientStatus("Released", reason or "")
end

local function clearActiveServerSession(reason: string?)
	activeServerSessionId = nil
	activeServerSessionKind = nil
	setDebugAttribute("Active", false)
	setDebugAttribute("ActiveKind", "")
	setClientStatus("Released", reason or "")
end

local function getActiveSessionId(): number?
	return if activePull then activePull.sessionId else activeServerSessionId
end

local function sendCancel(controller, slot: string)
	controller:SendMessage(slot, AbilityConfig.MessageTypes.Cancel, {
		sessionId = getActiveSessionId(),
	})
end

local function getMoveSteerDirection(humanoid: Humanoid, pullDirection: Vector3): Vector3
	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude < 0.05 then
		return Vector3.zero
	end

	local steer = moveDirection - pullDirection * moveDirection:Dot(pullDirection)
	if steer.Magnitude < 0.05 then
		steer = flattenDirection(moveDirection)
	end
	return if steer.Magnitude > 0.05 then steer.Unit else Vector3.zero
end

local function getPullTargetPosition(anchorPosition: Vector3, hitNormal: Vector3?, definition: AbilityDefinition): Vector3
	if not hitNormal then
		return anchorPosition
	end

	local wallNormalY = getDefinitionNumber(definition, "wallAssistMaxNormalY", 0.45)
	if math.abs(hitNormal.Y) > wallNormalY then
		return anchorPosition
	end

	local standOff = math.max(getDefinitionNumber(definition, "wallAssistStandOff", 4.5), 0)
	local lift = math.max(getDefinitionNumber(definition, "wallAssistLift", 4.5), 0)
	return anchorPosition + hitNormal.Unit * standOff + Vector3.yAxis * lift
end

local function stepPlayerPull(active: ActivePlayerPull)
	local rootPart = active.rootPart
	if not rootPart.Parent then
		cancelActivePull(false, "MissingRoot")
		return
	end

	local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		cancelActivePull(false, "Dead")
		return
	end

	local now = os.clock()
	local elapsed = now - active.startedAt
	if elapsed >= active.maxDuration then
		cancelActivePull(false, "Timeout")
		return
	end

	local dt = math.clamp(now - active.lastStepAt, 1 / 240, 1 / 20)
	active.lastStepAt = now

	local offset = active.pullTargetPosition - rootPart.Position
	local distance = offset.Magnitude
	if distance <= active.arrivalDistance then
		cancelActivePull(false, "Arrived")
		return
	end
	if distance > active.maxRange * 1.35 then
		cancelActivePull(false, "TooFar")
		return
	end

	local pullDirection = offset.Unit
	local currentVelocity = rootPart.AssemblyLinearVelocity
	local radialSpeed = currentVelocity:Dot(pullDirection)
	local targetRadialSpeed = math.min(active.minPullSpeed + active.pullAcceleration * elapsed, active.maxPullSpeed)
	local nextRadialSpeed = math.min(math.max(radialSpeed, 0) + active.pullAcceleration * dt, targetRadialSpeed)

	local tangentialVelocity = currentVelocity - pullDirection * radialSpeed
	tangentialVelocity *= math.clamp(active.tangentialRetention, 0, 1)
	tangentialVelocity = clampMagnitude(tangentialVelocity, active.maxTangentialSpeed)

	local steerDirection = getMoveSteerDirection(humanoid, pullDirection)
	local steerVelocity = if steerDirection.Magnitude > 0
		then steerDirection * math.min(active.steerAcceleration * dt, active.maxSteerSpeed)
		else Vector3.zero

	local upwardAssist = Vector3.yAxis * active.upwardBias * math.clamp(distance / math.max(active.startDistance, 1), 0.25, 1)
	local desiredVelocity = pullDirection * nextRadialSpeed + tangentialVelocity + steerVelocity + upwardAssist
	rootPart.AssemblyLinearVelocity = clampMagnitude(desiredVelocity, active.maxPullSpeed + active.maxTangentialSpeed)
end

local function startPlayerPull(sessionId: number, anchorPosition: Vector3, payload, definition: AbilityDefinition, visual: GrappleVisual?)
	cancelActivePull(false, "Restart")

	local rootPart = getCharacterRoot(LocalPlayer)
	if not rootPart then
		setClientStatus("Rejected", "NoCharacter")
		fadeAndDestroyVisual(visual)
		return
	end

	if visual and visual.anchorPart then
		local anchorInstance = visual.anchorInstance or visual.anchorPart
		pivotTo(anchorInstance, getHookCFrame(anchorPosition, anchorPosition - rootPart.Position))
	end

	local pullTargetPosition = getPullTargetPosition(anchorPosition, getPayloadNormal(payload), definition)
	local startDistance = math.max((pullTargetPosition - rootPart.Position).Magnitude, 1)
	local configuredPullSpeed = math.max(tonumber(payload.playerPullSpeed) or getDefinitionNumber(definition, "playerPullSpeed", 120), 1)
	local pullDirection = pullTargetPosition - rootPart.Position

	local active: ActivePlayerPull = {
		sessionId = sessionId,
		rootPart = rootPart,
		anchorPosition = anchorPosition,
		pullTargetPosition = pullTargetPosition,
		hitNormal = getPayloadNormal(payload),
		startedAt = os.clock(),
		lastStepAt = os.clock(),
		startDistance = startDistance,
		maxDuration = math.max(tonumber(payload.playerMaxPullTime) or getDefinitionNumber(definition, "playerMaxPullTime", 1.5), 0.05),
		arrivalDistance = math.max(tonumber(payload.playerArrivalDistance) or getDefinitionNumber(definition, "playerArrivalDistance", 7), 1),
		minPullSpeed = math.max(getDefinitionNumber(definition, "playerMinPullSpeed", 55), 1),
		maxPullSpeed = math.max(getDefinitionNumber(definition, "playerMaxPullSpeed", configuredPullSpeed), 1),
		pullAcceleration = math.max(getDefinitionNumber(definition, "playerPullAcceleration", 190), 1),
		upwardBias = tonumber(payload.playerUpwardBias) or getDefinitionNumber(definition, "playerUpwardBias", 22),
		steerAcceleration = math.max(getDefinitionNumber(definition, "playerSteerAcceleration", 75), 0),
		maxSteerSpeed = math.max(getDefinitionNumber(definition, "playerMaxSteerSpeed", 26), 0),
		tangentialRetention = getDefinitionNumber(definition, "playerTangentialRetention", 0.88),
		maxTangentialSpeed = math.max(getDefinitionNumber(definition, "playerMaxTangentialSpeed", 62), 0),
		releaseUpwardVelocity = getDefinitionNumber(definition, "releaseUpwardVelocity", 48),
		releaseForwardVelocity = getDefinitionNumber(definition, "releaseForwardVelocity", 70),
		releaseMomentumScale = getDefinitionNumber(definition, "releaseMomentumScale", 0.82),
		releaseMaxSpeed = getDefinitionNumber(definition, "releaseMaxSpeed", 105),
		releaseWallKickSpeed = getDefinitionNumber(definition, "releaseWallKickSpeed", 26),
		releaseWallKickMaxDistance = getDefinitionNumber(definition, "releaseWallKickMaxDistance", 10),
		releaseWallKickIntoWallDot = getDefinitionNumber(definition, "releaseWallKickIntoWallDot", 0.35),
		airControlMinAirTime = getDefinitionNumber(definition, "airControlMinAirTime", 0.2),
		maxRange = math.max(tonumber(payload.maxRange) or getDefinitionNumber(definition, "maxRange", 350), 1),
		connection = nil,
		visual = visual,
	}

	if pullDirection.Magnitude > 0.05 then
		local direction = pullDirection.Unit
		local currentVelocity = rootPart.AssemblyLinearVelocity
		local initialBoost = math.max(getDefinitionNumber(definition, "playerInitialPullBoost", 24), 0)
		local radialDelta = math.max(initialBoost - currentVelocity:Dot(direction), 0)
		if radialDelta > 0 then
			rootPart:ApplyImpulse(direction * radialDelta * rootPart.AssemblyMass)
		end
	end

	active.connection = RunService.Heartbeat:Connect(function()
		stepPlayerPull(active)
	end)
	activePull = active

	setDebugAttribute("Active", true)
	setDebugAttribute("AnchorPosition", anchorPosition)
	setClientStatus("ActiveWall", "")
	MovementController:RecordExternalAirControlLaunch("GrappleHook", getDefinitionNumber(definition, "airControlMinAirTime", 0.2))
	if type(CameraController.PlayGrapplePullPunch) == "function" then
		CameraController:PlayGrapplePullPunch()
	elseif type(CameraController.PlayAirBurstPunch) == "function" then
		CameraController:PlayAirBurstPunch()
	end
end

local function ensureJumpCancel(controller, slot: string)
	if jumpConnection then
		return
	end
	jumpConnection = UserInputService.JumpRequest:Connect(function()
		if activePull or activeServerSessionId then
			sendCancel(controller, slot)
			if activePull then
				cancelActivePull(false, "JumpCancel")
			else
				clearActiveServerSession("JumpCancel")
			end
		end
	end)
end

function GrappleHook.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	local inputState = context.inputState or Enum.UserInputState.Begin
	if inputState ~= Enum.UserInputState.Begin then
		return true
	end

	if activePull then
		sendCancel(context.controller, context.slot)
		cancelActivePull(false, "ManualCancel")
		return true
	end
	if activeServerSessionId then
		sendCancel(context.controller, context.slot)
		clearActiveServerSession("ManualCancel")
		return true
	end

	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		setClientStatus("Rejected", "Cooldown")
		return true
	end

	local mouseOrigin, mouseDirection = getMouseRay()
	if not mouseOrigin or not mouseDirection then
		setClientStatus("Rejected", "NoMouseRay")
		return true
	end

	local rootPart = getCharacterRoot(context.localPlayer)
	if not rootPart then
		setClientStatus("Rejected", "NoCharacter")
		return true
	end

	nextSequence += 1
	local sequence = nextSequence
	local predictionEnd = predictEndpoint(mouseOrigin, mouseDirection, context.definition)
	local fireOrigin = rootPart.Position + Vector3.yAxis * 1.6
	local fireDirection = predictionEnd - fireOrigin
	if fireDirection.Magnitude < 0.05 then
		setClientStatus("Rejected", "BadDirection")
		return true
	end
	fireDirection = fireDirection.Unit
	local visual = createVisual(context.localPlayer, rootPart.Position, predictionEnd, context.definition, nil)
	if visual then
		trackPendingVisual(sequence, visual, context.definition)
	end

	playOptionalSound(SOUND_FIRE, rootPart)
	ensureJumpCancel(context.controller, context.slot)
	setClientStatus("Sent", "")
	context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, {
		sequence = sequence,
		origin = fireOrigin,
		direction = fireDirection,
		clientTimestamp = workspace:GetServerTimeNow(),
	})
	return true
end

function GrappleHook.OnEffect(context: ClientEffectContext)
	local payload = context.payload.payload
	if typeof(payload) ~= "table" then
		return
	end

	local definition = AbilityConfig.GetDefinition("GrappleHook")
	if not definition then
		return
	end

	if context.effectName == "GrappleHookCancel" then
		local sessionId = if typeof(payload.sessionId) == "number" then payload.sessionId else 0
		if activePull and activePull.sessionId == sessionId then
			cancelActivePull(false, tostring(payload.reason or "ServerCancel"))
		end
		if activeServerSessionId == sessionId then
			clearActiveServerSession(tostring(payload.reason or "ServerCancel"))
		end
		local visual = remoteVisuals[sessionId]
		remoteVisuals[sessionId] = nil
		fadeAndDestroyVisual(visual)
		if context.payload.player == context.localPlayer then
			local rootPart = getCharacterRoot(context.localPlayer)
			playOptionalSound(SOUND_RELEASE, rootPart)
		end
		return
	end

	if context.effectName == "GrappleHookMiss" or context.effectName == "GrappleHookFail" then
		local sequence = if typeof(payload.sessionId) == "number" then payload.sessionId else 0
		local visual = pendingVisuals[sequence]
		pendingVisuals[sequence] = nil
		local failColor = getDefinitionColor(definition, "failColor", Color3.fromRGB(255, 86, 86))
		tintVisual(visual, failColor, 0.75)
		if typeof(payload.anchorPosition) == "Vector3" then
			spawnImpactPulse(
				payload.anchorPosition,
				failColor,
				getDefinitionNumber(definition, "failPulseSize", 2.2),
				getDefinitionNumber(definition, "failPulseSeconds", 0.16)
			)
		end
		fadeAndDestroyVisual(visual, getDefinitionNumber(definition, "missVisualDurationSeconds", 0.16))
		playOptionalSound(SOUND_FAIL, getCharacterRoot(context.localPlayer))
		setClientStatus(context.effectName == "GrappleHookMiss" and "Miss" or "Fail", "")
		return
	end

	if context.effectName ~= "GrappleHookAttached" then
		return
	end

	local player = context.payload.player
	if not (typeof(player) == "Instance" and player:IsA("Player")) then
		return
	end

	local sessionId = if typeof(payload.sessionId) == "number" then payload.sessionId else 0
	local targetKind = if typeof(payload.targetKind) == "string" then payload.targetKind else "Wall"
	local anchorPosition = payload.anchorPosition
	if typeof(anchorPosition) ~= "Vector3" then
		return
	end

	local visual = nil :: GrappleVisual?
	if player == context.localPlayer then
		visual = pendingVisuals[sessionId]
		pendingVisuals[sessionId] = nil
	else
		local targetPlayer = payload.targetPlayer
		local targetRoot = if typeof(targetPlayer) == "Instance" and targetPlayer:IsA("Player")
			then getCharacterRoot(targetPlayer)
			else nil
		local targetInstance = payload.targetInstance
		local bombRoot = if typeof(targetInstance) == "Instance" then getRootPartFromInstance(targetInstance) else nil
		local shooterRoot = getCharacterRoot(player)
		if shooterRoot then
			local attachmentParent = if targetKind == "Enemy" then targetRoot elseif targetKind == "Bomb" then bombRoot else nil
			visual = createVisual(player, shooterRoot.Position, anchorPosition, definition, attachmentParent)
			applyConfirmedTravelTime(visual, payload)
			if targetKind == "Bomb" then
				tintVisual(visual, getDefinitionColor(definition, "bombBeamColor", Color3.fromRGB(255, 211, 92)), 1.15)
			elseif targetKind == "Enemy" then
				tintVisual(visual, getDefinitionColor(definition, "enemyBeamColor", Color3.fromRGB(255, 95, 95)), 1.05)
			end
			finishTravelAndTaut(visual, anchorPosition, definition, nil)
			remoteVisuals[sessionId] = visual
		end
	end

	if targetKind == "Bomb" then
		tintVisual(visual, getDefinitionColor(definition, "bombBeamColor", Color3.fromRGB(255, 211, 92)), 1.15)
	elseif targetKind == "Enemy" then
		tintVisual(visual, getDefinitionColor(definition, "enemyBeamColor", Color3.fromRGB(255, 95, 95)), 1.05)
	else
		tintVisual(visual, getDefinitionColor(definition, "beamColor", Color3.fromRGB(103, 229, 255)), 1)
	end

	spawnImpactPulse(
		anchorPosition,
		if targetKind == "Bomb"
			then getDefinitionColor(definition, "bombBeamColor", Color3.fromRGB(255, 211, 92))
			elseif targetKind == "Enemy" then getDefinitionColor(definition, "enemyBeamColor", Color3.fromRGB(255, 95, 95))
			else getDefinitionColor(definition, "latchColor", Color3.fromRGB(133, 245, 255)),
		getDefinitionNumber(definition, "latchPulseSize", 2.8),
		getDefinitionNumber(definition, "latchPulseSeconds", 0.2)
	)

	if player == context.localPlayer then
		playVisualSounds(visual)
		playOptionalSound(if targetKind == "Bomb" then SOUND_BOMB else SOUND_LATCH, getCharacterRoot(context.localPlayer))
	else
		playVisualSounds(visual)
	end

	if player == context.localPlayer and targetKind == "Wall" then
		applyConfirmedTravelTime(visual, payload)
		activeServerSessionId = sessionId
		activeServerSessionKind = "Wall"
		setDebugAttribute("ActiveKind", "Wall")
		finishTravelAndTaut(visual, anchorPosition, definition, nil)

		local remainingDelay = getRemainingServerPullDelay(payload)
		local delaySeconds = if typeof(remainingDelay) == "number" then math.max(remainingDelay, 0) else 0
		task.delay(delaySeconds, function()
			if activeServerSessionId == sessionId then
				activeServerSessionId = nil
				activeServerSessionKind = nil
				startPlayerPull(sessionId, anchorPosition, payload, definition, visual)
			end
		end)
	elseif player == context.localPlayer then
		applyConfirmedTravelTime(visual, payload)
		activeServerSessionId = sessionId
		activeServerSessionKind = targetKind
		setDebugAttribute("Active", true)
		setDebugAttribute("ActiveKind", activeServerSessionKind)
		setClientStatus(if targetKind == "Bomb" then "TauteningBomb" else "TauteningEnemy", "")
		finishTravelAndTaut(visual, anchorPosition, definition, function()
			if activeServerSessionId == sessionId then
				setClientStatus(if targetKind == "Bomb" then "ActiveBomb" else "ActiveEnemy", "")
				fadeAndDestroyVisual(visual, getDefinitionNumber(definition, "remoteVisualDurationSeconds", 0.45))
			end
		end)
	elseif targetKind ~= "Enemy" then
		task.delay(getDefinitionNumber(definition, "remoteVisualDurationSeconds", 0.45), function()
			if remoteVisuals[sessionId] == visual then
				remoteVisuals[sessionId] = nil
			end
			fadeAndDestroyVisual(visual)
		end)
	end
end

return GrappleHook
