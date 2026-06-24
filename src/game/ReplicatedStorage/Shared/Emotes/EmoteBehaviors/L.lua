local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local L = EmoteEffect.Create("L", { catalogOrder = 18, rarity = "Common" })
function L:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function L:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end


return L
