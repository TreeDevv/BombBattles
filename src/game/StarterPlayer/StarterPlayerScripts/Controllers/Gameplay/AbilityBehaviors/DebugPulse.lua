local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type ClientEffectContext = AbilityTypes.ClientEffectContext

local DebugPulse = {} :: AbilityTypes.ClientBehavior

function DebugPulse.OnEffect(_context: ClientEffectContext)
	-- This stub intentionally keeps visuals minimal. Real abilities should drive VFX from Studio-owned assets.
end

return DebugPulse
