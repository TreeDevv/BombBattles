local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HumanoidStateGuards = require(ReplicatedStorage.Shared.Common.HumanoidStateGuards)

local CharacterAbilityService = {}
CharacterAbilityService._playerStates = {}

local LOOKUP_TIMEOUT_SECONDS = 5

function CharacterAbilityService:_disconnectPlayer(player: Player)
	local state = self._playerStates[player]
	if not state then
		return
	end

	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end
	if state.characterConnection then
		state.characterConnection:Disconnect()
	end
	self._playerStates[player] = nil
end

function CharacterAbilityService:_guardCharacter(player: Player, character: Model)
	local state = self._playerStates[player]
	if not state then
		return
	end

	if state.characterConnection then
		state.characterConnection:Disconnect()
		state.characterConnection = nil
	end

	local humanoid = HumanoidStateGuards.WaitForHumanoid(character, LOOKUP_TIMEOUT_SECONDS)
	if self._playerStates[player] ~= state or player.Character ~= character or not character.Parent then
		return
	end
	if humanoid then
		HumanoidStateGuards.DisableFallingDown(character, humanoid)
	end

	state.characterConnection = character.DescendantAdded:Connect(function(descendant)
		if self._playerStates[player] ~= state or player.Character ~= character then
			return
		end
		if descendant:IsA("Humanoid") then
			HumanoidStateGuards.DisableFallingDown(character, descendant)
		end
	end)
end

function CharacterAbilityService:OnPlayerAdded(player: Player)
	self:_disconnectPlayer(player)
	self._playerStates[player] = {
		connections = {},
		characterConnection = nil,
	}
	local state = self._playerStates[player]

	table.insert(state.connections, player.CharacterAdded:Connect(function(character)
		self:_guardCharacter(player, character)
	end))

	local currentCharacter = player.Character
	if currentCharacter then
		task.spawn(function()
			self:_guardCharacter(player, currentCharacter)
		end)
	end
end

function CharacterAbilityService:OnPlayerRemoving(player: Player)
	self:_disconnectPlayer(player)
end

return CharacterAbilityService
