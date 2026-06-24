local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local KazotskyKick = EmoteEffect.Create("Kazotsky Kick", { catalogOrder = 16, rarity = "Common" })

function KazotskyKick:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetVfxChild("KazotskySound"), runtime:GetRoot())
end

function KazotskyKick:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "KazotskySound")
end

return KazotskyKick
