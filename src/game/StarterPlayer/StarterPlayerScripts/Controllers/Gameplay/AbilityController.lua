local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local ReplicaController = require(ReplicatedStorage.Packages.ReplicaController)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local REMOTES_FOLDER_NAME = AbilityConfig.RemotesFolderName
local REQUEST_REMOTE_NAME = AbilityConfig.RequestRemoteName
local EFFECT_REMOTE_NAME = AbilityConfig.EffectRemoteName
local ACTIVATE_MESSAGE = AbilityConfig.MessageTypes.Activate
local RENDER_STEP_NAME = "BombBattlesAbilityButtons"
local RENDER_PRIORITY = Enum.RenderPriority.Last.Value
local SIZE_TWEEN = TweenInfo.new(0.24, Enum.EasingStyle.Back)
local FADE_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad)
local HELD_GROW_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HELD_PULSE_TWEEN = TweenInfo.new(0.52, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local READY_COLOR = Color3.fromRGB(255, 255, 255)
local HELD_COLOR = Color3.fromRGB(255, 255, 255)
local HELD_SCALE = 1.15
local HELD_PULSE_SCALE = 1.22
local PREDICTION_TIMEOUT_SECONDS = 1.25
local FLIPBOOK_LIFETIME = 0.357

local SLOT_INPUTS = {
	[AbilityConfig.Slots.Offensive] = {
		actionName = "BombBattlesOffensiveAbility",
		keys = { Enum.KeyCode.E, Enum.KeyCode.ButtonL1 },
		buttonName = "OffensiveAbility",
	},
	[AbilityConfig.Slots.Defensive] = {
		actionName = "BombBattlesDefensiveAbility",
		keys = { Enum.KeyCode.Q, Enum.KeyCode.ButtonR1 },
		buttonName = "DefensiveAbility",
	},
}

type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityEffectPayload = AbilityTypes.AbilityEffectPayload
type AbilitySlotState = AbilityTypes.AbilitySlotState
type AbilityState = AbilityTypes.AbilityState
type ClientBehavior = AbilityTypes.ClientBehavior
type PredictedCooldown = {
	abilityId: string,
	startedAt: number,
	endsAt: number,
	duration: number,
	expiresAt: number,
}
type ButtonVisual = {
	button: ImageButton,
	slot: string,
	normalSize: UDim2,
	hovering: boolean,
	pressing: boolean,
	held: boolean,
	heldAbilityId: string,
	heldSerial: number,
	heldGrowTween: Tween?,
	heldPulseTween: Tween?,
	heldColorTween: Tween?,
	onCooldown: boolean,
	cooldownAuthoritative: boolean,
	cooldownAbilityId: string,
	cooldownEndsAt: number,
	cooldownDuration: number,
	cooldownCover: GuiObject?,
	keybindCover: GuiObject?,
	progressValue: NumberValue?,
	progressLabel: TextLabel?,
	leftGradient: UIGradient?,
	rightGradient: UIGradient?,
	explodeEffect: ImageLabel?,
	cooldownEffect: Frame?,
}

local AbilityController = {}

AbilityController.StateReceived = Signal.new()
AbilityController.StateUpdated = Signal.new()
AbilityController.Loaded = false

AbilityController._requestRemote = nil :: RemoteEvent?
AbilityController._effectRemote = nil :: RemoteEvent?
AbilityController._effectConnection = nil :: RBXScriptConnection?
AbilityController._replicaConnection = nil :: RBXScriptConnection?
AbilityController._hudConnections = {} :: { RBXScriptConnection }
AbilityController._buttons = {} :: { [string]: ImageButton }
AbilityController._buttonVisuals = {} :: { [string]: ButtonVisual }
AbilityController._buttonConnections = {} :: { RBXScriptConnection }
AbilityController._data = nil :: AbilityState?
AbilityController._clientSequence = 0
AbilityController._behaviors = {} :: { [string]: ClientBehavior }
AbilityController._predictedCooldowns = {} :: { [string]: PredictedCooldown }

local function getRemote(name: string): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(name, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function loadBehaviors()
	table.clear(AbilityController._behaviors)

	local folder = script.Parent:FindFirstChild("AbilityBehaviors")
	if not folder then
		return
	end

	for _, child in ipairs(folder:GetChildren()) do
		if not child:IsA("ModuleScript") then
			continue
		end

		local ok, behavior = pcall(require, child)
		if ok and typeof(behavior) == "table" then
			AbilityController._behaviors[child.Name] = behavior
		else
			warn("[AbilityController] Failed to load ability behavior " .. child:GetFullName() .. ": " .. tostring(behavior))
		end
	end
end

local function getSlotState(slot: string): AbilitySlotState?
	local data = AbilityController._data
	local slots = data and data.slots
	return if typeof(slots) == "table" then slots[slot] else nil
end

local function getEquippedAbilityId(slot: string): string
	local slotState = getSlotState(slot)
	return if typeof(slotState) == "table" and typeof(slotState.abilityId) == "string" then slotState.abilityId else ""
end

local function getClientBehavior(abilityId: string, definition: AbilityDefinition?): ClientBehavior?
	local behaviorId = AbilityConfig.GetBehaviorId(abilityId)
	if behaviorId == "" and definition and typeof(definition.id) == "string" then
		behaviorId = definition.id
	end

	return AbilityController._behaviors[behaviorId]
end

local function getServerTime(): number
	return workspace:GetServerTimeNow()
end

local function getCharacterParts(): (Model?, Humanoid?, BasePart?)
	local character = LocalPlayer.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	return character, humanoid, if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

local function isActivationAllowed(): boolean
	if not CombatEligibility.IsClientCombatActive(LocalPlayer, RoundController:Get("state"), RoundStates.Active) then
		return false
	end

	local _, humanoid, rootPart = getCharacterParts()
	return humanoid ~= nil and humanoid.Health > 0 and rootPart ~= nil
end

local function isActivationInput(inputState: Enum.UserInputState?): boolean
	return inputState == nil or inputState == Enum.UserInputState.Begin
end

local function getAimPayload(): any
	local camera = workspace.CurrentCamera
	local character = LocalPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	local aimDirection = if camera then camera.CFrame.LookVector else Vector3.zAxis
	if aimDirection.Magnitude > 0.05 then
		aimDirection = aimDirection.Unit
	else
		aimDirection = Vector3.zAxis
	end

	return {
		aimDirection = aimDirection,
		rootPosition = if rootPart and rootPart:IsA("BasePart") then rootPart.Position else nil,
		cameraCFrame = if camera then camera.CFrame else nil,
		mouseLocation = UserInputService:GetMouseLocation(),
	}
end

local function getCooldownRemaining(slotState: AbilitySlotState?): number
	if typeof(slotState) ~= "table" or typeof(slotState.cooldownEndsAt) ~= "number" then
		return 0
	end

	return math.max(slotState.cooldownEndsAt - getServerTime(), 0)
end

local function getDefinitionCooldown(definition: AbilityDefinition?): number
	return if definition and typeof(definition.cooldownSeconds) == "number" then math.max(definition.cooldownSeconds, 0) else 0
end

local function scaleUDim2(value: UDim2, factor: number): UDim2
	return UDim2.new(value.X.Scale * factor, value.X.Offset * factor, value.Y.Scale * factor, value.Y.Offset * factor)
end

local function findChild(parent: Instance?, childName: string, recursive: boolean?): Instance?
	return if parent then parent:FindFirstChild(childName, recursive == true) else nil
end

local function findFirstGuiObject(parent: Instance?, childName: string): GuiObject?
	local child = findChild(parent, childName, true)
	return if child and child:IsA("GuiObject") then child else nil
end

local function findFirstTextLabel(parent: Instance?, childName: string): TextLabel?
	local child = findChild(parent, childName, true)
	return if child and child:IsA("TextLabel") then child else nil
end

local function getDefaultSize(button: GuiObject): UDim2
	local value = button:GetAttribute("defaultSize")
	return if typeof(value) == "UDim2" then value else button.Size
end

local function findButtonControls(button: ImageButton): Instance?
	local parent = button.Parent
	if parent then
		local controls = parent:FindFirstChild("ButtonControls")
		if controls then
			return controls
		end
	end

	local hud = button:FindFirstAncestor("HUD") or button:FindFirstAncestor("ScreenGui")
	return findChild(hud, "ButtonControls", true)
end

local function findExplodeEffect(button: ImageButton): ImageLabel?
	local controls = findButtonControls(button)
	local template = findChild(controls, "Flipbook", true)
	return if template and template:IsA("ImageLabel") then template else nil
end

local function findCooldownEffect(button: ImageButton): Frame?
	local controls = findButtonControls(button)
	local template = findChild(controls, "CooldownEffect", true)
	return if template and template:IsA("Frame") then template else nil
end

local function setGuiTransparency(guiObject: GuiObject?, value: number, tween: boolean)
	if not guiObject then
		return
	end

	if guiObject:IsA("ImageLabel") or guiObject:IsA("ImageButton") then
		local properties = { ImageTransparency = value }
		if tween then
			TweenService:Create(guiObject, FADE_TWEEN, properties):Play()
		else
			guiObject.ImageTransparency = value
		end
	elseif guiObject:IsA("TextLabel") or guiObject:IsA("TextButton") then
		local properties = { TextTransparency = value }
		if tween then
			TweenService:Create(guiObject, FADE_TWEEN, properties):Play()
		else
			guiObject.TextTransparency = value
		end
	else
		local properties = { BackgroundTransparency = value }
		if tween then
			TweenService:Create(guiObject, FADE_TWEEN, properties):Play()
		else
			guiObject.BackgroundTransparency = value
		end
	end
end

local function findCooldownGradient(cover: GuiObject?): UIGradient?
	if not cover then
		return nil
	end

	local gradient = cover:FindFirstChildWhichIsA("UIGradient", true)
	if gradient then
		return gradient
	end

	local fillTimer = cover:FindFirstAncestor("FillTimer")
	if fillTimer then
		return fillTimer:FindFirstChildWhichIsA("UIGradient", true)
	end

	return nil
end

local function setCooldownCoverVisual(cover: GuiObject?, visible: boolean, progress: number)
	if not cover then
		return
	end

	cover.Visible = visible
	cover.BackgroundTransparency = 1
	if cover:IsA("ImageLabel") or cover:IsA("ImageButton") then
		cover.ImageTransparency = if visible then 0.25 else 1
	end

	local gradient = findCooldownGradient(cover)
	if gradient then
		gradient.Offset = Vector2.new(0, math.clamp(progress, 0, 1) - 0.5)
	end
end

local function updateCircleMeter(visual: ButtonVisual, progress: number)
	progress = math.clamp(progress, 0, 1)
	if visual.progressValue then
		visual.progressValue.Value = progress
	end
	if visual.rightGradient then
		visual.rightGradient.Rotation = math.clamp(progress * 360, 0, 180)
	end
	if visual.leftGradient then
		visual.leftGradient.Rotation = math.clamp(progress * 360, 180, 360)
	end
end

local function playFlipbook(visual: ButtonVisual)
	local template = visual.explodeEffect
	local keybind = findChild(visual.button, "Keybind")
	if not (template and keybind and keybind:IsA("ImageLabel")) then
		return
	end

	local clone = template:Clone()
	clone.Parent = visual.button
	clone.ImageColor3 = keybind.ImageColor3

	local playSprite = clone:FindFirstChild("PlaySprite")
	if playSprite and playSprite:IsA("LocalScript") then
		playSprite.Enabled = true
	end

	task.delay(FLIPBOOK_LIFETIME, function()
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

local function playCooldownFinishedEffect(visual: ButtonVisual)
	local template = visual.cooldownEffect
	local keybind = findChild(visual.button, "Keybind")
	if not (template and keybind and keybind:IsA("ImageLabel")) then
		return
	end

	local clone = template:Clone()
	clone.Parent = visual.button
	clone.Size = UDim2.fromScale(0, 0)
	clone.BackgroundTransparency = 0
	clone.BackgroundColor3 = keybind.ImageColor3

	local stroke = clone:FindFirstChildWhichIsA("UIStroke")
	if stroke then
		stroke.Color = keybind.ImageColor3
		stroke.Transparency = 0
	end

	TweenService:Create(clone, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
		Size = UDim2.fromScale(1.1, 1.1),
		BackgroundTransparency = 1,
	}):Play()

	if stroke then
		TweenService:Create(stroke, TweenInfo.new(0.4, Enum.EasingStyle.Quad), {
			Thickness = 0,
			Transparency = 1,
		}):Play()
	end

	task.delay(0.3, function()
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

local function setButtonSize(visual: ButtonVisual, size: UDim2)
	TweenService:Create(visual.button, SIZE_TWEEN, {
		Size = size,
	}):Play()
end

local function cancelTween(tween: Tween?)
	if tween then
		tween:Cancel()
	end
end

local function getRestingSize(visual: ButtonVisual): UDim2
	return if visual.hovering then scaleUDim2(visual.normalSize, 1.1) else visual.normalSize
end

local function stopHeldVisual(visual: ButtonVisual)
	if not visual.held and not (visual.heldGrowTween or visual.heldPulseTween or visual.heldColorTween) then
		return
	end

	visual.held = false
	visual.heldAbilityId = ""
	visual.heldSerial += 1
	cancelTween(visual.heldGrowTween)
	cancelTween(visual.heldPulseTween)
	cancelTween(visual.heldColorTween)
	visual.heldGrowTween = nil
	visual.heldPulseTween = nil
	visual.heldColorTween = nil

	if visual.button.Parent and not visual.onCooldown then
		TweenService:Create(visual.button, SIZE_TWEEN, {
			Size = getRestingSize(visual),
			ImageColor3 = READY_COLOR,
		}):Play()
	end
end

local function startHeldVisual(visual: ButtonVisual)
	if visual.held or visual.onCooldown or getEquippedAbilityId(visual.slot) == "" or not isActivationAllowed() then
		return
	end

	visual.held = true
	visual.heldAbilityId = getEquippedAbilityId(visual.slot)
	visual.heldSerial += 1
	local serial = visual.heldSerial
	cancelTween(visual.heldGrowTween)
	cancelTween(visual.heldPulseTween)
	cancelTween(visual.heldColorTween)

	local heldSize = scaleUDim2(visual.normalSize, HELD_SCALE)
	local pulseSize = scaleUDim2(visual.normalSize, HELD_PULSE_SCALE)

	visual.heldGrowTween = TweenService:Create(visual.button, HELD_GROW_TWEEN, {
		Size = heldSize,
		ImageColor3 = HELD_COLOR,
	})
	visual.heldGrowTween.Completed:Once(function()
		if serial ~= visual.heldSerial or not visual.held or visual.onCooldown or not visual.button.Parent then
			return
		end

		visual.heldPulseTween = TweenService:Create(visual.button, HELD_PULSE_TWEEN, {
			Size = pulseSize,
		})
		visual.heldPulseTween:Play()
	end)
	visual.heldGrowTween:Play()

	visual.heldColorTween = TweenService:Create(visual.button, FADE_TWEEN, {
		ImageColor3 = HELD_COLOR,
	})
	visual.heldColorTween:Play()
end

local function setButtonCooldownState(
	visual: ButtonVisual,
	abilityId: string,
	remaining: number,
	cooldown: number,
	authoritative: boolean
)
	local button = visual.button
	local onCooldown = abilityId ~= "" and remaining > 0 and cooldown > 0
	local progress = if onCooldown then math.clamp(remaining / math.max(cooldown, 0.001), 0, 1) else 0
	if visual.held and visual.heldAbilityId ~= abilityId then
		stopHeldVisual(visual)
	end

	if onCooldown and not visual.onCooldown then
		stopHeldVisual(visual)
		visual.cooldownAuthoritative = authoritative
		visual.cooldownAbilityId = abilityId
		visual.cooldownEndsAt = getServerTime() + remaining
		visual.cooldownDuration = cooldown
		button:SetAttribute("OnCooldown", true)
		TweenService:Create(button, SIZE_TWEEN, {
			Size = scaleUDim2(getDefaultSize(button), 0.9),
			ImageColor3 = READY_COLOR,
		}):Play()
		setGuiTransparency(visual.keybindCover, 0.25, true)
		playFlipbook(visual)
	elseif not onCooldown and visual.onCooldown then
		local shouldPlayCooldownEffect = visual.cooldownAuthoritative
		visual.cooldownAuthoritative = false
		visual.cooldownAbilityId = ""
		visual.cooldownEndsAt = 0
		visual.cooldownDuration = 0
		button:SetAttribute("OnCooldown", false)
		setButtonSize(visual, if visual.hovering then scaleUDim2(visual.normalSize, 1.1) else visual.normalSize)
		setGuiTransparency(visual.keybindCover, 1, true)
		if shouldPlayCooldownEffect then
			playCooldownFinishedEffect(visual)
		end
	elseif onCooldown then
		visual.cooldownAuthoritative = visual.cooldownAuthoritative or authoritative
		visual.cooldownEndsAt = getServerTime() + remaining
		visual.cooldownDuration = cooldown
	elseif abilityId == "" then
		stopHeldVisual(visual)
	end

	visual.onCooldown = onCooldown
	setCooldownCoverVisual(visual.cooldownCover, onCooldown, progress)
	updateCircleMeter(visual, progress)
	if visual.progressLabel then
		visual.progressLabel.Text = if onCooldown then string.format("%.1fs", remaining) else ""
	end
end

local function createButtonVisual(slot: string, button: ImageButton): ButtonVisual
	button:SetAttribute("defaultSize", button.Size)
	button.AutoButtonColor = false

	local cooldownCover = findFirstGuiObject(button, "CooldownCover")
	local keybind = findChild(button, "Keybind")
	local keybindCover = findFirstGuiObject(keybind, "CooldownCover")
	local roundMeter = findChild(button, "RoundMeter", true) or findChild(button, "FillTimer", true) or button
	local leftCircle = findChild(roundMeter, "LHalf", true)
	local rightCircle = findChild(roundMeter, "RHalf", true)
	leftCircle = findChild(leftCircle, "Circle", true) or findChild(button, "LeftCircle", true)
	rightCircle = findChild(rightCircle, "Circle", true) or findChild(button, "RightCircle", true)
	local progressValue = findChild(roundMeter, "Progress", true)

	return {
		button = button,
		slot = slot,
		normalSize = button.Size,
		hovering = false,
		pressing = false,
		held = false,
		heldAbilityId = "",
		heldSerial = 0,
		heldGrowTween = nil,
		heldPulseTween = nil,
		heldColorTween = nil,
		onCooldown = false,
		cooldownAuthoritative = false,
		cooldownAbilityId = "",
		cooldownEndsAt = 0,
		cooldownDuration = 0,
		cooldownCover = cooldownCover,
		keybindCover = keybindCover,
		progressValue = if progressValue and progressValue:IsA("NumberValue") then progressValue else nil,
		progressLabel = findFirstTextLabel(roundMeter, "ProgressLabel")
			or findFirstTextLabel(button, "CooldownLabel")
			or findFirstTextLabel(button, "TimerLabel"),
		leftGradient = if leftCircle then leftCircle:FindFirstChildWhichIsA("UIGradient", true) else nil,
		rightGradient = if rightCircle then rightCircle:FindFirstChildWhichIsA("UIGradient", true) else nil,
		explodeEffect = findExplodeEffect(button),
		cooldownEffect = findCooldownEffect(button),
	}
end

local function getEffectiveCooldown(
	slot: string,
	abilityId: string,
	definition: AbilityDefinition?,
	slotState: AbilitySlotState?
): (number, number, boolean)
	local cooldown = getDefinitionCooldown(definition)
	local serverRemaining = getCooldownRemaining(slotState)
	if serverRemaining > 0 then
		AbilityController._predictedCooldowns[slot] = nil
		return serverRemaining, cooldown, true
	end

	local predicted = AbilityController._predictedCooldowns[slot]
	local currentTime = getServerTime()
	if predicted and predicted.abilityId == abilityId and predicted.endsAt > currentTime and predicted.expiresAt > currentTime then
		return predicted.endsAt - currentTime, predicted.duration, false
	end

	if predicted then
		AbilityController._predictedCooldowns[slot] = nil
	end
	return 0, cooldown, false
end

local function publishDebugState()
	LocalPlayer:SetAttribute("AbilityController_Loaded", AbilityController.Loaded)
	for _, slot in ipairs(AbilityConfig.SlotOrder) do
		LocalPlayer:SetAttribute("AbilityController_" .. slot .. "AbilityId", getEquippedAbilityId(slot))
		LocalPlayer:SetAttribute("AbilityController_" .. slot .. "CooldownRemaining", getCooldownRemaining(getSlotState(slot)))
	end
end

function AbilityController:_disconnectButtons()
	for _, visual in pairs(self._buttonVisuals) do
		stopHeldVisual(visual)
	end
	for _, connection in ipairs(self._buttonConnections) do
		connection:Disconnect()
	end
	self._buttonConnections = {}
	self._buttons = {}
	self._buttonVisuals = {}
end

function AbilityController:_setSlotHeld(slot: string, held: boolean)
	local visual = self._buttonVisuals[slot]
	if not visual then
		return
	end

	visual.pressing = held
	if held then
		if isActivationAllowed() then
			startHeldVisual(visual)
		else
			stopHeldVisual(visual)
		end
	else
		stopHeldVisual(visual)
	end
end

function AbilityController:_bindButton(slot: string, button: ImageButton)
	self._buttons[slot] = button
	local visual = createButtonVisual(slot, button)
	self._buttonVisuals[slot] = visual

	table.insert(self._buttonConnections, button.MouseEnter:Connect(function()
		visual.hovering = true
		if not visual.onCooldown then
			setButtonSize(visual, scaleUDim2(visual.normalSize, 1.1))
		end
	end))
	table.insert(self._buttonConnections, button.MouseLeave:Connect(function()
		visual.hovering = false
		if not visual.onCooldown and not visual.held then
			setButtonSize(visual, visual.normalSize)
		end
	end))
	table.insert(self._buttonConnections, button.InputBegan:Connect(function(inputObject: InputObject)
		if
			inputObject.UserInputType == Enum.UserInputType.MouseButton1
			or inputObject.UserInputType == Enum.UserInputType.Touch
			or inputObject.KeyCode == Enum.KeyCode.ButtonA
		then
			self:_setSlotHeld(slot, true)
			self:ActivateSlot(slot, Enum.UserInputState.Begin, inputObject)
		end
	end))
	table.insert(self._buttonConnections, button.InputEnded:Connect(function(inputObject: InputObject)
		if
			inputObject.UserInputType == Enum.UserInputType.MouseButton1
			or inputObject.UserInputType == Enum.UserInputType.Touch
			or inputObject.KeyCode == Enum.KeyCode.ButtonA
		then
			self:_setSlotHeld(slot, false)
			self:ActivateSlot(slot, Enum.UserInputState.End, inputObject)
		end
	end))
end

function AbilityController:_bindHud(hud: Instance?)
	self:_disconnectButtons()
	if not hud then
		return
	end

	local buttons = hud:FindFirstChild("Buttons")
	if not buttons then
		return
	end

	for slot, input in pairs(SLOT_INPUTS) do
		local button = buttons:FindFirstChild(input.buttonName)
		if button and button:IsA("ImageButton") then
			self:_bindButton(slot, button)
		end
	end

	self:_updateButtons()
end

function AbilityController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild("HUD") or PlayerGui:FindFirstChild("ScreenGui"))
end

function AbilityController:_updateButtons()
	local activationAllowed = isActivationAllowed()
	for slot, button in pairs(self._buttons) do
		local abilityId = getEquippedAbilityId(slot)
		local definition = AbilityConfig.GetDefinition(abilityId)
		local slotState = getSlotState(slot)
		local remaining, cooldown, authoritative = getEffectiveCooldown(slot, abilityId, definition, slotState)
		local icon = button:FindFirstChild("Icon")
		if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
			local image = if definition and typeof(definition.icon) == "string" then definition.icon else ""
			icon.Image = image
			icon.Visible = image ~= ""
		end

		button.Active = activationAllowed and abilityId ~= "" and remaining <= 0
		button:SetAttribute("AbilityId", abilityId)
		button:SetAttribute("CooldownRemaining", remaining)
		button:SetAttribute("AbilityDisplayName", if definition then definition.displayName else "")
		local visual = self._buttonVisuals[slot]
		if visual then
			if not activationAllowed then
				stopHeldVisual(visual)
			end
			setButtonCooldownState(visual, abilityId, remaining, cooldown, authoritative)
		end
	end
end

function AbilityController:_bindReplica(replica: any)
	if replica.Tags.Player ~= LocalPlayer then
		return
	end

	self._data = replica.Data
	self.Loaded = true
	self.StateReceived:Fire(self._data)
	self:_updateButtons()
	publishDebugState()

	replica:ListenToRaw(function(action, path, ...)
		if action == "SetValue" then
			self.StateUpdated:Fire(path, ...)
			self:_updateButtons()
			publishDebugState()
		elseif action == "SetValues" then
			self.StateUpdated:Fire(path, ...)
			self:_updateButtons()
			publishDebugState()
		end
	end)
end

function AbilityController:_bindEffects()
	if self._effectConnection then
		self._effectConnection:Disconnect()
		self._effectConnection = nil
	end

	if not self._effectRemote then
		return
	end

	self._effectConnection = self._effectRemote.OnClientEvent:Connect(function(effectName: string, payload: any)
		local token = RuntimeProfiler.Begin("Client/AbilityController/EffectRemote")
		RuntimeProfiler.Count("Client/AbilityController/Effects")
		RuntimeProfiler.Count("Client/AbilityController/EffectPayloadWeight", RuntimeProfiler.EstimatePayloadWeight(payload, 128))
		if typeof(payload) ~= "table" then
			RuntimeProfiler.End("Client/AbilityController/EffectRemote", token)
			return
		end

		local abilityId = payload.abilityId
		if typeof(abilityId) == "string" and abilityId ~= "" then
			RuntimeProfiler.Count("Client/AbilityController/Effect/" .. abilityId)
		end
		local behavior = if typeof(abilityId) == "string" then self._behaviors[abilityId] else nil
		if not behavior and typeof(abilityId) == "string" then
			local definition = AbilityConfig.GetDefinition(abilityId)
			behavior = getClientBehavior(abilityId, definition)
		end
		if behavior and type(behavior.OnEffect) == "function" then
			local behaviorLabel = if typeof(abilityId) == "string"
				then "Client/AbilityController/BehaviorEffect/" .. abilityId
				else "Client/AbilityController/BehaviorEffect/Unknown"
			local behaviorToken = RuntimeProfiler.Begin(behaviorLabel)
			local ok, err = pcall(function()
				behavior.OnEffect({
					effectName = effectName,
					payload = payload :: AbilityEffectPayload,
					localPlayer = LocalPlayer,
					controller = self,
				})
			end)
			RuntimeProfiler.End(behaviorLabel, behaviorToken)
			if not ok then
				warn("[AbilityController] OnEffect failed for " .. abilityId .. ": " .. tostring(err))
			end
		end
		RuntimeProfiler.End("Client/AbilityController/EffectRemote", token)
	end)
end

function AbilityController:_bindInputs()
	for slot, input in pairs(SLOT_INPUTS) do
		ContextActionService:UnbindAction(input.actionName)
		ContextActionService:BindAction(
			input.actionName,
			function(_actionName: string, inputState: Enum.UserInputState, inputObject: InputObject)
				if
					inputState == Enum.UserInputState.Begin
					or inputState == Enum.UserInputState.End
					or inputState == Enum.UserInputState.Cancel
				then
					if inputState == Enum.UserInputState.Begin then
						self:_setSlotHeld(slot, true)
					else
						self:_setSlotHeld(slot, false)
					end
					self:ActivateSlot(slot, inputState, inputObject)
				end
				return Enum.ContextActionResult.Pass
			end,
			false,
			table.unpack(input.keys)
		)
	end
end

function AbilityController:SendMessage(slot: string, messageType: string, payload: any?): boolean
	if not AbilityConfig.IsKnownSlot(slot) then
		return false
	end
	if messageType == ACTIVATE_MESSAGE and not isActivationAllowed() then
		return false
	end

	local abilityId = getEquippedAbilityId(slot)
	if abilityId == "" then
		return false
	end

	local remote = self._requestRemote
	if not remote then
		return false
	end

	self._clientSequence += 1
	remote:FireServer({
		slot = slot,
		abilityId = abilityId,
		messageType = messageType,
		payload = payload,
		clientSequence = self._clientSequence,
	})
	if messageType == ACTIVATE_MESSAGE then
		self:_predictCooldown(slot, abilityId)
	end
	return true
end

function AbilityController:_predictCooldown(slot: string, abilityId: string)
	local definition = AbilityConfig.GetDefinition(abilityId)
	local cooldown = getDefinitionCooldown(definition)
	if cooldown <= 0 then
		return
	end

	local currentTime = getServerTime()
	self._predictedCooldowns[slot] = {
		abilityId = abilityId,
		startedAt = currentTime,
		endsAt = currentTime + cooldown,
		duration = cooldown,
		expiresAt = currentTime + PREDICTION_TIMEOUT_SECONDS,
	}
	self:_updateButtons()
end

function AbilityController:ActivateSlot(slot: string, inputState: Enum.UserInputState?, inputObject: InputObject?): boolean
	local slotState = getSlotState(slot)
	local abilityId = getEquippedAbilityId(slot)
	if abilityId == "" then
		return false
	end
	if isActivationInput(inputState) and not isActivationAllowed() then
		return false
	end

	local definition = AbilityConfig.GetDefinition(abilityId)
	local behavior = getClientBehavior(abilityId, definition)
	if inputState and inputState ~= Enum.UserInputState.Begin then
		if not (behavior and behavior.HandlesInputState == true) then
			return false
		end
	end
	if behavior and type(behavior.OnActivateRequested) == "function" then
		local ok, handled = pcall(function()
			return behavior.OnActivateRequested({
				controller = self,
				localPlayer = LocalPlayer,
				slot = slot,
				abilityId = abilityId,
				definition = definition,
				slotState = slotState,
				inputState = inputState,
				inputObject = inputObject,
			})
		end)
		if not ok then
			warn("[AbilityController] OnActivateRequested failed for " .. abilityId .. ": " .. tostring(handled))
			return false
		end
		if handled == true then
			return true
		end
	end

	if getCooldownRemaining(slotState) > 0 then
		return false
	end

	return self:SendMessage(slot, ACTIVATE_MESSAGE, getAimPayload())
end

function AbilityController:GetCooldownRemaining(slot: string): number
	return getCooldownRemaining(getSlotState(slot))
end

function AbilityController:GetEquippedAbilityId(slot: string): string
	return getEquippedAbilityId(slot)
end

function AbilityController:GetState(): AbilityState?
	return self._data
end

function AbilityController:GetSlotState(slot: string): AbilitySlotState?
	return getSlotState(slot)
end

function AbilityController:OnStart()
	if self._replicaConnection then
		self._replicaConnection:Disconnect()
	end
	self._replicaConnection = ReplicaController.ReplicaOfClassCreated(AbilityConfig.Scope, function(replica)
		self:_bindReplica(replica)
	end)

	publishDebugState()
	for _, connection in ipairs(self._hudConnections) do
		connection:Disconnect()
	end
	self._hudConnections = {}
	self:_disconnectButtons()

	loadBehaviors()
	self._requestRemote = getRemote(REQUEST_REMOTE_NAME)
	self._effectRemote = getRemote(EFFECT_REMOTE_NAME)
	self:_bindEffects()
	self:_bindInputs()

	table.insert(self._hudConnections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == "HUD" or child.Name == "ScreenGui" then
			task.defer(function()
				self:_bindHud(child)
			end)
		end
	end))
	self:_bindCurrentHud()

	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function()
		local token = RuntimeProfiler.Begin("Client/AbilityController/Render")
		self:_updateButtons()
		RuntimeProfiler.End("Client/AbilityController/Render", token)
	end)
end

return AbilityController
