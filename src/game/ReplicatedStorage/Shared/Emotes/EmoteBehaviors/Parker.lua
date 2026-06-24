local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Parker = EmoteEffect.Create("Parker", { catalogOrder = 22, rarity = "Common", previewPauseTimeSeconds = 1.9 })

function Parker:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetVfxChild("ParkerSound"), runtime:GetRoot())
end

function Parker:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "ParkerSound")
end

return Parker
