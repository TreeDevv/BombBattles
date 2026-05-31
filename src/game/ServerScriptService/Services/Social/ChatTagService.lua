local PurchaseReceiptService = require(script.Parent.PurchaseReceiptService)

local function givePlayerVipTag(player: Player)
	player:SetAttribute("VIP", true)
end

local function onPurchaseProcessed(player: Player, key: string)
	if key == "vip" then
		givePlayerVipTag(player)
	end
end

local function onOwnedPassesReady(player: Player, ownedKeys: { [string]: boolean? })
	if ownedKeys["vip"] then
		givePlayerVipTag(player)
	end
end

local ChatTagService = {}

function ChatTagService:OnStart()
	PurchaseReceiptService.PurchaseProcessed:Connect(onPurchaseProcessed)
	PurchaseReceiptService.OwnedPassesReady:Connect(onOwnedPassesReady)
end

return ChatTagService
