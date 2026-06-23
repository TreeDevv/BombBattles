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
type ShieldRecord = {
	id: string,
	player: Player,
	slot: string,
	shield: Instance,
	cframe: CFrame,
	size: Vector3,
	activeEndsAt: number,
	serial: number,
	reflectedAt: { [string]: number },
	deathConnection: RBXScriptConnection?,
}

local ReflectShield = {} :: AbilityTypes.ServerBehavior

local RESULT_KIND = AbilityResult.Kind
local FOLDER_NAME = "AbilityObjects"
local SHIELD_FOLDER_NAME = "ReflectShield"
local OWNER_ATTR = "ReflectShieldOwnerUserId"
local ID_ATTR = "ReflectShieldId"
local ACTIVE_SHIELDS: { [Player]: { ShieldRecord } } = {}
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

local function getShieldFolder(player: Player): Folder
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

	local shieldFolder = abilityFolder:FindFirstChild(SHIELD_FOLDER_NAME)
	if shieldFolder and shieldFolder:IsA("Folder") then
		return shieldFolder
	end
	if shieldFolder then
		shieldFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = SHIELD_FOLDER_NAME
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

local function alignCloneInFrontOfRoot(clone: Instance, rootPart: BasePart, definition: AbilityDefinition): (CFrame, Vector3)
	local distance = tonumber(definition.placementDistance) or 8
	local targetPosition = rootPart.Position + rootPart.CFrame.LookVector * distance
	local targetCFrame = rootPart.CFrame + (targetPosition - rootPart.Position)
	pivotTo(clone, targetCFrame)

	local boundsCFrame = getBounds(clone)
	local centeredCFrame = targetCFrame + (targetPosition - boundsCFrame.Position)
	pivotTo(clone, centeredCFrame)

	return getBounds(clone)
end

local function getPlacementSize(boundsSize: Vector3, definition: AbilityDefinition): Vector3
	local thickness = math.max(tonumber(definition.reflectionThickness) or boundsSize.Z, 0.1)
	return Vector3.new(boundsSize.X, boundsSize.Y, math.min(boundsSize.Z, thickness))
end

local function isProtectedOrCharacter(part: BasePart): boolean
	if hasUnsafeTaggedAncestor(part) then
		return true
	end

	local model = part:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local function isPlacementClear(boundsCFrame: CFrame, boundsSize: Vector3, floor: Instance, definition: AbilityDefinition): boolean
	local placementSize = getPlacementSize(boundsSize, definition)
	local up = boundsCFrame.UpVector
	local overlapSize = Vector3.new(
		math.max(placementSize.X * 0.95, 0.1),
		math.max(placementSize.Y - 0.25, 0.1),
		math.max(placementSize.Z * 0.95, 0.1)
	)
	local overlapCFrame = boundsCFrame + up * 0.18

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	params.RespectCanCollide = true

	for _, part in ipairs(workspace:GetPartBoundsInBox(overlapCFrame, overlapSize, params)) do
		if part == floor or part:IsDescendantOf(floor) then
			continue
		end
		if isProtectedOrCharacter(part) then
			return false
		end
		if part.CanCollide and part.Transparency < 1 then
			return false
		end
	end

	return true
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

local function prepareShield(shield: Instance)
	for _, part in ipairs(getBaseParts(shield)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
	end
end

local function getNextShieldId(player: Player): (string, number)
	local serial = (SERIALS[player] or 0) + 1
	SERIALS[player] = serial
	return string.format("ReflectShield_%d_%d", player.UserId, serial), serial
end

local function removeRecord(player: Player, shieldId: string): ShieldRecord?
	local records = ACTIVE_SHIELDS[player]
	if not records then
		return nil
	end

	for index = #records, 1, -1 do
		local record = records[index]
		if record.id == shieldId then
			table.remove(records, index)
			if #records == 0 then
				ACTIVE_SHIELDS[player] = nil
			end
			return record
		end
	end

	return nil
end

local function expireShield(player: Player, shieldId: string)
	local record = removeRecord(player, shieldId)
	if not record then
		return
	end

	local service = abilityService
	if record.deathConnection then
		record.deathConnection:Disconnect()
		record.deathConnection = nil
	end
	if service then
		service:FireEffect("ReflectShieldExpired", {
			player = player,
			slot = record.slot,
			abilityId = "ReflectShield",
			shieldId = record.id,
		})
	end

	if record.shield.Parent then
		record.shield:Destroy()
	end
end

local function fireReflect(record: ShieldRecord, position: Vector3)
	local service = abilityService
	if not service then
		return
	end

	service:FireEffect("ReflectShieldReflected", {
		player = record.player,
		slot = record.slot,
		abilityId = "ReflectShield",
		shieldId = record.id,
		position = position,
	})
end

local function clipAxis(start: number, delta: number, halfExtent: number, tMin: number, tMax: number): (boolean, number, number)
	if math.abs(delta) < 0.0001 then
		return math.abs(start) <= halfExtent, tMin, tMax
	end

	local inv = 1 / delta
	local near = (-halfExtent - start) * inv
	local far = (halfExtent - start) * inv
	if near > far then
		near, far = far, near
	end

	tMin = math.max(tMin, near)
	tMax = math.min(tMax, far)
	return tMin <= tMax, tMin, tMax
end

local function getSegmentBoxHit(cframe: CFrame, size: Vector3, fromPosition: Vector3, toPosition: Vector3, padding: number): (boolean, Vector3)
	local from = cframe:PointToObjectSpace(fromPosition)
	local to = cframe:PointToObjectSpace(toPosition)
	local delta = to - from
	local half = size * 0.5 + Vector3.new(padding, padding, padding)
	local tMin = 0
	local tMax = 1

	local ok
	ok, tMin, tMax = clipAxis(from.X, delta.X, half.X, tMin, tMax)
	if not ok then
		return false, fromPosition
	end
	ok, tMin, tMax = clipAxis(from.Y, delta.Y, half.Y, tMin, tMax)
	if not ok then
		return false, fromPosition
	end
	ok, tMin, tMax = clipAxis(from.Z, delta.Z, half.Z, tMin, tMax)
	if not ok then
		return false, fromPosition
	end

	return true, fromPosition + (toPosition - fromPosition) * math.clamp(tMin, 0, 1)
end

local function readVector(value: any, fallback: Vector3): Vector3
	if typeof(value) == "Vector3" and value.Magnitude < math.huge then
		return value
	end
	return fallback
end

local function getReflectedDirection(record: ShieldRecord, velocity: Vector3): Vector3?
	if velocity.Magnitude <= 0.05 then
		return nil
	end

	local normal = record.cframe.LookVector
	if velocity:Dot(normal) > 0 then
		normal = -normal
	end

	local reflected = velocity - 2 * velocity:Dot(normal) * normal
	if reflected.Magnitude <= 0.05 then
		reflected = -velocity
	end
	if reflected.Magnitude <= 0.05 then
		return nil
	end
	return reflected.Unit
end

local function getReflectSpeed(definition: AbilityDefinition, velocity: Vector3): number
	local multiplier = math.max(tonumber(definition.reflectSpeedMultiplier) or 1, 0)
	local minSpeed = math.max(tonumber(definition.reflectMinLaunchSpeed) or 70, 1)
	local maxSpeed = math.max(tonumber(definition.reflectMaxLaunchSpeed) or 190, minSpeed)
	return math.clamp(velocity.Magnitude * multiplier, minSpeed, maxSpeed)
end

function ReflectShield.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function ReflectShield.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getTemplate(context.definition) ~= nil
end

function ReflectShield.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local definition = context.definition
	local template = getTemplate(definition)
	if not template then
		warn("[ReflectShield] Missing ReplicatedStorage.Assets.Abilities.ReflectShield.Reflect Shield")
		return false
	end

	local floor, boundsCFrame, boundsSize = validatePlacement(context.player, definition, template, context.payload)
	if not (floor and boundsCFrame and boundsSize) then
		return false
	end

	local shield = template:Clone()
	local shieldId, serial = getNextShieldId(context.player)
	shield.Name = shieldId
	shield:SetAttribute(ID_ATTR, shieldId)
	shield:SetAttribute(OWNER_ATTR, context.player.UserId)
	shield:SetAttribute("AbilityId", context.abilityId)
	alignCloneToFloor(shield, floor)
	if boundsSize.X <= 0 or boundsSize.Y <= 0 or boundsSize.Z <= 0 then
		shield:Destroy()
		return false
	end
	prepareShield(shield)
	shield.Parent = getShieldFolder(context.player)

	local durationSeconds = math.max(tonumber(definition.durationSeconds) or 0, 0)
	local activeEndsAt = context.now + durationSeconds
	local record: ShieldRecord = {
		id = shieldId,
		player = context.player,
		slot = context.slot,
		shield = shield,
		cframe = boundsCFrame,
		size = getPlacementSize(boundsSize, definition),
		activeEndsAt = activeEndsAt,
		serial = serial,
		reflectedAt = {},
		deathConnection = nil,
	}

	local records = ACTIVE_SHIELDS[context.player]
	if not records then
		records = {}
		ACTIVE_SHIELDS[context.player] = records
	end
	table.insert(records, record)

	local character = context.player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		record.deathConnection = humanoid.Died:Connect(function()
			expireShield(context.player, shieldId)
		end)
	end

	task.delay(durationSeconds + 0.05, function()
		local currentRecords = ACTIVE_SHIELDS[context.player]
		if not currentRecords then
			return
		end
		for _, current in ipairs(currentRecords) do
			if current.id == shieldId and current.serial == serial then
				expireShield(context.player, shieldId)
				return
			end
		end
	end)

	local state = context.slotState.state
	local shieldsPlaced = if typeof(state) == "table" and typeof(state.shieldsPlaced) == "number"
		then state.shieldsPlaced
		else 0

	return {
		state = {
			shieldsPlaced = shieldsPlaced + 1,
			lastPlacedAt = context.now,
		},
		effect = {
			name = "ReflectShieldPlaced",
			payload = {
				shieldId = shieldId,
				position = boundsCFrame.Position,
				cframe = boundsCFrame,
				activeEndsAt = activeEndsAt,
			},
		},
	}
end

function ReflectShield.OnProjectileStep(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	if not (typeof(payload) == "table" and typeof(payload.projectileId) == "string") then
		return AbilityResult.Continue()
	end
	if payload.owner == context.player then
		return AbilityResult.Continue()
	end

	local records = ACTIVE_SHIELDS[context.player]
	if not records then
		return AbilityResult.Continue()
	end
	if not getCharacterRoot(context.player) then
		for index = #records, 1, -1 do
			expireShield(context.player, records[index].id)
		end
		return AbilityResult.Continue()
	end

	local position = readVector(payload.position, Vector3.zero)
	local nextPosition = readVector(payload.nextPosition, position)
	local velocity = readVector(payload.currentVelocity, nextPosition - position)
	local sweepRadius = math.max(tonumber(payload.sweepRadius) or BombConfig.SweepRadius or 0, 0)
	local reflectCooldown = math.max(tonumber(context.definition.reflectCooldownSeconds) or 0.25, 0)
	local projectileId = payload.projectileId

	for index = #records, 1, -1 do
		local record = records[index]
		if context.now >= record.activeEndsAt then
			expireShield(context.player, record.id)
			continue
		end
		if not record.shield.Parent then
			table.remove(records, index)
			continue
		end

		local didHit, hitPosition = getSegmentBoxHit(record.cframe, record.size, position, nextPosition, sweepRadius)
		if not didHit then
			continue
		end

		local lastReflectedAt = record.reflectedAt[projectileId]
		if typeof(lastReflectedAt) == "number" and context.now - lastReflectedAt < reflectCooldown then
			continue
		end

		local aimDirection = getReflectedDirection(record, velocity)
		if not aimDirection then
			continue
		end

		record.reflectedAt[projectileId] = context.now
		fireReflect(record, hitPosition)

		local surfaceOffset = math.max(tonumber(context.definition.reflectSurfaceOffset) or 1.15, 0)
		return {
			kind = RESULT_KIND.RedirectProjectile,
			owner = context.player,
			sourceType = "Ability",
			sourceId = "ReflectShield",
			reflected = true,
			origin = hitPosition + aimDirection * (sweepRadius + surfaceOffset),
			aimDirection = aimDirection,
			launchSpeed = getReflectSpeed(context.definition, velocity),
			upwardVelocity = context.definition.reflectUpwardVelocity,
			maxFlightSeconds = context.definition.reflectMaxFlightSeconds,
		}
	end

	if #records == 0 then
		ACTIVE_SHIELDS[context.player] = nil
	end

	return AbilityResult.Continue()
end

function ReflectShield.OnPlayerRemoving(player: Player)
	local records = ACTIVE_SHIELDS[player]
	ACTIVE_SHIELDS[player] = nil
	SERIALS[player] = nil
	if not records then
		return
	end

	for _, record in ipairs(records) do
		if record.deathConnection then
			record.deathConnection:Disconnect()
			record.deathConnection = nil
		end
		if record.shield.Parent then
			record.shield:Destroy()
		end
	end
end

return ReflectShield
