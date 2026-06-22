local ServerScriptService = game:GetService("ServerScriptService")

local StudioAICombatants = require(ServerScriptService.Services.StudioAICombatants)

local RoundDeathRuntime = {}

local finisherService = nil

local function getFinisherService()
	if finisherService then
		return finisherService
	end

	finisherService = require(ServerScriptService.Services.FinisherService)
	return finisherService
end

local function isRecentEnemyContributor(options, attackerKey: string, contributor, victim: Player, currentTime: number): boolean
	if attackerKey == options.getPlayerKey(victim) then
		return false
	end
	if typeof(contributor) ~= "table" or typeof(contributor.damagedAt) ~= "number" then
		return false
	end
	if currentTime - contributor.damagedAt > options.assistWindowSeconds then
		return false
	end

	local victimTeam = options.getTrackedTeamName(victim)
	if not victimTeam then
		return true
	end

	return contributor.teamName ~= victimTeam
end

local function getKillerHealth(eliminatorPlayer: Player?): (number?, number?)
	if not (eliminatorPlayer and eliminatorPlayer.Character) then
		return nil, nil
	end

	local killerHumanoid = eliminatorPlayer.Character:FindFirstChildOfClass("Humanoid")
	if not killerHumanoid then
		return nil, nil
	end

	return killerHumanoid.Health, killerHumanoid.MaxHealth
end

local function getFinisher(eliminatorPlayer: Player?, deathPosition: Vector3?): (string, any)
	if not (eliminatorPlayer and deathPosition) then
		return "", nil
	end

	local service = getFinisherService()
	return service:GetEquippedFinisherId(eliminatorPlayer), service
end

function RoundDeathRuntime.CreditScoreboardDeath(options)
	local victim: Player = options.victim
	options.getScoreboardStatsFor(victim).deaths += 1

	local currentTime = workspace:GetServerTimeNow()
	local contributors = options.scoreboardState:GetContributorsFor(victim, false)
	local eliminatorKey: string? = nil
	local eliminatorDamagedAt = -math.huge
	local eliminatorContributor = nil
	local eliminatorPlayer: Player? = nil
	local assistUserIds = {}
	local assistUserIdSet = {}

	if contributors then
		for attackerKey, contributor in pairs(contributors) do
			if
				isRecentEnemyContributor(options, attackerKey, contributor, victim, currentTime)
				and contributor.damagedAt > eliminatorDamagedAt
			then
				eliminatorKey = attackerKey
				eliminatorDamagedAt = contributor.damagedAt
				eliminatorContributor = contributor
			end
		end

		if eliminatorKey then
			eliminatorPlayer = options.getPlayerByKey(eliminatorKey)
			if eliminatorPlayer then
				options.getScoreboardStatsFor(eliminatorKey).eliminations += 1
			end
			options.fireKillFeedElimination(eliminatorKey, victim)
		end

		for attackerKey, contributor in pairs(contributors) do
			if
				attackerKey ~= eliminatorKey
				and isRecentEnemyContributor(options, attackerKey, contributor, victim, currentTime)
			then
				local assistUserId = tonumber(attackerKey)
				if assistUserId and not assistUserIdSet[assistUserId] then
					assistUserIdSet[assistUserId] = true
					table.insert(assistUserIds, assistUserId)
				end
				if options.getPlayerByKey(attackerKey) then
					options.getScoreboardStatsFor(attackerKey).assists += 1
				end
			end
		end
	end

	local botEliminator = if not eliminatorPlayer and eliminatorKey
		then StudioAICombatants.GetOwnerIdentity({ studioAIBot = true, UserId = tonumber(eliminatorKey) })
		else nil
	local deathPosition = options.getPlayerRootPosition(victim)
	local killerHealth, killerMaxHealth = getKillerHealth(eliminatorPlayer)
	local finisherId, service = getFinisher(eliminatorPlayer, deathPosition)
	local playerKilledPayload = {
		timestamp = currentTime,
		roundId = options.roundId,
		victimUserId = victim.UserId,
		victimName = victim.Name,
		victimDisplayName = victim.DisplayName,
		victimTeam = options.getTrackedTeamName(victim),
		killerUserId = if eliminatorKey then tonumber(eliminatorKey) else nil,
		killerName = if eliminatorPlayer then eliminatorPlayer.Name elseif botEliminator then botEliminator.name else nil,
		killerDisplayName = if eliminatorPlayer then eliminatorPlayer.DisplayName elseif botEliminator then botEliminator.displayName else nil,
		killerTeam = if eliminatorPlayer
			then options.getTrackedTeamName(eliminatorPlayer)
			elseif botEliminator then botEliminator.teamName
			else nil,
		killerIsNPC = botEliminator ~= nil,
		sourceType = if eliminatorContributor then eliminatorContributor.sourceType else nil,
		sourceId = if eliminatorContributor then eliminatorContributor.sourceId else nil,
		bombId = if eliminatorContributor then eliminatorContributor.bombId else nil,
		bombType = if eliminatorContributor then eliminatorContributor.bombType else nil,
		abilityName = if eliminatorContributor then eliminatorContributor.abilityName else nil,
		abilityId = if eliminatorContributor then eliminatorContributor.abilityId else nil,
		directHit = if eliminatorContributor then eliminatorContributor.directHit else nil,
		sourceDetail = if eliminatorContributor then eliminatorContributor.sourceDetail else nil,
		assistUserIds = assistUserIds,
		killerHealthAfter = killerHealth,
		killerMaxHealth = killerMaxHealth,
	}
	if deathPosition then
		playerKilledPayload.position = deathPosition
	end
	if finisherId ~= "" then
		playerKilledPayload.finisherId = finisherId
	end
	options.debugDeathFlow("PlayerKilled payload built", playerKilledPayload)
	options.recordReplayEvent("PlayerKilled", playerKilledPayload)
	if finisherId ~= "" then
		service:FireFinisherPlayed({
			roundId = options.roundId,
			killerUserId = playerKilledPayload.killerUserId,
			victimUserId = playerKilledPayload.victimUserId,
			finisherId = finisherId,
			position = deathPosition,
		})
	end
	options.sendWorldText("PlayerKilled", eliminatorPlayer, victim, deathPosition, {
		roundId = options.roundId,
		killerUserId = playerKilledPayload.killerUserId,
		killerName = playerKilledPayload.killerName,
		killerDisplayName = playerKilledPayload.killerDisplayName,
		killerTeam = playerKilledPayload.killerTeam,
		killerIsNPC = playerKilledPayload.killerIsNPC,
		sourceType = playerKilledPayload.sourceType,
		sourceId = playerKilledPayload.sourceId,
	})

	options.clearRecentDamageFor(victim)
	options.syncScoreboardStats()
end

return table.freeze(RoundDeathRuntime)
