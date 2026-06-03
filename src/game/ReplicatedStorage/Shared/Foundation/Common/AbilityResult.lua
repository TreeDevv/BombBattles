local AbilityResult = {}

AbilityResult.Kind = table.freeze({
	Continue = "Continue",
	Block = "Block",
	Reflect = "Reflect",
	Absorb = "Absorb",
	DestroyProjectile = "DestroyProjectile",
	ModifyDamage = "ModifyDamage",
	DeferProjectile = "DeferProjectile",
	RedirectProjectile = "RedirectProjectile",
})

function AbilityResult.Continue(extra)
	local result = extra or {}
	result.kind = AbilityResult.Kind.Continue
	return result
end

function AbilityResult.IsHandled(result): boolean
	return typeof(result) == "table" and result.kind ~= nil and result.kind ~= AbilityResult.Kind.Continue
end

return table.freeze(AbilityResult)
