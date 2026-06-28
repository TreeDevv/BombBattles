local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BundleCatalog = require(ReplicatedStorage.Shared.Config.BundleCatalog)
local RobuxPurchases = require(ReplicatedStorage.Shared.Config.Lists.RobuxPurchases)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)

local BundlePreviewDirector = require(script.Parent.Bundles.BundlePreviewDirector)
local GameUiVisibilityController = require(script.Parent:WaitForChild("GameUiVisibilityController"))
local GiftMenuController = require(script.Parent:WaitForChild("GiftMenuController"))
local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = "Bundles"
local FRAMES_GUI_NAME = "Frames"
local TEMPLATE_ROLE_ATTRIBUTE = "BundleTemplateRole"
local RUNTIME_CLONE_ATTRIBUTE = "BundleRuntimeClone"
local TEMPLATE_PAGE_CARD = "PageCard"
local TEMPLATE_REWARD_CHIP = "RewardChip"
local OFFER_ROW_NAME = "Purchases"
local OVERLAY_SCOPE_ID = "BundlesOverlay"
local FRAME_SLIDE_OFFSET = 24
local FRAME_OPEN_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local FRAME_CLOSE_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local REWARD_HOVER_TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local REWARD_PRESS_TWEEN = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local REWARD_RELEASE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local REWARD_HOVER_LIFT = -4
local REWARD_PRESS_OFFSET = 2
local REWARD_HOVER_ICON_ROTATION = 2
local OPEN_BUNDLE_TAG = "OpenBundle"
local OPEN_BUNDLE_ATTRIBUTES = table.freeze({ "BundlePageId", "Bundle", "PageId" })
local BUNDLE_PAGE_ALIASES = table.freeze({
	fat = "FatPackPage",
	fatpack = "FatPackPage",
	fatpackpage = "FatPackPage",
	infinity = "InfinityBundlePage",
	infinitybundle = "InfinityBundlePage",
	infinitybundlepage = "InfinityBundlePage",
	gojo = "InfinityBundlePage",
})

local BundlesController = {}

BundlesController._frame = nil :: Frame?
BundlesController._director = BundlePreviewDirector.new()
BundlesController._connections = {} :: { RBXScriptConnection }
BundlesController._frameConnections = {} :: { RBXScriptConnection }
BundlesController._renderConnections = {} :: { RBXScriptConnection }
BundlesController._selectedPageId = nil :: string?
BundlesController._activePreviewId = nil :: string?
BundlesController._lastStagedPreviewId = nil :: string?
BundlesController._offerTemplate = nil :: Frame?
BundlesController._pageCardTemplate = nil :: ImageButton?
BundlesController._rewardChipTemplate = nil :: ImageButton?
BundlesController._pageCards = {} :: { [string]: ImageButton }
BundlesController._rewardChips = {} :: { [string]: { ImageButton } }
BundlesController._isOpen = false
BundlesController._overlayHidden = false
BundlesController._frameBasePosition = nil :: UDim2?
BundlesController._frameTween = nil :: Tween?
BundlesController._transitionSerial = 0
BundlesController._fullscreenPreviewActive = false
BundlesController._openBundleZones = {} :: { [Instance]: any }
BundlesController._warnedOpenBundleZoneIssues = {} :: { [Instance]: string }

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function getFramesGui(): ScreenGui?
	local frames = PlayerGui:FindFirstChild(FRAMES_GUI_NAME)
	return if frames and frames:IsA("ScreenGui") then frames else nil
end

local function findDescendant(root: Instance?, path: { string }): Instance?
	local current = root
	for _, name in ipairs(path) do
		current = current and current:FindFirstChild(name) or nil
		if not current then
			return nil
		end
	end
	return current
end

local function getZonePlus()
	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local module = packages and packages:FindFirstChild("ZonePlus")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end

	local ok, result = pcall(require, module)
	if ok then
		return result
	end

	warn("[BundlesController] ZonePlus failed to load: " .. tostring(result))
	return nil
end

local function normalizeBundleTarget(value: any): string?
	if typeof(value) ~= "string" then
		return nil
	end

	local normalized = string.lower(value):gsub("[^%w]", "")
	return if normalized ~= "" then normalized else nil
end

local function findFirstChildOfClass(root: Instance?, className: string): Instance?
	if not root then
		return nil
	end
	for _, child in ipairs(root:GetChildren()) do
		if child.ClassName == className then
			return child
		end
	end
	return nil
end

local function findTemplateByRole(root: Instance?, role: string, fallbackName: string): ImageButton?
	if not root then
		return nil
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ImageButton") and descendant:GetAttribute(TEMPLATE_ROLE_ATTRIBUTE) == role then
			return descendant
		end
	end

	if role == TEMPLATE_REWARD_CHIP then
		return nil
	end

	for _, child in ipairs(root:GetChildren()) do
		if child:IsA("ImageButton") and child.Name == fallbackName then
			return child
		end
	end

	local fallback = findFirstChildOfClass(root, "ImageButton")
	return if fallback and fallback:IsA("ImageButton") then fallback else nil
end

local function setLabel(root: Instance?, name: string, text: string)
	local label = root and root:FindFirstChild(name, true)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function setImage(root: Instance?, name: string, image: string?)
	local imageLabel = root and root:FindFirstChild(name, true)
	if imageLabel and imageLabel:IsA("ImageLabel") and typeof(image) == "string" then
		imageLabel.Image = image
	end
end

local function setSoldOutVisible(root: Instance?, visible: boolean)
	local soldOut = root and root:FindFirstChild("SoldOut", true)
	if soldOut and soldOut:IsA("GuiObject") then
		soldOut.Visible = visible
	end
end

local function formatPrice(product): string
	local price = product and tonumber(product.price) or 0
	if price and price > 0 then
		return tostring(math.floor(price))
	end
	return "OFFSALE"
end

local function formatCountdown(endsAt: number?): string
	local timestamp = tonumber(endsAt)
	if not timestamp or timestamp <= 0 then
		return ""
	end

	local remaining = math.max(0, timestamp - workspace:GetServerTimeNow())
	local days = math.floor(remaining / 86400)
	local hours = math.floor((remaining % 86400) / 3600)
	local minutes = math.floor((remaining % 3600) / 60)

	if days > 0 then
		return ("%dd %dh"):format(days, hours)
	elseif hours > 0 then
		return ("%dh %dm"):format(hours, minutes)
	end
	return ("%dm"):format(minutes)
end

local function setSelectedCover(card: ImageButton, selected: boolean)
	local cover = card:FindFirstChild("SelectedCover")
	if cover and cover:IsA("GuiObject") then
		cover.Visible = selected
	end
	card.ImageColor3 = if selected then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(177, 177, 177)
end

local function setChipActive(chip: ImageButton, active: boolean)
	local back = chip:FindFirstChild("Back")
	local stroke = back and back:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Enabled = true
		stroke.Thickness = if active then 4 else 1
	end
	chip.ImageTransparency = if active then 0 else 0.1
end

local function offsetPosition(position: UDim2, xOffset: number, yOffset: number): UDim2
	return UDim2.new(
		position.X.Scale,
		position.X.Offset + xOffset,
		position.Y.Scale,
		position.Y.Offset + yOffset
	)
end

local function brightenColor(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), math.clamp(amount, 0, 1))
end

local function preserveUiStrokeSizes(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("UIStroke") then
			pcall(function()
				descendant.StrokeSizingMode = Enum.StrokeSizingMode.FixedSize
			end)
		end
	end
end

function BundlesController:_bindRewardChipAnimation(chip: ImageButton)
	chip.AutoButtonColor = false
	chip.Selectable = true

	local back = chip:FindFirstChild("Back")
	local icon = chip:FindFirstChild("Icon")
	local itemName = chip:FindFirstChild("ItemName")
	local animatedObjects = {}
	for _, object in ipairs({ back, icon, itemName }) do
		if object and object:IsA("GuiObject") then
			table.insert(animatedObjects, object)
		end
	end

	local basePositions = {}
	local baseColors = {}
	local baseRotations = {}
	for _, object in ipairs(animatedObjects) do
		basePositions[object] = object.Position
		if object:IsA("ImageLabel") or object:IsA("ImageButton") then
			baseColors[object] = object.ImageColor3
		elseif object:IsA("TextLabel") or object:IsA("TextButton") then
			baseColors[object] = object.TextColor3
		end
		baseRotations[object] = object.Rotation
	end

	local activeTweens = {}
	local hovering = false
	local pressing = false

	local function cancelTweens()
		for _, tween in ipairs(activeTweens) do
			tween:Cancel()
		end
		table.clear(activeTweens)
	end

	local function tweenObject(object: GuiObject, tweenInfo: TweenInfo, goals)
		local tween = TweenService:Create(object, tweenInfo, goals)
		table.insert(activeTweens, tween)
		tween:Play()
	end

	local function applyState(tweenInfo: TweenInfo, state: string)
		cancelTweens()

		local yOffset = 0
		if state == "Hover" then
			yOffset = REWARD_HOVER_LIFT
		elseif state == "Pressed" then
			yOffset = REWARD_PRESS_OFFSET
		end

		for _, object in ipairs(animatedObjects) do
			local goals = {
				Position = offsetPosition(basePositions[object], 0, yOffset),
				Rotation = baseRotations[object],
			}

			if object == icon and state == "Hover" then
				goals.Rotation = baseRotations[object] + REWARD_HOVER_ICON_ROTATION
			end

			local baseColor = baseColors[object]
			if baseColor then
				local color = if state == "Hover" then brightenColor(baseColor, 0.18) else baseColor
				if object:IsA("ImageLabel") or object:IsA("ImageButton") then
					goals.ImageColor3 = color
				elseif object:IsA("TextLabel") or object:IsA("TextButton") then
					goals.TextColor3 = color
				end
			end

			tweenObject(object, tweenInfo, goals)
		end
	end

	table.insert(self._renderConnections, chip.MouseEnter:Connect(function()
		hovering = true
		if not pressing then
			applyState(REWARD_HOVER_TWEEN, "Hover")
		end
	end))

	table.insert(self._renderConnections, chip.MouseLeave:Connect(function()
		hovering = false
		pressing = false
		applyState(REWARD_HOVER_TWEEN, "Rest")
	end))

	table.insert(self._renderConnections, chip.MouseButton1Down:Connect(function()
		pressing = true
		applyState(REWARD_PRESS_TWEEN, "Pressed")
	end))

	table.insert(self._renderConnections, chip.MouseButton1Up:Connect(function()
		pressing = false
		applyState(REWARD_RELEASE_TWEEN, if hovering then "Hover" else "Rest")
	end))

	table.insert(self._renderConnections, chip.AncestryChanged:Connect(function()
		if not chip:IsDescendantOf(PlayerGui) then
			cancelTweens()
		end
	end))
end

function BundlesController:_disconnect()
	disconnectAll(self._connections)
	disconnectAll(self._frameConnections)
	disconnectAll(self._renderConnections)
end

function BundlesController:_registerFrame(frame: Frame)
	if CollectionService:HasTag(frame, "Frame") then
		CollectionService:RemoveTag(frame, "Frame")
	end
	frame:SetAttribute("Exclusive", nil)
end

function BundlesController:_clearRuntimeClones(root: Instance?)
	if not root then
		return
	end
	for _, child in ipairs(root:GetChildren()) do
		if child:GetAttribute(RUNTIME_CLONE_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
end

function BundlesController:_cancelFrameTween()
	if self._frameTween then
		self._frameTween:Cancel()
		self._frameTween = nil
	end
end

function BundlesController:_getFrameBasePosition(): UDim2
	local frame = self._frame
	if not frame then
		return UDim2.new()
	end

	if not self._frameBasePosition then
		self._frameBasePosition = frame.Position
	end
	return self._frameBasePosition
end

function BundlesController:_slidePosition(basePosition: UDim2): UDim2
	return UDim2.new(
		basePosition.X.Scale,
		basePosition.X.Offset,
		basePosition.Y.Scale,
		basePosition.Y.Offset + FRAME_SLIDE_OFFSET
	)
end

function BundlesController:_pushOverlayHidden()
	local frame = self._frame
	if self._overlayHidden or not frame then
		return
	end

	self._overlayHidden = true
	GameUiVisibilityController:PushHiddenScope(OVERLAY_SCOPE_ID, {
		Exclusions = { frame },
		IncludeTopbar = true,
		IncludeScreenEffects = true,
		HideByVisibility = true,
		IncludeFrameBackdrop = true,
	}, false)
end

function BundlesController:_popOverlayHidden(instant: boolean?)
	if not self._overlayHidden then
		return
	end

	self._overlayHidden = false
	GameUiVisibilityController:PopHiddenScope(OVERLAY_SCOPE_ID, instant)
end

function BundlesController:_showFrameAnimated()
	local frame = self._frame
	if not frame then
		return
	end

	self:_cancelFrameTween()
	self._transitionSerial += 1

	local basePosition = self:_getFrameBasePosition()
	frame.Position = self:_slidePosition(basePosition)
	frame.Visible = true

	local tween = TweenService:Create(frame, FRAME_OPEN_TWEEN, {
		Position = basePosition,
	})
	self._frameTween = tween
	tween:Play()
	tween.Completed:Once(function(playbackState)
		if playbackState ~= Enum.PlaybackState.Completed or self._frameTween ~= tween then
			return
		end
		self._frameTween = nil
		if frame.Parent then
			frame.Position = basePosition
		end
	end)
end

function BundlesController:_hideFrameAnimated()
	local frame = self._frame
	if not frame then
		self:_popOverlayHidden(false)
		return
	end

	self:_cancelFrameTween()
	self._transitionSerial += 1
	local serial = self._transitionSerial
	local basePosition = self:_getFrameBasePosition()

	if not frame.Visible then
		frame.Position = basePosition
		self:_popOverlayHidden(false)
		return
	end

	local tween = TweenService:Create(frame, FRAME_CLOSE_TWEEN, {
		Position = self:_slidePosition(basePosition),
	})
	self._frameTween = tween
	tween:Play()
	tween.Completed:Once(function()
		if self._transitionSerial ~= serial or self._frameTween ~= tween then
			return
		end

		self._frameTween = nil
		if frame.Parent then
			frame.Visible = false
			frame.Position = basePosition
		end
		self:_popOverlayHidden(false)
	end)
end

function BundlesController:_cacheTemplates()
	local frame = self._frame
	if not frame then
		return
	end

	local top = frame:FindFirstChild("Top")
	local bottom = frame:FindFirstChild("Bottom")
	local rewardList = findDescendant(frame, { "Top", "Purchases", "Rewards", "RewardList" })

	local offerTemplate = top and top:FindFirstChild(OFFER_ROW_NAME)
	self._offerTemplate = if offerTemplate and offerTemplate:IsA("Frame") then offerTemplate else nil
	self._pageCardTemplate = findTemplateByRole(bottom, TEMPLATE_PAGE_CARD, "Template")
	self._rewardChipTemplate = findTemplateByRole(rewardList, TEMPLATE_REWARD_CHIP, "DivineTemplate")

	if self._offerTemplate then
		self._offerTemplate.Visible = false
		self._offerTemplate:SetAttribute(RUNTIME_CLONE_ATTRIBUTE, false)
	end
	for _, template in ipairs({ self._pageCardTemplate, self._rewardChipTemplate }) do
		if template then
			template.Visible = false
			template.Active = false
			template:SetAttribute(RUNTIME_CLONE_ATTRIBUTE, false)
		end
	end
end

function BundlesController:_renderHeader(collection)
	local frame = self._frame
	if not frame then
		return
	end

	local headerBar = findDescendant(frame, { "Top", "HeaderBar" })
	if not headerBar then
		return
	end
	setLabel(headerBar, "Header", collection.DisplayName or "Bundles")
	setLabel(headerBar, "Stock", formatCountdown(collection.EndsAt))
end

function BundlesController:_renderPageCards(collection)
	local frame = self._frame
	if not (frame and self._pageCardTemplate) then
		return
	end

	local bottom = frame:FindFirstChild("Bottom")
	if not bottom then
		return
	end

	self:_clearRuntimeClones(bottom)
	self._pageCards = {}

	for order, pageId in ipairs(collection.PageIds or {}) do
		local page = BundleCatalog.GetPage(pageId)
		if not page then
			continue
		end

		local card = self._pageCardTemplate:Clone()
		card.Name = page.Id
		card:SetAttribute(RUNTIME_CLONE_ATTRIBUTE, true)
		card:SetAttribute("BundlePageId", page.Id)
		card.LayoutOrder = order
		card.Image = page.CardImage or card.Image
		card.Active = true
		card.Visible = true
		setLabel(card, "BundleName", page.CardTitle or page.Id)
		setLabel(card, "Timer", formatCountdown(collection.EndsAt))
		setSoldOutVisible(card, page.SoldOut == true)
		setSelectedCover(card, page.Id == self._selectedPageId)
		card.Parent = bottom
		self._pageCards[page.Id] = card

		table.insert(self._renderConnections, card.Activated:Connect(function()
			self:SelectPage(page.Id)
		end))
	end
end

function BundlesController:_renderRewardChip(parent: Instance, itemEntry, order: number)
	if not self._rewardChipTemplate then
		return
	end

	local item = BundleCatalog.GetItem(itemEntry.ItemId)
	if not item then
		return
	end
	local previewId = itemEntry.PreviewId or item.DefaultPreviewId

	local chip = self._rewardChipTemplate:Clone()
	chip.Name = item.Id
	chip:SetAttribute(RUNTIME_CLONE_ATTRIBUTE, true)
	chip:SetAttribute("BundleItemId", item.Id)
	chip:SetAttribute("BundlePreviewId", previewId)
	chip.LayoutOrder = order
	chip.Active = true
	chip.Visible = true
	setLabel(chip, "ItemName", item.DisplayName or item.Id)
	setImage(chip, "Icon", item.Icon)

	local count = chip:FindFirstChild("Count")
	if count and count:IsA("GuiObject") then
		count.Visible = false
	end

	setChipActive(chip, previewId == self._activePreviewId)
	chip.Parent = parent
	self._rewardChips[previewId] = self._rewardChips[previewId] or {}
	table.insert(self._rewardChips[previewId], chip)

	self:_bindRewardChipAnimation(chip)
	table.insert(self._renderConnections, chip.Activated:Connect(function()
		self:TryPreview(previewId)
	end))
end

function BundlesController:_renderOfferRow(top: Instance, offer, order: number)
	local template = self._offerTemplate
	if not template then
		return
	end

	local row = template:Clone()
	row.Name = offer.Id
	row:SetAttribute(RUNTIME_CLONE_ATTRIBUTE, true)
	row:SetAttribute("BundleOfferId", offer.Id)
	row.LayoutOrder = order
	row.Position = template.Position
		+ UDim2.fromScale((template.Size.X.Scale + 0.02) * math.max(order - 1, 0), 0)
	row.Active = true
	row.Visible = true
	row.Parent = top

	local rewardList = findDescendant(row, { "Rewards", "RewardList" })
	if rewardList then
		self:_clearRuntimeClones(rewardList)
		for order, itemEntry in ipairs(offer.Contents or {}) do
			self:_renderRewardChip(rewardList, itemEntry, order)
		end
	end

	local product = RobuxPurchases.Products[offer.ProductKey]
	local buyButton = findDescendant(row, { "BuyBundle" })
	if buyButton and buyButton:IsA("ImageButton") then
		buyButton:SetAttribute("BundleOfferId", offer.Id)
		buyButton.Active = true
		setLabel(buyButton, "Cost", formatPrice(product))
		setLabel(buyButton, "Buy", "BUY")
		table.insert(self._renderConnections, buyButton.Activated:Connect(function()
			self:_promptOffer(offer.Id)
		end))
	end

	local giftButton = buyButton and buyButton:FindFirstChild("GiftButton")
	if giftButton and giftButton:IsA("ImageButton") then
		giftButton:SetAttribute("BundleOfferId", offer.Id)
		giftButton.Active = offer.Giftable == true
		giftButton.Visible = offer.Giftable == true
		table.insert(self._renderConnections, giftButton.Activated:Connect(function()
			local product = RobuxPurchases.Products[offer.ProductKey]
			local giftProductKey = product and product.giftProductKey
			if typeof(giftProductKey) ~= "string" or giftProductKey == "" then
				giftProductKey = RobuxPurchases.GiftProductsByTargetKey and RobuxPurchases.GiftProductsByTargetKey[offer.ProductKey] or nil
			end
			if typeof(giftProductKey) ~= "string" or giftProductKey == "" then
				warn(("[BundlesController] Gift product missing for %s."):format(tostring(offer.ProductKey)))
				return
			end

			local page = self._selectedPageId and BundleCatalog.GetPage(self._selectedPageId) or nil
			GiftMenuController:OpenForProduct({
				productKey = offer.ProductKey,
				giftProductKey = giftProductKey,
				icon = page and page.CardImage or nil,
			})
		end))
	end
end

function BundlesController:_renderOffers(page)
	local frame = self._frame
	if not frame then
		return
	end

	local top = frame:FindFirstChild("Top")
	if not top then
		return
	end

	self:_clearRuntimeClones(top)
	self._rewardChips = {}

	for order, offerId in ipairs(page.OfferIds or {}) do
		local offer = BundleCatalog.GetOffer(offerId)
		if offer then
			self:_renderOfferRow(top, offer, order)
		end
	end
end

function BundlesController:_refreshSelectionVisuals()
	for pageId, card in pairs(self._pageCards) do
		setSelectedCover(card, pageId == self._selectedPageId)
	end

	for previewId, chips in pairs(self._rewardChips) do
		for _, chip in ipairs(chips) do
			setChipActive(chip, previewId == self._activePreviewId)
		end
	end
end

function BundlesController:_warnOpenBundleZone(instance: Instance, message: string)
	if self._warnedOpenBundleZoneIssues[instance] == message then
		return
	end

	self._warnedOpenBundleZoneIssues[instance] = message
	warn(("[BundlesController] %s (%s)"):format(message, instance:GetFullName()))
end

function BundlesController:_resolveBundlePageId(target: any): string?
	if typeof(target) ~= "string" or target == "" then
		return nil
	end

	if BundleCatalog.GetPage(target) then
		return target
	end

	local normalizedTarget = normalizeBundleTarget(target)
	if not normalizedTarget then
		return nil
	end

	local aliasPageId = BUNDLE_PAGE_ALIASES[normalizedTarget]
	if aliasPageId and BundleCatalog.GetPage(aliasPageId) then
		return aliasPageId
	end

	for pageId, page in pairs(BundleCatalog.Pages) do
		if normalizeBundleTarget(pageId) == normalizedTarget then
			return pageId
		end
		if typeof(page) == "table" and normalizeBundleTarget(page.CardTitle) == normalizedTarget then
			return pageId
		end
	end

	return nil
end

function BundlesController:_getOpenBundleZoneTarget(instance: Instance): string?
	for _, attributeName in ipairs(OPEN_BUNDLE_ATTRIBUTES) do
		local pageId = self:_resolveBundlePageId(instance:GetAttribute(attributeName))
		if pageId then
			return pageId
		end
	end

	return nil
end

function BundlesController:_isStagedPreview(previewId: string?): boolean
	if typeof(previewId) ~= "string" or previewId == "" then
		return false
	end

	local recipe = BundleCatalog.GetPreviewRecipe(previewId)
	return recipe ~= nil and recipe.Presenter ~= "HighlightIntroPresenter"
end

function BundlesController:_getReturnStagedPreviewId(): string?
	if self:_isStagedPreview(self._lastStagedPreviewId) then
		return self._lastStagedPreviewId
	end

	local page = BundleCatalog.GetPage(self._selectedPageId)
	if page and self:_isStagedPreview(page.DefaultPreviewId) then
		return page.DefaultPreviewId
	end

	local collection = BundleCatalog.GetDefaultCollection()
	page = collection and BundleCatalog.GetPage(collection.DefaultPageId) or nil
	if page and self:_isStagedPreview(page.DefaultPreviewId) then
		return page.DefaultPreviewId
	end

	return nil
end

function BundlesController:_openFromBundleZone(instance: Instance)
	local pageId = self:_getOpenBundleZoneTarget(instance)
	if not pageId then
		self:_warnOpenBundleZone(instance, "OpenBundle zone is missing a valid BundlePageId, Bundle, or PageId attribute")
		return
	end

	self:Open(pageId)
end

function BundlesController:_disconnectOpenBundleZone(instance: Instance)
	local record = self._openBundleZones[instance]
	if not record then
		return
	end

	self._openBundleZones[instance] = nil
	self._warnedOpenBundleZoneIssues[instance] = nil
	if record.enteredConnection then
		record.enteredConnection:Disconnect()
	end
	if record.zone then
		pcall(function()
			if type(record.zone.destroy) == "function" then
				record.zone:destroy()
			elseif type(record.zone.Destroy) == "function" then
				record.zone:Destroy()
			end
		end)
	end
end

function BundlesController:_bindOpenBundleZone(instance: Instance)
	if self._openBundleZones[instance] then
		return
	end
	if not instance:IsA("BasePart") then
		self:_warnOpenBundleZone(instance, "OpenBundle tag must be placed on a BasePart")
		return
	end

	local zonePlus = getZonePlus()
	if not zonePlus then
		self:_warnOpenBundleZone(instance, "ZonePlus is unavailable for OpenBundle zone")
		return
	end

	local ok, zone = pcall(function()
		return zonePlus.new(instance)
	end)
	if not ok or not zone then
		self:_warnOpenBundleZone(instance, "ZonePlus failed to start for OpenBundle zone: " .. tostring(zone))
		return
	end

	local enteredConnection = zone.localPlayerEntered:Connect(function()
		self:_openFromBundleZone(instance)
	end)

	self._openBundleZones[instance] = {
		zone = zone,
		enteredConnection = enteredConnection,
	}

	task.defer(function()
		if self._openBundleZones[instance] and zone:findLocalPlayer() then
			self:_openFromBundleZone(instance)
		end
	end)
end

function BundlesController:_startOpenBundleZones()
	for _, instance in ipairs(CollectionService:GetTagged(OPEN_BUNDLE_TAG)) do
		self:_bindOpenBundleZone(instance)
	end

	table.insert(self._connections, CollectionService:GetInstanceAddedSignal(OPEN_BUNDLE_TAG):Connect(function(instance)
		self:_bindOpenBundleZone(instance)
	end))
	table.insert(self._connections, CollectionService:GetInstanceRemovedSignal(OPEN_BUNDLE_TAG):Connect(function(instance)
		self:_disconnectOpenBundleZone(instance)
	end))
end

function BundlesController:TryPreview(previewId: string?)
	if typeof(previewId) ~= "string" or previewId == "" then
		return
	end
	local recipe = BundleCatalog.GetPreviewRecipe(previewId)
	if not recipe then
		warn(("[BundlesController] Unknown preview id %s"):format(previewId))
		return
	end

	self._activePreviewId = previewId
	self:_refreshSelectionVisuals()

	if recipe.Presenter == "HighlightIntroPresenter" then
		local frame = self._frame
		if not frame then
			return
		end

		self._fullscreenPreviewActive = true
		self:_cancelFrameTween()
		frame.Visible = false
		self._director:Play(previewId, function()
			self._fullscreenPreviewActive = false
			if self._isOpen and self._frame then
				self:_pushOverlayHidden()
				self._frame.Visible = true
				self._frame.Position = self:_getFrameBasePosition()
				local returnPreviewId = self:_getReturnStagedPreviewId()
				if returnPreviewId then
					self._activePreviewId = returnPreviewId
					self._lastStagedPreviewId = returnPreviewId
					self:_refreshSelectionVisuals()
					self._director:Play(returnPreviewId, nil, {
						InstantCamera = true,
					})
				end
			end
		end, {
			RevealAfterPreviewCallback = true,
		})
		return
	end

	self._lastStagedPreviewId = previewId
	self._director:Play(previewId)
end

function BundlesController:SelectPage(pageId: string?)
	local collection = BundleCatalog.GetDefaultCollection()
	if not collection then
		return
	end

	local page = BundleCatalog.GetPage(pageId or collection.DefaultPageId)
	if not page then
		return
	end

	self._selectedPageId = page.Id
	self._activePreviewId = page.DefaultPreviewId
	if self:_isStagedPreview(page.DefaultPreviewId) then
		self._lastStagedPreviewId = page.DefaultPreviewId
	else
		self._lastStagedPreviewId = nil
	end
	disconnectAll(self._renderConnections)
	self:_renderHeader(collection)
	self:_renderPageCards(collection)
	self:_renderOffers(page)
	self:_refreshSelectionVisuals()
	self._director:Play(page.DefaultPreviewId)
end

function BundlesController:_getOpenPageId(target: string?): string?
	if typeof(target) == "string" and target ~= "" then
		local pageId = self:_resolveBundlePageId(target)
		if pageId then
			return pageId
		end

		warn(("[BundlesController] Unknown bundle page target %s; opening default bundle page"):format(target))
	end

	local collection = BundleCatalog.GetDefaultCollection()
	return collection and collection.DefaultPageId or nil
end

function BundlesController:_promptOffer(offerId: string?)
	local offer = BundleCatalog.GetOffer(offerId)
	if not offer then
		warn(("[BundlesController] Unknown offer id %s"):format(tostring(offerId)))
		return
	end

	local product = RobuxPurchases.Products[offer.ProductKey]
	local productId = product and tonumber(product.id) or 0
	if not productId or productId <= 0 then
		warn(("[BundlesController] Product %s is disabled; purchase prompt skipped."):format(tostring(offer.ProductKey)))
		return
	end

	MarketplaceService:PromptProductPurchase(LocalPlayer, productId)
end

function BundlesController:_bindButtons()
	local frame = self._frame
	if not frame then
		return
	end

	local closeButton = frame:FindFirstChild("CloseButton")
	if closeButton and closeButton:IsA("GuiButton") then
		table.insert(self._frameConnections, closeButton.Activated:Connect(function()
			self:Close()
		end))
	end

	local buyButton = findDescendant(frame, { "Top", "Purchases", "BuyBundle" })
	if buyButton and buyButton:IsA("ImageButton") then
		buyButton.Active = false
	end

	local giftButton = buyButton and buyButton:FindFirstChild("GiftButton")
	if giftButton and giftButton:IsA("ImageButton") then
		giftButton.Active = false
	end
end

function BundlesController:_closeForRoundState(state: string?)
	if self._isOpen and (state == RoundStates.AssigningTeams or state == RoundStates.RoundStarting or state == RoundStates.Active) then
		self:Close()
	end
end

function BundlesController:_bindFrame(frame: Frame)
	disconnectAll(self._frameConnections)
	disconnectAll(self._renderConnections)
	self._frame = frame
	self:_registerFrame(frame)
	preserveUiStrokeSizes(frame)
	self:_cacheTemplates()
	self:_bindButtons()

	table.insert(self._frameConnections, frame:GetPropertyChangedSignal("Visible"):Connect(function()
		if not frame.Visible then
			if self._fullscreenPreviewActive then
				return
			end
			self._isOpen = false
			self._director:Stop()
			self:_popOverlayHidden(false)
		end
	end))

	self._isOpen = false
	self._overlayHidden = false
	self._fullscreenPreviewActive = false
	self._frameBasePosition = frame.Position
	frame.Visible = false
	self._director:Stop()
end

function BundlesController:_bindCurrentFrame()
	local frames = getFramesGui()
	local frame = frames and frames:FindFirstChild(FRAME_NAME)
	if frame and frame:IsA("Frame") then
		self:_bindFrame(frame)
	end
end

function BundlesController:Open(target: string?)
	if not self._frame then
		self:_bindCurrentFrame()
	end

	local frame = self._frame
	if not frame then
		warn("[BundlesController] Missing PlayerGui.Frames.Bundles")
		return
	end

	self._isOpen = true
	self:_pushOverlayHidden()
	self:SelectPage(self:_getOpenPageId(target))
	self:_showFrameAnimated()
end

function BundlesController:Close()
	if not self._isOpen and not (self._frame and self._frame.Visible) then
		self:_popOverlayHidden(false)
		return
	end

	local frame = self._frame
	self._fullscreenPreviewActive = false
	self._isOpen = false
	if frame then
		self:_hideFrameAnimated()
	else
		self:_popOverlayHidden(false)
	end
	self._director:Stop(true)
end

function BundlesController:OnStart()
	self:_bindCurrentFrame()
	self:_startOpenBundleZones()

	table.insert(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name ~= FRAMES_GUI_NAME then
			return
		end
		task.defer(function()
			self:_bindCurrentFrame()
		end)
	end))

	table.insert(self._connections, RoundController.StateReceived:Connect(function(state)
		self:_closeForRoundState(state and state.state)
	end))
	table.insert(self._connections, RoundController.StateUpdated:Connect(function(key, value)
		if key == "state" then
			self:_closeForRoundState(value)
		end
	end))
end

return BundlesController
