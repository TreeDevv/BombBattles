local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local EmoteConfig = require(ReplicatedStorage.Shared.Emotes.EmoteConfig)

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
	local existing = ReplicatedStorage:FindFirstChild(EmoteConfig.RemotesFolderName)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = EmoteConfig.RemotesFolderName
	folder.Parent = ReplicatedStorage
	return folder
end

local function ensureRemote(name: string): RemoteEvent
	local folder = ensureRemotesFolder()
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
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
	return window.count > 12
end

local function sendSnapshot(player: Player)
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
