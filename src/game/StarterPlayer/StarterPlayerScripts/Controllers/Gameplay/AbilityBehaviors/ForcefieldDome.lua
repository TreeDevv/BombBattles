local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientEffectContext = AbilityTypes.ClientEffectContext
type MeshRecord = {
	mesh: SpecialMesh,
	finalScale: Vector3,
	startScale: Vector3,
}
type VisualRecord = {
	instance: Instance,
	connections: { RBXScriptConnection },
}

local ForcefieldDome = {} :: AbilityTypes.ClientBehavior

local VISUAL_FOLDER_NAME = "ForcefieldDomeVisuals"
local ACTIVE_VISUALS: { [Player]: VisualRecord } = {}

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

local function pivotTo(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	else
		(instance :: BasePart).CFrame = cframe
	end
end

local function scaledVector(vector: Vector3, scale: number): Vector3
	return Vector3.new(
		math.max(vector.X * scale, 0.01),
		math.max(vector.Y * scale, 0.01),
		math.max(vector.Z * scale, 0.01)
	)
end

local function getRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	return if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

local function getVisualFolder(): Folder
	local existing = workspace:FindFirstChild(VISUAL_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = VISUAL_FOLDER_NAME
	folder.Parent = workspace
	return folder
end

local function removeAuthoredWelds(clone: Instance)
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("WeldConstraint") then
			descendant:Destroy()
		end
	end
end

local function weldPartToRoot(part: BasePart, rootPart: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "ForcefieldDomeWeld"
	weld.Part0 = rootPart
	weld.Part1 = part
	weld.Parent = part
end

local function disconnectConnections(connections: { RBXScriptConnection }?)
	for _, connection in ipairs(connections or {}) do
		connection:Disconnect()
	end
end

local function destroyVisual(player: Player)
	local record = ACTIVE_VISUALS[player]
	ACTIVE_VISUALS[player] = nil
	if record then
		disconnectConnections(record.connections)
		if record.instance.Parent then
			record.instance:Destroy()
		end
	end
end

local function bindVisualCleanup(player: Player, rootPart: BasePart, clone: Instance): { RBXScriptConnection }
	local connections = {}

	local function cleanupIfCurrent()
		local current = ACTIVE_VISUALS[player]
		if current and current.instance == clone then
			destroyVisual(player)
		end
	end

	table.insert(connections, rootPart.Destroying:Connect(cleanupIfCurrent))
	table.insert(connections, rootPart.AncestryChanged:Connect(function()
		if not rootPart:IsDescendantOf(workspace) then
			cleanupIfCurrent()
		end
	end))
	table.insert(connections, player.CharacterRemoving:Connect(function(character)
		if rootPart:IsDescendantOf(character) then
			cleanupIfCurrent()
		end
	end))
	table.insert(connections, player.AncestryChanged:Connect(function()
		if not player:IsDescendantOf(Players) then
			cleanupIfCurrent()
		end
	end))

	return connections
end

local function tweenParts(records, tweenInfo: TweenInfo, transparency: number, shrink: boolean)
	for _, record in ipairs(records) do
		local part = record.part
		if part.Parent then
			local goal = {
				Transparency = transparency,
				Size = if shrink then record.startSize else record.finalSize,
			}
			TweenService:Create(part, tweenInfo, goal):Play()
		end

		for _, meshRecord in ipairs(record.meshRecords) do
			local mesh = meshRecord.mesh
			if mesh.Parent then
				TweenService:Create(mesh, tweenInfo, {
					Scale = if shrink then meshRecord.startScale else meshRecord.finalScale,
				}):Play()
			end
		end
	end
end

local function playVisual(player: Player, definition: AbilityDefinition, activeEndsAt: number)
	destroyVisual(player)

	local rootPart = getRootPart(player)
	local template = getTemplate(definition)
	if not (rootPart and template) then
		return
	end

	local clone = template:Clone()
	clone.Name = "ForcefieldDome_" .. tostring(player.UserId)
	local visualParts = getBaseParts(clone)
	if #visualParts == 0 then
		clone:Destroy()
		return
	end

	pivotTo(clone, rootPart.CFrame)
	removeAuthoredWelds(clone)

	local startScale = math.clamp(tonumber(definition.startScale) or 0.01, 0.001, 1)
	local records = {}
	for _, part in ipairs(visualParts) do
		local finalSize = part.Size
		local finalTransparency = part.Transparency
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.Transparency = 1
		part.Size = scaledVector(finalSize, startScale)
		weldPartToRoot(part, rootPart)

		local meshRecords = {}
		for _, child in ipairs(part:GetChildren()) do
			if child:IsA("SpecialMesh") then
				local finalScale = child.Scale
				local meshStartScale = scaledVector(finalScale, startScale)
				child.Scale = meshStartScale
				table.insert(meshRecords, {
					mesh = child,
					finalScale = finalScale,
					startScale = meshStartScale,
				})
			end
		end

		table.insert(records, {
			part = part,
			finalSize = finalSize,
			startSize = part.Size,
			finalTransparency = finalTransparency,
			meshRecords = meshRecords,
		})
	end

	clone.Parent = getVisualFolder()
	ACTIVE_VISUALS[player] = {
		instance = clone,
		connections = bindVisualCleanup(player, rootPart, clone),
	}

	local fadeInSeconds = math.max(tonumber(definition.fadeInSeconds) or 0.18, 0.01)
	local growthSeconds = math.max(tonumber(definition.growthSeconds) or fadeInSeconds, 0.01)
	local inInfo = TweenInfo.new(math.max(fadeInSeconds, growthSeconds), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, record in ipairs(records) do
		if record.part.Parent then
			TweenService:Create(record.part, inInfo, {
				Size = record.finalSize,
				Transparency = record.finalTransparency,
			}):Play()
		end
		for _, meshRecord in ipairs(record.meshRecords) do
			local mesh = meshRecord.mesh
			if mesh.Parent then
				TweenService:Create(mesh, inInfo, {
					Scale = meshRecord.finalScale,
				}):Play()
			end
		end
	end

	local fadeOutSeconds = math.max(tonumber(definition.fadeOutSeconds) or 0.25, 0.01)
	local delaySeconds = math.max(activeEndsAt - workspace:GetServerTimeNow() - fadeOutSeconds, 0)
	task.delay(delaySeconds, function()
		local activeRecord = ACTIVE_VISUALS[player]
		if not activeRecord or activeRecord.instance ~= clone or not clone.Parent then
			return
		end

		local outInfo = TweenInfo.new(fadeOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tweenParts(records, outInfo, 1, true)
		task.delay(fadeOutSeconds, function()
			local current = ACTIVE_VISUALS[player]
			if current and current.instance == clone then
				destroyVisual(player)
			elseif clone.Parent then
				clone:Destroy()
			end
		end)
	end)
end

function ForcefieldDome.OnEffect(context: ClientEffectContext)
	if context.effectName ~= "Activated" then
		return
	end

	local payload = context.payload
	local player = payload and payload.player
	if not (typeof(player) == "Instance" and player:IsA("Player")) then
		return
	end

	local definition = AbilityConfig.GetDefinition("ForcefieldDome")
	if not definition then
		return
	end

	local activeEndsAt = if typeof(payload.activeEndsAt) == "number" and payload.activeEndsAt > 0
		then payload.activeEndsAt
		else workspace:GetServerTimeNow() + (definition.durationSeconds or 5)

	playVisual(player, definition, activeEndsAt)
end

return ForcefieldDome
