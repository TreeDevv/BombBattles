local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityHookResult = AbilityTypes.AbilityHookResult
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext
type FloorPlacement = {
	position: Vector3,
	facing: Vector3,
	floor: Instance,
}
type FieldRecord = {
	id: string,
	player: Player,
	slot: string,
	field: Instance,
	center: Vector3,
	cframe: CFrame,
	radius: number,
	activeEndsAt: number,
	serial: number,
}

local GravityField = {} :: AbilityTypes.ServerBehavior

local RESULT_KIND = AbilityResult.Kind
local FOLDER_NAME = "AbilityObjects"
local FIELD_FOLDER_NAME = "GravityField"
local OWNER_ATTR = "GravityFieldOwnerUserId"
local ID_ATTR = "GravityFieldId"
local ACTIVE_FIELDS: { [Player]: { FieldRecord } } = {}
local SERIALS: { [Player]: number } = {}
local abilityService: AbilityServiceLike? = nil

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

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

local function getActiveMap(): Instance?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getFieldFolder(): Folder
	local parent = getActiveMap() or workspace
	local abilityFolder = parent:FindFirstChild(FOLDER_NAME)
	if not (abilityFolder and abilityFolder:IsA("Folder")) then
		if abilityFolder then
			abilityFolder:Destroy()
		end
		abilityFolder = Instance.new("Folder")
		abilityFolder.Name = FOLDER_NAME
		abilityFolder.Parent = parent
	end

	local fieldFolder = abilityFolder:FindFirstChild(FIELD_FOLDER_NAME)
	if fieldFolder and fieldFolder:IsA("Folder") then
		return fieldFolder
	end
	if fieldFolder then
		fieldFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = FIELD_FOLDER_NAME
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

local function findFloor(rootPart: BasePart, definition: AbilityDefinition): FloorPlacement?
	local distance = definition.placementDistance or 8
	local rayUp = definition.floorRaycastUp or 8
	local rayDown = definition.floorRaycastDown or 32
	local facing = flattenDirection(rootPart.CFrame.LookVector)
	local target = rootPart.Position + facing * distance
	local rayOrigin = target + Vector3.yAxis * rayUp
	local rayDirection = Vector3.new(0, -(rayUp + rayDown), 0)
	local hit = workspace:Raycast(rayOrigin, rayDirection)
	if not hit then
		return nil
	end
	if hit.Normal.Y < (definition.minFloorNormalY or 0.65) then
		return nil
	end
	if hasUnsafeTaggedAncestor(hit.Instance) then
		return nil
	end

	local activeMap = getActiveMap()
	if activeMap and not hit.Instance:IsDescendantOf(activeMap) then
		return nil
	end

	return {
		position = hit.Position,
		facing = facing,
		floor = hit.Instance,
	}
end

local function alignCloneToFloor(clone: Instance, floorPosition: Vector3, facing: Vector3): (CFrame, Vector3)
	local pivot = CFrame.lookAt(floorPosition, floorPosition + facing)
	pivotTo(clone, pivot)

	local boundsCFrame, boundsSize = getBounds(clone)
	local bottomY = boundsCFrame.Position.Y - boundsSize.Y * 0.5
	local finalPivot = pivot + Vector3.yAxis * (floorPosition.Y - bottomY)
	pivotTo(clone, finalPivot)

	return getBounds(clone)
end

local function validatePlacement(player: Player, definition: AbilityDefinition, template: Instance): (FloorPlacement?, CFrame?, Vector3?)
	local rootPart = getCharacterRoot(player)
	if not rootPart then
		return nil, nil, nil
	end

	local floor = findFloor(rootPart, definition)
	if not floor then
		return nil, nil, nil
	end

	local clone = template:Clone()
	local boundsCFrame, boundsSize = alignCloneToFloor(clone, floor.position, floor.facing)
	clone:Destroy()

	if boundsSize.X <= 0 or boundsSize.Y <= 0 or boundsSize.Z <= 0 then
		return nil, nil, nil
	end

	return floor, boundsCFrame, boundsSize
end

local function prepareField(field: Instance)
	for _, part in ipairs(getBaseParts(field)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
	end
end

local function getNextFieldId(player: Player): (string, number)
	local serial = (SERIALS[player] or 0) + 1
	SERIALS[player] = serial
	return string.format("GravityField_%d_%d", player.UserId, serial), serial
end

local function removeRecord(player: Player, fieldId: string): FieldRecord?
	local records = ACTIVE_FIELDS[player]
	if not records then
		return nil
	end

	for index = #records, 1, -1 do
		local record = records[index]
		if record.id == fieldId then
			table.remove(records, index)
			if #records == 0 then
				ACTIVE_FIELDS[player] = nil
			end
			return record
		end
	end

	return nil
end

local function expireField(player: Player, fieldId: string)
	local record = removeRecord(player, fieldId)
	if not record then
		return
	end

	local service = abilityService
	if service then
		service:FireEffect("GravityFieldExpired", {
			player = player,
			slot = record.slot,
			abilityId = "GravityField",
			fieldId = record.id,
		})
	end

	if record.field.Parent then
		record.field:Destroy()
	end
end

local function readVector(value: any, fallback: Vector3): Vector3
	if typeof(value) == "Vector3" and value.Magnitude < math.huge then
		return value
	end
	return fallback
end

local function getRadius(definition: AbilityDefinition, boundsSize: Vector3): number
	local configured = tonumber(definition.radius)
	if configured and configured > 0 then
		return configured
	end
	return math.max(boundsSize.X, boundsSize.Y, boundsSize.Z) * 0.5
end

local function getDistanceToSegment(point: Vector3, startPosition: Vector3, endPosition: Vector3): number
	local segment = endPosition - startPosition
	local lengthSquared = segment:Dot(segment)
	if lengthSquared <= 0.0001 then
		return (point - startPosition).Magnitude
	end

	local alpha = math.clamp((point - startPosition):Dot(segment) / lengthSquared, 0, 1)
	local closest = startPosition + segment * alpha
	return (point - closest).Magnitude
end

local function getDropVelocity(record: FieldRecord, definition: AbilityDefinition, payload): Vector3?
	if payload.attached == true then
		return nil
	end

	local position = readVector(payload.position, Vector3.zero)
	local nextPosition = readVector(payload.nextPosition, position)
	local sweepRadius = math.max(tonumber(payload.sweepRadius) or BombConfig.SweepRadius or 0, 0)
	local distance = getDistanceToSegment(record.center, position, nextPosition)
	if distance > record.radius + sweepRadius then
		return nil
	end

	local dropSpeed = math.max(tonumber(definition.dropSpeed) or 120, 1)
	return Vector3.new(0, -dropSpeed, 0)
end

local function getMaxDropSpeed(definition: AbilityDefinition): number
	local dropSpeed = math.max(tonumber(definition.dropSpeed) or 120, 1)
	return math.max(tonumber(definition.maxDropSpeed) or dropSpeed, dropSpeed)
end

function GravityField.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function GravityField.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getTemplate(context.definition) ~= nil
end

function GravityField.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local definition = context.definition
	local template = getTemplate(definition)
	if not template then
		warn("[GravityField] Missing ReplicatedStorage.Assets.Abilities.GravityField.Gravity Field")
		return false
	end

	local placement, boundsCFrame, boundsSize = validatePlacement(context.player, definition, template)
	if not (placement and boundsCFrame and boundsSize) then
		return false
	end

	local field = template:Clone()
	local fieldId, serial = getNextFieldId(context.player)
	field.Name = fieldId
	field:SetAttribute(ID_ATTR, fieldId)
	field:SetAttribute(OWNER_ATTR, context.player.UserId)
	field:SetAttribute("AbilityId", context.abilityId)
	alignCloneToFloor(field, placement.position, placement.facing)
	prepareField(field)
	field.Parent = getFieldFolder()

	local durationSeconds = math.max(tonumber(definition.durationSeconds) or 0, 0)
	local activeEndsAt = context.now + durationSeconds
	local radius = getRadius(definition, boundsSize)
	local record: FieldRecord = {
		id = fieldId,
		player = context.player,
		slot = context.slot,
		field = field,
		center = boundsCFrame.Position,
		cframe = boundsCFrame,
		radius = radius,
		activeEndsAt = activeEndsAt,
		serial = serial,
	}

	local records = ACTIVE_FIELDS[context.player]
	if not records then
		records = {}
		ACTIVE_FIELDS[context.player] = records
	end
	table.insert(records, record)

	task.delay(durationSeconds + 0.05, function()
		local currentRecords = ACTIVE_FIELDS[context.player]
		if not currentRecords then
			return
		end
		for _, current in ipairs(currentRecords) do
			if current.id == fieldId and current.serial == serial then
				expireField(context.player, fieldId)
				return
			end
		end
	end)

	local state = context.slotState.state
	local fieldsPlaced = if typeof(state) == "table" and typeof(state.fieldsPlaced) == "number"
		then state.fieldsPlaced
		else 0

	return {
		state = {
			fieldsPlaced = fieldsPlaced + 1,
			lastPlacedAt = context.now,
		},
		effect = {
			name = "GravityFieldPlaced",
			payload = {
				fieldId = fieldId,
				cframe = boundsCFrame,
				radius = radius,
				activeEndsAt = activeEndsAt,
			},
		},
	}
end

function GravityField.OnProjectileStep(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	if not (typeof(payload) == "table" and typeof(payload.projectileId) == "string") then
		return AbilityResult.Continue()
	end

	local records = ACTIVE_FIELDS[context.player]
	if not records then
		return AbilityResult.Continue()
	end

	for index = #records, 1, -1 do
		local record = records[index]
		if context.now >= record.activeEndsAt then
			expireField(context.player, record.id)
			continue
		end
		if not record.field.Parent then
			table.remove(records, index)
			continue
		end

		local velocity = getDropVelocity(record, context.definition, payload)
		if velocity then
			return {
				kind = RESULT_KIND.ModifyProjectileVelocity,
				velocity = velocity,
				maxSpeed = getMaxDropSpeed(context.definition),
				maxFlightSeconds = BombConfig.ProjectileMaxFlightSeconds,
			}
		end
	end

	if #records == 0 then
		ACTIVE_FIELDS[context.player] = nil
	end

	return AbilityResult.Continue()
end

function GravityField.OnPlayerRemoving(player: Player)
	local records = ACTIVE_FIELDS[player]
	ACTIVE_FIELDS[player] = nil
	SERIALS[player] = nil
	if not records then
		return
	end

	for _, record in ipairs(records) do
		if record.field.Parent then
			record.field:Destroy()
		end
	end
end

return GravityField

