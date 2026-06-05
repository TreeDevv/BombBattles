local QuestConfig = {}

QuestConfig.RemotesFolderName = "Remotes"
QuestConfig.RequestRemoteName = "QuestRequest"
QuestConfig.ActiveDailyCount = 5

QuestConfig.Actions = {
	Claim = "Claim",
}

QuestConfig.Metrics = {
	RoundsPlayed = "roundsPlayed",
	Wins = "wins",
	Eliminations = "eliminations",
	Damage = "damage",
	Destruction = "destruction",
	TimePlayed = "timePlayed",
}

local DEFINITIONS = {
	{
		id = "play_2_rounds",
		metric = QuestConfig.Metrics.RoundsPlayed,
		target = 2,
		rewardCash = 25,
		displayName = "Play 2 rounds",
		order = 10,
	},
	{
		id = "play_5_rounds",
		metric = QuestConfig.Metrics.RoundsPlayed,
		target = 5,
		rewardCash = 75,
		displayName = "Play 5 rounds",
		order = 20,
	},
	{
		id = "win_1_round",
		metric = QuestConfig.Metrics.Wins,
		target = 1,
		rewardCash = 75,
		displayName = "Win 1 round",
		order = 30,
	},
	{
		id = "win_3_rounds",
		metric = QuestConfig.Metrics.Wins,
		target = 3,
		rewardCash = 150,
		displayName = "Win 3 rounds",
		order = 40,
	},
	{
		id = "get_3_eliminations",
		metric = QuestConfig.Metrics.Eliminations,
		target = 3,
		rewardCash = 50,
		displayName = "Get 3 eliminations",
		order = 50,
	},
	{
		id = "get_10_eliminations",
		metric = QuestConfig.Metrics.Eliminations,
		target = 10,
		rewardCash = 125,
		displayName = "Get 10 eliminations",
		order = 60,
	},
	{
		id = "deal_1000_damage",
		metric = QuestConfig.Metrics.Damage,
		target = 1000,
		rewardCash = 75,
		displayName = "Deal 1,000 damage",
		order = 70,
	},
	{
		id = "deal_3000_damage",
		metric = QuestConfig.Metrics.Damage,
		target = 3000,
		rewardCash = 150,
		displayName = "Deal 3,000 damage",
		order = 80,
	},
	{
		id = "destroy_3_targets",
		metric = QuestConfig.Metrics.Destruction,
		target = 3,
		rewardCash = 75,
		displayName = "Destroy 3 targets",
		order = 90,
	},
	{
		id = "play_20_minutes",
		metric = QuestConfig.Metrics.TimePlayed,
		target = 20 * 60,
		rewardCash = 100,
		displayName = "Play 20 minutes",
		order = 100,
	},
}

local definitionsById = {}
local orderedIds = {}
local orderById = {}

for _, definition in ipairs(DEFINITIONS) do
	definitionsById[definition.id] = definition
	table.insert(orderedIds, definition.id)
	orderById[definition.id] = definition.order or #orderedIds
end

local function copyArray(source)
	local copy = {}
	for index, value in ipairs(source) do
		copy[index] = value
	end
	return copy
end

local function hashString(value: string): number
	local hash = 2166136261
	for index = 1, #value do
		hash = (hash * 16777619 + string.byte(value, index)) % 2147483647
	end
	return math.max(1, hash)
end

function QuestConfig.NormalizeQuestId(questId: any): string
	if typeof(questId) ~= "string" then
		return ""
	end
	return string.match(questId, "^%s*(.-)%s*$") or ""
end

function QuestConfig.GetDefinitions()
	return DEFINITIONS
end

function QuestConfig.GetDefinition(questId: string)
	return definitionsById[QuestConfig.NormalizeQuestId(questId)]
end

function QuestConfig.GetActiveQuestIds(dayKey: string?): { string }
	local ids = copyArray(orderedIds)
	local rng = Random.new(hashString(tostring(dayKey or "")))

	for index = #ids, 2, -1 do
		local swapIndex = rng:NextInteger(1, index)
		ids[index], ids[swapIndex] = ids[swapIndex], ids[index]
	end

	local activeIds = {}
	local count = math.min(QuestConfig.ActiveDailyCount, #ids)
	for index = 1, count do
		table.insert(activeIds, ids[index])
	end

	table.sort(activeIds, function(left, right)
		return (orderById[left] or math.huge) < (orderById[right] or math.huge)
	end)

	return activeIds
end

function QuestConfig.IsActiveQuest(dayKey: string?, questId: string): boolean
	for _, activeQuestId in ipairs(QuestConfig.GetActiveQuestIds(dayKey)) do
		if activeQuestId == questId then
			return true
		end
	end
	return false
end

return QuestConfig
