local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local CombatMotionService = require(ServerScriptService.Services.CombatMotionService)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext

type PlatformRecord = {
	part: BasePart,
	highlight: Highlight?,
	owner: Player,
	connections: { RBXScriptConnection },
	fading: boolean,
	lastTouchEffectAt: number,
}

type Placement = {
	cframe: CFrame,
	size: Vector3,
	topPosition: Vector3,
}

local Platform = {} :: AbilityTypes.ServerBehavior

local FOLDER_NAME = "AbilityObjects"
local PLATFORM_FOLDER_NAME = "Platform"
local OWNER_ATTR = "PlatformOwnerUserId"
local STATUS_ATTR = "PlatformStatus"
local STATUS_REASON_ATTR = "PlatformStatusReason"
local STATUS_TIME_ATTR = "PlatformStatusTime"
local ACTIVE_PLATFORMS: { [Player]: PlatformRecord } = {}
local RECORD_BY_PART: { [BasePart]: PlatformRecord } = {}
local STABILIZE_SERIAL_BY_ROOT: { [BasePart]: number } = {}
local abilityService: AbilityServiceLike? = nil

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local function getNumber(definition: AbilityDefinition, key: string, fallback: number): number
	local value = definition[key]
	return if typeof(value) == "number" then value else fallback
end

local function getBoolean(definition: AbilityDefinition, key: string, fallback: boolean): boolean
	local value = definition[key]
	return if typeof(value) == "boolean" then value else fallback
end

local function getVector3(definition: AbilityDefinition, key: string, fallback: Vector3): Vector3
	local value = definition[key]
	return if typeof(value) == "Vector3" then value else fallback
end

local function getColor(definition: AbilityDefinition, key: string, fallback: Color3): Color3
	local value = definition[key]
	return if typeof(value) == "Color3" then value else fallback
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

local function setCharacterVelocity(rootPart: BasePart, velocity: Vector3, suppressSeconds: number?)
	local character = rootPart:FindFirstAncestorOfClass("Model")
	local player = character and Players:GetPlayerFromCharacter(character)
	if player then
		CombatMotionService.SendSetVelocity(player, character, velocity, {
			sourceType = "Ability",
			sourceId = "Platform",
			movementSuppressSeconds = suppressSeconds,
		})
	else
		rootPart.AssemblyLinearVelocity = velocity
	end
end

local function getActiveMap(): Instance?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getPlatformFolder(player: Player): Folder
	local parent = PracticeRangeTargeting.GetObjectParentForServer(player, getActiveMap())
	local abilityFolder = parent:FindFirstChild(FOLDER_NAME)
	if not (abilityFolder and abilityFolder:IsA("Folder")) then
		if abilityFolder then
			abilityFolder:Destroy()
		end
		abilityFolder = Instance.new("Folder")
		abilityFolder.Name = FOLDER_NAME
		abilityFolder.Parent = parent
	end

	local platformFolder = abilityFolder:FindFirstChild(PLATFORM_FOLDER_NAME)
	if platformFolder and platformFolder:IsA("Folder") then
		return platformFolder
	end
	if platformFolder then
		platformFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = PLATFORM_FOLDER_NAME
	folder.Parent = abilityFolder
	return folder
end

local function hasUnsafeTaggedAncestor(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		for _, tagName in ipairs(UNSAFE_TAGS) do
			if CollectionService:HasTag(current, tagName) then
				return true
			end
		end
		current = current.Parent
	end
	return false
end

local function flattenDirection(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.zAxis
	end
	return flat.Unit
end

local function getYawCFrame(rootPart: BasePart, position: Vector3): CFrame
	local look = flattenDirection(rootPart.CFrame.LookVector)
	return CFrame.lookAt(position, position + look)
end

local function addHighlight(part: BasePart, definition: AbilityDefinition): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = "PlatformHighlight"
	highlight.Adornee = part
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = getColor(definition, "topColor", Color3.new(1, 1, 1))
	highlight.FillTransparency = 0.94
	highlight.OutlineColor = getColor(definition, "topColor", Color3.new(1, 1, 1))
	highlight.OutlineTransparency = 0.08
	highlight.Parent = part
	return highlight
end

local function tweenPart(part: BasePart, info: TweenInfo, goal)
	if not part.Parent then
		return
	end

	local tween = TweenService:Create(part, info, goal)
	tween:Play()
end

local function fireEffect(effectName: string, player: Player, payload: { [string]: any })
	local service = abilityService
	if not service then
		return
	end

	payload.abilityId = "Platform"
	service:FireEffect(effectName, {
		player = player,
		abilityId = "Platform",
		payload = payload,
	})
end

local function setStatus(player: Player, status: string, reason: string?, position: Vector3?)
	player:SetAttribute(STATUS_ATTR, status)
	player:SetAttribute(STATUS_REASON_ATTR, reason or "")
	player:SetAttribute(STATUS_TIME_ATTR, workspace:GetServerTimeNow())
	if position then
		player:SetAttribute("PlatformStatusPosition", position)
	end
end

local function fireFailure(player: Player, reason: string, position: Vector3?)
	setStatus(player, "Failed", reason, position)

	local service = abilityService
	if not service then
		return
	end

	service:FireEffectToPlayer(player, "PlatformFailed", {
		player = player,
		abilityId = "Platform",
		payload = {
			abilityId = "Platform",
			reason = reason,
			position = position,
		},
	})
end

local function disconnectRecord(record: PlatformRecord)
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	table.clear(record.connections)
end

local function untrackRecord(record: PlatformRecord)
	if ACTIVE_PLATFORMS[record.owner] == record then
		ACTIVE_PLATFORMS[record.owner] = nil
	end
	if RECORD_BY_PART[record.part] == record then
		RECORD_BY_PART[record.part] = nil
	end
	disconnectRecord(record)
end

local function fadeAndDestroy(record: PlatformRecord, definition: AbilityDefinition, reason: string)
	local part = record.part
	if record.fading or not part.Parent then
		return
	end

	record.fading = true
	untrackRecord(record)

	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false

	fireEffect("PlatformDespawn", record.owner, {
		position = part.Position,
		reason = reason,
	})

	local fadeSeconds = math.max(getNumber(definition, "fadeSeconds", 0.35), 0.01)
	local fadeInfo = TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tweenPart(part, fadeInfo, {
		Transparency = 1,
		Size = Vector3.new(part.Size.X * 0.88, math.max(part.Size.Y * 0.4, 0.05), part.Size.Z * 0.88),
	})

	local highlight = record.highlight
	if highlight and highlight.Parent then
		TweenService:Create(highlight, fadeInfo, {
			FillTransparency = 1,
			OutlineTransparency = 1,
		}):Play()
	end

	task.delay(fadeSeconds, function()
		if part.Parent then
			part:Destroy()
		end
	end)
end

local function destroyActivePlatform(player: Player, definition: AbilityDefinition?)
	local record = ACTIVE_PLATFORMS[player]
	if not record then
		return
	end

	if definition and record.part.Parent then
		fadeAndDestroy(record, definition, "Replaced")
	else
		untrackRecord(record)
		if record.part.Parent then
			record.part:Destroy()
		end
	end
end

local function getRaycastParams(player: Player): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded = {}
	if player.Character then
		table.insert(excluded, player.Character)
	end
	local folder = workspace:FindFirstChild(FOLDER_NAME, true)
	if folder then
		table.insert(excluded, folder)
	end
	params.FilterDescendantsInstances = excluded
	params.RespectCanCollide = true
	return params
end

local function getOverlapParams(player: Player, platformFolder: Folder): OverlapParams
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded = { platformFolder }
	if player.Character then
		table.insert(excluded, player.Character)
	end
	params.FilterDescendantsInstances = excluded
	params.RespectCanCollide = true
	return params
end

local function getPlatformSize(definition: AbilityDefinition): Vector3
	local size = getVector3(definition, "platformSize", Vector3.new(7, 0.8, 7))
	return Vector3.new(math.max(size.X, 0.1), math.max(size.Y, 0.1), math.max(size.Z, 0.1))
end

local function getTopYOffset(definition: AbilityDefinition, rootPart: BasePart): number
	local velocityY = rootPart.AssemblyLinearVelocity.Y
	local fastFallSpeed = math.abs(getNumber(definition, "fastFallSpeedThreshold", -60))
	if velocityY <= -fastFallSpeed then
		return getNumber(definition, "fastFallTopOffset", 2.55)
	end
	return getNumber(definition, "verticalOffset", 3.05)
end

local function clampTopAgainstFloor(
	player: Player,
	rootPart: BasePart,
	topPosition: Vector3,
	size: Vector3,
	definition: AbilityDefinition
): Vector3
	local probeUp = math.max(getNumber(definition, "floorProbeUp", 1.5), 0)
	local probeDown = math.max(getNumber(definition, "floorProbeDown", 7), 0)
	local rayOrigin = topPosition + Vector3.yAxis * probeUp
	local hit = workspace:Raycast(rayOrigin, Vector3.yAxis * -(probeUp + probeDown), getRaycastParams(player))
	if not hit or hit.Normal.Y < getNumber(definition, "minFloorNormalY", 0.55) or hasUnsafeTaggedAncestor(hit.Instance) then
		return topPosition
	end

	local clearance = math.max(getNumber(definition, "floorClearance", 0.08), 0)
	local minCenterY = hit.Position.Y + clearance + size.Y * 0.5
	local currentCenterY = topPosition.Y - size.Y * 0.5
	if currentCenterY < minCenterY then
		return Vector3.new(topPosition.X, minCenterY + size.Y * 0.5, topPosition.Z)
	end
	return topPosition
end

local function isCharacterPart(part: BasePart): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local function isPlacementClear(
	player: Player,
	platformFolder: Folder,
	cframe: CFrame,
	size: Vector3,
	definition: AbilityDefinition
): boolean
	local clearance = math.max(getNumber(definition, "overlapClearance", 0.12), 0)
	local overlapSize = Vector3.new(
		math.max(size.X - clearance, 0.1),
		math.max(size.Y - clearance, 0.1),
		math.max(size.Z - clearance, 0.1)
	)

	for _, part in ipairs(workspace:GetPartBoundsInBox(cframe, overlapSize, getOverlapParams(player, platformFolder))) do
		if hasUnsafeTaggedAncestor(part) or isCharacterPart(part) then
			return false
		end
		if part.CanCollide and part.Transparency < 1 then
			return false
		end
	end

	return true
end

local function buildCandidatePlacement(
	player: Player,
	rootPart: BasePart,
	definition: AbilityDefinition,
	offset: Vector3
): Placement
	local size = getPlatformSize(definition)
	local rootPosition = rootPart.Position + offset
	local topPosition = rootPosition - Vector3.yAxis * getTopYOffset(definition, rootPart)
	topPosition = clampTopAgainstFloor(player, rootPart, topPosition, size, definition)

	local center = topPosition - Vector3.yAxis * (size.Y * 0.5)
	local cframe = getYawCFrame(rootPart, center)
	return {
		cframe = cframe,
		size = size,
		topPosition = topPosition,
	}
end

local function buildPlacement(
	player: Player,
	rootPart: BasePart,
	definition: AbilityDefinition,
	offset: Vector3,
	platformFolder: Folder
): Placement?
	local placement = buildCandidatePlacement(player, rootPart, definition, offset)
	if not isPlacementClear(player, platformFolder, placement.cframe, placement.size, definition) then
		return nil
	end

	return placement
end

local function findPlacement(player: Player, rootPart: BasePart, definition: AbilityDefinition, platformFolder: Folder): Placement?
	local right = flattenDirection(rootPart.CFrame.RightVector)
	local forward = flattenDirection(rootPart.CFrame.LookVector)
	local fallbackStep = math.max(getNumber(definition, "fallbackStep", 1.7), 0)
	local offsets = {
		Vector3.zero,
		right * fallbackStep,
		-right * fallbackStep,
		forward * fallbackStep,
		-forward * fallbackStep,
		(right + forward).Unit * fallbackStep,
		(-right + forward).Unit * fallbackStep,
		(right - forward).Unit * fallbackStep,
		(-right - forward).Unit * fallbackStep,
	}

	for _, offset in ipairs(offsets) do
		local placement = buildPlacement(player, rootPart, definition, offset, platformFolder)
		if placement then
			return placement
		end
	end

	if getBoolean(definition, "allowEmergencyFallbackPlacement", true) then
		local placement = buildCandidatePlacement(player, rootPart, definition, Vector3.zero)
		if isPlacementClear(player, platformFolder, placement.cframe, placement.size, definition) then
			return placement
		end
	end

	return nil
end

local function createPlatform(context: ServerActivateContext, placement: Placement): BasePart
	local definition = context.definition
	local part = Instance.new("Part")
	part.Name = "Platform_" .. context.player.UserId
	part:SetAttribute(OWNER_ATTR, context.player.UserId)
	part:SetAttribute("AbilityId", context.abilityId)
	part:SetAttribute("ExpiresAt", context.now + math.max(getNumber(definition, "lifetimeSeconds", 6.5), 0))
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CanTouch = true
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = getColor(definition, "color", Color3.fromRGB(96, 222, 255))
	part.Transparency = math.clamp(getNumber(definition, "transparency", 0.12), 0, 1)
	part.Size = placement.size
	part.CFrame = placement.cframe
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function prepareGrowth(part: BasePart, definition: AbilityDefinition)
	local finalSize = part.Size
	local finalCFrame = part.CFrame
	local finalTransparency = part.Transparency
	local startHeight = math.max(math.min(getNumber(definition, "startHeight", 0.08), finalSize.Y), 0.01)
	local bottom = finalCFrame.Position - finalCFrame.UpVector * (finalSize.Y * 0.5)
	local startPosition = bottom + finalCFrame.UpVector * (startHeight * 0.5)

	part.Size = Vector3.new(finalSize.X * 0.92, startHeight, finalSize.Z * 0.92)
	part.CFrame = (finalCFrame - finalCFrame.Position) + startPosition
	part.Transparency = math.max(finalTransparency, 0.45)

	return {
		finalSize = finalSize,
		finalCFrame = finalCFrame,
		finalTransparency = finalTransparency,
	}
end

local function growPlatform(part: BasePart, record, definition: AbilityDefinition)
	local growthSeconds = math.max(getNumber(definition, "growthSeconds", 0.1), 0.01)
	local growthInfo = TweenInfo.new(growthSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tweenPart(part, growthInfo, {
		Size = record.finalSize,
		CFrame = record.finalCFrame,
		Transparency = record.finalTransparency,
	})

	task.delay(growthSeconds, function()
		if not part.Parent then
			return
		end

		local scale = getNumber(definition, "bounceScale", 1.025)
		local outSeconds = math.max(getNumber(definition, "bounceOutSeconds", 0.06), 0.01)
		local backSeconds = math.max(getNumber(definition, "bounceBackSeconds", 0.09), 0.01)
		tweenPart(part, TweenInfo.new(outSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(record.finalSize.X * scale, record.finalSize.Y, record.finalSize.Z * scale),
		})
		task.delay(outSeconds, function()
			tweenPart(part, TweenInfo.new(backSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Size = record.finalSize,
			})
		end)
	end)
end

local function stabilizeRoot(rootPart: BasePart, definition: AbilityDefinition)
	local velocity = rootPart.AssemblyLinearVelocity
	local maxDownwardSpeed = math.abs(getNumber(definition, "stabilizedDownwardSpeed", -12))
	local horizontalDamping = math.clamp(getNumber(definition, "stabilizeHorizontalDamping", 0.7), 0, 1)
	local maxHorizontalSpeed = math.max(getNumber(definition, "stabilizedMaxHorizontalSpeed", 34), 0)
	if velocity.Y >= -maxDownwardSpeed and horizontalDamping >= 0.999 then
		return
	end

	local horizontal = Vector3.new(velocity.X * horizontalDamping, 0, velocity.Z * horizontalDamping)
	if maxHorizontalSpeed > 0 and horizontal.Magnitude > maxHorizontalSpeed then
		horizontal = horizontal.Unit * maxHorizontalSpeed
	end

	setCharacterVelocity(rootPart, Vector3.new(
		horizontal.X,
		math.max(velocity.Y, -maxDownwardSpeed),
		horizontal.Z
	), 0.12)
end

local function rescueRootToPlatform(rootPart: BasePart, placement: Placement, definition: AbilityDefinition)
	local velocity = rootPart.AssemblyLinearVelocity
	local snapSpeed = math.abs(getNumber(definition, "snapDownwardSpeedThreshold", -38))
	local platformHalfX = placement.size.X * 0.5
	local platformHalfZ = placement.size.Z * 0.5
	local localPosition = placement.cframe:PointToObjectSpace(rootPart.Position)
	local overPlatform = math.abs(localPosition.X) <= platformHalfX and math.abs(localPosition.Z) <= platformHalfZ

	if velocity.Y > -snapSpeed and rootPart.Position.Y >= placement.topPosition.Y + getNumber(definition, "rootRescueHeight", 3.05) then
		stabilizeRoot(rootPart, definition)
		return
	end

	local rescueHeight = math.max(getNumber(definition, "rootRescueHeight", 3.05), 1.5)
	local targetPosition = Vector3.new(rootPart.Position.X, placement.topPosition.Y + rescueHeight, rootPart.Position.Z)
	if not overPlatform then
		local clampedLocal = Vector3.new(
			math.clamp(localPosition.X, -platformHalfX * 0.72, platformHalfX * 0.72),
			localPosition.Y,
			math.clamp(localPosition.Z, -platformHalfZ * 0.72, platformHalfZ * 0.72)
		)
		targetPosition = placement.cframe:PointToWorldSpace(Vector3.new(clampedLocal.X, rescueHeight + placement.size.Y * 0.5, clampedLocal.Z))
	end

	rootPart.CFrame = CFrame.new(targetPosition) * (rootPart.CFrame - rootPart.CFrame.Position)
	local horizontalDamping = math.clamp(getNumber(definition, "rescueHorizontalDamping", 0.45), 0, 1)
	local maxHorizontalSpeed = math.max(getNumber(definition, "rescueMaxHorizontalSpeed", 26), 0)
	local horizontal = Vector3.new(velocity.X * horizontalDamping, 0, velocity.Z * horizontalDamping)
	if maxHorizontalSpeed > 0 and horizontal.Magnitude > maxHorizontalSpeed then
		horizontal = horizontal.Unit * maxHorizontalSpeed
	end
	setCharacterVelocity(rootPart, Vector3.new(
		horizontal.X,
		math.max(getNumber(definition, "rescueUpwardVelocity", 4), 0),
		horizontal.Z
	), 0.18)
end

local function stabilizeCharacterForLanding(rootPart: BasePart, definition: AbilityDefinition, seconds: number)
	local character = rootPart:FindFirstAncestorOfClass("Model")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		end)
	end

	local serial = (STABILIZE_SERIAL_BY_ROOT[rootPart] or 0) + 1
	STABILIZE_SERIAL_BY_ROOT[rootPart] = serial
	local interval = math.max(getNumber(definition, "stabilizeTickSeconds", 0.05), 0.02)
	local deadline = os.clock() + math.max(seconds, 0)
	task.spawn(function()
		while rootPart.Parent and os.clock() < deadline and STABILIZE_SERIAL_BY_ROOT[rootPart] == serial do
			local velocity = rootPart.AssemblyLinearVelocity
			local maxDownwardSpeed = math.abs(getNumber(definition, "stabilizedDownwardSpeed", -6))
			local horizontalDamping = math.clamp(getNumber(definition, "rescueTickHorizontalDamping", 0.82), 0, 1)
			setCharacterVelocity(rootPart, Vector3.new(
				velocity.X * horizontalDamping,
				math.max(velocity.Y, -maxDownwardSpeed),
				velocity.Z * horizontalDamping
			), interval + 0.05)
			task.wait(interval)
		end
		if STABILIZE_SERIAL_BY_ROOT[rootPart] == serial then
			STABILIZE_SERIAL_BY_ROOT[rootPart] = nil
		end
	end)
end

local function playWarning(record: PlatformRecord, definition: AbilityDefinition)
	local part = record.part
	if record.fading or not part.Parent then
		return
	end

	fireEffect("PlatformWarning", record.owner, {
		position = part.Position,
	})

	local warningSeconds = math.max(getNumber(definition, "warningPulseSeconds", 0.22), 0.05)
	local warningColor = getColor(definition, "warningColor", Color3.fromRGB(255, 236, 117))
	local originalColor = part.Color
	TweenService:Create(part, TweenInfo.new(warningSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
		Color = warningColor,
		Transparency = math.min(part.Transparency + 0.18, 0.75),
	}):Play()
	task.delay(warningSeconds, function()
		if part.Parent and not record.fading then
			TweenService:Create(part, TweenInfo.new(warningSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
				Color = originalColor,
				Transparency = math.clamp(getNumber(definition, "transparency", 0.12), 0, 1),
			}):Play()
		end
	end)
end

local function connectPlatformTouch(record: PlatformRecord, definition: AbilityDefinition)
	local part = record.part
	local connection = part.Touched:Connect(function(hit: BasePart)
		if record.fading or not hit.Parent then
			return
		end

		local character = hit:FindFirstAncestorOfClass("Model")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if not (humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart")) then
			return
		end

		local now = workspace:GetServerTimeNow()
		local ownerRoot = if character == record.owner.Character then rootPart else nil
		if ownerRoot then
			stabilizeRoot(ownerRoot, definition)
		end

		if now - record.lastTouchEffectAt >= getNumber(definition, "touchEffectCooldown", 0.45) then
			record.lastTouchEffectAt = now
			fireEffect("PlatformTouched", record.owner, {
				position = part.Position + Vector3.yAxis * (part.Size.Y * 0.5),
			})
		end
	end)
	table.insert(record.connections, connection)
end

local function trackPlatform(player: Player, part: BasePart, highlight: Highlight?, definition: AbilityDefinition): PlatformRecord
	local record: PlatformRecord = {
		part = part,
		highlight = highlight,
		owner = player,
		connections = {},
		fading = false,
		lastTouchEffectAt = -math.huge,
	}

	ACTIVE_PLATFORMS[player] = record
	RECORD_BY_PART[part] = record
	connectPlatformTouch(record, definition)

	table.insert(record.connections, part.AncestryChanged:Connect(function()
		if part.Parent then
			return
		end
		untrackRecord(record)
	end))

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(record.connections, humanoid.Died:Connect(function()
			if getBoolean(definition, "cleanupOnOwnerDeath", true) then
				fadeAndDestroy(record, definition, "OwnerDied")
			end
		end))
	end

	return record
end

function Platform.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil
end

function Platform.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local rootPart = getCharacterRoot(context.player)
	if not rootPart then
		fireFailure(context.player, "NoCharacter", nil)
		return false
	end

	setStatus(context.player, "Activate", "", rootPart.Position)

	local platformFolder = getPlatformFolder(context.player)
	local placement = findPlacement(context.player, rootPart, context.definition, platformFolder)
	if not placement then
		fireFailure(context.player, "NoSafePlacement", rootPart.Position)
		return false
	end

	destroyActivePlatform(context.player, context.definition)

	local platform = createPlatform(context, placement)
	local highlight = addHighlight(platform, context.definition)
	local growthRecord = prepareGrowth(platform, context.definition)
	platform.Parent = platformFolder
	local record = trackPlatform(context.player, platform, highlight, context.definition)
	growPlatform(platform, growthRecord, context.definition)
	rescueRootToPlatform(rootPart, placement, context.definition)
	stabilizeCharacterForLanding(
		rootPart,
		context.definition,
		getNumber(context.definition, "stabilizeDurationSeconds", 0.35)
	)
	setStatus(context.player, "Placed", "", placement.topPosition)

	local lifetimeSeconds = math.max(getNumber(context.definition, "lifetimeSeconds", 6.5), 0)
	local warningLeadSeconds = math.max(getNumber(context.definition, "warningLeadSeconds", 1.1), 0)
	if warningLeadSeconds > 0 and lifetimeSeconds > warningLeadSeconds then
		task.delay(lifetimeSeconds - warningLeadSeconds, function()
			playWarning(record, context.definition)
		end)
	end
	task.delay(lifetimeSeconds, function()
		fadeAndDestroy(record, context.definition, "Expired")
	end)

	local state = context.slotState.state
	local platformCount = if typeof(state) == "table" and typeof(state.platformCount) == "number"
		then state.platformCount
		else 0

	return {
		state = {
			platformCount = platformCount + 1,
			lastPlacedAt = context.now,
		},
		effect = {
			name = "PlatformPlaced",
			payload = {
				position = platform.Position,
				topPosition = placement.topPosition,
				size = platform.Size,
			},
		},
	}
end

function Platform.OnPlayerRemoving(player: Player)
	destroyActivePlatform(player, nil)
end

function Platform.OnStart(service: AbilityServiceLike)
	abilityService = service
end

return Platform
