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
FirstPersonBodyVisibilityController._visibleParts = {} :: { [BasePart]: boolean }

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

local function shouldShowPart(part: BasePart): boolean
	if CameraConfig.FirstPersonHiddenPartNames[part.Name] then
		return false
	end

	if CameraConfig.FirstPersonHideAccessories and hasAncestorOfClass(part, "Accessory") then
		return false
	end

	return true
end

local function getFirstPersonTransparency(part: BasePart): number
	return if CameraConfig.FirstPersonTransparentPartNames[part.Name] then 1 else 0
end

function FirstPersonBodyVisibilityController:_restoreVisibleParts()
	for part in pairs(self._visibleParts) do
		if part.Parent then
			part.LocalTransparencyModifier = 0
		end
	end

	table.clear(self._visibleParts)
end

function FirstPersonBodyVisibilityController:_setBodyVisible(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") and shouldShowPart(descendant) then
			descendant.LocalTransparencyModifier = getFirstPersonTransparency(descendant)
			self._visibleParts[descendant] = true
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
