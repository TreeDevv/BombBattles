local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local PenguinWalk = EmoteEffect.Create("Penguin Walk", { catalogOrder = 23 })



function PenguinWalk:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function PenguinWalk:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end

return PenguinWalk
