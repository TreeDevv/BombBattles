local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local RoundController = require(script.Parent:WaitForChild("RoundController"))
local ReplayClient = require(script.Parent:WaitForChild("Replay"):WaitForChild("ReplayClient"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ROUND_TEAM_ATTR = "RoundTeam"
local ROUND_ALIVE_ATTR = "RoundAlive"
local ROUND_RESPAWN_ENDS_AT_ATTR = "RoundRespawnEndsAt"
local CONTROLLER_ENTRY_ATTR = "TopHUDControllerEntry"

local LEFT_TEAM_NAME = RoundConfig.Teams.Red.name
local RIGHT_TEAM_NAME = RoundConfig.Teams.Blue.name
local TEAM_ORDER = { LEFT_TEAM_NAME, RIGHT_TEAM_NAME }

local NUKE_REVEAL_SECONDS = 60
local FULL_BLACKOUT_OFFSET = Vector2.new(0, 0.5)
local EMPTY_BLACKOUT_OFFSET = Vector2.new(0, -0.5)
local TOP_SLIDE_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local RESPAWN_SPIN_TWEEN = TweenInfo.new(8, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1)
local NUKE_SIZE_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local NUKE_FADE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

type Slot = {
	root: Frame,
	portrait: ImageLabel?,
	gradient: UIGradient?,
	respawnTimer: TextLabel?,
	skull: ImageLabel?,
	player: Player?,
	token: number,
}

type TeamView = {
	playerList: Frame?,
	prototype: Frame?,
	slots: { [Player]: Slot },
}

local TopHUDController = {}

TopHUDController._connections = {} :: { RBXScriptConnection }
TopHUDController._playerConnections = {} :: { [Player]: { RBXScriptConnection } }
TopHUDController._thumbnailCache = {} :: { [number]: string }
TopHUDController._teamViews = {} :: { [string]: TeamView }
TopHUDController._spawnerLabels = {} :: { [string]: TextLabel }
TopHUDController._top = nil :: Frame?
TopHUDController._topNativePosition = nil :: UDim2?
TopHUDController._topHiddenPosition = nil :: UDim2?
TopHUDController._topShown = false
TopHUDController._topTween = nil :: Tween?
TopHUDController._replayTopbarActive = false
TopHUDController._rosterSyncSerial = 0
TopHUDController._nukeTimer = nil :: Frame?
TopHUDController._nukeTimerLabel = nil :: TextLabel?
TopHUDController._nukeOriginalSize = nil :: UDim2?
TopHUDController._nukeCollapsedSize = nil :: UDim2?
TopHUDController._nukeShown = false
TopHUDController._nukeTweens = {} :: { Tween }
TopHUDController._nukeFaders = {} :: { [Instance]: { property: string, value: number } }
TopHUDController._respawnSpinTweens = {} :: { Tween }

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

local function getServerTime(): number
	return workspace:GetServerTimeNow()
end

local function getNumberAttribute(instance: Instance, attrName: string, fallback: number): number
	local value = instance:GetAttribute(attrName)
	return if typeof(value) == "number" then value else fallback
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function getGradientOffset(progress: number): Vector2
	progress = math.clamp(progress, 0, 1)
	return EMPTY_BLACKOUT_OFFSET:Lerp(FULL_BLACKOUT_OFFSET, progress)
end

local function setNukeFaderValue(item: Instance, propertyName: string, value: number)
	(item :: any)[propertyName] = value
end

local function getPlayersForTeam(teamName: string): { Player }
	local teamPlayers = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local playerTeamName = player:GetAttribute(ROUND_TEAM_ATTR)
		if playerTeamName == nil and player.Team then
			playerTeamName = player.Team.Name
		end

		if playerTeamName == teamName then
			table.insert(teamPlayers, player)
		end
	end
	return teamPlayers
end

local function shouldShowTopBar(state: string?): boolean
	return state == RoundStates.RoundStarting or state == RoundStates.Active
end

local function isReplayTopbarVisible(hud: Instance?): boolean
	if not hud then
		return false
	end

	local killReplay = hud:FindFirstChild("KillReplay")
	if killReplay and killReplay:IsA("GuiObject") and killReplay.Visible then
		return true
	end

	local potg = hud:FindFirstChild("POTG")
	return potg ~= nil and potg:IsA("GuiObject") and potg.Visible
end

function TopHUDController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function TopHUDController:_disconnectAll()
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

function TopHUDController:_resetSlot(slot: Slot)
	slot.player = nil
	slot.token += 1
	slot.root.Visible = false

	if slot.gradient then
		slot.gradient.Enabled = false
		slot.gradient.Offset = EMPTY_BLACKOUT_OFFSET
	end
	if slot.respawnTimer then
		slot.respawnTimer.Visible = false
	end
	if slot.skull then
		slot.skull.Visible = false
	end
end

function TopHUDController:_loadThumbnail(slot: Slot, player: Player)
	if not slot.portrait then
		return
	end

	local token = slot.token
	local cached = self._thumbnailCache[player.UserId]
	if cached then
		slot.portrait.Image = cached
		return
	end

	task.spawn(function()
		local success, content = pcall(function()
			local image = Players:GetUserThumbnailAsync(
				player.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size420x420
			)
			return image
		end)

		if not success or typeof(content) ~= "string" or content == "" then
			return
		end

		self._thumbnailCache[player.UserId] = content
		if slot.player == player and slot.token == token and slot.portrait then
			slot.portrait.Image = content
		end
	end)
end

function TopHUDController:_assignSlot(slot: Slot, player: Player)
	if slot.player == player then
		return
	end

	slot.player = player
	slot.token += 1
	slot.root.Visible = true
	self:_loadThumbnail(slot, player)
end

function TopHUDController:_getSlotState(slot: Slot): (boolean, number)
	local player = slot.player
	if not player then
		return false, 0
	end

	if player:GetAttribute(ROUND_ALIVE_ATTR) == false then
		return false, 0
	end

	local respawnEndsAt = getNumberAttribute(player, ROUND_RESPAWN_ENDS_AT_ATTR, 0)
	return true, math.max(respawnEndsAt - getServerTime(), 0)
end

function TopHUDController:_updateSlot(slot: Slot)
	if not slot.player then
		return
	end

	local isAlive, respawnRemaining = self:_getSlotState(slot)
	if not isAlive then
		if slot.gradient then
			slot.gradient.Enabled = true
			slot.gradient.Offset = FULL_BLACKOUT_OFFSET
		end
		if slot.respawnTimer then
			slot.respawnTimer.Visible = false
		end
		if slot.skull then
			slot.skull.Visible = true
		end
		return
	end

	if respawnRemaining > 0 then
		local respawnProgress = respawnRemaining / math.max(RoundConfig.RespawnSeconds, 0.01)
		if slot.gradient then
			slot.gradient.Enabled = true
			slot.gradient.Offset = getGradientOffset(respawnProgress)
		end
		if slot.respawnTimer then
			slot.respawnTimer.Visible = true
			slot.respawnTimer.Text = tostring(math.max(1, math.ceil(respawnRemaining)))
		end
		if slot.skull then
			slot.skull.Visible = false
		end
		return
	end

	if slot.gradient then
		slot.gradient.Enabled = false
		slot.gradient.Offset = EMPTY_BLACKOUT_OFFSET
	end
	if slot.respawnTimer then
		slot.respawnTimer.Visible = false
	end
	if slot.skull then
		slot.skull.Visible = false
	end
end

function TopHUDController:_buildSlot(root: Frame): Slot
	local portrait = findImageLabel(root, "PlayerTemplate")
	return {
		root = root,
		portrait = portrait,
		gradient = if portrait then portrait:FindFirstChildWhichIsA("UIGradient") else nil,
		respawnTimer = findTextLabel(root, "RespawnTimer"),
		skull = findImageLabel(root, "Skull"),
		player = nil,
		token = 0,
	}
end

function TopHUDController:_destroyTeamEntries(teamView: TeamView?)
	if not teamView then
		return
	end

	for player, slot in pairs(teamView.slots) do
		slot.token += 1
		if slot.root.Parent then
			slot.root:Destroy()
		end
		teamView.slots[player] = nil
	end

	local playerList = teamView.playerList
	if playerList then
		for _, child in ipairs(playerList:GetChildren()) do
			if child:IsA("Frame") and child:GetAttribute(CONTROLLER_ENTRY_ATTR) == true then
				child:Destroy()
			end
		end
	end
end

function TopHUDController:_buildTeamView(playerList: Instance?): TeamView
	local teamView = {
		playerList = if playerList and playerList:IsA("Frame") then playerList else nil,
		prototype = nil,
		slots = {},
	}

	if not teamView.playerList then
		return teamView
	end

	for _, child in ipairs(teamView.playerList:GetChildren()) do
		if child:IsA("Frame") and child:GetAttribute(CONTROLLER_ENTRY_ATTR) == true then
			child:Destroy()
		elseif child:IsA("Frame") and child.Name == "PlayerTemplate" then
			teamView.prototype = teamView.prototype or child
			self:_resetSlot(self:_buildSlot(child))
		end
	end

	return teamView
end

function TopHUDController:_syncTeamRoster(teamName: string)
	local teamView = self._teamViews[teamName]
	if not (teamView and teamView.playerList and teamView.prototype) then
		return
	end

	local used = {}
	local players = getPlayersForTeam(teamName)
	for index, player in ipairs(players) do
		local slot = teamView.slots[player]
		if not slot or not slot.root.Parent then
			local clone = teamView.prototype:Clone()
			clone.Name = "Player_" .. tostring(player.UserId)
			clone:SetAttribute(CONTROLLER_ENTRY_ATTR, true)
			clone.Parent = teamView.playerList
			slot = self:_buildSlot(clone)
			teamView.slots[player] = slot
		end

		used[player] = true
		slot.root.LayoutOrder = index
		slot.root.Visible = true
		self:_assignSlot(slot, player)
		self:_updateSlot(slot)
	end

	local stalePlayers = {}
	for player in pairs(teamView.slots) do
		if not used[player] then
			table.insert(stalePlayers, player)
		end
	end

	for _, player in ipairs(stalePlayers) do
		local slot = teamView.slots[player]
		if slot then
			slot.token += 1
			if slot.root.Parent then
				slot.root:Destroy()
			end
		end
		teamView.slots[player] = nil
	end
end

function TopHUDController:_syncRosters()
	for _, teamName in ipairs(TEAM_ORDER) do
		self:_syncTeamRoster(teamName)
	end
end

function TopHUDController:_deferRosterSync()
	self._rosterSyncSerial += 1
	local serial = self._rosterSyncSerial

	task.defer(function()
		if serial == self._rosterSyncSerial then
			self:_syncRosters()
		end
	end)

	task.delay(0.15, function()
		if serial == self._rosterSyncSerial then
			self:_syncRosters()
		end
	end)
end

function TopHUDController:_syncSpawnerCounts()
	local state = RoundController:GetState()
	local coreCounts = state and state.coreCounts

	for _, teamName in ipairs(TEAM_ORDER) do
		local label = self._spawnerLabels[teamName]
		if label then
			local count = if typeof(coreCounts) == "table" and typeof(coreCounts[teamName]) == "number" then coreCounts[teamName] else 0
			label.Text = tostring(count)
		end
	end
end

function TopHUDController:_cancelNukeTweens()
	for _, tween in ipairs(self._nukeTweens) do
		tween:Cancel()
	end
	self._nukeTweens = {}
end

function TopHUDController:_cancelRespawnSpinTweens()
	for _, tween in ipairs(self._respawnSpinTweens) do
		tween:Cancel()
	end
	self._respawnSpinTweens = {}
end

function TopHUDController:_startRespawnSpinner(label: ImageLabel?, direction: number)
	if not label then
		return
	end

	label.Rotation = label.Rotation % 360
	local tween = TweenService:Create(label, RESPAWN_SPIN_TWEEN, {
		Rotation = label.Rotation + 360 * direction,
	})
	table.insert(self._respawnSpinTweens, tween)
	tween:Play()
end

function TopHUDController:_setNukeFaders(transparent: boolean, tween: boolean)
	for item, fader in pairs(self._nukeFaders) do
		if item.Parent then
			local target = if transparent then 1 else fader.value
			if tween then
				local goal = {}
				goal[fader.property] = target
				local itemTween = TweenService:Create(item, NUKE_FADE_TWEEN, goal)
				table.insert(self._nukeTweens, itemTween)
				itemTween:Play()
			else
				setNukeFaderValue(item, fader.property, target)
			end
		end
	end
end

function TopHUDController:_setNukeVisible(visible: boolean)
	local nukeTimer = self._nukeTimer
	if not (nukeTimer and self._nukeOriginalSize and self._nukeCollapsedSize) then
		return
	end
	if self._nukeShown == visible then
		return
	end

	self:_cancelNukeTweens()
	self._nukeShown = visible

	if visible then
		nukeTimer.Visible = true
		nukeTimer.Size = self._nukeCollapsedSize
		self:_setNukeFaders(true, false)

		local sizeTween = TweenService:Create(nukeTimer, NUKE_SIZE_TWEEN, { Size = self._nukeOriginalSize })
		table.insert(self._nukeTweens, sizeTween)
		sizeTween:Play()
		self:_setNukeFaders(false, true)
		return
	end

	self:_setNukeFaders(true, true)
	local sizeTween = TweenService:Create(nukeTimer, NUKE_SIZE_TWEEN, { Size = self._nukeCollapsedSize })
	table.insert(self._nukeTweens, sizeTween)
	sizeTween:Play()
	sizeTween.Completed:Once(function()
		if not self._nukeShown and nukeTimer.Parent then
			nukeTimer.Visible = false
		end
	end)
end

function TopHUDController:_captureNukeTimer(nukeTimer: Frame?)
	self._nukeTimer = nukeTimer
	self._nukeTimerLabel = nil
	self._nukeOriginalSize = nil
	self._nukeCollapsedSize = nil
	self._nukeFaders = {}
	self._nukeShown = false
	self:_cancelNukeTweens()

	if not nukeTimer then
		return
	end

	self._nukeTimerLabel = findTextLabel(nukeTimer, "Timer")
	self._nukeOriginalSize = nukeTimer.Size
	self._nukeCollapsedSize = UDim2.new(0, 0, nukeTimer.Size.Y.Scale, nukeTimer.Size.Y.Offset)

	for _, item in ipairs(nukeTimer:GetDescendants()) do
		if item:IsA("ImageLabel") then
			self._nukeFaders[item] = { property = "ImageTransparency", value = item.ImageTransparency }
		elseif item:IsA("TextLabel") then
			self._nukeFaders[item] = { property = "TextTransparency", value = item.TextTransparency }
		elseif item:IsA("UIStroke") then
			self._nukeFaders[item] = { property = "Transparency", value = item.Transparency }
		end
	end

	nukeTimer.Visible = false
	nukeTimer.Size = self._nukeCollapsedSize
	self:_setNukeFaders(true, false)
end

function TopHUDController:_updateNukeTimer()
	local state = RoundController:GetState()
	local roundState = state and state.state
	local endsAt = if state and typeof(state.endsAt) == "number" then state.endsAt else 0
	local remaining = math.max(endsAt - getServerTime(), 0)
	local shouldShow = roundState == RoundStates.Active and remaining > 0 and remaining <= NUKE_REVEAL_SECONDS

	if self._nukeTimerLabel then
		self._nukeTimerLabel.Text = formatTime(remaining)
	end

	self:_setNukeVisible(shouldShow)
end

function TopHUDController:_setTopVisible(visible: boolean, instant: boolean?)
	local top = self._top
	if not (top and self._topNativePosition and self._topHiddenPosition) then
		return
	end
	if self._topShown == visible and top.Visible == visible and not instant then
		return
	end

	self._topShown = visible
	if self._topTween then
		self._topTween:Cancel()
		self._topTween = nil
	end

	local targetPosition = if visible then self._topNativePosition else self._topHiddenPosition

	if visible then
		top.Visible = true
	end

	if instant then
		top.Position = targetPosition
		top.Visible = visible
		return
	end

	self._topTween = TweenService:Create(top, TOP_SLIDE_TWEEN, { Position = targetPosition })
	self._topTween:Play()
	self._topTween.Completed:Once(function()
		if self._top == top and not self._topShown then
			top.Visible = false
		end
	end)
end

function TopHUDController:_updateTopVisibility(instant: boolean?)
	local state = RoundController:GetState()
	self:_setTopVisible(shouldShowTopBar(state and state.state) and not self._replayTopbarActive, instant)
end

function TopHUDController:_updateFrame()
	for _, teamView in pairs(self._teamViews) do
		for _, slot in pairs(teamView.slots) do
			self:_updateSlot(slot)
		end
	end

	self:_updateNukeTimer()
end

function TopHUDController:_bindHud(hud: Instance?)
	for _, teamView in pairs(self._teamViews) do
		self:_destroyTeamEntries(teamView)
	end
	self._teamViews = {}
	self._spawnerLabels = {}
	self._top = nil
	self._topNativePosition = nil
	self._topHiddenPosition = nil
	self._topShown = false
	if self._topTween then
		self._topTween:Cancel()
		self._topTween = nil
	end
	self:_cancelRespawnSpinTweens()
	self:_captureNukeTimer(nil)

	if not hud then
		return
	end
	self._replayTopbarActive = isReplayTopbarVisible(hud)

	local top = hud:FindFirstChild("Top")
	if not (top and top:IsA("Frame")) then
		return
	end
	self._top = top
	self._topNativePosition = top.Position
	self._topHiddenPosition = UDim2.new(
		top.Position.X.Scale,
		top.Position.X.Offset,
		top.Position.Y.Scale - top.Size.Y.Scale - 0.02,
		top.Position.Y.Offset - top.Size.Y.Offset
	)
	top.Position = self._topHiddenPosition
	top.Visible = false

	local leftTeam = top:FindFirstChild("LeftTeam")
	local rightTeam = top:FindFirstChild("RightTeam")
	local leftBackground = findChild(leftTeam, "Background")
	self:_startRespawnSpinner(findImageLabel(leftTeam, "Respawn"), 1)
	self:_startRespawnSpinner(findImageLabel(rightTeam, "Respawn"), -1)

	self._spawnerLabels[LEFT_TEAM_NAME] = findTextLabel(leftTeam, "SpawnerCount")
	self._spawnerLabels[RIGHT_TEAM_NAME] = findTextLabel(rightTeam, "SpawnerCount")
	self._teamViews[LEFT_TEAM_NAME] = self:_buildTeamView(findChild(leftBackground, "PlayerList"))
	self._teamViews[RIGHT_TEAM_NAME] = self:_buildTeamView(findChild(rightTeam, "PlayerList"))

	local nukeTimer = top:FindFirstChild("NukeTimer")
	self:_captureNukeTimer(if nukeTimer and nukeTimer:IsA("Frame") then nukeTimer else nil)

	self:_syncSpawnerCounts()
	self:_syncRosters()
	self:_updateNukeTimer()
	self:_updateTopVisibility(true)
end

function TopHUDController:_trackPlayer(player: Player)
	if self._playerConnections[player] then
		return
	end

	self._playerConnections[player] = {
		player:GetAttributeChangedSignal(ROUND_TEAM_ATTR):Connect(function()
			self:_deferRosterSync()
		end),
		player:GetAttributeChangedSignal(ROUND_ALIVE_ATTR):Connect(function()
			self:_syncRosters()
		end),
		player:GetAttributeChangedSignal(ROUND_RESPAWN_ENDS_AT_ATTR):Connect(function()
			self:_syncRosters()
		end),
		player:GetPropertyChangedSignal("Team"):Connect(function()
			self:_deferRosterSync()
		end),
	}
end

function TopHUDController:_untrackPlayer(player: Player)
	local connections = self._playerConnections[player]
	if not connections then
		return
	end

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	self._playerConnections[player] = nil
	self:_syncRosters()
end

function TopHUDController:_bindReplaySignals()
	local replayStarted = ReplayClient and ReplayClient.ReplayStarted
	if replayStarted and type(replayStarted.Connect) == "function" then
		self:_trackConnection(replayStarted:Connect(function()
			self._replayTopbarActive = isReplayTopbarVisible(PlayerGui:FindFirstChild("HUD"))
			self:_updateTopVisibility(false)
		end))
	end

	local replayEnded = ReplayClient and ReplayClient.ReplayEnded
	if replayEnded and type(replayEnded.Connect) == "function" then
		self:_trackConnection(replayEnded:Connect(function()
			self._replayTopbarActive = isReplayTopbarVisible(PlayerGui:FindFirstChild("HUD"))
			self:_updateTopVisibility(false)
		end))
	end
end

function TopHUDController:OnStart()
	self:_disconnectAll()
	self._replayTopbarActive = isReplayTopbarVisible(PlayerGui:FindFirstChild("HUD"))

	for _, player in ipairs(Players:GetPlayers()) do
		self:_trackPlayer(player)
	end

	self:_trackConnection(Players.PlayerAdded:Connect(function(player)
		self:_trackPlayer(player)
		self:_deferRosterSync()
	end))
	self:_trackConnection(Players.PlayerRemoving:Connect(function(player)
		self:_untrackPlayer(player)
	end))
	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" then
			task.defer(function()
				self:_bindHud(child)
			end)
		end
	end))
	self:_trackConnection(RoundController.StateReceived:Connect(function()
		self:_syncSpawnerCounts()
		self:_deferRosterSync()
		self:_updateNukeTimer()
		self:_updateTopVisibility(true)
	end))
	self:_trackConnection(RoundController.StateUpdated:Connect(function(key)
		if key == "coreCounts" then
			self:_syncSpawnerCounts()
		elseif key == "state" or key == "endsAt" or key == "roundId" then
			self:_deferRosterSync()
			self:_updateNukeTimer()
			self:_updateTopVisibility(false)
		end
	end))
	self:_trackConnection(RunService.RenderStepped:Connect(function()
		self:_updateFrame()
	end))
	self:_bindReplaySignals()

	self:_bindHud(PlayerGui:FindFirstChild("HUD"))
end

return TopHUDController
