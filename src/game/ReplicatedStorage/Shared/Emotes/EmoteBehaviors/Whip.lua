local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Whip = EmoteEffect.Create("Whip", { catalogOrder = 34 })



function Whip:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function Whip:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end


return Whip