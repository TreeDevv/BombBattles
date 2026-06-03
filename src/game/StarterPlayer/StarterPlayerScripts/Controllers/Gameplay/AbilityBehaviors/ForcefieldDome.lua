local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)

local ForcefieldDome = {}

local VISUAL_FOLDER_NAME = "ForcefieldDomeVisuals"
local ACTIVE_VISUALS: { [Player]: Instance } = {}

local function getByPath(root: Instance, path): Instance?
	local current: Instance? = root
	for _, name in ipairs(path) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getTemplate(definition): Instance?
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

local function getPrimaryVisualPart(clone: Instance): BasePart?
	if clone:IsA("Model") and clone.PrimaryPart then
		return clone.PrimaryPart
	end
	if clone:IsA("BasePart") then
		return clone
	end
	return clone:FindFirstChildWhichIsA("BasePart", true)
end

local function attachToRoot(clone: Instance, rootPart: BasePart)
	local visualPart = getPrimaryVisualPart(clone)
	if not visualPart then
		return false
	end

	pivotTo(clone, rootPart.CFrame)

	for _, weld in ipairs(clone:GetDescendants()) do
		if weld:IsA("WeldConstraint") then
			weld.Part0 = rootPart
			if not weld.Part1 then
				weld.Part1 = visualPart
			end
			weld.Enabled = true
		end
	end

	return true
end

local function destroyVisual(player: Player)
	local visual = ACTIVE_VISUALS[player]
	ACTIVE_VISUALS[player] = nil
	if visual and visual.Parent then
		visual:Destroy()
	end
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
	end
end

local function playVisual(player: Player, definition, activeEndsAt: number)
	destroyVisual(player)

	local rootPart = getRootPart(player)
	local template = getTemplate(definition)
	if not (rootPart and template) then
		return
	end

	local clone = template:Clone()
	clone.Name = "ForcefieldDome_" .. tostring(player.UserId)
	if not attachToRoot(clone, rootPart) then
		clone:Destroy()
		return
	end

	local startScale = math.clamp(tonumber(definition.startScale) or 0.01, 0.001, 1)
	local records = {}
	for _, part in ipairs(getBaseParts(clone)) do
		local finalSize = part.Size
		local finalTransparency = part.Transparency
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.Transparency = 1
		part.Size = Vector3.new(
			math.max(finalSize.X * startScale, 0.01),
			math.max(finalSize.Y * startScale, 0.01),
			math.max(finalSize.Z * startScale, 0.01)
		)
		table.insert(records, {
			part = part,
			finalSize = finalSize,
			startSize = part.Size,
			finalTransparency = finalTransparency,
		})
	end

	clone.Parent = getVisualFolder()
	ACTIVE_VISUALS[player] = clone

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
	end

	local fadeOutSeconds = math.max(tonumber(definition.fadeOutSeconds) or 0.25, 0.01)
	local delaySeconds = math.max(activeEndsAt - workspace:GetServerTimeNow() - fadeOutSeconds, 0)
	task.delay(delaySeconds, function()
		if ACTIVE_VISUALS[player] ~= clone or not clone.Parent then
			return
		end

		local outInfo = TweenInfo.new(fadeOutSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tweenParts(records, outInfo, 1, true)
		task.delay(fadeOutSeconds, function()
			if ACTIVE_VISUALS[player] == clone then
				destroyVisual(player)
			elseif clone.Parent then
				clone:Destroy()
			end
		end)
	end)
end

function ForcefieldDome.OnEffect(context)
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
