local function grantFatPack(player)
	local ServerScriptService = game:GetService("ServerScriptService")
	local services = ServerScriptService:WaitForChild("Services")
	local AbilityInventoryService = require(services:WaitForChild("AbilityInventoryService"))
	local BombSkinService = require(services:WaitForChild("BombSkinService"))

	local abilityOk, abilityResult = AbilityInventoryService:GrantAbility(player, "FatBomb", "FatPack")
	if not abilityOk then
		warn("[RobuxPurchases] FatPack failed to grant FatBomb: " .. tostring(abilityResult))
	end

	local skinOk, skinResult = BombSkinService:GrantSkin(player, "FatGuy", "FatPack")
	if not skinOk then
		warn("[RobuxPurchases] FatPack failed to grant FatGuy: " .. tostring(skinResult))
	end
end

local Purchases = {
	Products = {
		example = {
			price = 599,
			id = 3364638365,
		},
		FatPack = {
			displayName = "Fat Pack",
			price = 0,
			id = 0,
			onProcessed = function(player)
				grantFatPack(player)
			end,
		},
		PremiumCrateRoll = {
			displayName = "Premium Crate Roll",
			price = 99,
			id = 0,
			crateId = "Premium",
		},
		PremiumFinisherCrateRoll = {
			displayName = "Premium Finisher Crate Roll",
			price = 99,
			id = 0,
			crateId = "FinisherPremium",
		},
	},

	Passes = {
		Example = {
			id = 0,
		},
	},

	GiftingMap = {},
}

Purchases.ProductsById = {}
for key, config in pairs(Purchases.Products) do
	config.key = key
	if config.id and config.id > 0 then
		Purchases.ProductsById[config.id] = config
	end
end

Purchases.PassesById = {}
for key, config in pairs(Purchases.Passes) do
	config.key = key
	if config.id and config.id > 0 then
		Purchases.PassesById[config.id] = config
	end
end

return Purchases
