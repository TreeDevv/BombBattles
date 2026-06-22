local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local PlacementSurfaceUtil = require(ReplicatedStorage.Shared.Common.PlacementSurfaceUtil)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local DestructionConfig = require(ReplicatedStorage.Shared.Config.DestructionConfig)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type ServerActivateContext = AbilityTypes.ServerActivateContext
type FloorPlacement = {
	position: Vector3,
	facing: Vector3,
	normal: Vector3,
	floor: Instance,
}

local WallBuilder = {} :: AbilityTypes.ServerBehavior

local FOLDER_NAME = "AbilityObjects"
local WALL_FOLDER_NAME = "WallBuilder"
local OWNER_ATTR = "WallBuilderOwnerUserId"
local ACTIVE_WALLS: { [Player]: { Instance } } = {}

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

local function getActiveMap(): Instance?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getWallFolder(player: Player): Folder
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

	local wallFolder = abilityFolder:FindFirstChild(WALL_FOLDER_NAME)
	if wallFolder and wallFolder:IsA("Folder") then
		return wallFolder
	end
	if wallFolder then
		wallFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = WALL_FOLDER_NAME
	folder.Parent = abilityFolder
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

local function validatePlacement(player: Player, definition: AbilityDefinition, template: Instance, payload: any): FloorPlacement?
	local _ = template
	local rootPart = getCharacterRoot(player)
	if not rootPart then
		return nil
	end

	return PlacementSurfaceUtil.ResolveForwardOffsetPlacement({
		rootPart = rootPart,
		definition = definition,
		payload = payload,
	})
end

local function addHighlight(wall: Instance): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = "WallBuilderHighlight"
	highlight.Adornee = wall
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.92
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.OutlineTransparency = 0
	highlight.Parent = wall
	return highlight
end

local function tagWall(wall: Instance)
	if not CollectionService:HasTag(wall, DestructionConfig.Tag) then
		CollectionService:AddTag(wall, DestructionConfig.Tag)
	end
end

local function untagWall(wall: Instance)
	if CollectionService:HasTag(wall, DestructionConfig.Tag) then
		CollectionService:RemoveTag(wall, DestructionConfig.Tag)
	end
	for _, part in ipairs(getBaseParts(wall)) do
		if CollectionService:HasTag(part, DestructionConfig.Tag) then
			CollectionService:RemoveTag(part, DestructionConfig.Tag)
		end
	end
end

local function tweenPart(part: BasePart, info: TweenInfo, goal)
	if not part.Parent then
		return
	end

	local tween = TweenService:Create(part, info, goal)
	tween:Play()
end

local function bounceWall(records, definition)
	local scale = definition.bounceScale or 1.05
	local outInfo = TweenInfo.new(definition.bounceOutSeconds or 0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local backInfo = TweenInfo.new(definition.bounceBackSeconds or 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	for _, record in ipairs(records) do
		if record.part.Parent then
			tweenPart(record.part, outInfo, {
				Size = record.finalSize * scale,
			})
		end
	end

	task.delay(definition.bounceOutSeconds or 0.09, function()
		for _, record in ipairs(records) do
			if record.part.Parent then
				tweenPart(record.part, backInfo, {
					Size = record.finalSize,
				})
			end
		end
	end)
end

local function fadeAndDestroy(wall: Instance, highlight: Highlight?, definition)
	if not wall.Parent then
		return
	end

	untagWall(wall)
	local fadeInfo = TweenInfo.new(definition.fadeSeconds or 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	for _, part in ipairs(getBaseParts(wall)) do
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		tweenPart(part, fadeInfo, { Transparency = 1 })
	end

	if highlight and highlight.Parent then
		TweenService:Create(highlight, fadeInfo, {
			FillTransparency = 1,
			OutlineTransparency = 1,
		}):Play()
	end

	task.delay(definition.fadeSeconds or 0.45, function()
		if wall.Parent then
			wall:Destroy()
		end
	end)
end

local function prepareGrowth(wall: Instance, definition)
	local records = {}
	local startHeight = math.max(definition.startHeight or 0.1, 0.01)

	for _, part in ipairs(getBaseParts(wall)) do
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

local function growWall(records, definition)
	local growthInfo = TweenInfo.new(definition.growthSeconds or 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, record in ipairs(records) do
		if record.part.Parent then
			tweenPart(record.part, growthInfo, {
				Size = record.finalSize,
				CFrame = record.finalCFrame,
			})
		end
	end

	task.delay(definition.growthSeconds or 0.35, function()
		bounceWall(records, definition)
	end)
end

local function trackWall(player: Player, wall: Instance)
	local walls = ACTIVE_WALLS[player]
	if not walls then
		walls = {}
		ACTIVE_WALLS[player] = walls
	end

	table.insert(walls, wall)
	wall.AncestryChanged:Connect(function()
		if wall.Parent then
			return
		end

		local current = ACTIVE_WALLS[player]
		local index = current and table.find(current, wall)
		if index then
			table.remove(current, index)
		end
	end)
end

function WallBuilder.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local definition = context.definition
	local template = getTemplate(definition)
	if not template then
		warn("[WallBuilder] Missing ReplicatedStorage.Assets.Abilities.WallBuilder.Wall")
		return false
	end

	local placement = validatePlacement(context.player, definition, template, context.payload)
	if not placement then
		return false
	end

	local wall = template:Clone()
	wall.Name = "WallBuilder_" .. context.player.UserId
	wall:SetAttribute(OWNER_ATTR, context.player.UserId)
	wall:SetAttribute("AbilityId", context.abilityId)
	PlacementSurfaceUtil.PivotTo(wall, PlacementSurfaceUtil.GetFloorPivot(placement.position, placement.facing, placement.normal))

	local records = prepareGrowth(wall, definition)
	local highlight = addHighlight(wall)
	tagWall(wall)
	wall.Parent = getWallFolder(context.player)
	trackWall(context.player, wall)
	growWall(records, definition)

	task.delay(definition.lifetimeSeconds or 25, function()
		fadeAndDestroy(wall, highlight, definition)
	end)

	local state = context.slotState.state
	local wallCount = if typeof(state) == "table" and typeof(state.wallCount) == "number" then state.wallCount else 0

	return {
		state = {
			wallCount = wallCount + 1,
			lastPlacedAt = context.now,
		},
		effect = {
			name = "WallBuilderPlaced",
			payload = {
				position = placement.position,
			},
		},
	}
end

function WallBuilder.OnPlayerRemoving(player: Player)
	local walls = ACTIVE_WALLS[player]
	ACTIVE_WALLS[player] = nil
	if not walls then
		return
	end

	for _, wall in ipairs(walls) do
		if wall.Parent then
			wall:Destroy()
		end
	end
end

return WallBuilder
