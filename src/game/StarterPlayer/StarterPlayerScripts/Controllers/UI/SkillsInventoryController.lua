local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AudioSettings = require(ReplicatedStorage.Shared.Audio.AudioSettings)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
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
local SKINS_TAB_NAME = "Skins"
local HUD_TOGGLE_DEBOUNCE_SECONDS = 0.08
local TILE_SLOT_NAME = "SkillsInventoryTileSlot"
local TILE_SCALE_NAME = "SkillsInventoryVisualScale"
local SKIN_TEMPLATE_SUFFIX = "Template"
local SKIN_RUNTIME_TILE_ATTRIBUTE = "RuntimeSkinTile"
local TILE_HOVER_SIZE_FACTOR = 1.01
local TILE_PRESSED_SIZE_FACTOR = 0.9
local TILE_TWEEN_INFO = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICK_SOUND_NAME = "UIButtonClickSound"
local CLICK_SOUND_ID = "rbxassetid://5852470908"
local CLICK_SOUND_VOLUME = 0.6

local OWNED_ABILITIES_KEY = Schema.OwnedAbilities and Schema.OwnedAbilities.key or "ownedAbilities"
local LOADOUT_KEY = Schema.AbilityLoadout and Schema.AbilityLoadout.key or "abilityLoadout"
local OWNED_SKINS_KEY = Schema.OwnedBombSkins and Schema.OwnedBombSkins.key or "ownedBombSkins"
local SKIN_COPIES_KEY = Schema.BombSkinCopies and Schema.BombSkinCopies.key or "bombSkinCopies"
local EQUIPPED_SKIN_KEY = Schema.EquippedBombSkin and Schema.EquippedBombSkin.key or "equippedBombSkin"

type TileRecord = {
	button: ImageButton,
	layoutObject: GuiObject,
	abilityId: string,
	slot: string,
	normalSize: UDim2,
}

type SkinTileRecord = {
	button: ImageButton,
	skinId: string,
	normalSize: UDim2,
}

type TileButtonRecord = {
	button: ImageButton,
	layoutObject: GuiObject,
	index: number,
}

type TextStyleTemplate = {
	fontFace: Font,
	textColor3: Color3,
	textTransparency: number,
	textStrokeColor3: Color3,
	textStrokeTransparency: number,
	richText: boolean,
	children: { Instance },
}

local SkillsInventoryController = {}

SkillsInventoryController._connections = {} :: { RBXScriptConnection }
SkillsInventoryController._frameConnections = {} :: { RBXScriptConnection }
SkillsInventoryController._hudConnections = {} :: { RBXScriptConnection }
SkillsInventoryController._tileConnections = {} :: { RBXScriptConnection }
SkillsInventoryController._skinTileConnections = {} :: { RBXScriptConnection }
SkillsInventoryController._frame = nil :: GuiObject?
SkillsInventoryController._right = nil :: Instance?
SkillsInventoryController._topbar = nil :: Instance?
SkillsInventoryController._containers = {} :: { [string]: GuiObject }
SkillsInventoryController._tilesByAbilityId = {} :: { [string]: TileRecord }
SkillsInventoryController._skinTilesBySkinId = {} :: { [string]: SkinTileRecord }
SkillsInventoryController._tileTweens = {} :: { [ImageButton]: Tween }
SkillsInventoryController._selectedTab = AbilityConfig.Slots.Offensive
SkillsInventoryController._selectedSlot = AbilityConfig.Slots.Offensive
SkillsInventoryController._selectedAbilityId = ""
SkillsInventoryController._selectedSkinId = BombSkinConfig.DefaultSkinId
SkillsInventoryController._remote = nil :: RemoteEvent?
SkillsInventoryController._skinRemote = nil :: RemoteEvent?
SkillsInventoryController._statusByAbilityId = {} :: { [string]: string }
SkillsInventoryController._statusBySkinId = {} :: { [string]: string }
SkillsInventoryController._lastHudToggleAt = 0

local warnedMissingTextStyles = {}

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
	clickSound.SoundGroup = AudioSettings.GetGroup("UI")
	clickSound.Parent = PlayerGui
	return clickSound
end

local function playClick()
	local clickSound = getClickSound()
	clickSound.TimePosition = 0
	clickSound:Play()
end

local function getInventoryTabs(): { string }
	return {
		AbilityConfig.Slots.Offensive,
		AbilityConfig.Slots.Defensive,
		SKINS_TAB_NAME,
	}
end

local function getAbilityRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(AbilityConfig.RemotesFolderName, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(AbilityConfig.InventoryRequestRemoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getSkinRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(BombSkinConfig.RemotesFolderName, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(BombSkinConfig.InventoryRequestRemoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getOwnedAbilities(): { [string]: boolean }
	local rawOwned = DataController:Get(OWNED_ABILITIES_KEY)
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

local function getOwnedSkins(): { [string]: boolean }
	local rawOwned = DataController:Get(OWNED_SKINS_KEY)
	local owned = {}
	if typeof(rawOwned) ~= "table" then
		owned[BombSkinConfig.DefaultSkinId] = true
		return owned
	end

	for key, child in pairs(rawOwned) do
		local skinId = nil
		if typeof(key) == "string" and child == true then
			skinId = key
		elseif typeof(child) == "string" then
			skinId = child
		end

		if skinId then
			local normalizedSkinId = BombSkinConfig.NormalizeSkinId(skinId)
			if BombSkinConfig.IsCatalogSkin(normalizedSkinId) then
				owned[normalizedSkinId] = true
			end
		end
	end

	owned[BombSkinConfig.DefaultSkinId] = true
	return owned
end

local function getSkinCopies(): { [string]: number }
	local rawCopies = DataController:Get(SKIN_COPIES_KEY)
	local owned = getOwnedSkins()
	local copies = {}

	if typeof(rawCopies) == "table" then
		for rawSkinId, rawCount in pairs(rawCopies) do
			local skinId = BombSkinConfig.NormalizeSkinId(rawSkinId)
			local count = math.floor(tonumber(rawCount) or 0)
			if skinId ~= "" and owned[skinId] == true and count > 0 then
				copies[skinId] = count
			end
		end
	end

	for skinId in pairs(owned) do
		if (copies[skinId] or 0) < 1 then
			copies[skinId] = 1
		end
	end

	return copies
end

local function getEquippedSkinId(): string
	local skinId = BombSkinConfig.NormalizeSkinId(DataController:Get(EQUIPPED_SKIN_KEY))
	return if skinId ~= "" then skinId else BombSkinConfig.DefaultSkinId
end

local function getLoadout(): { [string]: string }
	local rawLoadout = DataController:Get(LOADOUT_KEY)
	local loadout = {}

	for _, slot in ipairs(AbilityConfig.SlotOrder) do
		loadout[slot] = AbilityConfig.GetSlotAbility(rawLoadout, slot)
	end

	return loadout
end

local rarityRank = {}
for index, rarity in ipairs(BombSkinConfig.RarityOrder) do
	rarityRank[rarity] = index
end

local function getSortedOwnedSkinIds(): { string }
	local owned = getOwnedSkins()
	local skinIds = {}

	for skinId in pairs(owned) do
		if BombSkinConfig.IsCatalogSkin(skinId) then
			table.insert(skinIds, skinId)
		end
	end

	table.sort(skinIds, function(leftId, rightId)
		local left = BombSkinConfig.GetDefinition(leftId)
		local right = BombSkinConfig.GetDefinition(rightId)
		local leftRank = if left then rarityRank[left.rarity] or math.huge else math.huge
		local rightRank = if right then rarityRank[right.rarity] or math.huge else math.huge

		if leftRank == rightRank then
			local leftOrder = if left then tonumber(left.catalogOrder) or 0 else 0
			local rightOrder = if right then tonumber(right.catalogOrder) or 0 else 0
			return leftOrder < rightOrder
		end

		return leftRank < rightRank
	end)

	return skinIds
end

local function findAbilityContainer(frame: Instance, name: string): GuiObject?
	for _, child in ipairs(frame:GetChildren()) do
		if child.Name == name and child:IsA("GuiObject") and child:FindFirstChildWhichIsA("ScrollingFrame") then
			return child
		end
	end

	return nil
end

local function findSkinTemplate(scroller: ScrollingFrame, rarity: string?): ImageButton?
	local templateName = tostring(rarity or BombSkinConfig.Rarities.Common) .. SKIN_TEMPLATE_SUFFIX
	local template = scroller:FindFirstChild(templateName)
	if not (template and template:IsA("ImageButton")) then
		template = scroller:FindFirstChild(BombSkinConfig.Rarities.Common .. SKIN_TEMPLATE_SUFFIX)
	end

	return if template and template:IsA("ImageButton") then template else nil
end

local function formatSkinTileName(definition, copyCount: number): string
	local displayName = definition.displayName or definition.id
	if copyCount > 1 then
		return ("%s [X%d]"):format(displayName, copyCount)
	end

	return displayName
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

local function normalizeInventoryTextStyleKey(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end

	local key = string.upper(value)
	key = string.gsub(key, "^%s+", "")
	key = string.gsub(key, "%s+$", "")
	key = string.gsub(key, "%s+", " ")
	return key
end

local function captureTextStyle(label: TextLabel): TextStyleTemplate
	local children = {}
	for _, child in ipairs(label:GetChildren()) do
		if child:IsA("UIGradient") or child:IsA("UIStroke") then
			table.insert(children, child:Clone())
		end
	end

	return {
		fontFace = label.FontFace,
		textColor3 = label.TextColor3,
		textTransparency = label.TextTransparency,
		textStrokeColor3 = label.TextStrokeColor3,
		textStrokeTransparency = label.TextStrokeTransparency,
		richText = label.RichText,
		children = children,
	}
end

local function buildTextStyleTemplates(records: { TileButtonRecord }): { [string]: TextStyleTemplate }
	local templates = {}
	for _, record in ipairs(records) do
		local label = findTextLabel(record.button, "Label")
		local key = normalizeInventoryTextStyleKey(label and label.Text)
		if label and key ~= "" and not templates[key] then
			templates[key] = captureTextStyle(label)
		end
	end
	return templates
end

local function applyTextStyle(label: TextLabel, template: TextStyleTemplate)
	label.FontFace = template.fontFace
	label.TextColor3 = template.textColor3
	label.TextTransparency = template.textTransparency
	label.TextStrokeColor3 = template.textStrokeColor3
	label.TextStrokeTransparency = template.textStrokeTransparency
	label.RichText = template.richText

	for _, child in ipairs(label:GetChildren()) do
		if child:IsA("UIGradient") or child:IsA("UIStroke") then
			child:Destroy()
		end
	end

	for _, child in ipairs(template.children) do
		child:Clone().Parent = label
	end
end

local function warnMissingTextStyleOnce(abilityId: string, styleKey: string)
	local warningKey = abilityId .. ":" .. styleKey
	if warnedMissingTextStyles[warningKey] then
		return
	end

	warnedMissingTextStyles[warningKey] = true
	warn(("[SkillsInventoryController] Missing inventory text style template for ability '%s' with key '%s'."):format(
		abilityId,
		styleKey
	))
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

function SkillsInventoryController:_disconnectSkinTiles()
	for _, record in pairs(self._skinTilesBySkinId) do
		self:_cancelTileTween(record.button)
		if record.button.Parent then
			record.button.Size = record.normalSize
		end
	end

	disconnectAll(self._skinTileConnections)
	table.clear(self._skinTilesBySkinId)
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
	self:_disconnectSkinTiles()
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

		local isEnabledTab = child.Name == AbilityConfig.Slots.Offensive
			or child.Name == AbilityConfig.Slots.Defensive
			or child.Name == SKINS_TAB_NAME
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
	local equippedSkinId = getEquippedSkinId()

	for abilityId, record in pairs(self._tilesByAbilityId) do
		local isSelected = self._selectedTab ~= SKINS_TAB_NAME and abilityId == self._selectedAbilityId
		local isOwned = owned[abilityId] == true
		local isEquipped = loadout[record.slot] == abilityId

		record.button:SetAttribute("Selected", isSelected)
		record.button:SetAttribute("Owned", isOwned)
		record.button:SetAttribute("Equipped", isEquipped)
	end

	for skinId, record in pairs(self._skinTilesBySkinId) do
		local isSelected = self._selectedTab == SKINS_TAB_NAME and skinId == self._selectedSkinId
		local isEquipped = equippedSkinId == skinId

		record.button:SetAttribute("Selected", isSelected)
		record.button:SetAttribute("Owned", true)
		record.button:SetAttribute("Equipped", isEquipped)
	end
end

function SkillsInventoryController:_updateSkinRightPanel()
	local right = self._right
	if not right then
		return
	end

	local skinId = self._selectedSkinId
	local definition = BombSkinConfig.GetDefinition(skinId)
	local owned = getOwnedSkins()
	local icon = findImage(right, "Icon")
	local nameLabel = findTextLabel(right, "AbilityName")
	local descriptionLabel = findTextLabel(right, "Description")
	local buyButton = findButton(right, "BuyButton")
	local equipButton = findButton(right, "EquipButton")
	local unequipButton = findButton(right, "UnequipButton")
	local favoriteButton = findButton(right, "FavoriteButton")
	local warning = findTextLabel(right, "Warning")

	if not (definition and owned[definition.id] == true) then
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

	local isEquipped = getEquippedSkinId() == definition.id

	if icon then
		icon.Image = definition.iconImage or ""
	end
	if nameLabel then
		nameLabel.Text = definition.displayName or definition.id
	end
	if descriptionLabel then
		descriptionLabel.Text = definition.description or ""
	end

	setButtonLabel(equipButton, "EQUIP")
	setButtonLabel(unequipButton, "EQUIPPED")
	setButtonVisible(buyButton, false)
	setButtonVisible(equipButton, not isEquipped)
	setButtonVisible(unequipButton, isEquipped)
	if isEquipped then
		setButtonEnabled(unequipButton, false)
	end
	setButtonVisible(favoriteButton, false)

	if warning then
		local statusText = self._statusBySkinId[definition.id]
		if statusText and statusText ~= "" then
			warning.Text = statusText
			warning.Visible = true
		else
			warning.Visible = false
		end
	end
end

function SkillsInventoryController:_updateRightPanel()
	if self._selectedTab == SKINS_TAB_NAME then
		self:_updateSkinRightPanel()
		return
	end

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

	self._selectedTab = definition.slot
	self._selectedAbilityId = definition.id
	self._selectedSlot = definition.slot
	self:_setContainerVisible(definition.slot)
	self:_setTopbarState(definition.slot)
	self:_refresh()
end

function SkillsInventoryController:_selectSkin(skinId: string)
	local definition = BombSkinConfig.GetDefinition(skinId)
	if not definition then
		return
	end

	local owned = getOwnedSkins()
	if owned[definition.id] ~= true then
		return
	end

	self._selectedTab = SKINS_TAB_NAME
	self._selectedSkinId = definition.id
	self:_setContainerVisible(SKINS_TAB_NAME)
	self:_setTopbarState(SKINS_TAB_NAME)
	self:_refresh()
end

function SkillsInventoryController:_selectSlot(slot: string)
	if slot == SKINS_TAB_NAME then
		self._selectedTab = SKINS_TAB_NAME
		self:_setContainerVisible(SKINS_TAB_NAME)
		self:_setTopbarState(SKINS_TAB_NAME)

		local owned = getOwnedSkins()
		local selectedSkin = BombSkinConfig.GetDefinition(self._selectedSkinId)
		if selectedSkin and owned[selectedSkin.id] == true then
			self:_refresh()
			return
		end

		local equippedSkinId = getEquippedSkinId()
		if owned[equippedSkinId] == true then
			self:_selectSkin(equippedSkinId)
			return
		end

		local skinIds = getSortedOwnedSkinIds()
		self:_selectSkin(skinIds[1] or BombSkinConfig.DefaultSkinId)
		return
	end

	if not AbilityConfig.IsKnownSlot(slot) then
		return
	end

	self._selectedTab = slot
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

function SkillsInventoryController:_sendSkinAction(action: string)
	if action ~= BombSkinConfig.InventoryActions.Equip then
		return
	end

	local remote = self._skinRemote
	local definition = BombSkinConfig.GetDefinition(self._selectedSkinId)
	if not (remote and definition) then
		return
	end

	self._statusBySkinId[definition.id] = nil
	remote:FireServer({
		action = action,
		skinId = definition.id,
	})
end

function SkillsInventoryController:_sendAction(action: string)
	if self._selectedTab == SKINS_TAB_NAME then
		self:_sendSkinAction(action)
		return
	end

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

function SkillsInventoryController:_bindSkinTileButton(button: ImageButton, skinId: string)
	local normalSize = button.Size
	local bigSize = scaleUDim2(normalSize, TILE_HOVER_SIZE_FACTOR)
	local smallSize = scaleUDim2(normalSize, TILE_PRESSED_SIZE_FACTOR)

	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button:SetAttribute("defaultSize", normalSize)
	button:SetAttribute("Hovered", false)
	button:SetAttribute("Pressed", false)

	track(self._skinTileConnections, button.MouseEnter:Connect(function()
		button:SetAttribute("Hovered", true)
		self:_tweenTileButton(button, bigSize)
	end))

	track(self._skinTileConnections, button.MouseLeave:Connect(function()
		button:SetAttribute("Hovered", false)
		button:SetAttribute("Pressed", false)
		self:_tweenTileButton(button, normalSize)
	end))

	track(self._skinTileConnections, button.MouseButton1Down:Connect(function()
		button:SetAttribute("Pressed", true)
		self:_tweenTileButton(button, smallSize)
	end))
	track(self._skinTileConnections, button.MouseButton1Up:Connect(function()
		button:SetAttribute("Pressed", false)
		self:_tweenTileButton(button, bigSize)
	end))
	track(self._skinTileConnections, button.Activated:Connect(function()
		button:SetAttribute("Pressed", false)
		playClick()
		self:_selectSkin(skinId)
	end))
	track(self._skinTileConnections, button.MouseButton1Click:Connect(function()
		button:SetAttribute("Pressed", false)
		self:_selectSkin(skinId)
	end))
end

local function clearSkinTiles(scroller: ScrollingFrame)
	for _, child in ipairs(scroller:GetChildren()) do
		if not child:IsA("ImageButton") then
			continue
		end

		if child:GetAttribute(SKIN_RUNTIME_TILE_ATTRIBUTE) == true then
			child:Destroy()
		elseif string.sub(child.Name, -#SKIN_TEMPLATE_SUFFIX) == SKIN_TEMPLATE_SUFFIX then
			child.Visible = false
			child.Active = false
			child.Selectable = false
		end
	end
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
	local textStyleTemplates = buildTextStyleTemplates(records)
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
			local styleKey = normalizeInventoryTextStyleKey(definition.inventoryTextStyleKey or definition.displayName or definition.id)
			local textStyle = textStyleTemplates[styleKey]
			if textStyle then
				applyTextStyle(label, textStyle)
			else
				warnMissingTextStyleOnce(definition.id, styleKey)
			end
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

function SkillsInventoryController:_populateSkins(container: GuiObject?)
	if not container then
		return
	end

	local scroller = container:FindFirstChildWhichIsA("ScrollingFrame")
	if not scroller then
		return
	end

	self:_disconnectSkinTiles()
	disableAuthoredTileTweenScripts(scroller)
	removeRuntimeTileScales(scroller)
	clearSkinTiles(scroller)

	local skinIds = getSortedOwnedSkinIds()
	local skinCopies = getSkinCopies()

	for index, skinId in ipairs(skinIds) do
		local definition = BombSkinConfig.GetDefinition(skinId)
		if not definition then
			continue
		end

		local template = findSkinTemplate(scroller, definition.rarity)
		if not template then
			warn(("[SkillsInventoryController] Missing skin inventory template for rarity '%s'."):format(tostring(definition.rarity)))
			continue
		end

		local button = template:Clone()
		button.Name = "Skin_" .. definition.id
		button.LayoutOrder = index
		button.Visible = true
		button.Active = true
		button.Selectable = true
		button:SetAttribute(SKIN_RUNTIME_TILE_ATTRIBUTE, true)
		button:SetAttribute("SkinId", definition.id)
		button:SetAttribute("Rarity", definition.rarity)

		local label = findTextLabel(button, "Label")
		if label then
			label.Text = formatSkinTileName(definition, skinCopies[definition.id] or 1)
		end

		local icon = findImage(button, "Icon")
		if icon then
			icon.Image = definition.iconImage or ""
		end

		button.Parent = scroller

		self._skinTilesBySkinId[definition.id] = {
			button = button,
			skinId = definition.id,
			normalSize = button.Size,
		}

		self:_bindSkinTileButton(button, definition.id)
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
	self._containers[SKINS_TAB_NAME] = findAbilityContainer(frame, SKINS_TAB_NAME)

	for slot, container in pairs(self._containers) do
		if slot == SKINS_TAB_NAME then
			self:_populateSkins(container)
		else
			self:_populateSlot(slot, container)
		end
	end

	if self._topbar then
		for _, slot in ipairs(getInventoryTabs()) do
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
	self._remote = getAbilityRemote()
	if self._remote then
		track(self._connections, self._remote.OnClientEvent:Connect(function(response)
			if typeof(response) ~= "table" then
				return
			end

			local abilityId = AbilityConfig.NormalizeAbilityId(response.abilityId)
			if abilityId ~= "" then
				self._statusByAbilityId[abilityId] =
					if response.ok == true then nil else tostring(response.message or "Skill action failed.")
			end

			self:_refresh()
		end))
	end

	self._skinRemote = getSkinRemote()
	if self._skinRemote then
		track(self._connections, self._skinRemote.OnClientEvent:Connect(function(response)
			if typeof(response) ~= "table" then
				return
			end

			local skinId = BombSkinConfig.NormalizeSkinId(response.skinId)
			if skinId ~= "" then
				self._statusBySkinId[skinId] =
					if response.ok == true then nil else tostring(response.message or "Skin action failed.")
			end

			self:_refresh()
		end))
	end
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
		if self._containers[SKINS_TAB_NAME] then
			self:_populateSkins(self._containers[SKINS_TAB_NAME])
		end
		if self._selectedTab == SKINS_TAB_NAME then
			self:_selectSlot(SKINS_TAB_NAME)
		else
			self:_refresh()
		end
	end))
	track(self._connections, DataController.DataUpdated:Connect(function(key)
		if key == OWNED_ABILITIES_KEY or key == LOADOUT_KEY then
			self:_refresh()
		elseif key == OWNED_SKINS_KEY or key == SKIN_COPIES_KEY then
			if self._containers[SKINS_TAB_NAME] then
				self:_populateSkins(self._containers[SKINS_TAB_NAME])
			end
			if self._selectedTab == SKINS_TAB_NAME then
				self:_selectSlot(SKINS_TAB_NAME)
			else
				self:_refresh()
			end
		elseif key == EQUIPPED_SKIN_KEY then
			self:_refresh()
		end
	end))
end

return SkillsInventoryController
