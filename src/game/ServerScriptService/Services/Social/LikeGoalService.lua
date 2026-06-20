local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LikeService = require(ServerScriptService.Services.LikeService)
local LikeGoalConfig = require(ReplicatedStorage.Shared.Config.LikeGoalConfig)
local NumberFormatter = require(ReplicatedStorage.Shared.Formatting.NumberFormatter)

local BOARD_PATH = { "Lobby", "Likeboard", "GUIFACE", "CODEPROGRESS", "Frame" }
local GOAL_TEXT_NAME = "Goal"
local GOAL_LABEL_NAME = "GoalProgress"
local BAR_NAME = "Bar"
local DEFAULT_GOAL_TEXT_TEMPLATE = "New code at %s Likes!"

local widgets = nil
local activeTween: Tween? = nil
local started = false

local function findChild(parent: Instance?, childName: string): Instance?
	if not parent then
		return nil
	end

	return parent:FindFirstChild(childName)
end

local function findBoardFrame(): Frame?
	local current: Instance? = Workspace
	for _, childName in ipairs(BOARD_PATH) do
		current = findChild(current, childName)
		if not current then
			return nil
		end
	end

	if current and current:IsA("Frame") then
		return current
	end

	return nil
end

local function bindWidgets()
	local frame = findBoardFrame()
	if not frame then
		return nil
	end

	local goalLabel = frame:FindFirstChild(GOAL_TEXT_NAME)
	local goalProgress = frame:FindFirstChild(GOAL_LABEL_NAME)
	local bar = frame:FindFirstChild(BAR_NAME)
	if not (
		goalLabel
		and goalLabel:IsA("TextLabel")
		and goalProgress
		and goalProgress:IsA("TextLabel")
		and bar
		and bar:IsA("Frame")
	) then
		return nil
	end

	return {
		frame = frame,
		goalLabel = goalLabel,
		goalTextTemplate = goalLabel.Text,
		goalProgress = goalProgress,
		bar = bar,
	}
end

local function getWidgets()
	if widgets and widgets.frame:IsDescendantOf(Workspace) then
		return widgets
	end

	widgets = bindWidgets()
	return widgets
end

local function sanitizeInteger(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue == math.huge or numberValue == -math.huge then
		return 0
	end

	return math.max(0, math.floor(numberValue + 0.5))
end

local function getGoalForLikes(likes: number): number
	local tiers = LikeGoalConfig.GoalTiers
	local fallbackGoal = 1

	for _, tier in ipairs(tiers) do
		local goal = sanitizeInteger(tier)
		if goal > 0 then
			fallbackGoal = goal
			if likes < goal then
				return goal
			end
		end
	end

	return fallbackGoal
end

local function formatLikeCount(value: number): string
	return NumberFormatter.Format(sanitizeInteger(value))
end

local function formatGoalTextCount(value: number): string
	value = sanitizeInteger(value)
	if value < 1000 then
		return tostring(value)
	end

	local short = value / 1000
	local formatted = if short % 1 == 0 then ("%d"):format(short) else ("%.1f"):format(short)
	return formatted .. "k"
end

local function formatGoalText(template: string, goal: number): string
	local formattedGoal = formatGoalTextCount(goal)
	local startIndex, endIndex = string.find(template, "%d+%.?%d*%s*[kKmM]?", 1)
	if startIndex and endIndex then
		return string.sub(template, 1, startIndex - 1) .. formattedGoal .. string.sub(template, endIndex + 1)
	end

	return DEFAULT_GOAL_TEXT_TEMPLATE:format(formattedGoal)
end

local function setBarWidth(bar: Frame, widthScale: number, animate: boolean)
	local currentSize = bar.Size
	local targetSize = UDim2.new(widthScale, 0, currentSize.Y.Scale, currentSize.Y.Offset)

	if activeTween then
		activeTween:Cancel()
		activeTween = nil
	end

	if not animate or LikeGoalConfig.TweenSeconds <= 0 then
		bar.Size = targetSize
		return
	end

	activeTween = TweenService:Create(bar, TweenInfo.new(LikeGoalConfig.TweenSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = targetSize,
	})
	activeTween:Play()
end

local function renderLikes(likes: number, animate: boolean)
	local currentWidgets = getWidgets()
	if not currentWidgets then
		warn("[LikeGoalService] Missing like board widgets at Workspace.Lobby.Likeboard.GUIFACE.CODEPROGRESS.Frame")
		return
	end

	likes = sanitizeInteger(likes)
	local goal = getGoalForLikes(likes)
	local progress = if goal > 0 then math.clamp(likes / goal, 0, 1) else 0
	local fullWidth = tonumber(LikeGoalConfig.FullBarWidthScale) or 0.757
	local widthScale = math.clamp(progress * fullWidth, 0, fullWidth)

	currentWidgets.goalLabel.Text = formatGoalText(currentWidgets.goalTextTemplate, goal)
	currentWidgets.goalProgress.Text = ("%s/%s"):format(formatLikeCount(likes), formatLikeCount(goal))
	setBarWidth(currentWidgets.bar, widthScale, animate)
end

local LikeGoalService = {}

function LikeGoalService:OnStart()
	if started then
		return
	end
	started = true

	renderLikes(0, false)

	task.spawn(function()
		while true do
			local likes, err = LikeService.FetchLikes()
			if likes ~= nil then
				renderLikes(likes, true)
			else
				warn(("[LikeGoalService] Failed to refresh likes: %s"):format(tostring(err)))
			end

			task.wait(math.max(1, tonumber(LikeGoalConfig.RefreshSeconds) or 3600))
		end
	end)
end

return LikeGoalService
