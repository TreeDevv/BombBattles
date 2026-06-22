local Purchases = {
	Products = {
		example = {
			price = 599,
			id = 3364638365,
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
