local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
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
	beam: Beam?,
	spring: SpringConstraint?,
	tween: Tween?,
	tweens: { Tween },
	followConnection: RBXScriptConnection?,
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
	startedAt: number,
	maxDuration: number,
	arrivalDistance: number,
	pullSpeed: number,
	upwardBias: number,
	maxRange: number,
	connection: RBXScriptConnection?,
	visual: GrappleVisual?,
}

local GrappleHook = {} :: AbilityTypes.ClientBehavior
GrappleHook.HandlesInputState = true

local LocalPlayer = Players.LocalPlayer
local DEBUG_GRAPPLE = false
local VISUAL_FOLDER_NAME = "GrappleHookVisuals"

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
	if visual.anchorPart and visual.anchorPart.Parent then
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

	if targetAttachmentParent then
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
		beam = beam,
		spring = spring,
		tween = nil,
		tweens = {},
		followConnection = nil,
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
			if targetAttachmentParent.Parent and anchorPart.Parent then
				anchorPart.CFrame = targetAttachmentParent.CFrame
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
		local tween = TweenService:Create(anchorPart, TweenInfo.new(travelTime, Enum.EasingStyle.Linear), {
			CFrame = CFrame.new(endPosition),
		})
		visual.tween = tween
		tween:Play()
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
	if visual.anchorPart and visual.anchorPart.Parent then
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

	local elapsed = os.clock() - visual.travelStartedAt
	local remainingTravel = math.max(visual.travelDuration - elapsed, 0)
	if remainingTravel <= 0.01 then
		anchorPart.CFrame = CFrame.new(anchorPosition)
		tauten()
		return
	end

	local tween = TweenService:Create(anchorPart, TweenInfo.new(remainingTravel, Enum.EasingStyle.Linear), {
		CFrame = CFrame.new(anchorPosition),
	})
	visual.tween = tween
	tween.Completed:Connect(function(playbackState)
		if playbackState == Enum.PlaybackState.Completed and not visual.destroyed then
			tauten()
		end
	end)
	tween:Play()
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

local function cancelActivePull(sendCancel: boolean, reason: string?)
	local active = activePull
	activePull = nil
	setDebugAttribute("Active", false)
	setDebugAttribute("ActiveKind", "")

	if active then
		if active.connection then
			active.connection:Disconnect()
		end
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

	local elapsed = os.clock() - active.startedAt
	if elapsed >= active.maxDuration then
		cancelActivePull(false, "Timeout")
		return
	end

	local offset = active.anchorPosition - rootPart.Position
	local distance = offset.Magnitude
	if distance <= active.arrivalDistance then
		cancelActivePull(false, "Arrived")
		return
	end
	if distance > active.maxRange * 1.35 then
		cancelActivePull(false, "TooFar")
		return
	end

	rootPart.AssemblyLinearVelocity = offset.Unit * active.pullSpeed + Vector3.yAxis * active.upwardBias
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
		visual.anchorPart.CFrame = CFrame.new(anchorPosition)
	end

	local active: ActivePlayerPull = {
		sessionId = sessionId,
		rootPart = rootPart,
		anchorPosition = anchorPosition,
		startedAt = os.clock(),
		maxDuration = math.max(tonumber(payload.playerMaxPullTime) or getDefinitionNumber(definition, "playerMaxPullTime", 1.5), 0.05),
		arrivalDistance = math.max(tonumber(payload.playerArrivalDistance) or getDefinitionNumber(definition, "playerArrivalDistance", 7), 1),
		pullSpeed = math.max(tonumber(payload.playerPullSpeed) or getDefinitionNumber(definition, "playerPullSpeed", 120), 1),
		upwardBias = tonumber(payload.playerUpwardBias) or getDefinitionNumber(definition, "playerUpwardBias", 22),
		maxRange = math.max(tonumber(payload.maxRange) or getDefinitionNumber(definition, "maxRange", 350), 1),
		connection = nil,
		visual = visual,
	}

	active.connection = RunService.Heartbeat:Connect(function()
		stepPlayerPull(active)
	end)
	activePull = active

	setDebugAttribute("Active", true)
	setDebugAttribute("AnchorPosition", anchorPosition)
	setClientStatus("ActiveWall", "")
	MovementController:RecordExternalAirControlLaunch("GrappleHook", getDefinitionNumber(definition, "airControlMinAirTime", 0.2))
	if type(CameraController.PlayAirBurstPunch) == "function" then
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
		pendingVisuals[sequence] = visual
	end

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
		return
	end

	if context.effectName == "GrappleHookMiss" or context.effectName == "GrappleHookFail" then
		local sequence = if typeof(payload.sessionId) == "number" then payload.sessionId else 0
		local visual = pendingVisuals[sequence]
		pendingVisuals[sequence] = nil
		fadeAndDestroyVisual(visual, getDefinitionNumber(definition, "missVisualDurationSeconds", 0.16))
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
			finishTravelAndTaut(visual, anchorPosition, definition, nil)
			remoteVisuals[sessionId] = visual
		end
	end

	if player == context.localPlayer and targetKind == "Wall" then
		applyConfirmedTravelTime(visual, payload)
		activeServerSessionId = sessionId
		activeServerSessionKind = "Wall"
		setDebugAttribute("ActiveKind", "Wall")
		finishTravelAndTaut(visual, anchorPosition, definition, function()
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
