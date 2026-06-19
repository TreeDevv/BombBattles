local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local RoundService = require(ServerScriptService.Services.RoundService)

local GAME_SCREEN_PATH = { "Lobby", "GameScreen" }
local PLAYER_COUNTER_PATH = { "Lobby", "PlayerCounter" }
local UPDATE_INTERVAL_SECONDS = 0.25
local SCREEN_STYLE_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local AFK_ATTR = "AFK"
local ROUND_ID_ATTR = "RoundId"

local RED_TEAM_NAME = RoundConfig.Teams.Red.name
local BLUE_TEAM_NAME = RoundConfig.Teams.Blue.name

local widgets = nil
local started = false
local missingWidgetsWarned = false
local screenStyleState: string? = nil
local activeStyleTweens = {}

local WHITE = Color3.new(1, 1, 1)
local NEAR_WHITE = Color3.fromRGB(245, 245, 245)
local MAIN_BEAM_INTERMISSION_COLOR = Color3.fromRGB(159, 159, 159)
local MIDDLE_BEAM_INTERMISSION_COLOR = Color3.fromRGB(94, 94, 94)
local MAIN_SCREEN_INTERMISSION_COLOR = Color3.fromRGB(42, 42, 42)
local SIDE_SCREEN_INTERMISSION_COLOR = Color3.fromRGB(31, 31, 31)
local RIGHT_SCREEN_INTERMISSION_COLOR = Color3.fromRGB(59, 59, 59)
local MAIN_FRAME_INTERMISSION_COLOR = Color3.fromRGB(163, 162, 165)
local BOARD_FRAME_INTERMISSION_COLOR = Color3.fromRGB(119, 119, 121)
local MAIN_GLOW_INTERMISSION_COLOR = Color3.fromRGB(189, 189, 189)
local SIDE_GLOW_INTERMISSION_COLOR = Color3.fromRGB(254, 254, 254)
local MIDDLE_GLOW_INTERMISSION_COLOR = Color3.fromRGB(252, 250, 255)
local RIGHT_GLOW_INTERMISSION_COLOR = Color3.fromRGB(255, 255, 255)

local INTERMISSION_STYLE = {
	mainHeadingColor = WHITE,
	subheadingColor = WHITE,
	timerColor = WHITE,
	redRespawnsColor = WHITE,
	blueRespawnsColor = WHITE,

	mainHeadingStrokeColor = NEAR_WHITE,
	subheadingStrokeColor = NEAR_WHITE,
	timerStrokeColor = WHITE,
	redRespawnsStrokeColor = NEAR_WHITE,
	blueRespawnsStrokeColor = WHITE,
	strokeTransparency = 0.92,
	strokeThickness = 0.04,

	mainLightColor = WHITE,
	middleLightColor = WHITE,
	redLightColor = WHITE,
	blueLightColor = WHITE,
	mainLightRange = 12,
	middleLightRange = 8,
	redLightRange = 8,
	blueLightRange = 8,
	mainLightBrightness = 1,
	middleLightBrightness = 1,
	redLightBrightness = 1,
	blueLightBrightness = 1.66,

	mainBeamColor = MAIN_BEAM_INTERMISSION_COLOR,
	middleBeamColor = MIDDLE_BEAM_INTERMISSION_COLOR,
	redBeamColor = MAIN_BEAM_INTERMISSION_COLOR,
	blueBeamColor = MAIN_BEAM_INTERMISSION_COLOR,

	mainScreenColor = MAIN_SCREEN_INTERMISSION_COLOR,
	leftScreenColor = SIDE_SCREEN_INTERMISSION_COLOR,
	middleScreenColor = SIDE_SCREEN_INTERMISSION_COLOR,
	rightScreenColor = RIGHT_SCREEN_INTERMISSION_COLOR,
	mainFrameColor = MAIN_FRAME_INTERMISSION_COLOR,
	leftFrameColor = BOARD_FRAME_INTERMISSION_COLOR,
	middleFrameColor = BOARD_FRAME_INTERMISSION_COLOR,
	rightFrameColor = BOARD_FRAME_INTERMISSION_COLOR,
	mainGlowColor = MAIN_GLOW_INTERMISSION_COLOR,
	leftGlowColor = SIDE_GLOW_INTERMISSION_COLOR,
	middleGlowColor = MIDDLE_GLOW_INTERMISSION_COLOR,
	rightGlowColor = RIGHT_GLOW_INTERMISSION_COLOR,
}

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

local function getLabelStroke(label: TextLabel?): UIStroke?
	local stroke = findChild(label, "UIStroke")
	return if stroke and stroke:IsA("UIStroke") then stroke else nil
end

local function findScreenChild(gameScreen: Instance, screenName: string): Instance?
	return findChild(gameScreen, screenName)
end

local function findScreenMeshPart(gameScreen: Instance, partName: string): MeshPart?
	local part = findChild(gameScreen, partName)
	return if part and part:IsA("MeshPart") then part else nil
end

local function findScreenLight(gameScreen: Instance, screenName: string): PointLight?
	local screen = findScreenChild(gameScreen, screenName)
	local attachment = findChild(screen, "LightAtt")
	local light = findChild(attachment, "PointLight")
	return if light and light:IsA("PointLight") then light else nil
end

local function findScreenBeam(gameScreen: Instance, screenName: string): Beam?
	local screen = findScreenChild(gameScreen, screenName)
	local attachment = findChild(screen, "TVStaticBeam")
	local beam = findChild(attachment, "Beam")
	return if beam and beam:IsA("Beam") then beam else nil
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
	local mainHeadingStroke = getLabelStroke(mainHeading)
	local subheadingStroke = getLabelStroke(subheading)
	local timerStroke = getLabelStroke(timerLabel)
	local redRespawnsStroke = getLabelStroke(redRespawnsLabel)
	local blueRespawnsStroke = getLabelStroke(blueRespawnsLabel)
	local mainLight = findScreenLight(gameScreen, "MainScreen")
	local middleLight = findScreenLight(gameScreen, "MiddleScreen")
	local redLight = findScreenLight(gameScreen, "LeftScreen")
	local blueLight = findScreenLight(gameScreen, "RightScreen")
	local mainBeam = findScreenBeam(gameScreen, "MainScreen")
	local middleBeam = findScreenBeam(gameScreen, "MiddleScreen")
	local redBeam = findScreenBeam(gameScreen, "LeftScreen")
	local blueBeam = findScreenBeam(gameScreen, "RightScreen")
	local mainScreenPart = findScreenMeshPart(gameScreen, "MainScreen")
	local leftScreenPart = findScreenMeshPart(gameScreen, "LeftScreen")
	local middleScreenPart = findScreenMeshPart(gameScreen, "MiddleScreen")
	local rightScreenPart = findScreenMeshPart(gameScreen, "RightScreen")
	local mainFramePart = findScreenMeshPart(gameScreen, "Main")
	local leftFramePart = findScreenMeshPart(gameScreen, "Left")
	local middleFramePart = findScreenMeshPart(gameScreen, "Middle")
	local rightFramePart = findScreenMeshPart(gameScreen, "Right")
	local mainGlowPart = findScreenMeshPart(gameScreen, "MainGlow")
	local leftGlowPart = findScreenMeshPart(gameScreen, "LeftGlow")
	local middleGlowPart = findScreenMeshPart(gameScreen, "MiddleGlow")
	local rightGlowPart = findScreenMeshPart(gameScreen, "RightGlow")
	local aliveCounterValue = findTextLabel(aliveCounterFrame, "Value")
	local inServerCounterValue = findTextLabel(inServerCounterFrame, "Value")
	local playingCounterValue = findTextLabel(playingCounterFrame, "Value")

	if not (
		mainHeading
		and subheading
		and timerLabel
		and mainHeadingStroke
		and subheadingStroke
		and timerStroke
		and redRespawnsGui
		and redRespawnsLabel
		and redRespawnsStroke
		and blueRespawnsGui
		and blueRespawnsLabel
		and blueRespawnsStroke
		and mainLight
		and middleLight
		and redLight
		and blueLight
		and mainBeam
		and middleBeam
		and redBeam
		and blueBeam
		and mainScreenPart
		and leftScreenPart
		and middleScreenPart
		and rightScreenPart
		and mainFramePart
		and leftFramePart
		and middleFramePart
		and rightFramePart
		and mainGlowPart
		and leftGlowPart
		and middleGlowPart
		and rightGlowPart
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
		mainHeadingStroke = mainHeadingStroke,
		subheadingStroke = subheadingStroke,
		timerStroke = timerStroke,
		redRespawnsGui = redRespawnsGui,
		redRespawnsLabel = redRespawnsLabel,
		redRespawnsStroke = redRespawnsStroke,
		blueRespawnsGui = blueRespawnsGui,
		blueRespawnsLabel = blueRespawnsLabel,
		blueRespawnsStroke = blueRespawnsStroke,
		mainLight = mainLight,
		middleLight = middleLight,
		redLight = redLight,
		blueLight = blueLight,
		mainBeam = mainBeam,
		middleBeam = middleBeam,
		redBeam = redBeam,
		blueBeam = blueBeam,
		mainScreenPart = mainScreenPart,
		leftScreenPart = leftScreenPart,
		middleScreenPart = middleScreenPart,
		rightScreenPart = rightScreenPart,
		mainFramePart = mainFramePart,
		leftFramePart = leftFramePart,
		middleFramePart = middleFramePart,
		rightFramePart = rightFramePart,
		mainGlowPart = mainGlowPart,
		leftGlowPart = leftGlowPart,
		middleGlowPart = middleGlowPart,
		rightGlowPart = rightGlowPart,
		aliveCounterValue = aliveCounterValue,
		inServerCounterValue = inServerCounterValue,
		playingCounterValue = playingCounterValue,
		normalStyle = nil,
	}
end

local function areWidgetsAlive(currentWidgets): boolean
	return currentWidgets
		and currentWidgets.mainHeading:IsDescendantOf(Workspace)
		and currentWidgets.subheading:IsDescendantOf(Workspace)
		and currentWidgets.timerLabel:IsDescendantOf(Workspace)
		and currentWidgets.mainHeadingStroke:IsDescendantOf(Workspace)
		and currentWidgets.subheadingStroke:IsDescendantOf(Workspace)
		and currentWidgets.timerStroke:IsDescendantOf(Workspace)
		and currentWidgets.redRespawnsGui:IsDescendantOf(Workspace)
		and currentWidgets.redRespawnsLabel:IsDescendantOf(Workspace)
		and currentWidgets.redRespawnsStroke:IsDescendantOf(Workspace)
		and currentWidgets.blueRespawnsGui:IsDescendantOf(Workspace)
		and currentWidgets.blueRespawnsLabel:IsDescendantOf(Workspace)
		and currentWidgets.blueRespawnsStroke:IsDescendantOf(Workspace)
		and currentWidgets.mainLight:IsDescendantOf(Workspace)
		and currentWidgets.middleLight:IsDescendantOf(Workspace)
		and currentWidgets.redLight:IsDescendantOf(Workspace)
		and currentWidgets.blueLight:IsDescendantOf(Workspace)
		and currentWidgets.mainBeam:IsDescendantOf(Workspace)
		and currentWidgets.middleBeam:IsDescendantOf(Workspace)
		and currentWidgets.redBeam:IsDescendantOf(Workspace)
		and currentWidgets.blueBeam:IsDescendantOf(Workspace)
		and currentWidgets.mainScreenPart:IsDescendantOf(Workspace)
		and currentWidgets.leftScreenPart:IsDescendantOf(Workspace)
		and currentWidgets.middleScreenPart:IsDescendantOf(Workspace)
		and currentWidgets.rightScreenPart:IsDescendantOf(Workspace)
		and currentWidgets.mainFramePart:IsDescendantOf(Workspace)
		and currentWidgets.leftFramePart:IsDescendantOf(Workspace)
		and currentWidgets.middleFramePart:IsDescendantOf(Workspace)
		and currentWidgets.rightFramePart:IsDescendantOf(Workspace)
		and currentWidgets.mainGlowPart:IsDescendantOf(Workspace)
		and currentWidgets.leftGlowPart:IsDescendantOf(Workspace)
		and currentWidgets.middleGlowPart:IsDescendantOf(Workspace)
		and currentWidgets.rightGlowPart:IsDescendantOf(Workspace)
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
		screenStyleState = nil
		missingWidgetsWarned = false
	elseif not missingWidgetsWarned then
		warn("[GameScreenService] Missing GameScreen or PlayerCounter widgets under Workspace.Lobby")
		missingWidgetsWarned = true
	end

	return widgets
end

local function getBeamColor(beam: Beam): Color3
	local keypoints = beam.Color.Keypoints
	local firstKeypoint = keypoints[1]
	return if firstKeypoint then firstKeypoint.Value else WHITE
end

local function cancelStyleTween(instance: Instance)
	local record = activeStyleTweens[instance]
	if not record then
		return
	end

	if record.tween then
		record.tween:Cancel()
	end
	if record.connection then
		record.connection:Disconnect()
	end
	if record.driver then
		record.driver:Destroy()
	end

	activeStyleTweens[instance] = nil
end

local function tweenProperties(instance: Instance, goals)
	cancelStyleTween(instance)

	local tween = TweenService:Create(instance, SCREEN_STYLE_TWEEN, goals)
	local record = {
		tween = tween,
	}
	activeStyleTweens[instance] = record

	tween.Completed:Connect(function()
		if activeStyleTweens[instance] == record then
			activeStyleTweens[instance] = nil
		end
	end)

	tween:Play()
end

local function tweenBeamColor(beam: Beam, targetColor: Color3)
	cancelStyleTween(beam)

	local driver = Instance.new("Color3Value")
	driver.Value = getBeamColor(beam)
	local record = {
		driver = driver,
	}

	record.connection = driver:GetPropertyChangedSignal("Value"):Connect(function()
		beam.Color = ColorSequence.new(driver.Value)
	end)

	local tween = TweenService:Create(driver, SCREEN_STYLE_TWEEN, {
		Value = targetColor,
	})
	record.tween = tween
	activeStyleTweens[beam] = record

	tween.Completed:Connect(function()
		if activeStyleTweens[beam] == record then
			beam.Color = ColorSequence.new(targetColor)
			record.connection:Disconnect()
			driver:Destroy()
			activeStyleTweens[beam] = nil
		end
	end)

	tween:Play()
end

local function captureScreenStyle(currentWidgets)
	return {
		mainHeadingColor = currentWidgets.mainHeading.TextColor3,
		subheadingColor = currentWidgets.subheading.TextColor3,
		timerColor = currentWidgets.timerLabel.TextColor3,
		redRespawnsColor = currentWidgets.redRespawnsLabel.TextColor3,
		blueRespawnsColor = currentWidgets.blueRespawnsLabel.TextColor3,

		mainHeadingStrokeColor = currentWidgets.mainHeadingStroke.Color,
		subheadingStrokeColor = currentWidgets.subheadingStroke.Color,
		timerStrokeColor = currentWidgets.timerStroke.Color,
		redRespawnsStrokeColor = currentWidgets.redRespawnsStroke.Color,
		blueRespawnsStrokeColor = currentWidgets.blueRespawnsStroke.Color,
		mainHeadingStrokeTransparency = currentWidgets.mainHeadingStroke.Transparency,
		subheadingStrokeTransparency = currentWidgets.subheadingStroke.Transparency,
		timerStrokeTransparency = currentWidgets.timerStroke.Transparency,
		redRespawnsStrokeTransparency = currentWidgets.redRespawnsStroke.Transparency,
		blueRespawnsStrokeTransparency = currentWidgets.blueRespawnsStroke.Transparency,
		mainHeadingStrokeThickness = currentWidgets.mainHeadingStroke.Thickness,
		subheadingStrokeThickness = currentWidgets.subheadingStroke.Thickness,
		timerStrokeThickness = currentWidgets.timerStroke.Thickness,
		redRespawnsStrokeThickness = currentWidgets.redRespawnsStroke.Thickness,
		blueRespawnsStrokeThickness = currentWidgets.blueRespawnsStroke.Thickness,

		mainLightColor = currentWidgets.mainLight.Color,
		middleLightColor = currentWidgets.middleLight.Color,
		redLightColor = currentWidgets.redLight.Color,
		blueLightColor = currentWidgets.blueLight.Color,
		mainLightRange = currentWidgets.mainLight.Range,
		middleLightRange = currentWidgets.middleLight.Range,
		redLightRange = currentWidgets.redLight.Range,
		blueLightRange = currentWidgets.blueLight.Range,
		mainLightBrightness = currentWidgets.mainLight.Brightness,
		middleLightBrightness = currentWidgets.middleLight.Brightness,
		redLightBrightness = currentWidgets.redLight.Brightness,
		blueLightBrightness = currentWidgets.blueLight.Brightness,

		mainBeamColor = getBeamColor(currentWidgets.mainBeam),
		middleBeamColor = getBeamColor(currentWidgets.middleBeam),
		redBeamColor = getBeamColor(currentWidgets.redBeam),
		blueBeamColor = getBeamColor(currentWidgets.blueBeam),

		mainScreenColor = currentWidgets.mainScreenPart.Color,
		leftScreenColor = currentWidgets.leftScreenPart.Color,
		middleScreenColor = currentWidgets.middleScreenPart.Color,
		rightScreenColor = currentWidgets.rightScreenPart.Color,
		mainFrameColor = currentWidgets.mainFramePart.Color,
		leftFrameColor = currentWidgets.leftFramePart.Color,
		middleFrameColor = currentWidgets.middleFramePart.Color,
		rightFrameColor = currentWidgets.rightFramePart.Color,
		mainGlowColor = currentWidgets.mainGlowPart.Color,
		leftGlowColor = currentWidgets.leftGlowPart.Color,
		middleGlowColor = currentWidgets.middleGlowPart.Color,
		rightGlowColor = currentWidgets.rightGlowPart.Color,
	}
end

local function getStrokeTransparency(style, key: string): number
	return style[key .. "StrokeTransparency"] or style.strokeTransparency
end

local function getStrokeThickness(style, key: string): number
	return style[key .. "StrokeThickness"] or style.strokeThickness
end

local function tweenStroke(stroke: UIStroke, style, key: string)
	tweenProperties(stroke, {
		Color = style[key .. "StrokeColor"],
		Transparency = getStrokeTransparency(style, key),
		Thickness = getStrokeThickness(style, key),
	})
end

local function applyScreenStyle(currentWidgets, isIntermission: boolean)
	local nextStyleState = if isIntermission then "intermission" else "normal"
	if screenStyleState == nextStyleState then
		return
	end
	screenStyleState = nextStyleState

	if not currentWidgets.normalStyle then
		currentWidgets.normalStyle = captureScreenStyle(currentWidgets)
	end

	local style = if isIntermission then INTERMISSION_STYLE else currentWidgets.normalStyle

	tweenProperties(currentWidgets.mainHeading, { TextColor3 = style.mainHeadingColor })
	tweenProperties(currentWidgets.subheading, { TextColor3 = style.subheadingColor })
	tweenProperties(currentWidgets.timerLabel, { TextColor3 = style.timerColor })
	tweenProperties(currentWidgets.redRespawnsLabel, { TextColor3 = style.redRespawnsColor })
	tweenProperties(currentWidgets.blueRespawnsLabel, { TextColor3 = style.blueRespawnsColor })

	tweenStroke(currentWidgets.mainHeadingStroke, style, "mainHeading")
	tweenStroke(currentWidgets.subheadingStroke, style, "subheading")
	tweenStroke(currentWidgets.timerStroke, style, "timer")
	tweenStroke(currentWidgets.redRespawnsStroke, style, "redRespawns")
	tweenStroke(currentWidgets.blueRespawnsStroke, style, "blueRespawns")

	tweenProperties(currentWidgets.mainLight, {
		Color = style.mainLightColor,
		Range = style.mainLightRange,
		Brightness = style.mainLightBrightness,
	})
	tweenProperties(currentWidgets.middleLight, {
		Color = style.middleLightColor,
		Range = style.middleLightRange,
		Brightness = style.middleLightBrightness,
	})
	tweenProperties(currentWidgets.redLight, {
		Color = style.redLightColor,
		Range = style.redLightRange,
		Brightness = style.redLightBrightness,
	})
	tweenProperties(currentWidgets.blueLight, {
		Color = style.blueLightColor,
		Range = style.blueLightRange,
		Brightness = style.blueLightBrightness,
	})

	tweenBeamColor(currentWidgets.mainBeam, style.mainBeamColor)
	tweenBeamColor(currentWidgets.middleBeam, style.middleBeamColor)
	tweenBeamColor(currentWidgets.redBeam, style.redBeamColor)
	tweenBeamColor(currentWidgets.blueBeam, style.blueBeamColor)

	tweenProperties(currentWidgets.mainScreenPart, { Color = style.mainScreenColor })
	tweenProperties(currentWidgets.leftScreenPart, { Color = style.leftScreenColor })
	tweenProperties(currentWidgets.middleScreenPart, { Color = style.middleScreenColor })
	tweenProperties(currentWidgets.rightScreenPart, { Color = style.rightScreenColor })
	tweenProperties(currentWidgets.mainFramePart, { Color = style.mainFrameColor })
	tweenProperties(currentWidgets.leftFramePart, { Color = style.leftFrameColor })
	tweenProperties(currentWidgets.middleFramePart, { Color = style.middleFrameColor })
	tweenProperties(currentWidgets.rightFramePart, { Color = style.rightFrameColor })
	tweenProperties(currentWidgets.mainGlowPart, { Color = style.mainGlowColor })
	tweenProperties(currentWidgets.leftGlowPart, { Color = style.leftGlowColor })
	tweenProperties(currentWidgets.middleGlowPart, { Color = style.middleGlowColor })
	tweenProperties(currentWidgets.rightGlowPart, { Color = style.rightGlowColor })
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
	elseif stateName == RoundStates.PlayOfTheGame then
		return "Play of the Game..."
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
	local stateName = state and state.state
	local isActive = stateName == RoundStates.Active
	local isIntermission = stateName == RoundStates.Intermission
	local usesIntermissionAppearance = isIntermission or stateName == RoundStates.WaitingForPlayers

	applyScreenStyle(currentWidgets, usesIntermissionAppearance == true)

	if isIntermission then
		currentWidgets.mainHeading.Text = "INTERMISSION"
		currentWidgets.subheading.Text = "Waiting for next round..."
	else
		currentWidgets.mainHeading.Text = tostring(RoundConfig.GameModeDisplayName or "TEAM DEATHMATCH")
		currentWidgets.subheading.Text = if stateName == RoundStates.WaitingForPlayers
			then "Waiting for players..."
			else formatSubheading(state)
	end
	currentWidgets.timerLabel.Text = formatTime(getRemainingSeconds(state))

	currentWidgets.redRespawnsGui.Enabled = isActive or usesIntermissionAppearance == true
	currentWidgets.blueRespawnsGui.Enabled = isActive or usesIntermissionAppearance == true
	currentWidgets.redRespawnsLabel.Text = if usesIntermissionAppearance then "..." else tostring(getCoreCount(state, RED_TEAM_NAME))
	currentWidgets.blueRespawnsLabel.Text = if usesIntermissionAppearance then "..." else tostring(getCoreCount(state, BLUE_TEAM_NAME))
	currentWidgets.aliveCounterValue.Text = tostring(getAlivePlayerCount(state))
	currentWidgets.inServerCounterValue.Text = tostring(#Players:GetPlayers())
	currentWidgets.playingCounterValue.Text = tostring(getPlayingPlayerCount(state))

	local latestState = RoundService:GetState()
	if latestState and latestState.state == RoundStates.WaitingForPlayers then
		currentWidgets.mainHeading.Text = tostring(RoundConfig.GameModeDisplayName or "TEAM DEATHMATCH")
		currentWidgets.subheading.Text = "Waiting for players..."
		currentWidgets.redRespawnsGui.Enabled = true
		currentWidgets.blueRespawnsGui.Enabled = true
		currentWidgets.redRespawnsLabel.Text = "..."
		currentWidgets.blueRespawnsLabel.Text = "..."
	end
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
