local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local SoundUtil = require(ReplicatedStorage.Shared.Audio.SoundUtil)
local CameraController = require(script.Parent.Parent:WaitForChild("CameraController"))
local MovementController = require(script.Parent.Parent:WaitForChild("MovementController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type PadRecord = {
	id: string,
	model: Instance,
	spring: BasePart,
	raisedCFrame: CFrame,
	compressedCFrame: CFrame,
	facing: Vector3,
	connection: RBXScriptConnection?,
	animationSerial: number,
	lastPredictedAt: number,
}

local JumpPad = {} :: AbilityTypes.ClientBehavior

local LocalPlayer = Players.LocalPlayer
local PAD_ID_ATTR = "JumpPadId"
local ARMED_ATTR = "JumpPadArmed"
local SOUND_ACTIVATE = "JumpPadActivate"
local SOUND_PLACE = "JumpPadPlace"
local SOUND_ARMED = "JumpPadArm"
local SOUND_TRIGGER = "JumpPadTrigger"
local SOUND_FAIL = "JumpPadFail"
local LOCAL_TRIGGER_SUPPRESS_SECONDS = 0.35
local JUMP_ANIMATION_KIND = "DoubleJump"
local PADS_BY_ID: { [string]: PadRecord } = {}

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getRootAndHumanoid(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart, humanoid
	end
	return nil, nil
end

local function playOptionalSound(soundName: string, parent: Instance?)
	SoundUtil.Play(soundName, parent)
end

local function flattenDirection(direction: Vector3, fallback: Vector3?): Vector3
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude >= 0.05 then
		return flat.Unit
	end
	if fallback and fallback.Magnitude >= 0.05 then
		return Vector3.new(fallback.X, 0, fallback.Z).Unit
	end
	return Vector3.zAxis
end

local function findPadModel(padId: string): Instance?
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:GetAttribute(PAD_ID_ATTR) == padId then
			return descendant
		end
	end
	return nil
end

local function findSpring(model: Instance): BasePart?
	local spring = model:FindFirstChild("spring", true)
	if spring and spring:IsA("BasePart") then
		return spring
	end
	return nil
end

local function disconnectRecord(record: PadRecord)
	if record.connection then
		record.connection:Disconnect()
		record.connection = nil
	end
end

local function forgetPad(padId: string)
	local record = PADS_BY_ID[padId]
	if not record then
		return
	end
	disconnectRecord(record)
	PADS_BY_ID[padId] = nil
end

local function getDirection(record: PadRecord, humanoid: Humanoid?, rootPart: BasePart?): Vector3
	if humanoid and humanoid.MoveDirection.Magnitude >= 0.05 then
		return flattenDirection(humanoid.MoveDirection, record.facing)
	end
	if rootPart then
		local velocity = rootPart.AssemblyLinearVelocity
		if Vector3.new(velocity.X, 0, velocity.Z).Magnitude >= 0.05 then
			return flattenDirection(velocity, record.facing)
		end
	end
	return flattenDirection(record.facing, Vector3.zAxis)
end

local function playCameraPunch(definition: AbilityDefinition?)
	if type(CameraController.PlayAbilityFOVPunch) == "function" then
		CameraController:PlayAbilityFOVPunch(
			getDefinitionNumber(definition, "cameraPunchDuration", 0.18),
			getDefinitionNumber(definition, "cameraPunchFOVBonus", 2.6)
		)
	elseif type(CameraController.PlayAirBurstPunch) == "function" then
		CameraController:PlayAirBurstPunch()
	end
end

local function applyLocalLaunch(record: PadRecord, definition: AbilityDefinition?, directionOverride: Vector3?)
	local rootPart, humanoid = getRootAndHumanoid(LocalPlayer)
	if not (rootPart and humanoid) then
		return false
	end

	local direction = if typeof(directionOverride) == "Vector3"
		then flattenDirection(directionOverride, record.facing)
		else getDirection(record, humanoid, rootPart)
	local velocity = rootPart.AssemblyLinearVelocity
	local mass = math.max(rootPart.AssemblyMass, 0)
	if mass <= 0 then
		return false
	end

	local verticalTarget = math.max(getDefinitionNumber(definition, "verticalLaunchVelocity", 95), 0)
	local horizontalTarget = math.max(getDefinitionNumber(definition, "horizontalLaunchSpeed", 48), 0)
	local verticalDelta = math.max(verticalTarget - velocity.Y, 0)
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local forwardSpeed = horizontalVelocity:Dot(direction)
	local horizontalDelta = math.max(horizontalTarget - forwardSpeed, 0)
	local impulse = Vector3.yAxis * verticalDelta * mass + direction * horizontalDelta * mass
	if impulse.Magnitude > 0 then
		rootPart:ApplyImpulse(impulse)
	end

	humanoid.Jump = true
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end)

	local source = if definition and typeof(definition.airControlSource) == "string" then definition.airControlSource else "JumpPad"
	MovementController:RecordExternalAirControlLaunch(
		source,
		getDefinitionNumber(definition, "airControlMinAirTime", 0.24)
	)
	MovementController:PublishExternalJump(JUMP_ANIMATION_KIND)
	return true
end

local function animateSpring(record: PadRecord, definition: AbilityDefinition?)
	local spring = record.spring
	if not spring.Parent then
		return
	end

	record.animationSerial += 1
	local serial = record.animationSerial
	local upSeconds = math.max(getDefinitionNumber(definition, "springUpSeconds", 0.12), 0.01)
	local holdSeconds = math.max(getDefinitionNumber(definition, "springHoldSeconds", 0.08), 0)
	local recompressSeconds = math.max(getDefinitionNumber(definition, "springRecompressSeconds", 0.16), 0.01)

	TweenService:Create(spring, TweenInfo.new(upSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		CFrame = record.raisedCFrame,
	}):Play()

	task.delay(upSeconds + holdSeconds, function()
		if record.animationSerial ~= serial or not spring.Parent then
			return
		end
		TweenService:Create(spring, TweenInfo.new(recompressSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			CFrame = record.compressedCFrame,
		}):Play()
	end)
end

local function handleLocalTouch(record: PadRecord, definition: AbilityDefinition?)
	if not record.model.Parent or record.model:GetAttribute(ARMED_ATTR) ~= true then
		return
	end

	local now = os.clock()
	if now - record.lastPredictedAt < getDefinitionNumber(definition, "triggerCooldownSeconds", 0.65) then
		return
	end

	if applyLocalLaunch(record, definition, nil) then
		record.lastPredictedAt = now
		animateSpring(record, definition)
		playOptionalSound(SOUND_TRIGGER, record.spring)
		playCameraPunch(definition)
	end
end

local function connectLocalTouch(record: PadRecord, definition: AbilityDefinition?)
	disconnectRecord(record)
	record.connection = record.spring.Touched:Connect(function(hit: BasePart)
		local character = LocalPlayer.Character
		if not character or not hit:IsDescendantOf(character) then
			return
		end
		handleLocalTouch(record, definition)
	end)
end

local function registerPad(
	padId: string,
	model: Instance,
	raisedCFrame: CFrame?,
	compressedCFrame: CFrame?,
	definition: AbilityDefinition?
): PadRecord?
	local spring = findSpring(model)
	if not spring then
		return nil
	end

	local record = PADS_BY_ID[padId]
	if not record then
		record = {
			id = padId,
			model = model,
			spring = spring,
			raisedCFrame = raisedCFrame or spring.CFrame,
			compressedCFrame = compressedCFrame or spring.CFrame,
			facing = flattenDirection((raisedCFrame or spring.CFrame).LookVector, nil),
			connection = nil,
			animationSerial = 0,
			lastPredictedAt = -math.huge,
		}
		PADS_BY_ID[padId] = record
	else
		record.model = model
		record.spring = spring
		record.raisedCFrame = raisedCFrame or record.raisedCFrame
		record.compressedCFrame = compressedCFrame or record.compressedCFrame
		record.facing = flattenDirection(record.raisedCFrame.LookVector, record.facing)
	end

	if record.spring.Parent and model:GetAttribute(ARMED_ATTR) == true then
		record.spring.CFrame = record.compressedCFrame
	end
	connectLocalTouch(record, definition)

	model.AncestryChanged:Connect(function()
		if model.Parent then
			return
		end
		forgetPad(padId)
	end)

	return record
end

local function registerPadWhenReplicated(
	padId: string,
	raisedCFrame: CFrame?,
	compressedCFrame: CFrame?,
	definition: AbilityDefinition?,
	onFound: ((PadRecord) -> ())?
)
	local model = findPadModel(padId)
	if model then
		local record = registerPad(padId, model, raisedCFrame, compressedCFrame, definition)
		if record and onFound then
			onFound(record)
		end
		return
	end

	task.spawn(function()
		local deadline = os.clock() + 1.25
		while os.clock() < deadline do
			task.wait(0.05)
			model = findPadModel(padId)
			if model then
				local record = registerPad(padId, model, raisedCFrame, compressedCFrame, definition)
				if record and onFound then
					onFound(record)
				end
				return
			end
		end
	end)
end

function JumpPad.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if context.inputState and context.inputState ~= Enum.UserInputState.Begin then
		return true
	end

	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		context.localPlayer:SetAttribute("JumpPadClientStatus", "Cooldown")
		return true
	end

	if not context.controller:SendMessage(context.slot, AbilityConfig.MessageTypes.Activate, nil) then
		context.localPlayer:SetAttribute("JumpPadClientStatus", "SendFailed")
		return true
	end

	context.localPlayer:SetAttribute("JumpPadClientStatus", "Sent")
	context.localPlayer:SetAttribute("JumpPadClientStatusTime", workspace:GetServerTimeNow())
	playOptionalSound(SOUND_ACTIVATE, getRootAndHumanoid(context.localPlayer))
	return true
end

function JumpPad.OnEffect(context: ClientEffectContext)
	local payload = context.payload.payload
	if typeof(payload) ~= "table" then
		payload = {}
	end

	local definition = AbilityConfig.GetDefinition("JumpPad")
	if context.effectName == "JumpPadPlaced" then
		local padId = if typeof(payload.padId) == "string" then payload.padId else nil
		if not padId then
			return
		end

		registerPadWhenReplicated(
			padId,
			if typeof(payload.raisedCFrame) == "CFrame" then payload.raisedCFrame else nil,
			if typeof(payload.compressedCFrame) == "CFrame" then payload.compressedCFrame else nil,
			definition,
			nil
		)
		if context.payload.player == context.localPlayer then
			playOptionalSound(SOUND_PLACE, getRootAndHumanoid(context.localPlayer))
		end
	elseif context.effectName == "JumpPadArmed" then
		local padId = if typeof(payload.padId) == "string" then payload.padId else nil
		if not padId then
			return
		end

		registerPadWhenReplicated(
			padId,
			if typeof(payload.raisedCFrame) == "CFrame" then payload.raisedCFrame else nil,
			if typeof(payload.compressedCFrame) == "CFrame" then payload.compressedCFrame else nil,
			definition,
			function(record)
				record.model:SetAttribute(ARMED_ATTR, true)
				if context.payload.player == context.localPlayer then
					playOptionalSound(SOUND_ARMED, record.spring)
				end
			end
		)
	elseif context.effectName == "JumpPadTriggered" then
		local padId = if typeof(payload.padId) == "string" then payload.padId else nil
		if not padId then
			return
		end

		local function playTrigger(record: PadRecord)
			local recentPrediction = os.clock() - record.lastPredictedAt <= LOCAL_TRIGGER_SUPPRESS_SECONDS
			if not recentPrediction then
				animateSpring(record, definition)
				playOptionalSound(SOUND_TRIGGER, record.spring)
			end

			if payload.launchedPlayer == context.localPlayer then
				applyLocalLaunch(
					record,
					definition,
					if typeof(payload.direction) == "Vector3" then payload.direction else nil
				)
				playCameraPunch(definition)
			end
		end

		local record = PADS_BY_ID[padId]
		if record then
			playTrigger(record)
		else
			registerPadWhenReplicated(
				padId,
				if typeof(payload.raisedCFrame) == "CFrame" then payload.raisedCFrame else nil,
				if typeof(payload.compressedCFrame) == "CFrame" then payload.compressedCFrame else nil,
				definition,
				playTrigger
			)
		end
	elseif context.effectName == "JumpPadDespawned" then
		local padId = if typeof(payload.padId) == "string" then payload.padId else nil
		if padId then
			forgetPad(padId)
		end
	elseif context.effectName == "JumpPadFailed" then
		context.localPlayer:SetAttribute("JumpPadClientStatus", "Failed")
		context.localPlayer:SetAttribute("JumpPadClientStatusReason", if typeof(payload.reason) == "string" then payload.reason else "")
		context.localPlayer:SetAttribute("JumpPadClientStatusTime", workspace:GetServerTimeNow())
		playOptionalSound(SOUND_FAIL, getRootAndHumanoid(context.localPlayer))
	end
end

return JumpPad
