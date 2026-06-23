local EmoteEffect = require(script.Parent.Parent.EmoteEffect)


local Reanimated = EmoteEffect.Create("Reanimated", { catalogOrder = 24 })


function Reanimated:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function Reanimated:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end


return Reanimated