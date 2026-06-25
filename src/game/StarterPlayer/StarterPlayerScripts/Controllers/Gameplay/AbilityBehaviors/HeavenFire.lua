local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local OverheadPlacementTargeting = require(ReplicatedStorage.Shared.Common.OverheadPlacementTargeting)
local PlayerSettings = require(ReplicatedStorage.Shared.Common.PlayerSettings)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)
local ExplosionVisibility = require(ReplicatedStorage.Shared.Effects.ExplosionVisibility)
local ScreenEffects = require(ReplicatedStorage.Shared.UI.ScreenEffects)
local VoxelDebris = require(ReplicatedStorage.Packages.VoxManager.Voxelizer.Debris)
local RoundController = require(script.Parent.Parent:WaitForChild("RoundController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

local HeavenFire = {} :: AbilityTypes.ClientBehavior

local LocalPlayer = Players.LocalPlayer
local ABILITY_ID = "HeavenFire"
local RENDER_STEP_NAME = "BombBattlesHeavenFireTargeting"
local ACTION_NAME = "BombBattlesHeavenFireTargetingInput"
local PREVIEW_FOLDER_NAME = "HeavenFirePreview"
local VFX_FOLDER_NAME = "HeavenFireVFX"
local DEBRIS_FOLDER_NAME = "VoxelDebris"
local warned = {}

local targeting = OverheadPlacementTargeting.new({
	abilityId = ABILITY_ID,
	renderStepName = RENDER_STEP_NAME,
	actionName = ACTION_NAME,
	previewFolderName = PREVIEW_FOLDER_NAME,
	uiName = "HeavenFireTargetingGui",
	markerPrefix = "HeavenFire",
	radiusKey = "impactExplosionRadius",
	radiusFallback = 32,
	cameraTweenSeconds = 0.4,
	focusResponsiveness = 14,
	targetRayDistance = 10000,
	targetRayMode = "CameraDown",
	renderPriority = Enum.RenderPriority.Camera.Value + 6,
	actionPriority = Enum.ContextActionPriority.High.Value + 80,
	getRoundState = function()
		return RoundController:Get("state")
	end,
})

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getPayloadNumber(payload: any, key: string, fallback: number): number
	local value = if typeof(payload) == "table" then payload[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function warnOnce(key: string, message: string)
	if warned[key] then
		return
	end

	warned[key] = true
	warn(message)
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

local function getTemplate(definition: AbilityDefinition?): Instance?
	local path = definition and definition.assetPath
	if typeof(path) ~= "table" then
		warnOnce("missingAssetPath", "[HeavenFire] Ability definition is missing assetPath")
		return nil
	end

	local template = getByPath(ReplicatedStorage, path)
	if template and template:IsA("Model") then
		return template
	end
	warnOnce("missingTemplate", "[HeavenFire] Missing ReplicatedStorage.Assets.Abilities.HeavenFire.HeavenFire")
	return nil
end

local function getCameraTemplate(definition: AbilityDefinition?): BasePart?
	local path = definition and definition.cameraAssetPath
	if typeof(path) ~= "table" then
		warnOnce("missingCameraAssetPath", "[HeavenFire] Ability definition is missing cameraAssetPath")
		return nil
	end

	local template = getByPath(ReplicatedStorage, path)
	if template and template:IsA("BasePart") then
		return template
	end
	warnOnce("missingCameraTemplate", "[HeavenFire] Missing ReplicatedStorage.Assets.Abilities.HeavenFire.Camera")
	return nil
end

local function getVfxFolder(): Folder
	local existing = workspace:FindFirstChild(VFX_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = VFX_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function prepareVisualInstance(instance: Instance)
	if instance:IsA("BasePart") then
		instance.Anchored = true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = false
		instance.AssemblyLinearVelocity = Vector3.zero
		instance.AssemblyAngularVelocity = Vector3.zero
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function getPivot(instance: Instance): CFrame
	if instance:IsA("Model") then
		return instance:GetPivot()
	end
	return (instance :: BasePart).CFrame
end

local function withPosition(cframe: CFrame, position: Vector3): CFrame
	return CFrame.new(position) * cframe.Rotation
end

local function setCFrameAttributePosition(instance: Instance, attributeName: string, position: Vector3): boolean
	local value = instance:GetAttribute(attributeName)
	if typeof(value) ~= "CFrame" then
		return false
	end

	instance:SetAttribute(attributeName, withPosition(value, position))
	return true
end

local function cleanupVisualAfterDelay(clone: Instance, cleanupSeconds: number)
	task.delay(math.max(cleanupSeconds, 0), function()
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

local function playCameraVfx(definition: AbilityDefinition?)
	local template = getCameraTemplate(definition)
	local camera = workspace.CurrentCamera
	if not (template and camera) then
		if template and not camera then
			warnOnce("missingCamera", "[HeavenFire] Workspace.CurrentCamera is missing for camera VFX")
		end
		return
	end

	local cleanupSeconds = math.max(getDefinitionNumber(definition, "cameraVfxDurationSeconds", 3), 0.1)
	local clone = template:Clone()
	clone.Name = "HeavenFireCameraVFX"
	prepareVisualInstance(clone)
	clone.CFrame = camera.CFrame
	clone.Parent = getVfxFolder()

	if not EmitService.EmitWithResult(clone, "[HeavenFire]", 10) then
		warnOnce("cameraEmitFailed", "[HeavenFire] EmitModule did not emit camera VFX")
	end

	local renderConnection: RBXScriptConnection? = nil
	renderConnection = RunService.RenderStepped:Connect(function()
		local currentCamera = workspace.CurrentCamera
		if clone.Parent and currentCamera then
			clone.CFrame = currentCamera.CFrame
		elseif renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
		end
	end)

	task.delay(cleanupSeconds, function()
		if renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
		end
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

local function positionHeavenFireClone(clone: Model, position: Vector3): boolean
	local top = clone:FindFirstChild("Top")
	local explosion = clone:FindFirstChild("explosion")
	local beamPart = clone:FindFirstChild("Part")
	if not (top and explosion and beamPart) then
		warnOnce("missingTemplateParts", "[HeavenFire] Template must contain Top, explosion, and Part")
		return false
	end
	if
		not (top:IsA("Model") or top:IsA("BasePart"))
		or not (explosion:IsA("Model") or explosion:IsA("BasePart"))
		or not beamPart:IsA("BasePart")
	then
		warnOnce("invalidTemplateParts", "[HeavenFire] Top and explosion must be Model or BasePart instances, and Part must be a BasePart")
		return false
	end

	local authoredExplosionPivot = getPivot(explosion)
	local authoredClonePivot = clone:GetPivot()
	local targetExplosionPivot = withPosition(authoredExplosionPivot, position)
	local targetClonePivot = targetExplosionPivot * authoredExplosionPivot:ToObjectSpace(authoredClonePivot)

	clone:PivotTo(targetClonePivot)

	local cframeTween = beamPart:FindFirstChild("CFrame")
	if not cframeTween then
		warnOnce("missingBeamCFrameTween", "[HeavenFire] Part is missing authored CFrame RayValue")
		return false
	end
	if not cframeTween:IsA("RayValue") then
		warnOnce("invalidBeamCFrameTween", "[HeavenFire] Part.CFrame must be a RayValue")
		return false
	end
	if not setCFrameAttributePosition(cframeTween, "_END_VALUE", targetExplosionPivot.Position) then
		warnOnce("missingBeamEndValue", "[HeavenFire] Part.CFrame is missing authored _END_VALUE CFrame attribute")
		return false
	end

	return true
end

local function playHeavenFireVfx(payload: any)
	local position = if typeof(payload) == "table" then payload.position else nil
	if typeof(position) ~= "Vector3" then
		warnOnce("invalidImpactPosition", "[HeavenFire] HeavenFireImpact payload is missing Vector3 position")
		return
	end

	local definition = AbilityConfig.GetDefinition(ABILITY_ID)
	local template = getTemplate(definition)
	if not template then
		return
	end

	local clone = template:Clone()
	clone.Name = "HeavenFireVFX"
	prepareVisualInstance(clone)
	if not positionHeavenFireClone(clone, position) then
		clone:Destroy()
		return
	end
	clone.Parent = getVfxFolder()

	if EmitService.EmitWithResult(clone, "[HeavenFire]", 10) then
		playCameraVfx(definition)
	else
		warnOnce("modelEmitFailed", "[HeavenFire] EmitModule did not emit the authored HeavenFire model")
	end
	cleanupVisualAfterDelay(clone, getDefinitionNumber(definition, "strikeVisualCleanupSeconds", 5))
end

local function createLocalTelegraph(payload: any)
	if typeof(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local radius = if typeof(payload.radius) == "number" then math.max(payload.radius, 1) else 22
	local lifetime = if typeof(payload.strikeDelay) == "number" then math.max(payload.strikeDelay, 0.2) else 1.35
	local folder = workspace:FindFirstChild(PREVIEW_FOLDER_NAME)
	if not (folder and folder:IsA("Folder")) then
		folder = Instance.new("Folder")
		folder.Name = PREVIEW_FOLDER_NAME
		folder.Parent = workspace
	end

	local ring = Instance.new("Part")
	ring.Name = "HeavenFireTelegraph"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanTouch = false
	ring.CanQuery = false
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.05, radius * 2, radius * 2)
	ring.CFrame = CFrame.new(payload.position + Vector3.yAxis * 0.12) * CFrame.Angles(0, 0, math.rad(90))
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 130, 55)
	ring.Transparency = 0.58
	ring.Parent = folder

	local startDiameter = radius * 2
	local endDiameter = math.max(radius * 0.45, 1)
	local shrinkTween = TweenService:Create(
		ring,
		TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Size = Vector3.new(0.05, endDiameter, endDiameter) }
	)
	shrinkTween:Play()

	local finalPulseSeconds = math.clamp(getDefinitionNumber(AbilityConfig.GetDefinition(ABILITY_ID), "warningFinalPulseSeconds", 0.22), 0.05, lifetime)
	local startedAt = os.clock()
	task.spawn(function()
		while ring.Parent do
			local elapsed = os.clock() - startedAt
			if elapsed >= lifetime then
				break
			end
			local alpha = math.clamp(elapsed / lifetime, 0, 1)
			local pulse = (math.sin(elapsed * math.pi * 7) + 1) * 0.5
			ring.Transparency = math.clamp(0.62 - 0.28 * alpha - 0.1 * pulse, 0.18, 0.72)
			ring.Color = Color3.fromRGB(255, math.floor(118 + 98 * alpha + 26 * pulse), 50)
			task.wait(1 / 20)
		end
	end)

	task.delay(math.max(lifetime - finalPulseSeconds, 0), function()
		if not ring.Parent then
			return
		end
		local finalDiameter = math.max(startDiameter * 1.08, ring.Size.Y)
		TweenService:Create(
			ring,
			TweenInfo.new(finalPulseSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				Size = Vector3.new(0.05, finalDiameter, finalDiameter),
				Transparency = 0.16,
				Color = Color3.fromRGB(255, 236, 145),
			}
		):Play()
	end)

	task.delay(lifetime, function()
		if ring.Parent then
			ring:Destroy()
		end
	end)
end

local function getRootPart(): BasePart?
	local character = LocalPlayer.Character
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

local function smoothstep(value: number): number
	local x = math.clamp(value, 0, 1)
	return x * x * (3 - 2 * x)
end

local function playProximityBlackFlash(payload: any, definition: AbilityDefinition?)
	local position = if typeof(payload) == "table" then payload.position else nil
	if typeof(position) ~= "Vector3" then
		return
	end

	local rootPart = getRootPart()
	if not rootPart then
		return
	end

	local radius = math.max(getPayloadNumber(payload, "blackFlashRadius", getDefinitionNumber(definition, "blackFlashRadius", 260)), 0)
	if radius <= 0 then
		return
	end

	local rootPosition = rootPart.Position
	local distance = Vector3.new(rootPosition.X - position.X, 0, rootPosition.Z - position.Z).Magnitude
	if distance > radius then
		return
	end

	local strength = smoothstep(1 - distance / radius)
	if strength <= 0 then
		return
	end

	local closestTransparency =
		math.clamp(getPayloadNumber(payload, "blackFlashClosestTransparency", getDefinitionNumber(definition, "blackFlashClosestTransparency", 0.3)), 0, 1)
	local initialTransparency = 1 - ((1 - closestTransparency) * strength)
	if initialTransparency >= 1 then
		return
	end

	ScreenEffects.FlashBlack(getPayloadNumber(payload, "blackFlashDuration", getDefinitionNumber(definition, "blackFlashDuration", 3)), initialTransparency)
end

local function playHitBlackFlash(payload: any)
	if typeof(payload) ~= "table" or payload.abilityId ~= ABILITY_ID then
		return
	end

	local definition = AbilityConfig.GetDefinition(ABILITY_ID)
	local duration = if typeof(payload.durationSeconds) == "number"
		then payload.durationSeconds
		else getDefinitionNumber(definition, "blackFlashHitDuration", 3)
	local initialTransparency = if typeof(payload.initialTransparency) == "number"
		then payload.initialTransparency
		else getDefinitionNumber(definition, "blackFlashClosestTransparency", 0.3)
	ScreenEffects.FlashBlack(duration, initialTransparency)
end

local function playTerrainDebris(payload: any, definition: AbilityDefinition?)
	if typeof(payload) ~= "table" or typeof(payload.debrisPayloads) ~= "table" then
		return
	end
	if PlayerSettings:Get("explosionDebrisEnabled") ~= true then
		return
	end

	local position = if typeof(payload.position) == "Vector3" then payload.position else ExplosionVisibility.GetDebrisPosition(payload.debrisPayloads)
	if not position then
		return
	end

	local decision = ExplosionVisibility.Choose({
		position = position,
		terrainRadius = if typeof(payload.terrainRadius) == "number"
			then payload.terrainRadius
			else getDefinitionNumber(definition, "impactExplosionRadius", 32),
	}, {
		localPlayer = LocalPlayer,
		explosionFolderName = VFX_FOLDER_NAME,
		debrisFolderName = DEBRIS_FOLDER_NAME,
		defaultTerrainRadius = getDefinitionNumber(definition, "impactExplosionRadius", 32),
		defaultOuterRadius = getDefinitionNumber(definition, "impactExplosionRadius", 32),
	})
	if decision.quality == ExplosionVisibility.Quality.Skip or decision.quality == ExplosionVisibility.Quality.SoundOnly then
		return
	end

	local remainingParts = math.max(getDefinitionNumber(definition, "impactDebrisMaxParts", 48), 0)
	for _, debrisPayload in ipairs(payload.debrisPayloads) do
		if remainingParts <= 0 then
			break
		end
		local spawned = VoxelDebris.spawnPayload(debrisPayload, {
			maxParts = remainingParts,
		})
		if typeof(spawned) == "number" and spawned > 0 then
			remainingParts -= spawned
		end
	end
end

local function playExplosionResolved(payload: any)
	if typeof(payload) ~= "table" or payload.abilityId ~= ABILITY_ID then
		return
	end

	local definition = AbilityConfig.GetDefinition(ABILITY_ID)
	playProximityBlackFlash(payload, definition)
	playTerrainDebris(payload, definition)
end

function HeavenFire.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	return targeting:OnActivateRequested(context)
end

function HeavenFire.OnEffect(context: ClientEffectContext)
	local payload = context.payload
	if context.effectName == "HeavenFireBeginTargeting" then
		targeting:Begin(context)
	elseif typeof(payload) == "table" and context.effectName == "HeavenFireRejected" and payload.abilityId == ABILITY_ID then
		if typeof(payload.sessionId) ~= "number" or payload.sessionId == targeting:GetSessionId() then
			targeting:Cancel(false)
		end
	elseif typeof(payload) == "table" and context.effectName == "HeavenFireCancelled" and payload.abilityId == ABILITY_ID then
		if typeof(payload.sessionId) ~= "number" or payload.sessionId == targeting:GetSessionId() then
			targeting:Cancel(false)
		end
	elseif typeof(payload) == "table" and context.effectName == "HeavenFireTelegraph" and payload.abilityId == ABILITY_ID then
		createLocalTelegraph(payload)
	elseif typeof(payload) == "table" and context.effectName == "HeavenFireImpact" and payload.abilityId == ABILITY_ID then
		playHeavenFireVfx(payload)
	elseif typeof(payload) == "table" and context.effectName == "HeavenFireExplosionResolved" and payload.abilityId == ABILITY_ID then
		playExplosionResolved(payload)
	elseif context.effectName == "HeavenFireHitFlash" then
		playHitBlackFlash(payload)
	end
end

return HeavenFire
