local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local RidethePony = EmoteEffect.Create("Ride the Pony", { catalogOrder = 13, rarity = "Common" })



function RidethePony:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function RidethePony:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end

return RidethePony
