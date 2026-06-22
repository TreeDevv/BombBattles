local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local HIGHLIGHT_NAME = "BombBattlesEnemyTeamHighlight"
local ROUND_TEAM_ATTR = "RoundTeam"
local ROUND_ALIVE_ATTR = "RoundAlive"
local FILL_TRANSPARENCY = 0.55
local OUTLINE_TRANSPARENCY = 0.05

local EnemyHighlightController = {}

EnemyHighlightController._connections = {} :: { RBXScriptConnection }
EnemyHighlightController._playerConnections = {} :: { [Player]: { RBXScriptConnection } }
EnemyHighlightController._characterConnections = {} :: { [Player]: { RBXScriptConnection } }
EnemyHighlightController._highlights = {} :: { [Player]: Highlight }

local function isRoundActive(): boolean
	local state = RoundController:GetState()
	return typeof(state) == "table" and state.state == RoundStates.Active
end

local function getTeamName(player: Player): string?
	local teamName = player:GetAttribute(ROUND_TEAM_ATTR)
	if typeof(teamName) == "string" and teamName ~= "" then
		return teamName
	end

	local team = player.Team
	return if team then team.Name else nil
end

local function getTeamColor(teamName: string?, player: Player): Color3
	if typeof(teamName) == "string" and teamName ~= "" then
		for _, teamConfig in pairs(RoundConfig.Teams) do
			if typeof(teamConfig) == "table" and teamConfig.name == teamName then
				local color = teamConfig.color
				if typeof(color) == "BrickColor" then
					return color.Color
				elseif typeof(color) == "Color3" then
					return color
				end
			end
		end
	end

	local team = player.Team
	if team then
		return team.TeamColor.Color
	end

	return Color3.new(1, 1, 1)
end

local function getAliveCharacter(player: Player): Model?
	local character = player.Character
	if not (character and character.Parent) then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end

	return character
end

function EnemyHighlightController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function EnemyHighlightController:_removeHighlight(player: Player)
	local highlight = self._highlights[player]
	self._highlights[player] = nil

	if highlight and highlight.Parent then
		highlight:Destroy()
	end

	local character = player.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child ~= highlight and child:IsA("Highlight") and child.Name == HIGHLIGHT_NAME then
				child:Destroy()
			end
		end
	end
end

function EnemyHighlightController:_ensureHighlight(player: Player, character: Model, color: Color3)
	local highlight = self._highlights[player]
	if highlight and highlight.Adornee == character and highlight.Parent == character then
		highlight.FillColor = color
		highlight.OutlineColor = color
		highlight.FillTransparency = FILL_TRANSPARENCY
		highlight.OutlineTransparency = OUTLINE_TRANSPARENCY
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		return
	end

	self:_removeHighlight(player)

	local staleHighlight = character:FindFirstChild(HIGHLIGHT_NAME)
	if staleHighlight and staleHighlight:IsA("Highlight") then
		staleHighlight:Destroy()
	end

	highlight = Instance.new("Highlight")
	highlight.Name = HIGHLIGHT_NAME
	highlight.Adornee = character
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = color
	highlight.FillTransparency = FILL_TRANSPARENCY
	highlight.OutlineColor = color
	highlight.OutlineTransparency = OUTLINE_TRANSPARENCY
	highlight.Parent = character

	self._highlights[player] = highlight
end

function EnemyHighlightController:_shouldHighlight(player: Player): (boolean, Model?, Color3?)
	if player == LocalPlayer or player.Parent ~= Players then
		return false, nil, nil
	end
	if not isRoundActive() or LocalPlayer:GetAttribute(ROUND_ALIVE_ATTR) ~= true then
		return false, nil, nil
	end
	if player:GetAttribute(ROUND_ALIVE_ATTR) ~= true then
		return false, nil, nil
	end

	local localTeamName = getTeamName(LocalPlayer)
	local targetTeamName = getTeamName(player)
	if not localTeamName or not targetTeamName or localTeamName == targetTeamName then
		return false, nil, nil
	end

	local character = getAliveCharacter(player)
	if not character then
		return false, nil, nil
	end

	return true, character, getTeamColor(targetTeamName, player)
end

function EnemyHighlightController:_syncPlayer(player: Player)
	local shouldHighlight, character, color = self:_shouldHighlight(player)
	if shouldHighlight and character and color then
		self:_ensureHighlight(player, character, color)
	else
		self:_removeHighlight(player)
	end
end

function EnemyHighlightController:_syncAll()
	for _, player in ipairs(Players:GetPlayers()) do
		self:_syncPlayer(player)
	end

	for player in pairs(self._highlights) do
		if player.Parent ~= Players then
			self:_removeHighlight(player)
		end
	end
end

function EnemyHighlightController:_disconnectCharacter(player: Player)
	local connections = self._characterConnections[player]
	if not connections then
		return
	end

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	self._characterConnections[player] = nil
end

function EnemyHighlightController:_bindCharacter(player: Player, character: Model?)
	self:_disconnectCharacter(player)
	if not character then
		self:_syncAll()
		return
	end

	local connections = {}
	self._characterConnections[player] = connections

	local function bindHumanoid(humanoid: Humanoid)
		table.insert(connections, humanoid.Died:Connect(function()
			self:_syncAll()
		end))
		table.insert(connections, humanoid:GetPropertyChangedSignal("Health"):Connect(function()
			if humanoid.Health <= 0 then
				self:_syncAll()
			end
		end))
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		bindHumanoid(humanoid)
	else
		table.insert(connections, character.ChildAdded:Connect(function(child)
			if child:IsA("Humanoid") then
				bindHumanoid(child)
				self:_syncAll()
			end
		end))
	end

	self:_syncAll()
end

function EnemyHighlightController:_trackPlayer(player: Player)
	if self._playerConnections[player] then
		return
	end

	self._playerConnections[player] = {
		player:GetAttributeChangedSignal(ROUND_TEAM_ATTR):Connect(function()
			self:_syncAll()
		end),
		player:GetAttributeChangedSignal(ROUND_ALIVE_ATTR):Connect(function()
			self:_syncAll()
		end),
		player:GetPropertyChangedSignal("Team"):Connect(function()
			self:_syncAll()
		end),
		player.CharacterAdded:Connect(function(character)
			self:_bindCharacter(player, character)
		end),
		player.CharacterRemoving:Connect(function()
			self:_disconnectCharacter(player)
			self:_removeHighlight(player)
			self:_syncAll()
		end),
	}

	self:_bindCharacter(player, player.Character)
end

function EnemyHighlightController:_untrackPlayer(player: Player)
	local connections = self._playerConnections[player]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end

	self._playerConnections[player] = nil
	self:_disconnectCharacter(player)
	self:_removeHighlight(player)
	self:_syncAll()
end

function EnemyHighlightController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)

	for player, connections in pairs(self._playerConnections) do
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		self._playerConnections[player] = nil
	end

	for player in pairs(self._characterConnections) do
		self:_disconnectCharacter(player)
	end

	for player in pairs(self._highlights) do
		self:_removeHighlight(player)
	end
end

function EnemyHighlightController:OnStart()
	self:_disconnectAll()

	for _, player in ipairs(Players:GetPlayers()) do
		self:_trackPlayer(player)
	end

	self:_trackConnection(Players.PlayerAdded:Connect(function(player)
		self:_trackPlayer(player)
		self:_syncAll()
	end))
	self:_trackConnection(Players.PlayerRemoving:Connect(function(player)
		self:_untrackPlayer(player)
	end))
	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self:_syncAll()
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "state" then
			self:_syncAll()
		end
	end))
end

function EnemyHighlightController:Destroy()
	self:_disconnectAll()
end

return EnemyHighlightController
