local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local RoundService = require(ServerScriptService.Services.RoundService)

local GAME_SCREEN_PATH = { "Lobby", "GameScreen" }
local PLAYER_COUNTER_PATH = { "Lobby", "PlayerCounter" }
local UPDATE_INTERVAL_SECONDS = 0.25
local AFK_ATTR = "AFK"
local ROUND_ID_ATTR = "RoundId"

local RED_TEAM_NAME = RoundConfig.Teams.Red.name
local BLUE_TEAM_NAME = RoundConfig.Teams.Blue.name

local widgets = nil
local started = false
local missingWidgetsWarned = false

local function findChild(parent: Instance?, childName: string): Instance?
	return if parent then parent:FindFirstChild(childName) else nil
end

local function findGameScreen(): Instance?
	local current: Instance? = Workspace
	for _, childName in ipairs(GAME_SCREEN_PATH) do
		current = findChild(current, childName)
		if not current then
			return nil
		end
	end

	return current
end

local function findPlayerCounter(): Instance?
	local current: Instance? = Workspace
	for _, childName in ipairs(PLAYER_COUNTER_PATH) do
		current = findChild(current, childName)
		if not current then
			return nil
		end
	end

	return current
end

local function findSurfaceGui(root: Instance?, path: { string }): SurfaceGui?
	local current = root
	for _, childName in ipairs(path) do
		current = findChild(current, childName)
		if not current then
			return nil
		end
	end

	return if current and current:IsA("SurfaceGui") then current else nil
end

local function findTextLabel(parent: Instance?, childName: string): TextLabel?
	local child = findChild(parent, childName)
	return if child and child:IsA("TextLabel") then child else nil
end

local function getSurfaceHeading(surfaceGui: SurfaceGui?): TextLabel?
	local frame = findChild(surfaceGui, "Frame")
	return findTextLabel(frame, "Heading")
end

local function bindWidgets()
	local gameScreen = findGameScreen()
	local playerCounter = findPlayerCounter()
	if not (gameScreen and playerCounter) then
		return nil
	end

	local gameProgressGui = findSurfaceGui(gameScreen, { "MainScreen", "GAMEPROGRESS" })
	local timerGui = findSurfaceGui(gameScreen, { "MiddleScreen", "TIMER" })
	local redRespawnsGui = findSurfaceGui(gameScreen, { "LeftScreen", "RedTeamRespawns" })
	local blueRespawnsGui = findSurfaceGui(gameScreen, { "RightScreen", "BlueTeamRespawns" })
	local aliveCounterGui = findSurfaceGui(playerCounter, { "LeftScreen", "ALIVE" })
	local inServerCounterGui = findSurfaceGui(playerCounter, { "MiddleScreen", "InServer" })
	local playingCounterGui = findSurfaceGui(playerCounter, { "RightScreen", "Playing" })

	local gameProgressFrame = findChild(gameProgressGui, "Frame")
	local aliveCounterFrame = findChild(aliveCounterGui, "Frame")
	local inServerCounterFrame = findChild(inServerCounterGui, "Frame")
	local playingCounterFrame = findChild(playingCounterGui, "Frame")
	local mainHeading = findTextLabel(gameProgressFrame, "Heading")
	local subheading = findTextLabel(gameProgressFrame, "Subheading")
	local timerLabel = getSurfaceHeading(timerGui)
	local redRespawnsLabel = getSurfaceHeading(redRespawnsGui)
	local blueRespawnsLabel = getSurfaceHeading(blueRespawnsGui)
	local aliveCounterValue = findTextLabel(aliveCounterFrame, "Value")
	local inServerCounterValue = findTextLabel(inServerCounterFrame, "Value")
	local playingCounterValue = findTextLabel(playingCounterFrame, "Value")

	if not (
		mainHeading
		and subheading
		and timerLabel
		and redRespawnsGui
		and redRespawnsLabel
		and blueRespawnsGui
		and blueRespawnsLabel
		and aliveCounterValue
		and inServerCounterValue
		and playingCounterValue
	) then
		return nil
	end

	return {
		mainHeading = mainHeading,
		subheading = subheading,
		timerLabel = timerLabel,
		redRespawnsGui = redRespawnsGui,
		redRespawnsLabel = redRespawnsLabel,
		blueRespawnsGui = blueRespawnsGui,
		blueRespawnsLabel = blueRespawnsLabel,
		aliveCounterValue = aliveCounterValue,
		inServerCounterValue = inServerCounterValue,
		playingCounterValue = playingCounterValue,
	}
end

local function areWidgetsAlive(currentWidgets): boolean
	return currentWidgets
		and currentWidgets.mainHeading:IsDescendantOf(Workspace)
		and currentWidgets.subheading:IsDescendantOf(Workspace)
		and currentWidgets.timerLabel:IsDescendantOf(Workspace)
		and currentWidgets.redRespawnsGui:IsDescendantOf(Workspace)
		and currentWidgets.redRespawnsLabel:IsDescendantOf(Workspace)
		and currentWidgets.blueRespawnsGui:IsDescendantOf(Workspace)
		and currentWidgets.blueRespawnsLabel:IsDescendantOf(Workspace)
		and currentWidgets.aliveCounterValue:IsDescendantOf(Workspace)
		and currentWidgets.inServerCounterValue:IsDescendantOf(Workspace)
		and currentWidgets.playingCounterValue:IsDescendantOf(Workspace)
end

local function getWidgets()
	if areWidgetsAlive(widgets) then
		return widgets
	end

	widgets = bindWidgets()
	if widgets then
		missingWidgetsWarned = false
	elseif not missingWidgetsWarned then
		warn("[GameScreenService] Missing GameScreen or PlayerCounter widgets under Workspace.Lobby")
		missingWidgetsWarned = true
	end

	return widgets
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function getRemainingSeconds(state): number
	local endsAt = if state and typeof(state.endsAt) == "number" then state.endsAt else 0
	if endsAt <= 0 then
		return 0
	end

	return math.max(endsAt - Workspace:GetServerTimeNow(), 0)
end

local function formatRoundEnding(state): string
	local winnerTeam = if state and typeof(state.winnerTeam) == "string" then state.winnerTeam else ""
	if winnerTeam == "Draw" then
		return "Draw!"
	end
	if winnerTeam == RED_TEAM_NAME or winnerTeam == BLUE_TEAM_NAME then
		return winnerTeam .. " wins!"
	end

	local status = if state and typeof(state.status) == "string" then state.status else ""
	if status ~= "" then
		return if string.match(status, "[!%.%?]$") then status else status .. "!"
	end

	return "Round ending..."
end

local function formatSubheading(state): string
	local stateName = state and state.state

	if stateName == RoundStates.WaitingForPlayers then
		return "Waiting for players..."
	elseif stateName == RoundStates.Intermission then
		return "Intermission..."
	elseif stateName == RoundStates.AssigningTeams then
		return "Assigning teams..."
	elseif stateName == RoundStates.RoundStarting then
		return "Round starting..."
	elseif stateName == RoundStates.Active then
		return "Round in progress..."
	elseif stateName == RoundStates.RoundEnding then
		return formatRoundEnding(state)
	elseif stateName == RoundStates.Resetting then
		return "Resetting..."
	end

	return "Waiting for players..."
end

local function getCoreCount(state, teamName: string): number
	local coreCounts = state and state.coreCounts
	local count = if typeof(coreCounts) == "table" then coreCounts[teamName] else 0
	count = tonumber(count) or 0
	if count ~= count or count < 0 then
		return 0
	end

	return math.floor(count + 0.5)
end

local function getAlivePlayerCount(state): number
	if not (state and state.state == RoundStates.Active) then
		return 0
	end

	local aliveCounts = state.aliveCounts
	if typeof(aliveCounts) ~= "table" then
		return 0
	end

	local count = (tonumber(aliveCounts[RED_TEAM_NAME]) or 0) + (tonumber(aliveCounts[BLUE_TEAM_NAME]) or 0)
	if count ~= count or count < 0 then
		return 0
	end

	return math.floor(count + 0.5)
end

local function getPlayingPlayerCount(state): number
	local isActive = state and state.state == RoundStates.Active
	local roundId = if state and typeof(state.roundId) == "number" then state.roundId else nil
	local count = 0

	for _, player in ipairs(Players:GetPlayers()) do
		if player.Parent == Players and player:GetAttribute(AFK_ATTR) ~= true then
			if isActive then
				if roundId and player:GetAttribute(ROUND_ID_ATTR) == roundId then
					count += 1
				end
			else
				count += 1
			end
		end
	end

	return count
end

local function render()
	local currentWidgets = getWidgets()
	if not currentWidgets then
		return
	end

	local state = RoundService:GetState()
	local isActive = state and state.state == RoundStates.Active

	currentWidgets.mainHeading.Text = tostring(RoundConfig.GameModeDisplayName or "TEAM DEATHMATCH")
	currentWidgets.subheading.Text = formatSubheading(state)
	currentWidgets.timerLabel.Text = formatTime(getRemainingSeconds(state))

	currentWidgets.redRespawnsGui.Enabled = isActive
	currentWidgets.blueRespawnsGui.Enabled = isActive
	currentWidgets.redRespawnsLabel.Text = tostring(getCoreCount(state, RED_TEAM_NAME))
	currentWidgets.blueRespawnsLabel.Text = tostring(getCoreCount(state, BLUE_TEAM_NAME))
	currentWidgets.aliveCounterValue.Text = tostring(getAlivePlayerCount(state))
	currentWidgets.inServerCounterValue.Text = tostring(#Players:GetPlayers())
	currentWidgets.playingCounterValue.Text = tostring(getPlayingPlayerCount(state))
end

local GameScreenService = {}

function GameScreenService:OnStart()
	if started then
		return
	end
	started = true

	task.spawn(function()
		while true do
			render()
			task.wait(UPDATE_INTERVAL_SECONDS)
		end
	end)
end

return GameScreenService
