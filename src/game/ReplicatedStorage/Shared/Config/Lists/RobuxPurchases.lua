local CASH_KEY = "cash"
local CRATE_TOKENS_KEY = "crateTokens"

local function roundNonNegative(value)
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue < 0 then
		return 0
	end
	return math.floor(numberValue + 0.5)
end

local function getServices()
	local ServerScriptService = game:GetService("ServerScriptService")
	return ServerScriptService:WaitForChild("Services")
end

local function addCash(player, amount)
	local DataService = require(getServices():WaitForChild("DataService"))
	local cashAmount = roundNonNegative(amount)
	if cashAmount <= 0 then
		return
	end

	DataService:Set(player, CASH_KEY, function(currentValue)
		return roundNonNegative(currentValue) + cashAmount
	end)
end

local function addPremiumCrateTokens(player, amount)
	local DataService = require(getServices():WaitForChild("DataService"))
	local tokenAmount = roundNonNegative(amount)
	if tokenAmount <= 0 then
		return
	end

	DataService:Set(player, CRATE_TOKENS_KEY, function(currentValue)
		local tokens = if typeof(currentValue) == "table" then table.clone(currentValue) else {}
		tokens.Premium = roundNonNegative(tokens.Premium) + tokenAmount
		return tokens
	end)
end

local function grantInfinityBundle(player)
	local services = getServices()
	local AbilityInventoryService = require(services:WaitForChild("AbilityInventoryService"))

	local abilityOk, abilityResult = AbilityInventoryService:GrantAbility(player, "Infinity", "InfinityBundle")
	if not abilityOk then
		warn("[RobuxPurchases] InfinityBundle failed to grant Infinity: " .. tostring(abilityResult))
	end
end

local function grantFatPack(player)
	local services = getServices()
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

local function addSpinWheelSpins(player, amount)
	local services = getServices()
	local SpinWheelService = require(services:WaitForChild("SpinWheelService"))
	local ok, result = SpinWheelService:GrantSpins(player, amount, "RobuxPurchase")
	if not ok then
		warn("[RobuxPurchases] SpinWheel failed to grant spins: " .. tostring(result))
	end
end

local Purchases = {
	Products = {
		InfinityBundle = {
			displayName = "Infinity Bundle",
			price = 1499,
			id = 3606250976,
			onProcessed = function(player)
				grantInfinityBundle(player)
			end,
		},
		InfinityBundleGift = {
			displayName = "Infinity Bundle Gift",
			price = 1499,
			id = 3606250984,
			giftTargetKey = "InfinityBundle",
		},
		FatPack = {
			displayName = "Fat Bundle",
			price = 799,
			id = 3606250987,
			onProcessed = function(player)
				grantFatPack(player)
			end,
		},
		FatPackGift = {
			displayName = "Fat Bundle Gift",
			price = 799,
			id = 3606250993,
			giftTargetKey = "FatPack",
		},
		StarterPack = {
			displayName = "Starter Pack",
			price = 99,
			id = 3606250997,
		},
		StarterPackGift = {
			displayName = "Starter Pack Gift",
			price = 99,
			id = 3606251000,
			giftTargetKey = "StarterPack",
		},
		Coins500 = {
			displayName = "500 Coins",
			price = 49,
			id = 3606251003,
			cash = 500,
			onProcessed = function(player)
				addCash(player, 500)
			end,
		},
		Coins500Gift = {
			displayName = "500 Coins Gift",
			price = 49,
			id = 3606251006,
			giftTargetKey = "Coins500",
		},
		Coins2500 = {
			displayName = "2,500 Coins",
			price = 199,
			id = 3606251010,
			cash = 2500,
			onProcessed = function(player)
				addCash(player, 2500)
			end,
		},
		Coins2500Gift = {
			displayName = "2,500 Coins Gift",
			price = 199,
			id = 3606251016,
			giftTargetKey = "Coins2500",
		},
		Coins7000 = {
			displayName = "7,000 Coins",
			price = 499,
			id = 3606251019,
			cash = 7000,
			onProcessed = function(player)
				addCash(player, 7000)
			end,
		},
		Coins7000Gift = {
			displayName = "7,000 Coins Gift",
			price = 499,
			id = 3606251022,
			giftTargetKey = "Coins7000",
		},
		Coins15000 = {
			displayName = "15,000 Coins",
			price = 999,
			id = 3606251026,
			cash = 15000,
			onProcessed = function(player)
				addCash(player, 15000)
			end,
		},
		Coins15000Gift = {
			displayName = "15,000 Coins Gift",
			price = 999,
			id = 3606251027,
			giftTargetKey = "Coins15000",
		},
		Coins25000 = {
			displayName = "25,000 Coins",
			price = 1499,
			id = 3606251033,
			cash = 25000,
			onProcessed = function(player)
				addCash(player, 25000)
			end,
		},
		Coins25000Gift = {
			displayName = "25,000 Coins Gift",
			price = 1499,
			id = 3606251036,
			giftTargetKey = "Coins25000",
		},
		PremiumCrateRoll = {
			displayName = "1 Premium Bomb Crate",
			price = 79,
			id = 3606251039,
			crateId = "Premium",
			crateTokens = 1,
			onProcessed = function(player)
				addPremiumCrateTokens(player, 1)
			end,
		},
		PremiumCrateRollGift = {
			displayName = "1 Premium Bomb Crate Gift",
			price = 79,
			id = 3606251046,
			giftTargetKey = "PremiumCrateRoll",
		},
		PremiumCrateRoll5 = {
			displayName = "5 Premium Bomb Crates",
			price = 349,
			id = 3606251049,
			crateId = "Premium",
			crateTokens = 5,
			onProcessed = function(player)
				addPremiumCrateTokens(player, 5)
			end,
		},
		PremiumCrateRoll5Gift = {
			displayName = "5 Premium Bomb Crates Gift",
			price = 349,
			id = 3606251053,
			giftTargetKey = "PremiumCrateRoll5",
		},
		PremiumCrateRoll10 = {
			displayName = "10 Premium Bomb Crates",
			price = 649,
			id = 3606251059,
			crateId = "Premium",
			crateTokens = 10,
			onProcessed = function(player)
				addPremiumCrateTokens(player, 10)
			end,
		},
		PremiumCrateRoll10Gift = {
			displayName = "10 Premium Bomb Crates Gift",
			price = 649,
			id = 3606251063,
			giftTargetKey = "PremiumCrateRoll10",
		},
		PremiumFinisherCrateRoll = {
			displayName = "Premium Finisher Crate Roll",
			price = 99,
			id = 0,
			crateId = "FinisherPremium",
		},
		SpinWheel1 = {
			displayName = "1 Wheel Spin",
			price = 29,
			id = 3604180954,
			spins = 1,
			onProcessed = function(player)
				addSpinWheelSpins(player, 1)
			end,
		},
		SpinWheel3 = {
			displayName = "3 Wheel Spins",
			price = 79,
			id = 3604181024,
			spins = 3,
			onProcessed = function(player)
				addSpinWheelSpins(player, 3)
			end,
		},
	},

	Passes = {
		vip = {
			displayName = "VIP",
			price = 299,
			id = 1889596299,
		},
		InstantSpin = {
			displayName = "Instant Spin",
			price = 99,
			id = 1889872288,
		},
	},

	GiftingMap = {
		[3606250984] = "InfinityBundle",
		[3606250993] = "FatPack",
		[3606251000] = "StarterPack",
		[3606251006] = "Coins500",
		[3606251016] = "Coins2500",
		[3606251022] = "Coins7000",
		[3606251027] = "Coins15000",
		[3606251036] = "Coins25000",
		[3606251046] = "PremiumCrateRoll",
		[3606251053] = "PremiumCrateRoll5",
		[3606251063] = "PremiumCrateRoll10",
	},
}

Purchases.ProductsById = {}
for key, config in pairs(Purchases.Products) do
	config.key = key
	if config.id and config.id > 0 then
		Purchases.ProductsById[config.id] = config
	end
end

Purchases.GiftProductsByTargetKey = {}
for key, config in pairs(Purchases.Products) do
	local targetKey = config.giftTargetKey
	if typeof(targetKey) == "string" and targetKey ~= "" then
		Purchases.GiftProductsByTargetKey[targetKey] = key

		local targetConfig = Purchases.Products[targetKey]
		if targetConfig then
			targetConfig.giftProductKey = key
		end
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
