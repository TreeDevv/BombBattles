local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local PlayerHitFlash = {}

local HIGHLIGHT_NAME = "BombHitFlash"
local COLOR = Color3.fromRGB(255, 55, 55)
local FILL_TRANSPARENCY = 0.28
local OUTLINE_TRANSPARENCY = 0.05
local FADE_SECONDS = 0.26
local CLEANUP_SECONDS = 0.6

local function getPlayerByUserId(userId: any): Player?
	if typeof(userId) ~= "number" then
		return nil
	end

	return Players:GetPlayerByUserId(userId)
end

function PlayerHitFlash.PlayForPlayer(player: Player)
	local character = player.Character
	if not character then
		return
	end

	local existing = character:FindFirstChild(HIGHLIGHT_NAME)
	if existing then
		existing:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = HIGHLIGHT_NAME
	highlight.Adornee = character
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = COLOR
	highlight.OutlineColor = COLOR
	highlight.FillTransparency = FILL_TRANSPARENCY
	highlight.OutlineTransparency = OUTLINE_TRANSPARENCY
	highlight.Parent = character

	local tween = TweenService:Create(highlight, TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	})
	tween.Completed:Connect(function()
		if highlight.Parent then
			highlight:Destroy()
		end
	end)
	tween:Play()

	task.delay(CLEANUP_SECONDS, function()
		if highlight.Parent then
			highlight:Destroy()
		end
	end)
end

function PlayerHitFlash.PlayForUserIds(userIds)
	if typeof(userIds) ~= "table" then
		return
	end

	for _, userId in ipairs(userIds) do
		local player = getPlayerByUserId(userId)
		if player then
			PlayerHitFlash.PlayForPlayer(player)
		end
	end
end

return table.freeze(PlayerHitFlash)
