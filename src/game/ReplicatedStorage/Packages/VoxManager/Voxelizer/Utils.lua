local Utils = {}

function Utils.distanceSqFromPointToAABB(point: Vector3, aabbCenter: Vector3, halfSize: Vector3)
	local dx = math.max(math.abs(point.X - aabbCenter.X) - halfSize.X, 0)
	local dy = math.max(math.abs(point.Y - aabbCenter.Y) - halfSize.Y, 0)
	local dz = math.max(math.abs(point.Z - aabbCenter.Z) - halfSize.Z, 0)
	return dx * dx + dy * dy + dz * dz
end

function Utils.isAABBInsideSphere(aabbCenter: Vector3, halfSize: Vector3, sphereCenter: Vector3, sphereRadius: number)
	local corners = {
		Vector3.new(aabbCenter.X - halfSize.X, aabbCenter.Y - halfSize.Y, aabbCenter.Z - halfSize.Z),
		Vector3.new(aabbCenter.X + halfSize.X, aabbCenter.Y - halfSize.Y, aabbCenter.Z - halfSize.Z),
		Vector3.new(aabbCenter.X - halfSize.X, aabbCenter.Y + halfSize.Y, aabbCenter.Z - halfSize.Z),
		Vector3.new(aabbCenter.X + halfSize.X, aabbCenter.Y + halfSize.Y, aabbCenter.Z - halfSize.Z),
		Vector3.new(aabbCenter.X - halfSize.X, aabbCenter.Y - halfSize.Y, aabbCenter.Z + halfSize.Z),
		Vector3.new(aabbCenter.X + halfSize.X, aabbCenter.Y - halfSize.Y, aabbCenter.Z + halfSize.Z),
		Vector3.new(aabbCenter.X - halfSize.X, aabbCenter.Y + halfSize.Y, aabbCenter.Z + halfSize.Z),
		Vector3.new(aabbCenter.X + halfSize.X, aabbCenter.Y + halfSize.Y, aabbCenter.Z + halfSize.Z),
	}

	for _, corner in ipairs(corners) do
		if (corner - sphereCenter).Magnitude > sphereRadius then
			return false
		end
	end

	return true
end

function Utils.isAABBOutsideSphere(aabbCenter: Vector3, halfSize: Vector3, sphereCenter: Vector3, sphereRadius: number)
	local distSq = Utils.distanceSqFromPointToAABB(sphereCenter, aabbCenter, halfSize)
	return distSq >= sphereRadius * sphereRadius
end

return Utils
