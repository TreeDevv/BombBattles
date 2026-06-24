local KINDS = table.freeze({
	Product = "Product",
	Pass = "Pass",
})

local ShopCatalog = {}

ShopCatalog.Kinds = KINDS

ShopCatalog.Entries = table.freeze({
	VIP = table.freeze({
		cardName = "VIP",
		kind = KINDS.Pass,
		key = "vip",
		displayName = "VIP",
		description = "VIP chat tag and bonus rewards.",
		ownedText = "OWNED",
	}),
	StarterPack = table.freeze({
		cardName = "StarterPack",
		kind = KINDS.Product,
		key = "StarterPack",
		displayName = "Starter Pack",
		description = "A one-time starter offer for getting into the action faster.",
		ownedAttribute = "StarterPackOwned",
		ownedText = "OWNED",
	}),
	InstantSpin = table.freeze({
		cardName = "InstantSpin",
		kind = KINDS.Pass,
		key = "InstantSpin",
		displayName = "Instant Spin",
		description = "Skip crate spin waiting and reveal rewards faster.",
		ownedText = "OWNED",
	}),
	Coins500 = table.freeze({
		cardName = "500Coins",
		kind = KINDS.Product,
		key = "Coins500",
		displayName = "500 Coins",
		description = "Add 500 coins to your balance.",
	}),
	Coins2500 = table.freeze({
		cardName = "2.5KCoins",
		kind = KINDS.Product,
		key = "Coins2500",
		displayName = "2,500 Coins",
		description = "Add 2,500 coins to your balance.",
	}),
	Coins7000 = table.freeze({
		cardName = "7KCoins",
		kind = KINDS.Product,
		key = "Coins7000",
		displayName = "7,000 Coins",
		description = "Add 7,000 coins to your balance.",
	}),
	Coins15000 = table.freeze({
		cardName = "15KCoins",
		kind = KINDS.Product,
		key = "Coins15000",
		displayName = "15,000 Coins",
		description = "Add 15,000 coins to your balance.",
	}),
	Coins25000 = table.freeze({
		cardName = "25KCoins",
		kind = KINDS.Product,
		key = "Coins25000",
		displayName = "25,000 Coins",
		description = "Add 25,000 coins to your balance.",
	}),
})

ShopCatalog.Order = table.freeze({
	"VIP",
	"StarterPack",
	"InstantSpin",
	"Coins500",
	"Coins2500",
	"Coins7000",
	"Coins15000",
	"Coins25000",
})

local entriesByCardName = {}
for _, entryKey in ipairs(ShopCatalog.Order) do
	local entry = ShopCatalog.Entries[entryKey]
	if entry then
		entriesByCardName[entry.cardName] = entry
	end
end

function ShopCatalog.GetEntry(entryKey: any)
	if typeof(entryKey) ~= "string" or entryKey == "" then
		return nil
	end

	return ShopCatalog.Entries[entryKey]
end

function ShopCatalog.GetEntryByCardName(cardName: any)
	if typeof(cardName) ~= "string" or cardName == "" then
		return nil
	end

	return entriesByCardName[cardName]
end

return table.freeze(ShopCatalog)
