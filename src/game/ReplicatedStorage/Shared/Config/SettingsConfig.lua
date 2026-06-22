local SettingsConfig = {}

SettingsConfig.RemotesFolderName = "Remotes"
SettingsConfig.UpdateRemoteName = "UpdatePlayerSetting"

SettingsConfig.Quality = table.freeze({
	Full = "Full",
	Reduced = "Reduced",
	Minimal = "Minimal",
	Off = "Off",
})

SettingsConfig.Defaults = table.freeze({
	shiftLockKey = "LeftControl",
	cameraShakeScale = 100,
	cameraMotionScale = 100,
	dynamicFovScale = 100,
	screenEffectsScale = 100,
	explosionVfxQuality = SettingsConfig.Quality.Full,
	debrisVfxQuality = SettingsConfig.Quality.Full,
	enemyHighlightsEnabled = true,
	enemyHighlightColorHex = "",
	masterVolume = 100,
	musicVolume = 100,
	sfxVolume = 100,
	uiVolume = 100,
	uiAnimationScale = 100,
})

SettingsConfig.Sections = table.freeze({
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
		},
	},
	{
		id = "GameplayFeel",
		label = "Gameplay Feel",
		settings = {
			{
				id = "cameraShakeScale",
				label = "Camera Shake",
				description = "Controls landing, throw, and explosion shake strength.",
				kind = "slider",
				default = SettingsConfig.Defaults.cameraShakeScale,
				min = 0,
				max = 100,
				step = 5,
			},
			{
				id = "cameraMotionScale",
				label = "Camera Motion",
				description = "Controls movement bob, roll, drift, and fall lag.",
				kind = "slider",
				default = SettingsConfig.Defaults.cameraMotionScale,
				min = 0,
				max = 100,
				step = 5,
			},
			{
				id = "dynamicFovScale",
				label = "Dynamic FOV",
				description = "Controls speed and action field-of-view changes.",
				kind = "slider",
				default = SettingsConfig.Defaults.dynamicFovScale,
				min = 0,
				max = 100,
				step = 5,
			},
		},
	},
	{
		id = "Visuals",
		label = "Visuals",
		settings = {
			{
				id = "screenEffectsScale",
				label = "Screen Effects",
				description = "Controls full-screen flashes, blur, and status effects.",
				kind = "slider",
				default = SettingsConfig.Defaults.screenEffectsScale,
				min = 0,
				max = 100,
				step = 5,
			},
			{
				id = "explosionVfxQuality",
				label = "Explosion VFX",
				description = "Reduces non-critical explosion visuals for performance.",
				kind = "slider",
				default = SettingsConfig.Defaults.explosionVfxQuality,
				min = 0,
				max = 100,
				step = 50,
			},
			{
				id = "debrisVfxQuality",
				label = "Debris VFX",
				description = "Reduces local terrain debris visuals for performance.",
				kind = "slider",
				default = SettingsConfig.Defaults.debrisVfxQuality,
				min = 0,
				max = 100,
				step = 50,
			},
			{
				id = "enemyHighlightsEnabled",
				label = "Enemy Highlights",
				description = "Shows active enemy players through combat clutter.",
				kind = "toggle",
				default = SettingsConfig.Defaults.enemyHighlightsEnabled,
			},
			{
				id = "enemyHighlightColorHex",
				label = "Enemy Highlight Color",
				description = "Override enemy highlight color for readability.",
				kind = "color",
				default = SettingsConfig.Defaults.enemyHighlightColorHex,
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
			{
				id = "uiVolume",
				label = "UI Volume",
				description = "Controls menu and button sounds.",
				kind = "slider",
				default = SettingsConfig.Defaults.uiVolume,
				min = 0,
				max = 100,
				step = 5,
			},
		},
	},
	{
		id = "Interface",
		label = "Interface",
		settings = {
			{
				id = "uiAnimationScale",
				label = "UI Animations",
				description = "Controls menu and button animation intensity.",
				kind = "slider",
				default = SettingsConfig.Defaults.uiAnimationScale,
				min = 0,
				max = 100,
				step = 5,
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

function SettingsConfig.NormalizeQualityFromSlider(value: any): string
	local numberValue = tonumber(value)
	if typeof(value) == "string" then
		if value == SettingsConfig.Quality.Full
			or value == SettingsConfig.Quality.Reduced
			or value == SettingsConfig.Quality.Minimal
			or value == SettingsConfig.Quality.Off
		then
			return value
		end
	end
	if not numberValue then
		return SettingsConfig.Quality.Full
	end
	if numberValue <= 0 then
		return SettingsConfig.Quality.Off
	elseif numberValue <= 35 then
		return SettingsConfig.Quality.Minimal
	elseif numberValue <= 75 then
		return SettingsConfig.Quality.Reduced
	end
	return SettingsConfig.Quality.Full
end

function SettingsConfig.QualityToSlider(value: any): number
	if value == SettingsConfig.Quality.Off then
		return 0
	elseif value == SettingsConfig.Quality.Minimal then
		return 35
	elseif value == SettingsConfig.Quality.Reduced then
		return 65
	end
	return 100
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

	if definition.kind == "toggle" then
		return value == true
	elseif definition.kind == "keybind" then
		return if typeof(value) == "string" and keyCodeNames[value] then value else definition.default
	elseif definition.kind == "color" then
		return SettingsConfig.NormalizeColorHex(value)
	elseif id == "explosionVfxQuality" or id == "debrisVfxQuality" then
		return SettingsConfig.NormalizeQualityFromSlider(value)
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
