local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FrameController = require(script.Parent:WaitForChild("FrameController"))
local POTGCutsceneController = require(script.Parent:WaitForChild("POTGCutsceneController"))
local ReplayClient = require(script.Parent:WaitForChild("Replay"):WaitForChild("ReplayClient"))
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundController = require(script.Parent:WaitForChild("RoundController"))
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local ScreenEffects = require(ReplicatedStorage.Shared.UI.ScreenEffects)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local RESULTS_FRAME_NAME = "ResultsScreen"
local FRAMES_GUI_NAME = "Frames"
local ENTRY_ATTRIBUTE = "ResultsScreenControllerEntry"
local EXCLUSIVE_ATTRIBUTE = FrameController.ExclusiveAttribute
local ROUND_TEAM_ATTR = "RoundTeam"

local PLATFORM_IMAGES = {
	KeyboardAndMouse = "rbxassetid://110858289830145",
	Touch = "rbxassetid://107363908444987",
	Gamepad = "rbxassetid://72151703998638",
}

local TEAM_ORDER = { RoundConfig.Teams.Red.name, RoundConfig.Teams.Blue.name }

type PlayerResult = {
	userId: number,
	name: string,
	displayName: string?,
	teamName: string?,
	platform: string?,
	stats: { [string]: number },
	rewards: { [string]: any },
}

type Row = {
	root: Frame,
	playerIcon: ImageLabel?,
	platformIcon: ImageLabel?,
	username: TextLabel?,
	damage: TextLabel?,
	eliminations: TextLabel?,
	deaths: TextLabel?,
	destruction: TextLabel?,
	token: number,
}

local ResultsScreenController = {}

ResultsScreenController._connections = {} :: { RBXScriptConnection }
ResultsScreenController._frame = nil :: Frame?
ResultsScreenController._closeButton = nil :: GuiButton?
ResultsScreenController._scrollingFrame = nil :: ScrollingFrame?
ResultsScreenController._winnerTemplate = nil :: Frame?
ResultsScreenController._loserTemplate = nil :: Frame?
ResultsScreenController._rows = {} :: { Row }
ResultsScreenController._thumbnailCache = {} :: { [number]: string }
ResultsScreenController._dismissedRoundId = nil :: number?
ResultsScreenController._shownRoundId = nil :: number?
ResultsScreenController._snapshot = nil

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

local function getStatValue(stats, key: string): number
	if typeof(stats) ~= "table" then
		return 0
	end

	local value = tonumber(stats[key]) or 0
	if value ~= value or value < 0 then
		return 0
	end

	return value
end

local function getRewardValue(rewards, key: string): number
	if typeof(rewards) ~= "table" then
		return 0
	end

	local value = tonumber(rewards[key]) or 0
	if value ~= value or value < 0 then
		return 0
	end

	return value
end

local function formatInteger(value: number): string
	local rounded = tostring(math.max(0, math.floor(value + 0.5)))
	local formatted = rounded
	while true do
		local nextFormatted, count = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2", 1)
		formatted = nextFormatted
		if count == 0 then
			return formatted
		end
	end
end

local function formatKd(eliminations: number, deaths: number): string
	if deaths <= 0 then
		return string.format("%.2f", math.max(0, eliminations))
	end

	return string.format("%.2f", math.max(0, eliminations / deaths))
end

local function getMapDisplayName(mapId: string): string
	for _, mapConfig in ipairs(RoundConfig.Maps) do
		if mapConfig.id == mapId and typeof(mapConfig.displayName) == "string" and mapConfig.displayName ~= "" then
			return mapConfig.displayName
		end
	end

	return mapId
end

local function getPlayerResult(results, userId: number): PlayerResult?
	if typeof(results) ~= "table" or typeof(results.players) ~= "table" then
		return nil
	end

	for _, playerResult in ipairs(results.players) do
		if typeof(playerResult) == "table" and playerResult.userId == userId then
			return playerResult
		end
	end

	return nil
end

local function getResultPlayers(results): { PlayerResult }
	local players = {}
	if typeof(results) ~= "table" or typeof(results.players) ~= "table" then
		return players
	end

	for _, playerResult in ipairs(results.players) do
		if typeof(playerResult) == "table" and typeof(playerResult.userId) == "number" then
			table.insert(players, playerResult :: PlayerResult)
		end
	end

	return players
end

local function isPOTGReplayActive(): boolean
	if type(ReplayClient.GetActiveReplayDebugInfo) ~= "function" then
		return false
	end

	local debugInfo = ReplayClient:GetActiveReplayDebugInfo()
	return typeof(debugInfo) == "table" and debugInfo.replayType == "POTGReplay"
end

local function sortPlayerResults(players: { PlayerResult })
	table.sort(players, function(left: PlayerResult, right: PlayerResult): boolean
		local leftStats = left.stats or {}
		local rightStats = right.stats or {}

		local leftElims = getStatValue(leftStats, "eliminations")
		local rightElims = getStatValue(rightStats, "eliminations")
		if leftElims ~= rightElims then
			return leftElims > rightElims
		end

		local leftDamage = getStatValue(leftStats, "damage")
		local rightDamage = getStatValue(rightStats, "damage")
		if leftDamage ~= rightDamage then
			return leftDamage > rightDamage
		end

		local leftDestruction = getStatValue(leftStats, "destruction")
		local rightDestruction = getStatValue(rightStats, "destruction")
		if leftDestruction ~= rightDestruction then
			return leftDestruction > rightDestruction
		end

		local leftDeaths = getStatValue(leftStats, "deaths")
		local rightDeaths = getStatValue(rightStats, "deaths")
		if leftDeaths ~= rightDeaths then
			return leftDeaths < rightDeaths
		end

		return tostring(left.name or ""):lower() < tostring(right.name or ""):lower()
	end)
end

local function findStatLabel(frame: Frame?, rowName: string): TextLabel?
	local row = frame and frame:FindFirstChild(rowName)
	if not (row and row:IsA("Frame")) then
		return nil
	end

	return findTextLabel(row, "Stat")
end

local function setStatLabel(frame: Frame?, rowName: string, value: number)
	local label = findStatLabel(frame, rowName)
	if label then
		label.Text = formatInteger(value)
	end
end

local function collectTemplates(scrollingFrame: ScrollingFrame): { Frame }
	local templates = {}
	for _, child in ipairs(scrollingFrame:GetChildren()) do
		if child:IsA("Frame") and child:GetAttribute(ENTRY_ATTRIBUTE) ~= true then
			table.insert(templates, child)
		end
	end

	table.sort(templates, function(left: Frame, right: Frame): boolean
		if left.Name ~= right.Name then
			return left.Name < right.Name
		end
		return left.LayoutOrder < right.LayoutOrder
	end)

	return templates
end

function ResultsScreenController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function ResultsScreenController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
end

function ResultsScreenController:_destroyRows()
	for _, row in ipairs(self._rows) do
		row.token += 1
		if row.root.Parent then
			row.root:Destroy()
		end
	end
	self._rows = {}
end

function ResultsScreenController:_buildRow(root: Frame): Row
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
		deaths = findTextLabel(stats, "Deaths"),
		destruction = findTextLabel(stats, "Destruction"),
		token = 0,
	}
end

function ResultsScreenController:_loadThumbnail(row: Row, userId: number)
	if not row.playerIcon then
		return
	end

	local cached = self._thumbnailCache[userId]
	if cached then
		row.playerIcon.Image = cached
		return
	end

	row.token += 1
	local token = row.token
	task.spawn(function()
		local success, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size420x420)
		end)
		if not success or typeof(content) ~= "string" or content == "" then
			return
		end

		self._thumbnailCache[userId] = content
		if row.token == token and row.playerIcon then
			row.playerIcon.Image = content
		end
	end)
end

function ResultsScreenController:_setPersonalStats(playerResult: PlayerResult?)
	local frame = self._frame
	if not frame then
		return
	end

	local statsFrame = frame:FindFirstChild("Stats")
	if not (statsFrame and statsFrame:IsA("Frame")) then
		return
	end

	local stats = if playerResult then playerResult.stats else {}
	local rewards = if playerResult then playerResult.rewards else {}
	local damage = getStatValue(stats, "damage")
	local eliminations = getStatValue(stats, "eliminations")
	local deaths = getStatValue(stats, "deaths")
	local destruction = getStatValue(stats, "destruction")

	setStatLabel(statsFrame, "Damage", damage)

	local kdLabel = findStatLabel(statsFrame, "KD")
	if kdLabel then
		kdLabel.Text = formatKd(eliminations, deaths)
	end

	setStatLabel(statsFrame, "Elims", eliminations)
	setStatLabel(statsFrame, "Deaths", deaths)
	setStatLabel(statsFrame, "DestructionScore", destruction)
	setStatLabel(statsFrame, "CoinsEarned", getRewardValue(rewards, "baseCoins"))
	setStatLabel(statsFrame, "VIPBonus", getRewardValue(rewards, "vipBonusCoins"))
	setStatLabel(statsFrame, "TotalCoins", getRewardValue(rewards, "totalCoins"))
end

function ResultsScreenController:_setBanner(results, playerResult: PlayerResult?)
	local frame = self._frame
	if not frame then
		return
	end

	local victoryLabel = findTextLabel(frame, "VictoryLabel")
	local defeatLabel = findTextLabel(frame, "DefeatLabel")
	local winnerTeam = if typeof(results) == "table" and typeof(results.winnerTeam) == "string" then results.winnerTeam else ""
	local localTeam = if playerResult and typeof(playerResult.teamName) == "string" then playerResult.teamName else LocalPlayer:GetAttribute(ROUND_TEAM_ATTR)

	if winnerTeam == "Draw" then
		if victoryLabel then
			victoryLabel.Text = "DRAW"
			victoryLabel.Visible = true
		end
		if defeatLabel then
			defeatLabel.Visible = false
		end
		return
	end

	local won = typeof(localTeam) == "string" and localTeam == winnerTeam
	if victoryLabel then
		victoryLabel.Text = "VICTORY!"
		victoryLabel.Visible = won
	end
	if defeatLabel then
		defeatLabel.Text = "DEFEAT..."
		defeatLabel.Visible = not won
	end
end

function ResultsScreenController:_setMapName(results)
	local frame = self._frame
	if not frame then
		return
	end

	local mapName = findTextLabel(frame, "MapName")
	if not mapName then
		return
	end

	local displayName = if typeof(results) == "table" and typeof(results.mapDisplayName) == "string" and results.mapDisplayName ~= ""
		then results.mapDisplayName
		else nil
	if not displayName and typeof(results) == "table" and typeof(results.selectedMapId) == "string" then
		displayName = getMapDisplayName(results.selectedMapId)
	end

	mapName.Text = displayName or "Unknown Map"
end

function ResultsScreenController:_getTeamDisplayOrder(results): { string }
	local winnerTeam = if typeof(results) == "table" and typeof(results.winnerTeam) == "string" then results.winnerTeam else ""
	if winnerTeam ~= "" and winnerTeam ~= "Draw" then
		local order = { winnerTeam }
		for _, teamName in ipairs(TEAM_ORDER) do
			if teamName ~= winnerTeam then
				table.insert(order, teamName)
			end
		end
		return order
	end

	return TEAM_ORDER
end

function ResultsScreenController:_populateRow(row: Row, playerResult: PlayerResult, layoutOrder: number)
	row.root.LayoutOrder = layoutOrder
	row.root.Visible = true

	if row.username then
		row.username.Text = playerResult.name or ("Player " .. tostring(playerResult.userId))
	end

	local stats = playerResult.stats or {}
	if row.damage then
		row.damage.Text = formatInteger(getStatValue(stats, "damage"))
	end
	if row.eliminations then
		row.eliminations.Text = formatInteger(getStatValue(stats, "eliminations"))
	end
	if row.deaths then
		row.deaths.Text = formatInteger(getStatValue(stats, "deaths"))
	end
	if row.destruction then
		row.destruction.Text = formatInteger(getStatValue(stats, "destruction"))
	end

	if row.platformIcon then
		row.platformIcon.Image = PLATFORM_IMAGES[playerResult.platform or "KeyboardAndMouse"] or PLATFORM_IMAGES.KeyboardAndMouse
	end

	self:_loadThumbnail(row, playerResult.userId)
end

function ResultsScreenController:_setScoreboard(results)
	local scrollingFrame = self._scrollingFrame
	if not (scrollingFrame and self._winnerTemplate) then
		return
	end

	self:_destroyRows()

	local players = getResultPlayers(results)
	local playersByTeam = {}
	for _, playerResult in ipairs(players) do
		local teamName = if typeof(playerResult.teamName) == "string" and playerResult.teamName ~= "" then playerResult.teamName else "Unknown"
		playersByTeam[teamName] = playersByTeam[teamName] or {}
		table.insert(playersByTeam[teamName], playerResult)
	end

	local layoutOrder = 0
	local used = {}
	for index, teamName in ipairs(self:_getTeamDisplayOrder(results)) do
		local teamPlayers = playersByTeam[teamName] or {}
		used[teamName] = true
		sortPlayerResults(teamPlayers)

		for _, playerResult in ipairs(teamPlayers) do
			layoutOrder += 1
			local template = if index == 1 then self._winnerTemplate else self._loserTemplate or self._winnerTemplate
			local clone = template:Clone()
			clone.Name = "Player_" .. tostring(playerResult.userId)
			clone:SetAttribute(ENTRY_ATTRIBUTE, true)
			clone.Parent = scrollingFrame
			local row = self:_buildRow(clone)
			table.insert(self._rows, row)
			self:_populateRow(row, playerResult, layoutOrder)
		end
	end

	for teamName, teamPlayers in pairs(playersByTeam) do
		if not used[teamName] then
			sortPlayerResults(teamPlayers)
			for _, playerResult in ipairs(teamPlayers) do
				layoutOrder += 1
				local clone = (self._loserTemplate or self._winnerTemplate):Clone()
				clone.Name = "Player_" .. tostring(playerResult.userId)
				clone:SetAttribute(ENTRY_ATTRIBUTE, true)
				clone.Parent = scrollingFrame
				local row = self:_buildRow(clone)
				table.insert(self._rows, row)
				self:_populateRow(row, playerResult, layoutOrder)
			end
		end
	end
end

function ResultsScreenController:_render(results)
	self._snapshot = results

	local playerResult = getPlayerResult(results, LocalPlayer.UserId)
	self:_setBanner(results, playerResult)
	self:_setMapName(results)
	self:_setPersonalStats(playerResult)
	self:_setScoreboard(results)
end

function ResultsScreenController:_openForResults(results)
	if typeof(results) ~= "table" or typeof(results.roundId) ~= "number" then
		return
	end
	if self._dismissedRoundId == results.roundId or self._shownRoundId == results.roundId then
		return
	end
	if
		type(POTGCutsceneController.QueueAfterRoundIntro) == "function"
		and POTGCutsceneController:QueueAfterRoundIntro(function()
			self:_openForResults(results)
		end)
	then
		return
	end
	if isPOTGReplayActive() and ReplayClient.ReplayEnded and type(ReplayClient.ReplayEnded.Once) == "function" then
		ReplayClient.ReplayEnded:Once(function(payload)
			if typeof(payload) == "table" and payload.type == "POTGReplay" then
				self:_openForResults(results)
			end
		end)
		return
	end

	self._shownRoundId = results.roundId
	ScreenEffects.HoldBlack()
	self:_render(results)
	FrameController:OpenFrame(RESULTS_FRAME_NAME)
	task.defer(function()
		RunService.RenderStepped:Wait()
		ScreenEffects.FadeFromBlack(0.35)
	end)
end

function ResultsScreenController:_syncFromState()
	local state = RoundController:GetState()
	if typeof(state) ~= "table" then
		return
	end

	local results = state.roundResults
	if state.state == RoundStates.RoundEnding then
		self:_openForResults(results)
	elseif state.state == RoundStates.Resetting then
		FrameController:CloseFrame(RESULTS_FRAME_NAME, true)
	elseif state.state == RoundStates.MapVoting or state.state == RoundStates.Intermission or state.state == RoundStates.Active then
		self._dismissedRoundId = nil
		self._shownRoundId = nil
		FrameController:CloseFrame(RESULTS_FRAME_NAME, true)
	end
end

function ResultsScreenController:_bindResultsScreen(frame: Instance?)
	self:_destroyRows()
	self._frame = nil
	self._closeButton = nil
	self._scrollingFrame = nil
	self._winnerTemplate = nil
	self._loserTemplate = nil

	if not (frame and frame:IsA("Frame")) then
		return
	end

	self._frame = frame
	if not CollectionService:HasTag(frame, FrameController.FrameTag) then
		CollectionService:AddTag(frame, FrameController.FrameTag)
	end
	if frame:GetAttribute(EXCLUSIVE_ATTRIBUTE) == nil then
		frame:SetAttribute(EXCLUSIVE_ATTRIBUTE, true)
	end

	local closeButton = frame:FindFirstChild("CloseButton")
	if closeButton and closeButton:IsA("GuiButton") then
		self._closeButton = closeButton
		self:_trackConnection(closeButton.Activated:Connect(function()
			local state = RoundController:GetState()
			local results = state and state.roundResults
			if typeof(results) == "table" and typeof(results.roundId) == "number" then
				self._dismissedRoundId = results.roundId
			end
			FrameController:CloseFrame(RESULTS_FRAME_NAME)
		end))
	end

	local scoreboard = frame:FindFirstChild("Scoreboard")
	local scrollingFrame = scoreboard and scoreboard:FindFirstChild("ScrollingFrame")
	if scrollingFrame and scrollingFrame:IsA("ScrollingFrame") then
		self._scrollingFrame = scrollingFrame
		local friendlyTemplate = scrollingFrame:FindFirstChild("FriendlyTemplate")
		local enemyTemplate = scrollingFrame:FindFirstChild("EnemyTemplate")
		local templates = collectTemplates(scrollingFrame)

		self._winnerTemplate = if friendlyTemplate and friendlyTemplate:IsA("Frame") then friendlyTemplate else templates[1]
		self._loserTemplate = if enemyTemplate and enemyTemplate:IsA("Frame") then enemyTemplate else templates[2] or self._winnerTemplate

		for _, template in ipairs(templates) do
			template.Visible = false
		end
		if self._winnerTemplate then
			self._winnerTemplate.Visible = false
		end
		if self._loserTemplate then
			self._loserTemplate.Visible = false
		end
	end

	self:_syncFromState()
end

function ResultsScreenController:_bindFromPlayerGui()
	local frames = PlayerGui:FindFirstChild(FRAMES_GUI_NAME)
	self:_bindFramesGui(frames)
end

function ResultsScreenController:_bindFramesGui(frames: Instance?)
	if not (frames and frames:IsA("ScreenGui")) then
		self:_bindResultsScreen(nil)
		return
	end

	self:_bindResultsScreen(frames:FindFirstChild(RESULTS_FRAME_NAME))
	self:_trackConnection(frames.ChildAdded:Connect(function(child)
		if child.Name == RESULTS_FRAME_NAME then
			task.defer(function()
				self:_bindResultsScreen(child)
			end)
		end
	end))
end

function ResultsScreenController:OnStart()
	self:_disconnectAll()
	self._thumbnailCache = {}
	self._dismissedRoundId = nil
	self._shownRoundId = nil
	self._snapshot = nil

	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == FRAMES_GUI_NAME then
			task.defer(function()
				self:_bindFramesGui(child)
			end)
		end
	end))
	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self:_syncFromState()
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "roundResults" or key == "state" or key == "roundId" then
			self:_syncFromState()
		end
	end))

	self:_bindFromPlayerGui()
end

return ResultsScreenController
