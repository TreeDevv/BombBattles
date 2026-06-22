local Players = game:GetService("Players")

local RoundRespawnTokens = {}
RoundRespawnTokens.__index = RoundRespawnTokens

function RoundRespawnTokens.new()
	return setmetatable({
		respawnTokens = {},
		characterDestroyTokens = {},
		pendingRoundRespawnTokens = {},
	}, RoundRespawnTokens)
end

function RoundRespawnTokens:BumpRespawn(player: Player): number
	local token = (self.respawnTokens[player] or 0) + 1
	self.respawnTokens[player] = token
	return token
end

function RoundRespawnTokens:GetRespawn(player: Player): number?
	return self.respawnTokens[player]
end

function RoundRespawnTokens:CancelRespawn(player: Player)
	self:BumpRespawn(player)
	self.pendingRoundRespawnTokens[player] = nil
end

function RoundRespawnTokens:SetPendingRoundRespawn(player: Player, token: number)
	self.pendingRoundRespawnTokens[player] = token
end

function RoundRespawnTokens:GetPendingRoundRespawn(player: Player): number?
	return self.pendingRoundRespawnTokens[player]
end

function RoundRespawnTokens:ClearPendingRoundRespawn(player: Player)
	self.pendingRoundRespawnTokens[player] = nil
end

function RoundRespawnTokens:BumpCharacterDestroy(player: Player): number
	local token = (self.characterDestroyTokens[player] or 0) + 1
	self.characterDestroyTokens[player] = token
	return token
end

function RoundRespawnTokens:GetCharacterDestroy(player: Player): number?
	return self.characterDestroyTokens[player]
end

function RoundRespawnTokens:CancelCharacterDestroy(player: Player)
	self:BumpCharacterDestroy(player)
end

function RoundRespawnTokens:DestroyPlayerCharacter(player: Player)
	self:CancelCharacterDestroy(player)
	local character = player.Character
	if character then
		character:Destroy()
	end
end

function RoundRespawnTokens:DestroyPlayerCharacterAfter(player: Player, delaySeconds: number)
	local character = player.Character
	if not character then
		return
	end

	local token = self:BumpCharacterDestroy(player)
	task.delay(math.max(delaySeconds, 0), function()
		if self.characterDestroyTokens[player] ~= token then
			return
		end
		if player.Parent ~= Players then
			return
		end
		if player.Character ~= character then
			return
		end

		character:Destroy()
	end)
end

function RoundRespawnTokens:ClearPlayer(player: Player)
	self.respawnTokens[player] = nil
	self.characterDestroyTokens[player] = nil
	self.pendingRoundRespawnTokens[player] = nil
end

return RoundRespawnTokens
