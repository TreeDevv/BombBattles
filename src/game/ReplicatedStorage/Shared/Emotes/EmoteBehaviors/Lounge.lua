local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Lounge = EmoteEffect.Create("Lounge", { catalogOrder = 21, rarity = "Rare" })

function Lounge:Begin(_character: Model, runtime)
	local root = runtime:GetRoot()
	local leftArm = runtime:FindPart("Left Arm")

	local chips = runtime:CloneVfxChildTo("Chips", runtime.character)
	local beanbag = runtime:CloneVfxChildTo("BeanBag", runtime.character)
	local cola = runtime:CloneVfxChildTo("BartoColaPower", runtime.character)

	runtime:MakeMotor(
		leftArm or runtime.character,
		"CouchM61",
		leftArm,
		cola :: BasePart?,
		CFrame.new(0, -1.14, -0.14) * CFrame.Angles(math.rad(-90), 0, 0)
	)
	runtime:MakeMotor(
		root or runtime.character,
		"CouchM62",
		root,
		chips :: BasePart?,
		CFrame.new(1.249, -1.321, -0.939) * CFrame.Angles(math.rad(59.947), math.rad(5.335), math.rad(-4.718))
	)
	runtime:MakeMotor(root or runtime.character, "CouchM63", root, beanbag :: BasePart?, CFrame.new(0, -1.315, 0.2))
end

function Lounge:Finish(_character: Model, runtime)
	local root = runtime:GetRoot()
	local leftArm = runtime:FindPart("Left Arm")
	runtime:DestroyChild(runtime.character, "Chips")
	runtime:DestroyChild(runtime.character, "BeanBag")
	runtime:DestroyChild(runtime.character, "BartoColaPower")
	runtime:DestroyChild(leftArm, "CouchM61")
	runtime:DestroyChild(root, "CouchM62")
	runtime:DestroyChild(root, "CouchM63")
end

return Lounge
