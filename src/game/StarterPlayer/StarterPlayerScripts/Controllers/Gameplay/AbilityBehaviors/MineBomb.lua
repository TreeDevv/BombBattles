local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

local MineBomb = {} :: AbilityTypes.ClientBehavior

function MineBomb.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate)
	return true
end

function MineBomb.OnEffect(_context: ClientEffectContext)
end

return MineBomb
