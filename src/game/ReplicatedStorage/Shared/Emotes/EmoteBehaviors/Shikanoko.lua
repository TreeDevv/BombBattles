local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Shikanoko = EmoteEffect.Create("Shikanoko", { catalogOrder = 27, rarity = "Legendary" })

function Shikanoko:Begin(_character: Model, runtime)
	local root = runtime:GetRoot()
	local leftArm = runtime:FindPart("Left Arm")

	local deer = runtime:CloneVfxChildTo("Deer", runtime.character)
	local mic = runtime:CloneVfxChildTo("Mic", runtime.character)

	runtime:MakeMotor(leftArm or runtime.character, "Shikam61", leftArm, mic :: BasePart?, CFrame.new(0.43, -1, 0) * CFrame.Angles(0, math.rad(-90), 0))
	runtime:MakeMotor(root or runtime.character, "Shikam62", root, deer :: BasePart?, CFrame.new(1.823, 0.302, -7.303) * CFrame.Angles(0, math.rad(-10), 0))
	runtime:CloneVfxDescendantTo({ "Att", "ShikaAtt" }, root)
	runtime:PlaySound(runtime:GetVfxChild("ShikaSound"), root)
end

function Shikanoko:Finish(_character: Model, runtime)
	local root = runtime:GetRoot()
	local leftArm = runtime:FindPart("Left Arm")
	runtime:DestroyChild(runtime.character, "Deer")
	runtime:DestroyChild(runtime.character, "Mic")
	runtime:DestroyChild(leftArm, "Shikam61")
	runtime:DestroyChild(root, "Shikam62")
	runtime:DestroyChild(root, "ShikaAtt")
	runtime:DestroyChild(root, "ShikaSound")
end

return Shikanoko
