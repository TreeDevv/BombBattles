local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityHookResult = AbilityTypes.AbilityHookResult
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext
type FieldRecord = {
	id: string,
	player: Player,
	slot: string,
	center: Vector3,
	cframe: CFrame,
	radius: number,
	startedAt: number,
	activeEndsAt: number,
	serial: number,
	capturedProjectiles: { [string]: boolean },
}
type CaptureRecord = {
	fieldId: string,
	activeEndsAt: number,
}

local TimeBubble = {} :: AbilityTypes.ServerBehavior

local RESULT_KIND = AbilityResult.Kind
local ACTIVE_FIELDS: { [Player]: { FieldRecord } } = {}
local SERIALS: { [Player]: number } = {}
local CAPTURED_PROJECTILES: { [string]: CaptureRecord } = {}
local RELEASED_AT: { [string]: number } = {}
local RELEASE_TTL_SECONDS = math.max((BombConfig.FuseSeconds or 3) + (BombConfig.ProjectileLifetimePadding or 0) + 10, 15)
local abilityService: AbilityServiceLike? = nil

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

local function getRadius(definition: AbilityDefinition?): number
	return math.max(tonumber(definition and definition.radius) or 18, 1)
end

local function getNextFieldId(player: Player): (string, number)
	local serial = (SERIALS[player] or 0) + 1
	SERIALS[player] = serial
	return string.format("TimeBubble_%d_%d", player.UserId, serial), serial
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

local function getClosestPointOnSegment(point: Vector3, startPosition: Vector3, endPosition: Vector3): Vector3
	local segment = endPosition - startPosition
	local lengthSquared = segment:Dot(segment)
	if lengthSquared <= 0.0001 then
		return startPosition
	end

	local alpha = math.clamp((point - startPosition):Dot(segment) / lengthSquared, 0, 1)
	return startPosition + segment * alpha
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

local function markReleased(projectileId: string, releaseTime: number)
	RELEASED_AT[projectileId] = releaseTime
	task.delay(RELEASE_TTL_SECONDS, function()
		if RELEASED_AT[projectileId] == releaseTime then
			RELEASED_AT[projectileId] = nil
		end
	end)
end

local function expireField(player: Player, fieldId: string, currentTime: number?)
	local record = removeRecord(player, fieldId)
	if not record then
		return
	end

	local releaseTime = currentTime or record.activeEndsAt
	for projectileId in pairs(record.capturedProjectiles) do
		local capture = CAPTURED_PROJECTILES[projectileId]
		if capture and capture.fieldId == record.id then
			CAPTURED_PROJECTILES[projectileId] = nil
			markReleased(projectileId, releaseTime)
		end
	end

	local service = abilityService
	if service then
		service:FireEffect("TimeBubbleExpired", {
			player = player,
			slot = record.slot,
			abilityId = "TimeBubble",
			fieldId = record.id,
		})
	end
end

local function getProjectileFreezePosition(record: FieldRecord, payload): Vector3?
	local position = payload.position
	if typeof(position) ~= "Vector3" then
		return nil
	end

	local nextPosition = if typeof(payload.nextPosition) == "Vector3" then payload.nextPosition else position
	local sweepRadius = math.max(tonumber(payload.sweepRadius) or BombConfig.SweepRadius or 0, 0)
	if getDistanceToSegment(record.center, position, nextPosition) > record.radius + sweepRadius then
		return nil
	end

	return getClosestPointOnSegment(record.center, position, nextPosition)
end

function TimeBubble.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function TimeBubble.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getTemplate(context.definition) ~= nil
end

function TimeBubble.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local rootPart = getCharacterRoot(context.player)
	if not rootPart then
		return false
	end
	if not getTemplate(context.definition) then
		warn("[TimeBubble] Missing ReplicatedStorage.Assets.Abilities.TimeBubble.Time Bubble")
		return false
	end

	local durationSeconds = math.max(tonumber(context.definition.durationSeconds) or 0, 0)
	local activeEndsAt = context.now + durationSeconds
	local center = rootPart.Position
	local fieldId, serial = getNextFieldId(context.player)
	local record: FieldRecord = {
		id = fieldId,
		player = context.player,
		slot = context.slot,
		center = center,
		cframe = CFrame.new(center),
		radius = getRadius(context.definition),
		startedAt = context.now,
		activeEndsAt = activeEndsAt,
		serial = serial,
		capturedProjectiles = {},
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
				expireField(context.player, fieldId, workspace:GetServerTimeNow())
				return
			end
		end
	end)

	local state = context.slotState.state
	local bubblesCreated = if typeof(state) == "table" and typeof(state.bubblesCreated) == "number"
		then state.bubblesCreated
		else 0

	return {
		state = {
			bubblesCreated = bubblesCreated + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "TimeBubbleCreated",
			payload = {
				fieldId = fieldId,
				cframe = record.cframe,
				radius = record.radius,
				activeEndsAt = activeEndsAt,
			},
		},
	}
end

function TimeBubble.OnProjectileStep(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	if not (typeof(payload) == "table" and typeof(payload.projectileId) == "string") then
		return AbilityResult.Continue()
	end
	if payload.owner == context.player then
		return AbilityResult.Continue()
	end

	local projectileId = payload.projectileId
	local capture = CAPTURED_PROJECTILES[projectileId]
	if capture and context.now < capture.activeEndsAt then
		return AbilityResult.Continue()
	elseif capture then
		CAPTURED_PROJECTILES[projectileId] = nil
		markReleased(projectileId, context.now)
	end

	local records = ACTIVE_FIELDS[context.player]
	if not records then
		return AbilityResult.Continue()
	end

	for index = #records, 1, -1 do
		local record = records[index]
		if context.now >= record.activeEndsAt then
			expireField(context.player, record.id, context.now)
			continue
		end

		local releasedAt = RELEASED_AT[projectileId]
		if releasedAt and record.startedAt <= releasedAt then
			continue
		end

		local freezePosition = getProjectileFreezePosition(record, payload)
		if freezePosition then
			record.capturedProjectiles[projectileId] = true
			CAPTURED_PROJECTILES[projectileId] = {
				fieldId = record.id,
				activeEndsAt = record.activeEndsAt,
			}

			return {
				kind = RESULT_KIND.FreezeProjectile,
				frozenUntil = record.activeEndsAt,
				frozenBy = record.id,
				velocity = if typeof(payload.currentVelocity) == "Vector3" then payload.currentVelocity else Vector3.zero,
				position = freezePosition,
			}
		end
	end

	if #records == 0 then
		ACTIVE_FIELDS[context.player] = nil
	end

	return AbilityResult.Continue()
end

function TimeBubble.OnPlayerRemoving(player: Player)
	local records = ACTIVE_FIELDS[player]
	ACTIVE_FIELDS[player] = nil
	SERIALS[player] = nil
	if not records then
		return
	end

	local currentTime = workspace:GetServerTimeNow()
	for _, record in ipairs(records) do
		for projectileId in pairs(record.capturedProjectiles) do
			local capture = CAPTURED_PROJECTILES[projectileId]
			if capture and capture.fieldId == record.id then
				CAPTURED_PROJECTILES[projectileId] = nil
				markReleased(projectileId, currentTime)
			end
		end
	end
end

return TimeBubble
