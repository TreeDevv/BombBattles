local SettingsConfig = {}

SettingsConfig.RemotesFolderName = "Remotes"
SettingsConfig.UpdateRemoteName = "UpdatePlayerSetting"

SettingsConfig.Defaults = table.freeze({
	explosionDebrisEnabled = true,
	enemyOutlineColorHex = "FF4E4E",
	friendlyOutlineColorHex = "48ABFF",
	masterVolume = 100,
	musicVolume = 100,
	sfxVolume = 100,
	shiftLockKey = "LeftControl",
	offensiveAbilityKey = "E",
	defensiveAbilityKey = "Q",
	emoteKey = "B",
})

SettingsConfig.Sections = table.freeze({
	{
		id = "Visuals",
		label = "Visuals",
		settings = {
			{
				id = "explosionDebrisEnabled",
				label = "Explosion Debris",
				description = "Shows terrain debris chunks from explosions.",
				kind = "toggle",
				default = SettingsConfig.Defaults.explosionDebrisEnabled,
			},
			{
				id = "enemyOutlineColorHex",
				label = "Enemy Outline Color",
				description = "Controls enemy player outline color.",
				kind = "color",
				default = SettingsConfig.Defaults.enemyOutlineColorHex,
			},
			{
				id = "friendlyOutlineColorHex",
				label = "Friendly Outline Color",
				description = "Controls friendly player outline color.",
				kind = "color",
				default = SettingsConfig.Defaults.friendlyOutlineColorHex,
			},
		},
	},
	{
		id = "Audio",
		label = "Audio",
		settings = {
			{
				id = "masterVolume",
				label = "Master Volume",
				description = "Controls all game audio.",
				kind = "slider",
				default = SettingsConfig.Defaults.masterVolume,
				min = 0,
				max = 100,
				step = 5,
			},
			{
				id = "musicVolume",
				label = "Music Volume",
				description = "Controls music volume.",
				kind = "slider",
				default = SettingsConfig.Defaults.musicVolume,
				min = 0,
				max = 100,
				step = 5,
			},
			{
				id = "sfxVolume",
				label = "SFX Volume",
				description = "Controls gameplay sound effects.",
				kind = "slider",
				default = SettingsConfig.Defaults.sfxVolume,
				min = 0,
				max = 100,
				step = 5,
			},
		},
	},
	{
		id = "Controls",
		label = "Controls",
		settings = {
			{
				id = "shiftLockKey",
				label = "Shift Lock",
				description = "Change the key used to toggle camera lock.",
				kind = "keybind",
				default = SettingsConfig.Defaults.shiftLockKey,
			},
			{
				id = "offensiveAbilityKey",
				label = "Offensive Ability",
				description = "Change the key used to activate your offensive ability.",
				kind = "keybind",
				default = SettingsConfig.Defaults.offensiveAbilityKey,
			},
			{
				id = "defensiveAbilityKey",
				label = "Defensive Ability",
				description = "Change the key used to activate your defensive ability.",
				kind = "keybind",
				default = SettingsConfig.Defaults.defensiveAbilityKey,
			},
			{
				id = "emoteKey",
				label = "Emote",
				description = "Change the key used to open the emote wheel.",
				kind = "keybind",
				default = SettingsConfig.Defaults.emoteKey,
			},
		},
	},
})

local definitionsById = {}
for _, section in ipairs(SettingsConfig.Sections) do
	for _, definition in ipairs(section.settings) do
		definitionsById[definition.id] = definition
	end
end
SettingsConfig.DefinitionsById = table.freeze(definitionsById)

local keyCodeNames = {}
for _, keyCode in ipairs(Enum.KeyCode:GetEnumItems()) do
	keyCodeNames[keyCode.Name] = true
end

local function cloneDefaults()
	local defaults = {}
	for key, value in pairs(SettingsConfig.Defaults) do
		defaults[key] = value
	end
	return defaults
end

local function normalizeNumber(value: any, definition): number
	local numberValue = tonumber(value) or tonumber(definition.default) or 0
	if numberValue ~= numberValue then
		numberValue = tonumber(definition.default) or 0
	end

	local minValue = tonumber(definition.min) or 0
	local maxValue = tonumber(definition.max) or 100
	local step = math.max(tonumber(definition.step) or 1, 0.001)
	numberValue = math.clamp(numberValue, minValue, maxValue)
	numberValue = math.floor(((numberValue - minValue) / step) + 0.5) * step + minValue
	return math.clamp(math.floor(numberValue + 0.5), minValue, maxValue)
end

function SettingsConfig.NormalizeColorHex(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end

	local hex = value:gsub("#", "")
	if hex == "" then
		return ""
	end
	if #hex ~= 6 or not hex:match("^[0-9a-fA-F]+$") then
		return ""
	end
	return string.upper(hex)
end

function SettingsConfig.Color3ToHex(color: Color3?): string
	if typeof(color) ~= "Color3" then
		return ""
	end
	return string.upper(color:ToHex())
end

function SettingsConfig.HexToColor3(hex: any): Color3?
	hex = SettingsConfig.NormalizeColorHex(hex)
	if hex == "" then
		return nil
	end

	local ok, color = pcall(function()
		return Color3.fromHex(hex)
	end)
	return if ok then color else nil
end

function SettingsConfig.NormalizeValue(id: string, value: any): any
	local definition = SettingsConfig.DefinitionsById[id]
	if not definition then
		return nil
	end
	if value == nil then
		return definition.default
	end

	if definition.kind == "toggle" then
		return value == true
	elseif definition.kind == "keybind" then
		return if typeof(value) == "string" and keyCodeNames[value] then value else definition.default
	elseif definition.kind == "color" then
		local normalized = SettingsConfig.NormalizeColorHex(value)
		return if normalized ~= "" then normalized else definition.default
	elseif definition.kind == "slider" then
		return normalizeNumber(value, definition)
	end

	return value
end

function SettingsConfig.NormalizeSettings(settings: any): { [string]: any }
	local result = cloneDefaults()
	if typeof(settings) ~= "table" then
		return result
	end

	for id in pairs(SettingsConfig.Defaults) do
		local normalized = SettingsConfig.NormalizeValue(id, settings[id])
		if normalized ~= nil then
			result[id] = normalized
		end
	end
	return result
end

return table.freeze(SettingsConfig)
