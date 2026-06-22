local BombSkinConfig = require(script.Parent.BombSkinConfig)

local DailyRewardConfig = {}

DailyRewardConfig.RemotesFolderName = "Remotes"
DailyRewardConfig.RequestRemoteName = "DailyRewardRequest"
DailyRewardConfig.StateRemoteName = "DailyRewardState"
DailyRewardConfig.FrameName = "DailyRewards"
DailyRewardConfig.RewardSource = "DailyReward"
DailyRewardConfig.MaxDay = 21

DailyRewardConfig.ZonePaths = table.freeze({
	table.freeze({ "Lobby", "DailyRewards", "ZonePart" }),
})

DailyRewardConfig.Actions = table.freeze({
	GetState = "GetState",
	Claim = "Claim",
})

DailyRewardConfig.RewardTypes = table.freeze({
	Cash = "Cash",
	CrateToken = "CrateToken",
	Skin = "Skin",
})

DailyRewardConfig.Icons = table.freeze({
	Cash = "rbxassetid://133902414661833",
	BasicCrate = "rbxassetid://133902414661833",
	PremiumCrate = "rbxassetid://133902414661833",
})

DailyRewardConfig.Days = table.freeze({
	table.freeze({
		day = 1,
		displayText = "250",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 250 }),
		}),
	}),
	table.freeze({
		day = 2,
		displayText = "1 Normal Crate",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Basic", amount = 1 }),
		}),
	}),
	table.freeze({
		day = 3,
		displayText = "500",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 500 }),
		}),
	}),
	table.freeze({
		day = 4,
		displayText = "2 Normal Crates",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Basic", amount = 2 }),
		}),
	}),
	table.freeze({
		day = 5,
		displayText = "750",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 750 }),
		}),
	}),
	table.freeze({
		day = 6,
		displayText = "1,000",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 1000 }),
		}),
	}),
	table.freeze({
		day = 7,
		displayText = "1,500 + 1 Premium Crate",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 1500 }),
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Premium", amount = 1 }),
		}),
		milestone = true,
	}),
	table.freeze({
		day = 8,
		displayText = "500 + 1 Normal Crate",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 500 }),
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Basic", amount = 1 }),
		}),
	}),
	table.freeze({
		day = 9,
		displayText = "900",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 900 }),
		}),
	}),
	table.freeze({
		day = 10,
		displayText = "1 Premium Crate",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Premium", amount = 1 }),
		}),
	}),
	table.freeze({
		day = 11,
		displayText = "3 Normal Crates",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Basic", amount = 3 }),
		}),
	}),
	table.freeze({
		day = 12,
		displayText = "1,250 + 1 Normal Crate",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 1250 }),
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Basic", amount = 1 }),
		}),
	}),
	table.freeze({
		day = 13,
		displayText = "1,750",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 1750 }),
		}),
	}),
	table.freeze({
		day = 14,
		displayText = "1,500 + UFO Bomb",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 1500 }),
			table.freeze({ type = DailyRewardConfig.RewardTypes.Skin, skinId = "UFO" }),
		}),
		milestone = true,
	}),
	table.freeze({
		day = 15,
		displayText = "750 + 2 Normal Crates",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 750 }),
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Basic", amount = 2 }),
		}),
	}),
	table.freeze({
		day = 16,
		displayText = "2,000",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 2000 }),
		}),
	}),
	table.freeze({
		day = 17,
		displayText = "1 Normal + 1 Premium Crate",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Basic", amount = 1 }),
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Premium", amount = 1 }),
		}),
	}),
	table.freeze({
		day = 18,
		displayText = "4 Normal Crates",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Basic", amount = 4 }),
		}),
	}),
	table.freeze({
		day = 19,
		displayText = "2,500",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 2500 }),
		}),
	}),
	table.freeze({
		day = 20,
		displayText = "1,500 + 2 Normal Crates",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 1500 }),
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Basic", amount = 2 }),
		}),
	}),
	table.freeze({
		day = 21,
		displayText = "2,500 + Nuke Bomb + 2 Premium Crates",
		rewards = table.freeze({
			table.freeze({ type = DailyRewardConfig.RewardTypes.Cash, amount = 2500 }),
			table.freeze({ type = DailyRewardConfig.RewardTypes.Skin, skinId = "Nuke" }),
			table.freeze({ type = DailyRewardConfig.RewardTypes.CrateToken, crateId = "Premium", amount = 2 }),
		}),
		milestone = true,
	}),
})

local daysByNumber = {}
for _, day in ipairs(DailyRewardConfig.Days) do
	daysByNumber[day.day] = day
end

function DailyRewardConfig.GetDay(dayNumber: any)
	local normalized = math.floor(tonumber(dayNumber) or 0)
	return daysByNumber[normalized]
end

function DailyRewardConfig.GetPrimaryIcon(dayDefinition): string?
	if typeof(dayDefinition) ~= "table" then
		return nil
	end

	for _, reward in ipairs(dayDefinition.rewards or {}) do
		if reward.type == DailyRewardConfig.RewardTypes.Skin then
			return BombSkinConfig.GetIconImage(reward.skinId) or BombSkinConfig.GetArchivedIconImage(reward.skinId)
		end
	end

	for _, reward in ipairs(dayDefinition.rewards or {}) do
		if reward.type == DailyRewardConfig.RewardTypes.CrateToken and reward.crateId == "Premium" then
			return DailyRewardConfig.Icons.PremiumCrate
		end
	end

	for _, reward in ipairs(dayDefinition.rewards or {}) do
		if reward.type == DailyRewardConfig.RewardTypes.CrateToken then
			return DailyRewardConfig.Icons.BasicCrate
		end
	end

	return DailyRewardConfig.Icons.Cash
end

function DailyRewardConfig.GetDaysPayload()
	local payload = {}
	for _, day in ipairs(DailyRewardConfig.Days) do
		table.insert(payload, {
			day = day.day,
			displayText = day.displayText,
			milestone = day.milestone == true,
			iconImage = DailyRewardConfig.GetPrimaryIcon(day),
		})
	end
	return payload
end

return table.freeze(DailyRewardConfig)
