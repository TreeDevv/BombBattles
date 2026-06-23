local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CameraConfig = require(ReplicatedStorage.Shared.Config.CameraConfig)

local LocalPlayer = Players.LocalPlayer
local RENDER_STEP_NAME = "BombBattlesFirstPersonBodyVisibilityController"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2

local FirstPersonBodyVisibilityController = {}

FirstPersonBodyVisibilityController._character = nil :: Model?
FirstPersonBodyVisibilityController._characterConnection = nil :: RBXScriptConnection?
FirstPersonBodyVisibilityController._descendantAddedConnection = nil :: RBXScriptConnection?
FirstPersonBodyVisibilityController._modifiedParts = {} :: { [BasePart]: number }
FirstPersonBodyVisibilityController._modifiedDecals = {} :: { [Decal]: number }
FirstPersonBodyVisibilityController._bodyParts = {} :: { [BasePart]: boolean }
FirstPersonBodyVisibilityController._hiddenDecals = {} :: { [Decal]: boolean }

local function hasAncestorOfClass(instance: Instance, className: string): boolean
	local current = instance.Parent
	while current do
		if current.ClassName == className then
			return true
		end
		current = current.Parent
	end

	return false
end

local function shouldHidePart(part: BasePart): boolean
	if CameraConfig.FirstPersonHiddenPartNames[part.Name] then
		return true
	end

	if CameraConfig.FirstPersonHideAccessories and hasAncestorOfClass(part, "Accessory") then
		return true
	end

	return false
end

local function getFirstPersonTransparency(part: BasePart): number
	return if shouldHidePart(part) or CameraConfig.FirstPersonTransparentPartNames[part.Name] then 1 else 0
end

local function shouldHideDecal(decal: Decal): boolean
	local parent = decal.Parent
	if parent and parent:IsA("BasePart") and CameraConfig.FirstPersonHiddenPartNames[parent.Name] then
		return true
	end

	return CameraConfig.FirstPersonHideAccessories and hasAncestorOfClass(decal, "Accessory")
end

function FirstPersonBodyVisibilityController:_restoreVisibleParts()
	for part, transparency in pairs(self._modifiedParts) do
		if part.Parent then
			part.LocalTransparencyModifier = transparency
		end
	end
	table.clear(self._modifiedParts)

	for decal, transparency in pairs(self._modifiedDecals) do
		if decal.Parent then
			decal.Transparency = transparency
		end
	end
	table.clear(self._modifiedDecals)
end

function FirstPersonBodyVisibilityController:_trackBodyVisibilityTarget(descendant: Instance)
	if descendant:IsA("BasePart") then
		self._bodyParts[descendant] = true
	elseif descendant:IsA("Decal") and shouldHideDecal(descendant) then
		self._hiddenDecals[descendant] = true
	end
end

function FirstPersonBodyVisibilityController:_rebuildBodyVisibilityTargets(character: Model)
	table.clear(self._bodyParts)
	table.clear(self._hiddenDecals)
	for _, descendant in character:GetDescendants() do
		self:_trackBodyVisibilityTarget(descendant)
	end
end

function FirstPersonBodyVisibilityController:_setBodyVisible(character: Model)
	for part in pairs(self._bodyParts) do
		if part.Parent and part:IsDescendantOf(character) then
			if self._modifiedParts[part] == nil then
				self._modifiedParts[part] = part.LocalTransparencyModifier
			end
			local transparency = getFirstPersonTransparency(part)
			if part.LocalTransparencyModifier ~= transparency then
				part.LocalTransparencyModifier = transparency
			end
		else
			self._bodyParts[part] = nil
			self._modifiedParts[part] = nil
		end
	end

	for decal in pairs(self._hiddenDecals) do
		if decal.Parent and decal:IsDescendantOf(character) then
			if self._modifiedDecals[decal] == nil then
				self._modifiedDecals[decal] = decal.Transparency
			end
			if decal.Transparency ~= 1 then
				decal.Transparency = 1
			end
		else
			self._hiddenDecals[decal] = nil
			self._modifiedDecals[decal] = nil
		end
	end
end

function FirstPersonBodyVisibilityController:_bindCharacter(character: Model?)
	if character == self._character then
		return
	end

	if self._descendantAddedConnection then
		self._descendantAddedConnection:Disconnect()
		self._descendantAddedConnection = nil
	end
	self:_restoreVisibleParts()
	self._character = character
	table.clear(self._bodyParts)
	table.clear(self._hiddenDecals)

	if character then
		self:_rebuildBodyVisibilityTargets(character)
		self._descendantAddedConnection = character.DescendantAdded:Connect(function(descendant)
			self:_trackBodyVisibilityTarget(descendant)
		end)
	end
end

function FirstPersonBodyVisibilityController:_step()
	local character = LocalPlayer.Character
	if character ~= self._character then
		self:_bindCharacter(character)
	end

	if not (CameraConfig.FirstPersonBodyVisible and character and character.Parent) then
		self:_restoreVisibleParts()
		return
	end

	if character:GetAttribute("Camera_FirstPerson") == true then
		self:_setBodyVisible(character)
	else
		self:_restoreVisibleParts()
	end
end

function FirstPersonBodyVisibilityController:OnStart()
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function()
		self:_step()
	end)

	if self._characterConnection then
		self._characterConnection:Disconnect()
	end

	self._characterConnection = LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)

	self:_bindCharacter(LocalPlayer.Character)
end

return FirstPersonBodyVisibilityController
