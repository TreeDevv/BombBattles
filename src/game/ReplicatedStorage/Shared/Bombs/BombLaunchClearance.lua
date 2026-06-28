local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local CollisionGroupConfig = require(ReplicatedStorage.Shared.Config.CollisionGroupConfig)

local BombLaunchClearance = {}

local PROJECTILE_VISUAL_FOLDER_NAME = "BombProjectileVisuals"
local DEFAULT_SURFACE_OFFSET = 0.05
local MIN_CAST_DISTANCE = 0.001

export type ResolveOptions = {
	character: Model?,
	radius: number?,
	collisionGroup: string?,
	respectCanCollide: boolean?,
	ignoreWater: boolean?,
	extraExcludeInstances: { Instance }?,
}

local function addIfPresent(excluded: { Instance }, instance: Instance?)
	if instance then
		table.insert(excluded, instance)
	end
end

local function getExcludedInstances(options: ResolveOptions?): { Instance }
	local excluded = {}
	if options then
		addIfPresent(excluded, options.character)
		if options.extraExcludeInstances then
			for _, instance in ipairs(options.extraExcludeInstances) do
				addIfPresent(excluded, instance)
			end
		end
	end

	addIfPresent(excluded, workspace:FindFirstChild(BombConfig.ProjectileFolderName))
	addIfPresent(excluded, workspace:FindFirstChild(PROJECTILE_VISUAL_FOLDER_NAME))
	return excluded
end

local function applySharedParams(params, options: ResolveOptions?)
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = getExcludedInstances(options)

	local collisionGroup = if options and typeof(options.collisionGroup) == "string" and options.collisionGroup ~= ""
		then options.collisionGroup
		else CollisionGroupConfig.Groups.BombProjectile
	pcall(function()
		params.CollisionGroup = collisionGroup
	end)

	pcall(function()
		params.RespectCanCollide = not (options and options.respectCanCollide == false)
	end)
end

local function createRaycastParams(options: ResolveOptions?): RaycastParams
	local params = RaycastParams.new()
	applySharedParams(params, options)
	params.IgnoreWater = not (options and options.ignoreWater == false)
	return params
end

local function createOverlapParams(options: ResolveOptions?): OverlapParams
	local params = OverlapParams.new()
	applySharedParams(params, options)
	pcall(function()
		params.MaxParts = 1
	end)
	return params
end

local function getRadius(options: ResolveOptions?): number
	local radius = if options and typeof(options.radius) == "number" then options.radius else BombConfig.SweepRadius
	return math.max(radius, 0.05)
end

local function castLaunchSegment(
	fromPosition: Vector3,
	toPosition: Vector3,
	radius: number,
	params: RaycastParams
): (RaycastResult?, boolean)
	local direction = toPosition - fromPosition
	if direction.Magnitude <= MIN_CAST_DISTANCE then
		return nil, false
	end

	local spherecastOk, spherecastResult = pcall(function()
		return workspace:Spherecast(fromPosition, radius, direction, params)
	end)
	if spherecastOk then
		return spherecastResult, true
	end

	return workspace:Raycast(fromPosition, direction, params), false
end

local function getHitCenter(fromPosition: Vector3, toPosition: Vector3, radius: number, hit: RaycastResult, usedSpherecast: boolean): Vector3
	local direction = toPosition - fromPosition
	if usedSpherecast and direction.Magnitude > MIN_CAST_DISTANCE then
		return fromPosition + direction.Unit * math.max(hit.Distance, 0)
	end
	return hit.Position + hit.Normal * radius
end

local function hasInitialOverlap(position: Vector3, radius: number, options: ResolveOptions?): boolean
	local parts = workspace:GetPartBoundsInRadius(position, radius, createOverlapParams(options))
	return #parts > 0
end

local function findClearPlayerSideFallback(
	rootPart: BasePart,
	startPosition: Vector3,
	desiredOrigin: Vector3,
	radius: number,
	options: ResolveOptions?
): Vector3
	if not hasInitialOverlap(startPosition, radius, options) then
		return startPosition
	end

	local movement = desiredOrigin - startPosition
	local awayDirection = if movement.Magnitude > MIN_CAST_DISTANCE then -movement.Unit else -rootPart.CFrame.LookVector
	local stepDistance = math.max(radius * 0.5, 0.25)
	for index = 1, 8 do
		local candidate = startPosition + awayDirection * (stepDistance * index)
		if not hasInitialOverlap(candidate, radius, options) then
			return candidate
		end
	end

	return startPosition
end

function BombLaunchClearance.GetStartPosition(rootPart: BasePart): Vector3
	return rootPart.Position + Vector3.yAxis * BombConfig.ThrowOffset.Y
end

function BombLaunchClearance.ResolveOrigin(rootPart: BasePart, desiredOrigin: Vector3, options: ResolveOptions?): Vector3
	local radius = getRadius(options)
	local startPosition = BombLaunchClearance.GetStartPosition(rootPart)
	local params = createRaycastParams(options)
	local hit, usedSpherecast = castLaunchSegment(startPosition, desiredOrigin, radius, params)
	if hit then
		local center = getHitCenter(startPosition, desiredOrigin, radius, hit, usedSpherecast)
		return center + hit.Normal * DEFAULT_SURFACE_OFFSET
	end

	if hasInitialOverlap(desiredOrigin, radius, options) then
		return findClearPlayerSideFallback(rootPart, startPosition, desiredOrigin, radius, options)
	end

	return desiredOrigin
end

return table.freeze(BombLaunchClearance)
