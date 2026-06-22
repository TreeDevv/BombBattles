local CodeConfig = {}

CodeConfig.RemotesFolderName = "Remotes"
CodeConfig.RequestRemoteName = "CodeRedeemRequest"
CodeConfig.FrameName = "Codes"
CodeConfig.RewardSource = "Code"

CodeConfig.Actions = table.freeze({
	Redeem = "Redeem",
})

CodeConfig.RewardTypes = table.freeze({
	Cash = "Cash",
	Crate = "Crate",
})

CodeConfig.Codes = table.freeze({
	WELCOME = table.freeze({
		id = "WELCOME",
		displayName = "WELCOME",
		reward = table.freeze({
			type = CodeConfig.RewardTypes.Cash,
			amount = 500,
		}),
		successText = "Code redeemed: 500 coins!",
	}),
})

function CodeConfig.NormalizeCode(value: any): string
	if typeof(value) ~= "string" then
		return ""
	end

	local trimmed = string.match(value, "^%s*(.-)%s*$")
	return string.upper(trimmed or "")
end

function CodeConfig.GetCode(value: any)
	local code = CodeConfig.NormalizeCode(value)
	if code == "" then
		return nil
	end
	return CodeConfig.Codes[code]
end

return table.freeze(CodeConfig)
