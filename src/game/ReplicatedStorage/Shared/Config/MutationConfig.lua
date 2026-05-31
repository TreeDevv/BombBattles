local MutationConfig = {}

local VISUALS = {
	Default = {},
}

local function normalizeName(name: any): string?
	if typeof(name) ~= "string" then
		return nil
	end

	local trimmed = string.match(name, "%S.*%S") or string.match(name, "%S+")
	if not trimmed or trimmed == "" then
		return nil
	end

	return trimmed
end

function MutationConfig.NormalizeNames(input): { string }
	if typeof(input) == "string" then
		local normalized = normalizeName(input)
		return if normalized then { normalized } else {}
	end

	if typeof(input) ~= "table" then
		return {}
	end

	local names = {}
	local seen = {}

	for _, value in ipairs(input) do
		local normalized = normalizeName(value)
		if normalized and not seen[normalized] then
			seen[normalized] = true
			table.insert(names, normalized)
		end
	end

	return names
end

function MutationConfig.GetVisual(name: string)
	return VISUALS[name] or VISUALS.Default
end

function MutationConfig.GetTextureVariant(name: string): string?
	local visual = MutationConfig.GetVisual(name)
	if typeof(visual) == "table" and typeof(visual.textureVariant) == "string" and visual.textureVariant ~= "" then
		return visual.textureVariant
	end

	return nil
end

return MutationConfig
