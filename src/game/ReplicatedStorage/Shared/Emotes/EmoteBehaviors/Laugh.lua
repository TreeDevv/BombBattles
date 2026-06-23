local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Laugh = EmoteEffect.Create("Laugh", { catalogOrder = 19,previewPauseTimeSeconds = 2 })

function Laugh:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "LaughSound"), runtime:GetRoot())
end

function Laugh:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "LaughSound")
end

return Laugh