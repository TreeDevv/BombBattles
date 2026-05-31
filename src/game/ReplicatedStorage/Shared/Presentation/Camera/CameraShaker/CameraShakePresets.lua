local CameraShakeInstance = require(script.Parent.CameraShakeInstance)

local CameraShakePresets = {
	Bump = function()
		local instance = CameraShakeInstance.new(2.5, 4, 0.1, 0.75)
		instance.PositionInfluence = Vector3.new(0.15, 0.15, 0.15)
		instance.RotationInfluence = Vector3.new(1, 1, 1)
		return instance
	end,
	Explosion = function()
		local instance = CameraShakeInstance.new(5, 10, 0, 1.5)
		instance.PositionInfluence = Vector3.new(0.25, 0.25, 0.25)
		instance.RotationInfluence = Vector3.new(4, 1, 1)
		return instance
	end,
	Earthquake = function()
		local instance = CameraShakeInstance.new(0.6, 3.5, 2, 10)
		instance.PositionInfluence = Vector3.new(0.25, 0.25, 0.25)
		instance.RotationInfluence = Vector3.new(1, 1, 4)
		return instance
	end,
	BadTrip = function()
		local instance = CameraShakeInstance.new(10, 0.15, 5, 10)
		instance.PositionInfluence = Vector3.new(0, 0, 0.15)
		instance.RotationInfluence = Vector3.new(2, 1, 4)
		return instance
	end,
	HandheldCamera = function()
		local instance = CameraShakeInstance.new(1, 0.25, 5, 10)
		instance.PositionInfluence = Vector3.new(0, 0, 0)
		instance.RotationInfluence = Vector3.new(1, 0.5, 0.5)
		return instance
	end,
	Vibration = function()
		local instance = CameraShakeInstance.new(0.4, 20, 2, 2)
		instance.PositionInfluence = Vector3.new(0, 0.15, 0)
		instance.RotationInfluence = Vector3.new(1.25, 0, 4)
		return instance
	end,
	RoughDriving = function()
		local instance = CameraShakeInstance.new(1, 2, 1, 1)
		instance.PositionInfluence = Vector3.new(0, 0, 0)
		instance.RotationInfluence = Vector3.new(1, 1, 1)
		return instance
	end,
}

return setmetatable({}, {
	__index = function(_, index)
		local constructor = CameraShakePresets[index]
		if type(constructor) == "function" then
			return constructor()
		end

		error("No preset found with index \"" .. tostring(index) .. "\"")
	end,
})
