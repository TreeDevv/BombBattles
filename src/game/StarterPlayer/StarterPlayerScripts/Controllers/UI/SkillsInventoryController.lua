local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local DataController = require(script.Parent:WaitForChild("DataController"))
local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = "SkillsInventory"
local FRAMES_GUI_NAME = "Frames"
local HUD_GUI_NAME = "HUD"
local SIDE_BUTTONS_NAME = "SideButtons"
local SKILLS_BUTTON_NAME = "Skills"
local SKILLS_LABEL_TEXT = "SKILLS"
local HUD_TOGGLE_DEBOUNCE_SECONDS = 0.08
local TILE_SLOT_NAME = "SkillsInventoryTileSlot"
local TILE_SCALE_NAME = "SkillsInventoryVisualScale"
local TILE_HOVER_SIZE_FACTOR = 1.01
local TILE_PRESSED_SIZE_FACTOR = 0.9
local TILE_TWEEN_INFO = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICK_SOUND_NAME = "UIButtonClickSound"
local CLICK_SOUND_ID = "rbxassetid://5852470908"
local CLICK_SOUND_VOLUME = 0.6

local OWNED_KEY = Schema.OwnedAbilities and Schema.OwnedAbilities.key or "ownedAbilities"
local LOADOUT_KEY = Schema.AbilityLoadout and Schema.AbilityLoadout.key or "abilityLoadout"

type TileRecord = {
	button: ImageButton,
	layoutObject: GuiObject,
	abilityId: string,
	slot: string,
	normalSize: UDim2,
}

type TileButtonRecord = {
	button: ImageButton,
	layoutObject: GuiObject,
	index: number,
}

local SkillsInventoryController = {}

SkillsInventoryController._connections = {} :: { RBXScriptConnection }
SkillsInventoryController._frameConnections = {} :: { RBXScriptConnection }
SkillsInventoryController._hudConnections = {} :: { RBXScriptConnection }
SkillsInventoryController._tileConnections = {} :: { RBXScriptConnection }
SkillsInventoryController._frame = nil :: GuiObject?
SkillsInventoryController._right = nil :: Instance?
SkillsInventoryController._topbar = nil :: Instance?
SkillsInventoryController._containers = {} :: { [string]: GuiObject }
SkillsInventoryController._tilesByAbilityId = {} :: { [string]: TileRecord }
SkillsInventoryController._tileTweens = {} :: { [ImageButton]: Tween }
SkillsInventoryController._selectedSlot = AbilityConfig.Slots.Offensive
SkillsInventoryController._selectedAbilityId = ""
SkillsInventoryController._remote = nil :: RemoteEvent?
SkillsInventoryController._statusByAbilityId = {} :: { [string]: string }
SkillsInventoryController._lastHudToggleAt = 0

local function track(list: { RBXScriptConnection }, connection: RBXScriptConnection?)
	if connection then
		table.insert(list, connection)
	end
end

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in ipairs(list) do
		connection:Disconnect()
	end
	table.clear(list)
end

local function findTextLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findImage(parent: Instance?, name: string): (ImageLabel | ImageButton)?
	local child = parent and parent:FindFirstChild(name)
	return if child and (child:IsA("ImageLabel") or child:IsA("ImageButton")) then child else nil
end

local function findButton(parent: Instance?, name: string): ImageButton?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("ImageButton") then child else nil
end

local function setButtonLabel(button: ImageButton?, text: string)
	local label = findTextLabel(button, "Label")
	if label then
		label.Text = text
	end
end

local function setButtonEnabled(button: ImageButton?, enabled: boolean)
	if not button then
		return
	end

	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
end

local function setButtonVisible(button: ImageButton?, visible: boolean)
	if not button then
		return
	end

	button.Visible = visible
	setButtonEnabled(button, visible)
end

local function setBuyPrice(button: ImageButton?, price: number)
	if not button then
		return
	end

	local cost = button:FindFirstChild("Cost")
	local statNumber = findTextLabel(cost, "StatNumber")
	if statNumber then
		statNumber.Text = tostring(math.max(math.floor(price), 0))
	end
end

local function scaleUDim2(size: UDim2, factor: number): UDim2
	return UDim2.fromScale(size.X.Scale * factor, size.Y.Scale * factor)
end

local function getClickSound(): Sound
	local existing = PlayerGui:FindFirstChild(CLICK_SOUND_NAME)
	if existing and existing:IsA("Sound") then
		return existing
	end

	local clickSound = Instance.new("Sound")
	clickSound.Name = CLICK_SOUND_NAME
	clickSound.SoundId = CLICK_SOUND_ID
	clickSound.Volume = CLICK_SOUND_VOLUME
	clickSound.Parent = PlayerGui
	return clickSound
end

local function playClick()
	local clickSound = getClickSound()
	clickSound.TimePosition = 0
	clickSound:Play()
end

local function getRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(AbilityConfig.RemotesFolderName, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(AbilityConfig.InventoryRequestRemoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getOwnedAbilities(): { [string]: boolean }
	local rawOwned = DataController:Get(OWNED_KEY)
	local owned = {}
	if typeof(rawOwned) ~= "table" then
		return owned
	end

	for key, child in pairs(rawOwned) do
		local abilityId = nil
		if typeof(key) == "string" and child == true then
			abilityId = key
		elseif typeof(child) == "string" then
			abilityId = child
		end

		if abilityId then
			local normalizedAbilityId = AbilityConfig.NormalizeAbilityId(abilityId)
			if AbilityConfig.IsCatalogAbility(normalizedAbilityId) then
				owned[normalizedAbilityId] = true
			end
		end
	end

	return owned
end

local function getLoadout(): { [string]: string }
	local rawLoadout = DataController:Get(LOADOUT_KEY)
	local loadout = {}

	for _, slot in ipairs(AbilityConfig.SlotOrder) do
		loadout[slot] = AbilityConfig.GetSlotAbility(rawLoadout, slot)
	end

	return loadout
end

local function findAbilityContainer(frame: Instance, name: string): GuiObject?
	for _, child in ipairs(frame:GetChildren()) do
		if child.Name == name and child:IsA("GuiObject") and child:FindFirstChildWhichIsA("ScrollingFrame") then
			return child
		end
	end

	return nil
end

local function getTileButtonRecords(scroller: ScrollingFrame): { TileButtonRecord }
	local records = {}
	for index, child in ipairs(scroller:GetChildren()) do
		local button = nil
		local layoutObject = nil

		if child:IsA("ImageButton") then
			button = child
			layoutObject = child
		elseif child:IsA("GuiObject") then
			local nestedButton = child:FindFirstChild("IndexButton")
			if nestedButton and nestedButton:IsA("ImageButton") then
				button = nestedButton
				layoutObject = child
			end
		end

		if button and layoutObject then
			table.insert(records, {
				index = index,
				button = button,
				layoutObject = layoutObject,
			})
		end
	end

	table.sort(records, function(left, right)
		if left.layoutObject.LayoutOrder == right.layoutObject.LayoutOrder then
			return left.index < right.index
		end
		return left.layoutObject.LayoutOrder < right.layoutObject.LayoutOrder
	end)

	return records
end

local function findSkillsButton(hud: Instance?): ImageButton?
	local sideButtons = hud and hud:FindFirstChild(SIDE_BUTTONS_NAME)
	if not sideButtons then
		return nil
	end

	local namedButton = sideButtons:FindFirstChild(SKILLS_BUTTON_NAME)
	if namedButton and namedButton:IsA("ImageButton") then
		return namedButton
	end

	for _, child in ipairs(sideButtons:GetChildren()) do
		if child:IsA("ImageButton") then
			local label = findTextLabel(child, "Label")
			if label and string.upper(label.Text) == SKILLS_LABEL_TEXT then
				return child
			end
		end
	end

	return nil
end

local function ensureFrameRegistered(frame: GuiObject)
	local frameTag = FrameController.FrameTag or "Frame"
	if not CollectionService:HasTag(frame, frameTag) then
		CollectionService:AddTag(frame, frameTag)
	end

	local exclusiveAttribute = FrameController.ExclusiveAttribute or "Exclusive"
	if frame:GetAttribute(exclusiveAttribute) ~= true then
		frame:SetAttribute(exclusiveAttribute, true)
	end
end

local function disableAuthoredTileTweenScripts(scroller: ScrollingFrame)
	for _, descendant in ipairs(scroller:GetDescendants()) do
		if descendant:IsA("LocalScript") then
			descendant.Enabled = false
		end
	end
end

local function restoreRuntimeTileSlots(scroller: ScrollingFrame)
	for _, child in ipairs(scroller:GetChildren()) do
		if not (child:IsA("GuiObject") and child.Name == TILE_SLOT_NAME) then
			continue
		end

		local button = child:FindFirstChild("IndexButton")
		if button and button:IsA("ImageButton") then
			button.AnchorPoint = Vector2.new(0.5, 0.5)
			button.Position = UDim2.fromScale(0, 0)
			button.Size = child.Size
			button.LayoutOrder = child.LayoutOrder
			button.Visible = child.Visible
			button.Parent = scroller
		end

		child:Destroy()
	end
end

local function removeRuntimeTileScales(scroller: ScrollingFrame)
	for _, descendant in ipairs(scroller:GetDescendants()) do
		if descendant:IsA("UIScale") and descendant.Name == TILE_SCALE_NAME then
			descendant:Destroy()
		end
	end
end

function SkillsInventoryController:_cancelTileTween(button: ImageButton)
	local tween = self._tileTweens[button]
	if tween then
		tween:Cancel()
		self._tileTweens[button] = nil
	end
end

function SkillsInventoryController:_tweenTileButton(button: ImageButton, size: UDim2)
	self:_cancelTileTween(button)

	local tween = TweenService:Create(button, TILE_TWEEN_INFO, { Size = size })
	self._tileTweens[button] = tween
	tween.Completed:Once(function()
		if self._tileTweens[button] == tween then
			self._tileTweens[button] = nil
		end
	end)
	tween:Play()
end

function SkillsInventoryController:_disconnectHud()
	disconnectAll(self._hudConnections)
end

function SkillsInventoryController:_disconnectTiles()
	for button, tween in pairs(self._tileTweens) do
		tween:Cancel()
		self._tileTweens[button] = nil
	end

	for _, record in pairs(self._tilesByAbilityId) do
		record.button.Size = record.normalSize
	end

	disconnectAll(self._tileConnections)
	table.clear(self._tilesByAbilityId)
end

function SkillsInventoryController:_disconnectFrame()
	disconnectAll(self._frameConnections)
	self:_disconnectTiles()
end

function SkillsInventoryController:_setContainerVisible(slot: string)
	for candidateSlot, container in pairs(self._containers) do
		container.Visible = candidateSlot == slot
	end
end

function SkillsInventoryController:_setTopbarState(slot: string)
	if not self._topbar then
		return
	end

	for _, child in ipairs(self._topbar:GetChildren()) do
		if not child:IsA("ImageButton") then
			continue
		end

		local isEnabledTab = child.Name == AbilityConfig.Slots.Offensive or child.Name == AbilityConfig.Slots.Defensive
		local isSelected = child.Name == slot
		child:SetAttribute("Selected", isSelected)
		child:SetAttribute("Disabled", not isEnabledTab)
		setButtonEnabled(child, isEnabledTab)

		local label = findTextLabel(child, "Label")
		if label then
			label.TextTransparency = if isEnabledTab then 0 else 0.45
		end
	end
end

function SkillsInventoryController:_updateTileStates()
	local loadout = getLoadout()
	local owned = getOwnedAbilities()

	for abilityId, record in pairs(self._tilesByAbilityId) do
		local isSelected = abilityId == self._selectedAbilityId
		local isOwned = owned[abilityId] == true
		local isEquipped = loadout[record.slot] == abilityId

		record.button:SetAttribute("Selected", isSelected)
		record.button:SetAttribute("Owned", isOwned)
		record.button:SetAttribute("Equipped", isEquipped)
	end
end

function SkillsInventoryController:_updateRightPanel()
	local right = self._right
	if not right then
		return
	end

	local abilityId = self._selectedAbilityId
	local definition = AbilityConfig.GetDefinition(abilityId)
	local icon = findImage(right, "Icon")
	local nameLabel = findTextLabel(right, "AbilityName")
	local descriptionLabel = findTextLabel(right, "Description")
	local buyButton = findButton(right, "BuyButton")
	local equipButton = findButton(right, "EquipButton")
	local unequipButton = findButton(right, "UnequipButton")
	local favoriteButton = findButton(right, "FavoriteButton")
	local warning = findTextLabel(right, "Warning")

	if not definition then
		if icon then
			icon.Image = ""
		end
		if nameLabel then
			nameLabel.Text = ""
		end
		if descriptionLabel then
			descriptionLabel.Text = ""
		end
		setButtonVisible(buyButton, false)
		setButtonVisible(equipButton, false)
		setButtonVisible(unequipButton, false)
		setButtonVisible(favoriteButton, false)
		if warning then
			warning.Visible = false
		end
		return
	end

	local owned = getOwnedAbilities()
	local loadout = getLoadout()
	local isOwned = owned[definition.id] == true
	local isEquipped = loadout[definition.slot] == definition.id
	local price = math.max(math.floor(tonumber(definition.price) or 0), 0)

	if icon then
		icon.Image = definition.icon or ""
	end
	if nameLabel then
		nameLabel.Text = definition.displayName or definition.id
	end
	if descriptionLabel then
		descriptionLabel.Text = definition.description or ""
	end

	setButtonLabel(buyButton, "BUY")
	setBuyPrice(buyButton, price)
	setButtonLabel(equipButton, "EQUIP")
	setButtonLabel(unequipButton, "UNEQUIP")

	setButtonVisible(buyButton, not isOwned)
	setButtonVisible(equipButton, isOwned and not isEquipped)
	setButtonVisible(unequipButton, isOwned and isEquipped)
	setButtonVisible(favoriteButton, false)

	if warning then
		local statusText = self._statusByAbilityId[definition.id]
		if statusText and statusText ~= "" then
			warning.Text = statusText
			warning.Visible = true
		else
			warning.Visible = false
		end
	end
end

function SkillsInventoryController:_refresh()
	self:_updateTileStates()
	self:_updateRightPanel()
end

function SkillsInventoryController:_selectAbility(abilityId: string)
	local definition = AbilityConfig.GetDefinition(abilityId)
	if not definition then
		return
	end

	self._selectedAbilityId = definition.id
	self._selectedSlot = definition.slot
	self:_setContainerVisible(definition.slot)
	self:_setTopbarState(definition.slot)
	self:_refresh()
end

function SkillsInventoryController:_selectSlot(slot: string)
	if not AbilityConfig.IsKnownSlot(slot) then
		return
	end

	self._selectedSlot = slot
	self:_setContainerVisible(slot)
	self:_setTopbarState(slot)

	local selectedDefinition = AbilityConfig.GetDefinition(self._selectedAbilityId)
	if selectedDefinition and selectedDefinition.slot == slot then
		self:_refresh()
		return
	end

	local ids = AbilityConfig.GetCatalogIds(slot)
	self:_selectAbility(ids[1] or "")
end

function SkillsInventoryController:_sendAction(action: string)
	local remote = self._remote
	local definition = AbilityConfig.GetDefinition(self._selectedAbilityId)
	if not (remote and definition) then
		return
	end

	self._statusByAbilityId[definition.id] = nil
	remote:FireServer({
		action = action,
		abilityId = definition.id,
		slot = definition.slot,
	})
end

function SkillsInventoryController:_bindRightPanel()
	local right = self._right
	if not right then
		return
	end

	local buyButton = findButton(right, "BuyButton")
	local equipButton = findButton(right, "EquipButton")
	local unequipButton = findButton(right, "UnequipButton")

	track(self._frameConnections, buyButton and buyButton.Activated:Connect(function()
		self:_sendAction(AbilityConfig.InventoryActions.Buy)
	end))
	track(self._frameConnections, equipButton and equipButton.Activated:Connect(function()
		self:_sendAction(AbilityConfig.InventoryActions.Equip)
	end))
	track(self._frameConnections, unequipButton and unequipButton.Activated:Connect(function()
		self:_sendAction(AbilityConfig.InventoryActions.Unequip)
	end))
end

function SkillsInventoryController:_bindTileButton(button: ImageButton, abilityId: string)
	local normalSize = button.Size
	local bigSize = scaleUDim2(normalSize, TILE_HOVER_SIZE_FACTOR)
	local smallSize = scaleUDim2(normalSize, TILE_PRESSED_SIZE_FACTOR)

	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button:SetAttribute("defaultSize", normalSize)
	button:SetAttribute("Hovered", false)
	button:SetAttribute("Pressed", false)

	track(self._tileConnections, button.MouseEnter:Connect(function()
		button:SetAttribute("Hovered", true)
		self:_tweenTileButton(button, bigSize)
	end))

	track(self._tileConnections, button.MouseLeave:Connect(function()
		button:SetAttribute("Hovered", false)
		button:SetAttribute("Pressed", false)
		self:_tweenTileButton(button, normalSize)
	end))

	track(self._tileConnections, button.MouseButton1Down:Connect(function()
		button:SetAttribute("Pressed", true)
		self:_tweenTileButton(button, smallSize)
	end))
	track(self._tileConnections, button.MouseButton1Up:Connect(function()
		button:SetAttribute("Pressed", false)
		self:_tweenTileButton(button, bigSize)
	end))
	track(self._tileConnections, button.Activated:Connect(function()
		button:SetAttribute("Pressed", false)
		playClick()
		self:_selectAbility(abilityId)
	end))
	track(self._tileConnections, button.MouseButton1Click:Connect(function()
		button:SetAttribute("Pressed", false)
		self:_selectAbility(abilityId)
	end))
end

function SkillsInventoryController:_populateSlot(slot: string, container: GuiObject)
	local scroller = container:FindFirstChildWhichIsA("ScrollingFrame")
	if not scroller then
		return
	end

	disableAuthoredTileTweenScripts(scroller)
	restoreRuntimeTileSlots(scroller)
	removeRuntimeTileScales(scroller)

	local records = getTileButtonRecords(scroller)
	local abilityIds = AbilityConfig.GetCatalogIds(slot)

	for index, record in ipairs(records) do
		local button = record.button
		local layoutObject = record.layoutObject
		local abilityId = abilityIds[index]
		local definition = AbilityConfig.GetDefinition(abilityId)

		if not definition then
			layoutObject.Visible = false
			button.Visible = false
			button.Active = false
			button.Selectable = false
			button:SetAttribute("AbilityId", nil)
			continue
		end

		local label = findTextLabel(button, "Label")
		local icon = findImage(button, "Icon")

		layoutObject.Visible = true
		button.Visible = true
		button:SetAttribute("AbilityId", definition.id)
		button:SetAttribute("Slot", slot)
		if label then
			label.Text = string.upper(definition.displayName or definition.id)
		end
		if icon then
			icon.Image = definition.icon or ""
		end

		self._tilesByAbilityId[definition.id] = {
			button = button,
			layoutObject = layoutObject,
			abilityId = definition.id,
			slot = slot,
			normalSize = button.Size,
		}

		self:_bindTileButton(button, definition.id)
	end
end

function SkillsInventoryController:_bindFrame(frame: GuiObject?)
	self:_disconnectFrame()
	self._frame = frame
	self._right = nil
	self._topbar = nil
	table.clear(self._containers)

	if not frame then
		return
	end

	ensureFrameRegistered(frame)

	self._right = frame:FindFirstChild("Right")
	self._topbar = frame:FindFirstChild("Topbar")
	self._containers[AbilityConfig.Slots.Offensive] = findAbilityContainer(frame, "OffensiveAbilities")
	self._containers[AbilityConfig.Slots.Defensive] = findAbilityContainer(frame, "DefensiveAbilities")

	for slot, container in pairs(self._containers) do
		self:_populateSlot(slot, container)
	end

	if self._topbar then
		for _, slot in ipairs(AbilityConfig.SlotOrder) do
			local button = findButton(self._topbar, slot)
			track(self._frameConnections, button and button.Activated:Connect(function()
				self:_selectSlot(slot)
			end))
		end
	end

	local closeButton = findButton(frame, "CloseButton")
	track(self._frameConnections, closeButton and closeButton.Activated:Connect(function()
		FrameController:CloseFrame(FRAME_NAME)
	end))

	self:_bindRightPanel()
	self:_selectSlot(AbilityConfig.Slots.Offensive)
end

function SkillsInventoryController:_bindCurrentFrame()
	local framesGui = PlayerGui:FindFirstChild(FRAMES_GUI_NAME)
	local frame = framesGui and framesGui:FindFirstChild(FRAME_NAME)
	if frame and frame:IsA("GuiObject") then
		self:_bindFrame(frame)
	else
		self:_bindFrame(nil)
	end
end

function SkillsInventoryController:_toggleFrameFromHud()
	local now = os.clock()
	if now - self._lastHudToggleAt < HUD_TOGGLE_DEBOUNCE_SECONDS then
		return
	end

	self._lastHudToggleAt = now
	FrameController:ToggleFrame(FRAME_NAME)
end

function SkillsInventoryController:_watchHudForSkillsButton(hud: Instance)
	track(self._hudConnections, hud.DescendantAdded:Connect(function(descendant)
		if descendant.Name ~= SKILLS_BUTTON_NAME and descendant.Name ~= "Label" then
			return
		end

		task.defer(function()
			if hud.Parent then
				self:_bindHud(hud)
			end
		end)
	end))
end

function SkillsInventoryController:_bindHud(hud: Instance?)
	self:_disconnectHud()

	if not hud then
		return
	end

	local skillsButton = findSkillsButton(hud)
	if not skillsButton then
		self:_watchHudForSkillsButton(hud)
		return
	end

	skillsButton.Active = true
	skillsButton.Selectable = true
	track(self._hudConnections, skillsButton.Activated:Connect(function()
		self:_toggleFrameFromHud()
	end))
	track(self._hudConnections, skillsButton.MouseButton1Click:Connect(function()
		self:_toggleFrameFromHud()
	end))
end

function SkillsInventoryController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild(HUD_GUI_NAME))
end

function SkillsInventoryController:_bindRemote()
	self._remote = getRemote()
	if not self._remote then
		return
	end

	track(self._connections, self._remote.OnClientEvent:Connect(function(response)
		if typeof(response) ~= "table" then
			return
		end

		local abilityId = AbilityConfig.NormalizeAbilityId(response.abilityId)
		if abilityId ~= "" then
			self._statusByAbilityId[abilityId] = if response.ok == true then nil else tostring(response.message or "Skill action failed.")
		end

		self:_refresh()
	end))
end

function SkillsInventoryController:OnStart()
	disconnectAll(self._connections)
	self:_disconnectHud()
	self:_disconnectFrame()

	self:_bindCurrentFrame()
	self:_bindCurrentHud()
	task.spawn(function()
		self:_bindRemote()
	end)

	track(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == FRAMES_GUI_NAME then
			task.defer(function()
				self:_bindCurrentFrame()
			end)
		elseif child.Name == HUD_GUI_NAME then
			task.defer(function()
				self:_bindCurrentHud()
			end)
		end
	end))

	track(self._connections, DataController.DataReceived:Connect(function()
		self:_refresh()
	end))
	track(self._connections, DataController.DataUpdated:Connect(function(key)
		if key == OWNED_KEY or key == LOADOUT_KEY then
			self:_refresh()
		end
	end))
end

return SkillsInventoryController
