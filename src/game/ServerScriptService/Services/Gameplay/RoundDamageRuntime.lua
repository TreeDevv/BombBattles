local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local StudioAICombatants = require(ServerScriptService.Services.StudioAICombatants)

local RoundDamageRuntime = {}

local function readString(sourceContext, key: string): string?
	return if typeof(sourceContext) == "table" and typeof(sourceContext[key]) == "string" then sourceContext[key] else nil
end

local function buildContributor(attackerIdentity, sourceContext)
	return {
		damagedAt = workspace:GetServerTimeNow(),
		teamName = attackerIdentity.teamName,
		sourceType = readString(sourceContext, "sourceType"),
		sourceId = readString(sourceContext, "sourceId"),
		bombId = readString(sourceContext, "bombId"),
		bombType = readString(sourceContext, "bombType"),
		abilityName = if readString(sourceContext, "abilityName") then readString(sourceContext, "abilityName")
			elseif
				typeof(sourceContext) == "table"
				and sourceContext.sourceType == "Ability"
				and typeof(sourceContext.sourceId) == "string"
			then sourceContext.sourceId
			else nil,
		abilityId = if readString(sourceContext, "abilityId") then readString(sourceContext, "abilityId")
			elseif
				typeof(sourceContext) == "table"
				and sourceContext.sourceType == "Ability"
				and typeof(sourceContext.sourceId) == "string"
			then sourceContext.sourceId
			else nil,
		directHit = if typeof(sourceContext) == "table" and sourceContext.directHit == true then true else nil,
		sourceDetail = readString(sourceContext, "sourceDetail"),
	}
end

local function getAttackerIdentity(attacker, target: Player, getTrackedTeamName)
	if typeof(attacker) == "Instance" and attacker:IsA("Player") and attacker.Parent == Players then
		if attacker == target then
			return nil
		end
		return {
			userId = attacker.UserId,
			teamName = getTrackedTeamName(attacker),
			isPlayer = true,
		}
	elseif StudioAICombatants.IsBotOwner(attacker) then
		return StudioAICombatants.GetOwnerIdentity(attacker)
	end

	return nil
end

function RoundDamageRuntime.RecordPlayerDamage(options)
	local target: Player = options.target
	if not options.isRoundActive then
		return false
	end
	if not (target and target.Parent == Players) then
		return false
	end
	if not options.isPlayerActive(target) then
		return false
	end
	if typeof(options.damage) ~= "number" or options.damage ~= options.damage or options.damage <= 0 then
		return false
	end

	local attackerIdentity = getAttackerIdentity(options.attacker, target, options.getTrackedTeamName)
	if not attackerIdentity or typeof(attackerIdentity.userId) ~= "number" then
		return false
	end

	if attackerIdentity.isPlayer then
		local attackerStats = options.getScoreboardStatsFor(options.attacker)
		attackerStats.damage += options.damage
	end

	local attackerKey = tostring(attackerIdentity.userId)
	options.scoreboardState:RecordContributor(
		target,
		attackerKey,
		buildContributor(attackerIdentity, options.sourceContext)
	)

	options.syncScoreboardStats()
	return true
end

function RoundDamageRuntime.RecordMapDestruction(options)
	if not options.isRoundActive then
		return
	end
	if typeof(options.sourceContext) ~= "table" or typeof(options.sourceContext.ownerUserId) ~= "number" then
		return
	end
	if typeof(options.targetsHit) ~= "number" or options.targetsHit <= 0 then
		return
	end

	local player = Players:GetPlayerByUserId(options.sourceContext.ownerUserId)
	if not (player and player.Parent == Players and options.roundPlayers[player]) then
		return
	end

	local stats = options.getScoreboardStatsFor(player)
	local value = options.roundNonNegative(options.targetsHit)
	stats.destruction += value
	options.syncScoreboardStats()

	local payload = {
		value = value,
		roundId = options.roundId,
		timestamp = workspace:GetServerTimeNow(),
	}
	if typeof(options.position) == "Vector3" then
		payload.position = options.position
	end
	options.getDestructionScoreRemote():FireClient(player, payload)
end

return table.freeze(RoundDamageRuntime)
