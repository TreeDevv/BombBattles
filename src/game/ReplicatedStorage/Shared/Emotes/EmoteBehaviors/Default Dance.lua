local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local DefaultDance= EmoteEffect.Create("Default Dance", { catalogOrder = 10 })


function DefaultDance:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function DefaultDance:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end


return DefaultDance