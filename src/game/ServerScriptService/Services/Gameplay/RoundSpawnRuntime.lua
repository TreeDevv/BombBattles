local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

local RoundSpawnRuntime = {}

local SPAWN_HEIGHT_OFFSET = 4
local RAYCAST_UP_DISTANCE = 18
local RAYCAST_DOWN_DISTANCE = 90
local MIN_FLOOR_NORMAL_Y = 0.65
local RAYCAST_RETRY_LIMIT = 8
local SEARCH_RADII = { 6, 12, 18, 24, 32 }
local SEARCH_SAMPLES_PER_RING = 8
local CLEARANCE_SIZE = Vector3.new(4.5, 6.5, 4.5)
local CLEARANCE_CENTER_HEIGHT = 3.75
local SPAWN_MARKER_TAGS = {
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}
local warnedFallbackSpawns = setmetatable({}, { __mode = "k" })

local function getFallbackSpawnCFrame(spawnPart: BasePart): CFrame
	return spawnPart.CFrame + Vector3.new(0, SPAWN_HEIGHT_OFFSET, 0)
end

local function getFlatFacing(spawnPart: BasePart): Vector3
	local look = spawnPart.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end

local function getSpawnCFrame(floorPosition: Vector3, spawnPart: BasePart): CFrame
	local pivotPosition = floorPosition + Vector3.yAxis * SPAWN_HEIGHT_OFFSET
	local facing = getFlatFacing(spawnPart)
	return CFrame.lookAt(pivotPosition, pivotPosition + facing)
end

local function addTaggedDescendants(exclusions: { Instance }, tagName: string, root: Instance?)
	for _, instance in ipairs(CollectionService:GetTagged(tagName)) do
		if not root or instance:IsDescendantOf(root) then
			table.insert(exclusions, instance)
		end
	end
end

local function buildSpawnExclusions(character: Model?, map: Instance, includeOtherCharacters: boolean): { Instance }
	local exclusions = {}
	if character then
		table.insert(exclusions, character)
	end
	if includeOtherCharacters then
		for _, player in ipairs(Players:GetPlayers()) do
			local otherCharacter = player.Character
			if otherCharacter and otherCharacter ~= character then
				table.insert(exclusions, otherCharacter)
			end
		end
	end
	for _, tagName in ipairs(SPAWN_MARKER_TAGS) do
		addTaggedDescendants(exclusions, tagName, map)
	end
	return exclusions
end

local function isCharacterPart(part: BasePart): boolean
	local model = part:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local function isValidFloorHit(hit: RaycastResult, map: Instance): boolean
	local part = hit.Instance
	return part:IsA("BasePart")
		and part:IsDescendantOf(map)
		and part.CanCollide
		and hit.Normal.Y >= MIN_FLOOR_NORMAL_Y
end

local function raycastMapFloor(origin: Vector3, map: Instance, baseExclusions: { Instance }): RaycastResult?
	local exclusions = table.clone(baseExclusions)
	for _ = 1, RAYCAST_RETRY_LIMIT do
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = exclusions
		params.RespectCanCollide = true

		local hit = workspace:Raycast(origin, Vector3.yAxis * -(RAYCAST_UP_DISTANCE + RAYCAST_DOWN_DISTANCE), params)
		if not hit then
			return nil
		end
		if isValidFloorHit(hit, map) then
			return hit
		end
		table.insert(exclusions, hit.Instance)
	end
	return nil
end

local function isSpawnClear(floorPosition: Vector3, support: BasePart, baseExclusions: { Instance }): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = baseExclusions
	params.RespectCanCollide = false

	local center = floorPosition + Vector3.yAxis * CLEARANCE_CENTER_HEIGHT
	for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(center), CLEARANCE_SIZE, params)) do
		if part == support or part:IsDescendantOf(support) then
			continue
		end
		if isCharacterPart(part) then
			return false
		end
		if part.CanCollide then
			return false
		end
	end
	return true
end

local function resolveCandidate(
	candidate: Vector3,
	spawnPart: BasePart,
	map: Instance,
	raycastExclusions: { Instance },
	clearanceExclusions: { Instance }
): CFrame?
	local rayOrigin = candidate + Vector3.yAxis * RAYCAST_UP_DISTANCE
	local hit = raycastMapFloor(rayOrigin, map, raycastExclusions)
	if not hit then
		return nil
	end
	if not isSpawnClear(hit.Position, hit.Instance, clearanceExclusions) then
		return nil
	end
	return getSpawnCFrame(hit.Position, spawnPart)
end

local function warnFallback(player: Player, spawnPart: BasePart)
	if warnedFallbackSpawns[spawnPart] then
		return
	end
	warnedFallbackSpawns[spawnPart] = true
	warn(("[RoundSpawnRuntime] Falling back to authored TeamSpawn for %s; no clear procedural point found at %s"):format(
		player.Name,
		spawnPart:GetFullName()
	))
end

function RoundSpawnRuntime.GetTaggedSpawnParts(tagName: string, map: Instance?): { BasePart }
	local spawns = {}
	for _, instance in ipairs(CollectionService:GetTagged(tagName)) do
		if instance:IsA("BasePart") and (not map or instance:IsDescendantOf(map)) then
			table.insert(spawns, instance)
		end
	end
	return spawns
end

function RoundSpawnRuntime.GetTeamSpawns(teamName: string, map: Instance): { BasePart }
	local spawns = {}
	for _, spawnPart in ipairs(RoundSpawnRuntime.GetTaggedSpawnParts(RoundConfig.Tags.TeamSpawn, map)) do
		if spawnPart:GetAttribute("Team") == teamName then
			table.insert(spawns, spawnPart)
		end
	end
	return spawns
end

function RoundSpawnRuntime.GetTeamCores(teamName: string, map: Instance): { Instance }
	local cores = {}
	for _, instance in ipairs(CollectionService:GetTagged(RoundConfig.Tags.TeamCore)) do
		if instance:IsDescendantOf(map) and instance:GetAttribute("Team") == teamName then
			table.insert(cores, instance)
		end
	end
	return cores
end

function RoundSpawnRuntime.GetLobbySpawns(): { BasePart }
	return RoundSpawnRuntime.GetTaggedSpawnParts(RoundConfig.Tags.LobbySpawn, nil)
end

function RoundSpawnRuntime.MoveCharacterToSpawn(player: Player, spawnPart: BasePart)
	local character = player.Character
	if not character then
		return
	end

	character:PivotTo(getFallbackSpawnCFrame(spawnPart))
end

function RoundSpawnRuntime.ResolveTeamSpawnCFrame(player: Player, spawnPart: BasePart, map: Instance): (CFrame, boolean)
	local character = player.Character
	local raycastExclusions = buildSpawnExclusions(character, map, true)
	local clearanceExclusions = buildSpawnExclusions(character, map, false)
	local origin = spawnPart.Position
	local direct = resolveCandidate(origin, spawnPart, map, raycastExclusions, clearanceExclusions)
	if direct then
		return direct, true
	end

	for radiusIndex, radius in ipairs(SEARCH_RADII) do
		local angleOffset = (radiusIndex - 1) * (math.pi / SEARCH_SAMPLES_PER_RING)
		for sampleIndex = 1, SEARCH_SAMPLES_PER_RING do
			local angle = angleOffset + ((sampleIndex - 1) / SEARCH_SAMPLES_PER_RING) * math.pi * 2
			local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			local resolved = resolveCandidate(origin + offset, spawnPart, map, raycastExclusions, clearanceExclusions)
			if resolved then
				return resolved, true
			end
		end
	end

	return getFallbackSpawnCFrame(spawnPart), false
end

function RoundSpawnRuntime.MoveCharacterToTeamSpawn(player: Player, spawnPart: BasePart, map: Instance): boolean
	local character = player.Character
	if not character then
		return false
	end

	local spawnCFrame, resolved = RoundSpawnRuntime.ResolveTeamSpawnCFrame(player, spawnPart, map)
	if not resolved then
		warnFallback(player, spawnPart)
	end
	character:PivotTo(spawnCFrame)
	return true
end

function RoundSpawnRuntime.MovePlayerToLobby(player: Player, rng: Random)
	local lobbySpawns = RoundSpawnRuntime.GetLobbySpawns()
	if #lobbySpawns == 0 then
		warn("[RoundSpawnRuntime] Missing LobbySpawn tagged part")
		return
	end

	RoundSpawnRuntime.MoveCharacterToSpawn(player, lobbySpawns[rng:NextInteger(1, #lobbySpawns)])
end

return table.freeze(RoundSpawnRuntime)
