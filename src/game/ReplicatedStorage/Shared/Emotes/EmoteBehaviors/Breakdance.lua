local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Breakdance = EmoteEffect.Create("Breakdance", { catalogOrder = 3, rarity = "Common", previewPauseTimeSeconds = .3 })

function Breakdance:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Breakdance"), runtime:GetRoot())
end

function Breakdance:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Breakdance")
end

return Breakdance
