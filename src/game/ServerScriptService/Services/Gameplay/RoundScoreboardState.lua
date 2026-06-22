local RoundScoreboardState = {}
RoundScoreboardState.__index = RoundScoreboardState

local DEFAULT_STATS = {
	damage = 0,
	eliminations = 0,
	assists = 0,
	deaths = 0,
	destruction = 0,
}

local function normalizeStats(stats)
	for key, fallback in pairs(DEFAULT_STATS) do
		stats[key] = tonumber(stats[key]) or fallback
	end
	return stats
end

function RoundScoreboardState.new()
	return setmetatable({
		stats = {},
		platforms = {},
		recentDamageContributors = {},
	}, RoundScoreboardState)
end

function RoundScoreboardState.GetPlayerKey(playerOrUserId: Player | number | string): string
	if typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return tostring(playerOrUserId.UserId)
	end

	return tostring(playerOrUserId)
end

function RoundScoreboardState:GetStatsFor(playerOrUserId: Player | number | string)
	local key = RoundScoreboardState.GetPlayerKey(playerOrUserId)
	local stats = self.stats[key]
	if not stats then
		stats = table.clone(DEFAULT_STATS)
		self.stats[key] = stats
	end
	return normalizeStats(stats)
end

function RoundScoreboardState:Reset()
	self.stats = {}
	self.recentDamageContributors = {}
end

function RoundScoreboardState:ClearRecentDamageFor(player: Player)
	self.recentDamageContributors[RoundScoreboardState.GetPlayerKey(player)] = nil
end

function RoundScoreboardState:RemovePlayer(player: Player)
	local playerKey = RoundScoreboardState.GetPlayerKey(player)
	self.stats[playerKey] = nil
	self.platforms[playerKey] = nil
	self.recentDamageContributors[playerKey] = nil

	for _, contributors in pairs(self.recentDamageContributors) do
		contributors[playerKey] = nil
	end
end

function RoundScoreboardState:GetContributorsFor(player: Player, create: boolean?)
	local targetKey = RoundScoreboardState.GetPlayerKey(player)
	local contributors = self.recentDamageContributors[targetKey]
	if not contributors and create == true then
		contributors = {}
		self.recentDamageContributors[targetKey] = contributors
	end
	return contributors
end

function RoundScoreboardState:RecordContributor(target: Player, attackerKey: string, contributor)
	local contributors = self:GetContributorsFor(target, true)
	contributors[attackerKey] = contributor
end

function RoundScoreboardState:SetPreferredInput(player: Player, preferredInput: string): boolean
	local playerKey = RoundScoreboardState.GetPlayerKey(player)
	if self.platforms[playerKey] == preferredInput then
		return false
	end
	self.platforms[playerKey] = preferredInput
	return true
end

return RoundScoreboardState
