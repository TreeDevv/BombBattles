local CameraShaker = {}
CameraShaker.__index = CameraShaker

local profileBegin = debug.profilebegin
local profileEnd = debug.profileend
local profileTag = "CameraShakerUpdate"

local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local RAD = math.rad
local v3Zero = V3()

local CameraShakeInstance = require(script.CameraShakeInstance)
local CameraShakeState = CameraShakeInstance.CameraShakeState

local defaultPosInfluence = V3(0.15, 0.15, 0.15)
local defaultRotInfluence = V3(1, 1, 1)

CameraShaker.CameraShakeInstance = CameraShakeInstance
CameraShaker.Presets = require(script.CameraShakePresets)

function CameraShaker.new(renderPriority, callback)
	assert(type(renderPriority) == "number", "RenderPriority must be a number")
	assert(type(callback) == "function", "Callback must be a function")

	local self = setmetatable({
		_running = false,
		_renderName = "CameraShaker",
		_renderPriority = renderPriority,
		_posAddShake = v3Zero,
		_rotAddShake = v3Zero,
		_camShakeInstances = {},
		_removeInstances = {},
		_callback = callback,
	}, CameraShaker)

	return self
end

function CameraShaker:Start()
	if self._running then
		return
	end

	self._running = true
	local callback = self._callback

	game:GetService("RunService"):BindToRenderStep(self._renderName, self._renderPriority, function(dt)
		profileBegin(profileTag)
		local cf = self:Update(dt)
		profileEnd()
		callback(cf)
	end)
end

function CameraShaker:Stop()
	if not self._running then
		return
	end

	game:GetService("RunService"):UnbindFromRenderStep(self._renderName)
	self._running = false
end

function CameraShaker:StopSustained(duration)
	for _, instance in pairs(self._camShakeInstances) do
		if instance.fadeOutDuration == 0 then
			instance:StartFadeOut(duration or instance.fadeInDuration)
		end
	end
end

function CameraShaker:Update(dt)
	local posAddShake = v3Zero
	local rotAddShake = v3Zero
	local instances = self._camShakeInstances

	for index = 1, #instances do
		local instance = instances[index]
		local state = instance:GetState()

		if state == CameraShakeState.Inactive and instance.DeleteOnInactive then
			self._removeInstances[#self._removeInstances + 1] = index
		elseif state ~= CameraShakeState.Inactive then
			local shake = instance:UpdateShake(dt)
			posAddShake += shake * instance.PositionInfluence
			rotAddShake += shake * instance.RotationInfluence
		end
	end

	for index = #self._removeInstances, 1, -1 do
		local instanceIndex = self._removeInstances[index]
		table.remove(instances, instanceIndex)
		self._removeInstances[index] = nil
	end

	return CF(posAddShake) * ANG(0, RAD(rotAddShake.Y), 0) * ANG(RAD(rotAddShake.X), 0, RAD(rotAddShake.Z))
end

function CameraShaker:Shake(shakeInstance)
	assert(type(shakeInstance) == "table" and shakeInstance._camShakeInstance, "ShakeInstance must be of type CameraShakeInstance")
	self._camShakeInstances[#self._camShakeInstances + 1] = shakeInstance
	return shakeInstance
end

function CameraShaker:ShakeSustain(shakeInstance)
	assert(type(shakeInstance) == "table" and shakeInstance._camShakeInstance, "ShakeInstance must be of type CameraShakeInstance")
	self._camShakeInstances[#self._camShakeInstances + 1] = shakeInstance
	shakeInstance:StartFadeIn(shakeInstance.fadeInDuration)
	return shakeInstance
end

function CameraShaker:ShakeOnce(magnitude, roughness, fadeInTime, fadeOutTime, posInfluence, rotInfluence)
	local shakeInstance = CameraShakeInstance.new(magnitude, roughness, fadeInTime, fadeOutTime)
	shakeInstance.PositionInfluence = if typeof(posInfluence) == "Vector3" then posInfluence else defaultPosInfluence
	shakeInstance.RotationInfluence = if typeof(rotInfluence) == "Vector3" then rotInfluence else defaultRotInfluence
	self._camShakeInstances[#self._camShakeInstances + 1] = shakeInstance
	return shakeInstance
end

function CameraShaker:StartShake(magnitude, roughness, fadeInTime, posInfluence, rotInfluence)
	local shakeInstance = CameraShakeInstance.new(magnitude, roughness, fadeInTime)
	shakeInstance.PositionInfluence = if typeof(posInfluence) == "Vector3" then posInfluence else defaultPosInfluence
	shakeInstance.RotationInfluence = if typeof(rotInfluence) == "Vector3" then rotInfluence else defaultRotInfluence
	shakeInstance:StartFadeIn(fadeInTime)
	self._camShakeInstances[#self._camShakeInstances + 1] = shakeInstance
	return shakeInstance
end

return CameraShaker
