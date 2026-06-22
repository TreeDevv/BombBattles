local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local KazotskyKickTwo = EmoteEffect.Create("Kazotsky Kick Two", { catalogOrder = 17 })

function KazotskyKickTwo:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetVfxChild("KazotskySound"), runtime:GetRoot())
end

function KazotskyKickTwo:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "KazotskySound")
end

return KazotskyKickTwo
