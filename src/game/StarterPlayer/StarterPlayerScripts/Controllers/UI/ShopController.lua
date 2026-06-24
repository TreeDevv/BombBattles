local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local RobuxPurchases = require(ReplicatedStorage.Shared.Config.Lists.RobuxPurchases)
local ShopCatalog = require(ReplicatedStorage.Shared.Config.ShopCatalog)

local FrameController = require(script.Parent:WaitForChild("FrameController"))
local GiftMenuController = require(script.Parent:WaitForChild("GiftMenuController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = "Shop"
local FRAMES_GUI_NAME = "Frames"
local HUD_NAME = "HUD"
local SIDE_BUTTONS_NAME = "SideButtons"
local PRICE_LABEL_NAME = "RobuxCost"
local PRICE_REQUEST_ATTRIBUTE = "ShopPriceRequest"
local SELECTED_IMAGE_TRANSPARENCY = 0
local DESELECTED_IMAGE_TRANSPARENCY = 1

local ShopController = {}

ShopController._connections = {} :: { RBXScriptConnection }
ShopController._frameConnections = {} :: { RBXScriptConnection }
ShopController._priceSerial = 0
ShopController._passOwnershipSerial = 0
ShopController._passOwned = {} :: { [string]: boolean }
ShopController._cards = {} :: { [any]: ImageButton }
ShopController._selectedEntry = nil
ShopController._frame = nil :: GuiObject?
ShopController._hudButton = nil :: GuiButton?
ShopController._hudButtonConnection = nil :: RBXScriptConnection?
ShopController._right = nil :: Instance?
ShopController._rightName = nil :: TextLabel?
ShopController._rightDescription = nil :: TextLabel?
ShopController._rightIcon = nil :: ImageLabel?
ShopController._rightPrice = nil :: TextLabel?
ShopController._rightWarning = nil :: TextLabel?
ShopController._buyButton = nil :: GuiButton?
ShopController._buyLabel = nil :: TextLabel?
ShopController._giftButton = nil :: GuiButton?

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function track(connections: { RBXScriptConnection }, connection: RBXScriptConnection?)
	if connection then
		table.insert(connections, connection)
	end
end

local function findTextLabel(root: Instance?, name: string): TextLabel?
	local child = root and root:FindFirstChild(name, true)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findImageLabel(root: Instance?, name: string): ImageLabel?
	local child = root and root:FindFirstChild(name, true)
	return if child and child:IsA("ImageLabel") then child else nil
end

local function findGuiButton(root: Instance?, name: string): GuiButton?
	local child = root and root:FindFirstChild(name, true)
	return if child and child:IsA("GuiButton") then child else nil
end

local function setButtonEnabled(button: GuiButton?, enabled: boolean)
	if not button then
		return
	end

	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
end

local function getProductConfig(entry)
	if not entry or entry.kind ~= ShopCatalog.Kinds.Product then
		return nil
	end

	return RobuxPurchases.Products[entry.key]
end

local function getPassConfig(entry)
	if not entry or entry.kind ~= ShopCatalog.Kinds.Pass then
		return nil
	end

	return RobuxPurchases.Passes[entry.key]
end

local function getOfferConfig(entry)
	return if entry and entry.kind == ShopCatalog.Kinds.Pass then getPassConfig(entry) else getProductConfig(entry)
end

local function getOfferId(entry): number
	local config = getOfferConfig(entry)
	return math.floor(tonumber(config and config.id) or 0)
end

local function fallbackPrice(entry): string
	local config = getOfferConfig(entry)
	local price = tonumber(config and config.price) or 0
	return if price > 0 then tostring(math.floor(price)) else "OFFSALE"
end

local function getDisplayName(entry): string
	local config = getOfferConfig(entry)
	return tostring((entry and entry.displayName) or (config and config.displayName) or (entry and entry.key) or "Shop Item")
end

local function getGiftProductKey(entry): string?
	if not entry or entry.kind ~= ShopCatalog.Kinds.Product then
		return nil
	end

	local product = getProductConfig(entry)
	local direct = product and product.giftProductKey
	if typeof(direct) == "string" and direct ~= "" then
		return direct
	end

	local mapped = RobuxPurchases.GiftProductsByTargetKey and RobuxPurchases.GiftProductsByTargetKey[entry.key]
	if typeof(mapped) == "string" and mapped ~= "" then
		return mapped
	end

	return nil
end

local function getPriceInfoType(entry): Enum.InfoType?
	if entry.kind == ShopCatalog.Kinds.Product then
		return Enum.InfoType.Product
	elseif entry.kind == ShopCatalog.Kinds.Pass then
		return Enum.InfoType.GamePass
	end

	return nil
end

local function setBackSelected(card: ImageButton, selected: boolean)
	local back = card:FindFirstChild("Back")
	if back and back:IsA("ImageLabel") then
		back.ImageTransparency = if selected then SELECTED_IMAGE_TRANSPARENCY else DESELECTED_IMAGE_TRANSPARENCY
	end
end

function ShopController:_isEntryOwned(entry): boolean
	if not entry then
		return false
	end

	if typeof(entry.ownedAttribute) == "string" and entry.ownedAttribute ~= "" then
		return LocalPlayer:GetAttribute(entry.ownedAttribute) == true
	end

	if entry.kind == ShopCatalog.Kinds.Pass then
		return self._passOwned[entry.key] == true
	end

	return false
end

function ShopController:_isEntryAvailable(entry): boolean
	return getOfferId(entry) > 0
end

function ShopController:_setPriceLabel(label: TextLabel?, entry)
	if not label then
		return
	end

	label.Text = fallbackPrice(entry)
	local offerId = getOfferId(entry)
	local infoType = getPriceInfoType(entry)
	if offerId <= 0 or not infoType then
		return
	end

	self._priceSerial += 1
	local serial = self._priceSerial
	label:SetAttribute(PRICE_REQUEST_ATTRIBUTE, serial)
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(offerId, infoType)
		end)
		if not ok or label:GetAttribute(PRICE_REQUEST_ATTRIBUTE) ~= serial then
			return
		end

		local price = typeof(info) == "table" and tonumber(info.PriceInRobux) or nil
		if price and price > 0 and label.Parent then
			label.Text = tostring(math.floor(price))
		end
	end)
end

function ShopController:_refreshCardPrice(card: ImageButton, entry)
	self:_setPriceLabel(findTextLabel(card, PRICE_LABEL_NAME), entry)
end

function ShopController:_refreshPassOwnership(entry)
	if not entry or entry.kind ~= ShopCatalog.Kinds.Pass then
		return
	end

	local passId = getOfferId(entry)
	if passId <= 0 then
		return
	end

	self._passOwnershipSerial += 1
	local serial = self._passOwnershipSerial
	task.spawn(function()
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(LocalPlayer.UserId, passId)
		end)
		if not ok or serial ~= self._passOwnershipSerial then
			return
		end

		self._passOwned[entry.key] = owns == true
		if self._selectedEntry == entry then
			self:_renderSelectedEntry()
		end
	end)
end

function ShopController:_renderSelectedEntry()
	local entry = self._selectedEntry
	if not entry then
		return
	end

	for cardEntry, card in pairs(self._cards) do
		setBackSelected(card, cardEntry == entry)
	end

	if self._rightName then
		self._rightName.Text = getDisplayName(entry)
	end
	if self._rightDescription then
		self._rightDescription.Text = tostring(entry.description or "")
	end

	local selectedCard = self._cards[entry]
	local cardIcon = selectedCard and findImageLabel(selectedCard, "Icon") or nil
	if self._rightIcon and cardIcon then
		self._rightIcon.Image = cardIcon.Image
	end

	self:_setPriceLabel(self._rightPrice, entry)

	local available = self:_isEntryAvailable(entry)
	local owned = self:_isEntryOwned(entry)
	setButtonEnabled(self._buyButton, available and not owned)
	if self._buyLabel then
		if not available then
			self._buyLabel.Text = "OFFSALE"
		elseif owned then
			self._buyLabel.Text = tostring(entry.ownedText or "OWNED")
		else
			self._buyLabel.Text = "BUY"
		end
	end

	if self._rightWarning then
		self._rightWarning.Visible = not available or owned
		self._rightWarning.Text = if owned then "Already owned" else "Unavailable"
	end

	local giftProductKey = getGiftProductKey(entry)
	local giftConfig = giftProductKey and RobuxPurchases.Products[giftProductKey] or nil
	local giftProductId = math.floor(tonumber(giftConfig and giftConfig.id) or 0)
	local canGift = entry.kind == ShopCatalog.Kinds.Product and giftProductId > 0
	if self._giftButton then
		self._giftButton.Visible = canGift
		setButtonEnabled(self._giftButton, canGift)
	end
end

function ShopController:_selectEntry(entry)
	if not entry then
		return
	end

	self._selectedEntry = entry
	self:_refreshPassOwnership(entry)
	self:_renderSelectedEntry()
end

function ShopController:_promptSelectedEntry()
	local entry = self._selectedEntry
	if not entry then
		return
	end

	local offerId = getOfferId(entry)
	if offerId <= 0 then
		Notify.Show("This item is unavailable.", { color = "Red" })
		return
	end

	if self:_isEntryOwned(entry) then
		Notify.Show("You already own this item.", { color = "Orange" })
		return
	end

	if entry.kind == ShopCatalog.Kinds.Pass then
		MarketplaceService:PromptGamePassPurchase(LocalPlayer, offerId)
	elseif entry.kind == ShopCatalog.Kinds.Product then
		MarketplaceService:PromptProductPurchase(LocalPlayer, offerId)
	end
end

function ShopController:_promptSelectedGift()
	local entry = self._selectedEntry
	local giftProductKey = getGiftProductKey(entry)
	if not (entry and giftProductKey) then
		Notify.Show("This item cannot be gifted yet.", { color = "Red" })
		return
	end

	local giftConfig = RobuxPurchases.Products[giftProductKey]
	local giftProductId = math.floor(tonumber(giftConfig and giftConfig.id) or 0)
	if giftProductId <= 0 then
		Notify.Show("Gift product is unavailable.", { color = "Red" })
		return
	end

	local selectedCard = self._cards[entry]
	local cardIcon = selectedCard and findImageLabel(selectedCard, "Icon") or nil
	GiftMenuController:OpenForProduct({
		productKey = entry.key,
		giftProductKey = giftProductKey,
		icon = cardIcon and cardIcon.Image or nil,
	})
end

function ShopController:_bindCard(card: ImageButton, entry)
	self._cards[entry] = card
	card.Active = true
	card.Selectable = true

	local label = findTextLabel(card, "Label")
	if label then
		label.Text = getDisplayName(entry)
	end
	self:_refreshCardPrice(card, entry)
	setBackSelected(card, false)

	track(self._frameConnections, card.Activated:Connect(function()
		self:_selectEntry(entry)
	end))
end

function ShopController:_bindCards(frame: GuiObject)
	table.clear(self._cards)

	local items = frame:FindFirstChild("Items")
	local scroller = items and items:FindFirstChild("ScrollingFrame")
	if not scroller then
		return
	end

	for _, child in ipairs(scroller:GetChildren()) do
		if child:IsA("ImageButton") then
			local entry = ShopCatalog.GetEntryByCardName(child.Name)
			if entry then
				self:_bindCard(child, entry)
			end
		end
	end
end

function ShopController:_bindFrame(frame: GuiObject?)
	disconnectAll(self._frameConnections)
	table.clear(self._cards)
	self._frame = frame
	self._selectedEntry = nil
	self._right = nil
	self._rightName = nil
	self._rightDescription = nil
	self._rightIcon = nil
	self._rightPrice = nil
	self._rightWarning = nil
	self._buyButton = nil
	self._buyLabel = nil
	self._giftButton = nil

	if not frame then
		return
	end

	self._right = frame:FindFirstChild("Right")
	self._rightName = findTextLabel(self._right, "AbilityName")
	self._rightDescription = findTextLabel(self._right, "Description")
	self._rightIcon = findImageLabel(self._right, "Icon")
	self._rightPrice = findTextLabel(self._right, PRICE_LABEL_NAME)
	self._rightWarning = findTextLabel(self._right, "Warning")
	self._buyButton = findGuiButton(self._right, "BuyButton")
	self._buyLabel = self._buyButton and findTextLabel(self._buyButton, "Label") or nil
	self._giftButton = findGuiButton(self._right, "GiftButton")

	self:_bindCards(frame)

	local closeButton = findGuiButton(frame, "CloseButton")
	track(self._frameConnections, closeButton and closeButton.Activated:Connect(function()
		FrameController:CloseFrame(FRAME_NAME)
	end))
	track(self._frameConnections, self._buyButton and self._buyButton.Activated:Connect(function()
		self:_promptSelectedEntry()
	end))
	track(self._frameConnections, self._giftButton and self._giftButton.Activated:Connect(function()
		self:_promptSelectedGift()
	end))

	local firstEntry = nil
	for _, entryKey in ipairs(ShopCatalog.Order) do
		local entry = ShopCatalog.GetEntry(entryKey)
		if entry and self._cards[entry] then
			firstEntry = entry
			break
		end
	end
	self:_selectEntry(firstEntry)
end

function ShopController:_bindCurrentFrame()
	local frames = PlayerGui:FindFirstChild(FRAMES_GUI_NAME)
	local frame = frames and frames:FindFirstChild(FRAME_NAME)
	self:_bindFrame(if frame and frame:IsA("GuiObject") then frame else nil)
end

function ShopController:_bindHudButton()
	if self._hudButtonConnection then
		self._hudButtonConnection:Disconnect()
		self._hudButtonConnection = nil
	end
	self._hudButton = nil

	local hud = PlayerGui:FindFirstChild(HUD_NAME)
	local sideButtons = hud and hud:FindFirstChild(SIDE_BUTTONS_NAME)
	local shopButton = sideButtons and sideButtons:FindFirstChild(FRAME_NAME)
	if shopButton and shopButton:IsA("GuiButton") then
		self._hudButton = shopButton
		shopButton.Active = true
		shopButton.Selectable = true
		self._hudButtonConnection = shopButton.Activated:Connect(function()
			if not self._frame then
				self:_bindCurrentFrame()
			end
			FrameController:ToggleFrame(FRAME_NAME)
		end)
	end
end

function ShopController:OnStart()
	if self._hudButtonConnection then
		self._hudButtonConnection:Disconnect()
		self._hudButtonConnection = nil
	end
	disconnectAll(self._connections)
	disconnectAll(self._frameConnections)
	table.clear(self._passOwned)

	self:_bindCurrentFrame()
	self:_bindHudButton()

	track(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == FRAMES_GUI_NAME then
			task.defer(function()
				self:_bindCurrentFrame()
			end)
		elseif child.Name == HUD_NAME then
			task.defer(function()
				self:_bindHudButton()
			end)
		end
	end))
	track(self._connections, PlayerGui.DescendantAdded:Connect(function(descendant)
		if descendant.Name == FRAME_NAME or descendant.Name == "BuyButton" or descendant.Name == "GiftButton" then
			task.defer(function()
				self:_bindCurrentFrame()
				self:_bindHudButton()
			end)
		end
	end))
	track(self._connections, LocalPlayer:GetAttributeChangedSignal("StarterPackOwned"):Connect(function()
		self:_renderSelectedEntry()
	end))
	track(self._connections, MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if player ~= LocalPlayer or not wasPurchased then
			return
		end
		for _, entry in pairs(ShopCatalog.Entries) do
			if entry.kind == ShopCatalog.Kinds.Pass and getOfferId(entry) == gamePassId then
				self._passOwned[entry.key] = true
				break
			end
		end
		self:_renderSelectedEntry()
	end))
end

return ShopController
