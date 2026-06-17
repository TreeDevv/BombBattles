local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MovementConfig = require(ReplicatedStorage.Shared.Config.MovementConfig)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)
local CameraController = require(script.Parent:WaitForChild("CameraController"))
local ScreenEffectsController = require(script.Parent:WaitForChild("ScreenEffectsController"))

local LocalPlayer = Players.LocalPlayer

local MovementEffectsController = {}

MovementEffectsController._character = nil :: Model?
MovementEffectsController._characterAddedConnection = nil :: RBXScriptConnection?
MovementEffectsController._characterRemovingConnection = nil :: RBXScriptConnection?
MovementEffectsController._renderConnection = nil :: RBXScriptConnection?
MovementEffectsController._effectActive = false
MovementEffectsController._smoothedSpeed = 0

local function getConfigValue(key: string, fallback: any): any
	local config = MovementConfig.SpeedScreenEffect
	if typeof(config) == "table" and config[key] ~= nil then
		return config[key]
	end
	return fallback
end

local function getCharacterNumberAttribute(character: Model?, attributeName: string): number
	if not character then
		return 0
	end

	local value = character:GetAttribute(attributeName)
	return if typeof(value) == "number" and value == value then value else 0
end

local function exponentialAlpha(responsiveness: number, dt: number): number
	return 1 - math.exp(-math.max(responsiveness, 0) * dt)
end

local function getMovementSpeed(character: Model?): number
	local horizontalSpeed = getCharacterNumberAttribute(character, "Movement_HorizontalSpeed")
	local effectiveSpeed = getCharacterNumberAttribute(character, "Movement_EffectiveSpeed")
	return math.max(horizontalSpeed, effectiveSpeed)
end

local function getIntensity(speed: number): number
	local startSpeed = math.max(getConfigValue("StartSpeed", 28), 0)
	local strongSpeed = math.max(getConfigValue("StrongSpeed", 42), startSpeed + 0.01)
	local minIntensity = math.clamp(getConfigValue("MinIntensity", 0.35), 0, 1)
	local maxIntensity = math.clamp(getConfigValue("MaxIntensity", 1), minIntensity, 1)
	local alpha = math.clamp((speed - startSpeed) / (strongSpeed - startSpeed), 0, 1)
	return minIntensity + (maxIntensity - minIntensity) * alpha
end

function MovementEffectsController:_stopSpeedEffect()
	if not self._effectActive then
		return
	end

	self._effectActive = false
	if type(CameraController.SetSpeedEffectFOVIntensity) == "function" then
		CameraController:SetSpeedEffectFOVIntensity(0)
	end
	ScreenEffectsController:Stop(getConfigValue("PresetName", "Speed"))
end

function MovementEffectsController:_enableSpeedEffect(intensity: number)
	if type(CameraController.SetSpeedEffectFOVIntensity) == "function" then
		CameraController:SetSpeedEffectFOVIntensity(intensity)
	end

	if self._effectActive then
		ScreenEffectsController:SetIntensity(getConfigValue("PresetName", "Speed"), intensity)
		return
	end

	self._effectActive = ScreenEffectsController:Enable(getConfigValue("PresetName", "Speed"), {
		intensity = intensity,
	})
end

function MovementEffectsController:_step(dt: number)
	if getConfigValue("Enabled", true) ~= true then
		self:_stopSpeedEffect()
		return
	end

	local character = self._character
	if not (character and character.Parent) then
		self:_stopSpeedEffect()
		return
	end

	local speed = getMovementSpeed(character)
	local responsiveness = getConfigValue("SpeedResponsiveness", 12)
	self._smoothedSpeed += (speed - self._smoothedSpeed) * exponentialAlpha(responsiveness, dt)

	local stopSpeed = math.max(getConfigValue("StopSpeed", 24), 0)
	local startSpeed = math.max(getConfigValue("StartSpeed", 28), stopSpeed)
	if self._effectActive then
		if self._smoothedSpeed <= stopSpeed then
			self:_stopSpeedEffect()
			return
		end
	elseif self._smoothedSpeed < startSpeed then
		return
	end

	self:_enableSpeedEffect(getIntensity(self._smoothedSpeed))
end

function MovementEffectsController:_bindCharacter(character: Model?)
	self:_stopSpeedEffect()
	self._character = character
	self._smoothedSpeed = 0
end

function MovementEffectsController:OnStart()
	if self._characterAddedConnection then
		self._characterAddedConnection:Disconnect()
	end
	if self._characterRemovingConnection then
		self._characterRemovingConnection:Disconnect()
	end
	if self._renderConnection then
		self._renderConnection:Disconnect()
	end

	self:_bindCharacter(LocalPlayer.Character)

	self._characterAddedConnection = LocalPlayer.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)
	self._characterRemovingConnection = LocalPlayer.CharacterRemoving:Connect(function()
		self:_bindCharacter(nil)
	end)
	self._renderConnection = RunService.RenderStepped:Connect(function(dt)
		local token = RuntimeProfiler.Begin("Client/MovementEffectsController/Render")
		self:_step(dt)
		RuntimeProfiler.End("Client/MovementEffectsController/Render", token)
	end)
end

return MovementEffectsController
