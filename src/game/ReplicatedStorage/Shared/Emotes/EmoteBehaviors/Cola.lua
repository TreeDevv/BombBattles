local EmoteEffect = require(script.Parent.Parent.EmoteEffect)



local cola =  EmoteEffect.Create("Cola", { catalogOrder = 7,previewPauseTimeSeconds = 3 })



function cola:Begin(_character: Model, runtime)
	local root = runtime:GetRoot()
	local rightArm = runtime:FindPart("Right Arm")

	local cola = runtime:CloneVfxChildTo("BartoCola", runtime.character)
	
	local trackObject = runtime:PlayAnimation("Animation1", nil, nil)
	if not trackObject then
		return
	end

	runtime:TrackConnection(trackObject:GetMarkerReachedSignal("Drink"):Connect(function()
		runtime:PlaySound(runtime:GetVfxChild("drink loop"), root)
	end))
	
	runtime:TrackConnection(trackObject:GetMarkerReachedSignal("Open"):Connect(function()
		runtime:PlaySound(runtime:GetVfxChild("soda pop"), root)
	end))


	runtime:MakeMotor(
		rightArm or runtime.character,
		"CouchM61",
		rightArm,
		cola :: BasePart?,
		CFrame.new(0, -1.14, -0.14) * CFrame.Angles(math.rad(-90), 0, 0)
	)
end

function cola:Finish(_character: Model, runtime)
	local root = runtime:GetRoot()
	local rightArm = runtime:FindPart("Left Arm")
	runtime:DestroyChild(runtime.character, "BartoColaPower")
end



return cola