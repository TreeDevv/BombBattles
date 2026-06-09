local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local CameraController = require(script.Parent.Parent:WaitForChild("CameraController"))
local MovementController = require(script.Parent.Parent:WaitForChild("MovementController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

local AirBurst = {} :: AbilityTypes.ClientBehavior

local LocalPlayer = Players.LocalPlayer
local VISUAL_FOLDER_NAME = "AirBurstVisuals"
local LOCAL_VISUAL_SUPPRESS_SECONDS = 2
local JUMP_ANIMATION_KIND = "DoubleJump"
local predictedCooldownEndsAt = 0
local lastLocalVisualAt = -math.huge

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

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

local function playBurstVisual(player: Player, definition: AbilityDefinition?)
	local rootPart = getRootPart(player)
	if not rootPart then
		return
	end

	local duration = math.max(getDefinitionNumber(definition, "visualDurationSeconds", 0.28), 0.05)
	local startRadius = math.max(getDefinitionNumber(definition, "visualStartRadius", 1.8), 0.1)
	local endRadius = math.max(getDefinitionNumber(definition, "visualEndRadius", 7), startRadius)
	local thickness = math.max(getDefinitionNumber(definition, "visualThickness", 0.12), 0.02)
	local color = getDefinitionColor(definition, "visualColor", Color3.fromRGB(132, 221, 255))

	local ring = Instance.new("Part")
	ring.Name = "AirBurstRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.32
	ring.Size = Vector3.new(startRadius * 2, thickness, startRadius * 2)
	ring.CFrame = CFrame.new(rootPart.Position - Vector3.yAxis * 2.3)
	ring.Parent = getVisualFolder()

	local tween = TweenService:Create(ring, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(endRadius * 2, thickness, endRadius * 2),
		Transparency = 1,
	})
	tween:Play()
	task.delay(duration, function()
		if ring.Parent then
			ring:Destroy()
		end
	end)
end

local function applyVerticalRescue(definition: AbilityDefinition)
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not (character and humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart")) then
		return false
	end

	local targetVelocity = math.max(getDefinitionNumber(definition, "verticalVelocity", 80), 0)
	local currentVelocity = rootPart.AssemblyLinearVelocity
	local upwardDelta = math.max(targetVelocity - currentVelocity.Y, 0)
	if upwardDelta > 0 then
		rootPart:ApplyImpulse(Vector3.yAxis * upwardDelta * rootPart.AssemblyMass)
	end

	humanoid.Jump = true
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)

	local source = if typeof(definition.airControlSource) == "string" then definition.airControlSource else "AirBurst"
	local minAirTime = getDefinitionNumber(definition, "airControlMinAirTime", 0.24)
	MovementController:RecordExternalAirControlLaunch(source, minAirTime)
	MovementController:PublishExternalJump(JUMP_ANIMATION_KIND)
	return true
end

function AirBurst.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	local now = workspace:GetServerTimeNow()
	if context.controller:GetCooldownRemaining(context.slot) > 0 or predictedCooldownEndsAt > now then
		return true
	end

	if not context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, nil) then
		return true
	end

	if not applyVerticalRescue(context.definition) then
		return true
	end

	predictedCooldownEndsAt = now + math.max(getDefinitionNumber(context.definition, "cooldownSeconds", 0), 0)
	lastLocalVisualAt = os.clock()
	playBurstVisual(context.localPlayer, context.definition)
	CameraController:PlayAirBurstPunch()
	return true
end

function AirBurst.OnEffect(context: ClientEffectContext)
	if context.effectName ~= "Activated" or context.payload.abilityId ~= "AirBurst" then
		return
	end

	local player = context.payload.player
	if not (typeof(player) == "Instance" and player:IsA("Player")) then
		return
	end

	if player == context.localPlayer and os.clock() - lastLocalVisualAt <= LOCAL_VISUAL_SUPPRESS_SECONDS then
		return
	end

	playBurstVisual(player, AbilityConfig.GetDefinition("AirBurst"))
end

return AirBurst
