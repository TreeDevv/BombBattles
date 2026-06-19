local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local EmoteConfig = require(ReplicatedStorage.Shared.Emotes.EmoteConfig)
local NumberFormatter = require(ReplicatedStorage.Shared.Formatting.NumberFormatter)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local REMOTES_FOLDER_NAME = "Remotes"
local GET_LEADERBOARD_REMOTE_NAME = "GetGlobalLeaderboard"
local LEADERBOARD_UPDATED_REMOTE_NAME = "GlobalLeaderboardUpdated"
local ENTRY_NAME_PREFIX = "Entry_"
local SURFACE_GUI_CLONE_PREFIX = "GlobalLeaderboardSurfaceGui_"
local FETCH_RETRY_SECONDS = 2

local BOARD_CONFIGS = {
	{
		id = "kills",
		modelName = "KillsLeaderboard",
		displayModelName = "KillsPlayerDisplay",
		fallbackDisplayModelName = "PlayerDisplay",
		metricLabel = "Kills",
		rankText = "#1 MOST KILLS",
	},
	{
		id = "wins",
		modelName = "WinsLeaderboard",
		displayModelName = "WinsPlayerDisplay",
		fallbackDisplayModelName = "PlayerDisplay",
		metricLabel = "Wins",
		rankText = "#1 MOST WINS",
	},
	{
		id = "destruction",
		modelName = "DestructionLeaderboard",
		displayModelName = "DestructionPlayerDisplay",
		fallbackDisplayModelName = "PlayerDisplay",
		metricLabel = "Destruction",
		rankText = "#1 MOST DESTRUCTION",
	},
}

local PERIOD_BUTTONS = {
	allTime = "AllTimeButton",
	monthly = "MonthlyButton",
	daily = "DailyButton",
}

local BUTTON_PERIODS = {
	AllTimeButton = "allTime",
	MonthlyButton = "monthly",
	DailyButton = "daily",
}

type BoardRecord = {
	id: string,
	modelName: string,
	metricLabel: string,
	rankText: string,
	uiPart: BasePart,
	surfaceGui: SurfaceGui,
	leaderboard: Frame,
	scrollingFrame: ScrollingFrame,
	topbar: Frame,
	timer: TextLabel?,
	templates: { [string]: Frame },
	displayModel: Model?,
	displayRootCFrame: CFrame?,
	displayUsernameLabel: TextLabel?,
	displayCountLabel: TextLabel?,
	displayRankLabel: TextLabel?,
	displayedUserId: number?,
	displayedPeriod: string?,
	displaySerial: number,
	displayTrack: AnimationTrack?,
	displayAnimation: Animation?,
	selectedPeriod: string,
	cache: { [string]: any },
	fetchingPeriods: { [string]: boolean },
	lastFetchStartedAt: { [string]: number },
	connections: { RBXScriptConnection },
	lastInputSelectAt: number,
	lastInputSelectPeriod: string?,
}

local GlobalLeaderboardController = {}

local boardRecords: { BoardRecord } = {}
local getLeaderboardRemote: RemoteFunction? = nil
local leaderboardUpdatedRemote: RemoteEvent? = nil
local rng = Random.new()
local emoteAnimationCache: { Animation }? = nil
local inputBeganPositions: { [InputObject]: Vector2 } = {}

local function cleanupHostedSurfaceGuis()
	for _, child in ipairs(PlayerGui:GetChildren()) do
		if child:IsA("SurfaceGui") and string.sub(child.Name, 1, #SURFACE_GUI_CLONE_PREFIX) == SURFACE_GUI_CLONE_PREFIX then
			child:Destroy()
		end
	end
end

local function getLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function getButton(parent: Instance?, name: string): ImageButton?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("ImageButton") then child else nil
end

local function findDescendantTextLabel(root: Instance?, name: string): TextLabel?
	if not root then
		return nil
	end

	local direct = root:FindFirstChild(name, true)
	return if direct and direct:IsA("TextLabel") then direct else nil
end

local function getChildModel(parent: Instance?, name: string): Model?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("Model") then child else nil
end

local function getModelPosition(model: Model): Vector3
	return model:GetPivot().Position
end

local function formatDuration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local days = math.floor(seconds / 86400)
	local hours = math.floor((seconds % 86400) / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local remainingSeconds = seconds % 60

	if days > 0 then
		return string.format("%dd %02dh", days, hours)
	end
	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	end
	if minutes > 0 then
		return string.format("%dm %02ds", minutes, remainingSeconds)
	end
	return string.format("%ds", remainingSeconds)
end

local function formatMetricValue(value: any, metricLabel: string): string
	return NumberFormatter.Format(tonumber(value) or 0) .. " " .. metricLabel
end

local function getPositiveUserId(value: any): number?
	local userId = tonumber(value)
	if not userId or userId ~= userId or userId <= 0 or math.abs(userId) >= math.huge then
		return nil
	end
	return math.floor(userId)
end

local function getRankTemplate(record: BoardRecord, rank: number): Frame?
	if rank == 1 then
		return record.templates.gold
	end
	if rank == 2 then
		return record.templates.silver
	end
	if rank == 3 then
		return record.templates.bronze
	end
	return record.templates.normal
end

local function clearRows(record: BoardRecord)
	for _, child in ipairs(record.scrollingFrame:GetChildren()) do
		if child:IsA("GuiObject") and string.sub(child.Name, 1, #ENTRY_NAME_PREFIX) == ENTRY_NAME_PREFIX then
			child:Destroy()
		end
	end
end

local function hideTemplates(record: BoardRecord)
	for _, template in pairs(record.templates) do
		template.Visible = false
	end
end

local function setRowLabel(row: Frame, labelName: string, text: string)
	local label = getLabel(row, labelName)
	if label then
		label.Text = text
	end
end

local function renderRows(record: BoardRecord, entries)
	hideTemplates(record)
	clearRows(record)

	for index, entry in ipairs(entries or {}) do
		local rank = tonumber(entry.rank) or index
		local template = getRankTemplate(record, rank)
		if not template then
			continue
		end

		local row = template:Clone()
		row.Name = ENTRY_NAME_PREFIX .. tostring(rank)
		row.LayoutOrder = rank
		row.Visible = true
		row.Parent = record.scrollingFrame

		local username = if typeof(entry.username) == "string" and entry.username ~= "" then entry.username else tostring(entry.userId or "")
		setRowLabel(row, "LeaderboardPlace", tostring(rank))
		setRowLabel(row, "PlayerName", "@" .. username)
		setRowLabel(row, "Stat", NumberFormatter.Format(tonumber(entry.value) or 0))
	end
end

local function stopDisplayAnimation(record: BoardRecord)
	if record.displayTrack then
		pcall(function()
			record.displayTrack:Stop(0)
			record.displayTrack:Destroy()
		end)
		record.displayTrack = nil
	end

	if record.displayAnimation then
		record.displayAnimation:Destroy()
		record.displayAnimation = nil
	end
end

local function getDisplayRig(record: BoardRecord): Model?
	local displayModel = record.displayModel
	if not displayModel then
		return nil
	end

	local rig = displayModel:FindFirstChild("Rig")
	return if rig and rig:IsA("Model") then rig else nil
end

local function getRigRootPart(rig: Model): BasePart?
	local rootPart = rig:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

local function configureDisplayRig(rig: Model)
	for _, descendant in ipairs(rig:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
			descendant.Anchored = descendant.Name == "HumanoidRootPart"
		end
	end

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.PlatformStand = false
		if not humanoid:FindFirstChildOfClass("Animator") then
			local animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
	end
end

local function pivotRigRootToCFrame(rig: Model, targetRootCFrame: CFrame)
	local rootPart = getRigRootPart(rig)
	if not rootPart then
		warn("[GlobalLeaderboardController] Display avatar is missing HumanoidRootPart; using model pivot fallback")
		rig:PivotTo(targetRootCFrame)
		return
	end

	local pivotToRoot = rig:GetPivot():ToObjectSpace(rootPart.CFrame)
	rig:PivotTo(targetRootCFrame * pivotToRoot:Inverse())
end

local function createDisplayAvatar(userId: number): Model?
	local ok, model = pcall(function()
		local description = Players:GetHumanoidDescriptionFromUserIdAsync(userId)
		return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R6)
	end)
	if ok and model and model:IsA("Model") then
		return model
	end

	local fallbackOk, fallbackModel = pcall(function()
		return Players:CreateHumanoidModelFromUserIdAsync(userId)
	end)
	if fallbackOk and fallbackModel and fallbackModel:IsA("Model") then
		return fallbackModel
	end

	warn("[GlobalLeaderboardController] Failed to create display avatar:", if ok then fallbackModel else model)
	return nil
end

local function getAnimator(rig: Model): Animator?
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = humanoid
		end
		return animator
	end

	local animationController = rig:FindFirstChildOfClass("AnimationController")
	if not animationController then
		animationController = Instance.new("AnimationController")
		animationController.Parent = rig
	end
	local animator = animationController:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = animationController
	end
	return animator
end

local function getEmoteAnimations(): { Animation }
	if emoteAnimationCache then
		return emoteAnimationCache
	end

	local animations = {}
	for _, definition in ipairs(EmoteConfig.GetCatalog()) do
		local animation = EmoteConfig.GetAnimation(definition.id)
		if animation then
			table.insert(animations, animation)
		end
	end

	emoteAnimationCache = animations
	return animations
end

local function playRandomDisplayEmote(record: BoardRecord, rig: Model)
	stopDisplayAnimation(record)

	local animations = getEmoteAnimations()
	if #animations <= 0 then
		return
	end

	local sourceAnimation = animations[rng:NextInteger(1, #animations)]
	local animator = getAnimator(rig)
	if not animator then
		return
	end

	local animation = sourceAnimation:Clone()
	animation.Name = "LeaderboardDisplayEmote"
	animation.Parent = rig

	local ok, result = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok or not result then
		warn("[GlobalLeaderboardController] Failed to load display emote:", result)
		animation:Destroy()
		return
	end

	local track = result :: AnimationTrack
	track.Looped = true
	track.Priority = Enum.AnimationPriority.Action

	local playOk, playErr = pcall(function()
		track:Play(0.15, 1, 1)
	end)
	if not playOk then
		warn("[GlobalLeaderboardController] Failed to play display emote:", playErr)
		track:Destroy()
		animation:Destroy()
		return
	end

	record.displayTrack = track
	record.displayAnimation = animation
end

local function clearDisplayRig(record: BoardRecord)
	stopDisplayAnimation(record)

	local rig = getDisplayRig(record)
	if rig then
		if not record.displayRootCFrame then
			local rootPart = getRigRootPart(rig)
			if rootPart then
				record.displayRootCFrame = rootPart.CFrame
			end
		end
		rig:Destroy()
	end
	record.displayedUserId = nil
	record.displayedPeriod = nil
end

local function setDisplayText(record: BoardRecord, entry)
	if record.displayRankLabel then
		record.displayRankLabel.Text = record.rankText
	end

	if entry then
		local username = if typeof(entry.username) == "string" and entry.username ~= "" then entry.username else tostring(entry.userId or "")
		if record.displayUsernameLabel then
			record.displayUsernameLabel.Text = "@" .. username
		end
		if record.displayCountLabel then
			record.displayCountLabel.Text = formatMetricValue(entry.value, record.metricLabel)
		end
	else
		if record.displayUsernameLabel then
			record.displayUsernameLabel.Text = "NO PLAYER"
		end
		if record.displayCountLabel then
			record.displayCountLabel.Text = formatMetricValue(0, record.metricLabel)
		end
	end
end

local function updateDisplayRig(record: BoardRecord, entry)
	local userId = entry and getPositiveUserId(entry.userId) or nil
	if not (record.displayModel and record.displayRootCFrame and userId) then
		clearDisplayRig(record)
		return
	end

	if record.displayedUserId == userId and record.displayedPeriod == record.selectedPeriod then
		return
	end

	record.displaySerial += 1
	local serial = record.displaySerial
	local rootCFrame = record.displayRootCFrame
	local parent = record.displayModel
	clearDisplayRig(record)

	task.spawn(function()
		local rig = createDisplayAvatar(userId)
		if serial ~= record.displaySerial then
			if rig then
				rig:Destroy()
			end
			return
		end
		if not rig then
			return
		end

		rig.Name = "Rig"
		rig.Parent = parent
		pivotRigRootToCFrame(rig, rootCFrame)
		configureDisplayRig(rig)
		playRandomDisplayEmote(record, rig)

		record.displayedUserId = userId
		record.displayedPeriod = record.selectedPeriod
	end)
end

local function updateFeaturedDisplay(record: BoardRecord, entries)
	local entry = if typeof(entries) == "table" then entries[1] else nil
	setDisplayText(record, entry)
	updateDisplayRig(record, entry)
end

local function updateButtonState(record: BoardRecord)
	for periodId, buttonName in pairs(PERIOD_BUTTONS) do
		local button = getButton(record.topbar, buttonName)
		local selected = periodId == record.selectedPeriod
		if button then
			button:SetAttribute("Selected", selected)
			local label = getLabel(button, "Label")
			if label then
				label.TextTransparency = if selected then 0 else 0.25
			end

			local back = button:FindFirstChild("Back")
			if back then
				if back:IsA("GuiObject") then
					back.Visible = selected
				end
			end
		end
	end
end

local function updateTimer(record: BoardRecord)
	local timer = record.timer
	if not timer then
		return
	end

	local payload = record.cache[record.selectedPeriod]
	if typeof(payload) ~= "table" then
		timer.Text = ""
		return
	end

	local now = math.floor(Workspace:GetServerTimeNow())
	if typeof(payload.periodResetsAt) == "number" then
		timer.Text = "Resets in: " .. formatDuration(payload.periodResetsAt - now)
		return
	end

	if typeof(payload.nextRefreshAt) == "number" then
		timer.Text = "Refreshes in: " .. formatDuration(payload.nextRefreshAt - now)
		return
	end

	timer.Text = ""
end

local function isPayloadExpired(payload): boolean
	if typeof(payload) ~= "table" then
		return true
	end

	local now = math.floor(Workspace:GetServerTimeNow())
	if typeof(payload.periodResetsAt) == "number" and now >= payload.periodResetsAt then
		return true
	end
	if typeof(payload.nextRefreshAt) == "number" and now >= payload.nextRefreshAt then
		return true
	end

	return false
end

local function arrayContains(values, target: string): boolean
	if typeof(values) ~= "table" then
		return true
	end

	for _, value in ipairs(values) do
		if value == target then
			return true
		end
	end

	return false
end

local function invokeLeaderboard(boardId: string, periodId: string)
	local remote = getLeaderboardRemote
	if not remote then
		return nil
	end

	local success, result = pcall(function()
		return remote:InvokeServer({
			board = boardId,
			period = periodId,
		})
	end)
	if not success or typeof(result) ~= "table" or result.ok ~= true then
		if not success then
			warn("[GlobalLeaderboardController] Request failed:", result)
		end
		return nil
	end

	return result
end

local function renderSelectedPeriod(record: BoardRecord)
	local payload = record.cache[record.selectedPeriod]
	local entries = if typeof(payload) == "table" then payload.entries else {}
	renderRows(record, entries)
	updateButtonState(record)
	updateTimer(record)
	updateFeaturedDisplay(record, entries)
end

local function fetchAndRender(record: BoardRecord, periodId: string, force: boolean?): boolean
	if record.fetchingPeriods[periodId] then
		return false
	end

	local now = os.clock()
	local lastFetchStartedAt = record.lastFetchStartedAt[periodId]
	if not force and lastFetchStartedAt and now - lastFetchStartedAt < FETCH_RETRY_SECONDS then
		return false
	end

	record.fetchingPeriods[periodId] = true
	record.lastFetchStartedAt[periodId] = now
	local payload = invokeLeaderboard(record.id, periodId)
	record.fetchingPeriods[periodId] = nil
	if not payload then
		return false
	end

	record.cache[periodId] = payload
	if record.selectedPeriod == periodId then
		renderSelectedPeriod(record)
	end
	return true
end

local function selectPeriod(record: BoardRecord, periodId: string)
	record.selectedPeriod = periodId
	updateButtonState(record)

	local payload = record.cache[periodId]
	if not payload then
		fetchAndRender(record, periodId)
	elseif isPayloadExpired(payload) then
		if not fetchAndRender(record, periodId) then
			renderSelectedPeriod(record)
		end
	else
		renderSelectedPeriod(record)
	end
end

local function selectPeriodFromInput(record: BoardRecord, periodId: string)
	local now = os.clock()
	if record.lastInputSelectPeriod == periodId and now - record.lastInputSelectAt < 0.12 then
		return
	end

	record.lastInputSelectAt = now
	record.lastInputSelectPeriod = periodId
	selectPeriod(record, periodId)
end

local function handleLeaderboardUpdated(payload)
	if typeof(payload) ~= "table" then
		return
	end

	local boards = payload.boards
	local periods = payload.periods
	for _, record in ipairs(boardRecords) do
		if not arrayContains(boards, record.id) then
			continue
		end

		local selectedPeriodUpdated = false
		for periodId in pairs(PERIOD_BUTTONS) do
			if arrayContains(periods, periodId) then
				record.cache[periodId] = nil
				if periodId == record.selectedPeriod then
					selectedPeriodUpdated = true
				end
			end
		end

		if selectedPeriodUpdated then
			fetchAndRender(record, record.selectedPeriod, true)
		end
	end
end

local function bindButtons(record: BoardRecord)
	for buttonName, periodId in pairs(BUTTON_PERIODS) do
		local button = getButton(record.topbar, buttonName)
		if not button then
			continue
		end

		button.Active = true
		button.Selectable = true
		button.AutoButtonColor = true

		table.insert(record.connections, button.Activated:Connect(function()
			selectPeriodFromInput(record, periodId)
		end))
	end
end

local function getInputPosition(input: InputObject): Vector2?
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return nil
	end

	local position = input.Position
	return Vector2.new(position.X, position.Y)
end

local function getInputPositions(input: InputObject): { Vector2 }
	local positions = {}
	local endedPosition = getInputPosition(input)
	local beganPosition = inputBeganPositions[input]

	if endedPosition then
		table.insert(positions, endedPosition)
	end
	if beganPosition and (not endedPosition or (beganPosition - endedPosition).Magnitude > 1) then
		table.insert(positions, beganPosition)
	end

	return positions
end

local function getRecordForUiPart(instance: Instance?): BoardRecord?
	if not instance then
		return nil
	end

	for _, record in ipairs(boardRecords) do
		if instance == record.uiPart then
			return record
		end
	end
	return nil
end

local function raycastLeaderboardRecord(screenPosition: Vector2): (BoardRecord?, Vector3?)
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil, nil
	end

	local uiParts = {}
	for _, record in ipairs(boardRecords) do
		table.insert(uiParts, record.uiPart)
	end
	if #uiParts <= 0 then
		return nil, nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = uiParts

	local inset = GuiService:GetGuiInset()
	local rayPositions = {
		screenPosition,
		Vector2.new(screenPosition.X - inset.X, screenPosition.Y - inset.Y),
	}

	for _, rayPosition in ipairs(rayPositions) do
		for _, ray in ipairs({
			camera:ScreenPointToRay(rayPosition.X, rayPosition.Y),
			camera:ViewportPointToRay(rayPosition.X, rayPosition.Y),
		}) do
			local result = Workspace:Raycast(ray.Origin, ray.Direction * 10000, params)
			local record = result and getRecordForUiPart(result.Instance) or nil
			if record then
				return record, result.Position
			end
		end
	end

	return nil, nil
end

local function getSurfaceCanvasPosition(record: BoardRecord, worldPosition: Vector3): Vector2?
	local localPosition = record.uiPart.CFrame:PointToObjectSpace(worldPosition)
	local size = record.uiPart.Size
	if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
		return nil
	end

	local face = record.surfaceGui.Face
	local u = 0.5
	local v = 0.5

	if face == Enum.NormalId.Back then
		u = 0.5 + (localPosition.X / size.X)
		v = 0.5 - (localPosition.Y / size.Y)
	elseif face == Enum.NormalId.Front then
		u = 0.5 - (localPosition.X / size.X)
		v = 0.5 - (localPosition.Y / size.Y)
	elseif face == Enum.NormalId.Right then
		u = 0.5 + (localPosition.Z / size.Z)
		v = 0.5 - (localPosition.Y / size.Y)
	elseif face == Enum.NormalId.Left then
		u = 0.5 - (localPosition.Z / size.Z)
		v = 0.5 - (localPosition.Y / size.Y)
	elseif face == Enum.NormalId.Top then
		u = 0.5 + (localPosition.X / size.X)
		v = 0.5 + (localPosition.Z / size.Z)
	elseif face == Enum.NormalId.Bottom then
		u = 0.5 + (localPosition.X / size.X)
		v = 0.5 - (localPosition.Z / size.Z)
	end

	if u < 0 or u > 1 or v < 0 or v > 1 then
		return nil
	end

	local canvasSize = record.surfaceGui.CanvasSize
	return Vector2.new(u * canvasSize.X, v * canvasSize.Y)
end

local function isCanvasPointInside(button: GuiObject, canvasPosition: Vector2): boolean
	local position = button.AbsolutePosition
	local size = button.AbsoluteSize
	return canvasPosition.X >= position.X
		and canvasPosition.X <= position.X + size.X
		and canvasPosition.Y >= position.Y
		and canvasPosition.Y <= position.Y + size.Y
end

local function findTabButtonAtCanvasPosition(record: BoardRecord, canvasPosition: Vector2): ImageButton?
	for buttonName in pairs(BUTTON_PERIODS) do
		local button = getButton(record.topbar, buttonName)
		if button and button.Visible and isCanvasPointInside(button, canvasPosition) then
			return button
		end
	end
	return nil
end

local function bindRaycastTabInput()
	UserInputService.InputBegan:Connect(function(input)
		local screenPosition = getInputPosition(input)
		if screenPosition then
			inputBeganPositions[input] = screenPosition
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		local positions = getInputPositions(input)
		inputBeganPositions[input] = nil
		if #positions <= 0 then
			return
		end

		for _, screenPosition in ipairs(positions) do
			local record, hitPosition = raycastLeaderboardRecord(screenPosition)
			if not (record and hitPosition) then
				continue
			end

			local canvasPosition = getSurfaceCanvasPosition(record, hitPosition)
			if not canvasPosition then
				continue
			end

			local button = findTabButtonAtCanvasPosition(record, canvasPosition)
			local periodId = button and BUTTON_PERIODS[button.Name] or nil
			if periodId then
				selectPeriodFromInput(record, periodId)
				return
			end
		end
	end)
end

local function disableSourceSurfaceGui(surfaceGui: SurfaceGui)
	if surfaceGui.Enabled then
		surfaceGui.Enabled = false
	end
end

local function keepSourceSurfaceGuiDisabled(uiPart: BasePart, sourceSurfaceGui: SurfaceGui, connections: { RBXScriptConnection })
	local function watchSurfaceGui(surfaceGui: SurfaceGui)
		disableSourceSurfaceGui(surfaceGui)
		table.insert(connections, surfaceGui:GetPropertyChangedSignal("Enabled"):Connect(function()
			disableSourceSurfaceGui(surfaceGui)
		end))
	end

	watchSurfaceGui(sourceSurfaceGui)
	table.insert(connections, uiPart.ChildAdded:Connect(function(child)
		if child.Name == "SurfaceGui" and child:IsA("SurfaceGui") then
			watchSurfaceGui(child)
		end
	end))
end

local function hostSurfaceGui(config, uiPart: BasePart, sourceSurfaceGui: SurfaceGui): SurfaceGui?
	local cloneName = SURFACE_GUI_CLONE_PREFIX .. config.modelName
	local existing = PlayerGui:FindFirstChild(cloneName)
	if existing then
		existing:Destroy()
	end

	local success, clone = pcall(function()
		return sourceSurfaceGui:Clone()
	end)
	if not success or not clone or not clone:IsA("SurfaceGui") then
		warn("[GlobalLeaderboardController] Failed to clone SurfaceGui for", config.modelName, clone)
		return nil
	end

	clone.Name = cloneName
	clone.Adornee = uiPart
	clone.ResetOnSpawn = false
	clone.Active = true
	clone.Enabled = true
	clone.Parent = PlayerGui

	disableSourceSurfaceGui(sourceSurfaceGui)
	return clone
end

local function findLeaderboardModel(config): Model?
	local lobby = Workspace:FindFirstChild("Lobby") or Workspace:WaitForChild("Lobby", 30)
	if lobby then
		local model = lobby:FindFirstChild(config.modelName) or lobby:WaitForChild(config.modelName, 30)
		if model and model:IsA("Model") then
			return model
		end
	end

	local model = Workspace:FindFirstChild(config.modelName, true)
	if model and model:IsA("Model") then
		return model
	end

	warn("[GlobalLeaderboardController] Missing leaderboard model", config.modelName)
	return nil
end

local function findNearestSiblingDisplayModel(config, model: Model, uiPart: BasePart): Model?
	local parent = model.Parent
	if not parent then
		return nil
	end

	local nearestModel = nil
	local nearestDistance = math.huge
	local anchorPosition = uiPart.Position
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("Model") and child.Name == config.fallbackDisplayModelName then
			local distance = (getModelPosition(child) - anchorPosition).Magnitude
			if distance < nearestDistance then
				nearestDistance = distance
				nearestModel = child
			end
		end
	end

	return nearestModel
end

local function findDisplayModel(config, model: Model, uiPart: BasePart): Model?
	local displayModel = getChildModel(model, config.displayModelName)
	if displayModel then
		return displayModel
	end

	displayModel = getChildModel(model, config.fallbackDisplayModelName)
	if displayModel then
		return displayModel
	end

	return findNearestSiblingDisplayModel(config, model, uiPart)
end

local function findBoardRecord(config): BoardRecord?
	local model = findLeaderboardModel(config)
	local uiPart = model and model:WaitForChild("UIPart", 30)
	if not (uiPart and uiPart:IsA("BasePart")) then
		warn("[GlobalLeaderboardController] Missing UIPart for", config.modelName)
		return nil
	end

	local sourceSurfaceGui = uiPart:WaitForChild("SurfaceGui", 30)
	if not (sourceSurfaceGui and sourceSurfaceGui:IsA("SurfaceGui")) then
		warn("[GlobalLeaderboardController] Missing source SurfaceGui for", config.modelName)
		return nil
	end

	local connections = {}
	local surfaceGui = hostSurfaceGui(config, uiPart, sourceSurfaceGui)
	keepSourceSurfaceGuiDisabled(uiPart, sourceSurfaceGui, connections)
	local leaderboard = surfaceGui and surfaceGui:WaitForChild("Leaderboard", 30)
	local scrollingFrame = leaderboard and leaderboard:WaitForChild("ScrollingFrame", 30)
	local topbar = leaderboard and leaderboard:WaitForChild("Topbar", 30)

	if not (
		leaderboard
		and leaderboard:IsA("Frame")
		and scrollingFrame
		and scrollingFrame:IsA("ScrollingFrame")
		and topbar
		and topbar:IsA("Frame")
	) then
		warn("[GlobalLeaderboardController] Missing leaderboard UI for", config.modelName)
		return nil
	end

	local gold = scrollingFrame:FindFirstChild("GoldTemplate")
	local silver = scrollingFrame:FindFirstChild("SilverTemplate")
	local bronze = scrollingFrame:FindFirstChild("BronzeTemplate")
	local normal = scrollingFrame:FindFirstChild("Template")
	if not (gold and gold:IsA("Frame") and silver and silver:IsA("Frame") and bronze and bronze:IsA("Frame") and normal and normal:IsA("Frame")) then
		warn("[GlobalLeaderboardController] Missing row templates for", config.modelName)
		return nil
	end

	local displayModel = findDisplayModel(config, model, uiPart)
	local displayRig = displayModel and displayModel:FindFirstChild("Rig")
	local displayRootPart = if displayRig and displayRig:IsA("Model") then getRigRootPart(displayRig) else nil
	local displayRootCFrame = displayRootPart and displayRootPart.CFrame or nil

	if displayModel and not displayRootCFrame then
		warn("[GlobalLeaderboardController] Missing display Rig HumanoidRootPart for", config.modelName)
	elseif not displayModel then
		warn("[GlobalLeaderboardController] Missing player display model for", config.modelName, config.displayModelName)
	end

	return {
		id = config.id,
		modelName = config.modelName,
		metricLabel = config.metricLabel,
		rankText = config.rankText,
		uiPart = uiPart,
		surfaceGui = surfaceGui,
		leaderboard = leaderboard,
		scrollingFrame = scrollingFrame,
		topbar = topbar,
		timer = getLabel(leaderboard, "Timer"),
		templates = {
			gold = gold,
			silver = silver,
			bronze = bronze,
			normal = normal,
		},
		displayModel = displayModel,
		displayRootCFrame = displayRootCFrame,
		displayUsernameLabel = findDescendantTextLabel(displayModel, "Username"),
		displayCountLabel = findDescendantTextLabel(displayModel, "Count"),
		displayRankLabel = findDescendantTextLabel(displayModel, "Rank"),
		displayedUserId = nil,
		displayedPeriod = nil,
		displaySerial = 0,
		displayTrack = nil,
		displayAnimation = nil,
		selectedPeriod = "allTime",
		cache = {},
		fetchingPeriods = {},
		lastFetchStartedAt = {},
		connections = connections,
		lastInputSelectAt = 0,
		lastInputSelectPeriod = nil,
	}
end

local function startTimerLoop()
	task.spawn(function()
		while true do
			for _, record in ipairs(boardRecords) do
				local payload = record.cache[record.selectedPeriod]
				if isPayloadExpired(payload) then
					fetchAndRender(record, record.selectedPeriod)
				else
					updateTimer(record)
				end
			end
			task.wait(1)
		end
	end)
end

function GlobalLeaderboardController:OnStart()
	cleanupHostedSurfaceGuis()

	local remotesFolder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 30)
	local remote = remotesFolder and remotesFolder:WaitForChild(GET_LEADERBOARD_REMOTE_NAME, 30)
	if not (remote and remote:IsA("RemoteFunction")) then
		warn("[GlobalLeaderboardController] Missing GetGlobalLeaderboard remote")
		return
	end
	getLeaderboardRemote = remote
	local updatedRemote = remotesFolder and remotesFolder:WaitForChild(LEADERBOARD_UPDATED_REMOTE_NAME, 30)
	if updatedRemote and updatedRemote:IsA("RemoteEvent") then
		leaderboardUpdatedRemote = updatedRemote
		leaderboardUpdatedRemote.OnClientEvent:Connect(handleLeaderboardUpdated)
	else
		warn("[GlobalLeaderboardController] Missing GlobalLeaderboardUpdated remote")
	end

	for _, config in ipairs(BOARD_CONFIGS) do
		local record = findBoardRecord(config)
		if record then
			table.insert(boardRecords, record)
			hideTemplates(record)
			bindButtons(record)
			selectPeriod(record, "allTime")
		end
	end

	bindRaycastTabInput()
	startTimerLoop()
end

return GlobalLeaderboardController
