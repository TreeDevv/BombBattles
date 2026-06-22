local EmoteEffect = require(script.Parent.Parent.EmoteEffect)


local Conga = EmoteEffect.Create("Conga", { catalogOrder = 8 })

function Conga:Begin(_character: Model, runtime)
	local root = runtime:GetRoot()
	local rightArm = runtime:FindPart("Right Arm")
	local leftArm = runtime:FindPart("Left Arm")

	local m1 = runtime:CloneVfxChildTo("Maraca", runtime.character)
	local m2 = runtime:CloneVfxChildTo("Maraca", runtime.character)

	runtime:PlaySound(runtime:GetVfxChild("Music"), root)



	runtime:MakeMotor(
		rightArm or runtime.character,
		"Maraca1",
		rightArm,
		m1 :: BasePart?,
		CFrame.new(0, -1, -0.3) * CFrame.Angles(math.rad(-90), 0, 0)
	)
	
	runtime:MakeMotor(
		leftArm or runtime.character,
		"Maraca2",
		leftArm,
		m2 :: BasePart?,
		CFrame.new(0, -1, -0.3) * CFrame.Angles(math.rad(-90), 0, 0)
	)
end

function Conga:Finish(_character: Model, runtime)
	local root = runtime:GetRoot()
	local rightArm = runtime:FindPart("Right Arm")
	runtime:DestroyChild(runtime.character, "Maraca")
	local leftArm = runtime:FindPart("Left Arm")
	runtime:DestroyChild(runtime.character, "Maraca")
end




return Conga