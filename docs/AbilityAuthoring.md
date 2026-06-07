# Ability Authoring Guide

This guide is the default reference for creating or changing abilities.

The main rule is: put as much ability work on the client as possible, and keep the server focused on state, validation, and authoritative gameplay outcomes.

## Ownership

- Ability config lives in `src/game/ReplicatedStorage/Shared/Config/AbilityConfig.lua`.
- Shared ability result helpers live in `src/game/ReplicatedStorage/Shared/Foundation/Common/AbilityResult.lua`.
- Client ability behavior modules live in `src/game/StarterPlayer/StarterPlayerScripts/Controllers/Gameplay/AbilityBehaviors`.
- Server ability behavior modules live in `src/game/ServerScriptService/Services/Gameplay/AbilityBehaviors`.
- Studio-owned ability assets live in Studio-managed replicated asset folders. Reference them from config by path; do not author visual assets in Rojo.
- VFX emission should use `src/game/ReplicatedStorage/Packages/EmitModule` unless the task explicitly replaces that system.

## Client First

The client should own the ability experience whenever the result does not need server authority.

Good client responsibilities:

- Input handling and mode switching.
- Aim previews, placement ghosts, target indicators, valid/invalid coloring, and local affordances.
- Animation, sound, camera shake, UI updates, and cosmetic tweens.
- Short-lived cosmetic objects that do not affect gameplay authority.
- Local prediction for responsiveness, followed by correction from server state or effect messages.
- Taking over conflicting input during ability targeting, such as sinking left click while a placement preview is active.

Client behavior modules should use the controller hooks for ability-specific logic:

- `OnActivateRequested(context)`
- `OnEffect(context)`
- `context.controller:SendMessage(context.slot, messageType, payload)`

The client may send intent, not truth. For example, send "place wall near this aimed point", not "spawn this final wall with this exact authoritative result".

## Server Authority

The server should stay small and authoritative.

Good server responsibilities:

- Check equipped abilities and player state.
- Enforce cooldowns, charges, durations, rate limits, and round rules.
- Validate payload shape, numbers, distances, line of sight, placement rules, and target legitimacy.
- Recompute important outcomes from authoritative state when possible.
- Spawn, tag, and clean up gameplay-authoritative objects.
- Apply damage, knockback, destruction, projectile ownership, and bomb/explosion rules.
- Replicate durable state through ReplicaService or explicit effect messages.

Server behavior modules should keep ability-specific authority inside the behavior instead of adding one-off branches to central services.

Common server hooks:

- `CanActivate(context)`
- `OnActivate(context)`
- `OnClientMessage(context)`
- Hook functions called through `AbilityService:RunHook(...)`

If an activation is invalid, return failure without spending the cooldown unless the design explicitly says failed attempts should consume it.

## Typed Ability Templates

Shared ability contracts live in `ReplicatedStorage.Shared.Common.AbilityTypes`. Import those types in new behavior modules so Studio autocomplete shows the available context fields.

Minimal client behavior:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

local MyAbility = {} :: AbilityTypes.ClientBehavior

function MyAbility.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, {
		aimPosition = nil,
	})
	return true
end

function MyAbility.OnEffect(context: ClientEffectContext)
	if context.effectName ~= "Activated" or context.payload.abilityId ~= "MyAbility" then
		return
	end
end

return MyAbility
```

Minimal server behavior:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type ServerActivateContext = AbilityTypes.ServerActivateContext
type AbilityActivationResult = AbilityTypes.AbilityActivationResult

local MyAbility = {} :: AbilityTypes.ServerBehavior

function MyAbility.CanActivate(context: ServerActivateContext): boolean
	return context.player.Character ~= nil
end

function MyAbility.OnActivate(context: ServerActivateContext): AbilityActivationResult
	local state = context.slotState.state
	local uses = if typeof(state.uses) == "number" then state.uses else 0

	return {
		state = {
			uses = uses + 1,
			lastActivatedAt = context.now,
		},
		effect = {
			name = "MyAbilityActivated",
			payload = {},
		},
	}
end

return MyAbility
```

Ability-specific payloads and replicated state are intentionally broad at the shared boundary. Narrow them inside the behavior with `typeof` checks before trusting numbers, vectors, instances, or tables from the client.

## Networking Contract

Use remotes for compact ability intent and effect notifications.

- Client to server: ability id plus minimal intent payload.
- Server to client: accepted/rejected state through replicas, or effect messages for presentation.
- Never trust client payloads for damage, final placement, projectile hits, immunity, or destruction results.
- Clamp, type-check, and sanity-check all client numbers and vectors.
- Prefer server-side recomputation from character/root state over trusting exact client positions.

## Destruction And Bombs

Abilities that affect bombs, explosions, or destructible objects should integrate through shared hooks instead of patching every bomb call site.

- Use `AbilityService:RunHook(...)` for cross-cutting ability effects.
- Return explicit `AbilityResult` values so callers can distinguish allow, block, reflect, absorb, modify, and similar outcomes.
- Tag spawned destructible gameplay objects consistently with the destruction system.
- Do not add unsafe tags or attributes to objects that are not meant to participate in destruction.

## Adding A New Ability

1. Add or update the ability entry in `AbilityConfig.lua`.
2. Add a client behavior module if the ability has input, preview, UI, animation, VFX, SFX, camera, or local prediction.
3. Add a server behavior module only for validation, persistent state, authoritative spawning, damage, knockback, destruction, or bomb rules.
4. Reference Studio-owned assets from config by path.
5. Keep central services generic; put ability-specific decisions in behavior modules.
6. Validate the Rojo project locally, then use Studio MCP for asset inspection and live playtesting when needed.

## Anti-Patterns

- Do not put cosmetic-only tweens, sounds, camera shake, or visual previews on the server.
- Do not trust the client to declare damage, hits, final object placement, or immunity.
- Do not create or reorganize Studio-owned models, VFX, UI, sounds, or world content through Rojo.
- Do not bypass the shared EmitModule for normal VFX emission.
- Do not hard-code one ability's logic into generic services when a behavior module can own it.
- Do not leave input conflicts unresolved during targeting modes; explicitly sink or restore conflicting actions.

## Example Split

For a placement ability like Wall Builder:

- Client: enters placement mode, shows the ghost, colors it green or red, captures left click, and sends the requested placement intent.
- Server: validates the player, cooldown, distance, overlap, and surface; spawns the authoritative destructible wall; tags it for destruction; owns lifetime cleanup.
- Client: plays accepted placement effects from server state or effect messages.
