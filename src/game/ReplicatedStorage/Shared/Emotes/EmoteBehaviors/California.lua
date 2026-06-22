local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local California = EmoteEffect.Create("California", { catalogOrder = 4 })



function California:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function California:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end

return California