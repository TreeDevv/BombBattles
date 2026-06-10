local AbilityResult = {}

export type AbilityResultKind =
	"Continue"
	| "Block"
	| "Reflect"
	| "Absorb"
	| "DestroyProjectile"
	| "ExplodeProjectile"
	| "AttachProjectile"
	| "ModifyDamage"
	| "DeferProjectile"
	| "RedirectProjectile"

export type AbilityHookResult = {
	kind: AbilityResultKind?,
	[string]: any,
}

AbilityResult.Kind = table.freeze({
	Continue = "Continue",
	Block = "Block",
	Reflect = "Reflect",
	Absorb = "Absorb",
	DestroyProjectile = "DestroyProjectile",
	ExplodeProjectile = "ExplodeProjectile",
	AttachProjectile = "AttachProjectile",
	ModifyDamage = "ModifyDamage",
	DeferProjectile = "DeferProjectile",
	RedirectProjectile = "RedirectProjectile",
})

function AbilityResult.Continue(extra: AbilityHookResult?): AbilityHookResult
	local result = extra or {}
	result.kind = AbilityResult.Kind.Continue
	return result
end

function AbilityResult.IsHandled(result: any): boolean
	return typeof(result) == "table" and result.kind ~= nil and result.kind ~= AbilityResult.Kind.Continue
end

return table.freeze(AbilityResult)
