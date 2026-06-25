local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HighlightIntroConfig = require(ReplicatedStorage.Shared.Config.HighlightIntroConfig)
local RoundStates = require(ReplicatedStorage.Shared.Config.RoundStates)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local DataService = require(script.Parent.DataService)

local OWNED_KEY = Schema.OwnedHighlightIntros and Schema.OwnedHighlightIntros.key or "ownedHighlightIntros"
local COPIES_KEY = Schema.HighlightIntroCopies and Schema.HighlightIntroCopies.key or "highlightIntroCopies"
local EQUIPPED_KEY = Schema.EquippedHighlightIntro and Schema.EquippedHighlightIntro.key or "equippedHighlightIntro"
local DEFAULT_INTRO_ID = HighlightIntroConfig.DefaultHighlightIntroId
local EQUIPPED_ATTR = HighlightIntroConfig.AttributeName
local REMOTES_FOLDER_NAME = HighlightIntroConfig.RemotesFolderName
local REQUEST_REMOTE_NAME = HighlightIntroConfig.InventoryRequestRemoteName
local ACTIONS = HighlightIntroConfig.InventoryActions

local MAX_REQUESTS_PER_SECOND = 12

type RequestWindow = {
	startedAt: number,
	count: number,
}

local HighlightIntroService = {}

local requestRemote: RemoteEvent? = nil
local requestWindows: { [Player]: RequestWindow } = {}
local roundService = nil

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

local function normalizeOwnedHighlightIntros(value): ({ [string]: boolean }, boolean)
	local owned = {}
	local changed = false

	if typeof(value) ~= "table" then
		changed = value ~= nil
	else
		for key, child in pairs(value) do
			local rawIntroId = nil
			if typeof(key) == "string" and child == true then
				rawIntroId = key
			elseif typeof(child) == "string" then
				rawIntroId = child
			else
				changed = true
			end

			local introId = HighlightIntroConfig.NormalizeHighlightIntroId(rawIntroId)
			if introId ~= "" then
				owned[introId] = true
				if introId ~= rawIntroId or child ~= true then
					changed = true
				end
			else
				changed = true
			end
		end
	end

	for _, introId in ipairs(HighlightIntroConfig.GetCatalogIds()) do
		if owned[introId] ~= true then
			owned[introId] = true
			changed = true
		end
	end

	return owned, changed
end

local function normalizeHighlightIntroCopies(value, ownedIntros): ({ [string]: number }, boolean)
	local copies = {}
	local changed = false

	if typeof(value) ~= "table" then
		changed = value ~= nil
	else
		for rawIntroId, rawCount in pairs(value) do
			local introId = HighlightIntroConfig.NormalizeHighlightIntroId(rawIntroId)
			local count = math.floor(tonumber(rawCount) or 0)
			if introId ~= "" and count > 0 then
				copies[introId] = (copies[introId] or 0) + count
				if introId ~= rawIntroId or count ~= rawCount then
					changed = true
				end
			else
				changed = true
			end
		end
	end

	for introId in pairs(ownedIntros or {}) do
		if (copies[introId] or 0) < 1 then
			copies[introId] = 1
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

local function resolveEquippedHighlightIntro(value, ownedIntros): (string, boolean)
	local introId = HighlightIntroConfig.NormalizeHighlightIntroId(value)
	if introId ~= "" and ownedIntros[introId] == true then
		return introId, introId ~= value
	end

	return DEFAULT_INTRO_ID, value ~= DEFAULT_INTRO_ID
end

local function setEquippedAttribute(player: Player, introId: string)
	player:SetAttribute(EQUIPPED_ATTR, introId)
end

local function sanitizePlayerData(player: Player): string
	local data = DataService:Get(player)
	if typeof(data) ~= "table" then
		setEquippedAttribute(player, DEFAULT_INTRO_ID)
		return DEFAULT_INTRO_ID
	end

	local ownedIntros, ownedChanged = normalizeOwnedHighlightIntros(data[OWNED_KEY])
	local introCopies, copiesChanged = normalizeHighlightIntroCopies(data[COPIES_KEY], ownedIntros)
	local equippedIntro, equippedChanged = resolveEquippedHighlightIntro(data[EQUIPPED_KEY], ownedIntros)

	if ownedChanged or not mapMatches(ownedIntros, data[OWNED_KEY] or {}) then
		DataService:Set(player, OWNED_KEY, ownedIntros)
	end
	if copiesChanged or not mapMatches(introCopies, data[COPIES_KEY] or {}) then
		DataService:Set(player, COPIES_KEY, introCopies)
	end
	if equippedChanged or data[EQUIPPED_KEY] ~= equippedIntro then
		DataService:Set(player, EQUIPPED_KEY, equippedIntro)
	end

	setEquippedAttribute(player, equippedIntro)
	return equippedIntro
end

local function respond(player: Player, request, ok: boolean, code: string, message: string?, extra)
	local remote = requestRemote
	if not remote then
		return
	end

	local action = nil
	local highlightIntroId = nil
	if typeof(request) == "table" then
		action = request.action
		highlightIntroId = request.highlightIntroId
	end

	local response = {
		action = action,
		highlightIntroId = highlightIntroId,
		ok = ok,
		code = code,
		message = message,
	}
	if typeof(extra) == "table" then
		for key, value in pairs(extra) do
			response[key] = value
		end
	end

	remote:FireClient(player, response)
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
	if not isPlainString(action, HighlightIntroConfig.MaxInventoryActionLength) then
		return nil
	end
	if action ~= ACTIONS.Equip then
		return nil
	end

	local introId = request.highlightIntroId
	if isPlainString(introId, HighlightIntroConfig.MaxHighlightIntroIdLength) then
		introId = HighlightIntroConfig.NormalizeHighlightIntroId(introId)
	else
		introId = ""
	end

	local definition = if introId ~= "" then HighlightIntroConfig.GetDefinition(introId) else nil
	if not (definition and HighlightIntroConfig.IsKnownHighlightIntroId(introId)) then
		return nil
	end

	return {
		action = action,
		highlightIntroId = introId,
		definition = definition,
	}
end

local function handleRequest(player: Player, rawRequest)
	if isRateLimited(player) then
		return
	end

	local request = resolveRequest(rawRequest)
	if not request then
		fail(player, rawRequest, "InvalidRequest", "Invalid highlight intro request.")
		return
	end
	if isInventoryLocked(player) then
		fail(player, request, "InventoryLocked", "Inventory is locked during battle.")
		return
	end

	local ok, message, equipResult = HighlightIntroService:EquipHighlightIntro(player, request.highlightIntroId)
	if not ok then
		fail(player, request, "EquipFailed", message or "Highlight intro equip failed.")
		return
	end

	respond(player, request, true, "Equipped", nil, {
		equippedHighlightIntroId = if typeof(equipResult) == "table" then equipResult.highlightIntroId else request.highlightIntroId,
	})
end

function HighlightIntroService:GetEquippedHighlightIntroId(player: Player): string
	if not (player and player.Parent == Players) then
		return DEFAULT_INTRO_ID
	end

	local introId = HighlightIntroConfig.NormalizeHighlightIntroId(player:GetAttribute(EQUIPPED_ATTR))
	if introId ~= "" then
		return introId
	end

	return sanitizePlayerData(player)
end

function HighlightIntroService:GetOwnedHighlightIntros(player: Player): { [string]: boolean }
	local data = DataService:Get(player)
	if typeof(data) ~= "table" then
		local owned = {}
		for _, introId in ipairs(HighlightIntroConfig.GetCatalogIds()) do
			owned[introId] = true
		end
		return owned
	end

	local ownedIntros = normalizeOwnedHighlightIntros(data[OWNED_KEY])
	return ownedIntros
end

function HighlightIntroService:EquipHighlightIntro(player: Player, rawIntroId: any): (boolean, string?, any?)
	if not (player and player.Parent == Players) then
		return false, "Target player is not in this server", nil
	end

	local introId = HighlightIntroConfig.NormalizeHighlightIntroId(rawIntroId)
	local definition = HighlightIntroConfig.GetDefinition(introId)
	if not definition then
		return false, "Unknown highlight intro: " .. tostring(rawIntroId), nil
	end

	local ownedIntros = self:GetOwnedHighlightIntros(player)
	if ownedIntros[introId] ~= true then
		return false, "You do not own this highlight intro.", nil
	end

	DataService:Set(player, EQUIPPED_KEY, introId)
	setEquippedAttribute(player, introId)

	return true, nil, {
		highlightIntroId = introId,
		definition = definition,
	}
end

function HighlightIntroService:OnStart()
	requestRemote = ensureRequestRemote()
	requestRemote.OnServerEvent:Connect(handleRequest)
end

function HighlightIntroService:OnPlayerAdded(player: Player)
	sanitizePlayerData(player)
end

function HighlightIntroService:OnPlayerRemoving(player: Player)
	requestWindows[player] = nil
	player:SetAttribute(EQUIPPED_ATTR, nil)
end

return HighlightIntroService
