local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CodeConfig = require(ReplicatedStorage.Shared.Config.CodeConfig)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local CrateRollService = require(script.Parent.CrateRollService)
local DataService = require(script.Parent.DataService)

local CASH_KEY = Schema.Cash and Schema.Cash.key or "cash"
local REDEEMED_CODES_KEY = Schema.RedeemedCodes and Schema.RedeemedCodes.key or "redeemedCodes"

local CodeService = {}

local requestRemote: RemoteFunction? = nil
local redeemLocks: { [Player]: boolean } = {}

local function roundNonNegative(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue == math.huge or numberValue == -math.huge then
		return 0
	end
	return math.max(0, math.floor(numberValue + 0.5))
end

local function normalizeRedeemedCodes(value: any): { [string]: boolean }
	local redeemed = {}
	if typeof(value) ~= "table" then
		return redeemed
	end

	for codeId, isRedeemed in pairs(value) do
		if typeof(codeId) == "string" and isRedeemed == true then
			redeemed[CodeConfig.NormalizeCode(codeId)] = true
		end
	end

	return redeemed
end

local function buildResponse(ok: boolean, code: string, message: string, color: string?)
	local resolvedColor = color
	if not resolvedColor then
		resolvedColor = if ok then "Green" else "Red"
	end

	return {
		ok = ok,
		code = code,
		message = message,
		color = resolvedColor,
	}
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, CodeConfig.RemotesFolderName)
end

local function ensureRemotes()
	local remotesFolder = ensureRemotesFolder()
	requestRemote = RemoteUtil.EnsureRemoteFunction(remotesFolder, CodeConfig.RequestRemoteName)
end

local function addCash(player: Player, amount: number)
	amount = roundNonNegative(amount)
	if amount <= 0 then
		return
	end

	DataService:Set(player, CASH_KEY, function(currentValue)
		return roundNonNegative(currentValue) + amount
	end)
end

local function awardReward(player: Player, codeDefinition): (boolean, string?)
	local reward = codeDefinition.reward
	if typeof(reward) ~= "table" then
		return false, "Code reward is unavailable right now."
	end

	if reward.type == CodeConfig.RewardTypes.Cash then
		addCash(player, reward.amount)
		return true, nil
	elseif reward.type == CodeConfig.RewardTypes.Crate then
		local ok, message = CrateRollService:GrantRewardRoll(
			player,
			reward.crateId,
			("%s:%s"):format(CodeConfig.RewardSource, codeDefinition.id)
		)
		if not ok then
			return false, tostring(message or "Code reward is unavailable right now.")
		end
		return true, nil
	end

	return false, "Code reward is unavailable right now."
end

local function setRedeemed(player: Player, codeId: string, isRedeemed: boolean)
	DataService:Set(player, REDEEMED_CODES_KEY, function(currentValue)
		local redeemed = normalizeRedeemedCodes(currentValue)
		redeemed[codeId] = if isRedeemed then true else nil
		return redeemed
	end)
end

local function redeemCode(player: Player, rawCode: any)
	local codeId = CodeConfig.NormalizeCode(rawCode)
	if codeId == "" then
		return buildResponse(false, "BadRequest", "Enter a code first.", "Red")
	end

	local codeDefinition = CodeConfig.GetCode(codeId)
	if not codeDefinition then
		return buildResponse(false, "InvalidCode", "Invalid code.", "Red")
	end

	if redeemLocks[player] then
		return buildResponse(false, "Busy", "Please wait.", "Yellow")
	end

	redeemLocks[player] = true
	local ok, response = pcall(function()
		local profileData = DataService:Get(player)
		if typeof(profileData) ~= "table" then
			return buildResponse(false, "DataNotReady", "Codes are unavailable right now.", "Red")
		end

		local redeemed = normalizeRedeemedCodes(profileData[REDEEMED_CODES_KEY])
		if redeemed[codeDefinition.id] == true then
			return buildResponse(false, "AlreadyRedeemed", "You already redeemed this code.", "Yellow")
		end

		setRedeemed(player, codeDefinition.id, true)
		local awarded, awardMessage = awardReward(player, codeDefinition)
		if not awarded then
			setRedeemed(player, codeDefinition.id, false)
			warn(("[CodeService] Failed to grant %s to %s: %s"):format(
				codeDefinition.id,
				player.Name,
				tostring(awardMessage)
			))
			return buildResponse(false, "GrantFailed", "Code reward is unavailable right now.", "Red")
		end

		return buildResponse(true, "Redeemed", tostring(codeDefinition.successText or "Code redeemed!"), "Green")
	end)
	redeemLocks[player] = nil

	if not ok then
		warn(("[CodeService] Redeem failed for %s: %s"):format(player.Name, tostring(response)))
		return buildResponse(false, "Error", "Codes are unavailable right now.", "Red")
	end

	return response
end

local function handleInvoke(player: Player, request: any)
	if typeof(request) ~= "table" then
		return buildResponse(false, "BadRequest", "Bad request.", "Red")
	end

	if request.action == CodeConfig.Actions.Redeem then
		return redeemCode(player, request.code)
	end

	return buildResponse(false, "UnknownAction", "Unknown code action.", "Red")
end

function CodeService:OnStart()
	ensureRemotes()
	if requestRemote then
		requestRemote.OnServerInvoke = handleInvoke
	end
end

function CodeService:OnPlayerRemoving(player: Player)
	redeemLocks[player] = nil
end

return CodeService
