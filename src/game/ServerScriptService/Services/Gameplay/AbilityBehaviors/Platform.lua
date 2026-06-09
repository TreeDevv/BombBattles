local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

type AbilityActivationResult = AbilityTypes.AbilityActivationResult
type AbilityDefinition = AbilityTypes.AbilityDefinition
type ServerActivateContext = AbilityTypes.ServerActivateContext

local Platform = {} :: AbilityTypes.ServerBehavior

local FOLDER_NAME = "AbilityObjects"
local PLATFORM_FOLDER_NAME = "Platform"
local OWNER_ATTR = "PlatformOwnerUserId"
local ACTIVE_PLATFORMS: { [Player]: BasePart } = {}

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

local function getActiveMap(): Instance?
	local map = workspace:FindFirstChild(RoundConfig.ActiveMapName)
	return if map and map:IsA("Model") then map else nil
end

local function getPlatformFolder(): Folder
	local parent = getActiveMap() or workspace
	local abilityFolder = parent:FindFirstChild(FOLDER_NAME)
	if not (abilityFolder and abilityFolder:IsA("Folder")) then
		if abilityFolder then
			abilityFolder:Destroy()
		end
		abilityFolder = Instance.new("Folder")
		abilityFolder.Name = FOLDER_NAME
		abilityFolder.Parent = parent
	end

	local platformFolder = abilityFolder:FindFirstChild(PLATFORM_FOLDER_NAME)
	if platformFolder and platformFolder:IsA("Folder") then
		return platformFolder
	end
	if platformFolder then
		platformFolder:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = PLATFORM_FOLDER_NAME
	folder.Parent = abilityFolder
	return folder
end

local function getVector3(definition: AbilityDefinition, key: string, fallback: Vector3): Vector3
	local value = definition[key]
	return if typeof(value) == "Vector3" then value else fallback
end

local function getNumber(definition: AbilityDefinition, key: string, fallback: number): number
	local value = definition[key]
	return if typeof(value) == "number" then value else fallback
end

local function getColor(definition: AbilityDefinition, key: string, fallback: Color3): Color3
	local value = definition[key]
	return if typeof(value) == "Color3" then value else fallback
end

local function addHighlight(part: BasePart, definition: AbilityDefinition): Highlight
	local highlight = Instance.new("Highlight")
	highlight.Name = "PlatformHighlight"
	highlight.Adornee = part
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = getColor(definition, "topColor", Color3.new(1, 1, 1))
	highlight.FillTransparency = 0.94
	highlight.OutlineColor = getColor(definition, "topColor", Color3.new(1, 1, 1))
	highlight.OutlineTransparency = 0.08
	highlight.Parent = part
	return highlight
end

local function getYawCFrame(rootPart: BasePart, position: Vector3): CFrame
	local look = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, position + look.Unit)
end

local function tweenPart(part: BasePart, info: TweenInfo, goal)
	if not part.Parent then
		return
	end

	local tween = TweenService:Create(part, info, goal)
	tween:Play()
end

local function fadeAndDestroy(player: Player, part: BasePart, highlight: Highlight?, definition: AbilityDefinition)
	if not part.Parent then
		return
	end

	if ACTIVE_PLATFORMS[player] == part then
		ACTIVE_PLATFORMS[player] = nil
	end

	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false

	local fadeSeconds = math.max(getNumber(definition, "fadeSeconds", 0.35), 0.01)
	local fadeInfo = TweenInfo.new(fadeSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tweenPart(part, fadeInfo, { Transparency = 1 })

	if highlight and highlight.Parent then
		TweenService:Create(highlight, fadeInfo, {
			FillTransparency = 1,
			OutlineTransparency = 1,
		}):Play()
	end

	task.delay(fadeSeconds, function()
		if part.Parent then
			part:Destroy()
		end
	end)
end

local function prepareGrowth(part: BasePart, definition: AbilityDefinition)
	local finalSize = part.Size
	local finalCFrame = part.CFrame
	local finalTransparency = part.Transparency
	local startHeight = math.max(math.min(getNumber(definition, "startHeight", 0.08), finalSize.Y), 0.01)
	local bottom = finalCFrame.Position - finalCFrame.UpVector * (finalSize.Y * 0.5)
	local startPosition = bottom + finalCFrame.UpVector * (startHeight * 0.5)

	part.Size = Vector3.new(finalSize.X, startHeight, finalSize.Z)
	part.CFrame = (finalCFrame - finalCFrame.Position) + startPosition
	part.Transparency = 1

	return {
		finalSize = finalSize,
		finalCFrame = finalCFrame,
		finalTransparency = finalTransparency,
	}
end

local function growPlatform(part: BasePart, record, definition: AbilityDefinition)
	local growthSeconds = math.max(getNumber(definition, "growthSeconds", 0.18), 0.01)
	local growthInfo = TweenInfo.new(growthSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	tweenPart(part, growthInfo, {
		Size = record.finalSize,
		CFrame = record.finalCFrame,
		Transparency = record.finalTransparency,
	})

	task.delay(growthSeconds, function()
		if not part.Parent then
			return
		end

		local scale = getNumber(definition, "bounceScale", 1.04)
		local outSeconds = math.max(getNumber(definition, "bounceOutSeconds", 0.08), 0.01)
		local backSeconds = math.max(getNumber(definition, "bounceBackSeconds", 0.11), 0.01)
		tweenPart(part, TweenInfo.new(outSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = record.finalSize * scale,
		})
		task.delay(outSeconds, function()
			tweenPart(part, TweenInfo.new(backSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Size = record.finalSize,
			})
		end)
	end)
end

local function destroyActivePlatform(player: Player)
	local active = ACTIVE_PLATFORMS[player]
	ACTIVE_PLATFORMS[player] = nil
	if active and active.Parent then
		active:Destroy()
	end
end

local function createPlatform(context: ServerActivateContext, rootPart: BasePart): BasePart
	local definition = context.definition
	local size = getVector3(definition, "platformSize", Vector3.new(7, 1, 7))
	local offset = getNumber(definition, "verticalOffset", 3.5)
	local position = rootPart.Position - Vector3.yAxis * offset

	local part = Instance.new("Part")
	part.Name = "Platform_" .. context.player.UserId
	part:SetAttribute(OWNER_ATTR, context.player.UserId)
	part:SetAttribute("AbilityId", context.abilityId)
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = getColor(definition, "color", Color3.fromRGB(96, 222, 255))
	part.Transparency = math.clamp(getNumber(definition, "transparency", 0.12), 0, 1)
	part.Size = Vector3.new(math.max(size.X, 0.1), math.max(size.Y, 0.1), math.max(size.Z, 0.1))
	part.CFrame = getYawCFrame(rootPart, position)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	return part
end

function Platform.CanActivate(context: ServerActivateContext): boolean
	return getCharacterRoot(context.player) ~= nil
end

function Platform.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local rootPart = getCharacterRoot(context.player)
	if not rootPart then
		return false
	end

	destroyActivePlatform(context.player)

	local platform = createPlatform(context, rootPart)
	local highlight = addHighlight(platform, context.definition)
	local growthRecord = prepareGrowth(platform, context.definition)
	platform.Parent = getPlatformFolder()
	ACTIVE_PLATFORMS[context.player] = platform
	growPlatform(platform, growthRecord, context.definition)

	platform.AncestryChanged:Connect(function()
		if platform.Parent then
			return
		end
		if ACTIVE_PLATFORMS[context.player] == platform then
			ACTIVE_PLATFORMS[context.player] = nil
		end
	end)

	task.delay(math.max(getNumber(context.definition, "lifetimeSeconds", 8), 0), function()
		if platform.Parent then
			fadeAndDestroy(context.player, platform, highlight, context.definition)
		end
	end)

	local state = context.slotState.state
	local platformCount = if typeof(state) == "table" and typeof(state.platformCount) == "number"
		then state.platformCount
		else 0

	return {
		state = {
			platformCount = platformCount + 1,
			lastPlacedAt = context.now,
		},
		effect = {
			name = "PlatformPlaced",
			payload = {
				position = platform.Position,
			},
		},
	}
end

function Platform.OnPlayerRemoving(player: Player)
	destroyActivePlatform(player)
end

return Platform
