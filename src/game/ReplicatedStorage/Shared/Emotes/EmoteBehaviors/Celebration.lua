local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Celebration = EmoteEffect.Create("Celebration", { catalogOrder = 7, rarity = "Mythic" })

function Celebration:Begin(_character: Model, runtime)
	local root = runtime:GetRoot()
	local rightArm = runtime:FindPart("Right Arm")
	local leftArm = runtime:FindPart("Left Arm")
	if not root then
		return
	end

	runtime:PlaySound(runtime:GetVfxChild("CelebrationSound"), root)
	runtime:CloneVfxDescendantTo({ "Att", "CelebrationRootAtt" }, root)

	local trackObject = runtime:PlayAnimation("Animation1", nil, nil)
	if not trackObject then
		return
	end

	local colors = {
		Color3.fromRGB(0, 195, 255),
		Color3.fromRGB(255, 64, 0),
		Color3.fromRGB(255, 0, 251),
		Color3.fromRGB(26, 255, 0),
		Color3.fromRGB(0, 4, 255),
	}

	runtime:TrackConnection(trackObject:GetMarkerReachedSignal("rightSwing"):Connect(function()
		local attachment = runtime:CloneVfxDescendantTo({ "Att", "ArmSwingright" }, rightArm)
		runtime:Emit(attachment)
		runtime:AddDebris(attachment, 0.5)
	end))

	runtime:TrackConnection(trackObject:GetMarkerReachedSignal("leftSwing"):Connect(function()
		local attachment = runtime:CloneVfxDescendantTo({ "Att", "ArmSwingleft" }, leftArm)
		runtime:Emit(attachment)
		runtime:AddDebris(attachment, 0.5)
	end))

	local burstConnection: RBXScriptConnection? = nil
	burstConnection = trackObject:GetMarkerReachedSignal("burst"):Connect(function()
		local burst = runtime:CloneVfxDescendantTo({ "Att", "CelebrationBurst" }, root)
		local pointLight = burst and burst:FindFirstChild("PointLight")
		if pointLight and pointLight:IsA("PointLight") then
			pointLight.Color = colors[math.random(1, #colors)]
		end
		runtime:Emit(burst)
		runtime:AddDebris(burst, 3)
	end)
	runtime:TrackConnection(burstConnection)

	runtime:TrackConnection(trackObject.Ended:Once(function()
		if burstConnection then
			burstConnection:Disconnect()
		end
	end))
end

function Celebration:Finish(_character: Model, runtime)
	local root = runtime:GetRoot()
	runtime:DestroyChild(root, "CelebrationSound")
	runtime:DestroyChild(root, "CelebrationRootAtt")
	runtime:DestroyChild(root, "CelebrationBurst")
end

return Celebration
