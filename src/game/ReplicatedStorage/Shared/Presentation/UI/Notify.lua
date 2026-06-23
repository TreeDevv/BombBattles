local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local REMOTES_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "Notify"
local PLAYER_GUI_WAIT_SECONDS = 15
local GUI_NAME = "ToastNotifications"
local CONTAINER_NAME = "ToastContainer"
local TOAST_HEIGHT = 34
local TOAST_GAP = 4
local FALLBACK_TOP_PADDING = 96
local TOP_HUD_MARGIN = 10
local SIDE_PADDING = 32
local MAX_CONTAINER_WIDTH = 620
local ENTRY_OFFSET = 12
local EXIT_OFFSET = 16
local SHAKE_OFFSET = 5
local EXIT_FALLBACK_PADDING = 0.08
local DEFAULT_DURATION = 2.25
local DEFAULT_MAX_VISIBLE = 3
local MIN_DURATION = 0.75
local MAX_DURATION = 8

local DEFAULT_COLORS = {
	Info = Color3.fromRGB(255, 255, 255),
	Success = Color3.fromRGB(85, 255, 110),
	Reward = Color3.fromRGB(255, 226, 64),
	Warning = Color3.fromRGB(255, 184, 46),
	Error = Color3.fromRGB(255, 76, 76),
}

local COLOR_ALIASES = {
	Blue = Color3.fromRGB(125, 196, 255),
	Gold = DEFAULT_COLORS.Reward,
	Gray = Color3.fromRGB(170, 180, 190),
	Green = DEFAULT_COLORS.Success,
	Neutral = Color3.fromRGB(235, 240, 245),
	Orange = DEFAULT_COLORS.Warning,
	Purple = Color3.fromRGB(204, 150, 255),
	Red = DEFAULT_COLORS.Error,
	White = DEFAULT_COLORS.Info,
	Yellow = DEFAULT_COLORS.Reward,
}

local ANIMATION = {
	Enter = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Settle = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Layout = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Exit = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
	Shake = TweenInfo.new(0.04, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
}

type NotifyPayload = {
	Type: string,
	Title: string,
	Body: string,
	Duration: number,
	TextColor: Color3,
	MergeKey: string,
}

type ToastRecord = {
	id: number,
	key: string,
	payload: NotifyPayload,
	count: number,
	state: string,
	timerToken: number,
	expiresAt: number,
	slotY: number?,
	toast: Frame?,
	background: Frame?,
	scale: UIScale?,
	textLabel: TextLabel?,
	shadowLabel: TextLabel?,
	layoutTween: Tween?,
	finalized: boolean?,
}

local Notify = {}

Notify.Defaults = {
	title = "Notice",
	duration = DEFAULT_DURATION,
	maxVisible = DEFAULT_MAX_VISIBLE,
}

local screenGui: ScreenGui? = nil
local container: Frame? = nil
local containerUpdateConnections = {} :: { RBXScriptConnection }
local expiryConnection: RBXScriptConnection? = nil
local visibleToasts = {} :: { ToastRecord }
local queuedToasts = {} :: { ToastRecord }
local visibleByKey = {} :: { [string]: ToastRecord }
local queuedByKey = {} :: { [string]: ToastRecord }
local nextToastId = 0

local function ensureRemote(): RemoteEvent
	local remotesFolder = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if RunService:IsServer() then
		if remotesFolder and not remotesFolder:IsA("Folder") then
			remotesFolder:Destroy()
			remotesFolder = nil
		end
		if not remotesFolder then
			remotesFolder = Instance.new("Folder")
			remotesFolder.Name = REMOTES_FOLDER_NAME
			remotesFolder.Parent = ReplicatedStorage
		end

		local remote = remotesFolder:FindFirstChild(REMOTE_NAME)
		if remote and remote:IsA("RemoteEvent") then
			return remote
		end
		if remote then
			remote:Destroy()
		end

		remote = Instance.new("RemoteEvent")
		remote.Name = REMOTE_NAME
		remote.Parent = remotesFolder
		return remote
	end

	while true do
		local safeRemotes = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
		if safeRemotes and safeRemotes:IsA("Folder") then
			local remote = safeRemotes:FindFirstChild(REMOTE_NAME)
			if remote and remote:IsA("RemoteEvent") then
				return remote
			end
		end

		task.wait(0.25)
	end
end

local function readOption(payload: any, opts: any, pascalName: string, camelName: string, legacyName: string?)
	if typeof(payload) == "table" then
		local value = payload[pascalName]
		if value ~= nil then
			return value
		end

		value = payload[camelName]
		if value ~= nil then
			return value
		end

		if legacyName then
			value = payload[legacyName]
			if value ~= nil then
				return value
			end
		end
	end

	if typeof(opts) == "table" then
		local value = opts[pascalName]
		if value ~= nil then
			return value
		end

		value = opts[camelName]
		if value ~= nil then
			return value
		end

		if legacyName then
			value = opts[legacyName]
			if value ~= nil then
				return value
			end
		end
	end

	return nil
end

local function parseHexColor(value: string): Color3?
	local hex = value:gsub("#", "")
	if #hex ~= 6 or not hex:match("^[%da-fA-F]+$") then
		return nil
	end

	return Color3.fromRGB(
		tonumber(hex:sub(1, 2), 16) or 255,
		tonumber(hex:sub(3, 4), 16) or 255,
		tonumber(hex:sub(5, 6), 16) or 255
	)
end

local function resolveTextColor(notificationType: string, colorOption: any): Color3
	if typeof(colorOption) == "Color3" then
		return colorOption
	end

	if typeof(colorOption) == "string" then
		local alias = COLOR_ALIASES[colorOption]
		if alias then
			return alias
		end

		local hex = parseHexColor(colorOption)
		if hex then
			return hex
		end
	end

	return DEFAULT_COLORS[notificationType] or DEFAULT_COLORS.Info
end

local function normalizePayload(text: any, opts: any): NotifyPayload
	opts = opts or {}
	local source = if typeof(text) == "table" then text else nil
	local notificationType = tostring(readOption(source, opts, "Type", "type") or "Info")
	local title = readOption(source, opts, "Title", "title")
	local body = readOption(source, opts, "Body", "body", "text")
	local duration = tonumber(readOption(source, opts, "Duration", "duration"))
	local color = readOption(source, opts, "TextColor", "textColor", "color")
	local mergeKey = readOption(source, opts, "MergeKey", "mergeKey")

	if body == nil and source then
		body = source.Text or source.text
	end
	if body == nil then
		body = text
	end

	title = tostring(title or Notify.Defaults.title)
	body = tostring(body or "")
	duration = math.clamp(duration or Notify.Defaults.duration or DEFAULT_DURATION, MIN_DURATION, MAX_DURATION)

	return {
		Type = notificationType,
		Title = title,
		Body = body,
		Duration = duration,
		TextColor = resolveTextColor(notificationType, color),
		MergeKey = tostring(mergeKey or string.format("%s|%s|%s", notificationType, title, body)),
	}
end

local function findTopHud(playerGui: PlayerGui): GuiObject?
	local hud = playerGui:FindFirstChild("HUD")
	if not hud then
		return nil
	end

	if hud:IsA("LayerCollector") and not hud.Enabled then
		return nil
	end

	local top = hud:FindFirstChild("Top")
	return if top and top:IsA("GuiObject") then top else nil
end

local function getTopHudBottom(playerGui: PlayerGui): number?
	local top = findTopHud(playerGui)
	if not (top and top.Visible) then
		return nil
	end

	local size = top.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return nil
	end

	return top.AbsolutePosition.Y + size.Y
end

local function updateContainerPosition(playerGui: PlayerGui)
	if not container then
		return
	end

	local topPadding = (getTopHudBottom(playerGui) or FALLBACK_TOP_PADDING) + TOP_HUD_MARGIN
	container.Position = UDim2.new(0.5, 0, 0, topPadding)
end

local function disconnectContainerPositionUpdates()
	for _, connection in ipairs(containerUpdateConnections) do
		connection:Disconnect()
	end
	table.clear(containerUpdateConnections)
end

local function trackContainerPositionConnection(connection: RBXScriptConnection)
	table.insert(containerUpdateConnections, connection)
end

local function bindContainerPositionUpdates(playerGui: PlayerGui)
	disconnectContainerPositionUpdates()
	updateContainerPosition(playerGui)

	local function updateOrDisconnect()
		if not (container and container.Parent) then
			disconnectContainerPositionUpdates()
			return
		end

		updateContainerPosition(playerGui)
	end

	local function rebind()
		if not (container and container.Parent) then
			disconnectContainerPositionUpdates()
			return
		end

		bindContainerPositionUpdates(playerGui)
	end

	trackContainerPositionConnection(playerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" then
			task.defer(rebind)
		end
	end))

	trackContainerPositionConnection(playerGui.ChildRemoved:Connect(function(child)
		if child.Name == "HUD" then
			task.defer(rebind)
		end
	end))

	local hud = playerGui:FindFirstChild("HUD")
	if hud then
		trackContainerPositionConnection(hud.ChildAdded:Connect(function(child)
			if child.Name == "Top" then
				task.defer(rebind)
			end
		end))

		trackContainerPositionConnection(hud.ChildRemoved:Connect(function(child)
			if child.Name == "Top" then
				task.defer(rebind)
			end
		end))
	end

	local top = findTopHud(playerGui)
	if top then
		trackContainerPositionConnection(top:GetPropertyChangedSignal("Visible"):Connect(updateOrDisconnect))
		trackContainerPositionConnection(top:GetPropertyChangedSignal("Position"):Connect(updateOrDisconnect))
		trackContainerPositionConnection(top:GetPropertyChangedSignal("AbsolutePosition"):Connect(updateOrDisconnect))
		trackContainerPositionConnection(top:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateOrDisconnect))
		trackContainerPositionConnection(top.AncestryChanged:Connect(function()
			task.defer(rebind)
		end))
	end
end

local function ensureGui(): Frame?
	if not RunService:IsClient() then
		return nil
	end

	if container and container.Parent then
		return container
	end

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return nil
	end

	local playerGui = localPlayer:WaitForChild("PlayerGui", PLAYER_GUI_WAIT_SECONDS)
	if not playerGui then
		warn("[Notify] PlayerGui was not ready; notification was skipped.")
		return nil
	end

	local existingGui = playerGui:FindFirstChild(GUI_NAME)
	if existingGui and existingGui:IsA("ScreenGui") then
		screenGui = existingGui
	else
		if existingGui then
			existingGui:Destroy()
		end

		screenGui = Instance.new("ScreenGui")
		screenGui.Name = GUI_NAME
		screenGui.ResetOnSpawn = false
		screenGui.IgnoreGuiInset = false
		screenGui.DisplayOrder = 10000
		screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		screenGui.Parent = playerGui
	end

	local existingContainer = screenGui:FindFirstChild(CONTAINER_NAME)
	if existingContainer and existingContainer:IsA("Frame") then
		container = existingContainer
		bindContainerPositionUpdates(playerGui)
		return container
	end

	if existingContainer then
		existingContainer:Destroy()
	end

	container = Instance.new("Frame")
	container.Name = CONTAINER_NAME
	container.AnchorPoint = Vector2.new(0.5, 0)
	container.BackgroundTransparency = 1
	container.Position = UDim2.new(0.5, 0, 0, FALLBACK_TOP_PADDING)
	container.Size = UDim2.new(1, -SIDE_PADDING, 0, 160)
	container.Parent = screenGui

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MaxSize = Vector2.new(MAX_CONTAINER_WIDTH, 10000)
	sizeConstraint.MinSize = Vector2.new(260, 0)
	sizeConstraint.Parent = container

	bindContainerPositionUpdates(playerGui)

	return container
end

local function tween(instance: Instance, tweenInfo: TweenInfo, properties: { [string]: any }): Tween
	local createdTween = TweenService:Create(instance, tweenInfo, properties)
	createdTween:Play()
	return createdTween
end

local function getSlotY(index: number): number
	return (index - 1) * (TOAST_HEIGHT + TOAST_GAP)
end

local function composeToastText(payload: NotifyPayload): string
	local body = tostring(payload.Body or "")
	if body ~= "" then
		return body
	end

	return tostring(payload.Title or "")
end

local function setToastText(record: ToastRecord)
	local text = composeToastText(record.payload)
	if record.count > 1 then
		text = string.format("%s x%d", text, record.count)
	end

	if record.textLabel then
		record.textLabel.Text = text
		record.textLabel.TextColor3 = record.payload.TextColor
	end
	if record.shadowLabel then
		record.shadowLabel.Text = text
	end
end

local function createToast(record: ToastRecord): Frame?
	local parent = ensureGui()
	if not parent then
		return nil
	end

	local toast = Instance.new("Frame")
	toast.Name = "GameplayNotification"
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.BackgroundTransparency = 1
	toast.BorderSizePixel = 0
	toast.Position = UDim2.new(0.5, 0, 0, -ENTRY_OFFSET)
	toast.Size = UDim2.new(1, 0, 0, TOAST_HEIGHT)
	toast.ZIndex = 100
	toast.Parent = parent

	local background = Instance.new("Frame")
	background.Name = "GradientBackground"
	background.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	background.BackgroundTransparency = 1
	background.BorderSizePixel = 0
	background.Size = UDim2.fromScale(1, 1)
	background.ZIndex = 100
	background.Parent = toast

	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 0
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.16, 0.84),
		NumberSequenceKeypoint.new(0.5, 0.52),
		NumberSequenceKeypoint.new(0.84, 0.84),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = background

	local scale = Instance.new("UIScale")
	scale.Scale = 0.9
	scale.Parent = toast

	local shadow = Instance.new("TextLabel")
	shadow.Name = "Shadow"
	shadow.BackgroundTransparency = 1
	shadow.Font = Enum.Font.FredokaOne
	shadow.Position = UDim2.fromOffset(2, 3)
	shadow.Size = UDim2.new(1, -4, 1, 0)
	shadow.TextColor3 = Color3.fromRGB(0, 0, 0)
	shadow.TextSize = 22
	shadow.TextTransparency = 1
	shadow.TextTruncate = Enum.TextTruncate.AtEnd
	shadow.TextWrapped = false
	shadow.TextXAlignment = Enum.TextXAlignment.Center
	shadow.TextYAlignment = Enum.TextYAlignment.Center
	shadow.ZIndex = 101
	shadow.Parent = toast

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Position = UDim2.fromOffset(0, 0)
	label.Size = UDim2.fromScale(1, 1)
	label.TextColor3 = record.payload.TextColor
	label.TextSize = 22
	label.TextTransparency = 1
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 1
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.TextWrapped = false
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = 102
	label.Parent = toast

	record.toast = toast
	record.background = background
	record.scale = scale
	record.textLabel = label
	record.shadowLabel = shadow
	setToastText(record)

	return toast
end

local function layoutVisible(skipRecord: ToastRecord?)
	for index, record in ipairs(visibleToasts) do
		record.slotY = getSlotY(index)
		if record ~= skipRecord and record.toast and record.toast.Parent and record.state ~= "exiting" then
			if record.layoutTween then
				record.layoutTween:Cancel()
			end

			record.layoutTween = tween(record.toast, ANIMATION.Layout, {
				Position = UDim2.new(0.5, 0, 0, record.slotY),
			})
		end
	end
end

local function playShake(record: ToastRecord)
	if record.finalized or not (record.toast and record.toast.Parent) then
		return
	end

	local y = record.slotY or 0
	local basePosition = UDim2.new(0.5, 0, 0, y)
	tween(record.toast, ANIMATION.Shake, { Position = UDim2.new(0.5, -SHAKE_OFFSET, 0, y) }).Completed:Connect(function()
		if record.finalized or record.state == "exiting" or not (record.toast and record.toast.Parent) then
			return
		end

		tween(record.toast, ANIMATION.Shake, { Position = UDim2.new(0.5, SHAKE_OFFSET, 0, y) }).Completed:Connect(function()
			if not record.finalized and record.state ~= "exiting" and record.toast and record.toast.Parent then
				tween(record.toast, ANIMATION.Shake, { Position = basePosition })
			end
		end)
	end)
end

local showQueuedIfPossible: () -> ()
local beginExit: (ToastRecord) -> ()

local function getNow(): number
	return os.clock()
end

local function ensureExpiryWatcher()
	if expiryConnection then
		return
	end

	expiryConnection = RunService.RenderStepped:Connect(function()
		local now = getNow()
		for _, record in ipairs(table.clone(visibleToasts)) do
			if not record.finalized and record.state == "visible" and record.expiresAt > 0 and now >= record.expiresAt then
				beginExit(record)
			end
		end

		local parent = container
		if not (parent and parent.Parent) then
			return
		end

		for _, child in ipairs(parent:GetChildren()) do
			if child.Name == "GameplayNotification" then
				local owned = false
				for _, record in ipairs(visibleToasts) do
					if record.toast == child then
						owned = true
						break
					end
				end
				if not owned then
					child:Destroy()
				end
			end
		end
	end)
end

local function startTimer(record: ToastRecord)
	record.timerToken = (record.timerToken or 0) + 1
	local token = record.timerToken
	record.expiresAt = getNow() + record.payload.Duration
	ensureExpiryWatcher()

	task.delay(record.payload.Duration, function()
		if record.timerToken ~= token or record.state == "exiting" or record.finalized then
			return
		end

		beginExit(record)
	end)
end

local function refreshRecord(record: ToastRecord, payload: NotifyPayload)
	record.count += 1
	record.payload = payload
	setToastText(record)

	if record.state ~= "queued" then
		startTimer(record)
		if record.scale then
			tween(record.scale, ANIMATION.Enter, { Scale = 1.05 }).Completed:Connect(function()
				if record.state ~= "exiting" and record.scale then
					tween(record.scale, ANIMATION.Settle, { Scale = 1 })
				end
			end)
		end
	end
end

local function findRecordIndex(list: { ToastRecord }, record: ToastRecord): number?
	for index, item in ipairs(list) do
		if item == record then
			return index
		end
	end

	return nil
end

local function removeRecordReferences(record: ToastRecord)
	if visibleByKey[record.key] == record then
		visibleByKey[record.key] = nil
	end
	if queuedByKey[record.key] == record then
		queuedByKey[record.key] = nil
	end

	local visibleIndex = findRecordIndex(visibleToasts, record)
	if visibleIndex then
		table.remove(visibleToasts, visibleIndex)
	end

	local queuedIndex = findRecordIndex(queuedToasts, record)
	if queuedIndex then
		table.remove(queuedToasts, queuedIndex)
	end

	if record.layoutTween then
		record.layoutTween:Cancel()
		record.layoutTween = nil
	end
end

local function finalizeRecord(record: ToastRecord, advanceQueue: boolean)
	if record.finalized then
		return
	end

	record.finalized = true
	removeRecordReferences(record)

	if record.toast then
		record.toast:Destroy()
		record.toast = nil
	end

	if advanceQueue then
		showQueuedIfPossible()
	end
end

showQueuedIfPossible = function()
	local maxVisible = math.max(1, tonumber(Notify.Defaults.maxVisible) or DEFAULT_MAX_VISIBLE)
	if #visibleToasts >= maxVisible or #queuedToasts == 0 then
		return
	end

	local record = table.remove(queuedToasts, 1)
	queuedByKey[record.key] = nil
	record.state = "visible"
	visibleByKey[record.key] = record
	table.insert(visibleToasts, record)

	if not createToast(record) then
		finalizeRecord(record, true)
		return
	end

	if not record.toast then
		return
	end

	record.slotY = getSlotY(#visibleToasts)
	record.toast.Position = UDim2.new(0.5, 0, 0, record.slotY - ENTRY_OFFSET)
	layoutVisible(record)

	local enterTween = tween(record.toast, ANIMATION.Enter, {
		Position = UDim2.new(0.5, 0, 0, record.slotY),
	})
	if record.background then
		tween(record.background, ANIMATION.Enter, { BackgroundTransparency = 0 })
	end
	if record.textLabel then
		tween(record.textLabel, ANIMATION.Enter, {
			TextTransparency = 0,
			TextStrokeTransparency = 0,
		})
	end
	if record.shadowLabel then
		tween(record.shadowLabel, ANIMATION.Enter, { TextTransparency = 0.32 })
	end
	if record.scale then
		tween(record.scale, ANIMATION.Enter, { Scale = 1.05 })
	end

	startTimer(record)

	enterTween.Completed:Connect(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed or record.state == "exiting" or record.finalized then
			return
		end

		if record.scale then
			tween(record.scale, ANIMATION.Settle, { Scale = 1 })
		end
		if record.payload.Type == "Error" then
			task.delay(0.04, function()
				playShake(record)
			end)
		end
	end)
end

beginExit = function(record: ToastRecord)
	if record.state == "exiting" or record.finalized then
		return
	end

	record.state = "exiting"
	record.timerToken = (record.timerToken or 0) + 1

	removeRecordReferences(record)
	layoutVisible(nil)

	if not (record.toast and record.toast.Parent) then
		finalizeRecord(record, true)
		return
	end

	local currentY = record.slotY or 0
	local exitTween = tween(record.toast, ANIMATION.Exit, {
		Position = UDim2.new(0.5, 0, 0, currentY - EXIT_OFFSET),
	})
	if record.background then
		tween(record.background, ANIMATION.Exit, { BackgroundTransparency = 1 })
	end
	if record.textLabel then
		tween(record.textLabel, ANIMATION.Exit, {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		})
	end
	if record.shadowLabel then
		tween(record.shadowLabel, ANIMATION.Exit, { TextTransparency = 1 })
	end
	if record.scale then
		tween(record.scale, ANIMATION.Exit, { Scale = 0.96 })
	end

	exitTween.Completed:Connect(function()
		finalizeRecord(record, true)
	end)

	task.delay(ANIMATION.Exit.Time + EXIT_FALLBACK_PADDING, function()
		finalizeRecord(record, true)
	end)
end

local function createRecord(payload: NotifyPayload): ToastRecord
	nextToastId += 1
	return {
		id = nextToastId,
		key = payload.MergeKey,
		payload = payload,
		count = 1,
		state = "queued",
		timerToken = 0,
		expiresAt = 0,
		finalized = false,
	}
end

local function enqueueRecord(record: ToastRecord)
	record.state = "queued"
	queuedByKey[record.key] = record
	table.insert(queuedToasts, record)
end

local function showPayload(payload: NotifyPayload): boolean
	local visibleRecord = visibleByKey[payload.MergeKey]
	if visibleRecord then
		refreshRecord(visibleRecord, payload)
		return true
	end

	local queuedRecord = queuedByKey[payload.MergeKey]
	if queuedRecord then
		refreshRecord(queuedRecord, payload)
		return true
	end

	local record = createRecord(payload)
	local maxVisible = math.max(1, tonumber(Notify.Defaults.maxVisible) or DEFAULT_MAX_VISIBLE)
	if #visibleToasts >= maxVisible then
		enqueueRecord(record)
		return true
	end

	enqueueRecord(record)
	showQueuedIfPossible()
	return true
end

function Notify.ShowCore(payloadOrText: any, opts: any): boolean
	return Notify.Show(payloadOrText, opts)
end

function Notify.Show(text: any, opts: any): boolean
	local payload = normalizePayload(text, opts)
	if RunService:IsServer() then
		return false
	end

	return showPayload(payload)
end

function Notify.Send(target: any, text: any, opts: any)
	if RunService:IsServer() then
		local payload = normalizePayload(text, opts)
		local remote = ensureRemote()

		if target == nil or target == "all" then
			remote:FireAllClients(payload)
		elseif typeof(target) == "Instance" and target:IsA("Player") then
			remote:FireClient(target, payload)
		elseif typeof(target) == "table" then
			for _, player in ipairs(target) do
				if typeof(player) == "Instance" and player:IsA("Player") then
					remote:FireClient(player, payload)
				end
			end
		end
	else
		return Notify.Show(text, opts)
	end
end

if RunService:IsServer() then
	ensureRemote()
end

return setmetatable(Notify, {
	__call = function(_, payload)
		return Notify.Show(payload)
	end,
})
