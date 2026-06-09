local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityResult = require(ReplicatedStorage.Shared.Common.AbilityResult)

export type AbilityDefinition = AbilityConfig.AbilityDefinition
export type AbilityEffectPayload = AbilityConfig.AbilityEffectPayload
export type AbilityId = AbilityConfig.AbilityId
export type AbilityLoadout = AbilityConfig.AbilityLoadout
export type AbilityRequest = AbilityConfig.AbilityRequest
export type AbilityReplicatedState = AbilityConfig.AbilityReplicatedState
export type AbilitySlot = AbilityConfig.AbilitySlot
export type AbilitySlotState = AbilityConfig.AbilitySlotState
export type AbilityState = AbilityConfig.AbilityState
export type MessageType = AbilityConfig.MessageType
export type AbilityHookResult = AbilityResult.AbilityHookResult

export type AbilityActivationEffect = {
	name: string?,
	payload: any?,
}

export type AbilityActivationResult =
	false
	| nil
	| {
		state: AbilityReplicatedState?,
		effect: AbilityActivationEffect?,
		cooldownSeconds: number?,
		[string]: any,
	}

export type AbilityControllerLike = {
	SendMessage: (any, AbilitySlot, MessageType, any?) -> boolean,
	ActivateSlot: (any, AbilitySlot) -> boolean,
	GetCooldownRemaining: (any, AbilitySlot) -> number,
	GetEquippedAbilityId: (any, AbilitySlot) -> AbilityId,
	GetState: (any) -> AbilityState?,
	GetSlotState: (any, AbilitySlot) -> AbilitySlotState?,
}

export type AbilityServiceLike = {
	RunHook: (any, string, any?) -> AbilityHookResult,
	FireEffect: (any, string, any?) -> (),
	SetSlotValues: (any, Player, AbilitySlot, { [string]: any }) -> boolean,
	SetEquippedAbility: (any, Player, AbilitySlot, AbilityId) -> boolean,
	SetLoadout: (any, Player, AbilityLoadout) -> boolean,
	GetPlayerState: (any, Player) -> AbilityState?,
}

export type ClientActivateRequestedContext = {
	controller: AbilityControllerLike,
	localPlayer: Player,
	slot: AbilitySlot,
	abilityId: AbilityId,
	definition: AbilityDefinition,
	slotState: AbilitySlotState?,
	inputState: Enum.UserInputState?,
	inputObject: InputObject?,
}

export type ClientEffectContext = {
	effectName: string,
	payload: AbilityEffectPayload,
	localPlayer: Player,
	controller: AbilityControllerLike,
}

export type ClientBehavior = {
	OnActivateRequested: ((ClientActivateRequestedContext) -> boolean?)?,
	OnEffect: ((ClientEffectContext) -> ())?,
	[string]: any,
}

export type ServerActivateContext = {
	player: Player,
	slot: AbilitySlot,
	abilityId: AbilityId,
	definition: AbilityDefinition,
	slotState: AbilitySlotState,
	payload: any?,
	now: number,
}

export type ServerClientMessageContext = ServerActivateContext & {
	messageType: MessageType,
	clientSequence: number?,
}

export type ServerHookContext = {
	player: Player,
	slot: AbilitySlot,
	abilityId: AbilityId,
	definition: AbilityDefinition,
	slotState: AbilitySlotState,
	hook: string,
	context: any?,
	now: number,
}

export type ServerBehavior = {
	CanActivate: ((ServerActivateContext) -> boolean?)?,
	OnActivate: ((ServerActivateContext) -> AbilityActivationResult)?,
	OnClientMessage: ((ServerClientMessageContext) -> ())?,
	OnStart: ((AbilityServiceLike) -> ())?,
	OnPlayerRemoving: ((Player) -> ())?,
	[string]: any,
}

return table.freeze({})
