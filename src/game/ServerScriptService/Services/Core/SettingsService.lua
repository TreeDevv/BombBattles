local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SettingsConfig = require(ReplicatedStorage.Shared.Config.SettingsConfig)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)
local DataService = require(script.Parent:WaitForChild("DataService"))

local PLAYER_SETTINGS_KEY = Schema.PlayerSettings.key

local SettingsService = {}

local updateRemote: RemoteEvent? = nil

local function ensureRemote(): RemoteEvent
	if updateRemote and updateRemote.Parent then
		return updateRemote
	end

	updateRemote = RemoteUtil.EnsureRemoteEventInFolder(
		ReplicatedStorage,
		SettingsConfig.RemotesFolderName,
		SettingsConfig.UpdateRemoteName,
		true
	)
	return updateRemote
end

local function updatePlayerSetting(player: Player, id: string, value: any)
	if typeof(id) ~= "string" or SettingsConfig.DefinitionsById[id] == nil then
		return
	end

	local normalizedValue = SettingsConfig.NormalizeValue(id, value)
	if normalizedValue == nil then
		return
	end

	DataService:Set(player, PLAYER_SETTINGS_KEY, function(currentSettings)
		local nextSettings = SettingsConfig.NormalizeSettings(currentSettings)
		nextSettings[id] = normalizedValue
		return nextSettings
	end)
end

function SettingsService:OnStart()
	ensureRemote().OnServerEvent:Connect(updatePlayerSetting)
end

function SettingsService:OnPlayerAdded(player: Player)
	local settings = DataService:Get(player, PLAYER_SETTINGS_KEY)
	if settings == nil then
		return
	end

	local normalized = SettingsConfig.NormalizeSettings(settings)
	DataService:Set(player, PLAYER_SETTINGS_KEY, normalized)
end

return SettingsService
