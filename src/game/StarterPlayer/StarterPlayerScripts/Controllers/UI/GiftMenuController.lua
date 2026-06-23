local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local RobuxPurchases = require(ReplicatedStorage.Shared.Config.Lists.RobuxPurchases)

local GameUiVisibilityController = require(script.Parent:WaitForChild("GameUiVisibilityController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = "GiftMenu"
local FRAMES_GUI_NAME = "Frames"
local REMOTES_FOLDER_NAME = "Remotes"
local PREPARE_GIFT_PURCHASE_REMOTE_NAME = "PrepareGiftPurchase"
local GIFT_PURCHASE_RESULT_REMOTE_NAME = "GiftPurchaseResult"
local RUNTIME_ROW_ATTRIBUTE = "GiftMenuRuntimeRow"
local OVERLAY_SCOPE_ID = "GiftMenuOverlay"
local DEFAULT_TAB = "Server"
local MAX_ONLINE_FRIENDS = 200
local OVERLAY_DISPLAY_ORDER = 1000

type RecipientRecord = {
	userId: number,
	username: string,
	displayName: string,
	isOnline: boolean,
	inServer: boolean,
}

local GiftMenuController = {}

GiftMenuController._connections = {} :: { RBXScriptConnection }
GiftMenuController._frameConnections = {} :: { RBXScriptConnection }
GiftMenuController._rowConnections = {} :: { RBXScriptConnection }
GiftMenuController._frame = nil :: GuiObject?
GiftMenuController._playersMenu = nil :: Instance?
GiftMenuController._scroller = nil :: ScrollingFrame?
GiftMenuController._template = nil :: GuiObject?
GiftMenuController._searchBox = nil :: TextBox?
GiftMenuController._serverTab = nil :: GuiButton?
GiftMenuController._friendsTab = nil :: GuiButton?
GiftMenuController._claimButton = nil :: GuiButton?
GiftMenuController._claimLabel = nil :: TextLabel?
GiftMenuController._recipientButton = nil :: GuiObject?
GiftMenuController._recipientUsername = nil :: TextLabel?
GiftMenuController._recipientIcon = nil :: ImageLabel?
GiftMenuController._productNameLabel = nil :: TextLabel?
GiftMenuController._priceLabel = nil :: TextLabel?
GiftMenuController._icon = nil :: ImageLabel?
GiftMenuController._prepareRemote = nil :: RemoteFunction?
GiftMenuController._resultRemote = nil :: RemoteEvent?
GiftMenuController._activeTab = DEFAULT_TAB
GiftMenuController._serverRecipients = {} :: { RecipientRecord }
GiftMenuController._friendRecipients = {} :: { RecipientRecord }
GiftMenuController._selectedRecipient = nil :: RecipientRecord?
GiftMenuController._currentProduct = nil
GiftMenuController._busy = false
GiftMenuController._pendingPromptProductId = 0
GiftMenuController._warnedMissingFrame = false
GiftMenuController._rebindQueued = false
GiftMenuController._zIndexOriginals = nil :: { [GuiObject]: number }?
GiftMenuController._screenGui = nil :: ScreenGui?
GiftMenuController._screenGuiOriginalDisplayOrder = nil :: number?
GiftMenuController._hiddenScopePushed = false
GiftMenuController._priceSerial = 0

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

local function normalizeUserId(value: any): number
	local userId = math.floor(tonumber(value) or 0)
	return if userId > 0 then userId else 0
end

local function getUsername(value: any, fallbackUserId: number): string
	if typeof(value) == "string" and value ~= "" then
		return value
	end
	return "User" .. tostring(fallbackUserId)
end

local function getDisplayName(value: any, username: string): string
	if typeof(value) == "string" and value ~= "" then
		return value
	end
	return username
end

local function getSortName(recipient: RecipientRecord): string
	return string.lower(tostring(recipient.username or recipient.displayName or recipient.userId or ""))
end

local function sortRecipients(recipients: { RecipientRecord })
	table.sort(recipients, function(left, right)
		if left.inServer ~= right.inServer then
			return left.inServer
		end
		if left.isOnline ~= right.isOnline then
			return left.isOnline
		end

		local leftName = getSortName(left)
		local rightName = getSortName(right)
		if leftName == rightName then
			return left.userId < right.userId
		end
		return leftName < rightName
	end)
end

local function avatarThumbnail(userId: number): string
	return ("rbxthumb://type=AvatarHeadShot&id=%d&w=420&h=420"):format(userId)
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

local function waitForRemoteFunction(remoteName: string): RemoteFunction?
	local folder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	if not folder then
		return nil
	end

	local remote = folder:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteFunction") then remote else nil
end

local function waitForRemoteEvent(remoteName: string): RemoteEvent?
	local folder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
	if not folder then
		return nil
	end

	local remote = folder:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getOnlineFriendUserId(value: any): number
	if typeof(value) ~= "table" then
		return 0
	end

	local userId = normalizeUserId(value.VisitorId)
	if userId <= 0 then
		userId = normalizeUserId(value.UserId)
	end
	if userId <= 0 then
		userId = normalizeUserId(value.Id)
	end
	return userId
end

local function iterFriendPages(pages)
	return coroutine.wrap(function()
		while true do
			for _, item in ipairs(pages:GetCurrentPage()) do
				coroutine.yield(item)
			end
			if pages.IsFinished then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
	end)
end

local function loadOnlineFriends(): ({ [number]: boolean }, { [number]: RecipientRecord })
	local onlineFriendIds = {}
	local onlineFriendsById = {}
	local ok, onlineFriends = pcall(function()
		return LocalPlayer:GetFriendsOnlineAsync(MAX_ONLINE_FRIENDS)
	end)
	if not ok or typeof(onlineFriends) ~= "table" then
		if not ok then
			warn("[GiftMenuController] Failed to load online friends: " .. tostring(onlineFriends))
		end
		return onlineFriendIds, onlineFriendsById
	end

	for _, onlineFriend in ipairs(onlineFriends) do
		if typeof(onlineFriend) == "table" and onlineFriend.IsOnline ~= false then
			local userId = getOnlineFriendUserId(onlineFriend)
			if userId > 0 then
				local username = getUsername(onlineFriend.UserName, userId)
				onlineFriendIds[userId] = true
				onlineFriendsById[userId] = {
					userId = userId,
					username = username,
					displayName = getDisplayName(onlineFriend.DisplayName, username),
					isOnline = true,
					inServer = Players:GetPlayerByUserId(userId) ~= nil,
				}
			end
		end
	end

	return onlineFriendIds, onlineFriendsById
end

local function getPromptProductArgs(a, b, c): (number, number, boolean)
	if typeof(a) == "Instance" and a:IsA("Player") then
		return a.UserId, tonumber(b) or 0, c == true
	end
	if typeof(a) == "number" and typeof(b) == "number" then
		return a, b, c == true
	end
	return LocalPlayer.UserId, tonumber(a) or 0, b == true or c == true
end

local function setButtonEnabled(button: GuiButton?, enabled: boolean)
	if not button then
		return
	end
	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
	if button:IsA("ImageButton") then
		button.ImageTransparency = if enabled then 0 else 0.35
	end
end

local function getGiftProductKey(targetKey: string): string?
	local direct = RobuxPurchases.GiftProductsByTargetKey and RobuxPurchases.GiftProductsByTargetKey[targetKey]
	if typeof(direct) == "string" and direct ~= "" then
		return direct
	end

	for productKey, product in pairs(RobuxPurchases.Products) do
		if product.giftTargetKey == targetKey then
			return productKey
		end
	end

	return nil
end

local function productDisplayName(productKey: string?): string
	local product = productKey and RobuxPurchases.Products[productKey] or nil
	return tostring((product and (product.displayName or product.name)) or productKey or "Gift")
end

local function productFallbackPrice(productKey: string?): string
	local product = productKey and RobuxPurchases.Products[productKey] or nil
	local price = product and tonumber(product.price) or 0
	return if price and price > 0 then tostring(math.floor(price)) else "OFFSALE"
end

function GiftMenuController:_clearRows()
	disconnectAll(self._rowConnections)
	local scroller = self._scroller
	if not scroller then
		return
	end

	for _, child in ipairs(scroller:GetChildren()) do
		if child:GetAttribute(RUNTIME_ROW_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
end

function GiftMenuController:_getCurrentRecipients(): { RecipientRecord }
	return if self._activeTab == "Friends" then self._friendRecipients else self._serverRecipients
end

function GiftMenuController:_recipientMatchesSearch(recipient: RecipientRecord): boolean
	local query = self._searchBox and string.lower(self._searchBox.Text) or ""
	if query == "" then
		return true
	end

	return string.find(string.lower(recipient.username), query, 1, true) ~= nil
		or string.find(string.lower(recipient.displayName), query, 1, true) ~= nil
end

function GiftMenuController:_setSelectedRecipient(recipient: RecipientRecord?)
	self._selectedRecipient = recipient

	if self._recipientUsername then
		self._recipientUsername.Text = if recipient then "@" .. recipient.username else "@Username"
	end
	if self._recipientIcon then
		self._recipientIcon.Image = if recipient then avatarThumbnail(recipient.userId) else self._recipientIcon.Image
	end

	self:_updateClaimButton()
	self:_renderRows()
end

function GiftMenuController:_buildRow(recipient: RecipientRecord, layoutOrder: number)
	local scroller = self._scroller
	local template = self._template
	if not (scroller and template) then
		return
	end

	local row = template:Clone()
	row.Name = "Recipient_" .. tostring(recipient.userId)
	row.LayoutOrder = layoutOrder
	row.Visible = true
	row:SetAttribute(RUNTIME_ROW_ATTRIBUTE, true)
	row.Parent = scroller

	local usernameLabel = findTextLabel(row, "Username")
	if usernameLabel then
		usernameLabel.Text = "@" .. recipient.username
	end

	local icon = findImageLabel(row, "Icon")
	if icon then
		icon.Image = avatarThumbnail(recipient.userId)
	end

	if row:IsA("GuiButton") then
		row.Active = true
		row.Selectable = true
		track(self._rowConnections, row.Activated:Connect(function()
			self:_setSelectedRecipient(recipient)
		end))
	end
end

function GiftMenuController:_renderRows()
	self:_clearRows()

	local template = self._template
	if template then
		template.Visible = false
	end
	if self._scroller then
		self._scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	end

	local layoutOrder = 0
	for _, recipient in ipairs(self:_getCurrentRecipients()) do
		if recipient.userId ~= LocalPlayer.UserId and self:_recipientMatchesSearch(recipient) then
			layoutOrder += 1
			self:_buildRow(recipient, layoutOrder)
		end
	end
end

function GiftMenuController:_setTabVisuals()
	local selected = self._activeTab
	for tabName, button in pairs({
		Server = self._serverTab,
		Friends = self._friendsTab,
	}) do
		if button then
			local isSelected = tabName == selected
			local selectedStroke = button:FindFirstChild("SelectedStroke", true)
			if selectedStroke and selectedStroke:IsA("UIStroke") then
				selectedStroke.Enabled = isSelected
			end

			button.ImageTransparency = if isSelected then 0 else 0.15
		end
	end
end

function GiftMenuController:_setActiveTab(tabName: string)
	if tabName ~= "Server" and tabName ~= "Friends" then
		return
	end

	self._activeTab = tabName
	self:_setTabVisuals()
	self:_renderRows()
end

function GiftMenuController:_loadServerRecipients()
	local recipients = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			table.insert(recipients, {
				userId = player.UserId,
				username = player.Name,
				displayName = player.DisplayName ~= "" and player.DisplayName or player.Name,
				isOnline = true,
				inServer = true,
			})
		end
	end
	sortRecipients(recipients)
	self._serverRecipients = recipients
end

function GiftMenuController:_loadFriendRecipients()
	task.spawn(function()
		local onlineFriendIds = {}
		local onlineFriendsById = {}
		local onlineDone = false
		local friendsDone = false
		local pagesOk = false
		local pages = nil
		local loaded = Instance.new("BindableEvent")

		task.spawn(function()
			onlineFriendIds, onlineFriendsById = loadOnlineFriends()
			onlineDone = true
			loaded:Fire()
		end)
		task.spawn(function()
			pagesOk, pages = pcall(function()
				return Players:GetFriendsAsync(LocalPlayer.UserId)
			end)
			friendsDone = true
			loaded:Fire()
		end)

		while not (onlineDone and friendsDone) do
			loaded.Event:Wait()
		end
		loaded:Destroy()

		local recipients = {}
		local seen = {}
		if pagesOk then
			for item in iterFriendPages(pages) do
				local userId = normalizeUserId(item.Id)
				if userId > 0 and not seen[userId] then
					seen[userId] = true
					local username = getUsername(item.Username, userId)
					table.insert(recipients, {
						userId = userId,
						username = username,
						displayName = getDisplayName(item.DisplayName, username),
						isOnline = onlineFriendIds[userId] == true,
						inServer = Players:GetPlayerByUserId(userId) ~= nil,
					})
				end
			end
		else
			warn("[GiftMenuController] Failed to load friends: " .. tostring(pages))
		end

		for userId, recipient in pairs(onlineFriendsById) do
			if not seen[userId] then
				seen[userId] = true
				table.insert(recipients, recipient)
			end
		end

		sortRecipients(recipients)
		self._friendRecipients = recipients
		if self._activeTab == "Friends" then
			self:_renderRows()
		end
	end)
end

function GiftMenuController:_updateClaimButton()
	local enabled = self._selectedRecipient ~= nil and self._currentProduct ~= nil and not self._busy
	setButtonEnabled(self._claimButton, enabled)
	if self._claimLabel then
		self._claimLabel.Text = if self._busy then "..." else "Gift"
	end
end

function GiftMenuController:_setBusy(busy: boolean)
	self._busy = busy
	self:_updateClaimButton()
end

function GiftMenuController:_setProductTexts(productKey: string, giftProductKey: string)
	if self._productNameLabel then
		self._productNameLabel.Text = productDisplayName(productKey)
	end
	if self._priceLabel then
		self._priceLabel.Text = productFallbackPrice(giftProductKey)
	end
end

function GiftMenuController:_refreshLivePrice(giftProductKey: string)
	local product = RobuxPurchases.Products[giftProductKey]
	local productId = product and tonumber(product.id) or 0
	if productId <= 0 then
		return
	end

	self._priceSerial += 1
	local serial = self._priceSerial
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
		end)
		if not ok or serial ~= self._priceSerial then
			return
		end

		local price = typeof(info) == "table" and tonumber(info.PriceInRobux) or nil
		if price and price > 0 and self._priceLabel then
			self._priceLabel.Text = tostring(math.floor(price))
		end
	end)
end

function GiftMenuController:_restoreZIndex()
	if not self._zIndexOriginals then
		return
	end

	for object, zIndex in pairs(self._zIndexOriginals) do
		if object.Parent then
			object.ZIndex = zIndex
		end
	end
	self._zIndexOriginals = nil
end

function GiftMenuController:_restoreScreenGuiDisplayOrder()
	local screenGui = self._screenGui
	local originalDisplayOrder = self._screenGuiOriginalDisplayOrder
	if screenGui and screenGui.Parent and originalDisplayOrder ~= nil then
		screenGui.DisplayOrder = originalDisplayOrder
	end

	self._screenGuiOriginalDisplayOrder = nil
end

function GiftMenuController:_pushOverlayHiddenScope()
	local frame = self._frame
	if not frame then
		return
	end

	self._hiddenScopePushed = true
	GameUiVisibilityController:PushHiddenScope(OVERLAY_SCOPE_ID, {
		Exclusions = { frame },
		IncludeTopbar = true,
		IncludeScreenEffects = true,
		HideByVisibility = true,
		IncludeFrameBackdrop = true,
	}, false)
end

function GiftMenuController:_popOverlayHiddenScope(instant: boolean?)
	if not self._hiddenScopePushed then
		return
	end

	self._hiddenScopePushed = false
	GameUiVisibilityController:PopHiddenScope(OVERLAY_SCOPE_ID, instant)
end

function GiftMenuController:_restoreLayering(instant: boolean?)
	self:_restoreZIndex()
	self:_restoreScreenGuiDisplayOrder()
	self:_popOverlayHiddenScope(instant)
end

function GiftMenuController:_promoteScreenGui()
	local frame = self._frame
	local screenGui = frame and frame:FindFirstAncestorWhichIsA("ScreenGui") or nil
	if not screenGui then
		return
	end

	self._screenGui = screenGui
	if self._screenGuiOriginalDisplayOrder == nil then
		self._screenGuiOriginalDisplayOrder = screenGui.DisplayOrder
	end

	local highest = OVERLAY_DISPLAY_ORDER
	for _, child in ipairs(PlayerGui:GetChildren()) do
		if child:IsA("ScreenGui") and child ~= screenGui and child.Enabled then
			highest = math.max(highest, child.DisplayOrder + 1)
		end
	end

	screenGui.DisplayOrder = highest
end

function GiftMenuController:_promoteAboveOpenFrames()
	self:_restoreZIndex()

	local frame = self._frame
	if not frame then
		return
	end

	self:_promoteScreenGui()

	local framesGui = frame.Parent
	local highest = 0
	if framesGui then
		for _, descendant in ipairs(framesGui:GetDescendants()) do
			if descendant:IsA("GuiObject") and not descendant:IsDescendantOf(frame) then
				highest = math.max(highest, descendant.ZIndex)
			end
		end
	end

	local originals = {}
	local delta = highest + 10
	if frame:IsA("GuiObject") then
		originals[frame] = frame.ZIndex
		frame.ZIndex = frame.ZIndex + delta
	end
	for _, descendant in ipairs(frame:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			originals[descendant] = descendant.ZIndex
			descendant.ZIndex = descendant.ZIndex + delta
		end
	end

	self._zIndexOriginals = originals
end

function GiftMenuController:_close()
	local frame = self._frame
	if frame then
		frame.Visible = false
	end
	self:_restoreLayering(false)
	self._pendingPromptProductId = 0
	self:_setBusy(false)
end

function GiftMenuController:_ensureRemotes()
	if not self._prepareRemote then
		self._prepareRemote = waitForRemoteFunction(PREPARE_GIFT_PURCHASE_REMOTE_NAME)
	end
	if not self._resultRemote then
		self._resultRemote = waitForRemoteEvent(GIFT_PURCHASE_RESULT_REMOTE_NAME)
		if self._resultRemote then
			track(self._connections, self._resultRemote.OnClientEvent:Connect(function(payload)
				self:_handleGiftResult(payload)
			end))
		end
	end
end

function GiftMenuController:_invokePrepare()
	self:_ensureRemotes()

	local remote = self._prepareRemote
	if not remote then
		return nil
	end

	local product = self._currentProduct
	local recipient = self._selectedRecipient
	if not (product and recipient) then
		return nil
	end

	local ok, response = pcall(function()
		return remote:InvokeServer({
			targetProductKey = product.productKey,
			giftProductKey = product.giftProductKey,
			recipientUserId = recipient.userId,
		})
	end)
	if not ok then
		warn("[GiftMenuController] Prepare gift request failed: " .. tostring(response))
		return {
			ok = false,
			message = "Gift is unavailable right now.",
		}
	end

	return response
end

function GiftMenuController:_promptGiftPurchase()
	if self._busy then
		return
	end

	local recipient = self._selectedRecipient
	local product = self._currentProduct
	if not (recipient and product) then
		Notify.Show("Choose someone to gift first.", { color = "Red" })
		return
	end

	self:_setBusy(true)
	task.spawn(function()
		local response = self:_invokePrepare()
		if typeof(response) ~= "table" or response.ok ~= true then
			self:_setBusy(false)
			local message = if typeof(response) == "table" and typeof(response.message) == "string"
				then response.message
				else "Gift could not be prepared."
			Notify.Show(message, { color = "Red" })
			return
		end

		local productId = normalizeUserId(response.productId)
		if productId <= 0 then
			self:_setBusy(false)
			Notify.Show("Gift product is unavailable.", { color = "Red" })
			return
		end

		self._pendingPromptProductId = productId
		MarketplaceService:PromptProductPurchase(LocalPlayer, productId)
	end)
end

function GiftMenuController:_handlePromptFinished(a, b, c)
	local userId, productId, wasPurchased = getPromptProductArgs(a, b, c)
	if userId ~= LocalPlayer.UserId or productId ~= self._pendingPromptProductId then
		return
	end

	if not wasPurchased then
		self._pendingPromptProductId = 0
		self:_setBusy(false)
	end
end

function GiftMenuController:_handleGiftResult(payload)
	if typeof(payload) ~= "table" or payload.productId ~= self._pendingPromptProductId then
		return
	end

	self._pendingPromptProductId = 0
	self:_setBusy(false)

	if payload.ok == true then
		Notify.Show(payload.message or "Gift sent!", { color = "Green" })
		self:_close()
	else
		Notify.Show(payload.message or "Gift failed to process.", { color = "Red" })
	end
end

function GiftMenuController:_cacheTextLabels(frame: GuiObject)
	local costLabels = {}
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("TextLabel") and child.Name == "Cost" then
			table.insert(costLabels, child)
		end
	end

	table.sort(costLabels, function(left, right)
		return left.Position.Y.Scale < right.Position.Y.Scale
	end)

	for _, label in ipairs(costLabels) do
		local text = string.lower(label.Text)
		if string.find(text, "massive", 1, true) then
			self._productNameLabel = label
		elseif string.find(text, "recipient", 1, true) then
			-- Keep the authored recipient title text; it is only used to identify the other labels.
		elseif tonumber(label.Text) then
			self._priceLabel = label
		end
	end

	self._productNameLabel = self._productNameLabel or costLabels[1]
	self._priceLabel = self._priceLabel or costLabels[2]
end

function GiftMenuController:_bindTabs(playersMenu: Instance)
	local toggleButtons = playersMenu:FindFirstChild("ToggleButtons")
	local serverTab = toggleButtons and toggleButtons:FindFirstChild("Server") or nil
	local friendsTab = toggleButtons and toggleButtons:FindFirstChild("Friends") or nil

	self._serverTab = if serverTab and serverTab:IsA("GuiButton") then serverTab else nil
	self._friendsTab = if friendsTab and friendsTab:IsA("GuiButton") then friendsTab else nil

	for _, button in ipairs({ self._serverTab, self._friendsTab }) do
		if button then
			button.Active = true
			button.Selectable = true
			button.AutoButtonColor = true
		end
	end

	track(self._frameConnections, self._serverTab and self._serverTab.Activated:Connect(function()
		self:_setActiveTab("Server")
	end))
	track(self._frameConnections, self._friendsTab and self._friendsTab.Activated:Connect(function()
		self:_setActiveTab("Friends")
	end))
end

function GiftMenuController:_bindFrame(frame: GuiObject?)
	disconnectAll(self._frameConnections)
	self:_clearRows()
	self:_restoreLayering(true)
	self._frame = nil
	self._playersMenu = nil
	self._scroller = nil
	self._template = nil
	self._searchBox = nil
	self._serverTab = nil
	self._friendsTab = nil
	self._claimButton = nil
	self._claimLabel = nil
	self._recipientButton = nil
	self._recipientUsername = nil
	self._recipientIcon = nil
	self._productNameLabel = nil
	self._priceLabel = nil
	self._icon = nil
	self._screenGui = nil

	if not frame then
		return
	end

	self._frame = frame
	self:_cacheTextLabels(frame)
	self._icon = findImageLabel(frame, "Icon")
	self._claimButton = findGuiButton(frame, "ClaimButton")
	self._claimLabel = self._claimButton and findTextLabel(self._claimButton, "Label") or nil

	local recipient = frame:FindFirstChild("Recipient")
	if recipient and recipient:IsA("GuiObject") then
		self._recipientButton = recipient
		self._recipientUsername = findTextLabel(recipient, "Username")
		self._recipientIcon = findImageLabel(recipient, "Icon")
	end

	local playersMenu = frame:FindFirstChild("PlayersMenu")
	if playersMenu then
		self._playersMenu = playersMenu
		self:_bindTabs(playersMenu)

		local scroller = playersMenu:FindFirstChild("ScrollingFrame")
		if scroller and scroller:IsA("ScrollingFrame") then
			self._scroller = scroller
			local template = scroller:FindFirstChild("Template")
			if template and template:IsA("GuiObject") then
				self._template = template
				template.Visible = false
			end
		end

		local searchBox = playersMenu:FindFirstChild("Searchbox")
		local textBox = searchBox and searchBox:FindFirstChild("TextBox")
		if textBox and textBox:IsA("TextBox") then
			self._searchBox = textBox
			track(self._frameConnections, textBox:GetPropertyChangedSignal("Text"):Connect(function()
				self:_renderRows()
			end))
		end
	end

	local closeButton = findGuiButton(frame, "CloseButton")
	track(self._frameConnections, closeButton and closeButton.Activated:Connect(function()
		self:_close()
	end))
	track(self._frameConnections, self._claimButton and self._claimButton.Activated:Connect(function()
		self:_promptGiftPurchase()
	end))

	frame.Visible = false
	self:_updateClaimButton()
end

function GiftMenuController:_warnMissingFrame()
	if self._warnedMissingFrame then
		return
	end
	self._warnedMissingFrame = true
	warn("[GiftMenuController] Missing PlayerGui.Frames.GiftMenu")
end

function GiftMenuController:_scheduleRebind()
	if self._rebindQueued then
		return
	end

	self._rebindQueued = true
	task.defer(function()
		self._rebindQueued = false
		self:_bindCurrentFrame()
	end)
end

function GiftMenuController:_bindCurrentFrame()
	local framesGui = PlayerGui:FindFirstChild(FRAMES_GUI_NAME)
	local frame = framesGui and framesGui:FindFirstChild(FRAME_NAME)
	if frame and frame:IsA("GuiObject") then
		self._warnedMissingFrame = false
		self:_bindFrame(frame)
	else
		self:_bindFrame(nil)
		self:_warnMissingFrame()
	end
end

function GiftMenuController:OpenForProduct(config)
	self:_ensureRemotes()

	if not self._frame then
		self:_bindCurrentFrame()
	end

	local frame = self._frame
	if not frame then
		self:_warnMissingFrame()
		return
	end

	local productKey = typeof(config) == "table" and config.productKey or nil
	if typeof(productKey) ~= "string" or productKey == "" then
		warn("[GiftMenuController] Missing productKey")
		return
	end

	local giftProductKey = if typeof(config.giftProductKey) == "string" and config.giftProductKey ~= ""
		then config.giftProductKey
		else getGiftProductKey(productKey)
	if typeof(giftProductKey) ~= "string" or giftProductKey == "" then
		Notify.Show("This item cannot be gifted yet.", { color = "Red" })
		return
	end

	self._currentProduct = {
		productKey = productKey,
		giftProductKey = giftProductKey,
	}
	self._pendingPromptProductId = 0
	self:_setBusy(false)
	self:_setSelectedRecipient(nil)
	self:_setProductTexts(productKey, giftProductKey)
	self:_refreshLivePrice(giftProductKey)

	if self._icon and typeof(config.icon) == "string" and config.icon ~= "" then
		self._icon.Image = config.icon
	end
	if self._searchBox then
		self._searchBox.Text = ""
	end

	self._activeTab = DEFAULT_TAB
	self:_setTabVisuals()
	self:_loadServerRecipients()
	self:_loadFriendRecipients()
	self:_renderRows()
	self:_pushOverlayHiddenScope()
	self:_promoteAboveOpenFrames()
	frame.Visible = true
end

function GiftMenuController:OnStart()
	disconnectAll(self._connections)
	disconnectAll(self._frameConnections)
	disconnectAll(self._rowConnections)

	self._prepareRemote = waitForRemoteFunction(PREPARE_GIFT_PURCHASE_REMOTE_NAME)
	self._resultRemote = waitForRemoteEvent(GIFT_PURCHASE_RESULT_REMOTE_NAME)
	self:_bindCurrentFrame()

	track(self._connections, PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == FRAMES_GUI_NAME then
			self:_scheduleRebind()
		end
	end))
	track(self._connections, PlayerGui.DescendantAdded:Connect(function(descendant)
		if descendant.Name == FRAME_NAME or descendant.Name == "Template" or descendant.Name == "ClaimButton" then
			self:_scheduleRebind()
		end
	end))
	track(self._connections, Players.PlayerAdded:Connect(function()
		if self._frame and self._frame.Visible then
			self:_loadServerRecipients()
			self:_loadFriendRecipients()
			self:_renderRows()
		end
	end))
	track(self._connections, Players.PlayerRemoving:Connect(function(player)
		if self._selectedRecipient and self._selectedRecipient.userId == player.UserId then
			self:_setSelectedRecipient(nil)
		end
		if self._frame and self._frame.Visible then
			self:_loadServerRecipients()
			self:_loadFriendRecipients()
			self:_renderRows()
		end
	end))
	track(self._connections, MarketplaceService.PromptProductPurchaseFinished:Connect(function(a, b, c)
		self:_handlePromptFinished(a, b, c)
	end))

	if self._resultRemote then
		track(self._connections, self._resultRemote.OnClientEvent:Connect(function(payload)
			self:_handleGiftResult(payload)
		end))
	end
end

return GiftMenuController
