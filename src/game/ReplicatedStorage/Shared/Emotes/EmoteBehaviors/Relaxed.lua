local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Relaxed =  EmoteEffect.Create("Relaxed", { catalogOrder = 25 })

function Relaxed:Begin(_character: Model, runtime)
	local root = runtime:GetRoot()
	local rightArm = runtime:FindPart("Right Arm")

	local chair = runtime:CloneVfxChildTo("PoolChair", runtime.character)
	local Drink = runtime:CloneVfxChildTo("Drink", runtime.character)

	runtime:MakeMotor(
		rightArm or runtime.character,
		"CouchM61",
		rightArm,
		Drink.Base :: BasePart?,
		CFrame.new(0, -1.14, -0.14) * CFrame.Angles(math.rad(-90), 0, 0)
	)

	runtime:MakeMotor(root or runtime.character, "CouchM63", root, chair :: BasePart?, CFrame.new(.3, -1.315, -1)* CFrame.Angles(0,math.rad(-90),0))
end

function Relaxed:Finish(_character: Model, runtime)
	local root = runtime:GetRoot()
	local rightArm = runtime:FindPart("Right Arm")
	runtime:DestroyChild(runtime.character, "PoolChair")
	runtime:DestroyChild(runtime.character, "BartoColaPower")
	runtime:DestroyChild(rightArm, "CouchM61")
	runtime:DestroyChild(root, "CouchM63")
end

return Relaxed
