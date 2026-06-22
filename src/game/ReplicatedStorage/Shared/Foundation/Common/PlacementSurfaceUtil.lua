local CollectionService = game:GetService("CollectionService")

local PlacementSurfaceUtil = {}

export type FloorPlacement = {
	position: Vector3,
	facing: Vector3,
	normal: Vector3,
	floor: Instance?,
}

local DEFAULT_PLACEMENT_DISTANCE = 8
local DEFAULT_RAYCAST_UP = 8
local DEFAULT_RAYCAST_DOWN = 32
local DEFAULT_DISTANCE_SLACK = 4
local DEFAULT_AIM_RAY_DISTANCE = 500
local DEFAULT_SURFACE_POSITION_TOLERANCE = 2

function PlacementSurfaceUtil.GetBaseParts(root: Instance): { BasePart }
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

function PlacementSurfaceUtil.GetBounds(instance: Instance): (CFrame, Vector3)
	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	end

	local part = instance :: BasePart
	return part.CFrame, part.Size
end

function PlacementSurfaceUtil.PivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	else
		(instance :: BasePart).CFrame = cframe
	end
end

function PlacementSurfaceUtil.FlattenDirection(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.zAxis
	end
	return flat.Unit
end

function PlacementSurfaceUtil.GetSurfaceFacing(direction: Vector3, normal: Vector3): Vector3
	local up = if normal.Magnitude > 0.05 then normal.Unit else Vector3.yAxis
	local forward = direction - up * direction:Dot(up)
	if forward.Magnitude < 0.05 then
		forward = Vector3.yAxis - up * Vector3.yAxis:Dot(up)
	end
	if forward.Magnitude < 0.05 then
		forward = Vector3.xAxis - up * Vector3.xAxis:Dot(up)
	end
	if forward.Magnitude < 0.05 then
		return Vector3.zAxis
	end
	return forward.Unit
end

function PlacementSurfaceUtil.IsFiniteVector(value: any): boolean
	return typeof(value) == "Vector3" and value.X == value.X and value.Y == value.Y and value.Z == value.Z
end

function PlacementSurfaceUtil.HasTaggedAncestor(instance: Instance, tagNames: { string }): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		for _, tagName in ipairs(tagNames) do
			if CollectionService:HasTag(current, tagName) then
				return true
			end
		end
		current = current.Parent
	end
	return false
end

function PlacementSurfaceUtil.GetPlacementDistanceLimit(definition): number
	return math.max(tonumber(definition.placementDistance) or DEFAULT_PLACEMENT_DISTANCE, 0)
		+ (tonumber(definition.placementDistanceSlack) or DEFAULT_DISTANCE_SLACK)
end

function PlacementSurfaceUtil.IsTargetSurfaceAllowed(hit: RaycastResult, options): boolean
	local _ = hit
	local _options = options
	return true
end

local function getRaycastParams(excludeInstances: { Instance }?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excludeInstances or {}
	params.RespectCanCollide = false
	return params
end

function PlacementSurfaceUtil.ResolveAimedSurfacePlacement(options): FloorPlacement?
	local rootPart: BasePart = options.rootPart
	local definition = options.definition or {}
	local rayOrigin: Vector3 = options.rayOrigin
	local rayDirection: Vector3 = options.rayDirection
	if not PlacementSurfaceUtil.IsFiniteVector(rayOrigin)
		or not PlacementSurfaceUtil.IsFiniteVector(rayDirection)
		or rayDirection.Magnitude < 0.05
	then
		return nil
	end

	local rayLength = math.max(tonumber(definition.aimRayDistance) or DEFAULT_AIM_RAY_DISTANCE, 1)
	local hit = workspace:Raycast(rayOrigin, rayDirection.Unit * rayLength, getRaycastParams(options.excludeInstances))
	if not hit or not PlacementSurfaceUtil.IsTargetSurfaceAllowed(hit, options) then
		return nil
	end
	if (hit.Position - rootPart.Position).Magnitude > PlacementSurfaceUtil.GetPlacementDistanceLimit(definition) then
		return nil
	end

	return {
		position = hit.Position,
		facing = PlacementSurfaceUtil.GetSurfaceFacing(-rayDirection, hit.Normal),
		normal = hit.Normal,
		floor = hit.Instance,
	}
end

function PlacementSurfaceUtil.ResolvePayloadSurfacePlacement(options): FloorPlacement?
	local rootPart: BasePart = options.rootPart
	local definition = options.definition or {}
	local payload = options.payload
	if typeof(payload) ~= "table" then
		return nil
	end

	local requested = if PlacementSurfaceUtil.IsFiniteVector(payload.surfacePosition)
		then payload.surfacePosition
		else payload.floorPosition
	if not PlacementSurfaceUtil.IsFiniteVector(requested) then
		return nil
	end
	if (requested - rootPart.Position).Magnitude > PlacementSurfaceUtil.GetPlacementDistanceLimit(definition) then
		return nil
	end

	local rayOrigin = rootPart.Position + Vector3.yAxis * (tonumber(definition.serverLineOfSightHeight) or 1.5)
	local rayDirection = requested - rayOrigin
	if rayDirection.Magnitude < 0.05 then
		return nil
	end

	local hit = workspace:Raycast(
		rayOrigin,
		rayDirection.Unit * (rayDirection.Magnitude + 0.75),
		getRaycastParams(options.excludeInstances)
	)
	if not hit or not PlacementSurfaceUtil.IsTargetSurfaceAllowed(hit, options) then
		return nil
	end

	local positionTolerance = tonumber(definition.surfacePositionTolerance) or DEFAULT_SURFACE_POSITION_TOLERANCE
	if (hit.Position - requested).Magnitude > positionTolerance then
		return nil
	end

	local facingDirection = if PlacementSurfaceUtil.IsFiniteVector(payload.facing)
		then payload.facing
		else rootPart.CFrame.LookVector
	return {
		position = hit.Position,
		facing = PlacementSurfaceUtil.GetSurfaceFacing(facingDirection, hit.Normal),
		normal = hit.Normal,
		floor = hit.Instance,
	}
end

function PlacementSurfaceUtil.ResolveForwardOffsetPlacement(options): FloorPlacement?
	local rootPart: BasePart = options.rootPart
	local definition = options.definition or {}
	local facing = PlacementSurfaceUtil.FlattenDirection(rootPart.CFrame.LookVector)
	local distance = tonumber(options.distance) or tonumber(definition.placementDistance) or DEFAULT_PLACEMENT_DISTANCE
	if typeof(options.payload) == "table" and PlacementSurfaceUtil.IsFiniteVector(options.payload.facing) then
		facing = PlacementSurfaceUtil.FlattenDirection(options.payload.facing)
	end

	return {
		position = rootPart.Position + facing * math.max(distance, 0),
		facing = facing,
		normal = Vector3.yAxis,
		floor = nil,
	}
end

function PlacementSurfaceUtil.ResolveRootPlacement(options): FloorPlacement?
	local rootPart: BasePart = options.rootPart
	local facing = PlacementSurfaceUtil.FlattenDirection(rootPart.CFrame.LookVector)
	if typeof(options.payload) == "table" and PlacementSurfaceUtil.IsFiniteVector(options.payload.facing) then
		facing = PlacementSurfaceUtil.FlattenDirection(options.payload.facing)
	end

	return {
		position = rootPart.Position,
		facing = facing,
		normal = Vector3.yAxis,
		floor = nil,
	}
end

function PlacementSurfaceUtil.ResolveFloorPlacement(options): FloorPlacement?
	local rootPart: BasePart = options.rootPart
	local definition = options.definition or {}
	local payload = options.payload
	local facing = PlacementSurfaceUtil.FlattenDirection(rootPart.CFrame.LookVector)
	local target = rootPart.Position + facing * (tonumber(definition.placementDistance) or DEFAULT_PLACEMENT_DISTANCE)

	if typeof(payload) == "table" and PlacementSurfaceUtil.IsFiniteVector(payload.floorPosition) then
		local requested = payload.floorPosition
		if (requested - rootPart.Position).Magnitude > PlacementSurfaceUtil.GetPlacementDistanceLimit(definition) then
			return nil
		end

		target = requested
		if PlacementSurfaceUtil.IsFiniteVector(payload.facing) then
			facing = PlacementSurfaceUtil.FlattenDirection(payload.facing)
		end
	elseif options.useRootPosition == true then
		target = rootPart.Position
	end

	local rayUp = tonumber(definition.floorRaycastUp) or DEFAULT_RAYCAST_UP
	local rayDown = tonumber(definition.floorRaycastDown) or DEFAULT_RAYCAST_DOWN
	local hit = workspace:Raycast(
		target + Vector3.yAxis * rayUp,
		Vector3.new(0, -(rayUp + rayDown), 0),
		getRaycastParams(options.excludeInstances)
	)
	if not hit then
		return nil
	end
	if not PlacementSurfaceUtil.IsTargetSurfaceAllowed(hit, options) then
		return nil
	end

	return {
		position = hit.Position,
		facing = facing,
		normal = hit.Normal,
		floor = hit.Instance,
	}
end

function PlacementSurfaceUtil.GetPartAxisExtents(part: BasePart, axis: Vector3, origin: Vector3): (number, number)
	local halfSize = part.Size * 0.5
	local minDistance = math.huge
	local maxDistance = -math.huge

	for _, xSign in ipairs({ -1, 1 }) do
		for _, ySign in ipairs({ -1, 1 }) do
			for _, zSign in ipairs({ -1, 1 }) do
				local corner = part.CFrame:PointToWorldSpace(Vector3.new(
					halfSize.X * xSign,
					halfSize.Y * ySign,
					halfSize.Z * zSign
				))
				local distance = (corner - origin):Dot(axis)
				minDistance = math.min(minDistance, distance)
				maxDistance = math.max(maxDistance, distance)
			end
		end
	end

	return minDistance, maxDistance
end

function PlacementSurfaceUtil.GetInstanceAxisExtents(instance: Instance, axis: Vector3, origin: Vector3): (number, number)
	local minDistance = math.huge
	local maxDistance = -math.huge
	local foundPart = false
	for _, part in ipairs(PlacementSurfaceUtil.GetBaseParts(instance)) do
		foundPart = true
		local partMin, partMax = PlacementSurfaceUtil.GetPartAxisExtents(part, axis, origin)
		minDistance = math.min(minDistance, partMin)
		maxDistance = math.max(maxDistance, partMax)
	end

	if not foundPart then
		return 0, 0
	end
	return minDistance, maxDistance
end

function PlacementSurfaceUtil.GetFloorPivot(floorPosition: Vector3, facing: Vector3, normal: Vector3): CFrame
	local up = if normal.Magnitude > 0.05 then normal.Unit else Vector3.yAxis
	local forward = facing - up * facing:Dot(up)
	if forward.Magnitude < 0.05 then
		forward = up:Cross(Vector3.xAxis)
		if forward.Magnitude < 0.05 then
			forward = up:Cross(Vector3.zAxis)
		end
	end

	forward = forward.Unit
	local right = up:Cross(forward).Unit
	forward = right:Cross(up).Unit
	return CFrame.fromMatrix(floorPosition, right, up, -forward)
end

function PlacementSurfaceUtil.AlignToFloor(instance: Instance, placement: FloorPlacement): (CFrame, Vector3)
	local pivot = PlacementSurfaceUtil.GetFloorPivot(placement.position, placement.facing, placement.normal)
	PlacementSurfaceUtil.PivotTo(instance, pivot)

	local bottomOffset = PlacementSurfaceUtil.GetInstanceAxisExtents(instance, pivot.UpVector, placement.position)
	local finalPivot = pivot - pivot.UpVector * bottomOffset
	PlacementSurfaceUtil.PivotTo(instance, finalPivot)

	return PlacementSurfaceUtil.GetBounds(instance)
end

function PlacementSurfaceUtil.IsCharacterPart(part: BasePart): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

function PlacementSurfaceUtil.IsPlacementClear(options): boolean
	local boundsCFrame: CFrame = options.boundsCFrame
	local boundsSize: Vector3 = options.boundsSize
	local support: Instance? = options.support
	local up = boundsCFrame.UpVector
	local overlapSize = Vector3.new(
		math.max(boundsSize.X * (options.scaleXZ or 0.92), 0.1),
		math.max(boundsSize.Y - (options.heightShrink or 0.2), 0.1),
		math.max(boundsSize.Z * (options.scaleXZ or 0.92), 0.1)
	)
	local overlapCFrame = boundsCFrame + up * (options.centerOffset or 0.12)

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = options.excludeInstances or {}
	params.RespectCanCollide = true

	for _, part in ipairs(workspace:GetPartBoundsInBox(overlapCFrame, overlapSize, params)) do
		if support and (part == support or part:IsDescendantOf(support)) then
			continue
		end
		if options.unsafeTags and PlacementSurfaceUtil.HasTaggedAncestor(part, options.unsafeTags) then
			return false
		end
		if PlacementSurfaceUtil.IsCharacterPart(part) then
			return false
		end
		if part.CanCollide and part.Transparency < 1 then
			return false
		end
	end

	return true
end

return table.freeze(PlacementSurfaceUtil)
