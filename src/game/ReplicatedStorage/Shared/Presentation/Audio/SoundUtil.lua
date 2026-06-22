local SoundService = game:GetService("SoundService")

local AudioSettings = require(script.Parent.AudioSettings)
local PlayerSettings = require(game:GetService("ReplicatedStorage").Shared.Common.PlayerSettings)

local SoundUtil = {}

local function resolveBaseSound(soundOrName)
	if typeof(soundOrName) == "Instance" and soundOrName:IsA("Sound") then
		return soundOrName
	end

	if typeof(soundOrName) ~= "string" or soundOrName == "" then
		return nil
	end

	local direct = SoundService:FindFirstChild(soundOrName)
	if direct and direct:IsA("Sound") then
		return direct
	end

	local nested = SoundService:FindFirstChild(soundOrName, true)
	if nested and nested:IsA("Sound") then
		return nested
	end

	return nil
end

function SoundUtil.Play(soundOrName, parent: Instance?, groupKind: string?): Sound?
	local baseSound = resolveBaseSound(soundOrName)
	if not baseSound then
		return nil
	end

	AudioSettings.Apply(PlayerSettings:GetAll())
	local clone = baseSound:Clone()
	clone.Looped = false
	clone.TimePosition = 0
	local requestedGroupKind = groupKind or baseSound:GetAttribute("SoundGroupKind")
	if requestedGroupKind ~= nil then
		clone.SoundGroup = AudioSettings.GetGroup(requestedGroupKind)
	elseif baseSound.SoundGroup then
		clone.SoundGroup = baseSound.SoundGroup
	else
		clone.SoundGroup = AudioSettings.GetGroup("SFX")
	end
	clone.Parent = parent or SoundService

	local endedConnection: RBXScriptConnection? = nil
	endedConnection = clone.Ended:Connect(function()
		if endedConnection then
			endedConnection:Disconnect()
			endedConnection = nil
		end

		if clone.Parent then
			clone:Destroy()
		end
	end)

	clone:Play()

	task.delay(math.max(1, tonumber(clone.TimeLength) or 0, (tonumber(clone.TimeLength) or 0) + 0.25), function()
		if endedConnection then
			endedConnection:Disconnect()
			endedConnection = nil
		end

		if clone.Parent then
			clone:Destroy()
		end
	end)

	return clone
end

return SoundUtil
