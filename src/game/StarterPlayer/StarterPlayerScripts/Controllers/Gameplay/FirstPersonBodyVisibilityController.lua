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
FirstPersonBodyVisibilityController._modifiedParts = {} :: { [BasePart]: number }
FirstPersonBodyVisibilityController._modifiedDecals = {} :: { [Decal]: number }

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

function FirstPersonBodyVisibilityController:_setBodyVisible(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			if self._modifiedParts[descendant] == nil then
				self._modifiedParts[descendant] = descendant.LocalTransparencyModifier
			end
			descendant.LocalTransparencyModifier = getFirstPersonTransparency(descendant)
		elseif descendant:IsA("Decal") and shouldHideDecal(descendant) then
			if self._modifiedDecals[descendant] == nil then
				self._modifiedDecals[descendant] = descendant.Transparency
			end
			descendant.Transparency = 1
		end
	end
end

function FirstPersonBodyVisibilityController:_bindCharacter(character: Model?)
	if character == self._character then
		return
	end

	self:_restoreVisibleParts()
	self._character = character
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
