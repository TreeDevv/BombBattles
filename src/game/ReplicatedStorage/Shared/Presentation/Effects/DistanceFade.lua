--[[
	Client-side distance fade surface effect.

	This is the Rojo-owned copy of the former Workspace.HexagonBarrier.Hexagon.DistanceFade
	module. It preserves the same public API while guarding character/root lookups so respawns
	and deaths do not throw from Step().
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DistanceFade = {}
DistanceFade.__index = DistanceFade

local DEFAULT_SETTINGS = {
	DistanceOuter = 16,
	DistanceInner = 4,
	EffectRadius = 16,
	EffectRadiusMin = 0,
	EdgeDistanceCalculations = false,
	Texture = "rbxassetid://18838056070",
	TextureTransparency = 0,
	TextureTransparencyMin = 1,
	BackgroundTransparency = 1,
	BackgroundTransparencyMin = 1,
	TextureColor = Color3.fromRGB(255, 255, 255),
	BackgroundColor = Color3.fromRGB(255, 255, 255),
	TextureSize = Vector2.new(8, 8),
	TextureOffset = Vector2.new(0, 0),
	ZOffset = 0,
	AlwaysOnTop = false,
	Brightness = 1,
	LightInfluence = 0,
	MaxDistance = 1000,
	PixelsPerStud = 100,
	SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
}

type FaceInfo = {
	SurfaceNormal: Enum.NormalId,
	SurfacePart: Part,
	SurfaceGui: SurfaceGui,
}

local function copyDefaults(target)
	for key, value in DEFAULT_SETTINGS do
		target[key] = value
	end
end

local function getWorkspaceFolder()
	local folder = workspace:FindFirstChild("DistanceFade_SurfaceParts")
	if folder and folder:IsA("Folder") then
		return folder
	end

	folder = Instance.new("Folder")
	folder.Name = "DistanceFade_SurfaceParts"
	folder.Parent = workspace
	return folder
end

local function getNormalOffset(normal: Enum.NormalId, targetPart: BasePart): (Vector3, CFrame)
	if normal == Enum.NormalId.Front then
		return (targetPart.Size.Z / 2) * targetPart.CFrame.LookVector, CFrame.Angles(0, 0, 0)
	elseif normal == Enum.NormalId.Back then
		return (targetPart.Size.Z / 2) * -targetPart.CFrame.LookVector, CFrame.Angles(0, math.rad(180), 0)
	elseif normal == Enum.NormalId.Left then
		return (targetPart.Size.X / 2) * -targetPart.CFrame.RightVector, CFrame.Angles(0, math.rad(90), 0)
	elseif normal == Enum.NormalId.Right then
		return (targetPart.Size.X / 2) * targetPart.CFrame.RightVector, CFrame.Angles(0, math.rad(-90), 0)
	elseif normal == Enum.NormalId.Top then
		return (targetPart.Size.Y / 2) * targetPart.CFrame.UpVector, CFrame.Angles(math.rad(90), 0, 0)
	end

	return (targetPart.Size.Y / 2) * -targetPart.CFrame.UpVector, CFrame.Angles(math.rad(-90), 0, 0)
end

local function getNormalDirection(normal: Enum.NormalId, targetPart: BasePart): Vector3
	if normal == Enum.NormalId.Front then
		return targetPart.CFrame.LookVector
	elseif normal == Enum.NormalId.Back then
		return -targetPart.CFrame.LookVector
	elseif normal == Enum.NormalId.Left then
		return -targetPart.CFrame.RightVector
	elseif normal == Enum.NormalId.Right then
		return targetPart.CFrame.RightVector
	elseif normal == Enum.NormalId.Top then
		return targetPart.CFrame.UpVector
	end

	return -targetPart.CFrame.UpVector
end

local function getTargetPosition(): Vector3?
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return nil
	end

	local character = localPlayer.Character
	if not character then
		return nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (rootPart and rootPart:IsA("BasePart")) then
		return nil
	end

	return rootPart.Position
end

local function createSurface(workspaceFolder: Folder, targetPart: BasePart, normal: Enum.NormalId)
	local surfacePart = Instance.new("Part")
	surfacePart.Name = "DistanceFadeSurface"
	surfacePart.Transparency = 1
	surfacePart.Anchored = true
	surfacePart.CanCollide = false
	surfacePart.CanTouch = false
	surfacePart.CanQuery = false
	surfacePart.Locked = true
	surfacePart.Size = Vector3.zero
	surfacePart.Parent = workspaceFolder

	local offset, rotation = getNormalOffset(normal, targetPart)
	surfacePart.CFrame = targetPart.CFrame * CFrame.new(offset) * rotation

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = "DistanceFadeSurfaceGui"
	surfaceGui.ResetOnSpawn = false
	surfaceGui.ClipsDescendants = true
	surfaceGui.Adornee = surfacePart
	surfaceGui.Face = Enum.NormalId.Front
	surfaceGui.Enabled = false
	surfaceGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local imageLabel = Instance.new("ImageLabel")
	imageLabel.Name = "Texture"
	imageLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	imageLabel.Position = UDim2.fromScale(0.5, 0.5)
	imageLabel.Size = UDim2.fromScale(1, 1)
	imageLabel.BackgroundTransparency = 1
	imageLabel.ScaleType = Enum.ScaleType.Tile
	imageLabel.Parent = surfaceGui

	return surfacePart, surfaceGui
end

local function applyGuiSettings(surfaceGui: SurfaceGui, settings)
	surfaceGui.ZOffset = settings.ZOffset
	surfaceGui.AlwaysOnTop = settings.AlwaysOnTop
	surfaceGui.Brightness = settings.Brightness
	surfaceGui.LightInfluence = settings.LightInfluence
	surfaceGui.MaxDistance = settings.MaxDistance
	surfaceGui.PixelsPerStud = settings.PixelsPerStud
	surfaceGui.SizingMode = settings.SizingMode
end

local function applyImageSettings(surfaceGui: SurfaceGui, settings, alpha: number)
	local imageLabel = surfaceGui:FindFirstChild("Texture")
	if not (imageLabel and imageLabel:IsA("ImageLabel")) then
		return
	end

	imageLabel.Image = settings.Texture
	imageLabel.ImageColor3 = settings.TextureColor
	imageLabel.BackgroundColor3 = settings.BackgroundColor
	imageLabel.ImageTransparency = settings.TextureTransparency
		+ (settings.TextureTransparencyMin - settings.TextureTransparency) * alpha
	imageLabel.BackgroundTransparency = settings.BackgroundTransparency
		+ (settings.BackgroundTransparencyMin - settings.BackgroundTransparency) * alpha

	local textureSize = settings.TextureSize
	imageLabel.TileSize = UDim2.new(
		math.max(textureSize.X / 16, 0.001),
		0,
		math.max(textureSize.Y / 16, 0.001),
		0
	)
	imageLabel.Position = UDim2.fromScale(0.5 - settings.TextureOffset.X / 16, 0.5 - settings.TextureOffset.Y / 16)
end

function DistanceFade.new()
	local obj = {
		Settings = {},
		FaceSettings = {},
		TargetParts = {},
		WorkspaceFolder = nil,
	}
	setmetatable(obj, DistanceFade)
	copyDefaults(obj.Settings)
	obj.WorkspaceFolder = getWorkspaceFolder()
	return obj
end

function DistanceFade:UpdateSettings(settingsTable)
	if self.Settings == nil then
		self.Settings = {}
	end

	if settingsTable == nil then
		copyDefaults(self.Settings)
		return
	end

	assert(type(settingsTable) == "table", "Expected table as parameter")
	for key, defaultValue in DEFAULT_SETTINGS do
		if settingsTable[key] ~= nil then
			self.Settings[key] = settingsTable[key]
		elseif self.Settings[key] == nil then
			self.Settings[key] = defaultValue
		end
	end
end

function DistanceFade:UpdateFaceSettings(targetPart: BasePart, normal: Enum.NormalId?, settingsTable)
	normal = normal or Enum.NormalId.Front
	if self.FaceSettings[targetPart] == nil then
		self.FaceSettings[targetPart] = {}
	end
	if self.FaceSettings[targetPart][normal] == nil then
		self.FaceSettings[targetPart][normal] = {}
	end

	if settingsTable == nil then
		self.FaceSettings[targetPart][normal] = nil
		return
	end

	assert(type(settingsTable) == "table", "Expected table as parameter")
	for key, value in pairs(settingsTable) do
		self.FaceSettings[targetPart][normal][key] = value
	end
end

function DistanceFade:AddFace(targetPart: BasePart, normal: Enum.NormalId?)
	normal = normal or Enum.NormalId.Front
	self.WorkspaceFolder = self.WorkspaceFolder or getWorkspaceFolder()

	local surfacePart, surfaceGui = createSurface(self.WorkspaceFolder, targetPart, normal)
	if self.TargetParts[targetPart] == nil then
		self.TargetParts[targetPart] = {}
	end
	self.TargetParts[targetPart][normal] = {
		SurfaceNormal = normal,
		SurfacePart = surfacePart,
		SurfaceGui = surfaceGui,
	}
end

function DistanceFade:RemoveFace(targetPart: BasePart, normal: Enum.NormalId?)
	normal = normal or Enum.NormalId.Front
	if self.TargetParts[targetPart] == nil then
		return
	end

	local info = self.TargetParts[targetPart][normal]
	if info == nil then
		return
	end

	info.SurfacePart:Destroy()
	info.SurfaceGui:Destroy()
	self.TargetParts[targetPart][normal] = nil
	if next(self.TargetParts[targetPart]) == nil then
		self.TargetParts[targetPart] = nil
	end
end

function DistanceFade:Clear()
	for targetPart, faces in self.TargetParts do
		for normal in faces do
			self:RemoveFace(targetPart, normal)
		end
	end
	table.clear(self.TargetParts)

	if self.WorkspaceFolder and #self.WorkspaceFolder:GetChildren() == 0 then
		self.WorkspaceFolder:Destroy()
		self.WorkspaceFolder = nil
	end
end

function DistanceFade:Step(targetPos: Vector3?)
	if not RunService:IsClient() then
		return
	end

	self.WorkspaceFolder = self.WorkspaceFolder or getWorkspaceFolder()
	targetPos = targetPos or getTargetPosition()
	if targetPos == nil then
		return
	end

	local settings = self.Settings
	if settings.EffectRadiusMin > settings.EffectRadius then
		settings.EffectRadiusMin = settings.EffectRadius
	end
	if settings.DistanceInner > settings.DistanceOuter then
		settings.DistanceInner = settings.DistanceOuter
	end

	for targetPart, faces in self.TargetParts do
		if not targetPart.Parent then
			self.TargetParts[targetPart] = nil
			continue
		end

		for normal, info: FaceInfo in faces do
			local faceSettings = self.FaceSettings[targetPart] and self.FaceSettings[targetPart][normal]
			local activeSettings = settings
			if faceSettings then
				activeSettings = {}
				for key, value in settings do
					activeSettings[key] = if faceSettings[key] ~= nil then faceSettings[key] else value
				end
			end

			local surfacePart = info.SurfacePart
			local surfaceGui = info.SurfaceGui
			if not (surfacePart.Parent and surfaceGui.Parent) then
				continue
			end

			applyGuiSettings(surfaceGui, activeSettings)

			local normalOffset, rotation = getNormalOffset(info.SurfaceNormal, targetPart)
			local normalDirection = getNormalDirection(info.SurfaceNormal, targetPart)
			local targetOffset = targetPos - (targetPart.Position + normalOffset)
			local perpendicularOffset = targetOffset - normalDirection * targetOffset:Dot(normalDirection)
			local newPosition = targetPart.Position + perpendicularOffset + normalOffset
			local objectCFrame = targetPart.CFrame * CFrame.new(normalOffset) * rotation
			surfacePart.CFrame = CFrame.new(newPosition)
				* CFrame.fromMatrix(Vector3.zero, objectCFrame.RightVector, objectCFrame.UpVector)

			local distance = (targetPos - surfacePart.Position).Magnitude
			if distance >= activeSettings.DistanceOuter then
				surfaceGui.Enabled = false
				continue
			end

			surfaceGui.Enabled = true
			local alpha = if distance <= activeSettings.DistanceInner
				then 0
				else math.clamp(
					(distance - activeSettings.DistanceInner)
						/ math.max(activeSettings.DistanceOuter - activeSettings.DistanceInner, 0.001),
					0,
					1
				)

			local radius = activeSettings.EffectRadiusMin
				+ (activeSettings.EffectRadius - activeSettings.EffectRadiusMin) * (1 - alpha)
			local size = math.max(radius * 2, 0.001)
			surfacePart.Size = Vector3.new(size, size, 0.001)
			applyImageSettings(surfaceGui, activeSettings, alpha)
		end
	end
end

return DistanceFade
