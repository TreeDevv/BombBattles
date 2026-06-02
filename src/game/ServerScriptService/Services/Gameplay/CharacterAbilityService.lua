local Players = game:GetService("Players")

local CharacterAbilityService = {}

local ABILITY_MANAGER_NAME = "AbilityManagerActor"
local ABILITIES_NAME = "Abilities"
local FALLING_DOWN_ABILITY_NAME = "FallingDown"
local SYNCED_STATE_NAME = "SyncedState"
local LOOKUP_TIMEOUT_SECONDS = 5

local function disableFallingDownAbility(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
	end

	local abilityManagerActor = character:WaitForChild(ABILITY_MANAGER_NAME, LOOKUP_TIMEOUT_SECONDS)
	if not abilityManagerActor then
		return
	end

	local abilities = abilityManagerActor:WaitForChild(ABILITIES_NAME, LOOKUP_TIMEOUT_SECONDS)
	if not abilities then
		return
	end

	local fallingDown = abilities:FindFirstChild(FALLING_DOWN_ABILITY_NAME)
	if not fallingDown then
		return
	end

	local syncedState = fallingDown:FindFirstChild(SYNCED_STATE_NAME)
	if syncedState then
		syncedState:SetAttribute("Enabled", false)
	end
end

function CharacterAbilityService:OnPlayerAdded(player: Player)
	if player.Character then
		task.spawn(disableFallingDownAbility, player.Character)
	end

	player.CharacterAdded:Connect(function(character)
		disableFallingDownAbility(character)
	end)
end

return CharacterAbilityService
