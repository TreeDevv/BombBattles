local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext

type FloorPlacement = {
	position: Vector3,
	facing: Vector3,
	normal: Vector3,
	floor: Instance,
}

type JumpPadRecord = {
	id: string,
	owner: Player,
	model: Instance,
	spring: BasePart,
	facing: Vector3,
	raisedCFrame: CFrame,
	compressedCFrame: CFrame,
	connections: { RBXScriptConnection },
	lastLaunchByCharacter: { [Model]: number },
	armed: boolean,
	fading: boolean,
}

local JumpPad = {} :: AbilityTypes.ServerBehavior

local FOLDER_NAME = "AbilityObjects"
local JUMP_PAD_FOLDER_NAME = "JumpPad"
local OWNER_ATTR = "JumpPadOwnerUserId"
local PAD_ID_ATTR = "JumpPadId"
local ARMED_ATTR = "JumpPadArmed"
local ACTIVE_PADS: { [Player]: { JumpPadRecord } } = {}
local RECORD_BY_SPRING: { [BasePart]: JumpPadRecord } = {}
local abilityService: AbilityServiceLike? = nil
local padSerial = 0

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

local function getBounds(instance: Instance): (CFrame, Vector3)
	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	end
	local part = instance :: BasePart
	return part.CFrame, part.Size
end

local function pivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	else
		(instance :: BasePart).CFrame = cframe
	end
end

local function getPartAxisExtents(part: BasePart, axis: Vector3, origin: Vector3): (number, number)
	local halfSize = part.Size * 0.5
	local minDistance = math.huge
	local maxDistance = -math.huge

	for _, xSign in ipairs({ -1, 1 }) do
		for _, ySign in ipairs({ -1, 1 }) do
			for _, zSign in ipairs({ -1, 1 }) do
				local corner = part.CFrame:PointToWorldSpace(Vector3.new(
					halfSize.X * xSign,
					halfSize.Y * ySign,
					halfSize.Z * zSign
				))
				local distance = (corner - origin):Dot(axis)
				minDistance = math.min(minDistance, distance)
				maxDistance = math.max(maxDistance, distance)
			end
		end
	end

	return minDistance, maxDistance
end

local function getInstanceAxisExtents(instance: Instance, axis: Vector3, origin: Vector3): (number, number)
	local minDistance = math.huge
	local maxDistance = -math.huge
	for _, part in ipairs(getBaseParts(instance)) do
		local partMin, partMax = getPartAxisExtents(part, axis, origin)
		minDistance = math.min(minDistance, partMin)
		maxDistance = math.max(maxDistance, partMax)
	end

	return minDistance, maxDistance
end

local function stripScripts(instance: Instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
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

local function getActiveMap(): Instance?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getJumpPadFolder(player: Player): Folder
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

	local jumpPadFolder = abilityFolder:FindFirstChild(JUMP_PAD_FOLDER_NAME)
	if jumpPadFolder and jumpPadFolder:IsA("Folder") then
		return jumpPadFolder
	end
	if jumpPadFolder then
		jumpPadFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = JUMP_PAD_FOLDER_NAME
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

local function flattenDirection(direction: Vector3, fallback: Vector3?): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude >= 0.05 then
		return flat.Unit
	end
	if fallback and fallback.Magnitude >= 0.05 then
		return Vector3.new(fallback.X, 0, fallback.Z).Unit
	end
	return Vector3.zAxis
end

local function getRaycastParams(player: Player): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded = {}
	if player.Character then
		table.insert(excluded, player.Character)
	end
	local abilityFolder = workspace:FindFirstChild(FOLDER_NAME, true)
	if abilityFolder then
		table.insert(excluded, abilityFolder)
	end
	params.FilterDescendantsInstances = excluded
	params.RespectCanCollide = true
	return params
end

local function findFloor(player: Player, rootPart: BasePart, definition: AbilityDefinition): FloorPlacement?
	local distance = math.max(getNumber(definition, "placementDistance", 8), 0)
	local rayUp = math.max(getNumber(definition, "floorRaycastUp", 8), 0)
	local rayDown = math.max(getNumber(definition, "floorRaycastDown", 140), 1)
	local facing = flattenDirection(rootPart.CFrame.LookVector, nil)
	local target = rootPart.Position + facing * distance
	local rayOrigin = target + Vector3.yAxis * rayUp
	local rayDirection = Vector3.new(0, -(rayUp + rayDown), 0)
	local hit = workspace:Raycast(rayOrigin, rayDirection, getRaycastParams(player))
	if not hit then
		return nil
	end
	if hit.Normal.Y < getNumber(definition, "minFloorNormalY", 0.6) then
		return nil
	end
	if hasUnsafeTaggedAncestor(hit.Instance) then
		return nil
	end

	local targetRoot = PracticeRangeTargeting.GetServerTargetRoot(player, getActiveMap())
	if not PracticeRangeTargeting.IsInTargetRoot(hit.Instance, targetRoot) then
		return nil
	end

	return {
		position = hit.Position,
		facing = facing,
		normal = hit.Normal,
		floor = hit.Instance,
	}
end

local function getFloorPivot(floorPosition: Vector3, facing: Vector3, normal: Vector3): CFrame
	local up = if normal.Magnitude > 0.05 then normal.Unit else Vector3.yAxis
	local forward = facing - up * facing:Dot(up)
	if forward.Magnitude < 0.05 then
		forward = up:Cross(Vector3.xAxis)
		if forward.Magnitude < 0.05 then
			forward = up:Cross(Vector3.zAxis)
		end
	end

	forward = forward.Unit
	local right = up:Cross(forward).Unit
	forward = right:Cross(up).Unit
	return CFrame.fromMatrix(floorPosition, right, up, -forward)
end

local function alignCloneToFloor(
	clone: Instance,
	floorPosition: Vector3,
	facing: Vector3,
	normal: Vector3
): (CFrame, Vector3, CFrame)
	local pivot = getFloorPivot(floorPosition, facing, normal)
	pivotTo(clone, pivot)

	local bottomOffset = getInstanceAxisExtents(clone, pivot.UpVector, floorPosition)
	local finalPivot = pivot - pivot.UpVector * bottomOffset
	pivotTo(clone, finalPivot)

	local finalBoundsCFrame, finalBoundsSize = getBounds(clone)
	return finalBoundsCFrame, finalBoundsSize, finalPivot
end

local function validatePlacement(player: Player, definition: AbilityDefinition, template: Instance): FloorPlacement?
	local rootPart = getCharacterRoot(player)
	if not rootPart then
		return nil
	end

	local placement = findFloor(player, rootPart, definition)
	if not placement then
		return nil
	end

	local clone = template:Clone()
	local boundsCFrame, boundsSize = alignCloneToFloor(clone, placement.position, placement.facing, placement.normal)
	clone:Destroy()

	if boundsSize.X <= 0 or boundsSize.Y <= 0 or boundsSize.Z <= 0 then
		return nil
	end

	local params = OverlapParams.new()
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

	local overlapSize = Vector3.new(
		math.max(boundsSize.X * 0.9, 0.1),
		math.max(boundsSize.Y - 0.2, 0.1),
		math.max(boundsSize.Z * 0.9, 0.1)
	)
	for _, part in ipairs(workspace:GetPartBoundsInBox(boundsCFrame + boundsCFrame.UpVector * 0.12, overlapSize, params)) do
		if part == placement.floor or part:IsDescendantOf(placement.floor) then
			continue
		end
		local model = part:FindFirstAncestorOfClass("Model")
		if hasUnsafeTaggedAncestor(part) or (model and model:FindFirstChildOfClass("Humanoid")) then
			return nil
		end
		if part.CanCollide and part.Transparency < 1 then
			return nil
		end
	end

	return placement
end

local function findSpring(instance: Instance): BasePart?
	local spring = instance:FindFirstChild("spring", true)
	if spring and spring:IsA("BasePart") then
		return spring
	end
	return nil
end

local function setPadParts(model: Instance, spring: BasePart, armed: boolean)
	for _, part in ipairs(getBaseParts(model)) do
		part.CanCollide = false
		part.CanQuery = true
		part.CanTouch = part == spring and armed
		if part == spring then
			part.Anchored = true
		elseif part:IsDescendantOf(spring) then
			part.Anchored = false
		else
			part.Anchored = true
		end
	end
end

local function getCompressedSpringCFrame(spring: BasePart, up: Vector3, floorPosition: Vector3, definition: AbilityDefinition): CFrame
	local clearance = math.max(getNumber(definition, "springCompressedClearance", 0.08), 0)
	local restingOffset = math.max(getNumber(definition, "springRestingHeightOffset", 0), 0)
	local springBottom = getPartAxisExtents(spring, up, floorPosition)
	local compressionDistance = math.max(springBottom - clearance, 0)
	return spring.CFrame - up * math.max(compressionDistance - restingOffset, 0)
end

local function tweenSpring(record: JumpPadRecord, definition: AbilityDefinition)
	if record.fading or not record.spring.Parent then
		return
	end

	local spring = record.spring
	local upSeconds = math.max(getNumber(definition, "springUpSeconds", 0.12), 0.01)
	local holdSeconds = math.max(getNumber(definition, "springHoldSeconds", 0.08), 0)
	local recompressSeconds = math.max(getNumber(definition, "springRecompressSeconds", 0.16), 0.01)
	TweenService:Create(spring, TweenInfo.new(upSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		CFrame = record.raisedCFrame,
	}):Play()

	task.delay(upSeconds + holdSeconds, function()
		if record.fading or not spring.Parent then
			return
		end
		TweenService:Create(spring, TweenInfo.new(recompressSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			CFrame = record.compressedCFrame,
		}):Play()
	end)
end

local function fireEffect(effectName: string, player: Player, payload: { [string]: any })
	local service = abilityService
	if not service then
		return
	end

	payload.abilityId = "JumpPad"
	service:FireEffect(effectName, {
		player = player,
		abilityId = "JumpPad",
		payload = payload,
	})
end

local function fireFailure(player: Player, reason: string, position: Vector3?)
	local service = abilityService
	if not service then
		return
	end

	service:FireEffectToPlayer(player, "JumpPadFailed", {
		player = player,
		abilityId = "JumpPad",
		payload = {
			abilityId = "JumpPad",
			reason = reason,
			position = position,
		},
	})
end

local function disconnectRecord(record: JumpPadRecord)
	for _, connection in ipairs(record.connections) do
		connection:Disconnect()
	end
	table.clear(record.connections)
end

local function untrackRecord(record: JumpPadRecord)
	local playerRecords = ACTIVE_PADS[record.owner]
	local index = playerRecords and table.find(playerRecords, record)
	if index then
		table.remove(playerRecords, index)
	end
	if playerRecords and #playerRecords == 0 then
		ACTIVE_PADS[record.owner] = nil
	end
	if RECORD_BY_SPRING[record.spring] == record then
		RECORD_BY_SPRING[record.spring] = nil
	end
	disconnectRecord(record)
end

local function fadeAndDestroy(record: JumpPadRecord, definition: AbilityDefinition, reason: string)
	if record.fading or not record.model.Parent then
		return
	end

	record.fading = true
	record.armed = false
	record.model:SetAttribute(ARMED_ATTR, false)
	record.spring.CanTouch = false
	untrackRecord(record)

	fireEffect("JumpPadDespawned", record.owner, {
		padId = record.id,
		reason = reason,
		position = getBounds(record.model).Position,
	})

	local fadeSeconds = math.max(getNumber(definition, "fadeSeconds", 0.25), 0.01)
	local fadeInfo = TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, part in ipairs(getBaseParts(record.model)) do
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		if part.Transparency < 1 then
			TweenService:Create(part, fadeInfo, { Transparency = 1 }):Play()
		end
	end

	task.delay(fadeSeconds, function()
		if record.model.Parent then
			record.model:Destroy()
		end
	end)
end

local function getLaunchDirection(humanoid: Humanoid, rootPart: BasePart, fallback: Vector3): Vector3
	if humanoid.MoveDirection.Magnitude >= 0.05 then
		return flattenDirection(humanoid.MoveDirection, fallback)
	end
	local velocity = rootPart.AssemblyLinearVelocity
	if Vector3.new(velocity.X, 0, velocity.Z).Magnitude >= 0.05 then
		return flattenDirection(velocity, fallback)
	end
	return flattenDirection(fallback, Vector3.zAxis)
end

local function launchCharacter(record: JumpPadRecord, character: Model, humanoid: Humanoid, rootPart: BasePart, definition: AbilityDefinition)
	local direction = getLaunchDirection(humanoid, rootPart, record.facing)
	local velocity = rootPart.AssemblyLinearVelocity
	local mass = math.max(rootPart.AssemblyMass, 0)
	if mass <= 0 then
		return
	end

	local verticalTarget = math.max(getNumber(definition, "verticalLaunchVelocity", 95), 0)
	local horizontalTarget = math.max(getNumber(definition, "horizontalLaunchSpeed", 48), 0)
	local verticalDelta = math.max(verticalTarget - velocity.Y, 0)
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local forwardSpeed = horizontalVelocity:Dot(direction)
	local horizontalDelta = math.max(horizontalTarget - forwardSpeed, 0)
	local impulse = Vector3.yAxis * verticalDelta * mass + direction * horizontalDelta * mass
	if impulse.Magnitude > 0 then
		rootPart:ApplyImpulse(impulse)
	end

	humanoid.Jump = true
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end)

	local launchedPlayer = Players:GetPlayerFromCharacter(character)
	fireEffect("JumpPadTriggered", record.owner, {
		padId = record.id,
		position = record.spring.Position,
		direction = direction,
		launchedPlayer = launchedPlayer,
		raisedCFrame = record.raisedCFrame,
		compressedCFrame = record.compressedCFrame,
		verticalLaunchVelocity = verticalTarget,
		horizontalLaunchSpeed = horizontalTarget,
	})
end

local function connectTouch(record: JumpPadRecord, definition: AbilityDefinition)
	table.insert(record.connections, record.spring.Touched:Connect(function(hit: BasePart)
		if record.fading or not record.armed or not hit.Parent then
			return
		end

		local character = hit:FindFirstAncestorOfClass("Model")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if not (character and humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart")) then
			return
		end

		local now = workspace:GetServerTimeNow()
		local lastLaunch = record.lastLaunchByCharacter[character] or -math.huge
		if now - lastLaunch < math.max(getNumber(definition, "triggerCooldownSeconds", 0.65), 0) then
			return
		end

		record.lastLaunchByCharacter[character] = now
		tweenSpring(record, definition)
		launchCharacter(record, character, humanoid, rootPart, definition)
	end))
end

local function trackRecord(record: JumpPadRecord, definition: AbilityDefinition)
	local playerRecords = ACTIVE_PADS[record.owner]
	if not playerRecords then
		playerRecords = {}
		ACTIVE_PADS[record.owner] = playerRecords
	end
	table.insert(playerRecords, record)
	RECORD_BY_SPRING[record.spring] = record
	connectTouch(record, definition)

	table.insert(record.connections, record.model.AncestryChanged:Connect(function()
		if record.model.Parent then
			return
		end
		untrackRecord(record)
	end))

	local character = record.owner.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(record.connections, humanoid.Died:Connect(function()
			if getBoolean(definition, "cleanupOnOwnerDeath", true) then
				fadeAndDestroy(record, definition, "OwnerDied")
			end
		end))
	end
end

local function armPad(record: JumpPadRecord)
	if record.fading or not record.model.Parent then
		return
	end

	record.armed = true
	record.model:SetAttribute(ARMED_ATTR, true)
	record.spring.CanTouch = true
	fireEffect("JumpPadArmed", record.owner, {
		padId = record.id,
		position = record.spring.Position,
		raisedCFrame = record.raisedCFrame,
		compressedCFrame = record.compressedCFrame,
	})
end

local function tweenModelPivot(model: Instance, fromPivot: CFrame, toPivot: CFrame, seconds: number, done: () -> ())
	if seconds <= 0.01 then
		pivotTo(model, toPivot)
		done()
		return
	end

	local value = Instance.new("CFrameValue")
	value.Value = fromPivot
	local connection = value:GetPropertyChangedSignal("Value"):Connect(function()
		if model.Parent then
			pivotTo(model, value.Value)
		end
	end)
	local tween = TweenService:Create(value, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Value = toPivot,
	})
	tween.Completed:Connect(function()
		connection:Disconnect()
		value:Destroy()
		if model.Parent then
			pivotTo(model, toPivot)
			done()
		end
	end)
	tween:Play()
end

function JumpPad.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil
end

function JumpPad.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local rootPart = getCharacterRoot(context.player)
	if not rootPart then
		fireFailure(context.player, "NoCharacter", nil)
		return false
	end

	local template = getTemplate(context.definition)
	if not template then
		warn("[JumpPad] Missing ReplicatedStorage.Assets.Abilities.JumpPad.JumpPad")
		fireFailure(context.player, "MissingAsset", rootPart.Position)
		return false
	end

	local placement = validatePlacement(context.player, context.definition, template)
	if not placement then
		fireFailure(context.player, "NoSafePlacement", rootPart.Position)
		return false
	end

	local model = template:Clone()
	stripScripts(model)
	local spring = findSpring(model)
	if not spring then
		model:Destroy()
		warn("[JumpPad] JumpPad asset has no BasePart named spring")
		fireFailure(context.player, "MissingSpring", placement.position)
		return false
	end

	padSerial += 1
	local padId = ("JumpPad_%d_%d"):format(context.player.UserId, padSerial)
	model.Name = padId
	model:SetAttribute(PAD_ID_ATTR, padId)
	model:SetAttribute(OWNER_ATTR, context.player.UserId)
	model:SetAttribute("AbilityId", context.abilityId)
	model:SetAttribute("ExpiresAt", context.now + math.max(getNumber(context.definition, "lifetimeSeconds", 8), 0))
	model:SetAttribute(ARMED_ATTR, false)

	local _, _, finalPivot = alignCloneToFloor(model, placement.position, placement.facing, placement.normal)
	local raisedCFrame = spring.CFrame
	local compressedCFrame = getCompressedSpringCFrame(spring, finalPivot.UpVector, placement.position, context.definition)
	setPadParts(model, spring, false)
	spring.CFrame = compressedCFrame

	local rootHeight = (rootPart.Position - placement.position):Dot(finalPivot.UpVector)
	local dropHeight = math.clamp(rootHeight, 0, math.max(getNumber(context.definition, "dropMaxHeight", 32), 0))
	local dropSpeed = math.max(getNumber(context.definition, "dropSpeed", 72), 1)
	local dropSeconds = if dropHeight > 0.5
		then math.clamp(
			dropHeight / dropSpeed,
			math.max(getNumber(context.definition, "dropMinSeconds", 0.12), 0),
			math.max(getNumber(context.definition, "dropMaxSeconds", 0.45), 0.01)
		)
		else math.max(getNumber(context.definition, "dropMinSeconds", 0.12), 0)
	local startPivot = finalPivot + finalPivot.UpVector * dropHeight
	pivotTo(model, startPivot)
	model.Parent = getJumpPadFolder(context.player)

	local record: JumpPadRecord = {
		id = padId,
		owner = context.player,
		model = model,
		spring = spring,
		facing = placement.facing,
		raisedCFrame = raisedCFrame,
		compressedCFrame = compressedCFrame,
		connections = {},
		lastLaunchByCharacter = {},
		armed = false,
		fading = false,
	}
	trackRecord(record, context.definition)

	tweenModelPivot(model, startPivot, finalPivot, dropSeconds, function()
		armPad(record)
	end)

	task.delay(math.max(getNumber(context.definition, "lifetimeSeconds", 8), 0), function()
		fadeAndDestroy(record, context.definition, "Expired")
	end)

	local state = context.slotState.state
	local padsPlaced = if typeof(state) == "table" and typeof(state.padsPlaced) == "number" then state.padsPlaced else 0

	return {
		state = {
			padsPlaced = padsPlaced + 1,
			lastPlacedAt = context.now,
		},
		effect = {
			name = "JumpPadPlaced",
			payload = {
				padId = padId,
				position = placement.position,
				raisedCFrame = raisedCFrame,
				compressedCFrame = compressedCFrame,
				dropSeconds = dropSeconds,
			},
		},
	}
end

function JumpPad.OnPlayerRemoving(player: Player)
	local records = ACTIVE_PADS[player]
	ACTIVE_PADS[player] = nil
	if not records then
		return
	end

	for _, record in ipairs(records) do
		untrackRecord(record)
		if record.model.Parent then
			record.model:Destroy()
		end
	end
end

function JumpPad.OnStart(service: AbilityServiceLike)
	abilityService = service
end

return JumpPad
