local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityVisualOverlay = require(ReplicatedStorage.Shared.Effects.AbilityVisualOverlay)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombThrowOrigin = require(ReplicatedStorage.Shared.Common.BombThrowOrigin)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)

local BombHeldVisualFactory = {}

local HELD_VISUAL_NAME = "BombHeldVisual"
local GRIP_ATTACHMENT_NAME = "BombGripAttachment"
local CONSTRAINT_NAME = "BombGripConstraint"
local WELD_NAME = "BombHeldWeld"

local function getHeldGripOffset(): CFrame
	return if typeof(BombConfig.HeldGripOffset) == "CFrame" then BombConfig.HeldGripOffset else CFrame.new()
end

function BombHeldVisualFactory.Create(character: Model, skinId: any, visualScale: number?)
	local gripAttachment = BombThrowOrigin.GetRightGripAttachment(character)
	if not gripAttachment then
		return nil
	end

	local instance, rootPart = BombVisualUtil.CreateBombVisual(skinId, HELD_VISUAL_NAME, {
		anchored = false,
		canCollide = false,
		canQuery = false,
		massless = true,
		effectState = {
			vfx = true,
			fuseSpark = false,
			trail = false,
		},
		visualScale = visualScale,
	})
	if not rootPart then
		instance:Destroy()
		return nil
	end

	instance.Name = HELD_VISUAL_NAME
	if instance:IsA("Model") then
		instance.PrimaryPart = rootPart
	end

	AbilityVisualOverlay.PrepareHeldVisual(instance, rootPart, WELD_NAME)

	local gripOffset = getHeldGripOffset()
	local bombAttachment = Instance.new("Attachment")
	bombAttachment.Name = GRIP_ATTACHMENT_NAME
	bombAttachment.CFrame = gripOffset
	bombAttachment.Parent = rootPart

	local rootCFrame = gripAttachment.WorldCFrame * gripOffset:Inverse()
	if instance:IsA("Model") then
		instance:PivotTo(rootCFrame)
	elseif instance:IsA("BasePart") then
		instance.CFrame = rootCFrame
	end
	instance.Parent = character

	local constraint = Instance.new("RigidConstraint")
	constraint.Name = CONSTRAINT_NAME
	constraint.Attachment0 = gripAttachment
	constraint.Attachment1 = bombAttachment
	constraint.Parent = rootPart

	return {
		instance = instance,
		rootPart = rootPart,
		skinId = skinId,
		visualScale = visualScale,
		highlight = nil,
		pulseConnection = nil,
		fuseStartedAt = nil,
		fuseEndsAt = nil,
		abilityVisualOverlay = nil,
	}
end

function BombHeldVisualFactory.DestroyCharacterVisuals(character: Model?)
	if not character then
		return
	end

	for _, child in ipairs(character:GetChildren()) do
		if child.Name == HELD_VISUAL_NAME then
			child:Destroy()
		end
	end
end

return table.freeze(BombHeldVisualFactory)
