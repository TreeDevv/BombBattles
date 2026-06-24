local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Goop = EmoteEffect.Create("goop", { catalogOrder = 35, rarity = "Common" })

function Goop:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "GoopSound"), runtime:GetRoot())
end

function Goop:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "GoopSound")
end

return Goop
