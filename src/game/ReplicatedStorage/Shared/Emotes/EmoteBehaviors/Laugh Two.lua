local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local LaughTwo = EmoteEffect.Create("Laugh Two", { catalogOrder = 20, rarity = "Common" })

function LaughTwo:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "LaughSound"), runtime:GetRoot())
end

function LaughTwo:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "LaughSound")
end

return LaughTwo
