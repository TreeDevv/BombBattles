local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local TeamPerspective = require(ReplicatedStorage.Shared.Common.TeamPerspective)
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local REMOTES_FOLDER_NAME = "Remotes"
local REPORT_PREFERRED_INPUT_REMOTE_NAME = "ReportPreferredInput"
local ROUND_TEAM_ATTR = "RoundTeam"
local CONTROLLER_ENTRY_ATTR = "ScoreboardControllerEntry"
local SCALE_NAME = "ScoreboardControllerScale"

local OPEN_TWEEN = TweenInfo.new(0.1, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HIDDEN_SCALE = 0.985

local PLATFORM_IMAGES = {
	KeyboardAndMouse = "rbxassetid://110858289830145",
	Touch = "rbxassetid://107363908444987",
	Gamepad = "rbxassetid://72151703998638",
}

local VALID_PLATFORM = {
	KeyboardAndMouse = true,
	Touch = true,
	Gamepad = true,
}

type ScoreStats = {
	damage: number,
	eliminations: number,
	assists: number,
	deaths: number,
}

type Row = {
	root: Frame,
	playerIcon: ImageLabel?,
	platformIcon: ImageLabel?,
	username: TextLabel?,
	damage: TextLabel?,
	eliminations: TextLabel?,
	assists: TextLabel?,
	deaths: TextLabel?,
	player: Player?,
	token: number,
}

type TeamView = {
	list: ScrollingFrame?,
	prototype: Frame?,
	rows: { [Player]: Row },
}

local ScoreboardController = {}

ScoreboardController._connections = {} :: { RBXScriptConnection }
ScoreboardController._playerConnections = {} :: { [Player]: { RBXScriptConnection } }
ScoreboardController._thumbnailCache = {} :: { [number]: string }
ScoreboardController._teamViews = {} :: { [string]: TeamView }
ScoreboardController._scoreboard = nil :: Frame?
ScoreboardController._scale = nil :: UIScale?
ScoreboardController._visibilityTween = nil :: Tween?
ScoreboardController._framesChildConnection = nil :: RBXScriptConnection?
ScoreboardController._tabHeld = false
ScoreboardController._mobileHeld = false
ScoreboardController._reportRemote = nil :: RemoteEvent?
ScoreboardController._currentPlatform = nil :: string?
ScoreboardController._lastReportedPlatform = nil :: string?

local function findChild(parent: Instance?, childName: string): Instance?
	return if parent then parent:FindFirstChild(childName) else nil
end

local function findTextLabel(parent: Instance?, childName: string): TextLabel?
	local child = findChild(parent, childName)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findImageLabel(parent: Instance?, childName: string): ImageLabel?
	local child = findChild(parent, childName)
	return if child and child:IsA("ImageLabel") then child else nil
end

local function getPlayerKey(player: Player): string
	return tostring(player.UserId)
end

local function getPlayerTeamName(player: Player): string?
	return TeamPerspective.GetPlayerTeamName(player)
end

local function getPlayersForTeam(teamName: string): { Player }
	local teamPlayers = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if getPlayerTeamName(player) == teamName then
			table.insert(teamPlayers, player)
		end
	end
	return teamPlayers
end

local function getAllPlayers(): { Player }
	local allPlayers = {}
	for _, player in ipairs(Players:GetPlayers()) do
		table.insert(allPlayers, player)
	end
	return allPlayers
end

local function getStateStats(player: Player): ScoreStats
	local state = RoundController:GetState()
	local scoreboardStats = state and state.scoreboardStats
	local stats = if typeof(scoreboardStats) == "table" then scoreboardStats[getPlayerKey(player)] else nil

	return {
		damage = if typeof(stats) == "table" and typeof(stats.damage) == "number" then stats.damage else 0,
		eliminations = if typeof(stats) == "table" and typeof(stats.eliminations) == "number" then stats.eliminations else 0,
		assists = if typeof(stats) == "table" and typeof(stats.assists) == "number" then stats.assists else 0,
		deaths = if typeof(stats) == "table" and typeof(stats.deaths) == "number" then stats.deaths else 0,
	}
end

local function formatStat(value: number): string
	return tostring(math.max(0, math.floor(value + 0.5)))
end

local function normalizePlatform(platform: any): string
	if typeof(platform) == "string" and VALID_PLATFORM[platform] then
		return platform
	end

	return "KeyboardAndMouse"
end

local function getPreferredPlatformName(): string
	local ok, preferredInput = pcall(function()
		return UserInputService.PreferredInput
	end)

	if ok and typeof(preferredInput) == "EnumItem" then
		local inputName = preferredInput.Name
		if VALID_PLATFORM[inputName] then
			return inputName
		end
	end

	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Gamepad"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Touch"
	end

	return "KeyboardAndMouse"
end

local function disableDefaultPlayerList()
	for _ = 1, 3 do
		local success = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		end)
		if success then
			return
		end
		task.wait(0.25)
	end
end

local function sortPlayers(players: { Player })
	table.sort(players, function(left: Player, right: Player): boolean
		local leftStats = getStateStats(left)
		local rightStats = getStateStats(right)

		if leftStats.eliminations ~= rightStats.eliminations then
			return leftStats.eliminations > rightStats.eliminations
		end
		if leftStats.damage ~= rightStats.damage then
			return leftStats.damage > rightStats.damage
		end
		if leftStats.deaths ~= rightStats.deaths then
			return leftStats.deaths < rightStats.deaths
		end
		local leftIsLocal = left == LocalPlayer
		local rightIsLocal = right == LocalPlayer
		if leftIsLocal ~= rightIsLocal then
			return leftIsLocal
		end

		return left.Name:lower() < right.Name:lower()
	end)
end

function ScoreboardController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function ScoreboardController:_disconnectAll()
	if self._framesChildConnection then
		self._framesChildConnection:Disconnect()
		self._framesChildConnection = nil
	end

	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}

	for player, connections in pairs(self._playerConnections) do
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		self._playerConnections[player] = nil
	end
end

function ScoreboardController:_getReportRemote(): RemoteEvent?
	if self._reportRemote and self._reportRemote.Parent then
		return self._reportRemote
	end

	local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(REPORT_PREFERRED_INPUT_REMOTE_NAME, 10)
	if remote and remote:IsA("RemoteEvent") then
		self._reportRemote = remote
		return remote
	end

	return nil
end

function ScoreboardController:_reportPreferredPlatform(force: boolean?)
	local platformName = getPreferredPlatformName()
	self._currentPlatform = platformName

	local remote = self:_getReportRemote()
	if remote and (force or self._lastReportedPlatform ~= platformName) then
		self._lastReportedPlatform = platformName
		remote:FireServer(platformName)
	end
	self:_syncRows()
end

function ScoreboardController:_ensureScale(frame: Frame): UIScale
	local scale = frame:FindFirstChild(SCALE_NAME)
	if not (scale and scale:IsA("UIScale")) then
		scale = Instance.new("UIScale")
		scale.Name = SCALE_NAME
		scale.Parent = frame
	end

	self._scale = scale
	return scale
end

function ScoreboardController:_cancelVisibilityTween()
	if self._visibilityTween then
		self._visibilityTween:Cancel()
		self._visibilityTween = nil
	end
end

function ScoreboardController:_setVisible(visible: boolean, instant: boolean?)
	local scoreboard = self._scoreboard
	if not scoreboard then
		return
	end

	local scale = self:_ensureScale(scoreboard)
	self:_cancelVisibilityTween()

	if visible then
		scoreboard.Visible = true
		if instant then
			scale.Scale = 1
			return
		end

		scale.Scale = HIDDEN_SCALE
		local tween = TweenService:Create(scale, OPEN_TWEEN, { Scale = 1 })
		self._visibilityTween = tween
		tween:Play()
		tween.Completed:Once(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed and self._visibilityTween == tween then
				self._visibilityTween = nil
			end
		end)
		return
	end

	if instant then
		scale.Scale = 1
		scoreboard.Visible = false
		return
	end

	local tween = TweenService:Create(scale, CLOSE_TWEEN, { Scale = HIDDEN_SCALE })
	self._visibilityTween = tween
	tween:Play()
	tween.Completed:Once(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed or self._visibilityTween ~= tween then
			return
		end

		scoreboard.Visible = false
		scale.Scale = 1
		self._visibilityTween = nil
	end)
end

function ScoreboardController:_buildRow(root: Frame): Row
	local inner = findChild(root, "Inner")
	local platform = findChild(inner, "Platform")
	local username = findChild(inner, "Username")
	local stats = findChild(inner, "Stats")

	return {
		root = root,
		playerIcon = findImageLabel(inner, "PlayerIcon"),
		platformIcon = findImageLabel(platform, "Icon"),
		username = findTextLabel(username, "Keybind"),
		damage = findTextLabel(stats, "Damage"),
		eliminations = findTextLabel(stats, "Eliminations"),
		assists = findTextLabel(stats, "Assists"),
		deaths = findTextLabel(stats, "Deaths"),
		player = nil,
		token = 0,
	}
end

function ScoreboardController:_loadThumbnail(row: Row, player: Player)
	if not row.playerIcon then
		return
	end

	local cached = self._thumbnailCache[player.UserId]
	if cached then
		row.playerIcon.Image = cached
		return
	end

	local token = row.token
	task.spawn(function()
		local success, content = pcall(function()
			return Players:GetUserThumbnailAsync(player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size420x420)
		end)

		if not success or typeof(content) ~= "string" or content == "" then
			return
		end

		self._thumbnailCache[player.UserId] = content
		if row.player == player and row.token == token and row.playerIcon then
			row.playerIcon.Image = content
		end
	end)
end

function ScoreboardController:_assignRow(row: Row, player: Player)
	if row.player ~= player then
		row.player = player
		row.token += 1
		self:_loadThumbnail(row, player)
	end

	row.root.Visible = true
	if row.username then
		row.username.Text = player.Name
	end
end

function ScoreboardController:_updateRow(row: Row)
	local player = row.player
	if not player then
		return
	end

	local stats = getStateStats(player)
	if row.damage then
		row.damage.Text = formatStat(stats.damage)
	end
	if row.eliminations then
		row.eliminations.Text = formatStat(stats.eliminations)
	end
	if row.assists then
		row.assists.Text = formatStat(stats.assists)
	end
	if row.deaths then
		row.deaths.Text = formatStat(stats.deaths)
	end

	local state = RoundController:GetState()
	local platforms = state and state.scoreboardPlatforms
	local platformName = if typeof(platforms) == "table" then normalizePlatform(platforms[getPlayerKey(player)]) else "KeyboardAndMouse"
	if player == LocalPlayer and self._currentPlatform then
		platformName = self._currentPlatform
	end

	if row.platformIcon then
		row.platformIcon.Image = PLATFORM_IMAGES[platformName] or PLATFORM_IMAGES.KeyboardAndMouse
	end
end

function ScoreboardController:_destroyTeamRows(teamView: TeamView?)
	if not teamView then
		return
	end

	for player, row in pairs(teamView.rows) do
		row.token += 1
		if row.root.Parent then
			row.root:Destroy()
		end
		teamView.rows[player] = nil
	end

	local list = teamView.list
	if list then
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("Frame") and child:GetAttribute(CONTROLLER_ENTRY_ATTR) == true then
				child:Destroy()
			end
		end
	end
end

function ScoreboardController:_buildTeamView(list: Instance?): TeamView
	local teamView = {
		list = if list and list:IsA("ScrollingFrame") then list else nil,
		prototype = nil,
		rows = {},
	}

	if not teamView.list then
		return teamView
	end

	local templates = {}
	for _, child in ipairs(teamView.list:GetChildren()) do
		if child:IsA("Frame") and child:GetAttribute(CONTROLLER_ENTRY_ATTR) == true then
			child:Destroy()
		elseif child:IsA("Frame") and child.Name == "Template" then
			table.insert(templates, child)
		end
	end

	table.sort(templates, function(left: Frame, right: Frame): boolean
		return left.LayoutOrder < right.LayoutOrder
	end)

	teamView.prototype = templates[1]
	if teamView.prototype then
		teamView.prototype.Visible = false
	end
	for index = 2, #templates do
		templates[index]:Destroy()
	end

	return teamView
end

function ScoreboardController:_syncTeamRows(teamKey: string, players: { Player })
	local teamView = self._teamViews[teamKey]
	if not (teamView and teamView.list and teamView.prototype) then
		return
	end

	sortPlayers(players)

	local used = {}
	for index, player in ipairs(players) do
		local row = teamView.rows[player]
		if not row or not row.root.Parent then
			local clone = teamView.prototype:Clone()
			clone.Name = "Player_" .. tostring(player.UserId)
			clone:SetAttribute(CONTROLLER_ENTRY_ATTR, true)
			clone.Parent = teamView.list
			row = self:_buildRow(clone)
			teamView.rows[player] = row
		end

		used[player] = true
		row.root.LayoutOrder = index
		self:_assignRow(row, player)
		self:_updateRow(row)
	end

	local stalePlayers = {}
	for player in pairs(teamView.rows) do
		if not used[player] then
			table.insert(stalePlayers, player)
		end
	end

	for _, player in ipairs(stalePlayers) do
		local row = teamView.rows[player]
		if row then
			row.token += 1
			if row.root.Parent then
				row.root:Destroy()
			end
		end
		teamView.rows[player] = nil
	end
end

function ScoreboardController:_getColumnPlayers(): ({ Player }, { Player })
	local allyTeam, enemyTeam = TeamPerspective.ResolveTeams(getPlayerTeamName(LocalPlayer))
	local allyPlayers = getPlayersForTeam(allyTeam)
	local enemyPlayers = getPlayersForTeam(enemyTeam)

	if #allyPlayers == 0 and #enemyPlayers == 0 then
		allyPlayers = getAllPlayers()
	end

	return allyPlayers, enemyPlayers
end

function ScoreboardController:_syncRows()
	if not self._scoreboard then
		return
	end

	local allyPlayers, enemyPlayers = self:_getColumnPlayers()
	self:_syncTeamRows("AllyTeam", allyPlayers)
	self:_syncTeamRows("EnemyTeam", enemyPlayers)
end

function ScoreboardController:_bindScoreboard(scoreboard: Instance?)
	for _, teamView in pairs(self._teamViews) do
		self:_destroyTeamRows(teamView)
	end
	self._teamViews = {}
	self._scoreboard = nil
	self._scale = nil
	self:_cancelVisibilityTween()

	if not (scoreboard and scoreboard:IsA("Frame")) then
		return
	end

	self._scoreboard = scoreboard
	self:_ensureScale(scoreboard)
	scoreboard.Visible = false

	self._teamViews.AllyTeam = self:_buildTeamView(scoreboard:FindFirstChild("AllyTeam"))
	self._teamViews.EnemyTeam = self:_buildTeamView(scoreboard:FindFirstChild("EnemyTeam"))
	self:_syncRows()

	if self._tabHeld or self._mobileHeld then
		self:_setVisible(true, true)
	end
end

function ScoreboardController:_bindFromPlayerGui()
	local frames = PlayerGui:FindFirstChild("Frames")
	self:_bindFramesGui(frames)
end

function ScoreboardController:_bindFramesGui(frames: Instance?)
	if self._framesChildConnection then
		self._framesChildConnection:Disconnect()
		self._framesChildConnection = nil
	end

	if not (frames and frames:IsA("ScreenGui")) then
		self:_bindScoreboard(nil)
		return
	end

	self:_bindScoreboard(frames:FindFirstChild("Scoreboard"))
	self._framesChildConnection = frames.ChildAdded:Connect(function(child)
		if child.Name == "Scoreboard" then
			task.defer(function()
				self:_bindScoreboard(child)
			end)
		end
	end)
end

function ScoreboardController:_trackPlayer(player: Player)
	if self._playerConnections[player] then
		return
	end

	self._playerConnections[player] = {
		player:GetAttributeChangedSignal(ROUND_TEAM_ATTR):Connect(function()
			self:_syncRows()
		end),
		player:GetPropertyChangedSignal("Team"):Connect(function()
			self:_syncRows()
		end),
	}
end

function ScoreboardController:_untrackPlayer(player: Player)
	local connections = self._playerConnections[player]
	if not connections then
		return
	end

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	self._playerConnections[player] = nil
	self:_syncRows()
end

function ScoreboardController:_handleInputBegan(input: InputObject, gameProcessed: boolean)
	if input.KeyCode ~= Enum.KeyCode.Tab then
		return
	end
	if UserInputService:GetFocusedTextBox() then
		return
	end

	self._tabHeld = true
	self:_syncRows()
	self:_setVisible(true)
end

function ScoreboardController:_handleInputEnded(input: InputObject)
	if input.KeyCode ~= Enum.KeyCode.Tab then
		return
	end

	self._tabHeld = false
	self:_setVisible(self._mobileHeld)
end

function ScoreboardController:SetMobileHeld(held: boolean)
	local nextHeld = held == true
	if self._mobileHeld == nextHeld then
		return
	end

	self._mobileHeld = nextHeld
	if nextHeld then
		self:_syncRows()
	end
	self:_setVisible(self._tabHeld or self._mobileHeld)
end

function ScoreboardController:OnStart()
	self:_disconnectAll()
	self._thumbnailCache = {}
	self._currentPlatform = nil
	self._lastReportedPlatform = nil
	self._reportRemote = nil
	self._tabHeld = false
	self._mobileHeld = false

	for _, player in ipairs(Players:GetPlayers()) do
		self:_trackPlayer(player)
	end

	self:_trackConnection(Players.PlayerAdded:Connect(function(player)
		self:_trackPlayer(player)
		self:_syncRows()
	end))
	self:_trackConnection(Players.PlayerRemoving:Connect(function(player)
		self:_untrackPlayer(player)
	end))
	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "Frames" then
			task.defer(function()
				self:_bindFramesGui(child)
			end)
		end
	end))
	self:_trackConnection(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		self:_handleInputBegan(input, gameProcessed)
	end))
	self:_trackConnection(UserInputService.InputEnded:Connect(function(input)
		self:_handleInputEnded(input)
	end))
	local preferredSignalOk, preferredSignal = pcall(function()
		return UserInputService:GetPropertyChangedSignal("PreferredInput")
	end)
	if preferredSignalOk then
		self:_trackConnection(preferredSignal:Connect(function()
			task.defer(function()
				self:_reportPreferredPlatform(false)
			end)
		end))
	end
	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self:_syncRows()
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "scoreboardStats" or key == "scoreboardPlatforms" or key == "roundId" or key == "state" then
			self:_syncRows()
		end
	end))

	task.spawn(disableDefaultPlayerList)
	self:_bindFromPlayerGui()
	task.spawn(function()
		self:_reportPreferredPlatform(true)
	end)
end

return ScoreboardController
