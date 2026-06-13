local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local CameraController = require(script.Parent.Parent:WaitForChild("CameraController"))

type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

local EmergencyFort = {} :: AbilityTypes.ClientBehavior

local function getEffectData(payload: any): any
	if typeof(payload) == "table" and typeof(payload.payload) == "table" then
		return payload.payload
	end
	return payload
end

function EmergencyFort.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, nil)
	return true
end

function EmergencyFort.OnEffect(context: ClientEffectContext)
	if context.effectName ~= "EmergencyFortCreated" or context.payload.abilityId ~= "EmergencyFort" then
		return
	end

	local definition = AbilityConfig.GetDefinition("EmergencyFort")
	if not definition then
		return
	end

	local data = getEffectData(context.payload)
	if typeof(data) ~= "table" or typeof(data.position) ~= "Vector3" then
		return
	end

	if type(CameraController.PlayExplosionShake) == "function" then
		CameraController:PlayExplosionShake(data.position, definition.cameraShakeRadius or 40)
	end
end

return EmergencyFort
