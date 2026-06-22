local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EmoteConfig = require(ReplicatedStorage.Shared.Emotes.EmoteConfig)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)
local Schema = require(ReplicatedStorage.Shared.Config.Lists.Schema)

local DataService = require(script.Parent.DataService)

local ORDER_KEY = Schema.EmoteOrder and Schema.EmoteOrder.key or "emoteOrder"
local FAVORITES_KEY = Schema.FavoriteEmotes and Schema.FavoriteEmotes.key or "favoriteEmotes"
local MAX_REQUESTS_PER_SECOND = 12

type ActiveEmote = {
	player: Player,
	emoteId: string,
	startedAt: number,
	startedRoundAlive: boolean,
	originalWalkSpeed: number,
	originalJumpHeight: number?,
	originalJumpPower: number?,
	originalAutoRotate: boolean,
	lastHealth: number,
	connections: { RBXScriptConnection },
}

local EmoteService = {}

local requestRemote: RemoteEvent? = nil
local stateRemote: RemoteEvent? = nil
local heartbeatConnection: RBXScriptConnection? = nil
local activeByPlayer: { [Player]: ActiveEmote } = {}
local requestWindows: { [Player]: { startedAt: number, count: number } } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function ensureRemotesFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, EmoteConfig.RemotesFolderName)
end

local function ensureRemote(name: string): RemoteEvent
	return RemoteUtil.EnsureRemoteEvent(ensureRemotesFolder(), name)
end

local function tablesArrayMatch(left: { string }, right: any): boolean
	if typeof(right) ~= "table" or #left ~= #right then
		return false
	end

	for index, emoteId in ipairs(left) do
		if right[index] ~= emoteId then
			return false
		end
	end
	return true
end

local function tablesMapMatch(left: { [string]: boolean }, right: any): boolean
	if typeof(right) ~= "table" then
		return false
	end

	for emoteId, value in pairs(left) do
		if right[emoteId] ~= value then
			return false
		end
	end
	for emoteId, value in pairs(right) do
		if left[emoteId] ~= value then
			return false
		end
	end
	return true
end

local function normalizeEmoteOrder(rawOrder: any): ({ string }, boolean)
	local catalogIds = EmoteConfig.GetCatalogIds()
	local known: { [string]: boolean } = {}
	for _, emoteId in ipairs(catalogIds) do
		known[emoteId] = true
	end

	local order = {}
	local seen: { [string]: boolean } = {}
	local changed = typeof(rawOrder) ~= "table"

	if typeof(rawOrder) == "table" then
		for _, rawEmoteId in ipairs(rawOrder) do
			local emoteId = EmoteConfig.NormalizeEmoteId(rawEmoteId)
			if emoteId ~= "" and known[emoteId] and not seen[emoteId] then
				table.insert(order, emoteId)
				seen[emoteId] = true
				if emoteId ~= rawEmoteId then
					changed = true
				end
			else
				changed = true
			end
		end
	end

	for _, emoteId in ipairs(catalogIds) do
		if not seen[emoteId] then
			table.insert(order, emoteId)
			seen[emoteId] = true
			changed = true
		end
	end

	if not tablesArrayMatch(order, rawOrder) then
		changed = true
	end

	return order, changed
end

local function normalizeFavorites(rawFavorites: any): ({ [string]: boolean }, boolean)
	local favorites = {}
	local changed = typeof(rawFavorites) ~= "table"

	if typeof(rawFavorites) == "table" then
		for rawEmoteId, value in pairs(rawFavorites) do
			local emoteId = EmoteConfig.NormalizeEmoteId(rawEmoteId)
			if emoteId ~= "" and value == true then
				favorites[emoteId] = true
				if emoteId ~= rawEmoteId then
					changed = true
				end
			elseif value ~= nil then
				changed = true
			end
		end
	end

	if not tablesMapMatch(favorites, rawFavorites) then
		changed = true
	end

	return favorites, changed
end

local function sanitizePlayerEmoteData(player: Player): ({ string }, { [string]: boolean })
	local data = DataService:Get(player)
	local rawOrder = if typeof(data) == "table" then data[ORDER_KEY] else nil
	local rawFavorites = if typeof(data) == "table" then data[FAVORITES_KEY] else nil
	local order, orderChanged = normalizeEmoteOrder(rawOrder)
	local favorites, favoritesChanged = normalizeFavorites(rawFavorites)

	if orderChanged then
		DataService:Set(player, ORDER_KEY, order)
	end
	if favoritesChanged then
		DataService:Set(player, FAVORITES_KEY, favorites)
	end

	return order, favorites
end

local function respondInventory(player: Player, request: any, ok: boolean, code: string, message: string?)
	local remote = requestRemote
	if not remote then
		return
	end

	local action = nil
	local emoteId = nil
	if typeof(request) == "table" then
		action = request.action
		emoteId = request.emoteId
	end

	remote:FireClient(player, {
		action = action,
		emoteId = emoteId,
		ok = ok,
		code = code,
		message = message,
	})
end

local function failInventory(player: Player, request: any, code: string, message: string?)
	respondInventory(player, request, false, code, message)
end

local function getCharacterParts(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	return character, humanoid, if rootPart and rootPart:IsA("BasePart") then rootPart else nil
end

local function getStartFailureReason(player: Player): string?
	if player.Parent ~= Players then
		return "PlayerLeft"
	end

	local character, humanoid, rootPart = getCharacterParts(player)
	if not character then
		return "NoCharacter"
	end
	if not humanoid then
		return "NoHumanoid"
	end
	if humanoid.Health <= 0 then
		return "Dead"
	end
	if not rootPart then
		return "NoRootPart"
	end

	return nil
end

local function fireState(target: Player?, eventName: string, payload: any)
	local remote = stateRemote
	if not remote then
		return
	end

	if target then
		remote:FireClient(target, eventName, payload)
	else
		remote:FireAllClients(eventName, payload)
	end
end

local function rejectStart(player: Player, emoteId: any, reason: string)
	fireState(player, "Rejected", {
		player = player,
		emoteId = emoteId,
		reason = reason,
		serverTime = now(),
	})
end

local function restoreHumanoid(state: ActiveEmote)
	local _, humanoid = getCharacterParts(state.player)
	if not humanoid then
		return
	end

	humanoid.WalkSpeed = state.originalWalkSpeed
	humanoid.AutoRotate = state.originalAutoRotate
	if state.originalJumpHeight ~= nil then
		humanoid.JumpHeight = state.originalJumpHeight
	end
	if state.originalJumpPower ~= nil then
		humanoid.JumpPower = state.originalJumpPower
	end
end

local function disconnectState(state: ActiveEmote)
	for _, connection in ipairs(state.connections) do
		connection:Disconnect()
	end
	table.clear(state.connections)
end

local function stopEmote(player: Player, reason: string?)
	local state = activeByPlayer[player]
	if not state then
		return false
	end

	activeByPlayer[player] = nil
	disconnectState(state)
	restoreHumanoid(state)
	player:SetAttribute("Emote_ActiveId", "")
	player:SetAttribute("Emote_StartedAt", 0)

	fireState(nil, "Stop", {
		player = player,
		emoteId = state.emoteId,
		reason = reason or "Stopped",
		stoppedAt = now(),
	})
	return true
end

local function cancelOnInterrupt(player: Player, reason: string)
	if activeByPlayer[player] then
		stopEmote(player, reason)
	end
end

local function bindInterrupts(state: ActiveEmote, humanoid: Humanoid, character: Model)
	table.insert(state.connections, humanoid.Running:Connect(function(speed: number)
		if now() - state.startedAt < EmoteConfig.MovementCancelGraceSeconds then
			return
		end
		if math.abs(speed) > EmoteConfig.CancelMoveSpeed then
			cancelOnInterrupt(state.player, "Movement")
		end
	end))

	table.insert(state.connections, humanoid.StateChanged:Connect(function(_, newState)
		if newState == Enum.HumanoidStateType.Jumping or newState == Enum.HumanoidStateType.Freefall then
			cancelOnInterrupt(state.player, "Movement")
		end
	end))

	table.insert(state.connections, humanoid.HealthChanged:Connect(function(health: number)
		if health < state.lastHealth then
			cancelOnInterrupt(state.player, "Damage")
		end
		state.lastHealth = health
	end))

	table.insert(state.connections, humanoid.Died:Connect(function()
		cancelOnInterrupt(state.player, "Death")
	end))

	table.insert(state.connections, character.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			cancelOnInterrupt(state.player, "CharacterRemoved")
		end
	end))

	table.insert(state.connections, state.player:GetAttributeChangedSignal("RoundAlive"):Connect(function()
		if state.startedRoundAlive and state.player:GetAttribute("RoundAlive") ~= true then
			cancelOnInterrupt(state.player, "RoundEnded")
		end
	end))
end

local function applyHumanoidLock(humanoid: Humanoid, definition: any): (number, number?, number?, boolean)
	local originalWalkSpeed = humanoid.WalkSpeed
	local originalJumpHeight = humanoid.JumpHeight
	local originalJumpPower = humanoid.JumpPower
	local originalAutoRotate = humanoid.AutoRotate

	humanoid.WalkSpeed = math.max(tonumber(definition.walkSpeed) or EmoteConfig.DefaultWalkSpeed, 0)
	if humanoid.UseJumpPower then
		humanoid.JumpPower = 0
	else
		humanoid.JumpHeight = 0
	end
	humanoid.AutoRotate = if typeof(definition.autoRotate) == "boolean" then definition.autoRotate else EmoteConfig.DefaultAutoRotate

	return originalWalkSpeed, originalJumpHeight, originalJumpPower, originalAutoRotate
end

local function startEmote(player: Player, emoteId: string)
	if not EmoteConfig.IsKnownEmoteId(emoteId) then
		rejectStart(player, emoteId, "UnknownEmote")
		return
	end

	local startFailureReason = getStartFailureReason(player)
	if startFailureReason then
		rejectStart(player, emoteId, startFailureReason)
		return
	end

	local asset = EmoteConfig.GetAssetFolder(emoteId)
	if not asset then
		warn("[EmoteService] Missing emote asset folder for " .. emoteId)
		rejectStart(player, emoteId, "MissingAsset")
		return
	end

	stopEmote(player, "Replaced")

	local character, humanoid = getCharacterParts(player)
	local definition = EmoteConfig.GetDefinition(emoteId)
	if not (character and humanoid and definition) then
		return
	end

	local originalWalkSpeed, originalJumpHeight, originalJumpPower, originalAutoRotate = applyHumanoidLock(humanoid, definition)
	local startedAt = now()
	local state: ActiveEmote = {
		player = player,
		emoteId = emoteId,
		startedAt = startedAt,
		startedRoundAlive = player:GetAttribute("RoundAlive") == true,
		originalWalkSpeed = originalWalkSpeed,
		originalJumpHeight = originalJumpHeight,
		originalJumpPower = originalJumpPower,
		originalAutoRotate = originalAutoRotate,
		lastHealth = humanoid.Health,
		connections = {},
	}

	activeByPlayer[player] = state
	player:SetAttribute("Emote_ActiveId", emoteId)
	player:SetAttribute("Emote_StartedAt", startedAt)
	bindInterrupts(state, humanoid, character)

	fireState(nil, "Start", {
		player = player,
		emoteId = emoteId,
		startedAt = startedAt,
	})
end

local function isRateLimited(player: Player): boolean
	local currentTime = now()
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

local function sendSnapshot(player: Player)
	sanitizePlayerEmoteData(player)

	for activePlayer, state in pairs(activeByPlayer) do
		if activePlayer.Parent == Players then
			fireState(player, "Start", {
				player = activePlayer,
				emoteId = state.emoteId,
				startedAt = state.startedAt,
			})
		end
	end
end

local function swapSlot(player: Player, request: any)
	local pageIndex = if typeof(request.pageIndex) == "number" then math.floor(request.pageIndex) else 0
	local slotIndex = if typeof(request.slotIndex) == "number" then math.floor(request.slotIndex) else 0
	local emoteId = EmoteConfig.NormalizeEmoteId(request.emoteId)

	if pageIndex < 1 or slotIndex < 1 or slotIndex > EmoteConfig.PageSize then
		failInventory(player, request, "InvalidSlot", "Invalid emote slot.")
		return
	end
	if emoteId == "" then
		failInventory(player, request, "InvalidEmote", "Invalid emote.")
		return
	end

	local order = sanitizePlayerEmoteData(player)
	local targetIndex = ((pageIndex - 1) * EmoteConfig.PageSize) + slotIndex
	if targetIndex < 1 or targetIndex > #order then
		failInventory(player, request, "InvalidSlot", "Invalid emote slot.")
		return
	end

	local sourceIndex = nil
	for index, orderedEmoteId in ipairs(order) do
		if orderedEmoteId == emoteId then
			sourceIndex = index
			break
		end
	end
	if not sourceIndex then
		failInventory(player, request, "InvalidEmote", "Invalid emote.")
		return
	end

	if sourceIndex ~= targetIndex then
		order[sourceIndex], order[targetIndex] = order[targetIndex], order[sourceIndex]
		DataService:Set(player, ORDER_KEY, order)
	end

	respondInventory(player, request, true, "Swapped")
end

local function toggleFavorite(player: Player, request: any)
	local emoteId = EmoteConfig.NormalizeEmoteId(request.emoteId)
	if emoteId == "" then
		failInventory(player, request, "InvalidEmote", "Invalid emote.")
		return
	end

	local _, favorites = sanitizePlayerEmoteData(player)
	favorites[emoteId] = if favorites[emoteId] == true then nil else true
	DataService:Set(player, FAVORITES_KEY, favorites)

	respondInventory(player, request, true, "FavoriteToggled")
end

local function handleRequest(player: Player, request: any)
	if isRateLimited(player) then
		return
	end
	if typeof(request) ~= "table" then
		return
	end

	local action = request.action
	if action == EmoteConfig.Actions.Start and typeof(request.emoteId) == "string" then
		startEmote(player, request.emoteId)
	elseif action == EmoteConfig.Actions.Stop then
		stopEmote(player, "Client")
	elseif action == EmoteConfig.Actions.Snapshot then
		sendSnapshot(player)
	elseif action == EmoteConfig.Actions.SwapSlots then
		swapSlot(player, request)
	elseif action == EmoteConfig.Actions.ToggleFavorite then
		toggleFavorite(player, request)
	end
end

local function stepActivePlayers()
	for player in pairs(activeByPlayer) do
		local failureReason = getStartFailureReason(player)
		if failureReason then
			stopEmote(player, "InvalidState")
		end
	end
end

function EmoteService:OnStart()
	requestRemote = ensureRemote(EmoteConfig.RequestRemoteName)
	stateRemote = ensureRemote(EmoteConfig.StateRemoteName)
	requestRemote.OnServerEvent:Connect(handleRequest)

	if heartbeatConnection then
		heartbeatConnection:Disconnect()
	end
	heartbeatConnection = RunService.Heartbeat:Connect(stepActivePlayers)
end

function EmoteService:OnPlayerAdded(player: Player)
	player:SetAttribute("Emote_ActiveId", "")
	player:SetAttribute("Emote_StartedAt", 0)
	sanitizePlayerEmoteData(player)
end

function EmoteService:OnPlayerRemoving(player: Player)
	stopEmote(player, "PlayerRemoving")
	requestWindows[player] = nil
end

function EmoteService:CancelActive(player: Player, reason: string?): boolean
	return stopEmote(player, reason or "Canceled")
end

function EmoteService:GetActiveEmote(player: Player): string?
	local state = activeByPlayer[player]
	return state and state.emoteId or nil
end

return EmoteService
