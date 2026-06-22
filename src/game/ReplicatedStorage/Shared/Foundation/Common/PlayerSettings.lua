local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SettingsConfig = require(ReplicatedStorage.Shared.Config.SettingsConfig)
local Signal = require(script.Parent.Signal)

local PlayerSettings = {}

PlayerSettings.Changed = Signal.new()

local currentSettings = SettingsConfig.NormalizeSettings(nil)

local function copySettings(settings: { [string]: any }): { [string]: any }
	local copy = {}
	for key, value in pairs(settings) do
		copy[key] = value
	end
	return copy
end

function PlayerSettings:Get(id: string): any
	local value = currentSettings[id]
	if value == nil then
		return SettingsConfig.Defaults[id]
	end
	return value
end

function PlayerSettings:GetAll(): { [string]: any }
	return copySettings(currentSettings)
end

function PlayerSettings:GetNumberScale(id: string): number
	local value = tonumber(self:Get(id))
	if not value or value ~= value then
		value = tonumber(SettingsConfig.Defaults[id]) or 100
	end
	return math.clamp(value / 100, 0, 1)
end

function PlayerSettings:ApplySnapshot(settings: any)
	local normalized = SettingsConfig.NormalizeSettings(settings)
	local changedIds = {}

	for id, value in pairs(normalized) do
		if currentSettings[id] ~= value then
			currentSettings[id] = value
			table.insert(changedIds, id)
		end
	end

	for _, id in ipairs(changedIds) do
		PlayerSettings.Changed:Fire(id, currentSettings[id])
	end
end

function PlayerSettings:ApplyLocal(id: string, value: any): any
	local normalized = SettingsConfig.NormalizeValue(id, value)
	if normalized == nil then
		return nil
	end

	if currentSettings[id] ~= normalized then
		currentSettings[id] = normalized
		PlayerSettings.Changed:Fire(id, normalized)
	end

	return normalized
end

function PlayerSettings:GetShiftLockKeyCode(): Enum.KeyCode
	local keyName = self:Get("shiftLockKey")
	local keyCode = nil
	if typeof(keyName) == "string" then
		local ok, result = pcall(function()
			return Enum.KeyCode[keyName]
		end)
		if ok and typeof(result) == "EnumItem" then
			keyCode = result
		end
	end
	return keyCode or Enum.KeyCode.LeftControl
end

return PlayerSettings
