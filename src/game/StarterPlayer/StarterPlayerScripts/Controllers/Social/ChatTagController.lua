local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local ChatTagController = {}

function ChatTagController:OnStart()
	TextChatService.OnIncomingMessage = function(message: TextChatMessage)
		local textSource = message.TextSource
		if not textSource then
			return nil
		end

		local player = Players:GetPlayerByUserId(textSource.UserId)
		if player and player:GetAttribute("VIP") then
			local overrideProperties = Instance.new("TextChatMessageProperties")
			overrideProperties.PrefixText = `<font color="#ff8c00"><b>[VIP]</b></font> ` .. message.PrefixText
			return overrideProperties
		end

		return nil
	end
end

return ChatTagController
