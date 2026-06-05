local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReplayConstants = require(ReplicatedStorage.Shared.Replay.ReplayConstants)

local POTGService = {}

local DEBUG = false
local MAX_CANDIDATES = 8
local RECENT_EVENT_LIMIT = 128
local LONG_RANGE_BOMB_KILL_STUDS = 80
local ABILITY_COMBO_WINDOW_SECONDS = 4
local BASE_DAMAGE_BURST_WINDOW_SECONDS = 3
local MIN_BASE_DAMAGE_BURST_FOR_CANDIDATE = 40
local HUGE_BASE_DAMAGE_BURST = 50
local LAST_SECOND_WINDOW_SECONDS = 12
local CLOSE_SCORE_TIE_MARGIN = 35
local LOW_HEALTH_RATIO = 0.25
local LOW_HEALTH_ABSOLUTE = 25

local SCORE_KILL = 80
local SCORE_CLEANUP_KILL = 45
local SCORE_ASSIST = 35
local SCORE_DIRECT_HIT = 70
local SCORE_BASE_DAMAGE_PER_100 = 12
local SCORE_BASE_DAMAGE_BURST_PER_100 = 55
local SCORE_HUGE_BASE_DAMAGE_BURST = 120
local SCORE_BASE_BREAK = 320
local SCORE_LAST_SECOND_BASE_BREAK = 220
local SCORE_REFLECTED_BOMB_KILL = 220
local SCORE_ABSORB_SHIELD_COUNTER_KILL = 240
local SCORE_ENVIRONMENTAL_KILL = 150
local SCORE_LONG_RANGE_BOMB_KILL = 140
local SCORE_DEFENSIVE_SAVE = 170
local SCORE_INTERCEPTOR_COUNTER_KILL = 180
local SCORE_DEFENSIVE_ABILITY_SAVE = 130
local SCORE_ABILITY_COMBO_KILL = 90
local SCORE_LOW_HEALTH_CLUTCH = 70
local SCORE_OBJECTIVE_KILL = 90
local SCORE_MEGA_BOMB_KILL = 90
local SCORE_CHAIN_REACTION = 180
local SCORE_MULTI_KILL_2 = 160
local SCORE_MULTI_KILL_3 = 360
local SCORE_MULTI_KILL_4_PLUS = 600

local RARITY = {
	BaseDamage = 1,
	Assist = 2,
	Kill = 3,
	DirectHit = 4,
	BaseBreaker = 5,
	MultiKill2 = 6,
	ObjectiveKill = 7,
	Environmental = 8,
	LongRange = 9,
	MegaBomb = 10,
	AbilityCombo = 11,
	LowHealthClutch = 12,
	DefensiveSave = 13,
	InterceptorCounter = 14,
	Reflected = 15,
	AbsorbCounter = 16,
	MultiKill3 = 17,
	ChainReaction = 18,
	MultiKill4 = 19,
	LastSecond = 20,
}

local replayService = nil
local initialized = false
local roundId = 0
local candidates = {}
local recentEvents = {}
local recentKillsByPlayer = {}
local recentBaseDamageByPlayer = {}
local recentAbilitiesByPlayer = {}
local bombLaunches = {}
local bombTravelDistances = {}

local function debugPrint(...)
	if DEBUG then
		print("[POTGService]", ...)
	end
end

local function unwrapOptionalSelf(first, second)
	if first == POTGService then
		return second
	end
	return first
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function getTimestamp(event): number?
	if typeof(event) ~= "table" then
		return nil
	end
	if isFiniteNumber(event.timestamp) then
		return event.timestamp
	end
	if isFiniteNumber(event.t) then
		return event.t
	end
	return nil
end

local function getUserId(value: any): number?
	if not (isFiniteNumber(value) and value > 0) then
		return nil
	end
	return math.floor(value)
end

local function getSourceId(value: any): string?
	if typeof(value) == "string" and value ~= "" then
		return value
	end
	if isFiniteNumber(value) then
		return tostring(value)
	end
	return nil
end

local function getString(value: any): string?
	return if typeof(value) == "string" and value ~= "" then value else nil
end

local function getPositionFromEvent(event): Vector3?
	if typeof(event) ~= "table" then
		return nil
	end
	if typeof(event.position) == "Vector3" then
		return event.position
	end
	if typeof(event.cframe) == "CFrame" then
		return event.cframe.Position
	end
	return nil
end

local function copyReplayValue(value: any, depth: number): any
	local valueType = typeof(value)
	if
		valueType == "number"
		or valueType == "string"
		or valueType == "boolean"
		or valueType == "Vector3"
		or valueType == "CFrame"
	then
		return value
	end

	if valueType ~= "table" or depth >= 3 then
		return nil
	end

	local copy = {}
	for key, child in pairs(value) do
		local keyType = typeof(key)
		if keyType ~= "string" and keyType ~= "number" then
			continue
		end

		local copiedChild = copyReplayValue(child, depth + 1)
		if copiedChild ~= nil then
			copy[key] = copiedChild
		end
	end
	return copy
end

local function copyReplayEvent(event)
	if typeof(event) ~= "table" then
		return nil
	end
	return copyReplayValue(event, 0)
end

local function containsText(value: any, needle: string): boolean
	if typeof(value) ~= "string" then
		return false
	end
	return string.find(string.lower(value), string.lower(needle), 1, true) ~= nil
end

local function anyEventTextContains(event, needles: { string }): boolean
	local fields = {
		event.sourceType,
		event.sourceId,
		event.sourceDetail,
		event.killType,
		event.reason,
		event.abilityName,
		event.effectName,
		event.bombType,
		event.baseId,
		event.teamName,
		event.objectiveId,
	}

	for _, value in ipairs(fields) do
		for _, needle in ipairs(needles) do
			if containsText(value, needle) then
				return true
			end
		end
	end

	return false
end

local function countUserIds(value: any): number
	if typeof(value) ~= "table" then
		return 0
	end

	local count = 0
	for _, child in pairs(value) do
		local userId = nil
		if typeof(child) == "table" then
			userId = getUserId(child.userId) or getUserId(child.playerUserId)
		else
			userId = getUserId(child)
		end
		if userId then
			count += 1
		end
	end
	return count
end

local function getPrimaryPlayerUserId(event): number?
	return getUserId(event.killerUserId)
		or getUserId(event.attackerUserId)
		or getUserId(event.ownerUserId)
		or getUserId(event.playerUserId)
		or getUserId(event.userId)
end

local function getSourceConfidence(event, playerUserId: number?): number
	local confidence = 0
	if getUserId(playerUserId) then
		confidence += 1
	end
	if getUserId(event.killerUserId)
		or getUserId(event.attackerUserId)
		or getUserId(event.ownerUserId)
		or getUserId(event.playerUserId)
		or getUserId(event.userId)
	then
		confidence += 2
	end
	if getSourceId(event.sourceId) or getSourceId(event.bombId) then
		confidence += 2
	end
	if getString(event.sourceType) or getString(event.bombType) or getString(event.abilityName) then
		confidence += 1
	end
	return confidence
end

local function applySourceContext(context, event)
	context.sourceId = getSourceId(event.sourceId) or getSourceId(event.bombId)
	context.sourceType = getString(event.sourceType) or getString(event.bombType)
	context.sourceConfidence = getSourceConfidence(event, context.playerUserId)
end

local function pruneListByTime(list, cutoffTime: number, timeField: string)
	local writeIndex = 1
	for readIndex = 1, #list do
		local entry = list[readIndex]
		local entryTime = if typeof(entry) == "table" then entry[timeField] else nil
		if isFiniteNumber(entryTime) and entryTime >= cutoffTime then
			list[writeIndex] = entry
			writeIndex += 1
		end
	end

	for index = #list, writeIndex, -1 do
		list[index] = nil
	end
end

local function pruneDictionaryLists(dictionary, cutoffTime: number, timeField: string)
	for key, list in pairs(dictionary) do
		pruneListByTime(list, cutoffTime, timeField)
		if #list == 0 then
			dictionary[key] = nil
		end
	end
end

local function pruneHistories(currentTime: number)
	local historySeconds = math.max(
		ReplayConstants.POTG_PRE_SECONDS + ReplayConstants.POTG_POST_SECONDS,
		ABILITY_COMBO_WINDOW_SECONDS,
		ReplayConstants.BUFFER_SECONDS
	)
	local cutoffTime = currentTime - historySeconds

	pruneListByTime(recentEvents, cutoffTime, "timestamp")
	if #recentEvents > RECENT_EVENT_LIMIT then
		local removeCount = #recentEvents - RECENT_EVENT_LIMIT
		for _ = 1, removeCount do
			table.remove(recentEvents, 1)
		end
	end

	pruneDictionaryLists(recentKillsByPlayer, currentTime - ReplayConstants.POTG_PRE_SECONDS, "timestamp")
	pruneDictionaryLists(recentBaseDamageByPlayer, currentTime - ReplayConstants.POTG_PRE_SECONDS, "timestamp")
	pruneDictionaryLists(recentAbilitiesByPlayer, currentTime - ABILITY_COMBO_WINDOW_SECONDS, "timestamp")

	for sourceId, launch in pairs(bombLaunches) do
		if not (typeof(launch) == "table" and isFiniteNumber(launch.timestamp) and launch.timestamp >= cutoffTime) then
			bombLaunches[sourceId] = nil
		end
	end

	for sourceId, travel in pairs(bombTravelDistances) do
		if not (typeof(travel) == "table" and isFiniteNumber(travel.timestamp) and travel.timestamp >= cutoffTime) then
			bombTravelDistances[sourceId] = nil
		end
	end
end

local function getPlayerHistory(dictionary, playerUserId: number)
	local key = tostring(playerUserId)
	local history = dictionary[key]
	if not history then
		history = {}
		dictionary[key] = history
	end
	return history
end

local function registerKill(playerUserId: number, timestamp: number)
	table.insert(getPlayerHistory(recentKillsByPlayer, playerUserId), {
		timestamp = timestamp,
	})
end

local function countRecentKills(playerUserId: number, timestamp: number): number
	local history = recentKillsByPlayer[tostring(playerUserId)]
	if not history then
		return 0
	end

	local cutoffTime = timestamp - ReplayConstants.POTG_PRE_SECONDS
	local count = 0
	for _, entry in ipairs(history) do
		if entry.timestamp >= cutoffTime and entry.timestamp <= timestamp then
			count += 1
		end
	end
	return count
end

local function registerBaseDamage(playerUserId: number, timestamp: number, amount: number)
	table.insert(getPlayerHistory(recentBaseDamageByPlayer, playerUserId), {
		timestamp = timestamp,
		amount = amount,
	})
end

local function sumRecentBaseDamage(playerUserId: number, timestamp: number, windowSeconds: number?): number
	local history = recentBaseDamageByPlayer[tostring(playerUserId)]
	if not history then
		return 0
	end

	local window = if isFiniteNumber(windowSeconds) and windowSeconds > 0 then windowSeconds else ReplayConstants.POTG_PRE_SECONDS
	local cutoffTime = timestamp - window
	local total = 0
	for _, entry in ipairs(history) do
		if entry.timestamp >= cutoffTime and entry.timestamp <= timestamp and isFiniteNumber(entry.amount) then
			total += entry.amount
		end
	end
	return total
end

local function registerAbility(event, timestamp: number)
	local playerUserId = getUserId(event.userId) or getUserId(event.playerUserId) or getUserId(event.ownerUserId)
	if not playerUserId then
		return
	end

	table.insert(getPlayerHistory(recentAbilitiesByPlayer, playerUserId), {
		timestamp = timestamp,
		abilityName = getString(event.abilityName) or getString(event.abilityId) or "Ability",
	})
end

local function getRecentAbility(playerUserId: number, timestamp: number)
	local history = recentAbilitiesByPlayer[tostring(playerUserId)]
	if not history then
		return nil
	end

	for index = #history, 1, -1 do
		local entry = history[index]
		if timestamp - entry.timestamp <= ABILITY_COMBO_WINDOW_SECONDS then
			return entry
		end
	end
	return nil
end

local function recentAbilityContains(playerUserId: number, timestamp: number, needles: { string }): boolean
	local ability = getRecentAbility(playerUserId, timestamp)
	if not ability then
		return false
	end

	for _, needle in ipairs(needles) do
		if containsText(ability.abilityName, needle) then
			return true
		end
	end
	return false
end

local function registerBombThrown(event, timestamp: number)
	local sourceId = getSourceId(event.bombId) or getSourceId(event.sourceId)
	if not sourceId then
		return
	end

	bombLaunches[sourceId] = {
		timestamp = timestamp,
		position = getPositionFromEvent(event),
		ownerUserId = getUserId(event.ownerUserId),
		bombType = getString(event.bombType),
	}
end

local function registerBombExploded(event, timestamp: number)
	local sourceId = getSourceId(event.bombId) or getSourceId(event.sourceId)
	if not sourceId then
		return
	end

	local explicitDistance = event.distance or event.travelDistance or event.bombTravelDistance
	local distance = if isFiniteNumber(explicitDistance) and explicitDistance > 0 then explicitDistance else nil
	local position = getPositionFromEvent(event)
	local launch = bombLaunches[sourceId]

	if not distance and position and typeof(launch) == "table" and typeof(launch.position) == "Vector3" then
		distance = (position - launch.position).Magnitude
	end

	if distance then
		bombTravelDistances[sourceId] = {
			timestamp = timestamp,
			distance = distance,
		}
	end
end

local function getBombTypeFromEvent(event): string?
	local sourceId = getSourceId(event.sourceId) or getSourceId(event.bombId)
	local launch = if sourceId then bombLaunches[sourceId] else nil
	local bombType = getString(event.bombType)
	if bombType then
		return bombType
	end
	return if typeof(launch) == "table" then getString(launch.bombType) else nil
end

local function newScoreContext(playerUserId: number, timestamp: number, eventType: string)
	return {
		playerUserId = playerUserId,
		timestamp = timestamp,
		sourceId = nil,
		sourceType = nil,
		score = 0,
		reasons = {},
		reasonSet = {},
		eventTypeSet = {
			[eventType] = true,
		},
		kills = 0,
		baseDamage = 0,
		rareRank = 0,
		sourceConfidence = 0,
	}
end

local function addEventType(context, eventType: string?)
	if typeof(eventType) == "string" and eventType ~= "" then
		context.eventTypeSet[eventType] = true
	end
end

local function addScore(context, amount: number, reason: string, rareRank: number?)
	if not (isFiniteNumber(amount) and amount > 0) then
		return
	end

	context.score += amount
	if not context.reasonSet[reason] then
		context.reasonSet[reason] = true
		table.insert(context.reasons, reason)
	end
	context.rareRank = math.max(context.rareRank, rareRank or 0)
end

local function getEventTypesArray(eventTypeSet)
	local eventTypes = {}
	for eventType in pairs(eventTypeSet) do
		table.insert(eventTypes, eventType)
	end
	table.sort(eventTypes)
	return eventTypes
end

local function buildCandidate(context)
	if not (context and getUserId(context.playerUserId) and context.score > 0) then
		return nil
	end

	local timestamp = context.timestamp
	return {
		roundId = roundId,
		playerUserId = context.playerUserId,
		sourceId = context.sourceId,
		sourceType = context.sourceType,
		startTime = timestamp - ReplayConstants.POTG_PRE_SECONDS,
		endTime = timestamp + ReplayConstants.POTG_POST_SECONDS,
		score = math.floor(context.score + 0.5),
		reason = if #context.reasons > 0 then table.concat(context.reasons, " + ") else "Highlight",
		eventTypes = getEventTypesArray(context.eventTypeSet),
		primaryEventTime = timestamp,
		kills = context.kills or 0,
		baseDamage = math.floor((context.baseDamage or 0) + 0.5),
		rareRank = context.rareRank or 0,
		sourceConfidence = context.sourceConfidence or 0,
	}
end

local function copyCandidate(candidate)
	if typeof(candidate) ~= "table" then
		return nil
	end

	local eventTypes = {}
	if typeof(candidate.eventTypes) == "table" then
		for _, eventType in ipairs(candidate.eventTypes) do
			table.insert(eventTypes, eventType)
		end
	end

	return {
		roundId = candidate.roundId,
		playerUserId = candidate.playerUserId,
		sourceId = candidate.sourceId,
		sourceType = candidate.sourceType,
		startTime = candidate.startTime,
		endTime = candidate.endTime,
		score = candidate.score,
		reason = candidate.reason,
		eventTypes = eventTypes,
		primaryEventTime = candidate.primaryEventTime,
		kills = candidate.kills,
		baseDamage = candidate.baseDamage,
		rareRank = candidate.rareRank,
		sourceConfidence = candidate.sourceConfidence,
	}
end

local function candidateComesBefore(left, right): boolean
	if left.score ~= right.score then
		if math.abs(left.score - right.score) > CLOSE_SCORE_TIE_MARGIN then
			return left.score > right.score
		end
	end
	if left.kills ~= right.kills then
		return left.kills > right.kills
	end
	if left.baseDamage ~= right.baseDamage then
		return left.baseDamage > right.baseDamage
	end
	if left.rareRank ~= right.rareRank then
		return left.rareRank > right.rareRank
	end
	if left.sourceConfidence ~= right.sourceConfidence then
		return left.sourceConfidence > right.sourceConfidence
	end
	if left.score ~= right.score then
		return left.score > right.score
	end
	return left.primaryEventTime > right.primaryEventTime
end

local function addCandidate(candidate)
	if not candidate then
		return false
	end

	table.insert(candidates, candidate)
	table.sort(candidates, candidateComesBefore)

	while #candidates > MAX_CANDIDATES do
		table.remove(candidates)
	end

	debugPrint(
		("candidate player=%s score=%s reason=%s"):format(
			tostring(candidate.playerUserId),
			tostring(candidate.score),
			tostring(candidate.reason)
		)
	)
	return true
end

local function addMultiKillScore(context, killCount: number)
	if killCount >= 4 then
		addScore(context, SCORE_MULTI_KILL_4_PLUS, "Chain Reaction", RARITY.MultiKill4)
	elseif killCount == 3 then
		addScore(context, SCORE_MULTI_KILL_3, "Triple Detonation", RARITY.MultiKill3)
	elseif killCount == 2 then
		addScore(context, SCORE_MULTI_KILL_2, "Multi-Kill", RARITY.MultiKill2)
	end
end

local function isDirectHit(event): boolean
	return event.directHit == true
		or event.isDirectHit == true
		or event.hitType == "Direct"
		or event.sourceDetail == "Direct"
		or anyEventTextContains(event, { "direct" })
end

local function isReflectedKill(event): boolean
	return event.reflected == true
		or event.wasReflected == true
		or getUserId(event.reflectorUserId) ~= nil
		or anyEventTextContains(event, { "reflect", "redirect" })
end

local function isEnvironmentalKill(event): boolean
	return event.environmental == true
		or event.knockoff == true
		or anyEventTextContains(event, { "environment", "knockoff", "knockback", "void", "fall", "ringout" })
end

local function isDefensiveSave(event): boolean
	return event.defensiveSave == true
		or getString(event.saveType) ~= nil
		or anyEventTextContains(event, { "defensive save", "save", "prevented", "blocked" })
end

local function isAbsorbShieldCounter(event, playerUserId: number, timestamp: number): boolean
	if event.absorbShieldCounter == true or event.counterKill == true then
		return true
	end
	if anyEventTextContains(event, { "absorb shield", "absorbshield" }) then
		return true
	end

	return recentAbilityContains(playerUserId, timestamp, { "absorb" })
end

local function isInterceptorCounter(event, playerUserId: number, timestamp: number): boolean
	if event.interceptorCounter == true or event.counterAttack == true then
		return true
	end
	if anyEventTextContains(event, { "interceptor", "counterattack", "counter-attack" }) then
		return true
	end
	return recentAbilityContains(playerUserId, timestamp, { "interceptor" })
end

local function isDefensiveAbilityContext(event, playerUserId: number, timestamp: number): boolean
	if isDefensiveSave(event) then
		return true
	end
	if anyEventTextContains(event, {
		"forcefield",
		"force field",
		"wall",
		"shield",
		"interceptor",
		"absorb",
		"reflect",
	}) then
		return true
	end
	return recentAbilityContains(playerUserId, timestamp, {
		"forcefield",
		"force field",
		"wall",
		"shield",
		"interceptor",
		"absorb",
		"reflect",
	})
end

local function isAbilityComboKill(event, playerUserId: number, timestamp: number): boolean
	if event.abilityCombo == true or event.comboKill == true then
		return true
	end
	if anyEventTextContains(event, { "ability combo", "combo" }) then
		return true
	end
	return getRecentAbility(playerUserId, timestamp) ~= nil
end

local function isMegaBombEvent(event, playerUserId: number?, timestamp: number?): boolean
	local bombType = getBombTypeFromEvent(event)
	if containsText(bombType, "mega") or containsText(bombType, "fat") then
		return true
	end
	if anyEventTextContains(event, { "mega bomb", "megabomb", "fat bomb", "fatbomb" }) then
		return true
	end
	return playerUserId ~= nil
		and timestamp ~= nil
		and recentAbilityContains(playerUserId, timestamp, { "mega bomb", "megabomb", "fat bomb", "fatbomb" })
end

local function isChainReactionEvent(event, killCount: number?): boolean
	return (killCount ~= nil and killCount >= 4)
		or countUserIds(event.killedUserIds) >= 4
		or anyEventTextContains(event, { "chain reaction", "chain", "cluster", "triple toss" })
end

local function isNearObjectiveEvent(event): boolean
	return event.nearObjective == true
		or event.objective == true
		or getString(event.baseId) ~= nil
		or getString(event.teamName) ~= nil
		or anyEventTextContains(event, { "objective", "base", "core" })
end

local function isBaseDestroyedEvent(event): boolean
	return event.baseDestroyed == true
		or event.coreDestroyed == true
		or event.objectiveDestroyed == true
		or event.destroyed == true
		or event.finalBlow == true
		or anyEventTextContains(event, { "base destroyed", "core destroyed", "objective destroyed", "base break" })
end

local function getRoundTimeRemaining(event): number?
	local remaining = event.roundTimeRemaining
		or event.timeRemaining
		or event.secondsRemaining
		or event.remainingSeconds
		or event.roundSecondsRemaining
	if isFiniteNumber(remaining) and remaining >= 0 then
		return remaining
	end
	return nil
end

local function isLastSecondBaseBreak(event): boolean
	if event.lastSecond == true or event.clutch == true then
		return isBaseDestroyedEvent(event)
	end

	local remaining = getRoundTimeRemaining(event)
	return isBaseDestroyedEvent(event) and remaining ~= nil and remaining <= LAST_SECOND_WINDOW_SECONDS
end

local function getPreventedDamage(event): number
	local value = event.preventedDamage or event.savedDamage or event.baseDamagePrevented or event.preventedBaseDamage
	return if isFiniteNumber(value) and value > 0 then value else 0
end

local function getPreventedDeaths(event): number
	local value = event.preventedDeaths or event.savedDeaths or event.deathsPrevented
	return if isFiniteNumber(value) and value > 0 then math.floor(value) else 0
end

local function getLongRangeDistance(event): number?
	local explicitDistance = event.distance or event.travelDistance or event.bombTravelDistance or event.sourceDistance
	if isFiniteNumber(explicitDistance) and explicitDistance > 0 then
		return explicitDistance
	end

	local sourceId = getSourceId(event.sourceId) or getSourceId(event.bombId)
	local travel = sourceId and bombTravelDistances[sourceId]
	if typeof(travel) == "table" and isFiniteNumber(travel.distance) then
		return travel.distance
	end

	return nil
end

local function isLongRangeBombKill(event): boolean
	local sourceId = getSourceId(event.sourceId) or getSourceId(event.bombId)
	local hasBombSource = anyEventTextContains(event, { "bomb", "projectile" })
		or getSourceId(event.bombId) ~= nil
		or (sourceId ~= nil and bombTravelDistances[sourceId] ~= nil)
	if not hasBombSource then
		return false
	end

	local distance = getLongRangeDistance(event)
	return distance ~= nil and distance >= LONG_RANGE_BOMB_KILL_STUDS
end

local function isLowHealthClutch(event): boolean
	if event.lowHealthClutch == true then
		return true
	end

	local health = event.killerHealthAfter or event.killerHealth or event.attackerHealthAfter or event.attackerHealth
	local maxHealth = event.killerMaxHealth or event.attackerMaxHealth
	local healthFraction = event.killerHealthFraction or event.attackerHealthFraction or event.killerHealthPercent

	if isFiniteNumber(healthFraction) then
		if healthFraction > 1 then
			healthFraction /= 100
		end
		return healthFraction <= LOW_HEALTH_RATIO
	end

	if isFiniteNumber(health) and isFiniteNumber(maxHealth) and maxHealth > 0 then
		return health / maxHealth <= LOW_HEALTH_RATIO
	end

	return isFiniteNumber(health) and health <= LOW_HEALTH_ABSOLUTE
end

local function getAssistUserIds(event): { number }
	local assistUserIds = {}
	local singularAssistUserId = getUserId(event.assistUserId)
		or getUserId(event.assistantUserId)
		or getUserId(event.assistPlayerUserId)
	if singularAssistUserId then
		table.insert(assistUserIds, singularAssistUserId)
	end

	local source = nil
	if typeof(event.assistUserIds) == "table" then
		source = event.assistUserIds
	elseif typeof(event.assists) == "table" then
		source = event.assists
	end

	if not source then
		return assistUserIds
	end

	for _, value in pairs(source) do
		local userId = nil
		if typeof(value) == "table" then
			userId = getUserId(value.userId) or getUserId(value.playerUserId)
		else
			userId = getUserId(value)
		end
		if userId then
			table.insert(assistUserIds, userId)
		end
	end
	return assistUserIds
end

local function addAssistCandidates(event, timestamp: number)
	for _, assistUserId in ipairs(getAssistUserIds(event)) do
		local context = newScoreContext(assistUserId, timestamp, event.eventType)
		applySourceContext(context, event)
		addScore(context, SCORE_ASSIST, "Assist", RARITY.Assist)
		addCandidate(buildCandidate(context))
	end
end

local function processAbilityEvent(event, timestamp: number)
	registerAbility(event, timestamp)

	local playerUserId = getPrimaryPlayerUserId(event)
	if not playerUserId then
		return
	end

	local preventedDamage = getPreventedDamage(event)
	local preventedDeaths = getPreventedDeaths(event)
	if not (isDefensiveSave(event) or preventedDamage > 0 or preventedDeaths > 0) then
		return
	end

	local context = newScoreContext(playerUserId, timestamp, event.eventType)
	context.baseDamage = preventedDamage
	applySourceContext(context, event)
	if not context.sourceType then
		context.sourceType = "Ability"
	end
	if not context.sourceId then
		context.sourceId = getString(event.abilityName) or getString(event.abilityId)
	end
	context.sourceConfidence = math.max(context.sourceConfidence, getSourceConfidence(event, playerUserId))

	addScore(context, SCORE_DEFENSIVE_ABILITY_SAVE, "Clutch Defense", RARITY.DefensiveSave)
	if preventedDamage > 0 then
		addScore(context, (preventedDamage / 100) * SCORE_BASE_DAMAGE_BURST_PER_100, "Clutch Defense", RARITY.DefensiveSave)
	end
	if preventedDeaths > 0 then
		addScore(context, preventedDeaths * SCORE_KILL, "Clutch Defense", RARITY.DefensiveSave)
	end

	addCandidate(buildCandidate(context))
end

local function processKillEvent(event, timestamp: number)
	local playerUserId = getUserId(event.killerUserId) or getUserId(event.attackerUserId) or getUserId(event.ownerUserId)
	if not playerUserId then
		addAssistCandidates(event, timestamp)
		return
	end

	registerKill(playerUserId, timestamp)

	local killCount = math.max(countRecentKills(playerUserId, timestamp), 1)
	local assistUserIds = getAssistUserIds(event)
	local directHit = isDirectHit(event)
	local reflectedKill = isReflectedKill(event) or recentAbilityContains(playerUserId, timestamp, { "reflect" })
	local absorbCounter = isAbsorbShieldCounter(event, playerUserId, timestamp)
	local interceptorCounter = isInterceptorCounter(event, playerUserId, timestamp)
	local environmentalKill = isEnvironmentalKill(event)
	local longRangeKill = isLongRangeBombKill(event)
	local defensivePlay = isDefensiveAbilityContext(event, playerUserId, timestamp)
	local abilityCombo = isAbilityComboKill(event, playerUserId, timestamp)
	local lowHealthClutch = isLowHealthClutch(event)
	local megaBomb = isMegaBombEvent(event, playerUserId, timestamp)
	local objectiveDamage = sumRecentBaseDamage(playerUserId, timestamp, BASE_DAMAGE_BURST_WINDOW_SECONDS)
	local objectivePlay = isNearObjectiveEvent(event) or (killCount >= 2 and objectiveDamage > 0)
	local cleanupKill = killCount == 1
		and #assistUserIds > 0
		and not (
			directHit
			or reflectedKill
			or absorbCounter
			or interceptorCounter
			or environmentalKill
			or longRangeKill
			or defensivePlay
			or abilityCombo
			or megaBomb
			or objectivePlay
		)

	local context = newScoreContext(playerUserId, timestamp, event.eventType)
	context.kills = killCount
	context.baseDamage = objectiveDamage
	applySourceContext(context, event)

	local killScore = if cleanupKill then SCORE_CLEANUP_KILL else SCORE_KILL
	addScore(context, killScore * killCount, if killCount > 1 then tostring(killCount) .. " Kills" else "Kill", RARITY.Kill)
	addMultiKillScore(context, killCount)

	if isChainReactionEvent(event, killCount) and killCount >= 2 and killCount < 4 then
		addScore(context, SCORE_CHAIN_REACTION, "Chain Reaction", RARITY.ChainReaction)
	end
	if directHit then
		addScore(context, SCORE_DIRECT_HIT, "Direct Hit", RARITY.DirectHit)
	end
	if reflectedKill then
		addScore(context, SCORE_REFLECTED_BOMB_KILL, "Reflect Master", RARITY.Reflected)
	end
	if absorbCounter then
		addScore(context, SCORE_ABSORB_SHIELD_COUNTER_KILL, "Absorb Counter", RARITY.AbsorbCounter)
		addEventType(context, "AbilityUsed")
	end
	if interceptorCounter then
		addScore(context, SCORE_INTERCEPTOR_COUNTER_KILL, "Clutch Defense", RARITY.InterceptorCounter)
		addEventType(context, "AbilityUsed")
	end
	if environmentalKill then
		addScore(context, SCORE_ENVIRONMENTAL_KILL, "Environmental Kill", RARITY.Environmental)
	end
	if longRangeKill then
		addScore(context, SCORE_LONG_RANGE_BOMB_KILL, "Long Shot", RARITY.LongRange)
	end
	if defensivePlay then
		addScore(context, SCORE_DEFENSIVE_SAVE, "Clutch Defense", RARITY.DefensiveSave)
		addEventType(context, "AbilityUsed")
	end
	if abilityCombo then
		addScore(context, SCORE_ABILITY_COMBO_KILL, "Ability Combo Kill", RARITY.AbilityCombo)
		addEventType(context, "AbilityUsed")
	end
	if megaBomb then
		addScore(context, SCORE_MEGA_BOMB_KILL, "Mega Bomb", RARITY.MegaBomb)
	end
	if objectivePlay then
		addScore(context, SCORE_OBJECTIVE_KILL, "Base Breaker", RARITY.ObjectiveKill)
	end
	if lowHealthClutch then
		addScore(context, SCORE_LOW_HEALTH_CLUTCH, "Low Health Clutch", RARITY.LowHealthClutch)
	end

	addCandidate(buildCandidate(context))
	addAssistCandidates(event, timestamp)
end

local function processBaseDamageEvent(event, timestamp: number)
	local playerUserId = getUserId(event.attackerUserId) or getUserId(event.ownerUserId) or getUserId(event.playerUserId)
	if not playerUserId then
		return
	end

	local amount = if isFiniteNumber(event.amount) and event.amount > 0 then event.amount else 0
	if amount <= 0 then
		return
	end

	registerBaseDamage(playerUserId, timestamp, amount)
	local baseDamage = sumRecentBaseDamage(playerUserId, timestamp)
	local baseDamageBurst = sumRecentBaseDamage(playerUserId, timestamp, BASE_DAMAGE_BURST_WINDOW_SECONDS)
	local baseDestroyed = isBaseDestroyedEvent(event)
	if baseDamageBurst < MIN_BASE_DAMAGE_BURST_FOR_CANDIDATE and not baseDestroyed then
		return
	end

	local context = newScoreContext(playerUserId, timestamp, event.eventType)
	context.baseDamage = baseDamageBurst
	applySourceContext(context, event)

	local sustainedDamage = math.max(baseDamage - baseDamageBurst, 0)
	local burstScore = (baseDamageBurst / 100) * SCORE_BASE_DAMAGE_BURST_PER_100
	local sustainedScore = (sustainedDamage / 100) * SCORE_BASE_DAMAGE_PER_100
	addScore(context, burstScore + sustainedScore, "Base Breaker", RARITY.BaseDamage)

	if baseDamageBurst >= HUGE_BASE_DAMAGE_BURST then
		addScore(context, SCORE_HUGE_BASE_DAMAGE_BURST, "Base Breaker", RARITY.BaseBreaker)
	end
	if baseDestroyed then
		addScore(context, SCORE_BASE_BREAK, "Base Breaker", RARITY.BaseBreaker)
	end
	if isLastSecondBaseBreak(event) then
		addScore(context, SCORE_LAST_SECOND_BASE_BREAK, "Last-Second Blast", RARITY.LastSecond)
	end
	if isMegaBombEvent(event, playerUserId, timestamp) then
		addScore(context, SCORE_MEGA_BOMB_KILL, "Mega Bomb", RARITY.MegaBomb)
	end

	addCandidate(buildCandidate(context))
end

local function processDamageEvent(event, timestamp: number)
	if not isDirectHit(event) then
		return
	end

	local playerUserId = getUserId(event.attackerUserId) or getUserId(event.ownerUserId) or getUserId(event.playerUserId)
	if not playerUserId then
		return
	end

	local context = newScoreContext(playerUserId, timestamp, event.eventType)
	applySourceContext(context, event)
	addScore(context, SCORE_DIRECT_HIT, "Direct Hit", RARITY.DirectHit)
	addCandidate(buildCandidate(context))
end

local function processBombExplodedEvent(event, timestamp: number)
	registerBombExploded(event, timestamp)

	local playerUserId = getPrimaryPlayerUserId(event)
	if not playerUserId then
		return
	end

	local killedCount = countUserIds(event.killedUserIds)
	local megaBomb = isMegaBombEvent(event, playerUserId, timestamp)
	local chainReaction = isChainReactionEvent(event, killedCount)
	if killedCount < 2 and not (megaBomb and killedCount >= 1) and not (chainReaction and killedCount >= 1) then
		return
	end

	local context = newScoreContext(playerUserId, timestamp, event.eventType)
	context.kills = killedCount
	applySourceContext(context, event)

	if killedCount > 0 then
		addScore(
			context,
			SCORE_KILL * killedCount,
			if killedCount > 1 then tostring(killedCount) .. " Kills" else "Kill",
			RARITY.Kill
		)
		addMultiKillScore(context, killedCount)
	end
	if chainReaction and killedCount >= 1 and killedCount < 4 then
		addScore(context, SCORE_CHAIN_REACTION, "Chain Reaction", RARITY.ChainReaction)
	end
	if megaBomb then
		addScore(context, SCORE_MEGA_BOMB_KILL, "Mega Bomb", RARITY.MegaBomb)
	end
	if isLongRangeBombKill(event) then
		addScore(context, SCORE_LONG_RANGE_BOMB_KILL, "Long Shot", RARITY.LongRange)
	end
	if isNearObjectiveEvent(event) then
		addScore(context, SCORE_OBJECTIVE_KILL, "Base Breaker", RARITY.ObjectiveKill)
	end

	addCandidate(buildCandidate(context))
end

function POTGService.Init(first, second)
	replayService = unwrapOptionalSelf(first, second)
	initialized = true
	return true
end

function POTGService.OnStart(_self)
	if not initialized then
		POTGService.Init()
	end
end

function POTGService.ResetRound(first, second)
	local nextRoundId = unwrapOptionalSelf(first, second)
	if isFiniteNumber(nextRoundId) then
		roundId = math.floor(nextRoundId)
	else
		roundId += 1
	end

	table.clear(candidates)
	table.clear(recentEvents)
	table.clear(recentKillsByPlayer)
	table.clear(recentBaseDamageByPlayer)
	table.clear(recentAbilitiesByPlayer)
	table.clear(bombLaunches)
	table.clear(bombTravelDistances)

	debugPrint("reset round", roundId)
	return true
end

function POTGService.ProcessReplayEvent(first, second)
	local rawEvent = unwrapOptionalSelf(first, second)
	local event = copyReplayEvent(rawEvent)
	local timestamp = getTimestamp(event)
	if not (event and timestamp and getString(event.eventType)) then
		return false
	end

	event.timestamp = timestamp
	pruneHistories(timestamp)
	table.insert(recentEvents, event)

	if event.eventType == "BombThrown" then
		registerBombThrown(event, timestamp)
	elseif event.eventType == "BombExploded" then
		processBombExplodedEvent(event, timestamp)
	elseif event.eventType == "AbilityUsed" then
		processAbilityEvent(event, timestamp)
	elseif event.eventType == "PlayerKilled" then
		processKillEvent(event, timestamp)
	elseif event.eventType == "BaseDamaged" then
		processBaseDamageEvent(event, timestamp)
	elseif event.eventType == "PlayerDamaged" then
		processDamageEvent(event, timestamp)
	end

	return true
end

function POTGService.GetBestCandidate(_self)
	return copyCandidate(candidates[1])
end

function POTGService.GetDebugCandidates(_self)
	local debugCandidates = {}
	for index, candidate in ipairs(candidates) do
		debugCandidates[index] = copyCandidate(candidate)
	end
	return debugCandidates
end

function POTGService.RecordEvent(first, second)
	return POTGService.ProcessReplayEvent(first, second)
end

function POTGService.AddCandidate(first, second)
	local candidate = unwrapOptionalSelf(first, second)
	local copiedCandidate = copyCandidate(candidate)
	if not (copiedCandidate and isFiniteNumber(copiedCandidate.score) and isFiniteNumber(copiedCandidate.primaryEventTime)) then
		return false
	end

	copiedCandidate.kills = if isFiniteNumber(copiedCandidate.kills) then copiedCandidate.kills else 0
	copiedCandidate.baseDamage = if isFiniteNumber(copiedCandidate.baseDamage) then copiedCandidate.baseDamage else 0
	copiedCandidate.rareRank = if isFiniteNumber(copiedCandidate.rareRank) then copiedCandidate.rareRank else 0
	copiedCandidate.sourceConfidence = if isFiniteNumber(copiedCandidate.sourceConfidence) then copiedCandidate.sourceConfidence else 0
	return addCandidate(copiedCandidate)
end

return POTGService
