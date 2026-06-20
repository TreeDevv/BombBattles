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

type ActiveRecord = {
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	slot: string,
	activeEndsAt: number,
	activeUntilAttribute: string,
	serial: number,
	deathConnection: RBXScriptConnection?,
}

local Infinity = {} :: AbilityTypes.ServerBehavior

local ABILITY_ID = "Infinity"
local DEFAULT_ACTIVE_UNTIL_ATTR = "Infinity_ActiveUntil"
local RESULT_KIND = AbilityResult.Kind
local ACTIVE_RECORDS: { [Player]: ActiveRecord } = {}
local SERIALS: { [Player]: number } = {}
local lastBlockPulseAt: { [Player]: number } = {}
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

local function getActiveUntilAttribute(definition: AbilityDefinition?): string
	local attribute = definition and definition.activeUntilAttribute
	return if typeof(attribute) == "string" and attribute ~= "" then attribute else DEFAULT_ACTIVE_UNTIL_ATTR
end

local function getCharacterParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return character, humanoid, rootPart
	end
	return character, humanoid, nil
end

local function clearActiveRecord(
	player: Player,
	expectedCharacter: Model?,
	expectedActiveEndsAt: number?,
	activeUntilAttribute: string?
)
	local record = ACTIVE_RECORDS[player]
	if record then
		if record.deathConnection then
			record.deathConnection:Disconnect()
		end
		ACTIVE_RECORDS[player] = nil
	end

	local character = expectedCharacter or (record and record.character)
	if not character then
		return
	end

	local attribute = activeUntilAttribute or (record and record.activeUntilAttribute) or DEFAULT_ACTIVE_UNTIL_ATTR
	local activeUntil = character:GetAttribute(attribute)
	if expectedActiveEndsAt == nil or activeUntil == expectedActiveEndsAt then
		character:SetAttribute(attribute, nil)
	end
end

local function setActiveWindow(
	player: Player,
	character: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	slot: string,
	activeEndsAt: number,
	activeUntilAttribute: string
)
	clearActiveRecord(player, nil, nil, nil)
	character:SetAttribute(activeUntilAttribute, activeEndsAt)

	local serial = (SERIALS[player] or 0) + 1
	SERIALS[player] = serial
	local record: ActiveRecord = {
		character = character,
		humanoid = humanoid,
		rootPart = rootPart,
		slot = slot,
		activeEndsAt = activeEndsAt,
		activeUntilAttribute = activeUntilAttribute,
		serial = serial,
		deathConnection = nil,
	}
	record.deathConnection = humanoid.Died:Connect(function()
		local current = ACTIVE_RECORDS[player]
		if current and current.serial == serial then
			clearActiveRecord(player, character, activeEndsAt, activeUntilAttribute)
		end
	end)
	ACTIVE_RECORDS[player] = record

	task.delay(math.max(activeEndsAt - workspace:GetServerTimeNow(), 0) + 0.1, function()
		local current = ACTIVE_RECORDS[player]
		if current and current.serial == serial then
			clearActiveRecord(player, character, activeEndsAt, activeUntilAttribute)
		end
	end)
end

local function getActiveRecord(context: ServerHookContext): ActiveRecord?
	local record = ACTIVE_RECORDS[context.player]
	if not record then
		return nil
	end
	if context.now >= record.activeEndsAt then
		clearActiveRecord(context.player, record.character, record.activeEndsAt, record.activeUntilAttribute)
		return nil
	end

	local character, humanoid, rootPart = getCharacterParts(context.player)
	if character ~= record.character or humanoid ~= record.humanoid or rootPart ~= record.rootPart then
		clearActiveRecord(context.player, record.character, record.activeEndsAt, record.activeUntilAttribute)
		return nil
	end

	local attribute = getActiveUntilAttribute(context.definition)
	local activeUntil = character:GetAttribute(attribute)
	if typeof(activeUntil) ~= "number" or activeUntil <= workspace:GetServerTimeNow() then
		clearActiveRecord(context.player, record.character, record.activeEndsAt, attribute)
		return nil
	end

	return record
end

local function copyState(state: any): { [string]: any }
	local nextState = {}
	if typeof(state) == "table" then
		for key, value in pairs(state) do
			nextState[key] = value
		end
	end
	return nextState
end

local function fireBlockPulse(context: ServerHookContext)
	local service = abilityService
	if not service then
		return
	end

	local throttleSeconds = math.max(tonumber(context.definition.blockPulseThrottleSeconds) or 0.16, 0)
	local lastPulse = lastBlockPulseAt[context.player]
	if typeof(lastPulse) == "number" and context.now - lastPulse < throttleSeconds then
		return
	end
	lastBlockPulseAt[context.player] = context.now

	local state = copyState(context.slotState.state)
	state.blocks = (tonumber(state.blocks) or 0) + 1
	state.lastBlockedAt = context.now
	service:SetSlotValues(context.player, context.slot, {
		state = state,
	})

	service:FireEffect("InfinityBlocked", {
		player = context.player,
		slot = context.slot,
		abilityId = ABILITY_ID,
		activeEndsAt = context.slotState.activeEndsAt,
	})
end

local function getBlockedResult(context: ServerHookContext): AbilityHookResult
	fireBlockPulse(context)
	return {
		kind = RESULT_KIND.Absorb,
		skipDamage = true,
		skipKnockback = true,
	}
end

local function isTargetedPlayerHook(context: ServerHookContext): boolean
	local payload = context.context
	return getActiveRecord(context) ~= nil and typeof(payload) == "table" and payload.target == context.player
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

local function getTargetTimeScale(definition: AbilityDefinition, distance: number, sweepRadius: number): number?
	local radius = math.max(tonumber(definition.radius) or 20, 0.1)
	if distance > radius + sweepRadius then
		return nil
	end

	local innerRadius = math.clamp(tonumber(definition.innerRadius) or 6, 0, radius)
	local minTimeScale = math.clamp(tonumber(definition.minTimeScale) or 0.03, 0.005, 1)
	if distance <= innerRadius then
		return minTimeScale
	end

	local alpha = math.clamp((distance - innerRadius) / math.max(radius - innerRadius, 0.001), 0, 1)
	local curvePower = math.max(tonumber(definition.timeScaleCurvePower) or 2.35, 0.1)
	local eased = 1 - ((1 - alpha) ^ curvePower)
	return minTimeScale + (1 - minTimeScale) * eased
end

function Infinity.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function Infinity.CanActivate(context: ServerActivateContext): boolean
	local _character, _humanoid, rootPart = getCharacterParts(context.player)
	return rootPart ~= nil and getTemplate(context.definition) ~= nil
end

function Infinity.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local character, humanoid, rootPart = getCharacterParts(context.player)
	if not (character and humanoid and rootPart) then
		return false
	end
	if not getTemplate(context.definition) then
		warn("[Infinity] Missing ReplicatedStorage.Assets.Abilities.Infinity.Infinity")
		return false
	end

	local durationSeconds = math.max(tonumber(context.definition.durationSeconds) or 0, 0)
	local activeEndsAt = context.now + durationSeconds
	lastBlockPulseAt[context.player] = nil
	setActiveWindow(
		context.player,
		character,
		humanoid,
		rootPart,
		context.slot,
		activeEndsAt,
		getActiveUntilAttribute(context.definition)
	)

	local state = copyState(context.slotState.state)
	state.activationCount = (tonumber(state.activationCount) or 0) + 1
	state.lastActivatedAt = context.now

	return {
		state = state,
	}
end

function Infinity.OnProjectileStep(context: ServerHookContext): AbilityHookResult
	local record = getActiveRecord(context)
	local payload = context.context
	if not (record and typeof(payload) == "table" and typeof(payload.projectileId) == "string") then
		return AbilityResult.Continue()
	end
	if payload.attached == true then
		return AbilityResult.Continue()
	end

	local position = if typeof(payload.position) == "Vector3" then payload.position else record.rootPart.Position
	local nextPosition = if typeof(payload.nextPosition) == "Vector3" then payload.nextPosition else position
	local sweepRadius = math.max(tonumber(payload.sweepRadius) or BombConfig.SweepRadius or 0, 0)
	local distance = getDistanceToSegment(record.rootPart.Position, position, nextPosition)
	local timeScale = getTargetTimeScale(context.definition, distance, sweepRadius)
	if not timeScale then
		return AbilityResult.Continue()
	end

	return {
		kind = RESULT_KIND.ModifyProjectileTimeScale,
		timeScale = timeScale,
		timeScaleSource = ABILITY_ID,
		timeScaleEnterRate = math.max(tonumber(context.definition.timeScaleEnterRate) or 7.5, 0.1),
		timeScaleExitRate = math.max(tonumber(context.definition.timeScaleExitRate) or 5.5, 0.1),
		infinityStrength = math.clamp(1 - timeScale, 0, 1),
	}
end

function Infinity.OnBeforePlayerDamage(context: ServerHookContext): AbilityHookResult
	if not isTargetedPlayerHook(context) then
		return AbilityResult.Continue()
	end

	return getBlockedResult(context)
end

function Infinity.OnBeforePlayerBombDamage(context: ServerHookContext): AbilityHookResult
	if not isTargetedPlayerHook(context) then
		return AbilityResult.Continue()
	end

	return getBlockedResult(context)
end

function Infinity.OnBeforeOwnerBombKnockback(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	if not (getActiveRecord(context) and typeof(payload) == "table" and payload.owner == context.player) then
		return AbilityResult.Continue()
	end

	return getBlockedResult(context)
end

function Infinity.OnPlayerRemoving(player: Player)
	clearActiveRecord(player, nil, nil, nil)
	SERIALS[player] = nil
	lastBlockPulseAt[player] = nil
end

return Infinity
