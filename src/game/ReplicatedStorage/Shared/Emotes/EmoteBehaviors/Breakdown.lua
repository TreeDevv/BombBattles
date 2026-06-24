local EmoteEffect = require(script.Parent.Parent.EmoteEffect)


local Breakdown = EmoteEffect.Create("Breakdown", { catalogOrder = 10, rarity = "Common" })


function Breakdown:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function Breakdown:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end

return Breakdown
