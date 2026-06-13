local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local SoundUtil = require(ReplicatedStorage.Shared.Audio.SoundUtil)
local CameraController = require(script.Parent.Parent:WaitForChild("CameraController"))
local MovementController = require(script.Parent.Parent:WaitForChild("MovementController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

local Platform = {} :: AbilityTypes.ClientBehavior

local LocalPlayer = Players.LocalPlayer
local VISUAL_FOLDER_NAME = "PlatformVisuals"
local SOUND_ACTIVATE = "PlatformActivate"
local SOUND_PLACE = "PlatformPlace"
local SOUND_LAND = "PlatformLand"
local SOUND_WARNING = "PlatformWarning"
local SOUND_DESPAWN = "PlatformDespawn"
local SOUND_FAIL = "PlatformFail"
local predictedPad: BasePart? = nil
local predictedPadSerial = 0

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
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

local function getRootPart(player: Player): BasePart?
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

local function playOptionalSound(soundName: string, parent: Instance?)
	SoundUtil.Play(soundName, parent)
end

local function destroyPredictedPad()
	if predictedPad and predictedPad.Parent then
		predictedPad:Destroy()
	end
	predictedPad = nil
	predictedPadSerial += 1
end

local function getPredictedPadCFrame(rootPart: BasePart, definition: AbilityDefinition): (CFrame, Vector3)
	local size = if typeof(definition.platformSize) == "Vector3" then definition.platformSize else Vector3.new(7.5, 0.72, 7.5)
	size = Vector3.new(math.max(size.X, 0.1), math.max(size.Y, 0.1), math.max(size.Z, 0.1))

	local velocityY = rootPart.AssemblyLinearVelocity.Y
	local fastFallSpeed = math.abs(getDefinitionNumber(definition, "fastFallSpeedThreshold", -60))
	local topOffset = if velocityY <= -fastFallSpeed
		then getDefinitionNumber(definition, "fastFallTopOffset", 2.55)
		else getDefinitionNumber(definition, "verticalOffset", 3.05)
	local topPosition = rootPart.Position - Vector3.yAxis * topOffset
	local center = topPosition - Vector3.yAxis * (size.Y * 0.5)
	local look = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		return CFrame.new(center), size
	end
	return CFrame.lookAt(center, center + look.Unit), size
end

local function createPredictedPad(definition: AbilityDefinition)
	destroyPredictedPad()

	local rootPart = getRootPart(LocalPlayer)
	if not rootPart then
		return
	end

	local cframe, size = getPredictedPadCFrame(rootPart, definition)
	local pad = Instance.new("Part")
	pad.Name = "PlatformPredictedCatchPad"
	pad.Anchored = true
	pad.CanCollide = true
	pad.CanQuery = false
	pad.CanTouch = false
	pad.CastShadow = false
	pad.Material = Enum.Material.ForceField
	pad.Color = getDefinitionColor(definition, "topColor", Color3.fromRGB(235, 252, 255))
	pad.Transparency = getDefinitionNumber(definition, "predictedPadTransparency", 0.78)
	pad.Size = size
	pad.CFrame = cframe
	pad.Parent = getVisualFolder()
	predictedPad = pad

	local serial = predictedPadSerial
	task.delay(getDefinitionNumber(definition, "predictedPadLifetimeSeconds", 0.75), function()
		if predictedPadSerial == serial and predictedPad == pad then
			destroyPredictedPad()
		end
	end)
end

local function playRing(position: Vector3, radius: number, color: Color3, duration: number, height: number?)
	local ring = Instance.new("Part")
	ring.Name = "PlatformEffectRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.3
	ring.Size = Vector3.new(0.08, math.max(height or 0.08, 0.02), 0.08)
	ring.CFrame = CFrame.new(position)
	ring.Parent = getVisualFolder()

	TweenService:Create(
		ring,
		TweenInfo.new(math.max(duration, 0.03), Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Size = Vector3.new(math.max(radius * 2, 0.1), ring.Size.Y, math.max(radius * 2, 0.1)),
			Transparency = 1,
		}
	):Play()

	task.delay(duration + 0.05, function()
		if ring.Parent then
			ring:Destroy()
		end
	end)
end

local function playPlacementVisual(payload, definition: AbilityDefinition?)
	local position = if typeof(payload.topPosition) == "Vector3"
		then payload.topPosition
		else if typeof(payload.position) == "Vector3" then payload.position else nil
	if not position then
		return
	end

	local size = if typeof(payload.size) == "Vector3" then payload.size else Vector3.new(7, 1, 7)
	local radius = math.max(size.X, size.Z) * 0.54
	local color = getDefinitionColor(definition, "topColor", Color3.fromRGB(235, 252, 255))
	playRing(position + Vector3.yAxis * 0.08, radius, color, getDefinitionNumber(definition, "placeVisualSeconds", 0.18))
end

local function playFailVisual(payload, definition: AbilityDefinition?)
	local position = if typeof(payload.position) == "Vector3" then payload.position else nil
	local rootPart = getRootPart(LocalPlayer)
	position = position or (rootPart and rootPart.Position) or Vector3.zero
	local color = getDefinitionColor(definition, "failColor", Color3.fromRGB(255, 86, 86))
	playRing(position - Vector3.yAxis * 2.8, getDefinitionNumber(definition, "failVisualRadius", 3), color, 0.18)
end

local function applyLocalStabilize(definition: AbilityDefinition)
	local rootPart = getRootPart(LocalPlayer)
	if not rootPart then
		return
	end

	local velocity = rootPart.AssemblyLinearVelocity
	local maxDownwardSpeed = math.abs(getDefinitionNumber(definition, "predictedDownwardSpeed", -4))
	local horizontalDamping = math.clamp(getDefinitionNumber(definition, "predictedHorizontalDamping", 0.58), 0, 1)
	local maxHorizontalSpeed = math.max(getDefinitionNumber(definition, "predictedMaxHorizontalSpeed", 28), 0)
	local horizontal = Vector3.new(velocity.X * horizontalDamping, 0, velocity.Z * horizontalDamping)
	if maxHorizontalSpeed > 0 and horizontal.Magnitude > maxHorizontalSpeed then
		horizontal = horizontal.Unit * maxHorizontalSpeed
	end
	rootPart.AssemblyLinearVelocity = Vector3.new(horizontal.X, math.max(velocity.Y, -maxDownwardSpeed), horizontal.Z)
	MovementController:RecordExternalAirControlLaunch("Platform", getDefinitionNumber(definition, "airControlMinAirTime", 0.12))
end

function Platform.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if context.inputState and context.inputState ~= Enum.UserInputState.Begin then
		return true
	end

	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		context.localPlayer:SetAttribute("PlatformClientStatus", "Cooldown")
		return true
	end

	if not context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, nil) then
		context.localPlayer:SetAttribute("PlatformClientStatus", "SendFailed")
		return true
	end

	context.localPlayer:SetAttribute("PlatformClientStatus", "Sent")
	context.localPlayer:SetAttribute("PlatformClientStatusTime", workspace:GetServerTimeNow())
	createPredictedPad(context.definition)
	applyLocalStabilize(context.definition)
	playOptionalSound(SOUND_ACTIVATE, getRootPart(context.localPlayer))
	if type(CameraController.PlayAbilityFOVPunch) == "function" then
		CameraController:PlayAbilityFOVPunch(0.16, 2.4)
	end
	return true
end

function Platform.OnEffect(context: ClientEffectContext)
	local payload = context.payload.payload
	if typeof(payload) ~= "table" then
		payload = {}
	end

	local definition = AbilityConfig.GetDefinition("Platform")
	if context.effectName == "PlatformPlaced" then
		destroyPredictedPad()
		playPlacementVisual(payload, definition)
		local player = context.payload.player
		if player == context.localPlayer then
			playOptionalSound(SOUND_PLACE, getRootPart(context.localPlayer))
		end
	elseif context.effectName == "PlatformFailed" then
		destroyPredictedPad()
		playFailVisual(payload, definition)
		playOptionalSound(SOUND_FAIL, getRootPart(context.localPlayer))
	elseif context.effectName == "PlatformTouched" then
		local position = if typeof(payload.position) == "Vector3" then payload.position else nil
		if position then
			playRing(
				position + Vector3.yAxis * 0.08,
				getDefinitionNumber(definition, "touchVisualRadius", 2.6),
				getDefinitionColor(definition, "supportColor", Color3.fromRGB(141, 255, 198)),
				getDefinitionNumber(definition, "touchVisualSeconds", 0.16),
				0.05
			)
		end
		if context.payload.player == context.localPlayer then
			playOptionalSound(SOUND_LAND, getRootPart(LocalPlayer))
		end
	elseif context.effectName == "PlatformWarning" then
		local position = if typeof(payload.position) == "Vector3" then payload.position else nil
		if position then
			playRing(
				position,
				getDefinitionNumber(definition, "warningVisualRadius", 4.4),
				getDefinitionColor(definition, "warningColor", Color3.fromRGB(255, 236, 117)),
				getDefinitionNumber(definition, "warningVisualSeconds", 0.22),
				0.05
			)
		end
		if context.payload.player == context.localPlayer then
			playOptionalSound(SOUND_WARNING, getRootPart(LocalPlayer))
		end
	elseif context.effectName == "PlatformDespawn" then
		local position = if typeof(payload.position) == "Vector3" then payload.position else nil
		if position then
			playRing(
				position,
				getDefinitionNumber(definition, "despawnVisualRadius", 3.5),
				getDefinitionColor(definition, "color", Color3.fromRGB(96, 222, 255)),
				getDefinitionNumber(definition, "despawnVisualSeconds", 0.2),
				0.05
			)
		end
		if context.payload.player == context.localPlayer then
			playOptionalSound(SOUND_DESPAWN, getRootPart(LocalPlayer))
		end
	end
end

return Platform
