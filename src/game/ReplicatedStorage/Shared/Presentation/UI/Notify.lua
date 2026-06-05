local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local REMOTES_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "Notify"
local MIN_DURATION = 0.5
local MAX_DURATION = 12
local RENDERER_WAIT_SECONDS = 6

local COLOR_NAMES = {
	Blue = Color3.fromRGB(75, 160, 255),
	Gold = Color3.fromRGB(255, 196, 64),
	Gray = Color3.fromRGB(170, 180, 190),
	Green = Color3.fromRGB(80, 220, 120),
	Neutral = Color3.fromRGB(235, 240, 245),
	Orange = Color3.fromRGB(255, 150, 70),
	Purple = Color3.fromRGB(170, 115, 255),
	Red = Color3.fromRGB(255, 90, 90),
	White = Color3.fromRGB(255, 255, 255),
	Yellow = Color3.fromRGB(255, 230, 90),
}

local Notify = {}

Notify.Defaults = {
	title = "Notice",
	duration = 4,
}

local clientRenderer = nil :: ((payload: { [string]: any }) -> boolean?)?
local pendingPayloads = {} :: { { [string]: any } }
local rendererSerial = 0

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

	local safeRemotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME)
	return safeRemotes:WaitForChild(REMOTE_NAME) :: RemoteEvent
end

local function normalizeDuration(value: any): number
	local duration = tonumber(value) or Notify.Defaults.duration
	return math.clamp(duration, MIN_DURATION, MAX_DURATION)
end

local function normalizeColor(value: any): Color3?
	if typeof(value) == "Color3" then
		return value
	end

	if typeof(value) ~= "string" then
		return nil
	end

	local key = value:gsub("^%l", string.upper)
	return COLOR_NAMES[key]
end

local function normalizePayload(text: any, opts)
	opts = opts or {}
	return {
		title = tostring(opts.title or Notify.Defaults.title),
		text = tostring(text),
		duration = normalizeDuration(opts.duration),
		color = normalizeColor(opts.color),
	}
end

local function showCorePayload(payload)
	return pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = payload.title,
			Text = payload.text,
			Duration = payload.duration,
		})
	end)
end

local function flushPendingPayloads()
	if not clientRenderer then
		return
	end

	local pending = pendingPayloads
	pendingPayloads = {}
	for _, payload in ipairs(pending) do
		local ok, handled = pcall(clientRenderer, payload)
		if not ok or handled == false then
			showCorePayload(payload)
		end
	end
end

local function dispatchClientPayload(payload)
	if clientRenderer then
		local ok, handled = pcall(clientRenderer, payload)
		if ok and handled ~= false then
			return true
		end

		if not ok then
			warn("[Notify] Custom notification renderer failed: " .. tostring(handled))
		end
		return showCorePayload(payload)
	end

	table.insert(pendingPayloads, payload)
	rendererSerial += 1
	local serial = rendererSerial
	task.delay(RENDERER_WAIT_SECONDS, function()
		if clientRenderer or serial ~= rendererSerial then
			return
		end

		local pending = pendingPayloads
		pendingPayloads = {}
		for _, pendingPayload in ipairs(pending) do
			showCorePayload(pendingPayload)
		end
	end)
	return true
end

function Notify.ShowCore(payloadOrText, opts)
	local payload = if typeof(payloadOrText) == "table" then payloadOrText else normalizePayload(payloadOrText, opts)
	return showCorePayload(payload)
end

function Notify.SetRenderer(renderer)
	if RunService:IsClient() and type(renderer) == "function" then
		clientRenderer = renderer
		flushPendingPayloads()
	end
end

function Notify.ClearRenderer(renderer)
	if clientRenderer == renderer then
		clientRenderer = nil
	end
end

function Notify.Show(text, opts)
	local payload = normalizePayload(text, opts)
	if RunService:IsClient() then
		return dispatchClientPayload(payload)
	end

	return showCorePayload(payload)
end

function Notify.Send(target, text, opts)
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

return Notify
