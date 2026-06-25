local HumanoidStateGuards = {}

local FALLING_DOWN_DISABLED_ATTR = "Movement_FallingDownStateDisabled"
local FALLING_DOWN_STATE = Enum.HumanoidStateType.FallingDown

function HumanoidStateGuards.WaitForHumanoid(character: Model, timeoutSeconds: number): Humanoid?
	local deadline = os.clock() + timeoutSeconds
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	while not humanoid and os.clock() <= deadline and character.Parent do
		task.wait()
		humanoid = character:FindFirstChildOfClass("Humanoid")
	end
	return humanoid
end

function HumanoidStateGuards.DisableFallingDown(character: Model, humanoid: Humanoid?): boolean
	local disabled = false
	if humanoid then
		disabled = pcall(function()
			humanoid:SetStateEnabled(FALLING_DOWN_STATE, false)
		end)
	end

	character:SetAttribute(FALLING_DOWN_DISABLED_ATTR, disabled)
	return disabled
end

function HumanoidStateGuards.RecoverFromFallingDown(humanoid: Humanoid): boolean
	if humanoid.Health <= 0 or humanoid.PlatformStand or humanoid:GetState() ~= FALLING_DOWN_STATE then
		return false
	end

	local recoveryState = if humanoid.FloorMaterial ~= Enum.Material.Air
		then Enum.HumanoidStateType.Running
		else Enum.HumanoidStateType.Freefall

	local recovered = pcall(function()
		humanoid:ChangeState(recoveryState)
	end)
	return recovered
end

return table.freeze(HumanoidStateGuards)
