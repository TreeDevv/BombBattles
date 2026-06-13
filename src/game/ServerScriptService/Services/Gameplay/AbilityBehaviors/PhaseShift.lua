local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityHookResult = AbilityTypes.AbilityHookResult
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext

type ActiveRecord = {
	character: Model,
	activeEndsAt: number,
	activeUntilAttribute: string,
	deathConnection: RBXScriptConnection?,
}

local PhaseShift = {} :: AbilityTypes.ServerBehavior

local RESULT_KIND = AbilityResult.Kind
local DEFAULT_ACTIVE_UNTIL_ATTR = "PhaseShift_ActiveUntil"

local activeRecords: { [Player]: ActiveRecord } = {}
local lastBlockPulseAt: { [Player]: number } = {}
local abilityService: AbilityServiceLike? = nil

local function getActiveUntilAttribute(definition): string
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
	local record = activeRecords[player]
	if record then
		if record.deathConnection then
			record.deathConnection:Disconnect()
		end
		activeRecords[player] = nil
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
	activeEndsAt: number,
	activeUntilAttribute: string
)
	clearActiveRecord(player, nil, nil, nil)
	character:SetAttribute(activeUntilAttribute, activeEndsAt)

	local record: ActiveRecord = {
		character = character,
		activeEndsAt = activeEndsAt,
		activeUntilAttribute = activeUntilAttribute,
		deathConnection = nil,
	}
	record.deathConnection = humanoid.Died:Connect(function()
		clearActiveRecord(player, character, activeEndsAt, activeUntilAttribute)
	end)
	activeRecords[player] = record

	task.delay(math.max(activeEndsAt - workspace:GetServerTimeNow(), 0) + 0.1, function()
		local current = activeRecords[player]
		if current and current.character == character and current.activeEndsAt == activeEndsAt then
			clearActiveRecord(player, character, activeEndsAt, activeUntilAttribute)
		end
	end)
end

local function isActiveForHook(context: ServerHookContext): boolean
	local record = activeRecords[context.player]
	if not record or context.now >= record.activeEndsAt then
		clearActiveRecord(
			context.player,
			record and record.character or nil,
			record and record.activeEndsAt or nil,
			record and record.activeUntilAttribute or nil
		)
		return false
	end

	local character = context.player.Character
	if character ~= record.character then
		clearActiveRecord(context.player, record.character, record.activeEndsAt, record.activeUntilAttribute)
		return false
	end

	local attribute = getActiveUntilAttribute(context.definition)
	local activeUntil = character:GetAttribute(attribute)
	if typeof(activeUntil) ~= "number" or activeUntil <= workspace:GetServerTimeNow() then
		clearActiveRecord(context.player, record.character, record.activeEndsAt, attribute)
		return false
	end

	return true
end

local function fireBlockPulse(context: ServerHookContext)
	local service = abilityService
	if not service then
		return
	end

	local throttleSeconds = math.max(tonumber(context.definition.blockPulseThrottleSeconds) or 0.18, 0)
	local lastPulse = lastBlockPulseAt[context.player]
	if typeof(lastPulse) == "number" and context.now - lastPulse < throttleSeconds then
		return
	end
	lastBlockPulseAt[context.player] = context.now

	local state = context.slotState.state
	local blocks = if typeof(state) == "table" and typeof(state.blocks) == "number" then state.blocks else 0
	local activationCount = if typeof(state) == "table" and typeof(state.activationCount) == "number"
		then state.activationCount
		else 0
	local lastActivatedAt = if typeof(state) == "table" and typeof(state.lastActivatedAt) == "number"
		then state.lastActivatedAt
		else 0
	service:SetSlotValues(context.player, context.slot, {
		state = {
			activationCount = activationCount,
			blocks = blocks + 1,
			lastActivatedAt = lastActivatedAt,
			lastBlockedAt = context.now,
		},
	})

	service:FireEffect("PhaseShiftBlocked", {
		player = context.player,
		slot = context.slot,
		abilityId = context.abilityId,
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
	return isActiveForHook(context) and typeof(payload) == "table" and payload.target == context.player
end

function PhaseShift.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function PhaseShift.CanActivate(context: ServerActivateContext): boolean
	local _character, _humanoid, rootPart = getCharacterParts(context.player)
	return rootPart ~= nil
end

function PhaseShift.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local character, humanoid, rootPart = getCharacterParts(context.player)
	if not (character and humanoid and rootPart) then
		return false
	end

	local durationSeconds = math.max(tonumber(context.definition.durationSeconds) or 0, 0)
	local activeEndsAt = context.now + durationSeconds
	lastBlockPulseAt[context.player] = nil
	setActiveWindow(context.player, character, humanoid, activeEndsAt, getActiveUntilAttribute(context.definition))

	local state = context.slotState.state
	local activationCount = if typeof(state) == "table" and typeof(state.activationCount) == "number"
		then state.activationCount
		else 0
	local blocks = if typeof(state) == "table" and typeof(state.blocks) == "number" then state.blocks else 0

	return {
		state = {
			activationCount = activationCount + 1,
			blocks = blocks,
			lastActivatedAt = context.now,
			lastBlockedAt = if typeof(state) == "table" and typeof(state.lastBlockedAt) == "number"
				then state.lastBlockedAt
				else 0,
		},
	}
end

function PhaseShift.OnBeforePlayerDamage(context: ServerHookContext): AbilityHookResult
	if not isTargetedPlayerHook(context) then
		return AbilityResult.Continue()
	end

	return getBlockedResult(context)
end

function PhaseShift.OnBeforePlayerBombDamage(context: ServerHookContext): AbilityHookResult
	if not isTargetedPlayerHook(context) then
		return AbilityResult.Continue()
	end

	return getBlockedResult(context)
end

function PhaseShift.OnBeforeOwnerBombKnockback(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	if not (isActiveForHook(context) and typeof(payload) == "table" and payload.owner == context.player) then
		return AbilityResult.Continue()
	end

	return getBlockedResult(context)
end

function PhaseShift.OnPlayerRemoving(player: Player)
	clearActiveRecord(player, nil, nil, nil)
	lastBlockPulseAt[player] = nil
end

return PhaseShift
