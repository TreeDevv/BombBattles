local EmoteConfig = require(script.Parent.EmoteConfig)
local EmoteEffect = require(script.Parent.EmoteEffect)

local EmoteVFX = {}

local function getBehavior(emoteId: string): any?
	local definition = EmoteConfig.GetDefinition(emoteId)
	return definition and definition.behavior or nil
end

function EmoteVFX.Start(character: Model, emoteId: string): any?
	local normalizedEmoteId = EmoteConfig.NormalizeEmoteId(emoteId)
	local assetFolder = EmoteConfig.GetAssetFolder(normalizedEmoteId)
	if not (assetFolder and character and character.Parent) then
		return nil
	end

	local behavior = getBehavior(normalizedEmoteId)
	if not behavior then
		warn("[EmoteVFX] No emote behavior module for " .. tostring(normalizedEmoteId))
		return nil
	end

	local runtime = EmoteEffect.CreateRuntime(normalizedEmoteId, character, assetFolder)
	if type(behavior.Begin) == "function" then
		local ok, err = pcall(function()
			behavior:Begin(character, runtime)
		end)
		if not ok then
			warn(("[EmoteVFX] Failed to begin %s VFX: %s"):format(normalizedEmoteId, tostring(err)))
		end
	end

	return {
		Destroy = function()
			runtime.running = false

			if type(behavior.Finish) == "function" then
				local ok, err = pcall(function()
					behavior:Finish(character, runtime)
				end)
				if not ok then
					warn(("[EmoteVFX] Failed to finish %s VFX: %s"):format(normalizedEmoteId, tostring(err)))
				end
			end

			runtime:Destroy()
		end,
	}
end

return EmoteVFX
