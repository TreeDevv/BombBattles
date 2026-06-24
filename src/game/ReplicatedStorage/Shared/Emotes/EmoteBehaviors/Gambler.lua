local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local Gambler = EmoteEffect.Create("Gambler", { catalogOrder = 12, rarity = "Legendary" })

function Gambler:Begin(_character: Model, runtime)
	local root = runtime:GetRoot()
	local leftArm = runtime:FindPart("Left Arm")
	local rightArm = runtime:FindPart("Right Arm")
	if not root then
		return
	end

	runtime:PlaySound(runtime:GetVfxChild("GamblerSound"), root)

	local aura = runtime:GetVfxChild("Aura")
	local leftE1 = runtime:CloneTo(runtime:GetChild(aura, "E1"), leftArm)
	local leftE2 = runtime:CloneTo(runtime:GetChild(aura, "E2"), leftArm)
	local leftE3 = runtime:CloneTo(runtime:GetChild(aura, "E3"), leftArm)
	local rightE1 = runtime:CloneTo(runtime:GetChild(aura, "E1"), rightArm)
	local rightE2 = runtime:CloneTo(runtime:GetChild(aura, "E2"), rightArm)
	local rightE3 = runtime:CloneTo(runtime:GetChild(aura, "E3"), rightArm)

	local windupTrack = runtime:PlayAnimation("Windup", 0.1, nil)
	if not windupTrack then
		return
	end

	runtime:TrackConnection(windupTrack:GetMarkerReachedSignal("Finished"):Once(function()
		runtime:SafeDestroy(leftE1)
		runtime:SafeDestroy(leftE2)
		runtime:SafeDestroy(leftE3)
		runtime:SafeDestroy(rightE1)
		runtime:SafeDestroy(rightE2)
		runtime:SafeDestroy(rightE3)

		local loopTrack = runtime:PlayAnimation("Animation1", nil, true)
		if not loopTrack then
			return
		end

		local auraAttachment = runtime:CloneTo(runtime:GetChild(aura, "AuraAtt"), root)
		runtime:TrackConnection(loopTrack:GetMarkerReachedSignal("burst"):Connect(function()
			local localPlayer = EmoteEffect.GetLocalPlayer()
			if localPlayer and localPlayer.Name == runtime.character.Name then
				runtime:PlaySmallCameraShake()
			end
			local emitTarget = auraAttachment and auraAttachment:FindFirstChild("Emit")
			runtime:Emit(emitTarget or auraAttachment)
			runtime:SpawnGamblerAfterimage()
		end))
	end))
end

function Gambler:Finish(_character: Model, runtime)
	local root = runtime:GetRoot()
	local leftArm = runtime:FindPart("Left Arm")
	local rightArm = runtime:FindPart("Right Arm")

	runtime:DestroyChild(root, "GamblerSound")
	runtime:DestroyChild(root, "AuraAtt")
	runtime:DestroyChild(leftArm, "E1")
	runtime:DestroyChild(leftArm, "E2")
	runtime:DestroyChild(leftArm, "E3")
	runtime:DestroyChild(rightArm, "E1")
	runtime:DestroyChild(rightArm, "E2")
	runtime:DestroyChild(rightArm, "E3")
end

return Gambler
