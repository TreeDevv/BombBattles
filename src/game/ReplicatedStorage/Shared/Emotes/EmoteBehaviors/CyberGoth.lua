local EmoteEffect = require(script.Parent.Parent.EmoteEffect)


local CyberGoth = EmoteEffect.Create("CyberGoth", { catalogOrder = 9 })


function CyberGoth:Begin(_character: Model, runtime)
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())
end

function CyberGoth:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "Music")
end

return CyberGoth