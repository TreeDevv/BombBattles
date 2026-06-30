local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

local TeamPerspective = {}

TeamPerspective.Roles = table.freeze({
	Friendly = "Friendly",
	Enemy = "Enemy",
	Neutral = "Neutral",
})

TeamPerspective.Colors = table.freeze({
	Friendly = Color3.fromRGB(72, 171, 255),
	Enemy = Color3.fromRGB(255, 78, 78),
	Neutral = Color3.fromRGB(255, 255, 255),
	Draw = Color3.fromRGB(255, 209, 92),
})

local TEAM_ORDER = table.freeze({
	RoundConfig.Teams.Red.name,
	RoundConfig.Teams.Blue.name,
})

function TeamPerspective.GetTeamOrder(): { string }
	return { TEAM_ORDER[1], TEAM_ORDER[2] }
end

function TeamPerspective.GetPlayerTeamName(player: Player?): string?
	if not player then
		return nil
	end

	local teamName = player:GetAttribute("RoundTeam")
	if typeof(teamName) == "string" and teamName ~= "" then
		return teamName
	end

	local team = player.Team
	return if team then team.Name else nil
end

function TeamPerspective.GetOtherTeamName(teamName: string?): string?
	if teamName == TEAM_ORDER[1] then
		return TEAM_ORDER[2]
	end
	if teamName == TEAM_ORDER[2] then
		return TEAM_ORDER[1]
	end
	return nil
end

function TeamPerspective.ResolveTeams(localTeamName: string?): (string?, string?)
	if typeof(localTeamName) == "string" and localTeamName ~= "" then
		local enemyTeamName = TeamPerspective.GetOtherTeamName(localTeamName)
		if enemyTeamName then
			return localTeamName, enemyTeamName
		end
	end

	return TEAM_ORDER[2], TEAM_ORDER[1]
end

function TeamPerspective.GetRoleForTeam(teamName: string?, localTeamName: string?): string
	if typeof(teamName) ~= "string" or teamName == "" then
		return TeamPerspective.Roles.Neutral
	end

	local friendlyTeamName, enemyTeamName = TeamPerspective.ResolveTeams(localTeamName)
	if teamName == friendlyTeamName then
		return TeamPerspective.Roles.Friendly
	end
	if teamName == enemyTeamName then
		return TeamPerspective.Roles.Enemy
	end

	return TeamPerspective.Roles.Neutral
end

function TeamPerspective.GetRoleForPlayer(player: Player?, localPlayer: Player?): string
	return TeamPerspective.GetRoleForTeam(
		TeamPerspective.GetPlayerTeamName(player),
		TeamPerspective.GetPlayerTeamName(localPlayer)
	)
end

function TeamPerspective.GetColorForRole(role: string?): Color3
	if role == TeamPerspective.Roles.Friendly then
		return TeamPerspective.Colors.Friendly
	end
	if role == TeamPerspective.Roles.Enemy then
		return TeamPerspective.Colors.Enemy
	end
	return TeamPerspective.Colors.Neutral
end

function TeamPerspective.GetColorForTeam(teamName: string?, localTeamName: string?): Color3
	return TeamPerspective.GetColorForRole(TeamPerspective.GetRoleForTeam(teamName, localTeamName))
end

return table.freeze(TeamPerspective)
