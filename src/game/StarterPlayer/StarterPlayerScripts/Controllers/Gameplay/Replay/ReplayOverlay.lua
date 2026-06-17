local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

local HUD_NAME = "HUD"
local KILL_REPLAY_FRAME_NAME = "KillReplay"
local POTG_FRAME_NAME = "POTG"

local ReplayOverlay = {}

local warnedMessages = {} :: { [string]: boolean }

local function warnOnce(message: string)
	if warnedMessages[message] then
		return
	end

	warnedMessages[message] = true
	warn("[ReplayOverlay] " .. message)
end

local function findFrame(parent: Instance?, childName: string): Frame?
	local child = if parent then parent:FindFirstChild(childName) else nil
	return if child and child:IsA("Frame") then child else nil
end

local function findTextLabel(parent: Instance?, childName: string): TextLabel?
	local child = if parent then parent:FindFirstChild(childName) else nil
	return if child and child:IsA("TextLabel") then child else nil
end

local function getHud(): ScreenGui?
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		warnOnce("PlayerGui unavailable; replay topbar skipped")
		return nil
	end

	local hud = playerGui:FindFirstChild(HUD_NAME)
	if not (hud and hud:IsA("ScreenGui")) then
		warnOnce("HUD ScreenGui unavailable; replay topbar skipped")
		return nil
	end

	return hud
end

local function hideReplayTopbars(hud: ScreenGui)
	local killReplay = findFrame(hud, KILL_REPLAY_FRAME_NAME)
	if killReplay then
		killReplay.Visible = false
	end

	local potg = findFrame(hud, POTG_FRAME_NAME)
	if potg then
		potg.Visible = false
	end
end

local function getDisplayName(userId: any, getPlayerDisplayName): string
	if type(getPlayerDisplayName) == "function" then
		return getPlayerDisplayName(userId)
	end

	return tostring(userId)
end

local function getReplayTopbar(payload, hud: ScreenGui): (Frame?, TextLabel?, string?)
	if payload.type == "POTGReplay" then
		local frame = findFrame(hud, POTG_FRAME_NAME)
		local inner = findFrame(frame, "Inner")
		return frame, findTextLabel(inner, "ByPlayer"), "POTG"
	end

	if payload.type == "KillReplay" then
		local frame = findFrame(hud, KILL_REPLAY_FRAME_NAME)
		local inner = findFrame(frame, "Inner")
		return frame, findTextLabel(inner, "KilledBy"), "KillReplay"
	end

	return nil, nil, nil
end

function ReplayOverlay.Create(payload, options)
	options = options or {}
	if typeof(payload) ~= "table" then
		warnOnce("Invalid replay payload; replay topbar skipped")
		return nil
	end

	local hud = getHud()
	if not hud then
		return nil
	end

	hideReplayTopbars(hud)

	local frame, playerLabel, topbarName = getReplayTopbar(payload, hud)
	if not (frame and playerLabel and topbarName) then
		warnOnce(("Missing authored %s replay topbar or semantic label; replay topbar skipped"):format(tostring(payload.type)))
		return nil
	end

	if payload.type == "POTGReplay" then
		local displayName = if typeof(payload.playerDisplayName) == "string" and payload.playerDisplayName ~= ""
			then payload.playerDisplayName
			elseif typeof(payload.playerName) == "string" and payload.playerName ~= ""
			then payload.playerName
			else getDisplayName(payload.playerUserId, options.getPlayerDisplayName)
		playerLabel.Text = "BY " .. displayName
	else
		local displayName = if typeof(payload.killerDisplayName) == "string" and payload.killerDisplayName ~= ""
			then payload.killerDisplayName
			elseif typeof(payload.killerName) == "string" and payload.killerName ~= ""
			then payload.killerName
			else getDisplayName(payload.killerUserId, options.getPlayerDisplayName)
		playerLabel.Text = "KILLED BY " .. displayName
	end

	frame.Visible = true

	local handle = {
		_frame = frame,
		_hud = hud,
		_topbarName = topbarName,
	}

	function handle:Destroy()
		if self._hud and self._hud.Parent then
			hideReplayTopbars(self._hud)
			return
		end

		if self._frame and self._frame.Parent then
			self._frame.Visible = false
		end
	end

	return handle
end

return ReplayOverlay
