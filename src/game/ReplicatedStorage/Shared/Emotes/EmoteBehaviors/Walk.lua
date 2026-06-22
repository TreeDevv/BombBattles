local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Walk = EmoteEffect.Create("Walk", { catalogOrder = 33 })

function Walk:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Kinetix M"), runtime:GetRoot())
end

function Walk:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Kinetix M")
end

return Walk
