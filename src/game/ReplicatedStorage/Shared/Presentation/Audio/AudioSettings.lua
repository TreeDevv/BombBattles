local SoundService = game:GetService("SoundService")

local AudioSettings = {}

AudioSettings.SoundGroups = table.freeze({
	Master = "BombBattlesMaster",
	Music = "BombBattlesMusic",
	SFX = "BombBattlesSFX",
	UI = "BombBattlesUI",
})

local function ensureSoundGroup(name: string, parent: Instance?): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Parent = parent or SoundService
	return group
end

function AudioSettings.EnsureSoundGroups()
	local master = ensureSoundGroup(AudioSettings.SoundGroups.Master, SoundService)
	local music = ensureSoundGroup(AudioSettings.SoundGroups.Music, SoundService)
	local sfx = ensureSoundGroup(AudioSettings.SoundGroups.SFX, SoundService)
	local ui = ensureSoundGroup(AudioSettings.SoundGroups.UI, SoundService)
	return master, music, sfx, ui
end

local function getVolume(percent: any): number
	local value = tonumber(percent) or 100
	return math.clamp(value / 100, 0, 1)
end

function AudioSettings.Apply(settings: { [string]: any })
	local master, music, sfx, ui = AudioSettings.EnsureSoundGroups()
	local masterVolume = getVolume(settings.masterVolume)
	master.Volume = masterVolume
	music.Volume = masterVolume * getVolume(settings.musicVolume)
	sfx.Volume = masterVolume * getVolume(settings.sfxVolume)
	ui.Volume = masterVolume * getVolume(settings.uiVolume)
end

function AudioSettings.GetGroup(kind: string?): SoundGroup
	local master, music, sfx, ui = AudioSettings.EnsureSoundGroups()
	if kind == "Music" then
		return music
	elseif kind == "UI" then
		return ui
	elseif kind == "Master" then
		return master
	end
	return sfx
end

return table.freeze(AudioSettings)
