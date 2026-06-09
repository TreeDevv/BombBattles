local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityHookResult = AbilityTypes.AbilityHookResult
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext

type ActiveRecord = {
	character: Model,
	activeEndsAt: number,
	activeUntilAttribute: string,
	deathConnection: RBXScriptConnection?,
}

local GravityBoots = {} :: AbilityTypes.ServerBehavior

local DEFAULT_ACTIVE_UNTIL_ATTR = "GravityBoots_ActiveUntil"
local RESULT_KIND = AbilityResult.Kind
local ACTIVE_RECORDS: { [Player]: ActiveRecord } = {}

local function getActiveUntilAttribute(definition): string
	local attribute = definition and definition.activeUntilAttribute
	return if typeof(attribute) == "string" and attribute ~= "" then attribute else DEFAULT_ACTIVE_UNTIL_ATTR
end

local function getKnockbackMultiplier(definition): number
	return math.clamp(tonumber(definition and definition.knockbackMultiplier) or 0.25, 0, 1)
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
	ACTIVE_RECORDS[player] = record

	task.delay(math.max(activeEndsAt - workspace:GetServerTimeNow(), 0) + 0.1, function()
		local current = ACTIVE_RECORDS[player]
		if current and current.character == character and current.activeEndsAt == activeEndsAt then
			clearActiveRecord(player, character, activeEndsAt, activeUntilAttribute)
		end
	end)
end

local function isActiveForHook(context: ServerHookContext): boolean
	local record = ACTIVE_RECORDS[context.player]
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

local function getKnockbackResult(context: ServerHookContext): AbilityHookResult
	return {
		kind = RESULT_KIND.ModifyDamage,
		knockbackMultiplier = getKnockbackMultiplier(context.definition),
	}
end

function GravityBoots.CanActivate(context: ServerActivateContext): boolean
	local _character, _humanoid, rootPart = getCharacterParts(context.player)
	return rootPart ~= nil
end

function GravityBoots.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local character, humanoid, rootPart = getCharacterParts(context.player)
	if not (character and humanoid and rootPart) then
		return false
	end

	local durationSeconds = math.max(tonumber(context.definition.durationSeconds) or 0, 0)
	local activeEndsAt = context.now + durationSeconds
	setActiveWindow(context.player, character, humanoid, activeEndsAt, getActiveUntilAttribute(context.definition))

	local state = context.slotState.state
	local activationCount = if typeof(state) == "table" and typeof(state.activationCount) == "number"
		then state.activationCount
		else 0

	return {
		state = {
			activationCount = activationCount + 1,
			lastActivatedAt = context.now,
		},
	}
end

function GravityBoots.OnBeforePlayerBombDamage(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	if not (isActiveForHook(context) and typeof(payload) == "table" and payload.target == context.player) then
		return AbilityResult.Continue()
	end

	return getKnockbackResult(context)
end

function GravityBoots.OnBeforeOwnerBombKnockback(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	if not (isActiveForHook(context) and typeof(payload) == "table" and payload.owner == context.player) then
		return AbilityResult.Continue()
	end

	return getKnockbackResult(context)
end

function GravityBoots.OnPlayerRemoving(player: Player)
	clearActiveRecord(player, nil, nil, nil)
end

return GravityBoots
