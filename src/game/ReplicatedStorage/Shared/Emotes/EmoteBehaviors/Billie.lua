local EmoteEffect = require(script.Parent.Parent.EmoteEffect)




local Billie = EmoteEffect.Create("Billie", { catalogOrder = 1,previewPauseTimeSeconds = 1.3 })


function Billie:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function Billie:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end

return Billie