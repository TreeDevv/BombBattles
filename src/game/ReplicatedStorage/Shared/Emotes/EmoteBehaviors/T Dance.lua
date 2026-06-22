local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local TDance = EmoteEffect.Create("T Dance", { catalogOrder = 31 })

function TDance:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "TDance"), runtime:GetRoot())
end

function TDance:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "TDance")
end

return TDance
