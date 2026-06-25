local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local AudioCatalog = require(script.Parent.AudioCatalog)
local AudioSettings = require(script.Parent.AudioSettings)
local PlayerSettings = require(ReplicatedStorage.Shared.Common.PlayerSettings)

local SoundUtil = {}

local POSITIONAL_SOUND_ANCHOR_SIZE = Vector3.new(0.2, 0.2, 0.2)
local LOOP_FADE_OUT_SECONDS = 0.18

local function getByPath(root: Instance, path: { string }): Instance?
	local current: Instance? = root
	for _, name in ipairs(path) do
		if typeof(name) ~= "string" or name == "" or not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getSoundLibrary(): Instance?
	local library = getByPath(ReplicatedStorage, AudioCatalog.GetSoundFolderPath())
	return if library and library:IsA("Folder") then library else nil
end

local function resolveBaseSound(soundOrName): Sound?
	if typeof(soundOrName) == "Instance" and soundOrName:IsA("Sound") then
		return soundOrName
	end

	local soundName = AudioCatalog.ResolveName(soundOrName)
	if soundName == "" then
		return nil
	end

	local library = getSoundLibrary()
	local directLibrarySound = library and library:FindFirstChild(soundName)
	if directLibrarySound and directLibrarySound:IsA("Sound") then
		return directLibrarySound
	end

	local nestedLibrarySound = library and library:FindFirstChild(soundName, true)
	if nestedLibrarySound and nestedLibrarySound:IsA("Sound") then
		return nestedLibrarySound
	end

	local direct = SoundService:FindFirstChild(soundName)
	if direct and direct:IsA("Sound") then
		return direct
	end

	local nested = SoundService:FindFirstChild(soundName, true)
	if nested and nested:IsA("Sound") then
		return nested
	end

	local workspaceSounds = Workspace:FindFirstChild("Sounds")
	local workspaceSound = workspaceSounds and workspaceSounds:FindFirstChild(soundName, true)
	if workspaceSound and workspaceSound:IsA("Sound") then
		return workspaceSound
	end

	return nil
end

local function readSoundDuration(sound: Sound): number
	local timeLength = tonumber(sound.TimeLength) or 0
	if timeLength == timeLength and timeLength > 0 then
		return timeLength / math.max(tonumber(sound.PlaybackSpeed) or 1, 0.01)
	end
	return 0
end

local function applySoundGroup(sound: Sound, baseSound: Sound, groupKind: string?)
	local requestedGroupKind = groupKind or baseSound:GetAttribute("SoundGroupKind")
	if requestedGroupKind ~= nil then
		sound.SoundGroup = AudioSettings.GetGroup(requestedGroupKind)
	elseif baseSound.SoundGroup then
		sound.SoundGroup = baseSound.SoundGroup
	else
		sound.SoundGroup = AudioSettings.GetGroup("SFX")
	end
end

local function cleanupAfterPlayback(sound: Sound, parentToDestroy: Instance?, minimumLifetime: number?)
	local endedConnection: RBXScriptConnection? = nil
	endedConnection = sound.Ended:Connect(function()
		if endedConnection then
			endedConnection:Disconnect()
			endedConnection = nil
		end

		if parentToDestroy and parentToDestroy.Parent then
			parentToDestroy:Destroy()
		elseif sound.Parent then
			sound:Destroy()
		end
	end)

	local duration = readSoundDuration(sound)
	local lifetime = math.max(tonumber(minimumLifetime) or 0, 1, if duration > 0 then duration + 0.25 else 0)
	task.delay(lifetime, function()
		if endedConnection then
			endedConnection:Disconnect()
			endedConnection = nil
		end

		if parentToDestroy and parentToDestroy.Parent then
			parentToDestroy:Destroy()
		elseif sound.Parent then
			sound:Destroy()
		end
	end)
end

local function prepareClone(soundOrName, groupKind: string?, looped: boolean?): Sound?
	local baseSound = resolveBaseSound(soundOrName)
	if not baseSound then
		return nil
	end

	AudioSettings.Apply(PlayerSettings:GetAll())
	local clone = baseSound:Clone()
	clone.Looped = looped == true
	clone.TimePosition = 0
	applySoundGroup(clone, baseSound, groupKind)
	return clone
end

local function createAnchor(position: Vector3, name: string): Part
	local anchor = Instance.new("Part")
	anchor.Name = name
	anchor.Size = POSITIONAL_SOUND_ANCHOR_SIZE
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.CFrame = CFrame.new(position)
	return anchor
end

local function getCharacterRoot(player: Player?): BasePart?
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function getCuePosition(cue, payload: any): Vector3?
	if typeof(payload) ~= "table" then
		return nil
	end

	local data = if typeof(payload.payload) == "table" then payload.payload else payload

	if typeof(data.position) == "Vector3" then
		return data.position
	elseif typeof(data.origin) == "Vector3" then
		return data.origin
	elseif typeof(data.targetPosition) == "Vector3" then
		return data.targetPosition
	elseif typeof(data.cframe) == "CFrame" then
		return data.cframe.Position
	end

	if typeof(cue) == "table" and typeof(cue.positionKey) == "string" then
		local value = data[cue.positionKey]
		if typeof(value) == "Vector3" then
			return value
		end
	end

	return nil
end

local function getCueLoopDuration(cue, payload: any): number?
	if typeof(cue) ~= "table" or cue.loop ~= true then
		return nil
	end

	if typeof(payload) == "table" then
		local data = if typeof(payload.payload) == "table" then payload.payload else payload
		if typeof(cue.durationKey) == "string" and typeof(data[cue.durationKey]) == "number" then
			return math.max(data[cue.durationKey], 0)
		end
		if typeof(data.activeEndsAt) == "number" then
			local startedAt = if typeof(data.startedAt) == "number" then data.startedAt else Workspace:GetServerTimeNow()
			return math.max(data.activeEndsAt - startedAt, 0)
		end
	end

	return 5
end

function SoundUtil.Resolve(soundOrName): Sound?
	return resolveBaseSound(soundOrName)
end

function SoundUtil.Play(soundOrName, parent: Instance?, groupKind: string?): Sound?
	local clone = prepareClone(soundOrName, groupKind, false)
	if not clone then
		return nil
	end

	clone.Parent = parent or SoundService
	cleanupAfterPlayback(clone, nil)
	clone:Play()
	return clone
end

function SoundUtil.PlayAtPosition(soundOrName, position: Vector3, parent: Instance?, groupKind: string?): Sound?
	local clone = prepareClone(soundOrName, groupKind, false)
	if not clone then
		return nil
	end

	local anchor = createAnchor(position, "PositionalSound")
	anchor.Parent = parent or Workspace
	clone.Parent = anchor
	cleanupAfterPlayback(clone, anchor)
	clone:Play()
	return clone
end

function SoundUtil.PlayLoop(soundOrName, parent: Instance?, groupKind: string?, lifetimeSeconds: number?): Sound?
	local clone = prepareClone(soundOrName, groupKind, true)
	if not clone then
		return nil
	end

	clone.Parent = parent or SoundService
	clone:Play()

	if typeof(lifetimeSeconds) == "number" and lifetimeSeconds > 0 then
		task.delay(lifetimeSeconds, function()
			SoundUtil.Stop(clone)
		end)
	end

	return clone
end

function SoundUtil.PlayLoopAtPosition(
	soundOrName,
	position: Vector3,
	parent: Instance?,
	groupKind: string?,
	lifetimeSeconds: number?
): Sound?
	local clone = prepareClone(soundOrName, groupKind, true)
	if not clone then
		return nil
	end

	local anchor = createAnchor(position, "PositionalLoopSound")
	anchor.Parent = parent or Workspace
	clone.Parent = anchor
	clone:Play()

	if typeof(lifetimeSeconds) == "number" and lifetimeSeconds > 0 then
		task.delay(lifetimeSeconds, function()
			SoundUtil.Stop(clone, anchor)
		end)
	end

	return clone
end

function SoundUtil.Stop(sound: Sound?, parentToDestroy: Instance?)
	if not sound then
		if parentToDestroy and parentToDestroy.Parent then
			parentToDestroy:Destroy()
		end
		return
	end

	local destroyParent = parentToDestroy
	if sound.Parent and sound.IsPlaying and sound.Volume > 0 then
		local tween = TweenService:Create(sound, TweenInfo.new(LOOP_FADE_OUT_SECONDS), { Volume = 0 })
		tween.Completed:Once(function()
			if destroyParent and destroyParent.Parent then
				destroyParent:Destroy()
			elseif sound.Parent then
				sound:Destroy()
			end
		end)
		tween:Play()
	else
		if destroyParent and destroyParent.Parent then
			destroyParent:Destroy()
		elseif sound.Parent then
			sound:Destroy()
		end
	end
end

function SoundUtil.PlayAbilityEffect(effectName: string, payload: any, localPlayer: Player?): Sound?
	local abilityId = if typeof(payload) == "table" then payload.abilityId else nil
	local cue = AudioCatalog.GetAbilityEventCue(effectName, abilityId)
	if typeof(cue) ~= "table" then
		return nil
	end

	local soundName = cue.soundName
	if typeof(soundName) ~= "string" or soundName == "" then
		return nil
	end

	local mode = if typeof(cue.mode) == "string" then cue.mode else "Local"
	local duration = getCueLoopDuration(cue, payload)
	local groupKind = if typeof(cue.groupKind) == "string" then cue.groupKind else "SFX"

	if mode == "Position" then
		local position = getCuePosition(cue, payload)
		if not position then
			return nil
		end
		if cue.loop == true then
			return SoundUtil.PlayLoopAtPosition(soundName, position, Workspace, groupKind, duration)
		end
		return SoundUtil.PlayAtPosition(soundName, position, Workspace, groupKind)
	elseif mode == "LocalOrCharacter" then
		local root = getCharacterRoot(localPlayer)
		if cue.loop == true then
			return SoundUtil.PlayLoop(soundName, root, groupKind, duration)
		end
		return SoundUtil.Play(soundName, root, groupKind)
	end

	if cue.loop == true then
		return SoundUtil.PlayLoop(soundName, nil, groupKind, duration)
	end
	return SoundUtil.Play(soundName, nil, groupKind)
end

return SoundUtil
