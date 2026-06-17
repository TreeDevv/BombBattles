local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type ServerActivateContext = AbilityTypes.ServerActivateContext
type FloorPlacement = {
	position: Vector3,
	facing: Vector3,
}
type GrowthRecord = {
	part: BasePart,
	finalSize: Vector3,
	finalCFrame: CFrame,
}

local EmergencyFort = {} :: AbilityTypes.ServerBehavior

local FOLDER_NAME = "AbilityObjects"
local FORT_FOLDER_NAME = "EmergencyFort"
local OWNER_ATTR = "EmergencyFortOwnerUserId"
local ACTIVE_FORTS: { [Player]: { Instance } } = {}

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
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
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

local function pivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	else
		(instance :: BasePart).CFrame = cframe
	end
end

local function getActiveMap(): Instance?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getFortFolder(player: Player): Folder
	local parent = PracticeRangeTargeting.GetObjectParentForServer(player, getActiveMap())
	local abilityFolder = parent:FindFirstChild(FOLDER_NAME)
	if not (abilityFolder and abilityFolder:IsA("Folder")) then
		if abilityFolder then
			abilityFolder:Destroy()
		end
		abilityFolder = Instance.new("Folder")
		abilityFolder.Name = FOLDER_NAME
		abilityFolder.Parent = parent
	end

	local fortFolder = abilityFolder:FindFirstChild(FORT_FOLDER_NAME)
	if fortFolder and fortFolder:IsA("Folder") then
		return fortFolder
	end
	if fortFolder then
		fortFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = FORT_FOLDER_NAME
	folder.Parent = abilityFolder
	return folder
end

local function hasUnsafeTaggedAncestor(instance: Instance): boolean
	local current: Instance? = instance
	while current and current ~= workspace do
		for _, tagName in ipairs(UNSAFE_TAGS) do
			if CollectionService:HasTag(current, tagName) then
				return true
			end
		end
		current = current.Parent
	end
	return false
end

local function flattenDirection(direction: Vector3): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.zAxis
	end
	return flat.Unit
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

local function findFloorBelow(player: Player, rootPart: BasePart, definition: AbilityDefinition): FloorPlacement?
	local rayUp = definition.floorRaycastUp or 8
	local rayDown = definition.floorRaycastDown or 32
	local rayOrigin = rootPart.Position + Vector3.yAxis * rayUp
	local rayDirection = Vector3.new(0, -(rayUp + rayDown), 0)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character }
	params.RespectCanCollide = true

	local hit = workspace:Raycast(rayOrigin, rayDirection, params)
	if not hit then
		return nil
	end
	if hit.Normal.Y < (definition.minFloorNormalY or 0.65) then
		return nil
	end
	if hasUnsafeTaggedAncestor(hit.Instance) then
		return nil
	end

	local targetRoot = PracticeRangeTargeting.GetServerTargetRoot(player, getActiveMap())
	if not PracticeRangeTargeting.IsInTargetRoot(hit.Instance, targetRoot) then
		return nil
	end

	return {
		position = hit.Position,
		facing = flattenDirection(rootPart.CFrame.LookVector),
	}
end

local function alignCloneToFloor(clone: Instance, floorPosition: Vector3, facing: Vector3): (CFrame, Vector3)
	local pivot = CFrame.lookAt(floorPosition, floorPosition + facing)
	pivotTo(clone, pivot)

	local boundsCFrame, boundsSize = getBounds(clone)
	local bottomY = boundsCFrame.Position.Y - boundsSize.Y * 0.5
	local finalPivot = pivot + Vector3.yAxis * (floorPosition.Y - bottomY)
	pivotTo(clone, finalPivot)

	return getBounds(clone)
end

local function overlapsUnsafeTagged(boundsCFrame: CFrame, boundsSize: Vector3): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	params.RespectCanCollide = false

	for _, part in ipairs(workspace:GetPartBoundsInBox(boundsCFrame, boundsSize, params)) do
		if hasUnsafeTaggedAncestor(part) then
			return true
		end
	end
	return false
end

local function tagFort(fort: Instance)
	CollectionService:AddTag(fort, DestructionConfig.Tag)
	for _, part in ipairs(getBaseParts(fort)) do
		CollectionService:AddTag(part, DestructionConfig.Tag)
	end
end

local function untagFort(fort: Instance)
	if CollectionService:HasTag(fort, DestructionConfig.Tag) then
		CollectionService:RemoveTag(fort, DestructionConfig.Tag)
	end
	for _, part in ipairs(getBaseParts(fort)) do
		if CollectionService:HasTag(part, DestructionConfig.Tag) then
			CollectionService:RemoveTag(part, DestructionConfig.Tag)
		end
	end
end

local function applyFortHealth(fort: Instance, definition: AbilityDefinition)
	local fortHealth = math.max(tonumber(definition.fortHealth) or 300, 1)
	fort:SetAttribute(DestructionConfig.TerrainHealthAttribute, fortHealth)
	for _, part in ipairs(getBaseParts(fort)) do
		part:SetAttribute(DestructionConfig.TerrainHealthAttribute, fortHealth)
	end
end

local function tweenPart(part: BasePart, info: TweenInfo, goal)
	if not part.Parent then
		return
	end

	local tween = TweenService:Create(part, info, goal)
	tween:Play()
end

local function bounceFort(records: { GrowthRecord }, definition: AbilityDefinition)
	local scale = definition.bounceScale or 1.04
	local outInfo = TweenInfo.new(definition.bounceOutSeconds or 0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local backInfo = TweenInfo.new(definition.bounceBackSeconds or 0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	for _, record in ipairs(records) do
		if record.part.Parent then
			tweenPart(record.part, outInfo, {
				Size = record.finalSize * scale,
			})
		end
	end

	task.delay(definition.bounceOutSeconds or 0.08, function()
		for _, record in ipairs(records) do
			if record.part.Parent then
				tweenPart(record.part, backInfo, {
					Size = record.finalSize,
				})
			end
		end
	end)
end

local function fadeAndDestroy(fort: Instance, definition: AbilityDefinition)
	if not fort.Parent then
		return
	end

	untagFort(fort)
	local fadeInfo = TweenInfo.new(definition.fadeSeconds or 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	for _, part in ipairs(getBaseParts(fort)) do
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		tweenPart(part, fadeInfo, { Transparency = 1 })
	end

	task.delay(definition.fadeSeconds or 0.45, function()
		if fort.Parent then
			fort:Destroy()
		end
	end)
end

local function prepareGrowth(fort: Instance, definition: AbilityDefinition): { GrowthRecord }
	local records = {}
	local startHeight = math.max(definition.startHeight or 0.12, 0.01)

	for _, part in ipairs(getBaseParts(fort)) do
		part.Anchored = true
		part.CanCollide = true
		part.CanQuery = true
		part.CanTouch = false

		local finalSize = part.Size
		local finalCFrame = part.CFrame
		local initialHeight = math.max(math.min(startHeight, finalSize.Y), 0.01)
		local rotation = finalCFrame - finalCFrame.Position
		local bottom = finalCFrame.Position - finalCFrame.UpVector * (finalSize.Y * 0.5)
		local startPosition = bottom + finalCFrame.UpVector * (initialHeight * 0.5)

		part.Size = Vector3.new(finalSize.X, initialHeight, finalSize.Z)
		part.CFrame = rotation + startPosition

		table.insert(records, {
			part = part,
			finalSize = finalSize,
			finalCFrame = finalCFrame,
		})
	end

	return records
end

local function growFort(records: { GrowthRecord }, definition: AbilityDefinition)
	local growthInfo = TweenInfo.new(definition.growthSeconds or 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, record in ipairs(records) do
		if record.part.Parent then
			tweenPart(record.part, growthInfo, {
				Size = record.finalSize,
				CFrame = record.finalCFrame,
			})
		end
	end

	task.delay(definition.growthSeconds or 0.16, function()
		bounceFort(records, definition)
	end)
end

local function trackFort(player: Player, fort: Instance)
	local forts = ACTIVE_FORTS[player]
	if not forts then
		forts = {}
		ACTIVE_FORTS[player] = forts
	end

	table.insert(forts, fort)
	fort.AncestryChanged:Connect(function()
		if fort.Parent then
			return
		end

		local current = ACTIVE_FORTS[player]
		local index = current and table.find(current, fort)
		if index then
			table.remove(current, index)
		end
	end)
end

function EmergencyFort.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil and getTemplate(context.definition) ~= nil
end

function EmergencyFort.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local definition = context.definition
	local template = getTemplate(definition)
	if not template then
		warn("[EmergencyFort] Missing ReplicatedStorage.Assets.Abilities.EmergencyFort.Emergency Fort")
		return false
	end

	local rootPart = getCharacterRoot(context.player)
	if not rootPart then
		return false
	end

	local placement = findFloorBelow(context.player, rootPart, definition)
	if not placement then
		return false
	end

	local fort = template:Clone()
	fort.Name = "EmergencyFort_" .. context.player.UserId
	fort:SetAttribute(OWNER_ATTR, context.player.UserId)
	fort:SetAttribute("AbilityId", context.abilityId)
	local boundsCFrame, boundsSize = alignCloneToFloor(fort, placement.position, placement.facing)

	if overlapsUnsafeTagged(boundsCFrame, boundsSize) then
		fort:Destroy()
		return false
	end

	local records = prepareGrowth(fort, definition)
	applyFortHealth(fort, definition)
	tagFort(fort)
	fort.Parent = getFortFolder(context.player)
	trackFort(context.player, fort)
	growFort(records, definition)

	task.delay(definition.lifetimeSeconds or 12, function()
		fadeAndDestroy(fort, definition)
	end)

	local state = context.slotState.state
	local fortsBuilt = if typeof(state) == "table" and typeof(state.fortsBuilt) == "number" then state.fortsBuilt else 0

	return {
		state = {
			fortsBuilt = fortsBuilt + 1,
			lastBuiltAt = context.now,
		},
		effect = {
			name = "EmergencyFortCreated",
			payload = {
				position = placement.position,
			},
		},
	}
end

function EmergencyFort.OnPlayerRemoving(player: Player)
	local forts = ACTIVE_FORTS[player]
	ACTIVE_FORTS[player] = nil
	if not forts then
		return
	end

	for _, fort in ipairs(forts) do
		if fort.Parent then
			fort:Destroy()
		end
	end
end

return EmergencyFort
