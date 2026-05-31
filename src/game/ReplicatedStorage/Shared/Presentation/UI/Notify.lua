local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local REMOTES_FOLDER_NAME = "Remotes"
local REMOTE_NAME = "Notify"

local Notify = {}

Notify.Defaults = {
	title = "Notice",
	duration = 4,
}

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

local function normalizePayload(text: any, opts)
	opts = opts or {}
	return {
		title = tostring(opts.title or Notify.Defaults.title),
		text = tostring(text),
		duration = tonumber(opts.duration) or Notify.Defaults.duration,
	}
end

function Notify.Show(text, opts)
	local payload = normalizePayload(text, opts)
	return pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = payload.title,
			Text = payload.text,
			Duration = payload.duration,
		})
	end)
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

if RunService:IsClient() then
	task.spawn(function()
		local remote = ensureRemote()
		remote.OnClientEvent:Connect(function(payload)
			Notify.Show(payload.text, payload)
		end)
	end)
end

return Notify
