local Purchases = {
	Products = {
		example = {
			price = 599,
			id = 3364638365,
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
	if config.id then
		Purchases.ProductsById[config.id] = config
	end
end

Purchases.PassesById = {}
for key, config in pairs(Purchases.Passes) do
	config.key = key
	if config.id then
		Purchases.PassesById[config.id] = config
	end
end

return Purchases
