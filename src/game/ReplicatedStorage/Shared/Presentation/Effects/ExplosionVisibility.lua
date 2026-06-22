local Players = game:GetService("Players")

local ExplosionVisibility = {}

local KEY_SIZE = 8
local CACHE_SECONDS = 2.5
local SCREEN_MARGIN = 72
local OCCLUSION_MIN_DISTANCE = 45
local OCCLUSION_RADIUS_SCALE = 0.45
local DEFAULT_TERRAIN_RADIUS = 24
local DEFAULT_OUTER_RADIUS = 24

ExplosionVisibility.Quality = table.freeze({
	Full = "Full",
	SoundOnly = "SoundOnly",
	Skip = "Skip",
})

local function getPayloadPosition(payload): Vector3?
	return if typeof(payload) == "table" and typeof(payload.position) == "Vector3" then payload.position else nil
end

local function getDefaultRadius(options): number
	if typeof(options) == "table" then
		if typeof(options.defaultTerrainRadius) == "number" then
			return math.max(options.defaultTerrainRadius, 1)
		end
		if typeof(options.defaultOuterRadius) == "number" then
			return math.max(options.defaultOuterRadius, 1)
		end
	end
	return DEFAULT_TERRAIN_RADIUS
end

function ExplosionVisibility.GetRadius(payload, options): number
	if typeof(payload) == "table" then
		if typeof(payload.terrainRadius) == "number" then
			return math.max(payload.terrainRadius, 1)
		end
		if typeof(payload.outerRadius) == "number" then
			return math.max(payload.outerRadius * 0.35, 1)
		end
		if typeof(payload.radius) == "number" then
			return math.max(payload.radius, 1)
		end
	end
	return getDefaultRadius(options)
end

function ExplosionVisibility.GetKey(position: Vector3): string
	return ("%d:%d:%d"):format(
		math.floor(position.X / KEY_SIZE + 0.5),
		math.floor(position.Y / KEY_SIZE + 0.5),
		math.floor(position.Z / KEY_SIZE + 0.5)
	)
end

function ExplosionVisibility.CreateCache(): { [string]: any }
	return {}
end

function ExplosionVisibility.Remember(cache: { [string]: any }?, position: Vector3, decision)
	if typeof(cache) ~= "table" then
		return
	end

	cache[ExplosionVisibility.GetKey(position)] = {
		decision = decision,
		expiresAt = os.clock() + CACHE_SECONDS,
	}
end

function ExplosionVisibility.GetCached(cache: { [string]: any }?, position: Vector3)
	if typeof(cache) ~= "table" then
		return nil
	end

	local key = ExplosionVisibility.GetKey(position)
	local record = cache[key]
	if typeof(record) ~= "table" then
		return nil
	end
	if typeof(record.expiresAt) ~= "number" or record.expiresAt < os.clock() then
		cache[key] = nil
		return nil
	end
	return record.decision
end

function ExplosionVisibility.SkipDecision()
	return {
		quality = ExplosionVisibility.Quality.Skip,
		distance = math.huge,
		inView = false,
		occluded = false,
	}
end

local function getExplosionSamplePoints(camera: Camera, position: Vector3, radius: number): { Vector3 }
	local offset = math.max(radius * OCCLUSION_RADIUS_SCALE, 2)
	return {
		position,
		position + Vector3.yAxis * offset,
		position - Vector3.yAxis * math.min(offset, 4),
		position + camera.CFrame.RightVector * offset,
		position - camera.CFrame.RightVector * offset,
	}
end

local function isViewportPointVisible(camera: Camera, point: Vector3): boolean
	local viewportPoint = camera:WorldToViewportPoint(point)
	if viewportPoint.Z <= 0 then
		return false
	end

	local viewportSize = camera.ViewportSize
	return viewportPoint.X >= -SCREEN_MARGIN
		and viewportPoint.X <= viewportSize.X + SCREEN_MARGIN
		and viewportPoint.Y >= -SCREEN_MARGIN
		and viewportPoint.Y <= viewportSize.Y + SCREEN_MARGIN
end

local function isExplosionInView(camera: Camera, position: Vector3, radius: number): boolean
	for _, point in ipairs(getExplosionSamplePoints(camera, position, radius)) do
		if isViewportPointVisible(camera, point) then
			return true
		end
	end
	return false
end

local function isBlockingOccluder(instance: Instance?): boolean
	if not instance then
		return false
	end

	local model = instance:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return false
	end

	if instance:IsA("BasePart") then
		return instance.Transparency < 0.85 and instance.CanQuery
	end

	return true
end

local function addWorkspaceChild(excluded: { Instance }, name: any)
	if typeof(name) ~= "string" or name == "" then
		return
	end

	local child = workspace:FindFirstChild(name)
	if child then
		table.insert(excluded, child)
	end
end

local function buildOcclusionParams(options): RaycastParams
	local excluded = {}
	local localPlayer = if typeof(options) == "table" and options.localPlayer then options.localPlayer else Players.LocalPlayer
	local character = localPlayer and localPlayer.Character
	if character then
		table.insert(excluded, character)
	end

	local currentCamera = workspace.CurrentCamera
	if currentCamera then
		table.insert(excluded, currentCamera)
	end

	if typeof(options) == "table" then
		addWorkspaceChild(excluded, options.explosionFolderName)
		addWorkspaceChild(excluded, options.debrisFolderName)
		addWorkspaceChild(excluded, options.projectileFolderName)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excluded
	params.IgnoreWater = true
	return params
end

local function isExplosionOccluded(camera: Camera, position: Vector3, radius: number, options): boolean
	local origin = camera.CFrame.Position
	if (position - origin).Magnitude <= OCCLUSION_MIN_DISTANCE then
		return false
	end

	local params = buildOcclusionParams(options)
	local blockedSamples = 0
	local sampleCount = 0
	for _, point in ipairs(getExplosionSamplePoints(camera, position, radius)) do
		local direction = point - origin
		local distance = direction.Magnitude
		if distance <= 1 then
			continue
		end

		sampleCount += 1
		local result = workspace:Raycast(origin, direction, params)
		if result and result.Distance < distance - 1 and isBlockingOccluder(result.Instance) then
			blockedSamples += 1
		end
	end

	return sampleCount > 0 and blockedSamples >= sampleCount
end

function ExplosionVisibility.Choose(payload, options): { quality: string, distance: number, inView: boolean, occluded: boolean }
	local position = getPayloadPosition(payload)
	if not position then
		return ExplosionVisibility.SkipDecision()
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return {
			quality = ExplosionVisibility.Quality.Full,
			distance = 0,
			inView = true,
			occluded = false,
		}
	end

	local distance = (camera.CFrame.Position - position).Magnitude
	local radius = ExplosionVisibility.GetRadius(payload, options)
	local inView = isExplosionInView(camera, position, radius)
	local occluded = false
	local quality = ExplosionVisibility.Quality.Full

	if not inView then
		quality = ExplosionVisibility.Quality.SoundOnly
	else
		occluded = isExplosionOccluded(camera, position, radius, options)
		if occluded then
			quality = ExplosionVisibility.Quality.SoundOnly
		end
	end

	return {
		quality = quality,
		distance = distance,
		inView = inView,
		occluded = occluded,
	}
end

function ExplosionVisibility.GetDebrisPosition(payloads): Vector3?
	if typeof(payloads) ~= "table" then
		return nil
	end

	for _, payload in ipairs(payloads) do
		if typeof(payload) == "table" and typeof(payload.explosionPosition) == "Vector3" then
			return payload.explosionPosition
		end
	end
	return nil
end

function ExplosionVisibility.GetDebrisRadius(payloads, options): number
	if typeof(payloads) ~= "table" then
		return ExplosionVisibility.GetRadius(nil, options)
	end

	for _, payload in ipairs(payloads) do
		if typeof(payload) == "table" and typeof(payload.radius) == "number" then
			return math.max(payload.radius, 1)
		end
	end
	return ExplosionVisibility.GetRadius(nil, options)
end

return table.freeze(ExplosionVisibility)
