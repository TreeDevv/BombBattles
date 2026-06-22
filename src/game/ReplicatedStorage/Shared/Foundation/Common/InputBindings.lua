local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerSettings = require(ReplicatedStorage.Shared.Common.PlayerSettings)

local InputBindings = {}

InputBindings.Actions = table.freeze({
	ShiftLock = "shiftLock",
})

function InputBindings.GetShiftLockInputs(): { any }
	return {
		PlayerSettings:GetShiftLockKeyCode(),
	}
end

return table.freeze(InputBindings)
