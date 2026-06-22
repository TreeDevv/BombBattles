local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AbilityBehaviorServices = require(ServerScriptService.Services.AbilityBehaviorServices)
local TweenService = game:GetService("TweenService")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local PlacementSurfaceUtil = require(ReplicatedStorage.Shared.Common.PlacementSurfaceUtil)
local PracticeRangeTargeting = require(ReplicatedStorage.Shared.Common.PracticeRangeTargeting)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)
local RoundService = require(ServerScriptService.Services.RoundService)
local StudioAICombatants = require(ServerScriptService.Services.StudioAICombatants)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type ServerActivateContext = AbilityTypes.ServerActivateContext

type FloorPlacement = {
	position: Vector3,
	facing: Vector3,
	normal: Vector3,
	floor: Instance?,
}

type MineRecord = {
	player: Player,
	mine: Instance,
	triggered: boolean,
}

local MineBomb = {} :: AbilityTypes.ServerBehavior

local FOLDER_NAME = "AbilityObjects"
local MINE_FOLDER_NAME = "MineBomb"
local OWNER_ATTR = "MineBombOwnerUserId"
local ACTIVE_MINES: { [Player]: { MineRecord } } = {}

local UNSAFE_TAGS = {
	RoundConfig.Tags.TeamCore,
	RoundConfig.Tags.TeamSpawn,
	RoundConfig.Tags.LobbySpawn,
}

local function getBombService()
	return AbilityBehaviorServices.GetBombService()
end

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

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

local function getPlacementExcludes(player: Player): { Instance }
	local excluded = {}
	if player.Character then
		table.insert(excluded, player.Character)
	end
	local abilityFolder = workspace:FindFirstChild(FOLDER_NAME, true)
	if abilityFolder then
		table.insert(excluded, abilityFolder)
	end
	return excluded
end

local function getMineFolder(player: Player): Folder
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

	local mineFolder = abilityFolder:FindFirstChild(MINE_FOLDER_NAME)
	if mineFolder and mineFolder:IsA("Folder") then
		return mineFolder
	end
	if mineFolder then
		mineFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = MINE_FOLDER_NAME
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

local function isOwnerActive(player: Player): boolean
	return player.Parent == Players
		and CombatEligibility.IsCombatActive(player, RoundService)
		and CombatEligibility.HasAliveCharacter(player)
end

local function findFloor(player: Player, rootPart: BasePart, definition: AbilityDefinition, payload: any): FloorPlacement?
	return PlacementSurfaceUtil.ResolveFloorPlacement({
		rootPart = rootPart,
		definition = definition,
		payload = payload,
		excludeInstances = getPlacementExcludes(player),
		useRootPosition = typeof(payload) ~= "table",
	})
end

local function getFloorPivot(floorPosition: Vector3, facing: Vector3, normal: Vector3): CFrame
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

local function alignCloneToFloor(
	clone: Instance,
	floorPosition: Vector3,
	facing: Vector3,
	normal: Vector3
): (CFrame, Vector3)
	local pivot = getFloorPivot(floorPosition, facing, normal)
	pivotTo(clone, pivot)

	local boundsCFrame, boundsSize = getBounds(clone)
	local bottomOffset = (boundsCFrame.Position - floorPosition):Dot(pivot.UpVector) - boundsSize.Y * 0.5
	local finalPivot = pivot - pivot.UpVector * bottomOffset
	pivotTo(clone, finalPivot)

	return getBounds(clone)
end

local function isProtectedOrCharacter(part: BasePart, ignoredCharacter: Model?): boolean
	if hasUnsafeTaggedAncestor(part) then
		return true
	end

	local model = part:FindFirstAncestorOfClass("Model")
	if model and model == ignoredCharacter then
		return false
	end
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local function isPlacementClear(
	boundsCFrame: CFrame,
	boundsSize: Vector3,
	floor: Instance,
	ignoredCharacter: Model?
): boolean
	local up = boundsCFrame.UpVector
	local overlapSize = Vector3.new(
		math.max(boundsSize.X * 0.95, 0.1),
		math.max(boundsSize.Y - 0.25, 0.1),
		math.max(boundsSize.Z * 0.95, 0.1)
	)
	local overlapCFrame = boundsCFrame + up * 0.18

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if ignoredCharacter then { ignoredCharacter } else {}
	params.RespectCanCollide = true

	for _, part in ipairs(workspace:GetPartBoundsInBox(overlapCFrame, overlapSize, params)) do
		if part == floor or part:IsDescendantOf(floor) then
			continue
		end
		if isProtectedOrCharacter(part, ignoredCharacter) then
			return false
		end
		if part.CanCollide and part.Transparency < 1 then
			return false
		end
	end

	return true
end

local function stripScripts(instance: Instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		end
	end
end

local function validatePlacement(player: Player, definition: AbilityDefinition, template: Instance, payload: any): FloorPlacement?
	local rootPart = getCharacterRoot(player)
	if not rootPart then
		return nil
	end

	local floor = findFloor(player, rootPart, definition, payload)
	if not floor then
		return nil
	end

	local clone = template:Clone()
	stripScripts(clone)
	local boundsCFrame, boundsSize = alignCloneToFloor(clone, floor.position, floor.facing, floor.normal)
	clone:Destroy()

	if boundsSize.X <= 0 or boundsSize.Y <= 0 or boundsSize.Z <= 0 then
		return nil
	end

	return floor
end

local function addLegendaryEffects(mine: Instance, definition: AbilityDefinition): Highlight
	local fillColor = getDefinitionColor(definition, "legendaryFillColor", Color3.fromRGB(255, 210, 76))
	local outlineColor = getDefinitionColor(definition, "legendaryOutlineColor", Color3.fromRGB(178, 92, 255))

	local highlight = Instance.new("Highlight")
	highlight.Name = "MineBombLegendaryHighlight"
	highlight.Adornee = mine
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = fillColor
	highlight.FillTransparency = 0.86
	highlight.OutlineColor = outlineColor
	highlight.OutlineTransparency = 0.22
	highlight.Parent = mine

	local boundsCFrame, boundsSize = getBounds(mine)
	local lightPart = Instance.new("Part")
	lightPart.Name = "MineBombLegendaryLight"
	lightPart.Anchored = true
	lightPart.CanCollide = false
	lightPart.CanQuery = false
	lightPart.CanTouch = false
	lightPart.Transparency = 1
	lightPart.Size = Vector3.new(0.2, 0.2, 0.2)
	lightPart.CFrame = boundsCFrame + Vector3.yAxis * math.max(boundsSize.Y * 0.5, 0.25)
	lightPart.Parent = mine

	local light = Instance.new("PointLight")
	light.Name = "LegendaryGlow"
	light.Color = fillColor
	light.Range = 9
	light.Brightness = 0.8
	light.Shadows = false
	light.Parent = lightPart

	return highlight
end

local function prepareMine(mine: Instance, definition: AbilityDefinition)
	stripScripts(mine)
	local placedTransparency = math.clamp(getDefinitionNumber(definition, "placedTransparency", 0.35), 0, 1)
	for _, part in ipairs(getBaseParts(mine)) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		if part.Transparency < 1 then
			part.Transparency = placedTransparency
		end
	end
	addLegendaryEffects(mine, definition)
end

local function getTeamName(player: Player): string?
	local teamName = player:GetAttribute("RoundTeam")
	return if typeof(teamName) == "string" and teamName ~= "" then teamName else nil
end

local function isEnemyPlayer(owner: Player, target: Player?): boolean
	if not target or target == owner then
		return false
	end
	if target.Parent ~= Players or not CombatEligibility.IsCombatActive(target, RoundService) then
		return false
	end

	local ownerTeam = getTeamName(owner)
	local targetTeam = getTeamName(target)
	return not (ownerTeam and targetTeam and ownerTeam == targetTeam)
end

local function hasEnemyStudioAIInRadius(owner: Player, center: Vector3, radius: number): boolean
	local ownerTeam = getTeamName(owner)
	for _, bot in ipairs(StudioAICombatants.GetAliveBots({
		enemyOfTeam = ownerTeam,
		excludeUserId = owner.UserId,
	})) do
		local rootPart = bot.rootPart
		if typeof(rootPart) == "Instance" and rootPart:IsA("BasePart") and (rootPart.Position - center).Magnitude <= radius then
			return true
		end
	end
	return false
end

local function hasEnemyInRadius(owner: Player, mine: Instance, radius: number): boolean
	local center = getBounds(mine).Position
	if hasEnemyStudioAIInRadius(owner, center, radius) then
		return true
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { mine }

	for _, part in ipairs(workspace:GetPartBoundsInRadius(center, radius, params)) do
		local model = part:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		if not (humanoid and humanoid.Health > 0) then
			continue
		end

		local target = Players:GetPlayerFromCharacter(model)
		if isEnemyPlayer(owner, target) then
			return true
		end
	end

	return false
end

local function removeRecord(record: MineRecord)
	local mines = ACTIVE_MINES[record.player]
	local index = mines and table.find(mines, record)
	if index then
		table.remove(mines, index)
	end
end

local function destroyMine(record: MineRecord)
	removeRecord(record)
	if record.mine.Parent then
		record.mine:Destroy()
	end
end

local function playMineSound(mine: Instance)
	local sound = mine:FindFirstChildWhichIsA("Sound", true)
	if sound then
		sound:Play()
	end
end

local function triggerMine(record: MineRecord, definition: AbilityDefinition)
	if record.triggered or not record.mine.Parent then
		return
	end
	record.triggered = true

	playMineSound(record.mine)

	local startCFrame = getBounds(record.mine)
	local duration = math.max(getDefinitionNumber(definition, "triggerBounceSeconds", 0.8), 0.05)
	local height = math.max(getDefinitionNumber(definition, "triggerBounceHeight", 7), 0)
	local targetValue = Instance.new("CFrameValue")
	targetValue.Value = startCFrame
	local connection = targetValue:GetPropertyChangedSignal("Value"):Connect(function()
		if record.mine.Parent then
			pivotTo(record.mine, targetValue.Value)
		end
	end)

	local tween = TweenService:Create(
		targetValue,
		TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Value = startCFrame + Vector3.yAxis * height }
	)
	tween:Play()

	task.delay(duration, function()
		connection:Disconnect()
		targetValue:Destroy()
		if not record.mine.Parent then
			return
		end
		if not isOwnerActive(record.player) then
			destroyMine(record)
			return
		end

		local explodePosition = getBounds(record.mine).Position
		destroyMine(record)
		local service = getBombService()
		if service and type(service.ExplodeAbility) == "function" then
			service:ExplodeAbility(record.player, explodePosition, "MineBomb", BombSkinConfig.DefaultSkinId, {
				abilityId = "MineBomb",
			})
		end
	end)
end

local function trackMine(record: MineRecord, definition: AbilityDefinition)
	local mines = ACTIVE_MINES[record.player]
	if not mines then
		mines = {}
		ACTIVE_MINES[record.player] = mines
	end
	table.insert(mines, record)

	record.mine.AncestryChanged:Connect(function()
		if not record.mine.Parent then
			removeRecord(record)
		end
	end)

	local radius = math.max(getDefinitionNumber(definition, "triggerRadius", 6), 0.5)
	local checkSeconds = math.max(getDefinitionNumber(definition, "triggerCheckSeconds", 0.1), 0.05)
	task.spawn(function()
		while record.mine.Parent and record.player.Parent == Players and not record.triggered do
			if not isOwnerActive(record.player) then
				destroyMine(record)
				break
			end
			if hasEnemyInRadius(record.player, record.mine, radius) then
				triggerMine(record, definition)
				break
			end
			task.wait(checkSeconds)
		end
	end)

	task.delay(math.max(getDefinitionNumber(definition, "mineLifetimeSeconds", 45), 1), function()
		if record.mine.Parent and not record.triggered then
			destroyMine(record)
		end
	end)
end

function MineBomb.CanActivate(context: ServerActivateContext): boolean
	return isOwnerActive(context.player) and getCharacterRoot(context.player) ~= nil
end

function MineBomb.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local definition = context.definition
	local template = getTemplate(definition)
	if not template then
		warn("[MineBomb] Missing ReplicatedStorage.Assets.Abilities.MineBomb.Landmine")
		return false
	end

	local placement = validatePlacement(context.player, definition, template, context.payload)
	if not placement then
		return false
	end

	local mine = template:Clone()
	mine.Name = "MineBomb_" .. context.player.UserId
	mine:SetAttribute(OWNER_ATTR, context.player.UserId)
	mine:SetAttribute("AbilityId", context.abilityId)
	alignCloneToFloor(mine, placement.position, placement.facing, placement.normal)
	prepareMine(mine, definition)
	mine.Parent = getMineFolder(context.player)

	local record = {
		player = context.player,
		mine = mine,
		triggered = false,
	}
	trackMine(record, definition)

	local state = context.slotState.state
	local minesPlaced = if typeof(state) == "table" and typeof(state.minesPlaced) == "number"
		then state.minesPlaced
		else 0
	return {
		state = {
			minesPlaced = minesPlaced + 1,
			lastPlacedAt = context.now,
		},
		effect = {
			name = "MineBombPlaced",
			payload = {
				position = placement.position,
			},
		},
	}
end

function MineBomb.OnPlayerRemoving(player: Player)
	local mines = ACTIVE_MINES[player]
	ACTIVE_MINES[player] = nil
	if not mines then
		return
	end

	for _, record in ipairs(mines) do
		if record.mine.Parent then
			record.mine:Destroy()
		end
	end
end

return MineBomb
