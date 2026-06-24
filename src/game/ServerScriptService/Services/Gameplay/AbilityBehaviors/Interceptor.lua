local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local PlacementSurfaceUtil = require(ReplicatedStorage.Shared.Common.PlacementSurfaceUtil)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityHookResult = AbilityTypes.AbilityHookResult
type AbilityServiceLike = AbilityTypes.AbilityServiceLike
type ServerActivateContext = AbilityTypes.ServerActivateContext
type ServerHookContext = AbilityTypes.ServerHookContext
type FloorPlacement = {
	position: Vector3,
	facing: Vector3,
	normal: Vector3,
	floor: Instance,
}
type InterceptorRecord = {
	id: string,
	player: Player,
	slot: string,
	folder: Folder,
	centerPiece: Instance,
	center: Vector3,
	radius: number,
	activeEndsAt: number,
	serial: number,
}

local Interceptor = {} :: AbilityTypes.ServerBehavior

local RESULT_KIND = AbilityResult.Kind
local ABILITIES_FOLDER_NAME = "Abilities"
local INTERCEPTOR_FOLDER_NAME = "Interceptor"
local OWNER_ATTR = "InterceptorOwnerUserId"
local ID_ATTR = "InterceptorId"
local PLACEMENT_DISTANCE = 3
local ACTIVE_INTERCEPTORS: { [Player]: { InterceptorRecord } } = {}
local SERIALS: { [Player]: number } = {}
local abilityService: AbilityServiceLike? = nil

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local function getByPath(root: Instance, path: { string }): Instance?
	local current: Instance? = root
	for _, name in ipairs(path) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getTemplate(definition: AbilityDefinition?): Instance?
	local path = definition and definition.assetPath
	if typeof(path) ~= "table" then
		return nil
	end

	local template = getByPath(ReplicatedStorage, path)
	if template and template:IsA("Model") then
		return template
	end
	return nil
end

local function getCenterTemplate(template: Instance): Instance?
	local center = template:FindFirstChild("CenterPiece")
	if center and (center:IsA("Model") or center:IsA("BasePart")) then
		return center
	end
	return nil
end

local function getForceFieldTemplate(template: Instance): BasePart?
	local forceField = template:FindFirstChild("ForceField")
	return if forceField and forceField:IsA("BasePart") then forceField else nil
end

local function getBaseParts(root: Instance): { BasePart }
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

local function getBounds(instance: Instance): (CFrame, Vector3)
	if instance:IsA("Model") then
		return instance:GetBoundingBox()
	end

	local part = instance :: BasePart
	return part.CFrame, part.Size
end

local function getActiveMap(): Instance?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getInterceptorRootFolder(player: Player): Folder
	local parent = PracticeRangeTargeting.GetObjectParentForServer(player, getActiveMap())
	local abilitiesFolder = parent:FindFirstChild(ABILITIES_FOLDER_NAME)
	if not (abilitiesFolder and abilitiesFolder:IsA("Folder")) then
		if abilitiesFolder then
			abilitiesFolder:Destroy()
		end
		abilitiesFolder = Instance.new("Folder")
		abilitiesFolder.Name = ABILITIES_FOLDER_NAME
		abilitiesFolder.Parent = parent
	end

	local interceptorFolder = abilitiesFolder:FindFirstChild(INTERCEPTOR_FOLDER_NAME)
	if interceptorFolder and interceptorFolder:IsA("Folder") then
		return interceptorFolder
	end
	if interceptorFolder then
		interceptorFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = INTERCEPTOR_FOLDER_NAME
	folder.Parent = abilitiesFolder
	return folder
end

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

local function findPlacement(player: Player, rootPart: BasePart, definition: AbilityDefinition): FloorPlacement?
	return PlacementSurfaceUtil.ResolveForwardSolidPlacement({
		rootPart = rootPart,
		definition = definition,
		distance = PLACEMENT_DISTANCE,
		excludeInstances = if player.Character then { player.Character } else {},
	})
end

local function validatePlacement(player: Player, definition: AbilityDefinition, centerTemplate: Instance, payload: any): FloorPlacement?
	local _ = centerTemplate
	local _payload = payload
	local rootPart = getCharacterRoot(player)
	if not rootPart then
		return nil
	end

	local placement = findPlacement(player, rootPart, definition)
	if not placement then
		return nil
	end

	return placement
end

local function prepareCenterPiece(centerPiece: Instance)
	for _, part in ipairs(getBaseParts(centerPiece)) do
		part.Anchored = true
		part.CanTouch = false
	end
end

local function getPlacementCenter(centerPiece: Instance): Vector3
	local boundsCFrame = getBounds(centerPiece)
	return boundsCFrame.Position
end

local function getRadiusFromForceField(forceField: BasePart): number
	return math.max(forceField.Size.X, forceField.Size.Y, forceField.Size.Z) * 0.5
end

local function getNextInterceptorId(player: Player): (string, number)
	local serial = (SERIALS[player] or 0) + 1
	SERIALS[player] = serial
	return string.format("Interceptor_%d_%d", player.UserId, serial), serial
end

local function removeRecord(player: Player, interceptorId: string): InterceptorRecord?
	local records = ACTIVE_INTERCEPTORS[player]
	if not records then
		return nil
	end

	for index = #records, 1, -1 do
		local record = records[index]
		if record.id == interceptorId then
			table.remove(records, index)
			if #records == 0 then
				ACTIVE_INTERCEPTORS[player] = nil
			end
			return record
		end
	end

	return nil
end

local function disableCenterCollision(centerPiece: Instance)
	for _, part in ipairs(getBaseParts(centerPiece)) do
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
end

local function expireInterceptor(player: Player, interceptorId: string)
	local record = removeRecord(player, interceptorId)
	if not record then
		return
	end

	disableCenterCollision(record.centerPiece)

	local service = abilityService
	if service then
		service:FireEffect("InterceptorExpired", {
			player = player,
			slot = record.slot,
			abilityId = "Interceptor",
			interceptorId = record.id,
		})
	end

	task.delay(0.5, function()
		if record.folder.Parent then
			record.folder:Destroy()
		end
	end)
end

local function getInterceptPoint(payload, center: Vector3, radius: number): Vector3?
	local position = payload.position
	if typeof(position) ~= "Vector3" then
		return nil
	end

	local nextPosition = if typeof(payload.nextPosition) == "Vector3" then payload.nextPosition else position
	local sweepRadius = math.max(tonumber(payload.sweepRadius) or BombConfig.SweepRadius or 0, 0)
	local expandedRadius = radius + sweepRadius
	local fromOffset = position - center
	if fromOffset.Magnitude <= expandedRadius then
		return position
	end

	local segment = nextPosition - position
	local lengthSquared = segment:Dot(segment)
	if lengthSquared <= 0.0001 then
		return nil
	end

	local toOffset = nextPosition - center
	local a = lengthSquared
	local b = 2 * fromOffset:Dot(segment)
	local c = fromOffset:Dot(fromOffset) - expandedRadius * expandedRadius
	local discriminant = b * b - 4 * a * c
	if discriminant >= 0 then
		local root = math.sqrt(discriminant)
		local alpha = (-b - root) / (2 * a)
		if alpha >= 0 and alpha <= 1 then
			return position + segment * alpha
		end
	end

	if toOffset.Magnitude <= expandedRadius then
		return nextPosition
	end

	return nil
end

local function fireIntercept(record: InterceptorRecord, position: Vector3)
	local service = abilityService
	if not service then
		return
	end

	service:FireEffect("InterceptorIntercepted", {
		player = record.player,
		slot = record.slot,
		abilityId = "Interceptor",
		interceptorId = record.id,
		position = position,
	})
end

function Interceptor.OnStart(service: AbilityServiceLike)
	abilityService = service
end

function Interceptor.CanActivate(context: ServerActivateContext): boolean
	local template = getTemplate(context.definition)
	local centerTemplate = if template then getCenterTemplate(template) else nil
	local forceField = if template then getForceFieldTemplate(template) else nil
	return getCharacterRoot(context.player) ~= nil and centerTemplate ~= nil and forceField ~= nil
end

function Interceptor.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local template = getTemplate(context.definition)
	local centerTemplate = if template then getCenterTemplate(template) else nil
	local forceField = if template then getForceFieldTemplate(template) else nil
	if not (template and centerTemplate and forceField) then
		warn("[Interceptor] Missing ReplicatedStorage.Assets.Abilities.Interceptor.Interceptor")
		return false
	end

	local placement = validatePlacement(context.player, context.definition, centerTemplate, context.payload)
	if not placement then
		return false
	end

	local interceptorId, serial = getNextInterceptorId(context.player)
	local folder = Instance.new("Folder")
	folder.Name = interceptorId
	folder:SetAttribute(ID_ATTR, interceptorId)
	folder:SetAttribute(OWNER_ATTR, context.player.UserId)
	folder:SetAttribute("AbilityId", context.abilityId)

	local centerPiece = centerTemplate:Clone()
	centerPiece.Name = "CenterPiece"
	centerPiece:SetAttribute(ID_ATTR, interceptorId)
	centerPiece:SetAttribute(OWNER_ATTR, context.player.UserId)
	centerPiece:SetAttribute("AbilityId", context.abilityId)
	local _boundsCFrame, boundsSize = PlacementSurfaceUtil.AlignToFloor(centerPiece, placement)
	if boundsSize.X <= 0 or boundsSize.Y <= 0 or boundsSize.Z <= 0 then
		folder:Destroy()
		return false
	end
	prepareCenterPiece(centerPiece)
	centerPiece.Parent = folder
	folder.Parent = getInterceptorRootFolder(context.player)

	local durationSeconds = math.max(tonumber(context.definition.durationSeconds) or 0, 0)
	local activeEndsAt = context.now + durationSeconds
	local record: InterceptorRecord = {
		id = interceptorId,
		player = context.player,
		slot = context.slot,
		folder = folder,
		centerPiece = centerPiece,
		center = getPlacementCenter(centerPiece),
		radius = math.max(getRadiusFromForceField(forceField), 1),
		activeEndsAt = activeEndsAt,
		serial = serial,
	}

	local records = ACTIVE_INTERCEPTORS[context.player]
	if not records then
		records = {}
		ACTIVE_INTERCEPTORS[context.player] = records
	end
	table.insert(records, record)

	task.delay(durationSeconds + 0.05, function()
		expireInterceptor(context.player, interceptorId)
	end)

	local state = context.slotState.state
	local placed = if typeof(state) == "table" and typeof(state.interceptorsPlaced) == "number"
		then state.interceptorsPlaced
		else 0

	return {
		state = {
			interceptorsPlaced = placed + 1,
			lastPlacedAt = context.now,
		},
		effect = {
			name = "InterceptorPlaced",
			payload = {
				interceptorId = interceptorId,
				position = record.center,
				radius = record.radius,
				activeEndsAt = activeEndsAt,
			},
		},
	}
end

function Interceptor.OnProjectileStep(context: ServerHookContext): AbilityHookResult
	local payload = context.context
	if not (typeof(payload) == "table" and typeof(payload.projectileId) == "string") then
		return AbilityResult.Continue()
	end

	local records = ACTIVE_INTERCEPTORS[context.player]
	if not records then
		return AbilityResult.Continue()
	end

	for index = #records, 1, -1 do
		local record = records[index]
		if context.now >= record.activeEndsAt then
			expireInterceptor(context.player, record.id)
			continue
		end
		if not record.folder.Parent then
			table.remove(records, index)
			continue
		end

		local hitPosition = getInterceptPoint(payload, record.center, record.radius)
		if hitPosition then
			fireIntercept(record, hitPosition)
			return {
				kind = RESULT_KIND.DestroyProjectile,
			}
		end
	end

	if #records == 0 then
		ACTIVE_INTERCEPTORS[context.player] = nil
	end

	return AbilityResult.Continue()
end

function Interceptor.OnPlayerRemoving(player: Player)
	local records = ACTIVE_INTERCEPTORS[player]
	ACTIVE_INTERCEPTORS[player] = nil
	SERIALS[player] = nil
	if not records then
		return
	end

	for _, record in ipairs(records) do
		if record.folder.Parent then
			record.folder:Destroy()
		end
	end
end

return Interceptor
