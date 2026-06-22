local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local CombatEligibility = require(ReplicatedStorage.Shared.Common.CombatEligibility)
local HipBombVisual = require(ReplicatedStorage.Shared.Effects.HipBombVisual)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)

local HIP_BOMB_VISUAL_NAME = (BombConfig.HipCarry and BombConfig.HipCarry.VisualName) or "BombHipVisual"
local HIP_BOMB_MOTOR_NAME = (BombConfig.HipCarry and BombConfig.HipCarry.MotorName) or "BombHipMotor"

local BombHipVisualRuntime = {}

function BombHipVisualRuntime.Destroy(controller, player: Player)
	local visual = controller._hipBombs[player]
	if visual then
		visual:Destroy()
	end
	controller._hipBombs[player] = nil
	if not visual then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant.Name == HIP_BOMB_VISUAL_NAME or (descendant.Name == HIP_BOMB_MOTOR_NAME and descendant:IsA("Motor6D")) then
			descendant:Destroy()
		end
	end
end

function BombHipVisualRuntime.IsSuppressed(controller, context, player: Player): boolean
	if controller._heldBombWanted[player] == true then
		return true
	end

	return player == context.localPlayer and (controller._holding or controller._releasePending or context.isCooking())
end

function BombHipVisualRuntime.ShouldShow(controller, context, player: Player): boolean
	local hipConfig = BombConfig.HipCarry
	if hipConfig and hipConfig.Enabled == false then
		return false
	end
	if player.Parent ~= Players then
		return false
	end
	if not CombatEligibility.IsClientCombatActive(player, context.getRoundState(), RoundStates.Active) then
		return false
	end
	if context.getPlayerBombCount(player) <= 0 then
		return false
	end
	if BombHipVisualRuntime.IsSuppressed(controller, context, player) then
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return character ~= nil and humanoid ~= nil and humanoid.Health > 0
end

function BombHipVisualRuntime.GetSwayState(player: Player)
	local character = player.Character
	if not character then
		return nil
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (rootPart and rootPart:IsA("BasePart")) then
		return nil
	end

	return {
		cframe = rootPart.CFrame,
		linearVelocity = rootPart.AssemblyLinearVelocity,
		grounded = character:GetAttribute("Movement_Grounded") ~= false,
		sprinting = character:GetAttribute("Movement_Sprinting") == true,
		sliding = character:GetAttribute("Movement_Sliding") == true,
		landingRecoveryAlpha = character:GetAttribute("Movement_LandingRecoveryAlpha"),
	}
end

function BombHipVisualRuntime.Step(controller, context, deltaTime: number)
	local activePlayers = {}

	for _, player in ipairs(Players:GetPlayers()) do
		activePlayers[player] = true
		if not BombHipVisualRuntime.ShouldShow(controller, context, player) then
			BombHipVisualRuntime.Destroy(controller, player)
			continue
		end

		local visual = controller._hipBombs[player]
		local skinId = context.getPlayerBombSkinId(player)
		if visual and visual.skinId ~= skinId then
			BombHipVisualRuntime.Destroy(controller, player)
			visual = nil
		end
		if not visual then
			local character = player.Character
			if character then
				visual = HipBombVisual.new(character, nil, {
					skinId = skinId,
				})
				controller._hipBombs[player] = visual
			end
		end

		if visual then
			local state = BombHipVisualRuntime.GetSwayState(player)
			if not state or not visual:Step(deltaTime, state) then
				BombHipVisualRuntime.Destroy(controller, player)
			else
				visual:SetVisible(true)
			end
		end
	end

	for player in pairs(controller._hipBombs) do
		if not activePlayers[player] then
			BombHipVisualRuntime.Destroy(controller, player)
		end
	end
end

return table.freeze(BombHipVisualRuntime)
