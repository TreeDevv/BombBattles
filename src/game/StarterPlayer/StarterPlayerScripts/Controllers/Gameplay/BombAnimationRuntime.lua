local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)

local BombAnimationRuntime = {}

local function isServerAnimator(animator: Animator): boolean
	local attributeName = AnimationConfig.ServerAnimatorAttributeName
	return typeof(attributeName) ~= "string" or attributeName == "" or animator:GetAttribute(attributeName) == true
end

local function findServerAnimator(humanoid: Humanoid): Animator?
	for _, child in ipairs(humanoid:GetChildren()) do
		if child:IsA("Animator") and isServerAnimator(child) then
			return child
		end
	end

	return nil
end

local function waitForServerAnimator(character: Model, lookupTimeout: number): Animator?
	local deadline = os.clock() + lookupTimeout
	repeat
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local animator = findServerAnimator(humanoid)
			if animator then
				return animator
			end
		end

		task.wait()
	until os.clock() >= deadline or not character.Parent

	return nil
end

local function getTrackWeight(name: string): number
	local config = AnimationConfig.BombAnimations[name]
	if config and typeof(config.Weight) == "number" then
		return math.clamp(config.Weight, 0, 1)
	end

	return 1
end

local function getFadeInTime(): number
	local fadeTime = AnimationConfig.BombAnimationFadeInTime
	if typeof(fadeTime) == "number" then
		return math.max(fadeTime, 0)
	end

	return math.max(AnimationConfig.BombAnimationFadeTime or 0, 0)
end

local function getFadeOutTime(): number
	local fadeTime = AnimationConfig.BombAnimationFadeOutTime
	if typeof(fadeTime) == "number" then
		return math.max(fadeTime, 0)
	end

	return math.max(AnimationConfig.BombAnimationFadeTime or 0, 0)
end

local function isTrackEnabled(name: string): boolean
	local toggles = AnimationConfig.DebugRiskyTrackEnabled
	return not (typeof(toggles) == "table" and toggles[name] == false)
end

local function readTrackNumber(track: AnimationTrack, propertyName: string): number?
	local ok, value = pcall(function()
		return track[propertyName]
	end)

	return if ok and typeof(value) == "number" then value else nil
end

local function getRootAngles(rootPart: BasePart?): (number, number, number)
	if not rootPart then
		return 0, 0, 0
	end

	local pitch, yaw, roll = rootPart.CFrame:ToOrientation()
	return math.deg(pitch), math.deg(roll), math.deg(yaw)
end

local function formatNumber(value: number?): string
	if typeof(value) ~= "number" then
		return "?"
	end

	return string.format("%.2f", value)
end

local function getTrackSummary(track: AnimationTrack?): string
	if not track then
		return "track=nil"
	end

	return string.format(
		"playing=%s weight=%s target=%s speed=%s priority=%s",
		tostring(track.IsPlaying),
		formatNumber(readTrackNumber(track, "WeightCurrent")),
		formatNumber(readTrackNumber(track, "WeightTarget")),
		formatNumber(readTrackNumber(track, "Speed")),
		track.Priority.Name
	)
end

function BombAnimationRuntime.DisconnectAnimationConnections(controller)
	for _, connection in ipairs(controller._animationConnections) do
		connection:Disconnect()
	end
	controller._animationConnections = {}
end

function BombAnimationRuntime.DisconnectReleaseMarker(controller)
	if controller._releaseMarkerConnection then
		controller._releaseMarkerConnection:Disconnect()
		controller._releaseMarkerConnection = nil
	end
end

function BombAnimationRuntime.StopTracks(controller, fadeTime: number?)
	local stopFadeTime = if typeof(fadeTime) == "number" then math.max(fadeTime, 0) else getFadeOutTime()
	for _, track in pairs(controller._bombTracks) do
		if track.IsPlaying then
			track:Stop(stopFadeTime)
		end
	end
end

function BombAnimationRuntime.ClearState(controller, context)
	controller._holding = false
	controller._releasePending = false
	controller._releaseFallbackSerial += 1
	controller._abilityThrowActive = false
	controller._abilityReleaseCallback = nil
	BombAnimationRuntime.DisconnectReleaseMarker(controller)
	BombAnimationRuntime.DisconnectAnimationConnections(controller)
	BombAnimationRuntime.StopTracks(controller)
	context.hideHeldBomb(context.localPlayer)
end

function BombAnimationRuntime.Destroy(controller, context)
	controller._animationLoadSerial += 1
	BombAnimationRuntime.ClearState(controller, context)

	for _, animation in ipairs(controller._animationObjects) do
		animation:Destroy()
	end

	controller._animationObjects = {}
	controller._bombTracks = {}
	controller._animator = nil
	controller._lastDebugLogTimes = {}
end

function BombAnimationRuntime.Bind(controller, context, character: Model, animator: Animator?, serial: number): boolean
	if
		controller._animationLoadSerial ~= serial
		or controller._character ~= character
		or context.localPlayer.Character ~= character
	then
		return false
	end
	if not (animator and character.Parent and animator.Parent and animator.Parent:IsA("Humanoid")) then
		return false
	end

	controller._animator = animator

	for name, config in pairs(AnimationConfig.BombAnimations) do
		if
			controller._animationLoadSerial ~= serial
			or controller._character ~= character
			or context.localPlayer.Character ~= character
		then
			return false
		end

		local animation = Instance.new("Animation")
		animation.Name = "Bomb" .. name
		animation.AnimationId = config.AnimationId
		animation.Parent = context.animationParent
		table.insert(controller._animationObjects, animation)

		local track = animator:LoadAnimation(animation)
		track.Looped = config.Looped == true
		track.Priority = config.Priority
		controller._bombTracks[name] = track
	end

	return true
end

function BombAnimationRuntime.Load(controller, context, character: Model)
	BombAnimationRuntime.Destroy(controller, context)
	controller._character = character
	local serial = controller._animationLoadSerial

	task.spawn(function()
		while
			controller._animationLoadSerial == serial
			and controller._character == character
			and context.localPlayer.Character == character
		do
			if not character.Parent then
				return
			end

			local animator = waitForServerAnimator(character, context.animatorLookupTimeout)
			if BombAnimationRuntime.Bind(controller, context, character, animator, serial) then
				return
			end
			if
				controller._animationLoadSerial ~= serial
				or controller._character ~= character
				or context.localPlayer.Character ~= character
			then
				return
			end
			if not character.Parent then
				return
			end

			warn("[BombController] Waiting for server-created Animator for character:", character:GetFullName())
			task.wait(context.animatorRetrySeconds)
		end
	end)
end

function BombAnimationRuntime.SetDebugAttributes(context, eventName: string, trackName: string?, pitch: number, roll: number)
	local character = context.localPlayer.Character
	if not character then
		return
	end

	character:SetAttribute("Animation_DebugLastEvent", eventName)
	character:SetAttribute("Animation_DebugLastRootPitch", pitch)
	character:SetAttribute("Animation_DebugLastRootRoll", roll)
	character:SetAttribute("Animation_DebugLastTrack", trackName or "")
end

function BombAnimationRuntime.LogDebug(controller, context, eventName: string, trackName: string?, force: boolean?)
	if not AnimationConfig.DebugTransitionsEnabled then
		return
	end

	local now = os.clock()
	local key = eventName .. ":" .. (trackName or "")
	local cooldown = AnimationConfig.DebugLogCooldownSeconds or 0
	if not force and now - (controller._lastDebugLogTimes[key] or -math.huge) < cooldown then
		return
	end
	controller._lastDebugLogTimes[key] = now

	local rootPart = context.getRootPart()
	local pitch, roll, yaw = getRootAngles(rootPart)
	local velocityY = if rootPart then rootPart.AssemblyLinearVelocity.Y else 0
	local angularVelocity = if rootPart then rootPart.AssemblyAngularVelocity.Magnitude else 0
	local track = if trackName then controller._bombTracks[trackName] else nil
	BombAnimationRuntime.SetDebugAttributes(context, eventName, trackName, pitch, roll)

	warn(string.format(
		"[AnimationDebug] event=%s track=%s holding=%s cooking=%s releasePending=%s pitch=%.1f roll=%.1f yaw=%.1f velY=%.1f angVel=%.2f focus={%s}",
		eventName,
		trackName or "",
		tostring(controller._holding),
		tostring(context.isCooking()),
		tostring(controller._releasePending),
		pitch,
		roll,
		yaw,
		velocityY,
		angularVelocity,
		getTrackSummary(track)
	))
end

function BombAnimationRuntime.PlayTrack(controller, context, name: string): AnimationTrack?
	local track = controller._bombTracks[name]
	if not track then
		return nil
	end

	if not isTrackEnabled(name) then
		BombAnimationRuntime.LogDebug(controller, context, "bomb-skip-disabled", name, true)
		return nil
	end

	if track.IsPlaying then
		track:Stop(getFadeOutTime())
	end

	BombAnimationRuntime.LogDebug(controller, context, "bomb-play-before", name, true)
	track:Play(getFadeInTime(), getTrackWeight(name), 1)
	track:AdjustSpeed(1)
	BombAnimationRuntime.LogDebug(controller, context, "bomb-play-after", name, true)
	return track
end

function BombAnimationRuntime.ConnectThrowMarker(controller, context, track: AnimationTrack)
	BombAnimationRuntime.DisconnectReleaseMarker(controller)
	controller._releaseMarkerConnection = track:GetMarkerReachedSignal(AnimationConfig.BombThrowMarkerName):Connect(function()
		BombAnimationRuntime.LogDebug(controller, context, "bomb-throw-marker", "Throw", true)
		context.fireReleaseFromAnimation()
	end)
end

function BombAnimationRuntime.PlayThrow(controller, context)
	controller._releasePending = false
	controller._releaseFallbackSerial += 1
	BombAnimationRuntime.DisconnectReleaseMarker(controller)
	BombAnimationRuntime.DisconnectAnimationConnections(controller)

	local throwTrack = BombAnimationRuntime.PlayTrack(controller, context, "Throw")
	if not throwTrack then
		return
	end

	BombAnimationRuntime.ConnectThrowMarker(controller, context, throwTrack)

	local holdConnection = throwTrack.KeyframeReached:Connect(function(keyframeName: string)
		if keyframeName == AnimationConfig.BombHoldKeyframeName and controller._holding and not controller._releasePending then
			BombAnimationRuntime.LogDebug(controller, context, "bomb-hold-pause", "Throw", true)
			throwTrack:AdjustSpeed(0)
		end
	end)
	table.insert(controller._animationConnections, holdConnection)
end

function BombAnimationRuntime.PlayRelease(controller, context)
	local throwTrack = controller._bombTracks.Throw
	if throwTrack and not throwTrack.IsPlaying then
		BombAnimationRuntime.PlayThrow(controller, context)
		throwTrack = controller._bombTracks.Throw
	end

	controller._releasePending = true
	controller._releaseFallbackSerial += 1
	local serial = controller._releaseFallbackSerial

	if throwTrack then
		BombAnimationRuntime.LogDebug(controller, context, "bomb-release-resume", "Throw", true)
		throwTrack:AdjustSpeed(1)
	end

	task.delay(AnimationConfig.BombReleaseFallbackSeconds, function()
		if serial == controller._releaseFallbackSerial and controller._releasePending then
			BombAnimationRuntime.LogDebug(controller, context, "bomb-release-fallback", "Throw", true)
			context.fireReleaseFromAnimation()
		end
	end)
end

return table.freeze(BombAnimationRuntime)
