local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerSettings = require(ReplicatedStorage.Shared.Common.PlayerSettings)

local InputBindings = {}

InputBindings.Actions = table.freeze({
	ShiftLock = "shiftLock",
	OffensiveAbility = "offensiveAbility",
	DefensiveAbility = "defensiveAbility",
	Emote = "emote",
})

function InputBindings.GetShiftLockInputs(): { any }
	return {
		PlayerSettings:GetKeyCode("shiftLockKey", Enum.KeyCode.LeftControl),
		Enum.KeyCode.ButtonR3,
	}
end

function InputBindings.GetOffensiveAbilityInputs(): { any }
	return {
		PlayerSettings:GetKeyCode("offensiveAbilityKey", Enum.KeyCode.E),
		Enum.KeyCode.ButtonL1,
	}
end

function InputBindings.GetDefensiveAbilityInputs(): { any }
	return {
		PlayerSettings:GetKeyCode("defensiveAbilityKey", Enum.KeyCode.Q),
		Enum.KeyCode.ButtonR1,
	}
end

function InputBindings.GetEmoteInputs(): { any }
	return {
		PlayerSettings:GetKeyCode("emoteKey", Enum.KeyCode.B),
	}
end

return table.freeze(InputBindings)
