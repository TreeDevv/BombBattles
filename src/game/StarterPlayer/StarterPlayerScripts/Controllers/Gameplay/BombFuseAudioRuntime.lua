local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local SoundUtil = require(ReplicatedStorage.Shared.Audio.SoundUtil)

local BombFuseAudioRuntime = {}

local TICK_SOUND_NAME = "BombTick"
local TICK_GROUP_KIND = "SFX"
local TICK_START_INTERVAL_SECONDS = 1
local TICK_END_INTERVAL_SECONDS = 0.18
local TICK_ACCELERATION_EXPONENT = 1.6

local function getRootPart(visual, instance: Instance?): BasePart?
	local rootPart = visual and visual.rootPart
	if rootPart and rootPart.Parent then
		return rootPart
	end

	local rootInstance = instance
	if not rootInstance and visual then
		rootInstance = visual.instance
	end
	return BombVisualUtil.GetRootPart(rootInstance)
end

local function disconnectMonitor(visual)
	local connection = visual and visual.fuseTickConnection
	if connection then
		connection:Disconnect()
		visual.fuseTickConnection = nil
	end
end

local function playTick(visual, rootPart: BasePart)
	local sound = SoundUtil.Play(TICK_SOUND_NAME, rootPart, TICK_GROUP_KIND)
	if sound then
		visual.fuseTickLastSound = sound
		visual.fuseTickRoot = rootPart
	end
end

local function getTickInterval(visual): number
	local fuseStartedAt = visual and visual.fuseStartedAt
	local fuseEndsAt = visual and visual.fuseEndsAt
	if typeof(fuseStartedAt) ~= "number" or typeof(fuseEndsAt) ~= "number" or fuseEndsAt <= fuseStartedAt then
		return TICK_START_INTERVAL_SECONDS
	end

	local now = workspace:GetServerTimeNow()
	local progress = math.clamp((now - fuseStartedAt) / (fuseEndsAt - fuseStartedAt), 0, 1)
	local remainingAlpha = (1 - progress) ^ TICK_ACCELERATION_EXPONENT
	return TICK_END_INTERVAL_SECONDS + ((TICK_START_INTERVAL_SECONDS - TICK_END_INTERVAL_SECONDS) * remainingAlpha)
end

function BombFuseAudioRuntime.Stop(visual)
	if not visual then
		return
	end

	visual.fuseTickEnabled = false
	disconnectMonitor(visual)

	local sound = visual.fuseTickSound or visual.fuseTickLastSound
	visual.fuseTickSound = nil
	visual.fuseTickLastSound = nil
	visual.fuseTickRoot = nil
	if sound then
		SoundUtil.Stop(sound)
	end
end

function BombFuseAudioRuntime.Start(visual, instance: Instance?)
	if not visual then
		return
	end

	local rootPart = getRootPart(visual, instance)
	if not rootPart then
		BombFuseAudioRuntime.Stop(visual)
		return
	end

	visual.fuseTickEnabled = true
	visual.fuseTickRoot = rootPart

	if visual.fuseTickConnection then
		return
	end

	disconnectMonitor(visual)
	playTick(visual, rootPart)
	visual.fuseTickNextAt = os.clock() + getTickInterval(visual)
	visual.fuseTickConnection = RunService.Heartbeat:Connect(function()
		if not visual.fuseTickEnabled then
			disconnectMonitor(visual)
			return
		end

		local activeRootPart = getRootPart(visual, instance)
		if not activeRootPart then
			BombFuseAudioRuntime.Stop(visual)
			return
		end

		visual.fuseTickRoot = activeRootPart

		local now = os.clock()
		local nextAt = if typeof(visual.fuseTickNextAt) == "number" then visual.fuseTickNextAt else now
		if now >= nextAt then
			playTick(visual, activeRootPart)
			visual.fuseTickNextAt = now + getTickInterval(visual)
		end
	end)
end

function BombFuseAudioRuntime.Refresh(visual, instance: Instance?)
	if not (visual and visual.fuseTickEnabled == true) then
		return
	end
	BombFuseAudioRuntime.Start(visual, instance)
end

return table.freeze(BombFuseAudioRuntime)
