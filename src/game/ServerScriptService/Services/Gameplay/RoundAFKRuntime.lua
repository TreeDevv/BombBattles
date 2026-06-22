local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundAFKRuntime = {}

local AFK_ATTR = "AFK"
local AFK_SOURCE_ATTR = "AFKSource"
local AFK_STARTED_AT_ATTR = "AFKStartedAt"
local MARKER_NAME = "AFK"

local missingTemplateWarned = false

function RoundAFKRuntime.IsPlayerAFK(player: Player): boolean
	return player:GetAttribute(AFK_ATTR) == true
end

function RoundAFKRuntime.NormalizeSource(value: any): string
	return if value == "Auto" then "Auto" else "Manual"
end

function RoundAFKRuntime.GetSource(player: Player): any
	return player:GetAttribute(AFK_SOURCE_ATTR)
end

function RoundAFKRuntime.ResetPlayer(player: Player)
	player:SetAttribute(AFK_ATTR, false)
	player:SetAttribute(AFK_SOURCE_ATTR, nil)
	player:SetAttribute(AFK_STARTED_AT_ATTR, nil)
end

function RoundAFKRuntime.SetPlayerAFK(player: Player, afk: boolean, source: string)
	player:SetAttribute(AFK_ATTR, afk)
	player:SetAttribute(AFK_SOURCE_ATTR, if afk then RoundAFKRuntime.NormalizeSource(source) else nil)
	player:SetAttribute(AFK_STARTED_AT_ATTR, if afk then workspace:GetServerTimeNow() else nil)
end

function RoundAFKRuntime.GetTemplate(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local ui = assets and assets:FindFirstChild("UI")
	local template = ui and ui:FindFirstChild(MARKER_NAME)
	if template then
		return template
	end

	if not missingTemplateWarned then
		missingTemplateWarned = true
		warn("[RoundAFKRuntime] Missing ReplicatedStorage.Assets.UI.AFK template")
	end
	return nil
end

function RoundAFKRuntime.RemoveMarker(player: Player)
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	for _, child in ipairs(rootPart:GetChildren()) do
		if child.Name == MARKER_NAME then
			child:Destroy()
		end
	end
end

function RoundAFKRuntime.SyncMarker(player: Player)
	RoundAFKRuntime.RemoveMarker(player)

	if not RoundAFKRuntime.IsPlayerAFK(player) then
		return
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local template = RoundAFKRuntime.GetTemplate()
	if not template then
		return
	end

	local marker = template:Clone()
	marker.Name = MARKER_NAME
	local billboardGui = marker:FindFirstChild("BillboardGui")
	local frame = billboardGui and billboardGui:FindFirstChild("Frame")
	local timerLabel = frame and frame:FindFirstChild("Timer")
	if timerLabel and timerLabel:IsA("TextLabel") then
		timerLabel.Text = "0:00"
	end
	marker.Parent = rootPart
end

return table.freeze(RoundAFKRuntime)
