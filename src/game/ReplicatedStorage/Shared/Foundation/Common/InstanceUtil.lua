local InstanceUtil = {}

function InstanceUtil.GetByPath(root: Instance, path: { string }): Instance?
	local current: Instance? = root
	for _, name in ipairs(path) do
		if typeof(name) ~= "string" or name == "" or not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

function InstanceUtil.GetBaseParts(root: Instance): { BasePart }
	local parts = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

function InstanceUtil.GetBounds(instance: Instance): (CFrame, Vector3)
	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	end

	local part = instance :: BasePart
	return part.CFrame, part.Size
end

function InstanceUtil.PivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	else
		(instance :: BasePart).CFrame = cframe
	end
end

function InstanceUtil.ScaledVector(vector: Vector3, scale: number): Vector3
	return Vector3.new(
		math.max(vector.X * scale, 0.01),
		math.max(vector.Y * scale, 0.01),
		math.max(vector.Z * scale, 0.01)
	)
end

return table.freeze(InstanceUtil)
