local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local EmoteConfig = require(ReplicatedStorage.Shared.Emotes.EmoteConfig)
local EmoteVFX = require(ReplicatedStorage.Shared.Emotes.EmoteVFX)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ACTION_NAME = "BombBattlesEmoteWheel"
local GUI_NAME = "EmoteWheelRuntime"
local HUD_GUI_NAME = "HUD"
local SIDE_BUTTONS_NAME = "SideButtons"
local EMOTES_BUTTON_NAME = "Emotes"
local WHEEL_RADIUS = 165
local SLOT_SIZE = Vector2.new(138, 54)
local CENTER_SIZE = Vector2.new(128, 46)
local OPEN_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLOSE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FADE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TOGGLE_DEBOUNCE_SECONDS = 0.08
local REMOTE_RETRY_SECONDS = 1

type RenderState = {
	track: AnimationTrack?,
	animation: Animation?,
	vfx: any?,
}

local EmoteController = {}

EmoteController._requestRemote = nil :: RemoteEvent?
EmoteController._stateRemote = nil :: RemoteEvent?
EmoteController._stateConnection = nil :: RBXScriptConnection?
EmoteController._connections = {} :: { RBXScriptConnection }
EmoteController._hudConnections = {} :: { RBXScriptConnection }
EmoteController._renderByPlayer = {} :: { [Player]: RenderState }
EmoteController._page = 1
EmoteController._open = false
EmoteController._screenGui = nil :: ScreenGui?
EmoteController._backdrop = nil :: TextButton?
EmoteController._wheel = nil :: Frame?
EmoteController._slotButtons = {} :: { TextButton }
EmoteController._pageLabel = nil :: TextLabel?
EmoteController._activeLocalEmoteId = ""
EmoteController._lastToggleAt = 0
EmoteController._remoteBindSerial = 0
EmoteController._warnedMissingRequestRemote = false
EmoteController._warnedMissingStateRemote = false

local function getRemote(name: string): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild(EmoteConfig.RemotesFolderName)
	if not remotes then
		return nil
	end

	local remote = remotes:FindFirstChild(name)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getAnimationId(animation: Animation?): string
	return if animation and typeof(animation.AnimationId) == "string" then animation.AnimationId else ""
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function makeTextButton(name: string, parent: Instance, size: UDim2, text: string): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
	button.BackgroundTransparency = 0.08
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Font = Enum.Font.GothamBold
	button.Text = text
	button.TextColor3 = Color3.fromRGB(245, 247, 250)
	button.TextScaled = true
	button.TextWrapped = true
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(90, 96, 108)
	stroke.Thickness = 1
	stroke.Transparency = 0.2
	stroke.Parent = button

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.Parent = button

	return button
end

local function findHudEmotesButton(hud: Instance?): ImageButton?
	local sideButtons = hud and hud:FindFirstChild(SIDE_BUTTONS_NAME)
	if not sideButtons then
		return nil
	end

	local button = sideButtons:FindFirstChild(EMOTES_BUTTON_NAME)
	return if button and button:IsA("ImageButton") then button else nil
end

local function findAnimator(character: Model): Animator?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

local function stopRenderState(state: RenderState?)
	if not state then
		return
	end
	if state.track then
		state.track:Stop(0.15)
		state.track:Destroy()
	end
	if state.animation then
		state.animation:Destroy()
	end
	if state.vfx and type(state.vfx.Destroy) == "function" then
		state.vfx.Destroy()
	end
end

function EmoteController:_ensureGui()
	if self._screenGui and self._screenGui.Parent then
		return
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = GUI_NAME
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 50
	screenGui.Enabled = false
	screenGui.Parent = PlayerGui
	self._screenGui = screenGui

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 1
	backdrop.BorderSizePixel = 0
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Parent = screenGui
	self._backdrop = backdrop

	local wheel = Instance.new("Frame")
	wheel.Name = "Wheel"
	wheel.AnchorPoint = Vector2.new(0.5, 0.5)
	wheel.Position = UDim2.fromScale(0.5, 0.52)
	wheel.Size = UDim2.fromOffset(430, 430)
	wheel.BackgroundTransparency = 1
	wheel.Parent = screenGui
	self._wheel = wheel

	local center = makeTextButton("Stop", wheel, UDim2.fromOffset(CENTER_SIZE.X, CENTER_SIZE.Y), "STOP")
	center.AnchorPoint = Vector2.new(0.5, 0.5)
	center.Position = UDim2.fromScale(0.5, 0.5)
	center.Activated:Connect(function()
		self:StopLocalEmote()
		self:CloseWheel()
	end)

	for index = 1, EmoteConfig.PageSize do
		local angle = ((index - 1) / EmoteConfig.PageSize) * math.pi * 2 - math.pi / 2
		local x = math.cos(angle) * WHEEL_RADIUS
		local y = math.sin(angle) * WHEEL_RADIUS
		local button = makeTextButton("Slot" .. index, wheel, UDim2.fromOffset(SLOT_SIZE.X, SLOT_SIZE.Y), "")
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Position = UDim2.new(0.5, x, 0.5, y)
		self._slotButtons[index] = button
		button.Activated:Connect(function()
			local emoteId = button:GetAttribute("EmoteId")
			if typeof(emoteId) == "string" and emoteId ~= "" then
				self:StartEmote(emoteId)
				self:CloseWheel()
			end
		end)
	end

	local previousButton = makeTextButton("PreviousPage", wheel, UDim2.fromOffset(46, 38), "<")
	previousButton.AnchorPoint = Vector2.new(0.5, 0.5)
	previousButton.Position = UDim2.new(0.5, -72, 0.5, 74)
	previousButton.Activated:Connect(function()
		self:SetPage(self._page - 1)
	end)

	local nextButton = makeTextButton("NextPage", wheel, UDim2.fromOffset(46, 38), ">")
	nextButton.AnchorPoint = Vector2.new(0.5, 0.5)
	nextButton.Position = UDim2.new(0.5, 72, 0.5, 74)
	nextButton.Activated:Connect(function()
		self:SetPage(self._page + 1)
	end)

	local pageLabel = Instance.new("TextLabel")
	pageLabel.Name = "PageLabel"
	pageLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	pageLabel.Position = UDim2.new(0.5, 0, 0.5, 74)
	pageLabel.Size = UDim2.fromOffset(82, 30)
	pageLabel.BackgroundTransparency = 1
	pageLabel.Font = Enum.Font.GothamMedium
	pageLabel.TextColor3 = Color3.fromRGB(230, 234, 240)
	pageLabel.TextScaled = true
	pageLabel.Parent = wheel
	self._pageLabel = pageLabel

	backdrop.Activated:Connect(function()
		self:CloseWheel()
	end)
	self:SetPage(1)
end

function EmoteController:SetPage(page: number)
	self._page = math.max(math.floor(page), 1)
	local pageDefinitions, pageCount = EmoteConfig.GetPage(self._page)
	self._page = math.clamp(self._page, 1, pageCount)
	pageDefinitions, pageCount = EmoteConfig.GetPage(self._page)

	for index, button in ipairs(self._slotButtons) do
		local definition = pageDefinitions[index]
		if definition then
			button.Text = string.upper(definition.displayName or definition.id)
			button:SetAttribute("EmoteId", definition.id)
			button.Visible = true
			button.Active = true
		else
			button.Text = ""
			button:SetAttribute("EmoteId", "")
			button.Visible = false
			button.Active = false
		end
	end

	if self._pageLabel then
		self._pageLabel.Text = string.format("%d/%d", self._page, pageCount)
	end
end

function EmoteController:OpenWheel()
	self:_ensureGui()
	if self._open then
		return
	end

	self._open = true
	local screenGui = self._screenGui
	local backdrop = self._backdrop
	local wheel = self._wheel
	if not (screenGui and backdrop and wheel) then
		return
	end

	screenGui.Enabled = true
	wheel.Size = UDim2.fromOffset(390, 390)
	TweenService:Create(backdrop, FADE_TWEEN, { BackgroundTransparency = 0.42 }):Play()
	TweenService:Create(wheel, OPEN_TWEEN, { Size = UDim2.fromOffset(430, 430) }):Play()
end

function EmoteController:CloseWheel()
	if not self._open then
		return
	end

	self._open = false
	local screenGui = self._screenGui
	local backdrop = self._backdrop
	local wheel = self._wheel
	if not (screenGui and backdrop and wheel) then
		return
	end

	TweenService:Create(backdrop, FADE_TWEEN, { BackgroundTransparency = 1 }):Play()
	local tween = TweenService:Create(wheel, CLOSE_TWEEN, { Size = UDim2.fromOffset(390, 390) })
	tween.Completed:Once(function()
		if not self._open and screenGui.Parent then
			screenGui.Enabled = false
		end
	end)
	tween:Play()
end

function EmoteController:ToggleWheel()
	if self._open then
		self:CloseWheel()
	else
		self:OpenWheel()
	end
end

function EmoteController:ToggleWheelDebounced()
	local currentTime = os.clock()
	if currentTime - self._lastToggleAt < TOGGLE_DEBOUNCE_SECONDS then
		return
	end

	self._lastToggleAt = currentTime
	self:ToggleWheel()
end

function EmoteController:StartEmote(emoteId: string)
	local remote = self._requestRemote
	if not remote then
		if not self._warnedMissingRequestRemote then
			warn("[EmoteController] EmoteRequest remote is unavailable; emote start was not sent.")
			self._warnedMissingRequestRemote = true
		end
		return
	end

	remote:FireServer({
		action = EmoteConfig.Actions.Start,
		emoteId = emoteId,
	})
end

function EmoteController:StopLocalEmote()
	local remote = self._requestRemote
	if remote then
		remote:FireServer({
			action = EmoteConfig.Actions.Stop,
		})
	end
end

function EmoteController:_startRender(player: Player, emoteId: string)
	self:_stopRender(player)

	local character = player.Character
	if not character then
		return
	end

	local sourceAnimation = EmoteConfig.GetAnimation(emoteId)
	local animator = findAnimator(character)
	if not sourceAnimation then
		warn("[EmoteController] Missing animation for emote " .. emoteId)
	end
	if not animator then
		warn("[EmoteController] Missing animator for emote " .. emoteId)
	end

	local animation = nil :: Animation?
	local track = nil :: AnimationTrack?
	if sourceAnimation and animator then
		animation = sourceAnimation:Clone()
		animation.Name = "Emote_" .. emoteId
		animation.Parent = script

		local ok, result = pcall(function()
			return animator:LoadAnimation(animation :: Animation)
		end)
		if ok and result then
			track = result
			track.Priority = Enum.AnimationPriority.Action
			track.Looped = true

			local playOk, playErr = pcall(function()
				(track :: AnimationTrack):Play(0.15, 1, 1)
			end)
			if not playOk then
				warn(
					("[EmoteController] Failed to play emote %s animation %s: %s"):format(
						emoteId,
						getAnimationId(animation),
						tostring(playErr)
					)
				)
				track:Destroy()
				track = nil
			end
		else
			warn(
				("[EmoteController] Failed to load emote %s animation %s: %s"):format(
					emoteId,
					getAnimationId(animation),
					tostring(result)
				)
			)
			animation:Destroy()
			animation = nil
		end
	end

	local vfx = EmoteVFX.Start(character, emoteId)
	if not (track or vfx) then
		return
	end

	self._renderByPlayer[player] = {
		track = track,
		animation = animation,
		vfx = vfx,
	}

	if player == LocalPlayer then
		self._activeLocalEmoteId = emoteId
	end
end

function EmoteController:_stopRender(player: Player)
	local state = self._renderByPlayer[player]
	if not state then
		return
	end

	stopRenderState(state)
	self._renderByPlayer[player] = nil
	if player == LocalPlayer then
		self._activeLocalEmoteId = ""
	end
end

function EmoteController:_bindStateRemote()
	if self._stateConnection then
		self._stateConnection:Disconnect()
		self._stateConnection = nil
	end
	if not self._stateRemote then
		return
	end

	self._stateConnection = self._stateRemote.OnClientEvent:Connect(function(eventName: string, payload: any)
		if typeof(payload) ~= "table" then
			return
		end

		local player = payload.player
		if not (typeof(player) == "Instance" and player:IsA("Player")) then
			return
		end

		if eventName == "Start" and typeof(payload.emoteId) == "string" then
			self:_startRender(player, payload.emoteId)
		elseif eventName == "Stop" then
			self:_stopRender(player)
		elseif eventName == "Rejected" then
			warn(
				("[EmoteController] Server rejected emote %s: %s"):format(
					tostring(payload.emoteId),
					tostring(payload.reason)
				)
			)
		end
	end)
end

function EmoteController:_bindHud(hud: Instance?)
	disconnectAll(self._hudConnections)
	if not hud then
		return
	end

	local button = findHudEmotesButton(hud)
	if not button then
		table.insert(self._hudConnections, hud.DescendantAdded:Connect(function(descendant)
			if descendant.Name == EMOTES_BUTTON_NAME then
				task.defer(function()
					if hud.Parent then
						self:_bindHud(hud)
					end
				end)
			end
		end))
		return
	end

	button.Active = true
	button.Selectable = true
	table.insert(self._hudConnections, button.Activated:Connect(function()
		self:ToggleWheelDebounced()
	end))
	table.insert(self._hudConnections, button.MouseButton1Click:Connect(function()
		self:ToggleWheelDebounced()
	end))
end

function EmoteController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild(HUD_GUI_NAME))
end

function EmoteController:_bindRemotes(): boolean
	self._requestRemote = getRemote(EmoteConfig.RequestRemoteName)
	self._stateRemote = getRemote(EmoteConfig.StateRemoteName)
	self:_bindStateRemote()

	if not self._requestRemote and not self._warnedMissingRequestRemote then
		warn("[EmoteController] Waiting for ReplicatedStorage.Remotes.EmoteRequest")
		self._warnedMissingRequestRemote = true
	end
	if not self._stateRemote and not self._warnedMissingStateRemote then
		warn("[EmoteController] Waiting for ReplicatedStorage.Remotes.EmoteState")
		self._warnedMissingStateRemote = true
	end

	return self._requestRemote ~= nil and self._stateRemote ~= nil
end

function EmoteController:_startRemoteBindingLoop()
	self._remoteBindSerial += 1
	local serial = self._remoteBindSerial

	task.spawn(function()
		while serial == self._remoteBindSerial do
			if self:_bindRemotes() then
				self._requestRemote:FireServer({
					action = EmoteConfig.Actions.Snapshot,
				})
				return
			end

			task.wait(REMOTE_RETRY_SECONDS)
		end
	end)
end

function EmoteController:_bindInputs()
	ContextActionService:UnbindAction(ACTION_NAME)
	ContextActionService:BindAction(ACTION_NAME, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self:ToggleWheelDebounced()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Sink
	end, false, EmoteConfig.OpenKeyCode)

	table.insert(self._connections, UserInputService.InputBegan:Connect(function(inputObject: InputObject, gameProcessed: boolean)
		if gameProcessed or self._activeLocalEmoteId == "" or self._open then
			return
		end
		if
			inputObject.KeyCode == Enum.KeyCode.W
			or inputObject.KeyCode == Enum.KeyCode.A
			or inputObject.KeyCode == Enum.KeyCode.S
			or inputObject.KeyCode == Enum.KeyCode.D
			or inputObject.KeyCode == Enum.KeyCode.Space
		then
			self:StopLocalEmote()
		end
	end))
end

function EmoteController:OnStart()
	disconnectAll(self._connections)
	disconnectAll(self._hudConnections)
	self:_startRemoteBindingLoop()
	self:_bindInputs()
	self:_bindCurrentHud()
	self:_ensureGui()

	table.insert(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == HUD_GUI_NAME then
			task.defer(function()
				self:_bindHud(child)
			end)
		end
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self:_stopRender(player)
	end))

end

return EmoteController
