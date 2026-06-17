local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local AdminConfig = require(ReplicatedStorage.Shared.Config.AdminConfig)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local CrateRollController = require(script.Parent:WaitForChild("CrateRollController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local REMOTES_FOLDER_NAME = "Remotes"
local TOGGLE_KEY = Enum.KeyCode.F4

local AdminPanelController = {}

AdminPanelController._remote = nil :: RemoteFunction?
AdminPanelController._screenGui = nil :: ScreenGui?
AdminPanelController._panel = nil :: Frame?
AdminPanelController._statusLabel = nil :: TextLabel?
AdminPanelController._stateLabel = nil :: TextLabel?
AdminPanelController._targetLabel = nil :: TextLabel?
AdminPanelController._mapLabel = nil :: TextLabel?
AdminPanelController._speedInput = nil :: TextBox?
AdminPanelController._jumpInput = nil :: TextBox?
AdminPanelController._damageInput = nil :: TextBox?
AdminPanelController._bombSkinInput = nil :: TextBox?
AdminPanelController._leaderboardStatInput = nil :: TextBox?
AdminPanelController._wipeInput = nil :: TextBox?
AdminPanelController._players = {}
AdminPanelController._maps = {}
AdminPanelController._roundState = nil
AdminPanelController._replayDebugEnabled = false
AdminPanelController._targetIndex = 1
AdminPanelController._mapIndex = 1
AdminPanelController._authorized = false

local function getRemote(): RemoteFunction?
	local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(AdminConfig.RequestRemoteName, 10)
	return if remote and remote:IsA("RemoteFunction") then remote else nil
end

local function createCorner(parent: Instance, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 6)
	corner.Parent = parent
	return corner
end

local function createStroke(parent: Instance, color: Color3, transparency: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Transparency = transparency or 0
	stroke.Thickness = 1
	stroke.Parent = parent
	return stroke
end

local function styleTextButton(button: TextButton)
	button.AutoButtonColor = true
	button.BackgroundColor3 = Color3.fromRGB(48, 54, 62)
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamMedium
	button.TextColor3 = Color3.fromRGB(242, 245, 248)
	button.TextSize = 13
	button.TextWrapped = true
	createCorner(button, 5)
	createStroke(button, Color3.fromRGB(82, 92, 104), 0.25)
end

local function styleTextBox(textBox: TextBox)
	textBox.BackgroundColor3 = Color3.fromRGB(28, 32, 38)
	textBox.BorderSizePixel = 0
	textBox.ClearTextOnFocus = false
	textBox.Font = Enum.Font.Gotham
	textBox.PlaceholderColor3 = Color3.fromRGB(142, 150, 160)
	textBox.TextColor3 = Color3.fromRGB(242, 245, 248)
	textBox.TextSize = 13
	textBox.TextWrapped = false
	createCorner(textBox, 5)
	createStroke(textBox, Color3.fromRGB(75, 84, 96), 0.35)
end

local function parseNumber(textBox: TextBox?, fallback: number): number
	if not textBox then
		return fallback
	end

	local value = tonumber(textBox.Text)
	return if value then value else fallback
end

local function parsePositiveInteger(textBox: TextBox?): number?
	if not textBox then
		return nil
	end

	local value = tonumber(textBox.Text)
	if not value or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	if value <= 0 or value ~= math.floor(value) then
		return nil
	end

	return value
end

function AdminPanelController:_invoke(request)
	local remote = self._remote
	if not remote then
		return {
			ok = false,
			message = "Admin remote is unavailable",
		}
	end

	local ok, response = pcall(function()
		return remote:InvokeServer(request)
	end)
	if not ok then
		return {
			ok = false,
			message = tostring(response),
		}
	end
	if typeof(response) ~= "table" then
		return {
			ok = false,
			message = "Invalid admin response",
		}
	end

	return response
end

function AdminPanelController:_setStatus(message: string, ok: boolean?)
	if not self._statusLabel then
		return
	end

	self._statusLabel.Text = message
	self._statusLabel.TextColor3 = if ok == false then Color3.fromRGB(255, 138, 124) else Color3.fromRGB(172, 232, 164)
end

function AdminPanelController:_getSelectedPlayer()
	if #self._players == 0 then
		return nil
	end

	self._targetIndex = math.clamp(self._targetIndex, 1, #self._players)
	return self._players[self._targetIndex]
end

function AdminPanelController:_getSelectedMap()
	if #self._maps == 0 then
		return nil
	end

	self._mapIndex = math.clamp(self._mapIndex, 1, #self._maps)
	return self._maps[self._mapIndex]
end

function AdminPanelController:_updateLabels()
	local roundState = self._roundState
	if self._stateLabel then
		if typeof(roundState) == "table" then
			self._stateLabel.Text = string.format(
				"Round: %s | %s",
				tostring(roundState.state or "?"),
				tostring(roundState.status or "")
			)
		else
			self._stateLabel.Text = "Round: unavailable"
		end
	end

	if self._targetLabel then
		local selectedPlayer = self:_getSelectedPlayer()
		self._targetLabel.Text = if selectedPlayer
			then string.format("%s (%d)", selectedPlayer.name, selectedPlayer.userId)
			else "No target"
	end

	if self._mapLabel then
		local selectedMap = self:_getSelectedMap()
		self._mapLabel.Text = if selectedMap then selectedMap.displayName or selectedMap.id else "No map"
	end
end

function AdminPanelController:_applyState(data)
	if typeof(data) ~= "table" then
		return
	end

	if typeof(data.players) == "table" then
		local selectedPlayer = self:_getSelectedPlayer()
		local selectedUserId = selectedPlayer and selectedPlayer.userId
		self._players = data.players
		self._targetIndex = 1
		if selectedUserId then
			for index, playerInfo in ipairs(self._players) do
				if playerInfo.userId == selectedUserId then
					self._targetIndex = index
					break
				end
			end
		end
	end

	if typeof(data.maps) == "table" then
		self._maps = data.maps
	end
	if typeof(data.round) == "table" then
		self._roundState = data.round
	end
	if typeof(data.replayDebug) == "table" then
		self._replayDebugEnabled = data.replayDebug.enabled == true
	end

	self:_updateLabels()
end

function AdminPanelController:_refresh()
	local response = self:_invoke({
		action = "GetState",
	})
	if response.ok then
		self:_applyState(response.data)
	end
	return response
end

function AdminPanelController:_runCommand(command: string, payload)
	payload = if typeof(payload) == "table" then payload else {}

	local selectedPlayer = self:_getSelectedPlayer()
	if selectedPlayer and payload.targetUserId == nil then
		payload.targetUserId = selectedPlayer.userId
	end

	local response = self:_invoke({
		action = "Command",
		command = command,
		payload = payload,
	})

	self:_setStatus(response.message or "Done", response.ok)
	if response.data then
		self:_applyState(response.data)
	else
		self:_refresh()
	end
end

function AdminPanelController:_runLeaderboardStatCommand(statName: string)
	local amount = parsePositiveInteger(self._leaderboardStatInput)
	if not amount then
		self:_setStatus("Enter a positive whole-number stat amount", false)
		return
	end

	local increments = {
		kills = 0,
		wins = 0,
		destruction = 0,
	}
	increments[statName] = amount

	self:_runCommand("data.addLeaderboardStats", {
		increments = increments,
	})
end

function AdminPanelController:_addLabel(parent: Instance, text: string, height: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamMedium
	label.Text = text
	label.TextColor3 = Color3.fromRGB(212, 218, 226)
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Size = UDim2.new(1, 0, 0, height or 22)
	label.Parent = parent
	return label
end

function AdminPanelController:_addSection(parent: Instance, text: string)
	local label = self:_addLabel(parent, text, 24)
	label.TextColor3 = Color3.fromRGB(255, 207, 105)
	label.TextSize = 14
	return label
end

function AdminPanelController:_addButton(parent: Instance, text: string, activated: () -> ())
	local button = Instance.new("TextButton")
	button.Text = text
	button.Size = UDim2.new(1, 0, 0, 32)
	button.Parent = parent
	styleTextButton(button)
	button.Activated:Connect(activated)
	return button
end

function AdminPanelController:_addButtonRow(parent: Instance, buttons)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 32)
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	for _, buttonConfig in ipairs(buttons) do
		local button = Instance.new("TextButton")
		button.Text = buttonConfig.text
		button.Size = UDim2.new(1 / #buttons, -4, 1, 0)
		button.Parent = row
		styleTextButton(button)
		button.Activated:Connect(buttonConfig.activated)
	end

	return row
end

function AdminPanelController:_addInputRow(parent: Instance, labelText: string, defaultText: string): TextBox
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 32)
	row.Parent = parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.Text = labelText
	label.TextColor3 = Color3.fromRGB(198, 205, 214)
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Size = UDim2.new(0.45, -4, 1, 0)
	label.Parent = row

	local input = Instance.new("TextBox")
	input.Text = defaultText
	input.Size = UDim2.new(0.55, 0, 1, 0)
	input.Position = UDim2.new(0.45, 4, 0, 0)
	input.Parent = row
	styleTextBox(input)
	return input
end

function AdminPanelController:_buildPanel()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "AdminPanel"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = PlayerGui
	self._screenGui = screenGui

	local toggle = Instance.new("TextButton")
	toggle.Name = "Toggle"
	toggle.AnchorPoint = Vector2.new(1, 0)
	toggle.Position = UDim2.new(1, -18, 0, 18)
	toggle.Size = UDim2.fromOffset(86, 30)
	toggle.Text = "ADMIN"
	toggle.Parent = screenGui
	styleTextButton(toggle)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -18, 0, 56)
	panel.Size = UDim2.fromOffset(360, 520)
	panel.BackgroundColor3 = Color3.fromRGB(18, 22, 27)
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = screenGui
	createCorner(panel, 8)
	createStroke(panel, Color3.fromRGB(88, 98, 112), 0.12)
	self._panel = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 12)
	padding.PaddingBottom = UDim.new(0, 12)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = panel

	local title = self:_addLabel(panel, "Testing Admin", 24)
	title.Position = UDim2.fromOffset(0, 0)
	title.TextColor3 = Color3.fromRGB(245, 247, 250)
	title.TextSize = 16

	self._stateLabel = self:_addLabel(panel, "Round: loading", 22)
	self._stateLabel.Position = UDim2.fromOffset(0, 26)

	self._statusLabel = self:_addLabel(panel, "Ready", 22)
	self._statusLabel.Position = UDim2.fromOffset(0, 48)
	self._statusLabel.TextColor3 = Color3.fromRGB(172, 232, 164)

	local scroller = Instance.new("ScrollingFrame")
	scroller.Name = "Content"
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.Position = UDim2.fromOffset(0, 72)
	scroller.Size = UDim2.new(1, 0, 1, -72)
	scroller.CanvasSize = UDim2.fromOffset(0, 0)
	scroller.ScrollBarThickness = 5
	scroller.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroller
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		scroller.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 8)
	end)

	self:_addSection(scroller, "Target")
	self._targetLabel = self:_addLabel(scroller, "No target", 22)
	self:_addButtonRow(scroller, {
		{
			text = "Prev",
			activated = function()
				self._targetIndex = if #self._players > 0 then ((self._targetIndex - 2) % #self._players) + 1 else 1
				self:_updateLabels()
			end,
		},
		{
			text = "Next",
			activated = function()
				self._targetIndex = if #self._players > 0 then (self._targetIndex % #self._players) + 1 else 1
				self:_updateLabels()
			end,
		},
		{
			text = "Refresh",
			activated = function()
				local response = self:_refresh()
				self:_setStatus(response.message or "Refreshed", response.ok)
			end,
		},
	})

	self:_addSection(scroller, "Map")
	self._mapLabel = self:_addLabel(scroller, "No map", 22)
	self:_addButtonRow(scroller, {
		{
			text = "Prev",
			activated = function()
				self._mapIndex = if #self._maps > 0 then ((self._mapIndex - 2) % #self._maps) + 1 else 1
				self:_updateLabels()
			end,
		},
		{
			text = "Next",
			activated = function()
				self._mapIndex = if #self._maps > 0 then (self._mapIndex % #self._maps) + 1 else 1
				self:_updateLabels()
			end,
		},
	})

	self:_addSection(scroller, "Round")
	self._damageInput = self:_addInputRow(scroller, "Core damage", "25")
	self:_addButton(scroller, "Start Selected Map", function()
		local selectedMap = self:_getSelectedMap()
		self:_runCommand("round.forceStart", {
			mapId = selectedMap and selectedMap.id or nil,
		})
	end)
	self:_addButton(scroller, "Test Kill Feed", function()
		self:_runCommand("round.testKillFeed", {})
	end)
	self:_addButtonRow(scroller, {
		{ text = "Reset", activated = function() self:_runCommand("round.reset", {}) end },
		{ text = "Respawn All", activated = function() self:_runCommand("round.respawnAll", {}) end },
	})
	self:_addButtonRow(scroller, {
		{ text = "Red Wins", activated = function() self:_runCommand("round.end", { winnerTeam = "Red" }) end },
		{ text = "Blue Wins", activated = function() self:_runCommand("round.end", { winnerTeam = "Blue" }) end },
		{ text = "Draw", activated = function() self:_runCommand("round.end", { winnerTeam = "Draw" }) end },
	})
	self:_addButtonRow(scroller, {
		{
			text = "Damage Red Core",
			activated = function()
				self:_runCommand("round.damageCore", {
					teamName = "Red",
					damage = parseNumber(self._damageInput, 25),
				})
			end,
		},
		{
			text = "Damage Blue Core",
			activated = function()
				self:_runCommand("round.damageCore", {
					teamName = "Blue",
					damage = parseNumber(self._damageInput, 25),
				})
			end,
		},
	})
	self:_addButtonRow(scroller, {
		{ text = "Destroy Red Core", activated = function() self:_runCommand("round.destroyCore", { teamName = "Red" }) end },
		{ text = "Destroy Blue Core", activated = function() self:_runCommand("round.destroyCore", { teamName = "Blue" }) end },
	})

	self:_addSection(scroller, "Replay Debug")
	self:_addLabel(scroller, "Self replay works in Studio; other tools require ReplayDebugEnabled", 22)
	self:_addButtonRow(scroller, {
		{ text = "Print Counts", activated = function() self:_runCommand("replay.printCounts", {}) end },
		{ text = "Print POTG", activated = function() self:_runCommand("replay.printPOTG", {}) end },
	})
	self:_addButtonRow(scroller, {
		{ text = "Self Kill Replay", activated = function() self:_runCommand("replay.testSelfKillReplay", {}) end },
		{ text = "Test POTG", activated = function() self:_runCommand("replay.testPOTG", {}) end },
	})

	self:_addSection(scroller, "Cutscene")
	self:_addButton(scroller, "Play POTG Cutscene", function()
		self:_runCommand("cutscene.playPOTG", {})
	end)

	self:_addSection(scroller, "Player")
	self._speedInput = self:_addInputRow(scroller, "Walk speed", "24")
	self._jumpInput = self:_addInputRow(scroller, "Jump power", "60")
	self:_addButtonRow(scroller, {
		{ text = "Respawn", activated = function() self:_runCommand("round.respawnPlayer", {}) end },
		{ text = "Heal", activated = function() self:_runCommand("player.heal", {}) end },
		{ text = "Kill", activated = function() self:_runCommand("player.kill", {}) end },
	})
	self:_addButtonRow(scroller, {
		{ text = "To Me", activated = function() self:_runCommand("player.teleportToAdmin", {}) end },
		{ text = "To Lobby", activated = function() self:_runCommand("player.teleportToLobby", {}) end },
		{ text = "To Map", activated = function() self:_runCommand("player.teleportToMapSpawn", {}) end },
	})
	self:_addButtonRow(scroller, {
		{ text = "Refill Bombs", activated = function() self:_runCommand("player.refillBombs", {}) end },
		{ text = "Clear Bomb", activated = function() self:_runCommand("player.clearBombState", {}) end },
	})
	self._bombSkinInput = self:_addInputRow(scroller, "Bomb skin", BombSkinConfig.DefaultSkinId)
	self:_addButton(scroller, "Grant + Equip Bomb Skin", function()
		self:_runCommand("player.setBombSkin", {
			skinId = self._bombSkinInput and self._bombSkinInput.Text or BombSkinConfig.DefaultSkinId,
		})
	end)
	self:_addButton(scroller, "Test Crate Roll", function()
		local rawSkinId = self._bombSkinInput and self._bombSkinInput.Text or BombSkinConfig.DefaultSkinId
		local skinId = BombSkinConfig.NormalizeSkinId(rawSkinId)
		if skinId == "" then
			skinId = BombSkinConfig.DefaultSkinId
		end

		local definition = BombSkinConfig.GetDefinition(skinId)
		local played = CrateRollController:PlayRoll({
			skinId = skinId,
			displayName = definition and definition.displayName or skinId,
			iconImage = definition and definition.iconImage or BombSkinConfig.GetIconImage(skinId),
			rarity = "Legendary",
		})

		self:_setStatus(if played then "Testing crate roll: " .. skinId else "Crate roll UI unavailable", played)
	end)
	self:_addButton(scroller, "Demo All Explosions", function()
		self:_runCommand("bomb.demoAllExplosions", {})
	end)
	self:_addButtonRow(scroller, {
		{
			text = "Set Speed",
			activated = function()
				self:_runCommand("player.setWalkSpeed", {
					value = parseNumber(self._speedInput, 24),
				})
			end,
		},
		{
			text = "Set Jump",
			activated = function()
				self:_runCommand("player.setJumpPower", {
					value = parseNumber(self._jumpInput, 60),
				})
			end,
		},
	})

	self:_addSection(scroller, "Data")
	self._leaderboardStatInput = self:_addInputRow(scroller, "Stat amount", "1")
	self:_addButtonRow(scroller, {
		{ text = "+ Kills", activated = function() self:_runLeaderboardStatCommand("kills") end },
		{ text = "+ Wins", activated = function() self:_runLeaderboardStatCommand("wins") end },
		{ text = "+ Destruction", activated = function() self:_runLeaderboardStatCommand("destruction") end },
	})
	self._wipeInput = self:_addInputRow(scroller, "Confirm wipe", "")
	self._wipeInput.PlaceholderText = AdminConfig.DataWipeConfirmation
	self:_addButton(scroller, "Wipe Target Data", function()
		self:_runCommand("data.wipe", {
			confirmation = self._wipeInput and self._wipeInput.Text or "",
		})
	end)

	toggle.Activated:Connect(function()
		panel.Visible = not panel.Visible
		if panel.Visible then
			self:_refresh()
		end
	end)
end

function AdminPanelController:_togglePanel()
	if not self._panel then
		return
	end

	self._panel.Visible = not self._panel.Visible
	if self._panel.Visible then
		self:_refresh()
	end
end

function AdminPanelController:OnStart()
	self._remote = getRemote()
	if not self._remote then
		return
	end

	local response = self:_invoke({
		action = "Bootstrap",
	})
	if not response.ok then
		return
	end

	self._authorized = true
	self:_buildPanel()
	self:_applyState(response.data)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == TOGGLE_KEY then
			self:_togglePanel()
		end
	end)
end

return AdminPanelController
