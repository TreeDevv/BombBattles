local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local PlacementSurfaceUtil = require(ReplicatedStorage.Shared.Common.PlacementSurfaceUtil)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
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
	normal: Vector3,
	floor: Instance?,
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
	projectileTimes: { [string]: number },
}

local MagnetField = {} :: AbilityTypes.ServerBehavior

local RESULT_KIND = AbilityResult.Kind
local FOLDER_NAME = "AbilityObjects"
local FIELD_FOLDER_NAME = "MagnetField"
local OWNER_ATTR = "MagnetFieldOwnerUserId"
local ID_ATTR = "MagnetFieldId"
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

local function getFieldFolder(player: Player): Folder
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

local function isFiniteVector(value: any): boolean
	return typeof(value) == "Vector3" and value.X == value.X and value.Y == value.Y and value.Z == value.Z
end

local function getRequestedPlacement(player: Player, rootPart: BasePart, definition: AbilityDefinition, payload: any): (Vector3?, Vector3?)
	if typeof(payload) ~= "table" or not isFiniteVector(payload.floorPosition) then
		return nil, nil
	end

	local floorPosition = payload.floorPosition
	local maxDistance = math.max(tonumber(definition.placementDistance) or 8, 0) + 4
	if (floorPosition - rootPart.Position).Magnitude > maxDistance then
		return nil, nil
	end

	local facing = flattenDirection(if isFiniteVector(payload.facing) then payload.facing else rootPart.CFrame.LookVector)
	return floorPosition, facing
end

local function findFloor(player: Player, rootPart: BasePart, definition: AbilityDefinition, payload: any): FloorPlacement?
	local _ = player
	return PlacementSurfaceUtil.ResolveRootPlacement({
		rootPart = rootPart,
		definition = definition,
		payload = payload,
	})
end

local function alignCloneToFloor(clone: Instance, placement: FloorPlacement): (CFrame, Vector3)
	local pivot = PlacementSurfaceUtil.GetFloorPivot(placement.position, placement.facing, placement.normal)
	PlacementSurfaceUtil.PivotTo(clone, pivot)
	local boundsCFrame = getBounds(clone)
	PlacementSurfaceUtil.PivotTo(clone, pivot + (placement.position - boundsCFrame.Position))
	return getBounds(clone)
end

local function alignCloneToRootPosition(clone: Instance, rootPart: BasePart): (CFrame, Vector3)
	local rootCFrame = rootPart.CFrame
	pivotTo(clone, rootCFrame)

	local boundsCFrame = getBounds(clone)
	local centeredCFrame = rootCFrame + (rootPart.Position - boundsCFrame.Position)
	pivotTo(clone, centeredCFrame)

	return getBounds(clone)
end

local function validatePlacement(player: Player, definition: AbilityDefinition, template: Instance, payload: any): (FloorPlacement?, CFrame?, Vector3?)
	local rootPart = getCharacterRoot(player)
	if not rootPart then
		return nil, nil, nil
	end

	local floor = findFloor(player, rootPart, definition, payload)
	if not floor then
		return nil, nil, nil
	end

	local clone = template:Clone()
	local boundsCFrame, boundsSize = alignCloneToFloor(clone, floor)
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
	return string.format("MagnetField_%d_%d", player.UserId, serial), serial
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
		service:FireEffect("MagnetFieldExpired", {
			player = player,
			slot = record.slot,
			abilityId = "MagnetField",
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

local function getPullVelocity(record: FieldRecord, definition: AbilityDefinition, payload, currentTime: number): Vector3?
	if payload.attached == true then
		return nil
	end

	local position = readVector(payload.position, Vector3.zero)
	local nextPosition = readVector(payload.nextPosition, position)
	local velocity = readVector(payload.currentVelocity, nextPosition - position)
	local sweepRadius = math.max(tonumber(payload.sweepRadius) or BombConfig.SweepRadius or 0, 0)
	local offset = record.center - position
	local distance = offset.Magnitude
	if distance > record.radius + sweepRadius then
		return nil
	end

	local projectileId = payload.projectileId
	local lastTime = if typeof(projectileId) == "string" then record.projectileTimes[projectileId] else nil
	local dt = if typeof(payload.deltaTime) == "number" and payload.deltaTime > 0
		then payload.deltaTime
		elseif typeof(lastTime) == "number"
			then currentTime - lastTime
			else 1 / 60
	dt = math.clamp(dt, 1 / 240, 0.12)
	if typeof(projectileId) == "string" then
		record.projectileTimes[projectileId] = currentTime
	end

	if distance <= 0.05 then
		return velocity * math.clamp(tonumber(definition.captureDamping) or 0.68, 0, 1)
	end

	local direction = offset.Unit
	local maxSpeed = math.max(tonumber(definition.maxPullSpeed) or 95, 1)
	local responsiveness = math.max(tonumber(definition.pullResponsiveness) or 5.5, 0)
	local captureRadius = math.max(tonumber(definition.captureRadius) or 2.75, 0.1)

	if distance <= captureRadius then
		local damping = math.clamp(tonumber(definition.captureDamping) or 0.68, 0, 1)
		local desired = direction * math.min(maxSpeed * 0.3, distance * 10)
		return velocity:Lerp(desired, math.clamp(responsiveness * dt, 0, 1)) * damping
	end

	local desired = direction * maxSpeed
	local falloff = math.clamp(1 - distance / math.max(record.radius, 0.1), 0, 1)
	local alpha = math.clamp(responsiveness * dt * (0.45 + falloff * 0.55), 0, 0.45)
	return velocity:Lerp(desired, alpha)
end

function MagnetField.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function MagnetField.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getTemplate(context.definition) ~= nil
end

function MagnetField.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local definition = context.definition
	local template = getTemplate(definition)
	if not template then
		warn("[MagnetField] Missing ReplicatedStorage.Assets.Abilities.MagnetField.Magnet Field")
		return false
	end

	local floor, boundsCFrame, boundsSize = validatePlacement(context.player, definition, template, context.payload)
	if not (floor and boundsCFrame and boundsSize) then
		return false
	end

	local field = template:Clone()
	local fieldId, serial = getNextFieldId(context.player)
	field.Name = fieldId
	field:SetAttribute(ID_ATTR, fieldId)
	field:SetAttribute(OWNER_ATTR, context.player.UserId)
	field:SetAttribute("AbilityId", context.abilityId)
	alignCloneToFloor(field, floor)
	if boundsSize.X <= 0 or boundsSize.Y <= 0 or boundsSize.Z <= 0 then
		field:Destroy()
		return false
	end
	prepareField(field)
	field.Parent = getFieldFolder(context.player)

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
		projectileTimes = {},
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
			name = "MagnetFieldPlaced",
			payload = {
				fieldId = fieldId,
				cframe = boundsCFrame,
				radius = radius,
				activeEndsAt = activeEndsAt,
			},
		},
	}
end

function MagnetField.OnProjectileStep(context: ServerHookContext): AbilityHookResult
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

		local velocity = getPullVelocity(record, context.definition, payload, context.now)
		if velocity then
			return {
				kind = RESULT_KIND.ModifyProjectileVelocity,
				velocity = velocity,
				maxSpeed = context.definition.maxPullSpeed,
				maxFlightSeconds = BombConfig.ProjectileMaxFlightSeconds,
			}
		end
	end

	if #records == 0 then
		ACTIVE_FIELDS[context.player] = nil
	end

	return AbilityResult.Continue()
end

function MagnetField.OnPlayerRemoving(player: Player)
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

return MagnetField
