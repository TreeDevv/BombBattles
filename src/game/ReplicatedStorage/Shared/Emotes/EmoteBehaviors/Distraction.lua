local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Distraction = EmoteEffect.Create("Distraction", { catalogOrder = 11, rarity = "Common", previewPauseTimeSeconds = 2.5 })



function Distraction:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function Distraction:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end

return Distraction
