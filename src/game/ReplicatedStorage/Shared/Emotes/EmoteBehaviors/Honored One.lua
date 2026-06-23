local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local HonoredOne = EmoteEffect.Create("Honored One", { catalogOrder = 36 })


function HonoredOne:Begin(_character: Model, runtime)
	local root = runtime:GetRoot()
	runtime:CloneVfxDescendantTo({ "HonoredOneAttachment" }, root)
	
	local trackObject = runtime:PlayAnimation("Animation1", nil, nil)
	if not trackObject then
		return
	end
	
	runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "Music"), runtime:GetRoot())

	
	runtime:TrackConnection(trackObject:GetMarkerReachedSignal("Freeze"):Connect(function()
		trackObject:AdjustSpeed(0)
	end))
	
	
end

function HonoredOne:Finish(_character: Model, runtime)
	local root = runtime:GetRoot()
	runtime:DestroyChild(root, "HonoredOneAttachment")
end

return HonoredOne
