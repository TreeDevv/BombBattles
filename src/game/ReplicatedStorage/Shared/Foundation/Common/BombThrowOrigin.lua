local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)

local BombThrowOrigin = {}

local RIGHT_GRIP_ATTACHMENT_NAME = "RightGripAttachment"
local STABLE_RIGHT_OFFSET = 1.45

local function findAttachment(part: Instance?): Attachment?
	local attachment = part and part:FindFirstChild(RIGHT_GRIP_ATTACHMENT_NAME)
	return if attachment and attachment:IsA("Attachment") then attachment else nil
end

function BombThrowOrigin.GetRightGripAttachment(character: Model?): Attachment?
	if not character then
		return nil
	end

	local rightHandGrip = findAttachment(character:FindFirstChild("RightHand"))
	if rightHandGrip then
		return rightHandGrip
	end

	local rightArmGrip = findAttachment(character:FindFirstChild("Right Arm"))
	if rightArmGrip then
		return rightArmGrip
	end

	local fallbackGrip = character:FindFirstChild(RIGHT_GRIP_ATTACHMENT_NAME, true)
	return if fallbackGrip and fallbackGrip:IsA("Attachment") then fallbackGrip else nil
end

function BombThrowOrigin.GetOrigin(rootPart: BasePart): Vector3
	local baseOffset = BombConfig.ThrowOffset
	return rootPart.CFrame:PointToWorldSpace(Vector3.new(STABLE_RIGHT_OFFSET, baseOffset.Y, baseOffset.Z))
end

return table.freeze(BombThrowOrigin)
