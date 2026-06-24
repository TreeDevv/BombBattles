local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local DefaultDance = EmoteEffect.Create("Default Dance", { catalogOrder = 4, rarity = "Common", previewPauseTimeSeconds = .3 })

function DefaultDance:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Breakdance"), runtime:GetRoot())
end

function DefaultDance:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Breakdance")
end

return DefaultDance
