local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Sleep = EmoteEffect.Create("Sleep", { catalogOrder = 30, rarity = "Epic" })

function Sleep:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Sleep"), runtime:GetRoot())
	runtime:CloneTo(runtime:GetChild(runtime.vfxModule, "SleepParticle"), runtime:GetHead())
end

function Sleep:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Sleep")
	runtime:DestroyChild(runtime:GetHead(), "SleepParticle")
end

return Sleep
