local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundController = require(script.Parent:WaitForChild("RoundController"))
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)

local LocalPlayer = Players.LocalPlayer

local ROUND_TEAM_ATTR = "RoundTeam"
local DEFAULT_DURATION = 3
local IMPORTANT_DURATION = 4

type RoundState = {
	roundId: number?,
	state: string?,
	status: string?,
	votingOpen: boolean?,
	selectedMapId: string?,
	winnerTeam: string?,
}

local GameStateNotificationController = {}

GameStateNotificationController._connections = {} :: { RBXScriptConnection }
GameStateNotificationController._lastState = nil :: string?
GameStateNotificationController._lastRoundId = nil :: number?
GameStateNotificationController._shownEvents = {} :: { [string]: boolean }
GameStateNotificationController._receivedInitialState = false

local function getRoundId(state: RoundState): number
	return if typeof(state.roundId) == "number" then state.roundId else 0
end

local function getMapDisplayName(mapId: string): string
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		if mapConfig.id == mapId and typeof(mapConfig.displayName) == "string" and mapConfig.displayName ~= "" then
			return mapConfig.displayName
		end
	end

	return mapId
end

local function getEventKey(roundId: number, key: string): string
	return tostring(roundId) .. ":" .. key
end

local function getLocalRoundTeam(): string?
	local teamName = LocalPlayer:GetAttribute(ROUND_TEAM_ATTR)
	return if typeof(teamName) == "string" and teamName ~= "" then teamName else nil
end

local function getWinnerMessage(winnerTeam: string): (string, string)
	if winnerTeam == "Draw" then
		return "Draw!", "Gold"
	end

	local localTeam = getLocalRoundTeam()
	if localTeam == winnerTeam then
		return "Victory!", "Green"
	end
	if localTeam and winnerTeam ~= "" then
		return "Defeat...", "Red"
	end

	return winnerTeam .. " wins!", "Gold"
end

function GameStateNotificationController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function GameStateNotificationController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
end

function GameStateNotificationController:_showOnce(roundId: number, key: string, text: string, color: string, duration: number?)
	local eventKey = getEventKey(roundId, key)
	if self._shownEvents[eventKey] then
		return
	end

	self._shownEvents[eventKey] = true
	Notify.Show(text, {
		color = color,
		duration = duration or DEFAULT_DURATION,
	})
end

function GameStateNotificationController:_showForState(state: RoundState, isInitial: boolean)
	local roundId = getRoundId(state)
	local stateName = state.state
	if typeof(stateName) ~= "string" then
		return
	end

	if self._lastRoundId ~= roundId then
		self._shownEvents = {}
		self._lastRoundId = roundId
	end

	if stateName == RoundStates.WaitingForPlayers then
		if not isInitial and self._lastState ~= RoundStates.WaitingForPlayers then
			self:_showOnce(roundId, "waiting", "Waiting for players", "Gold", DEFAULT_DURATION)
		end
	elseif stateName == RoundStates.Intermission then
		local text = if state.votingOpen == false then "Intermission" else "Intermission - vote for a map"
		self:_showOnce(roundId, "intermission", text, "Blue", DEFAULT_DURATION)
	elseif stateName == RoundStates.RoundStarting then
		self:_showOnce(roundId, "round-starting", "Round starting", "Gold", DEFAULT_DURATION)
	elseif stateName == RoundStates.Active then
		self:_showOnce(roundId, "active", "Battle started", "Green", DEFAULT_DURATION)
	elseif stateName == RoundStates.RoundEnding then
		local winnerTeam = state.winnerTeam
		if typeof(winnerTeam) == "string" and winnerTeam ~= "" then
			local message, color = getWinnerMessage(winnerTeam)
			self:_showOnce(roundId, "round-ending", message, color, IMPORTANT_DURATION)
		end
	end

	self._lastState = stateName
end

function GameStateNotificationController:_showMapSelected(state: RoundState, isInitial: boolean)
	if isInitial then
		return
	end

	local mapId = state.selectedMapId
	if typeof(mapId) ~= "string" or mapId == "" then
		return
	end

	self:_showOnce(getRoundId(state), "map-selected:" .. mapId, "Map selected: " .. getMapDisplayName(mapId), "Blue", DEFAULT_DURATION)
end

function GameStateNotificationController:_sync(isInitial: boolean?)
	local state = RoundController:GetState()
	if typeof(state) ~= "table" then
		return
	end

	self:_showMapSelected(state :: RoundState, isInitial == true)
	self:_showForState(state :: RoundState, isInitial == true)
end

function GameStateNotificationController:OnStart()
	self:_disconnectAll()
	self._lastState = nil
	self._lastRoundId = nil
	self._shownEvents = {}
	self._receivedInitialState = false

	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self._receivedInitialState = true
		self:_sync(true)
	end))

	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "state" or key == "roundId" or key == "selectedMapId" or key == "winnerTeam" or key == "votingOpen" then
			self:_sync(false)
		end
	end))

	if RoundController.Loaded then
		self._receivedInitialState = true
		self:_sync(true)
	end
end

return GameStateNotificationController
