local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AudioSettings = require(ReplicatedStorage.Shared.Audio.AudioSettings)
local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local FinisherConfig = require(ReplicatedStorage.Shared.Config.FinisherConfig)
local HighlightIntroConfig = require(ReplicatedStorage.Shared.Config.HighlightIntroConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local DataController = require(script.Parent:WaitForChild("DataController"))
local FrameController = require(script.Parent:WaitForChild("FrameController"))
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = "SkillsInventory"
local FRAMES_GUI_NAME = "Frames"
local HUD_GUI_NAME = "HUD"
local SIDE_BUTTONS_NAME = "SideButtons"
local SKILLS_BUTTON_NAME = "Skills"
local SKILLS_LABEL_TEXT = "SKILLS"
local SKINS_TAB_NAME = "Skins"
local FINISHERS_TAB_NAME = "Finishers"
local INTROS_TAB_NAME = "Intros"
local LEGACY_HIGHLIGHT_INTROS_TAB_NAME = "HighlightIntros"
local HUD_TOGGLE_DEBOUNCE_SECONDS = 0.08
local TILE_SLOT_NAME = "SkillsInventoryTileSlot"
local TILE_SCALE_NAME = "SkillsInventoryVisualScale"
local SKIN_TEMPLATE_SUFFIX = "Template"
local UNOWNED_DIVIDER_NAME = "UnownedDivider"
local LOCKED_COSMETIC_WARNING_TEXT = "Locked"
local SKIN_RUNTIME_TILE_ATTRIBUTE = "RuntimeSkinTile"
local FINISHER_RUNTIME_TILE_ATTRIBUTE = "RuntimeFinisherTile"
local HIGHLIGHT_INTRO_RUNTIME_TILE_ATTRIBUTE = "RuntimeHighlightIntroTile"
local TILE_HOVER_SIZE_FACTOR = 1.01
local TILE_PRESSED_SIZE_FACTOR = 0.9
local TILE_TWEEN_INFO = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLICK_SOUND_NAME = "UIButtonClickSound"
local CLICK_SOUND_ID = "rbxassetid://5852470908"
local CLICK_SOUND_VOLUME = 0.6
local ROUND_ID_ATTR = "RoundId"

local OWNED_ABILITIES_KEY = Schema.OwnedAbilities and Schema.OwnedAbilities.key or "ownedAbilities"
local LOADOUT_KEY = Schema.AbilityLoadout and Schema.AbilityLoadout.key or "abilityLoadout"
local OWNED_SKINS_KEY = Schema.OwnedBombSkins and Schema.OwnedBombSkins.key or "ownedBombSkins"
local SKIN_COPIES_KEY = Schema.BombSkinCopies and Schema.BombSkinCopies.key or "bombSkinCopies"
local EQUIPPED_SKIN_KEY = Schema.EquippedBombSkin and Schema.EquippedBombSkin.key or "equippedBombSkin"
local OWNED_FINISHERS_KEY = Schema.OwnedFinishers and Schema.OwnedFinishers.key or "ownedFinishers"
local FINISHER_COPIES_KEY = Schema.FinisherCopies and Schema.FinisherCopies.key or "finisherCopies"
local EQUIPPED_FINISHER_KEY = Schema.EquippedFinisher and Schema.EquippedFinisher.key or "equippedFinisher"
local OWNED_HIGHLIGHT_INTROS_KEY = Schema.OwnedHighlightIntros and Schema.OwnedHighlightIntros.key or "ownedHighlightIntros"
local HIGHLIGHT_INTRO_COPIES_KEY = Schema.HighlightIntroCopies and Schema.HighlightIntroCopies.key or "highlightIntroCopies"
local EQUIPPED_HIGHLIGHT_INTRO_KEY = Schema.EquippedHighlightIntro and Schema.EquippedHighlightIntro.key or "equippedHighlightIntro"

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

type FinisherTileRecord = {
	button: ImageButton,
	finisherId: string,
	normalSize: UDim2,
}

type HighlightIntroTileRecord = {
	button: ImageButton,
	highlightIntroId: string,
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
SkillsInventoryController._finisherTileConnections = {} :: { RBXScriptConnection }
SkillsInventoryController._highlightIntroTileConnections = {} :: { RBXScriptConnection }
SkillsInventoryController._frame = nil :: GuiObject?
SkillsInventoryController._right = nil :: Instance?
SkillsInventoryController._topbar = nil :: Instance?
SkillsInventoryController._containers = {} :: { [string]: GuiObject }
SkillsInventoryController._tilesByAbilityId = {} :: { [string]: TileRecord }
SkillsInventoryController._skinTilesBySkinId = {} :: { [string]: SkinTileRecord }
SkillsInventoryController._finisherTilesByFinisherId = {} :: { [string]: FinisherTileRecord }
SkillsInventoryController._highlightIntroTilesById = {} :: { [string]: HighlightIntroTileRecord }
SkillsInventoryController._tileTweens = {} :: { [ImageButton]: Tween }
SkillsInventoryController._selectedTab = AbilityConfig.Slots.Offensive
SkillsInventoryController._selectedSlot = AbilityConfig.Slots.Offensive
SkillsInventoryController._selectedAbilityId = ""
SkillsInventoryController._selectedSkinId = BombSkinConfig.DefaultSkinId
SkillsInventoryController._selectedFinisherId = FinisherConfig.DefaultFinisherId
SkillsInventoryController._selectedHighlightIntroId = HighlightIntroConfig.DefaultHighlightIntroId
SkillsInventoryController._remote = nil :: RemoteEvent?
SkillsInventoryController._skinRemote = nil :: RemoteEvent?
SkillsInventoryController._finisherRemote = nil :: RemoteEvent?
SkillsInventoryController._highlightIntroRemote = nil :: RemoteEvent?
SkillsInventoryController._statusByAbilityId = {} :: { [string]: string }
SkillsInventoryController._statusBySkinId = {} :: { [string]: string }
SkillsInventoryController._statusByFinisherId = {} :: { [string]: string }
SkillsInventoryController._statusByHighlightIntroId = {} :: { [string]: string }
SkillsInventoryController._skillsButton = nil :: ImageButton?
SkillsInventoryController._lastHudToggleAt = 0

local warnedMissingTextStyles = {}
local equippedHighlightIntroOverride: string? = nil

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

local function isLockedRoundState(stateName: any): boolean
	return stateName == RoundStates.AssigningTeams or stateName == RoundStates.RoundStarting or stateName == RoundStates.Active
end

local function setBuyPrice(button: ImageButton?, price: any)
	if not button then
		return
	end

	local cost = button:FindFirstChild("Cost")
	local statNumber = findTextLabel(cost, "StatNumber")
	if statNumber then
		if typeof(price) == "number" then
			statNumber.Text = tostring(math.max(math.floor(price), 0))
		else
			statNumber.Text = tostring(price or "")
		end
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
		FINISHERS_TAB_NAME,
		INTROS_TAB_NAME,
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

local function getFinisherRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(FinisherConfig.RemotesFolderName, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(FinisherConfig.InventoryRequestRemoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getHighlightIntroRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:WaitForChild(HighlightIntroConfig.RemotesFolderName, 10)
	if not remotes then
		return nil
	end

	local remote = remotes:WaitForChild(HighlightIntroConfig.InventoryRequestRemoteName, 10)
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

local function getOwnedFinishers(): { [string]: boolean }
	local rawOwned = DataController:Get(OWNED_FINISHERS_KEY)
	local owned = {}
	if typeof(rawOwned) ~= "table" then
		return owned
	end

	for key, child in pairs(rawOwned) do
		local finisherId = nil
		if typeof(key) == "string" and child == true then
			finisherId = key
		elseif typeof(child) == "string" then
			finisherId = child
		end

		if finisherId then
			local normalizedFinisherId = FinisherConfig.NormalizeFinisherId(finisherId)
			if FinisherConfig.IsKnownFinisherId(normalizedFinisherId) then
				owned[normalizedFinisherId] = true
			end
		end
	end

	return owned
end

local function getOwnedHighlightIntros(): { [string]: boolean }
	local owned = {}
	for _, introId in ipairs(HighlightIntroConfig.GetCatalogIds()) do
		if HighlightIntroConfig.IsKnownHighlightIntroId(introId) then
			owned[introId] = true
		end
	end
	return owned
end

local function getFinisherCopies(): { [string]: number }
	local rawCopies = DataController:Get(FINISHER_COPIES_KEY)
	local owned = getOwnedFinishers()
	local copies = {}

	if typeof(rawCopies) == "table" then
		for rawFinisherId, rawCount in pairs(rawCopies) do
			local finisherId = FinisherConfig.NormalizeFinisherId(rawFinisherId)
			local count = math.floor(tonumber(rawCount) or 0)
			if finisherId ~= "" and owned[finisherId] == true and count > 0 then
				copies[finisherId] = count
			end
		end
	end

	for finisherId in pairs(owned) do
		if (copies[finisherId] or 0) < 1 then
			copies[finisherId] = 1
		end
	end

	return copies
end

local function getHighlightIntroCopies(): { [string]: number }
	local rawCopies = DataController:Get(HIGHLIGHT_INTRO_COPIES_KEY)
	local owned = getOwnedHighlightIntros()
	local copies = {}

	if typeof(rawCopies) == "table" then
		for rawIntroId, rawCount in pairs(rawCopies) do
			local introId = HighlightIntroConfig.NormalizeHighlightIntroId(rawIntroId)
			local count = math.floor(tonumber(rawCount) or 0)
			if introId ~= "" and owned[introId] == true and count > 0 then
				copies[introId] = count
			end
		end
	end

	for introId in pairs(owned) do
		if (copies[introId] or 0) < 1 then
			copies[introId] = 1
		end
	end

	return copies
end

local function getEquippedSkinId(): string
	local skinId = BombSkinConfig.NormalizeSkinId(DataController:Get(EQUIPPED_SKIN_KEY))
	return if skinId ~= "" then skinId else BombSkinConfig.DefaultSkinId
end

local function getEquippedFinisherId(): string
	return FinisherConfig.NormalizeFinisherId(DataController:Get(EQUIPPED_FINISHER_KEY))
end

local function getEquippedHighlightIntroId(): string
	local overrideIntroId = HighlightIntroConfig.NormalizeHighlightIntroId(equippedHighlightIntroOverride)
	if overrideIntroId ~= "" then
		return overrideIntroId
	end

	local introId = HighlightIntroConfig.NormalizeHighlightIntroId(DataController:Get(EQUIPPED_HIGHLIGHT_INTRO_KEY))
	return if introId ~= "" then introId else HighlightIntroConfig.DefaultHighlightIntroId
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

local finisherRarityRank = {}
for index, rarity in ipairs(FinisherConfig.RarityOrder) do
	finisherRarityRank[rarity] = index
end

local highlightIntroRarityRank = {}
for index, rarity in ipairs(HighlightIntroConfig.RarityOrder) do
	highlightIntroRarityRank[rarity] = index
end

local function getSortedSkinCatalogIds(): { string }
	local skinIds = BombSkinConfig.GetCatalogIds()

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

local function getSortedFinisherCatalogIds(): { string }
	local finisherIds = FinisherConfig.GetCatalogIds()

	table.sort(finisherIds, function(leftId, rightId)
		local left = FinisherConfig.GetDefinition(leftId)
		local right = FinisherConfig.GetDefinition(rightId)
		local leftRank = if left then finisherRarityRank[left.rarity] or math.huge else math.huge
		local rightRank = if right then finisherRarityRank[right.rarity] or math.huge else math.huge

		if leftRank == rightRank then
			local leftOrder = if left then tonumber(left.catalogOrder) or 0 else 0
			local rightOrder = if right then tonumber(right.catalogOrder) or 0 else 0
			return leftOrder < rightOrder
		end

		return leftRank < rightRank
	end)

	return finisherIds
end

local function getSortedHighlightIntroCatalogIds(): { string }
	local introIds = HighlightIntroConfig.GetCatalogIds()

	table.sort(introIds, function(leftId, rightId)
		local left = HighlightIntroConfig.GetDefinition(leftId)
		local right = HighlightIntroConfig.GetDefinition(rightId)
		local leftRank = if left then highlightIntroRarityRank[left.rarity] or math.huge else math.huge
		local rightRank = if right then highlightIntroRarityRank[right.rarity] or math.huge else math.huge

		if leftRank == rightRank then
			local leftOrder = if left then tonumber(left.catalogOrder) or 0 else 0
			local rightOrder = if right then tonumber(right.catalogOrder) or 0 else 0
			return leftOrder < rightOrder
		end

		return leftRank < rightRank
	end)

	return introIds
end

local function partitionOwnedIds(ids: { string }, owned: { [string]: boolean }): ({ string }, { string })
	local ownedIds = {}
	local unownedIds = {}

	for _, id in ipairs(ids) do
		if owned[id] == true then
			table.insert(ownedIds, id)
		else
			table.insert(unownedIds, id)
		end
	end

	return ownedIds, unownedIds
end

local function appendIds(target: { string }, source: { string })
	for _, id in ipairs(source) do
		table.insert(target, id)
	end
end

local function findAbilityContainer(frame: Instance, name: string): GuiObject?
	for _, child in ipairs(frame:GetChildren()) do
		if child.Name == name and child:IsA("GuiObject") and child:FindFirstChildWhichIsA("ScrollingFrame") then
			return child
		end
	end

	return nil
end

local function findUnownedDivider(scroller: ScrollingFrame): GuiObject?
	local divider = scroller:FindFirstChild(UNOWNED_DIVIDER_NAME)
	return if divider and divider:IsA("GuiObject") then divider else nil
end

local function configureScrollerLayout(scroller: ScrollingFrame)
	local layout = scroller:FindFirstChildWhichIsA("UIListLayout")
	if layout then
		layout.SortOrder = Enum.SortOrder.LayoutOrder
	end
end

local function updateUnownedDivider(scroller: ScrollingFrame, ownedCount: number, unownedCount: number)
	local divider = findUnownedDivider(scroller)
	if not divider then
		return
	end

	divider.Visible = unownedCount > 0
	if unownedCount > 0 then
		divider.LayoutOrder = ownedCount + 1
	end
end

local function getGroupedItemLayoutOrder(index: number, ownedCount: number, unownedCount: number): number
	if unownedCount > 0 and index > ownedCount then
		return index + 1
	end

	return index
end

local function findSkinTemplate(scroller: ScrollingFrame, rarity: string?): ImageButton?
	local templateName = tostring(rarity or BombSkinConfig.Rarities.Common) .. SKIN_TEMPLATE_SUFFIX
	local template = scroller:FindFirstChild(templateName)
	if not (template and template:IsA("ImageButton")) then
		template = scroller:FindFirstChild(BombSkinConfig.Rarities.Common .. SKIN_TEMPLATE_SUFFIX)
	end

	return if template and template:IsA("ImageButton") then template else nil
end

local function findFinisherTemplate(scroller: ScrollingFrame, rarity: string?): ImageButton?
	local templateName = tostring(rarity or FinisherConfig.Rarities.Common) .. SKIN_TEMPLATE_SUFFIX
	local template = scroller:FindFirstChild(templateName)
	if not (template and template:IsA("ImageButton")) then
		template = scroller:FindFirstChild(FinisherConfig.Rarities.Common .. SKIN_TEMPLATE_SUFFIX)
	end

	return if template and template:IsA("ImageButton") then template else nil
end

local function findHighlightIntroTemplate(scroller: ScrollingFrame, rarity: string?): ImageButton?
	local templateName = tostring(rarity or HighlightIntroConfig.Rarities.Common) .. SKIN_TEMPLATE_SUFFIX
	local template = scroller:FindFirstChild(templateName)
	if not (template and template:IsA("ImageButton")) then
		template = scroller:FindFirstChild(HighlightIntroConfig.Rarities.Common .. SKIN_TEMPLATE_SUFFIX)
	end

	return if template and template:IsA("ImageButton") then template else nil
end

local function ensureHighlightIntroContainer(frame: Instance): GuiObject?
	local existing = findAbilityContainer(frame, INTROS_TAB_NAME)
	if existing then
		return existing
	end

	local source = findAbilityContainer(frame, FINISHERS_TAB_NAME) or findAbilityContainer(frame, SKINS_TAB_NAME)
	if not source then
		return nil
	end

	local clone = source:Clone()
	clone.Name = INTROS_TAB_NAME
	clone.Visible = false
	clone.Parent = frame
	return clone
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
	self._skillsButton = nil
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

function SkillsInventoryController:_disconnectFinisherTiles()
	for _, record in pairs(self._finisherTilesByFinisherId) do
		self:_cancelTileTween(record.button)
		if record.button.Parent then
			record.button.Size = record.normalSize
		end
	end

	disconnectAll(self._finisherTileConnections)
	table.clear(self._finisherTilesByFinisherId)
end

function SkillsInventoryController:_disconnectHighlightIntroTiles()
	for _, record in pairs(self._highlightIntroTilesById) do
		self:_cancelTileTween(record.button)
		if record.button.Parent then
			record.button.Size = record.normalSize
		end
	end

	disconnectAll(self._highlightIntroTileConnections)
	table.clear(self._highlightIntroTilesById)
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
	self:_disconnectFinisherTiles()
	self:_disconnectHighlightIntroTiles()
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
			or child.Name == FINISHERS_TAB_NAME
			or child.Name == INTROS_TAB_NAME
		local isSelected = child.Name == slot
		if child.Name == LEGACY_HIGHLIGHT_INTROS_TAB_NAME then
			isEnabledTab = false
			isSelected = false
			child.Visible = false
		end
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
	local ownedSkins = getOwnedSkins()
	local ownedFinishers = getOwnedFinishers()
	local ownedHighlightIntros = getOwnedHighlightIntros()
	local equippedSkinId = getEquippedSkinId()
	local equippedFinisherId = getEquippedFinisherId()
	local equippedHighlightIntroId = getEquippedHighlightIntroId()

	for abilityId, record in pairs(self._tilesByAbilityId) do
		local isSelected = AbilityConfig.IsKnownSlot(self._selectedTab) and abilityId == self._selectedAbilityId
		local isOwned = owned[abilityId] == true
		local isEquipped = loadout[record.slot] == abilityId

		record.button:SetAttribute("Selected", isSelected)
		record.button:SetAttribute("Owned", isOwned)
		record.button:SetAttribute("Equipped", isEquipped)
	end

	for skinId, record in pairs(self._skinTilesBySkinId) do
		local isSelected = self._selectedTab == SKINS_TAB_NAME and skinId == self._selectedSkinId
		local isOwned = ownedSkins[skinId] == true
		local isEquipped = equippedSkinId == skinId

		record.button:SetAttribute("Selected", isSelected)
		record.button:SetAttribute("Owned", isOwned)
		record.button:SetAttribute("Equipped", isEquipped)
	end

	for finisherId, record in pairs(self._finisherTilesByFinisherId) do
		local isSelected = self._selectedTab == FINISHERS_TAB_NAME and finisherId == self._selectedFinisherId
		local isOwned = ownedFinishers[finisherId] == true
		local isEquipped = equippedFinisherId == finisherId

		record.button:SetAttribute("Selected", isSelected)
		record.button:SetAttribute("Owned", isOwned)
		record.button:SetAttribute("Equipped", isEquipped)
	end

	for introId, record in pairs(self._highlightIntroTilesById) do
		local isSelected = self._selectedTab == INTROS_TAB_NAME and introId == self._selectedHighlightIntroId
		local isOwned = ownedHighlightIntros[introId] == true
		local isEquipped = equippedHighlightIntroId == introId

		record.button:SetAttribute("Selected", isSelected)
		record.button:SetAttribute("Owned", isOwned)
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

	local isOwned = owned[definition.id] == true
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
	setButtonVisible(equipButton, isOwned and not isEquipped)
	setButtonVisible(unequipButton, isOwned and isEquipped)
	if isEquipped then
		setButtonEnabled(unequipButton, false)
	end
	setButtonVisible(favoriteButton, false)

	if warning then
		local statusText = self._statusBySkinId[definition.id]
		if statusText and statusText ~= "" then
			warning.Text = statusText
			warning.Visible = true
		elseif not isOwned then
			warning.Text = LOCKED_COSMETIC_WARNING_TEXT
			warning.Visible = true
		else
			warning.Visible = false
		end
	end
end

function SkillsInventoryController:_updateFinisherRightPanel()
	local right = self._right
	if not right then
		return
	end

	local finisherId = self._selectedFinisherId
	local definition = FinisherConfig.GetDefinition(finisherId)
	local owned = getOwnedFinishers()
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

	local isOwned = owned[definition.id] == true
	local isEquipped = getEquippedFinisherId() == definition.id

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
	setButtonVisible(equipButton, isOwned and not isEquipped)
	setButtonVisible(unequipButton, isOwned and isEquipped)
	if isEquipped then
		setButtonEnabled(unequipButton, false)
	end
	setButtonVisible(favoriteButton, false)

	if warning then
		local statusText = self._statusByFinisherId[definition.id]
		if statusText and statusText ~= "" then
			warning.Text = statusText
			warning.Visible = true
		elseif not isOwned then
			warning.Text = LOCKED_COSMETIC_WARNING_TEXT
			warning.Visible = true
		else
			warning.Visible = false
		end
	end
end

function SkillsInventoryController:_updateHighlightIntroRightPanel()
	local right = self._right
	if not right then
		return
	end

	local introId = self._selectedHighlightIntroId
	local definition = HighlightIntroConfig.GetDefinition(introId)
	local owned = getOwnedHighlightIntros()
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

	local isOwned = owned[definition.id] == true
	local isEquipped = getEquippedHighlightIntroId() == definition.id

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
	setButtonVisible(equipButton, isOwned and not isEquipped)
	setButtonVisible(unequipButton, isOwned and isEquipped)
	if isEquipped then
		setButtonEnabled(unequipButton, false)
	end
	setButtonVisible(favoriteButton, false)

	if warning then
		local statusText = self._statusByHighlightIntroId[definition.id]
		if statusText and statusText ~= "" then
			warning.Text = statusText
			warning.Visible = true
		elseif not isOwned then
			warning.Text = LOCKED_COSMETIC_WARNING_TEXT
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
	if self._selectedTab == FINISHERS_TAB_NAME then
		self:_updateFinisherRightPanel()
		return
	end
	if self._selectedTab == INTROS_TAB_NAME then
		self:_updateHighlightIntroRightPanel()
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
	local purchaseKind = definition.purchaseKind or AbilityConfig.PurchaseKinds.Coins
	local canBuyWithCoins = purchaseKind == AbilityConfig.PurchaseKinds.Coins and price > 0
	local isBundleOnly = purchaseKind == AbilityConfig.PurchaseKinds.Bundle

	if icon then
		icon.Image = definition.icon or ""
	end
	if nameLabel then
		nameLabel.Text = definition.displayName or definition.id
	end
	if descriptionLabel then
		descriptionLabel.Text = definition.description or ""
	end

	if isBundleOnly then
		setButtonLabel(buyButton, "LOCKED")
		setBuyPrice(buyButton, definition.bundleLabel or "Bundle only")
	else
		setButtonLabel(buyButton, "BUY")
		setBuyPrice(buyButton, price)
	end
	setButtonLabel(equipButton, "EQUIP")
	setButtonLabel(unequipButton, "UNEQUIP")

	setButtonVisible(buyButton, not isOwned and (canBuyWithCoins or isBundleOnly))
	if buyButton and isBundleOnly and not isOwned then
		setButtonEnabled(buyButton, false)
	end
	setButtonVisible(equipButton, isOwned and not isEquipped)
	setButtonVisible(unequipButton, isOwned and isEquipped)
	setButtonVisible(favoriteButton, false)

	if warning then
		local statusText = self._statusByAbilityId[definition.id]
		if statusText and statusText ~= "" then
			warning.Text = statusText
			warning.Visible = true
		elseif isBundleOnly and not isOwned then
			warning.Text = definition.bundleLabel or "Bundle only"
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

function SkillsInventoryController:_isInventoryLocked(): boolean
	local state = RoundController:GetState()
	return typeof(state) == "table"
		and isLockedRoundState(state.state)
		and LocalPlayer:GetAttribute(ROUND_ID_ATTR) ~= nil
end

function SkillsInventoryController:_syncRoundLock()
	local locked = self:_isInventoryLocked()
	setButtonEnabled(self._skillsButton, not locked)

	if locked then
		FrameController:CloseFrame(FRAME_NAME, true)
	end
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

	self._selectedTab = SKINS_TAB_NAME
	self._selectedSkinId = definition.id
	self:_setContainerVisible(SKINS_TAB_NAME)
	self:_setTopbarState(SKINS_TAB_NAME)
	self:_refresh()
end

function SkillsInventoryController:_selectFinisher(finisherId: string)
	local definition = FinisherConfig.GetDefinition(finisherId)
	if not definition then
		return
	end

	self._selectedTab = FINISHERS_TAB_NAME
	self._selectedFinisherId = definition.id
	self:_setContainerVisible(FINISHERS_TAB_NAME)
	self:_setTopbarState(FINISHERS_TAB_NAME)
	self:_refresh()
end

function SkillsInventoryController:_selectHighlightIntro(highlightIntroId: string)
	local definition = HighlightIntroConfig.GetDefinition(highlightIntroId)
	if not definition then
		return
	end

	self._selectedTab = INTROS_TAB_NAME
	self._selectedHighlightIntroId = definition.id
	self:_setContainerVisible(INTROS_TAB_NAME)
	self:_setTopbarState(INTROS_TAB_NAME)
	self:_refresh()
end

function SkillsInventoryController:_selectSlot(slot: string)
	if slot == SKINS_TAB_NAME then
		self._selectedTab = SKINS_TAB_NAME
		self:_setContainerVisible(SKINS_TAB_NAME)
		self:_setTopbarState(SKINS_TAB_NAME)

		local owned = getOwnedSkins()
		local selectedSkin = BombSkinConfig.GetDefinition(self._selectedSkinId)
		if selectedSkin then
			self:_refresh()
			return
		end

		local equippedSkinId = getEquippedSkinId()
		if owned[equippedSkinId] == true then
			self:_selectSkin(equippedSkinId)
			return
		end

		local skinIds = getSortedSkinCatalogIds()
		self:_selectSkin(skinIds[1] or BombSkinConfig.DefaultSkinId)
		return
	end

	if slot == FINISHERS_TAB_NAME then
		self._selectedTab = FINISHERS_TAB_NAME
		self:_setContainerVisible(FINISHERS_TAB_NAME)
		self:_setTopbarState(FINISHERS_TAB_NAME)

		local owned = getOwnedFinishers()
		local selectedFinisher = FinisherConfig.GetDefinition(self._selectedFinisherId)
		if selectedFinisher then
			self:_refresh()
			return
		end

		local equippedFinisherId = getEquippedFinisherId()
		if owned[equippedFinisherId] == true then
			self:_selectFinisher(equippedFinisherId)
			return
		end

		local finisherIds = getSortedFinisherCatalogIds()
		local firstFinisherId = finisherIds[1]
		if firstFinisherId then
			self:_selectFinisher(firstFinisherId)
		else
			self._selectedFinisherId = FinisherConfig.DefaultFinisherId
			self:_refresh()
		end
		return
	end

	if slot == INTROS_TAB_NAME then
		self._selectedTab = INTROS_TAB_NAME
		self:_setContainerVisible(INTROS_TAB_NAME)
		self:_setTopbarState(INTROS_TAB_NAME)

		local owned = getOwnedHighlightIntros()
		local selectedIntro = HighlightIntroConfig.GetDefinition(self._selectedHighlightIntroId)
		if selectedIntro then
			self:_refresh()
			return
		end

		local equippedIntroId = getEquippedHighlightIntroId()
		if owned[equippedIntroId] == true then
			self:_selectHighlightIntro(equippedIntroId)
			return
		end

		local introIds = getSortedHighlightIntroCatalogIds()
		local firstIntroId = introIds[1]
		if firstIntroId then
			self:_selectHighlightIntro(firstIntroId)
		else
			self._selectedHighlightIntroId = HighlightIntroConfig.DefaultHighlightIntroId
			self:_refresh()
		end
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
	if getOwnedSkins()[definition.id] ~= true then
		return
	end

	self._statusBySkinId[definition.id] = nil
	remote:FireServer({
		action = action,
		skinId = definition.id,
	})
end

function SkillsInventoryController:_sendFinisherAction(action: string)
	if action ~= FinisherConfig.InventoryActions.Equip then
		return
	end

	local remote = self._finisherRemote
	local definition = FinisherConfig.GetDefinition(self._selectedFinisherId)
	if not (remote and definition) then
		return
	end
	if getOwnedFinishers()[definition.id] ~= true then
		return
	end

	self._statusByFinisherId[definition.id] = nil
	remote:FireServer({
		action = action,
		finisherId = definition.id,
	})
end

function SkillsInventoryController:_sendHighlightIntroAction(action: string)
	if action ~= HighlightIntroConfig.InventoryActions.Equip then
		return
	end

	local remote = self._highlightIntroRemote
	local definition = HighlightIntroConfig.GetDefinition(self._selectedHighlightIntroId)
	if not (remote and definition) then
		return
	end
	if getOwnedHighlightIntros()[definition.id] ~= true then
		return
	end

	self._statusByHighlightIntroId[definition.id] = nil
	remote:FireServer({
		action = action,
		highlightIntroId = definition.id,
	})
end

function SkillsInventoryController:_sendAction(action: string)
	if self._selectedTab == SKINS_TAB_NAME then
		self:_sendSkinAction(action)
		return
	end
	if self._selectedTab == FINISHERS_TAB_NAME then
		self:_sendFinisherAction(action)
		return
	end
	if self._selectedTab == INTROS_TAB_NAME then
		self:_sendHighlightIntroAction(action)
		return
	end

	local remote = self._remote
	local definition = AbilityConfig.GetDefinition(self._selectedAbilityId)
	if not (remote and definition) then
		return
	end

	if action == AbilityConfig.InventoryActions.Buy then
		local purchaseKind = definition.purchaseKind or AbilityConfig.PurchaseKinds.Coins
		local price = math.max(math.floor(tonumber(definition.price) or 0), 0)
		if purchaseKind == AbilityConfig.PurchaseKinds.Bundle then
			self._statusByAbilityId[definition.id] = definition.bundleLabel or "Bundle only"
			self:_refresh()
			return
		elseif purchaseKind ~= AbilityConfig.PurchaseKinds.Coins or price <= 0 then
			self._statusByAbilityId[definition.id] = "This skill is already unlocked."
			self:_refresh()
			return
		end
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

function SkillsInventoryController:_bindFinisherTileButton(button: ImageButton, finisherId: string)
	local normalSize = button.Size
	local bigSize = scaleUDim2(normalSize, TILE_HOVER_SIZE_FACTOR)
	local smallSize = scaleUDim2(normalSize, TILE_PRESSED_SIZE_FACTOR)

	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button:SetAttribute("defaultSize", normalSize)
	button:SetAttribute("Hovered", false)
	button:SetAttribute("Pressed", false)

	track(self._finisherTileConnections, button.MouseEnter:Connect(function()
		button:SetAttribute("Hovered", true)
		self:_tweenTileButton(button, bigSize)
	end))

	track(self._finisherTileConnections, button.MouseLeave:Connect(function()
		button:SetAttribute("Hovered", false)
		button:SetAttribute("Pressed", false)
		self:_tweenTileButton(button, normalSize)
	end))

	track(self._finisherTileConnections, button.MouseButton1Down:Connect(function()
		button:SetAttribute("Pressed", true)
		self:_tweenTileButton(button, smallSize)
	end))
	track(self._finisherTileConnections, button.MouseButton1Up:Connect(function()
		button:SetAttribute("Pressed", false)
		self:_tweenTileButton(button, bigSize)
	end))
	track(self._finisherTileConnections, button.Activated:Connect(function()
		button:SetAttribute("Pressed", false)
		playClick()
		self:_selectFinisher(finisherId)
	end))
	track(self._finisherTileConnections, button.MouseButton1Click:Connect(function()
		button:SetAttribute("Pressed", false)
		self:_selectFinisher(finisherId)
	end))
end

function SkillsInventoryController:_bindHighlightIntroTileButton(button: ImageButton, highlightIntroId: string)
	local normalSize = button.Size
	local bigSize = scaleUDim2(normalSize, TILE_HOVER_SIZE_FACTOR)
	local smallSize = scaleUDim2(normalSize, TILE_PRESSED_SIZE_FACTOR)

	button.Active = true
	button.Selectable = true
	button.AutoButtonColor = true
	button:SetAttribute("defaultSize", normalSize)
	button:SetAttribute("Hovered", false)
	button:SetAttribute("Pressed", false)

	track(self._highlightIntroTileConnections, button.MouseEnter:Connect(function()
		button:SetAttribute("Hovered", true)
		self:_tweenTileButton(button, bigSize)
	end))

	track(self._highlightIntroTileConnections, button.MouseLeave:Connect(function()
		button:SetAttribute("Hovered", false)
		button:SetAttribute("Pressed", false)
		self:_tweenTileButton(button, normalSize)
	end))

	track(self._highlightIntroTileConnections, button.MouseButton1Down:Connect(function()
		button:SetAttribute("Pressed", true)
		self:_tweenTileButton(button, smallSize)
	end))
	track(self._highlightIntroTileConnections, button.MouseButton1Up:Connect(function()
		button:SetAttribute("Pressed", false)
		self:_tweenTileButton(button, bigSize)
	end))
	track(self._highlightIntroTileConnections, button.Activated:Connect(function()
		button:SetAttribute("Pressed", false)
		playClick()
		self:_selectHighlightIntro(highlightIntroId)
	end))
	track(self._highlightIntroTileConnections, button.MouseButton1Click:Connect(function()
		button:SetAttribute("Pressed", false)
		self:_selectHighlightIntro(highlightIntroId)
	end))
end

local function clearCosmeticTiles(scroller: ScrollingFrame, runtimeTileAttribute: string)
	for _, child in ipairs(scroller:GetChildren()) do
		if not child:IsA("ImageButton") then
			continue
		end

		if child:GetAttribute(runtimeTileAttribute) == true then
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
	configureScrollerLayout(scroller)
	restoreRuntimeTileSlots(scroller)
	removeRuntimeTileScales(scroller)

	local records = getTileButtonRecords(scroller)
	local textStyleTemplates = buildTextStyleTemplates(records)
	local ownedAbilityIds, unownedAbilityIds = partitionOwnedIds(AbilityConfig.GetCatalogIds(slot), getOwnedAbilities())
	local abilityIds = {}
	appendIds(abilityIds, ownedAbilityIds)
	appendIds(abilityIds, unownedAbilityIds)
	updateUnownedDivider(scroller, #ownedAbilityIds, #unownedAbilityIds)
	if #abilityIds > #records then
		warn(("[SkillsInventoryController] Missing %d authored tile(s) for %s catalog."):format(#abilityIds - #records, slot))
	end

	for index, record in ipairs(records) do
		local button = record.button
		local layoutObject = record.layoutObject
		local abilityId = abilityIds[index]
		local definition = AbilityConfig.GetDefinition(abilityId)
		local layoutOrder = getGroupedItemLayoutOrder(index, #ownedAbilityIds, #unownedAbilityIds)
		layoutObject.LayoutOrder = layoutOrder
		button.LayoutOrder = layoutOrder

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
	configureScrollerLayout(scroller)
	removeRuntimeTileScales(scroller)
	clearCosmeticTiles(scroller, SKIN_RUNTIME_TILE_ATTRIBUTE)

	local owned = getOwnedSkins()
	local ownedSkinIds, unownedSkinIds = partitionOwnedIds(getSortedSkinCatalogIds(), owned)
	local skinIds = {}
	appendIds(skinIds, ownedSkinIds)
	appendIds(skinIds, unownedSkinIds)
	updateUnownedDivider(scroller, #ownedSkinIds, #unownedSkinIds)
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
		button.LayoutOrder = getGroupedItemLayoutOrder(index, #ownedSkinIds, #unownedSkinIds)
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

function SkillsInventoryController:_populateFinishers(container: GuiObject?)
	if not container then
		return
	end

	local scroller = container:FindFirstChildWhichIsA("ScrollingFrame")
	if not scroller then
		return
	end

	self:_disconnectFinisherTiles()
	disableAuthoredTileTweenScripts(scroller)
	configureScrollerLayout(scroller)
	removeRuntimeTileScales(scroller)
	clearCosmeticTiles(scroller, FINISHER_RUNTIME_TILE_ATTRIBUTE)

	local owned = getOwnedFinishers()
	local ownedFinisherIds, unownedFinisherIds = partitionOwnedIds(getSortedFinisherCatalogIds(), owned)
	local finisherIds = {}
	appendIds(finisherIds, ownedFinisherIds)
	appendIds(finisherIds, unownedFinisherIds)
	updateUnownedDivider(scroller, #ownedFinisherIds, #unownedFinisherIds)
	local finisherCopies = getFinisherCopies()

	for index, finisherId in ipairs(finisherIds) do
		local definition = FinisherConfig.GetDefinition(finisherId)
		if not definition then
			continue
		end

		local template = findFinisherTemplate(scroller, definition.rarity)
		if not template then
			warn(("[SkillsInventoryController] Missing finisher inventory template for rarity '%s'."):format(tostring(definition.rarity)))
			continue
		end

		local button = template:Clone()
		button.Name = "Finisher_" .. definition.id
		button.LayoutOrder = getGroupedItemLayoutOrder(index, #ownedFinisherIds, #unownedFinisherIds)
		button.Visible = true
		button.Active = true
		button.Selectable = true
		button:SetAttribute(FINISHER_RUNTIME_TILE_ATTRIBUTE, true)
		button:SetAttribute("FinisherId", definition.id)
		button:SetAttribute("Rarity", definition.rarity)

		local label = findTextLabel(button, "Label")
		if label then
			label.Text = formatSkinTileName(definition, finisherCopies[definition.id] or 1)
		end

		local icon = findImage(button, "Icon")
		if icon then
			icon.Image = definition.iconImage or ""
		end

		button.Parent = scroller

		self._finisherTilesByFinisherId[definition.id] = {
			button = button,
			finisherId = definition.id,
			normalSize = button.Size,
		}

		self:_bindFinisherTileButton(button, definition.id)
	end
end

function SkillsInventoryController:_populateHighlightIntros(container: GuiObject?)
	if not container then
		return
	end

	local scroller = container:FindFirstChildWhichIsA("ScrollingFrame")
	if not scroller then
		return
	end

	self:_disconnectHighlightIntroTiles()
	disableAuthoredTileTweenScripts(scroller)
	configureScrollerLayout(scroller)
	removeRuntimeTileScales(scroller)
	clearCosmeticTiles(scroller, HIGHLIGHT_INTRO_RUNTIME_TILE_ATTRIBUTE)

	local owned = getOwnedHighlightIntros()
	local ownedIntroIds, unownedIntroIds = partitionOwnedIds(getSortedHighlightIntroCatalogIds(), owned)
	local introIds = {}
	appendIds(introIds, ownedIntroIds)
	appendIds(introIds, unownedIntroIds)
	updateUnownedDivider(scroller, #ownedIntroIds, #unownedIntroIds)
	local introCopies = getHighlightIntroCopies()

	for index, introId in ipairs(introIds) do
		local definition = HighlightIntroConfig.GetDefinition(introId)
		if not definition then
			continue
		end

		local template = findHighlightIntroTemplate(scroller, definition.rarity)
		if not template then
			warn(("[SkillsInventoryController] Missing highlight intro inventory template for rarity '%s'."):format(tostring(definition.rarity)))
			continue
		end

		local button = template:Clone()
		button.Name = "HighlightIntro_" .. definition.id
		button.LayoutOrder = getGroupedItemLayoutOrder(index, #ownedIntroIds, #unownedIntroIds)
		button.Visible = true
		button.Active = true
		button.Selectable = true
		button:SetAttribute(HIGHLIGHT_INTRO_RUNTIME_TILE_ATTRIBUTE, true)
		button:SetAttribute("HighlightIntroId", definition.id)
		button:SetAttribute("Rarity", definition.rarity)

		local label = findTextLabel(button, "Label")
		if label then
			label.Text = formatSkinTileName(definition, introCopies[definition.id] or 1)
		end

		local icon = findImage(button, "Icon")
		if icon then
			icon.Image = definition.iconImage or ""
		end

		button.Parent = scroller

		self._highlightIntroTilesById[definition.id] = {
			button = button,
			highlightIntroId = definition.id,
			normalSize = button.Size,
		}

		self:_bindHighlightIntroTileButton(button, definition.id)
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
	self._containers[FINISHERS_TAB_NAME] = findAbilityContainer(frame, FINISHERS_TAB_NAME)
	self._containers[INTROS_TAB_NAME] = ensureHighlightIntroContainer(frame)

	for slot, container in pairs(self._containers) do
		if slot == SKINS_TAB_NAME then
			self:_populateSkins(container)
		elseif slot == FINISHERS_TAB_NAME then
			self:_populateFinishers(container)
		elseif slot == INTROS_TAB_NAME then
			self:_populateHighlightIntros(container)
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
	if self:_isInventoryLocked() then
		self:_syncRoundLock()
		return
	end

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
	self._skillsButton = skillsButton
	track(self._hudConnections, skillsButton.Activated:Connect(function()
		self:_toggleFrameFromHud()
	end))
	track(self._hudConnections, skillsButton.MouseButton1Click:Connect(function()
		self:_toggleFrameFromHud()
	end))
	self:_syncRoundLock()
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

	self._finisherRemote = getFinisherRemote()
	if self._finisherRemote then
		track(self._connections, self._finisherRemote.OnClientEvent:Connect(function(response)
			if typeof(response) ~= "table" then
				return
			end

			local finisherId = FinisherConfig.NormalizeFinisherId(response.finisherId)
			if finisherId ~= "" then
				self._statusByFinisherId[finisherId] =
					if response.ok == true then nil else tostring(response.message or "Finisher action failed.")
			end

			self:_refresh()
		end))
	end

	self._highlightIntroRemote = getHighlightIntroRemote()
	if self._highlightIntroRemote then
		track(self._connections, self._highlightIntroRemote.OnClientEvent:Connect(function(response)
			if typeof(response) ~= "table" then
				return
			end

			local introId = HighlightIntroConfig.NormalizeHighlightIntroId(response.highlightIntroId)
			if introId ~= "" then
				self._statusByHighlightIntroId[introId] =
					if response.ok == true then nil else tostring(response.message or "Highlight intro action failed.")
			end
			local equippedIntroId = HighlightIntroConfig.NormalizeHighlightIntroId(response.equippedHighlightIntroId)
			if response.ok == true and equippedIntroId ~= "" then
				equippedHighlightIntroOverride = equippedIntroId
				LocalPlayer:SetAttribute(HighlightIntroConfig.AttributeName, equippedIntroId)
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
				self:_syncRoundLock()
			end)
		elseif child.Name == HUD_GUI_NAME then
			task.defer(function()
				self:_bindCurrentHud()
			end)
		end
	end))

	track(self._connections, RoundController.StateReceived:Connect(function()
		self:_syncRoundLock()
	end))
	track(self._connections, RoundController.StateUpdated:Connect(function(key)
		if key == "state" then
			self:_syncRoundLock()
		end
	end))
	track(self._connections, LocalPlayer:GetAttributeChangedSignal(ROUND_ID_ATTR):Connect(function()
		self:_syncRoundLock()
	end))
	if RoundController.Loaded then
		self:_syncRoundLock()
	end

	track(self._connections, DataController.DataReceived:Connect(function()
		if self._containers[AbilityConfig.Slots.Offensive] then
			self:_populateSlot(AbilityConfig.Slots.Offensive, self._containers[AbilityConfig.Slots.Offensive])
		end
		if self._containers[AbilityConfig.Slots.Defensive] then
			self:_populateSlot(AbilityConfig.Slots.Defensive, self._containers[AbilityConfig.Slots.Defensive])
		end
		if self._containers[SKINS_TAB_NAME] then
			self:_populateSkins(self._containers[SKINS_TAB_NAME])
		end
		if self._containers[FINISHERS_TAB_NAME] then
			self:_populateFinishers(self._containers[FINISHERS_TAB_NAME])
		end
		if self._containers[INTROS_TAB_NAME] then
			self:_populateHighlightIntros(self._containers[INTROS_TAB_NAME])
		end
		if self._selectedTab == SKINS_TAB_NAME then
			self:_selectSlot(SKINS_TAB_NAME)
		elseif self._selectedTab == FINISHERS_TAB_NAME then
			self:_selectSlot(FINISHERS_TAB_NAME)
		elseif self._selectedTab == INTROS_TAB_NAME then
			self:_selectSlot(INTROS_TAB_NAME)
		else
			self:_refresh()
		end
	end))
	track(self._connections, DataController.DataUpdated:Connect(function(key)
		if key == OWNED_ABILITIES_KEY then
			if self._containers[AbilityConfig.Slots.Offensive] then
				self:_populateSlot(AbilityConfig.Slots.Offensive, self._containers[AbilityConfig.Slots.Offensive])
			end
			if self._containers[AbilityConfig.Slots.Defensive] then
				self:_populateSlot(AbilityConfig.Slots.Defensive, self._containers[AbilityConfig.Slots.Defensive])
			end
			self:_refresh()
		elseif key == LOADOUT_KEY then
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
		elseif key == OWNED_FINISHERS_KEY or key == FINISHER_COPIES_KEY then
			if self._containers[FINISHERS_TAB_NAME] then
				self:_populateFinishers(self._containers[FINISHERS_TAB_NAME])
			end
			if self._selectedTab == FINISHERS_TAB_NAME then
				self:_selectSlot(FINISHERS_TAB_NAME)
			else
				self:_refresh()
			end
		elseif key == OWNED_HIGHLIGHT_INTROS_KEY or key == HIGHLIGHT_INTRO_COPIES_KEY then
			if self._containers[INTROS_TAB_NAME] then
				self:_populateHighlightIntros(self._containers[INTROS_TAB_NAME])
			end
			if self._selectedTab == INTROS_TAB_NAME then
				self:_selectSlot(INTROS_TAB_NAME)
			else
				self:_refresh()
			end
		elseif key == EQUIPPED_SKIN_KEY then
			self:_refresh()
		elseif key == EQUIPPED_FINISHER_KEY then
			self:_refresh()
		elseif key == EQUIPPED_HIGHLIGHT_INTRO_KEY then
			equippedHighlightIntroOverride = nil
			self:_refresh()
		end
	end))
end

return SkillsInventoryController
