local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local RoundController = require(script.Parent:WaitForChild("RoundController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local REMOTES_FOLDER_NAME = "Remotes"
local KILL_FEED_REMOTE_NAME = "KillFeed"
local HUD_NAME = "HUD"
local TEMPLATE_NAME = "KillEffectTemplate"
local LEGACY_SCREEN_GUI_NAME = "KillEffect"
local LEGACY_TEMPLATE_PATH = { "Controls", "KillEffect" }
local DEFAULT_CELLS = Vector2.new(5, 5)
local DEFAULT_FPS = 40
local IN_TWEEN_SECONDS = 0.625
local OUT_TWEEN_SECONDS = 0.2
local SKULL_IN_SIZE = UDim2.fromScale(0.2, 0.2)
local SKULL_OUT_SIZE = UDim2.fromScale(0.1, 0.1)
local SPRITE_TICK_YIELD = 0
local IN_TWEEN = TweenInfo.new(IN_TWEEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OUT_TWEEN = TweenInfo.new(OUT_TWEEN_SECONDS, Enum.EasingStyle.Quad)

local KillEffectController = {}

KillEffectController._connections = {} :: { RBXScriptConnection }
KillEffectController._hud = nil :: ScreenGui?
KillEffectController._template = nil :: GuiObject?
KillEffectController._activeEffects = {} :: { [Instance]: boolean }
KillEffectController._remoteBindSerial = 0
KillEffectController._nextEffectId = 0

local function parsePositiveInteger(value: any, fallback: number): number
	if typeof(value) ~= "number" then
		return fallback
	end

	value = math.floor(value)
	if value <= 0 then
		return fallback
	end

	return value
end

local function parseCells(value: any): Vector2
	if typeof(value) == "Vector2" then
		return Vector2.new(
			parsePositiveInteger(value.X, DEFAULT_CELLS.X),
			parsePositiveInteger(value.Y, DEFAULT_CELLS.Y)
		)
	end

	if typeof(value) == "string" then
		local x, y = value:match("^%s*(%d+)%s*,%s*(%d+)%s*$")
		if x and y then
			return Vector2.new(parsePositiveInteger(tonumber(x), DEFAULT_CELLS.X), parsePositiveInteger(tonumber(y), DEFAULT_CELLS.Y))
		end
	end

	return DEFAULT_CELLS
end

local function isReplayUserId(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge and value > 0
end

local function findLegacyTemplate(): GuiObject?
	local legacyGui = PlayerGui:FindFirstChild(LEGACY_SCREEN_GUI_NAME)
	local current: Instance? = legacyGui
	for _, childName in ipairs(LEGACY_TEMPLATE_PATH) do
		current = if current then current:FindFirstChild(childName) else nil
	end

	return if current and current:IsA("GuiObject") then current else nil
end

local function findTemplate(hud: ScreenGui): GuiObject?
	local template = hud:FindFirstChild(TEMPLATE_NAME)
	if template and template:IsA("GuiObject") then
		return template
	end

	return findLegacyTemplate()
end

local function disableEmbeddedScripts(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BaseScript") then
			descendant.Disabled = true
		end
	end
end

local function getSpriteSettings(effect: GuiObject): (Vector2, number)
	local playSprite = effect:FindFirstChild("PlaySprite")
	if not playSprite then
		return DEFAULT_CELLS, DEFAULT_FPS
	end

	return parseCells(playSprite:GetAttribute("Cells")), parsePositiveInteger(playSprite:GetAttribute("FPS"), DEFAULT_FPS)
end

local function startSpriteAnimation(effect: any)
	local cells, fps = getSpriteSettings(effect)
	local frameSize = effect.ImageRectSize
	if frameSize.X <= 0 or frameSize.Y <= 0 then
		return
	end

	task.spawn(function()
		while effect.Parent do
			for y = 0, cells.Y - 1 do
				for x = 0, cells.X - 1 do
					if not effect.Parent then
						return
					end

					effect.ImageRectOffset = Vector2.new(frameSize.X * x, frameSize.Y * y)
					task.wait(1 / fps)
				end
			end

			task.wait(SPRITE_TICK_YIELD)
		end
	end)
end

function KillEffectController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
end

function KillEffectController:_destroyEffect(effect: Instance)
	self._activeEffects[effect] = nil
	if effect.Parent then
		effect:Destroy()
	end
end

function KillEffectController:_clearEffects()
	for effect in pairs(self._activeEffects) do
		self:_destroyEffect(effect)
	end
	self._activeEffects = {}
end

function KillEffectController:_disconnectAll()
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end

	self._connections = {}
	self._remoteBindSerial += 1
	self._hud = nil
	self._template = nil
	self:_clearEffects()
end

function KillEffectController:_bindHud(hud: Instance?)
	if not (hud and hud:IsA("ScreenGui")) then
		self._hud = nil
		self._template = nil
		return
	end

	self._hud = hud
	self._template = findTemplate(hud)
	if self._template then
		self._template.Visible = false
		disableEmbeddedScripts(self._template)
	end
end

function KillEffectController:_bindCurrentHud()
	self:_bindHud(PlayerGui:FindFirstChild(HUD_NAME))
end

function KillEffectController:_shouldAcceptPayload(payload): boolean
	if typeof(payload) ~= "table" then
		return false
	end

	if payload.killerUserId ~= LocalPlayer.UserId then
		return false
	end

	local killerTeam = payload.killerTeam
	local victimTeam = payload.victimTeam
	if typeof(killerTeam) ~= "string" or typeof(victimTeam) ~= "string" or killerTeam == victimTeam then
		return false
	end

	local payloadRoundId = payload.roundId
	local currentRoundId = RoundController:Get("roundId")
	if typeof(payloadRoundId) == "number" and typeof(currentRoundId) == "number" and payloadRoundId ~= currentRoundId then
		return false
	end

	return true
end

function KillEffectController:_playEffect(): boolean
	local hud = self._hud
	local template = self._template
	if not (hud and hud.Parent and template and template.Parent) then
		self:_bindCurrentHud()
		hud = self._hud
		template = self._template
	end
	if not (hud and hud.Parent and template and template.Parent) then
		return false
	end

	self._nextEffectId += 1
	local effect = template:Clone()
	effect.Name = string.format("KillEffect_%06d", self._nextEffectId)
	effect.Visible = true
	disableEmbeddedScripts(effect)
	effect.Parent = hud
	self._activeEffects[effect] = true

	if effect:IsA("ImageLabel") or effect:IsA("ImageButton") then
		local imageEffect = effect :: any
		imageEffect.ImageTransparency = 0
		imageEffect.ImageRectOffset = Vector2.zero
		startSpriteAnimation(imageEffect)
	end

	local skull = effect:FindFirstChild("Skull")
	local skullImage = if skull and (skull:IsA("ImageLabel") or skull:IsA("ImageButton")) then skull else nil
	if skullImage then
		skullImage.Size = UDim2.fromScale(0, 0)
		skullImage.ImageTransparency = 1
		TweenService:Create(skullImage, IN_TWEEN, {
			Size = SKULL_IN_SIZE,
			ImageTransparency = 0.2,
		}):Play()
	end

	task.delay(IN_TWEEN_SECONDS, function()
		if not effect.Parent then
			return
		end

		if skullImage and skullImage.Parent then
			TweenService:Create(skullImage, OUT_TWEEN, {
				Size = SKULL_OUT_SIZE,
				ImageTransparency = 1,
			}):Play()
		end
		if effect:IsA("ImageLabel") or effect:IsA("ImageButton") then
			local imageEffect = effect :: any
			imageEffect.ImageTransparency = 1
		end

		task.delay(OUT_TWEEN_SECONDS, function()
			self:_destroyEffect(effect)
		end)
	end)
	return true
end

function KillEffectController:PlayReplayKillEffect(payload): boolean
	if typeof(payload) ~= "table" then
		return false
	end
	if not isReplayUserId(payload.killerUserId) or not isReplayUserId(payload.victimUserId) then
		return false
	end
	if payload.killerUserId == payload.victimUserId then
		return false
	end

	return self:_playEffect()
end

function KillEffectController:_bindRemote()
	self._remoteBindSerial += 1
	local serial = self._remoteBindSerial

	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, 10)
		if serial ~= self._remoteBindSerial or not remotes then
			return
		end

		local remote = remotes:WaitForChild(KILL_FEED_REMOTE_NAME, 10)
		if serial ~= self._remoteBindSerial or not (remote and remote:IsA("RemoteEvent")) then
			return
		end

		self:_trackConnection(remote.OnClientEvent:Connect(function(payload)
			if self:_shouldAcceptPayload(payload) then
				self:_playEffect()
			end
		end))
	end)
end

function KillEffectController:OnStart()
	self:_disconnectAll()

	self:_trackConnection(PlayerGui.ChildAdded:Connect(function(child)
		if child.Name == HUD_NAME then
			task.defer(function()
				self:_bindHud(child)
			end)
		end
	end))

	self:_trackConnection(PlayerGui.ChildRemoved:Connect(function(child)
		if child == self._hud then
			self._hud = nil
			self._template = nil
			self:_clearEffects()
		end
	end))

	self:_bindCurrentHud()
	self:_bindRemote()
end

return KillEffectController
