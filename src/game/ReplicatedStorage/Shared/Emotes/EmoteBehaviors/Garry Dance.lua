local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local GarryDance = EmoteEffect.Create("Garry Dance", { catalogOrder = 14, rarity = "Common", previewPauseTimeSeconds = 2 })

function GarryDance:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Disco"), runtime:GetRoot())
end

function GarryDance:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Disco")
end

return GarryDance
