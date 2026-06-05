local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)

local CharacterAnimationService = {}

local LOOKUP_TIMEOUT_SECONDS = 5
local playerConnections = {} :: { [Player]: RBXScriptConnection }

local function waitForHumanoid(character: Model): Humanoid?
	local deadline = os.clock() + LOOKUP_TIMEOUT_SECONDS

	repeat
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return humanoid
		end

		task.wait()
	until os.clock() >= deadline or not character.Parent

	return nil
end

local function markServerAnimator(animator: Animator)
	local attributeName = AnimationConfig.ServerAnimatorAttributeName
	if typeof(attributeName) == "string" and attributeName ~= "" then
		animator:SetAttribute(attributeName, true)
	end
end

local function ensureCharacterAnimator(character: Model)
	local humanoid = waitForHumanoid(character)
	if not humanoid then
		warn("[CharacterAnimationService] Missing Humanoid for character:", character:GetFullName())
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	markServerAnimator(animator)
end

function CharacterAnimationService:OnPlayerAdded(player: Player)
	if playerConnections[player] then
		playerConnections[player]:Disconnect()
	end

	playerConnections[player] = player.CharacterAdded:Connect(function(character)
		task.spawn(ensureCharacterAnimator, character)
	end)

	if player.Character then
		task.spawn(ensureCharacterAnimator, player.Character)
	end
end

function CharacterAnimationService:OnPlayerRemoving(player: Player)
	if playerConnections[player] then
		playerConnections[player]:Disconnect()
		playerConnections[player] = nil
	end
end

return CharacterAnimationService
