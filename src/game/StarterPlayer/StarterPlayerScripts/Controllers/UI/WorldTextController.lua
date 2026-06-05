local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EventTextPresenter = require(ReplicatedStorage.Shared.Effects.EventTextPresenter)
local WorldTextConstants = require(ReplicatedStorage.Shared.Effects.WorldTextConstants)

local WorldTextController = {}

WorldTextController._connections = {} :: { RBXScriptConnection }
WorldTextController._effectsFolder = nil :: Folder?
WorldTextController._remoteBindSerial = 0

local function getEffectsFolder(): Folder
	local folder = WorldTextController._effectsFolder
	if folder and folder.Parent then
		return folder
	end

	folder = Instance.new("Folder")
	folder.Name = "_LocalWorldTextEffects"
	folder.Parent = workspace
	WorldTextController._effectsFolder = folder
	return folder
end

function WorldTextController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function WorldTextController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	self._connections = {}
	self._remoteBindSerial += 1

	if self._effectsFolder and self._effectsFolder.Parent then
		self._effectsFolder:Destroy()
	end
	self._effectsFolder = nil
end

function WorldTextController:_bindRemote()
	self._remoteBindSerial += 1
	local serial = self._remoteBindSerial

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild(WorldTextConstants.REMOTES_FOLDER_NAME, 10)
		if serial ~= self._remoteBindSerial or not remotes then
			return
		end

		local remote = remotes:WaitForChild(WorldTextConstants.REMOTE_NAME, 10)
		if serial ~= self._remoteBindSerial or not (remote and remote:IsA("RemoteEvent")) then
			return
		end

		self:_trackConnection(remote.OnClientEvent:Connect(function(payload)
			EventTextPresenter.PlayLiveEvent(getEffectsFolder(), payload)
		end))
	end)
end

function WorldTextController:OnStart()
	self:_disconnectAll()
	self:_bindRemote()
end

return WorldTextController
