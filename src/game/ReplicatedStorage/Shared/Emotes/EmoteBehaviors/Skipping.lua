local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Skipping = EmoteEffect.Create("Skipping", { catalogOrder = 29, rarity = "Common", previewPauseTimeSeconds = .5 })

function Skipping:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function Skipping:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end


return Skipping
