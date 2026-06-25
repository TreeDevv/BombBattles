local SocialService = game:GetService("SocialService")

local DEFAULT_DELAY_SECONDS = 1

export type PromptOptions = {
	player: Player,
	inviteUserId: number,
	promptMessage: string?,
	launchData: string?,
	delaySeconds: number?,
	shouldContinue: (() -> boolean)?,
}

local GameInvitePrompt = {}

local function normalizeInviteUserId(value: any): number
	local userId = math.floor(tonumber(value) or 0)
	return if userId > 0 then userId else 0
end

function GameInvitePrompt.Prompt(options: PromptOptions): (boolean, string, any?)
	local player = options.player
	local inviteUserId = normalizeInviteUserId(options.inviteUserId)
	if not (player and player.Parent and inviteUserId > 0) then
		return false, "InvalidInviteUser", nil
	end

	local okCanInvite, canInviteResult = pcall(function()
		return SocialService:CanSendGameInviteAsync(player, inviteUserId)
	end)
	if not okCanInvite then
		return false, "CanSendFailed", canInviteResult
	end
	if canInviteResult ~= true then
		return false, "CannotInvite", canInviteResult
	end

	local delaySeconds = math.max(0, tonumber(options.delaySeconds) or DEFAULT_DELAY_SECONDS)
	if delaySeconds > 0 then
		task.wait(delaySeconds)
	end

	if not (player and player.Parent) then
		return false, "Cancelled", nil
	end
	if options.shouldContinue and options.shouldContinue() ~= true then
		return false, "Cancelled", nil
	end

	local inviteOptions = Instance.new("ExperienceInviteOptions")
	inviteOptions.InviteUser = inviteUserId
	if typeof(options.promptMessage) == "string" and options.promptMessage ~= "" then
		inviteOptions.PromptMessage = options.promptMessage
	end
	if typeof(options.launchData) == "string" and options.launchData ~= "" then
		inviteOptions.LaunchData = options.launchData
	end

	local okPrompt, promptResult = pcall(function()
		SocialService:PromptGameInvite(player, inviteOptions)
	end)
	inviteOptions:Destroy()

	if not okPrompt then
		return false, "PromptFailed", promptResult
	end

	return true, "Prompted", nil
end

return GameInvitePrompt
