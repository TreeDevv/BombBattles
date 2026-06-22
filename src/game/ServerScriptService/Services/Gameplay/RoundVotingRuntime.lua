local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

local RoundVotingRuntime = {}

type MapConfig = {
	id: string,
	displayName: string,
	thumbnailImage: string?,
}

type VoteChoice = {
	choiceId: string,
	mapId: string,
	displayName: string,
	thumbnailImage: string?,
}

function RoundVotingRuntime.MakeChoice(mapConfig: MapConfig, occurrence: number): VoteChoice
	return {
		choiceId = if occurrence <= 1 then mapConfig.id else mapConfig.id .. ":" .. tostring(occurrence),
		mapId = mapConfig.id,
		displayName = mapConfig.displayName,
		thumbnailImage = mapConfig.thumbnailImage,
	}
end

function RoundVotingRuntime.ChooseOptions(hasMapTemplate: (string) -> boolean, rng: Random): { VoteChoice }
	local available = {}
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		if hasMapTemplate(mapConfig.id) then
			table.insert(available, mapConfig)
		end
	end

	local choices = {}
	local sourceMaps = table.clone(available)
	local occurrences = {}
	while #available > 0 and #choices < RoundConfig.VoteChoiceCount do
		local index = rng:NextInteger(1, #available)
		local mapConfig = table.remove(available, index)
		occurrences[mapConfig.id] = (occurrences[mapConfig.id] or 0) + 1
		table.insert(choices, RoundVotingRuntime.MakeChoice(mapConfig, occurrences[mapConfig.id]))
	end

	while #sourceMaps > 0 and #choices < RoundConfig.VoteChoiceCount do
		local mapConfig = sourceMaps[rng:NextInteger(1, #sourceMaps)]
		occurrences[mapConfig.id] = (occurrences[mapConfig.id] or 0) + 1
		table.insert(choices, RoundVotingRuntime.MakeChoice(mapConfig, occurrences[mapConfig.id]))
	end

	return choices
end

function RoundVotingRuntime.GetChoice(choices: { VoteChoice }, choiceId: string): VoteChoice?
	for _, choice in ipairs(choices) do
		if choice.choiceId == choiceId then
			return choice
		end
	end
	return nil
end

function RoundVotingRuntime.HasChoice(choices: { VoteChoice }, choiceId: string): boolean
	return RoundVotingRuntime.GetChoice(choices, choiceId) ~= nil
end

function RoundVotingRuntime.ChooseWinningMap(choices: { VoteChoice }, voteCounts: { [string]: number }, rng: Random): string?
	local tied = {}
	local best = -math.huge

	for _, choice in ipairs(choices) do
		local count = voteCounts[choice.choiceId] or 0
		if count > best then
			best = count
			tied = { choice.choiceId }
		elseif count == best then
			table.insert(tied, choice.choiceId)
		end
	end

	if #tied == 0 then
		return nil
	end

	local winningChoice = RoundVotingRuntime.GetChoice(choices, tied[rng:NextInteger(1, #tied)])
	if winningChoice then
		return winningChoice.mapId
	end

	return nil
end

return table.freeze(RoundVotingRuntime)
