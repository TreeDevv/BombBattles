local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Shuffle = EmoteEffect.Create("Shuffle", { catalogOrder = 26, rarity = "Common", previewPauseTimeSeconds = 1.5 })


function Shuffle:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function Shuffle:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end

return Shuffle
