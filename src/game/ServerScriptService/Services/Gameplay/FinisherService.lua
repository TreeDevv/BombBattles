local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FinisherConfig = require(ReplicatedStorage.Shared.Config.FinisherConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local DataService = require(script.Parent.DataService)

local OWNED_KEY = Schema.OwnedFinishers and Schema.OwnedFinishers.key or "ownedFinishers"
local COPIES_KEY = Schema.FinisherCopies and Schema.FinisherCopies.key or "finisherCopies"
local EQUIPPED_KEY = Schema.EquippedFinisher and Schema.EquippedFinisher.key or "equippedFinisher"
local DEFAULT_FINISHER_ID = FinisherConfig.DefaultFinisherId
local EQUIPPED_ATTR = FinisherConfig.AttributeName
local REMOTES_FOLDER_NAME = FinisherConfig.RemotesFolderName
local PLAYED_REMOTE_NAME = FinisherConfig.PlayedRemoteName
local REQUEST_REMOTE_NAME = FinisherConfig.InventoryRequestRemoteName
local ACTIONS = FinisherConfig.InventoryActions

local MAX_REQUESTS_PER_SECOND = 12

type RequestWindow = {
	startedAt: number,
	count: number,
}

local FinisherService = {}

local playedRemote: RemoteEvent? = nil
local requestRemote: RemoteEvent? = nil
local requestWindows: { [Player]: RequestWindow } = {}
local roundService = nil

local function ensurePlayedRemote(): RemoteEvent
	playedRemote = RemoteUtil.EnsureRemoteEventInFolder(ReplicatedStorage, REMOTES_FOLDER_NAME, PLAYED_REMOTE_NAME, true)
	return playedRemote :: RemoteEvent
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, REMOTES_FOLDER_NAME)
end

local function ensureRequestRemote(): RemoteEvent
	requestRemote = RemoteUtil.EnsureRemoteEvent(ensureRemotesFolder(), REQUEST_REMOTE_NAME)
	return requestRemote :: RemoteEvent
end

local function isPlainString(value: any, maxLength: number): boolean
	return typeof(value) == "string" and value ~= "" and #value <= maxLength
end

local function isRateLimited(player: Player): boolean
	local currentTime = os.clock()
	local window = requestWindows[player]
	if not window or currentTime - window.startedAt >= 1 then
		requestWindows[player] = {
			startedAt = currentTime,
			count = 1,
		}
		return false
	end

	window.count += 1
	return window.count > MAX_REQUESTS_PER_SECOND
end

local function getRoundService()
	if not roundService then
		roundService = require(script.Parent.RoundService)
	end

	return roundService
end

local function isInventoryLocked(player: Player): boolean
	local service = getRoundService()
	local state = service:GetState()
	local stateName = typeof(state) == "table" and state.state or nil
	local lockedRoundState = stateName == RoundStates.AssigningTeams
		or stateName == RoundStates.RoundStarting
		or stateName == RoundStates.Active
	return lockedRoundState and service:IsPlayerInCurrentRound(player)
end

local function normalizeOwnedFinishers(value): ({ [string]: boolean }, boolean)
	local owned = {}
	local changed = false

	if typeof(value) ~= "table" then
		changed = value ~= nil
	else
		for key, child in pairs(value) do
			local rawFinisherId = nil
			if typeof(key) == "string" and child == true then
				rawFinisherId = key
			elseif typeof(child) == "string" then
				rawFinisherId = child
			else
				changed = true
			end

			local finisherId = FinisherConfig.NormalizeFinisherId(rawFinisherId)
			if finisherId ~= "" then
				owned[finisherId] = true
				if finisherId ~= rawFinisherId or child ~= true then
					changed = true
				end
			else
				changed = true
			end
		end
	end

	return owned, changed
end

local function normalizeFinisherCopies(value, ownedFinishers): ({ [string]: number }, boolean)
	local copies = {}
	local changed = false

	if typeof(value) ~= "table" then
		changed = value ~= nil
	else
		for rawFinisherId, rawCount in pairs(value) do
			local finisherId = FinisherConfig.NormalizeFinisherId(rawFinisherId)
			local count = math.floor(tonumber(rawCount) or 0)
			if finisherId ~= "" and count > 0 then
				copies[finisherId] = (copies[finisherId] or 0) + count
				if finisherId ~= rawFinisherId or count ~= rawCount then
					changed = true
				end
			else
				changed = true
			end
		end
	end

	for finisherId in pairs(ownedFinishers or {}) do
		if (copies[finisherId] or 0) < 1 then
			copies[finisherId] = 1
			changed = true
		end
	end

	return copies, changed
end

local function mapMatches(left, right): boolean
	if typeof(right) ~= "table" then
		return false
	end

	for key, value in pairs(left) do
		if right[key] ~= value then
			return false
		end
	end
	for key in pairs(right) do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function resolveEquippedFinisher(value, ownedFinishers): (string, boolean)
	local finisherId = FinisherConfig.NormalizeFinisherId(value)
	if finisherId ~= "" and ownedFinishers[finisherId] == true then
		return finisherId, finisherId ~= value
	end

	return DEFAULT_FINISHER_ID, value ~= DEFAULT_FINISHER_ID
end

local function setEquippedAttribute(player: Player, finisherId: string)
	if finisherId == "" then
		player:SetAttribute(EQUIPPED_ATTR, nil)
	else
		player:SetAttribute(EQUIPPED_ATTR, finisherId)
	end
end

local function sanitizePlayerData(player: Player): string
	local data = DataService:Get(player)
	if typeof(data) ~= "table" then
		setEquippedAttribute(player, DEFAULT_FINISHER_ID)
		return DEFAULT_FINISHER_ID
	end

	local ownedFinishers, ownedChanged = normalizeOwnedFinishers(data[OWNED_KEY])
	local finisherCopies, copiesChanged = normalizeFinisherCopies(data[COPIES_KEY], ownedFinishers)
	local equippedFinisher, equippedChanged = resolveEquippedFinisher(data[EQUIPPED_KEY], ownedFinishers)

	if ownedChanged or not mapMatches(ownedFinishers, data[OWNED_KEY] or {}) then
		DataService:Set(player, OWNED_KEY, ownedFinishers)
	end
	if copiesChanged or not mapMatches(finisherCopies, data[COPIES_KEY] or {}) then
		DataService:Set(player, COPIES_KEY, finisherCopies)
	end
	if equippedChanged or data[EQUIPPED_KEY] ~= equippedFinisher then
		DataService:Set(player, EQUIPPED_KEY, equippedFinisher)
	end

	setEquippedAttribute(player, equippedFinisher)
	return equippedFinisher
end

local function respond(player: Player, request, ok: boolean, code: string, message: string?)
	local remote = requestRemote
	if not remote then
		return
	end

	local action = nil
	local finisherId = nil
	if typeof(request) == "table" then
		action = request.action
		finisherId = request.finisherId
	end

	remote:FireClient(player, {
		action = action,
		finisherId = finisherId,
		ok = ok,
		code = code,
		message = message,
	})
end

local function fail(player: Player, request, code: string, message: string?)
	respond(player, request, false, code, message)
	if message and message ~= "" then
		Notify.Send(player, message, { color = "Red" })
	end
end

local function resolveRequest(request)
	if typeof(request) ~= "table" then
		return nil
	end

	local action = request.action
	if not isPlainString(action, FinisherConfig.MaxInventoryActionLength) then
		return nil
	end
	if action ~= ACTIONS.Equip then
		return nil
	end

	local finisherId = request.finisherId
	if isPlainString(finisherId, FinisherConfig.MaxFinisherIdLength) then
		finisherId = FinisherConfig.NormalizeFinisherId(finisherId)
	else
		finisherId = ""
	end

	local definition = if finisherId ~= "" then FinisherConfig.GetDefinition(finisherId) else nil
	if not (definition and FinisherConfig.IsKnownFinisherId(finisherId)) then
		return nil
	end

	return {
		action = action,
		finisherId = finisherId,
		definition = definition,
	}
end

local function handleRequest(player: Player, rawRequest)
	if isRateLimited(player) then
		return
	end

	local request = resolveRequest(rawRequest)
	if not request then
		fail(player, rawRequest, "InvalidRequest", "Invalid finisher request.")
		return
	end
	if isInventoryLocked(player) then
		fail(player, request, "InventoryLocked", "Inventory is locked during battle.")
		return
	end

	local ok, message = FinisherService:EquipFinisher(player, request.finisherId)
	if not ok then
		fail(player, request, "EquipFailed", message or "Finisher equip failed.")
		return
	end

	respond(player, request, true, "Equipped")
end

function FinisherService:GetEquippedFinisherId(player: Player): string
	if not (player and player.Parent == Players) then
		return DEFAULT_FINISHER_ID
	end

	local finisherId = FinisherConfig.NormalizeFinisherId(player:GetAttribute(EQUIPPED_ATTR))
	if finisherId ~= "" then
		return finisherId
	end

	return sanitizePlayerData(player)
end

function FinisherService:GetOwnedFinishers(player: Player): { [string]: boolean }
	local data = DataService:Get(player)
	if typeof(data) ~= "table" then
		return {}
	end

	local ownedFinishers = normalizeOwnedFinishers(data[OWNED_KEY])
	return ownedFinishers
end

function FinisherService:EquipFinisher(player: Player, rawFinisherId: any): (boolean, string?, any?)
	if not (player and player.Parent == Players) then
		return false, "Target player is not in this server", nil
	end

	local finisherId = FinisherConfig.NormalizeFinisherId(rawFinisherId)
	local definition = FinisherConfig.GetDefinition(finisherId)
	if not definition then
		return false, "Unknown finisher: " .. tostring(rawFinisherId), nil
	end

	local ownedFinishers = self:GetOwnedFinishers(player)
	if ownedFinishers[finisherId] ~= true then
		return false, "You do not own this finisher.", nil
	end

	DataService:Set(player, EQUIPPED_KEY, finisherId)
	setEquippedAttribute(player, finisherId)

	return true, nil, {
		finisherId = finisherId,
		definition = definition,
	}
end

function FinisherService:GrantFinisher(player: Player, rawFinisherId: any, source: string?): (boolean, any)
	if not (player and player.Parent == Players) then
		return false, "Target player is not in this server"
	end

	local finisherId = FinisherConfig.NormalizeFinisherId(rawFinisherId)
	local definition = FinisherConfig.GetDefinition(finisherId)
	if not definition then
		return false, "Unknown finisher: " .. tostring(rawFinisherId)
	end

	local ownedBefore = self:GetOwnedFinishers(player)
	local wasOwned = ownedBefore[finisherId] == true
	DataService:Set(player, OWNED_KEY, function(currentValue)
		local ownedFinishers = normalizeOwnedFinishers(currentValue)
		ownedFinishers[finisherId] = true
		return ownedFinishers
	end)

	local copyCount = 1
	DataService:Set(player, COPIES_KEY, function(currentValue)
		local finisherCopies = normalizeFinisherCopies(currentValue, ownedBefore)
		local previousCount = finisherCopies[finisherId] or (if wasOwned then 1 else 0)
		copyCount = previousCount + 1
		finisherCopies[finisherId] = copyCount
		return finisherCopies
	end)

	return true, {
		finisherId = finisherId,
		definition = definition,
		source = source,
		isNew = not wasOwned,
		copyCount = copyCount,
	}
end

function FinisherService:AdminGrantAndEquipFinisher(player: Player, rawFinisherId: any): (boolean, string?)
	local ok, grantResult = self:GrantFinisher(player, rawFinisherId, "Admin")
	if not ok then
		return false, grantResult
	end

	DataService:Set(player, EQUIPPED_KEY, grantResult.finisherId)
	setEquippedAttribute(player, grantResult.finisherId)

	return true, "Equipped finisher " .. grantResult.definition.displayName .. " for " .. player.Name
end

function FinisherService:FireFinisherPlayed(payload): boolean
	if typeof(payload) ~= "table" then
		return false
	end
	if FinisherConfig.NormalizeFinisherId(payload.finisherId) == "" then
		return false
	end
	if typeof(payload.position) ~= "Vector3" then
		return false
	end

	local remote = playedRemote or ensurePlayedRemote()
	remote:FireAllClients(payload)
	return true
end

function FinisherService:OnStart()
	ensurePlayedRemote()
	requestRemote = ensureRequestRemote()
	requestRemote.OnServerEvent:Connect(handleRequest)
end

function FinisherService:OnPlayerAdded(player: Player)
	sanitizePlayerData(player)
end

function FinisherService:OnPlayerRemoving(player: Player)
	requestWindows[player] = nil
	player:SetAttribute(EQUIPPED_ATTR, nil)
end

return FinisherService
