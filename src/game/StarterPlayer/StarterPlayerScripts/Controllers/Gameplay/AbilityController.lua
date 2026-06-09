local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local ReplicaController = require(ReplicatedStorage.Packages.ReplicaController)
local Signal = require(ReplicatedStorage.Shared.Common.Signal)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local REMOTES_FOLDER_NAME = AbilityConfig.RemotesFolderName
local REQUEST_REMOTE_NAME = AbilityConfig.RequestRemoteName
local EFFECT_REMOTE_NAME = AbilityConfig.EffectRemoteName
local ACTIVATE_MESSAGE = AbilityConfig.MessageTypes.Activate
local RENDER_STEP_NAME = "BombBattlesAbilityButtons"
local RENDER_PRIORITY = Enum.RenderPriority.Last.Value

local SLOT_INPUTS = {
	[AbilityConfig.Slots.Offensive] = {
		actionName = "BombBattlesOffensiveAbility",
		keys = { Enum.KeyCode.Q, Enum.KeyCode.ButtonL1 },
		buttonName = "OffensiveAbility",
	},
	[AbilityConfig.Slots.Defensive] = {
		actionName = "BombBattlesDefensiveAbility",
		keys = { Enum.KeyCode.E, Enum.KeyCode.ButtonR1 },
		buttonName = "DefensiveAbility",
	},
}

type AbilityDefinition = AbilityTypes.AbilityDefinition
type AbilityEffectPayload = AbilityTypes.AbilityEffectPayload
type AbilitySlotState = AbilityTypes.AbilitySlotState
type AbilityState = AbilityTypes.AbilityState
type ClientBehavior = AbilityTypes.ClientBehavior

local AbilityController = {}

AbilityController.StateReceived = Signal.new()
AbilityController.StateUpdated = Signal.new()
AbilityController.Loaded = false

AbilityController._requestRemote = nil :: RemoteEvent?
AbilityController._effectRemote = nil :: RemoteEvent?
AbilityController._effectConnection = nil :: RBXScriptConnection?
AbilityController._hudConnections = {} :: { RBXScriptConnection }
AbilityController._buttons = {} :: { [string]: ImageButton }
AbilityController._buttonConnections = {} :: { RBXScriptConnection }
AbilityController._data = nil :: AbilityState?
AbilityController._clientSequence = 0
AbilityController._behaviors = {} :: { [string]: ClientBehavior }

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

local function publishDebugState()
	LocalPlayer:SetAttribute("AbilityController_Loaded", AbilityController.Loaded)
	for _, slot in ipairs(AbilityConfig.SlotOrder) do
		LocalPlayer:SetAttribute("AbilityController_" .. slot .. "AbilityId", getEquippedAbilityId(slot))
		LocalPlayer:SetAttribute("AbilityController_" .. slot .. "CooldownRemaining", getCooldownRemaining(getSlotState(slot)))
	end
end

local function setCooldownCover(button: ImageButton, visible: boolean, progress: number)
	local cover = button:FindFirstChild("CooldownCover")
	if cover and cover:IsA("GuiObject") then
		cover.Visible = visible
		cover.BackgroundTransparency = 1
		if cover:IsA("ImageLabel") or cover:IsA("ImageButton") then
			cover.ImageTransparency = if visible then math.clamp(0.18 + (progress * 0.55), 0, 1) else 1
		end
	end

	button:SetAttribute("OnCooldown", visible)
end

function AbilityController:_disconnectButtons()
	for _, connection in ipairs(self._buttonConnections) do
		connection:Disconnect()
	end
	self._buttonConnections = {}
	self._buttons = {}
end

function AbilityController:_bindButton(slot: string, button: ImageButton)
	self._buttons[slot] = button
	table.insert(self._buttonConnections, button.InputBegan:Connect(function(inputObject: InputObject)
		if
			inputObject.UserInputType == Enum.UserInputType.MouseButton1
			or inputObject.UserInputType == Enum.UserInputType.Touch
			or inputObject.KeyCode == Enum.KeyCode.ButtonA
		then
			self:ActivateSlot(slot, Enum.UserInputState.Begin, inputObject)
		end
	end))
	table.insert(self._buttonConnections, button.InputEnded:Connect(function(inputObject: InputObject)
		if
			inputObject.UserInputType == Enum.UserInputType.MouseButton1
			or inputObject.UserInputType == Enum.UserInputType.Touch
			or inputObject.KeyCode == Enum.KeyCode.ButtonA
		then
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
	for slot, button in pairs(self._buttons) do
		local abilityId = getEquippedAbilityId(slot)
		local definition = AbilityConfig.GetDefinition(abilityId)
		local slotState = getSlotState(slot)
		local remaining = getCooldownRemaining(slotState)
		local cooldown = if definition and typeof(definition.cooldownSeconds) == "number" then definition.cooldownSeconds else 0
		local progress = if cooldown > 0 then math.clamp(remaining / cooldown, 0, 1) else 0
		local icon = button:FindFirstChild("Icon")
		if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) then
			local image = if definition and typeof(definition.icon) == "string" then definition.icon else ""
			icon.Image = image
			icon.Visible = image ~= ""
		end

		button.Active = abilityId ~= "" and remaining <= 0
		button:SetAttribute("AbilityId", abilityId)
		button:SetAttribute("CooldownRemaining", remaining)
		button:SetAttribute("AbilityDisplayName", if definition then definition.displayName else "")
		setCooldownCover(button, remaining > 0, progress)
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
		if typeof(payload) ~= "table" then
			return
		end

		local abilityId = payload.abilityId
		local behavior = if typeof(abilityId) == "string" then self._behaviors[abilityId] else nil
		if not behavior and typeof(abilityId) == "string" then
			local definition = AbilityConfig.GetDefinition(abilityId)
			behavior = getClientBehavior(abilityId, definition)
		end
		if behavior and type(behavior.OnEffect) == "function" then
			local ok, err = pcall(function()
				behavior.OnEffect({
					effectName = effectName,
					payload = payload :: AbilityEffectPayload,
					localPlayer = LocalPlayer,
					controller = self,
				})
			end)
			if not ok then
				warn("[AbilityController] OnEffect failed for " .. abilityId .. ": " .. tostring(err))
			end
		end
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
	return true
end

function AbilityController:ActivateSlot(slot: string, inputState: Enum.UserInputState?, inputObject: InputObject?): boolean
	local slotState = getSlotState(slot)
	local abilityId = getEquippedAbilityId(slot)
	if abilityId == "" then
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

	ReplicaController.ReplicaOfClassCreated(AbilityConfig.Scope, function(replica)
		self:_bindReplica(replica)
	end)
	ReplicaController.RequestData()

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
		self:_updateButtons()
	end)
end

return AbilityController
