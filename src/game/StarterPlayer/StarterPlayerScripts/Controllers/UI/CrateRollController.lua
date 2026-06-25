local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local BombSkinConfig = require(ReplicatedStorage.Shared.Config.BombSkinConfig)
local CrateRollConfig = require(ReplicatedStorage.Shared.Config.CrateRollConfig)
local FinisherConfig = require(ReplicatedStorage.Shared.Config.FinisherConfig)
local SpinWheelConfig = require(ReplicatedStorage.Shared.Config.SpinWheelConfig)
local SoundUtil = require(ReplicatedStorage.Shared.Audio.SoundUtil)

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local HUD_NAME = "HUD"
local CRATE_ROLL_NAME = "CrateRoll"
local TRACK_VIEWPORT_NAME = "CrateRollTrackViewport"
local TRACK_NAME = "CrateRollTrack"
local GENERATED_ATTR = "CrateRollGenerated"
local WINNING_CARD_ATTR = "CrateRollWinningCard"
local CONTROLLER_SCALE_NAME = "CrateRollControllerScale"
local RESULT_SCALE_NAME = "CrateRollResultScale"
local CARD_SCALE_NAME = "CrateRollCardScale"
local POLISH_ATTR = "CrateRollControllerPolish"

local CARD_COUNT = 90
local WIN_INDEX_MIN = 62
local WIN_INDEX_MAX = 72
local DEFAULT_ROLL_DURATION = 4.6
local SKIP_DURATION = 0.6
local FINISHER_DURATION = 0.22
local FINISHER_PIXEL_EPSILON = 1
local ROLLBACK_OVERSHOOT_FRACTION = 0.14
local ROLLBACK_OVERSHOOT_MIN = 8
local ROLLBACK_OVERSHOOT_MAX = 14
local FINAL_REVEAL_DELAY = 0.22
local RESULT_REVIEW_SECONDS = 2.4

local RESULT_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local AUTO_CLOSE_TWEEN = TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local WINNER_POP_TWEEN = TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local WINNER_SETTLE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local WINNER_FLASH_TWEEN = TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MARKER_SCALE_NAME = "CrateRollMarkerScale"
local MARKER_PULSE_SPEED = 5.5
local TICK_PULSE_SECONDS = 0.16
local TICK_MARKER_POP_SCALE = 0.08

local TICK_SOUND_NAMES = { "CrateTick", "UITick", "Tick", "Click" }
local LOCK_SOUND_NAMES = { "CrateLock", "RewardUnlock", "Success", "Open" }
local WHOOSH_SOUND_NAMES = { "CrateWhoosh", "Whoosh" }
local RARITY_SEQUENCE = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" }

local RARITY_STYLES = {
	Common = {
		color = Color3.fromRGB(185, 202, 220),
		dark = Color3.fromRGB(39, 48, 59),
	},
	Uncommon = {
		color = Color3.fromRGB(76, 222, 128),
		dark = Color3.fromRGB(25, 79, 48),
	},
	Rare = {
		color = Color3.fromRGB(88, 166, 255),
		dark = Color3.fromRGB(28, 70, 132),
	},
	Epic = {
		color = Color3.fromRGB(187, 134, 252),
		dark = Color3.fromRGB(88, 49, 139),
	},
	Legendary = {
		color = Color3.fromRGB(255, 193, 70),
		dark = Color3.fromRGB(133, 81, 20),
	},
	Mythic = {
		color = Color3.fromRGB(255, 86, 125),
		dark = Color3.fromRGB(132, 24, 54),
	},
}

type SkinReward = {
	rewardType: string,
	itemId: string,
	skinId: string?,
	finisherId: string?,
	displayName: string,
	rarity: string,
	iconImage: string?,
}

type StrokeState = {
	stroke: UIStroke,
	color: Color3,
	transparency: number,
	thickness: number,
	isLabelStroke: boolean,
}

type CardRecord = {
	wrapper: GuiObject,
	button: GuiObject,
	icon: ImageLabel?,
	label: TextLabel?,
	back: ImageLabel?,
	scale: UIScale,
	baseButtonPosition: UDim2,
	baseIconTransparency: number,
	baseIconColor: Color3,
	baseLabelTransparency: number?,
	baseBackColor: Color3?,
	baseBackTransparency: number?,
	strokes: { StrokeState },
	reward: SkinReward,
	index: number,
}

type ReelMetrics = {
	cardWidth: number,
	cardHeight: number,
	cardStep: number,
	trackWidth: number,
	viewportCenterX: number,
}

local CrateRollController = {}

CrateRollController._connections = {} :: { RBXScriptConnection }
CrateRollController._tweens = {} :: { Tween }
CrateRollController._cards = {} :: { CardRecord }
CrateRollController._templateWrappers = {} :: { GuiObject }
CrateRollController._currentRollId = 0
CrateRollController._started = false
CrateRollController._rolling = false
CrateRollController._finishing = false
CrateRollController._skipRequested = false
CrateRollController._targetX = 0
CrateRollController._winningCard = nil :: CardRecord?
CrateRollController._lastTickIndex = nil :: number?
CrateRollController._renderConnection = nil :: RBXScriptConnection?
CrateRollController._skipConnection = nil :: RBXScriptConnection?
CrateRollController._requestRemote = nil :: RemoteFunction?
CrateRollController._resultRemote = nil :: RemoteEvent?
CrateRollController._rng = Random.new()

CrateRollController._root = nil :: Frame?
CrateRollController._scroller = nil :: ScrollingFrame?
CrateRollController._trackViewport = nil :: Frame?
CrateRollController._trackFrame = nil :: Frame?
CrateRollController._layout = nil :: UIListLayout?
CrateRollController._templateWrapper = nil :: GuiObject?
CrateRollController._sourceTemplateWrapper = nil :: GuiObject?
CrateRollController._privateTemplateWrapper = nil :: GuiObject?
CrateRollController._skipButton = nil :: GuiButton?
CrateRollController._result = nil :: Frame?
CrateRollController._resultLabel = nil :: TextLabel?
CrateRollController._centerMarker = nil :: GuiObject?
CrateRollController._rootScale = nil :: UIScale?
CrateRollController._resultScale = nil :: UIScale?
CrateRollController._centerMarkerScale = nil :: UIScale?
CrateRollController._edgeFades = {} :: { GuiObject }
CrateRollController._speedStreak = nil :: Frame?
CrateRollController._markerStroke = nil :: UIStroke?
CrateRollController._reelMetrics = nil :: ReelMetrics?
CrateRollController._tickPulseStartedAt = -math.huge
CrateRollController._tickPulseStrength = 0

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function findChild(parent: Instance?, childName: string): Instance?
	return if parent then parent:FindFirstChild(childName) else nil
end

local function findTextLabel(parent: Instance?, childName: string): TextLabel?
	local child = findChild(parent, childName)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findImageLabel(parent: Instance?, childName: string): ImageLabel?
	local child = findChild(parent, childName)
	return if child and child:IsA("ImageLabel") then child else nil
end

local function findImageButton(parent: Instance?, childName: string): ImageButton?
	local child = findChild(parent, childName)
	return if child and child:IsA("ImageButton") then child else nil
end

local function getOrCreateScale(parent: Instance, name: string): UIScale
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("UIScale") then
		return existing
	end

	local scale = Instance.new("UIScale")
	scale.Name = name
	scale.Parent = parent
	return scale
end

local function getStyle(rarity: string?)
	return RARITY_STYLES[rarity or ""] or RARITY_STYLES.Common
end

local function easeOutCubic(alpha: number): number
	local inverse = 1 - alpha
	return 1 - inverse * inverse * inverse
end

local function easeOutBack(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	local c1 = 1.70158
	local c3 = c1 + 1
	local shifted = alpha - 1
	return 1 + c3 * shifted * shifted * shifted + c1 * shifted * shifted
end

local function smoothstep(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	return alpha * alpha * (3 - 2 * alpha)
end

local function getMainProgress(alpha: number): number
	alpha = math.clamp(alpha, 0, 1)
	return easeOutCubic(alpha)
end

local function lerpNumber(fromValue: number, toValue: number, alpha: number): number
	return fromValue + (toValue - fromValue) * alpha
end

local function lerpColor(fromValue: Color3, toValue: Color3, alpha: number): Color3
	return Color3.new(
		lerpNumber(fromValue.R, toValue.R, alpha),
		lerpNumber(fromValue.G, toValue.G, alpha),
		lerpNumber(fromValue.B, toValue.B, alpha)
	)
end

local function getRarityRank(rarity: string?): number
	for index, rarityName in ipairs(RARITY_SEQUENCE) do
		if rarityName == rarity then
			return index
		end
	end

	return 1
end

local function getRarityAtRank(rank: number): string
	return RARITY_SEQUENCE[math.clamp(rank, 1, #RARITY_SEQUENCE)] or RARITY_SEQUENCE[1]
end

local function getNonEmptyString(value: any): string?
	return if typeof(value) == "string" and value ~= "" then value else nil
end

local function getRawRewardType(rawReward: any): string
	if typeof(rawReward) == "table" then
		local rewardType = getNonEmptyString(rawReward.rewardType)
		if rewardType == CrateRollConfig.RewardTypes.Finisher or getNonEmptyString(rawReward.finisherId) then
			return CrateRollConfig.RewardTypes.Finisher
		end
	end

	return CrateRollConfig.RewardTypes.BombSkin
end

local function getRawRewardItemId(rawReward: any, rewardType: string): string?
	local rawItemId = rawReward
	if typeof(rawReward) == "table" then
		if rewardType == CrateRollConfig.RewardTypes.Finisher then
			rawItemId = rawReward.finisherId or rawReward.itemId or rawReward.id or rawReward.name
		else
			rawItemId = rawReward.skinId or rawReward.itemId or rawReward.id or rawReward.name
		end
	end

	return getNonEmptyString(rawItemId)
end

local function getRawRewardDisplayName(rawReward: any): string?
	if typeof(rawReward) == "table" then
		return getNonEmptyString(rawReward.displayName)
			or getNonEmptyString(rawReward.name)
			or getNonEmptyString(rawReward.id)
			or getNonEmptyString(rawReward.itemId)
			or getNonEmptyString(rawReward.skinId)
			or getNonEmptyString(rawReward.finisherId)
	end

	return getNonEmptyString(rawReward)
end

local function getRawRewardExplicitDisplayName(rawReward: any): string?
	if typeof(rawReward) ~= "table" then
		return nil
	end

	return getNonEmptyString(rawReward.displayName)
end

local function getRawRewardIcon(rawReward: any): string?
	if typeof(rawReward) ~= "table" then
		return nil
	end

	return getNonEmptyString(rawReward.iconImage)
		or getNonEmptyString(rawReward.icon)
		or getNonEmptyString(rawReward.image)
end

local function getRawRewardRarity(rawReward: any): string?
	if typeof(rawReward) ~= "table" then
		return nil
	end

	return getNonEmptyString(rawReward.rarity)
end

local function getDefinitionForRewardType(rewardType: string, itemId: string)
	return if rewardType == CrateRollConfig.RewardTypes.Finisher
		then FinisherConfig.GetDefinition(itemId)
		else BombSkinConfig.GetDefinition(itemId)
end

local function normalizeReward(rawReward: any): SkinReward
	local rewardType = getRawRewardType(rawReward)
	local rawItemId = getRawRewardItemId(rawReward, rewardType)
	local itemId = if rewardType == CrateRollConfig.RewardTypes.Finisher
		then FinisherConfig.NormalizeFinisherId(rawItemId)
		else BombSkinConfig.NormalizeSkinId(rawItemId)
	local definition = if itemId ~= "" then getDefinitionForRewardType(rewardType, itemId) else nil
	local explicitDisplayName = getRawRewardExplicitDisplayName(rawReward)
	local fallbackDisplayName = getRawRewardDisplayName(rawReward)
	local rawIconImage = getRawRewardIcon(rawReward)
	local rarity = getRawRewardRarity(rawReward)

	if definition then
		return {
			rewardType = rewardType,
			itemId = itemId,
			skinId = if rewardType == CrateRollConfig.RewardTypes.BombSkin then itemId else nil,
			finisherId = if rewardType == CrateRollConfig.RewardTypes.Finisher then itemId else nil,
			displayName = explicitDisplayName or definition.displayName,
			rarity = rarity or definition.rarity or "Common",
			iconImage = rawIconImage or definition.iconImage,
		}
	end

	local fallbackItemId = rawItemId or fallbackDisplayName
	if fallbackItemId then
		return {
			rewardType = rewardType,
			itemId = fallbackItemId,
			skinId = if rewardType == CrateRollConfig.RewardTypes.BombSkin then fallbackItemId else nil,
			finisherId = if rewardType == CrateRollConfig.RewardTypes.Finisher then fallbackItemId else nil,
			displayName = explicitDisplayName or fallbackDisplayName or fallbackItemId,
			rarity = rarity or "Common",
			iconImage = rawIconImage
				or (if rewardType == CrateRollConfig.RewardTypes.Finisher
					then FinisherConfig.GetIconImage(fallbackItemId)
					else BombSkinConfig.GetIconImage(fallbackItemId) or BombSkinConfig.GetArchivedIconImage(fallbackItemId)),
		}
	end

	itemId = BombSkinConfig.DefaultSkinId
	definition = BombSkinConfig.GetDefinition(itemId)

	return {
		rewardType = CrateRollConfig.RewardTypes.BombSkin,
		itemId = itemId,
		skinId = itemId,
		displayName = definition and definition.displayName or itemId,
		rarity = rarity or "Common",
		iconImage = definition and definition.iconImage or BombSkinConfig.GetIconImage(itemId),
	}
end

local function rewardFromItemId(rewardType: string, itemId: string, fallbackRarity: string?): SkinReward
	local normalizedItemId = if rewardType == CrateRollConfig.RewardTypes.Finisher
		then FinisherConfig.NormalizeFinisherId(itemId)
		else BombSkinConfig.NormalizeSkinId(itemId)
	if normalizedItemId == "" then
		rewardType = CrateRollConfig.RewardTypes.BombSkin
		normalizedItemId = BombSkinConfig.DefaultSkinId
	end

	local definition = getDefinitionForRewardType(rewardType, normalizedItemId)
	return {
		rewardType = rewardType,
		itemId = normalizedItemId,
		skinId = if rewardType == CrateRollConfig.RewardTypes.BombSkin then normalizedItemId else nil,
		finisherId = if rewardType == CrateRollConfig.RewardTypes.Finisher then normalizedItemId else nil,
		displayName = definition and definition.displayName or normalizedItemId,
		rarity = fallbackRarity or (definition and definition.rarity) or "Common",
		iconImage = definition and definition.iconImage,
	}
end

local function getRewardCatalogIds(rewardType: string): { string }
	return if rewardType == CrateRollConfig.RewardTypes.Finisher then FinisherConfig.GetCatalogIds() else BombSkinConfig.GetCatalogIds()
end

local function getRewardDefinition(rewardType: string, itemId: string)
	return getDefinitionForRewardType(rewardType, itemId)
end

local function getRandomRewardExcluding(
	rewardType: string,
	catalogIds: { string },
	rng: Random,
	excludedItemId: string?
): SkinReward
	local candidates = {}
	for _, itemId in ipairs(catalogIds) do
		if itemId ~= excludedItemId then
			table.insert(candidates, itemId)
		end
	end

	local fallbackItemId = candidates[rng:NextInteger(1, math.max(1, #candidates))] or BombSkinConfig.DefaultSkinId
	return rewardFromItemId(rewardType, fallbackItemId)
end

local function getRandomRewardByRarities(
	rewardType: string,
	catalogIds: { string },
	rng: Random,
	rarities: { string },
	excludedItemId: string?
): SkinReward
	local candidates = {}
	local raritySet = {}
	for _, rarity in ipairs(rarities) do
		raritySet[rarity] = true
	end

	for _, itemId in ipairs(catalogIds) do
		if itemId ~= excludedItemId then
			local definition = getRewardDefinition(rewardType, itemId)
			if definition and raritySet[definition.rarity] then
				table.insert(candidates, itemId)
			end
		end
	end

	if #candidates > 0 then
		return rewardFromItemId(rewardType, candidates[rng:NextInteger(1, #candidates)])
	end

	for _, itemId in ipairs(catalogIds) do
		if itemId ~= excludedItemId then
			table.insert(candidates, itemId)
		end
	end

	local fallbackItemId = candidates[rng:NextInteger(1, math.max(1, #candidates))] or BombSkinConfig.DefaultSkinId
	return rewardFromItemId(rewardType, fallbackItemId)
end

local function playFirstAvailableSound(names: { string }, parent: Instance?, playbackSpeed: number?)
	for _, soundName in ipairs(names) do
		local sound = SoundUtil.Play(soundName, parent)
		if sound then
			if typeof(playbackSpeed) == "number" then
				sound.PlaybackSpeed = playbackSpeed
			end
			return sound
		end
	end

	return nil
end

local function getTickPlaybackSpeed(progress: number?): number
	local lateAlpha = smoothstep(progress or 0)
	return lerpNumber(1.24, 0.82, lateAlpha)
end

local function getGuiCenterX(guiObject: GuiObject): number
	return guiObject.AbsolutePosition.X + (guiObject.AbsoluteSize.X * 0.5)
end

local function getUDimPixels(value: UDim, parentPixels: number): number
	return (value.Scale * parentPixels) + value.Offset
end

local function getTrackOffsetX(trackFrame: GuiObject): number
	return trackFrame.Position.X.Offset
end

local function getCrateRequestRemote(): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild(CrateRollConfig.RemotesFolderName)
	if not (remotes and remotes:IsA("Folder")) then
		return nil
	end

	local remote = remotes:FindFirstChild(CrateRollConfig.RequestRemoteName)
	return if remote and remote:IsA("RemoteFunction") then remote else nil
end

local function getCrateResultRemote(): RemoteEvent?
	local remotes = ReplicatedStorage:FindFirstChild(CrateRollConfig.RemotesFolderName)
	if not (remotes and remotes:IsA("Folder")) then
		return nil
	end

	local remote = remotes:FindFirstChild(CrateRollConfig.ResultRemoteName)
	return if remote and remote:IsA("RemoteEvent") then remote else nil
end

local function getSpinWheelStateRemote(): RemoteFunction?
	local remotes = ReplicatedStorage:FindFirstChild(SpinWheelConfig.RemotesFolderName)
	if not (remotes and remotes:IsA("Folder")) then
		return nil
	end

	local remote = remotes:FindFirstChild(SpinWheelConfig.GetStateRemoteName)
	return if remote and remote:IsA("RemoteFunction") then remote else nil
end

local function playerHasInstantSpin(): boolean
	local remote = getSpinWheelStateRemote()
	if not remote then
		return false
	end

	local ok, state = pcall(function()
		return remote:InvokeServer()
	end)
	if not ok or typeof(state) ~= "table" then
		return false
	end

	if state.HasInstantSpin == true then
		return true
	end

	return (tonumber(state.InstantSpinUntil) or 0) > (tonumber(state.Now) or os.time())
end

local function getTemplateIconImage(templateWrapper: GuiObject?): string?
	local templateButton = findImageButton(templateWrapper, "CommonTemplate")
	local icon = findImageLabel(templateButton, "Icon")
	if icon and icon.Image ~= "" then
		return icon.Image
	end

	return nil
end

local function collectStrokes(root: Instance, label: TextLabel?): { StrokeState }
	local strokes = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("UIStroke") then
			table.insert(strokes, {
				stroke = descendant,
				color = descendant.Color,
				transparency = descendant.Transparency,
				thickness = descendant.Thickness,
				isLabelStroke = label ~= nil and descendant:IsDescendantOf(label),
			})
		end
	end
	return strokes
end

local function setCardGuiZIndex(button: GuiObject, icon: ImageLabel?, label: TextLabel?, back: ImageLabel?, zIndex: number)
	button.ZIndex = zIndex
	if back then
		back.ZIndex = math.max(1, zIndex - 1)
	end
	if icon then
		icon.ZIndex = zIndex + 1
	end
	if label then
		label.ZIndex = zIndex + 2
	end
end

function CrateRollController:_trackConnection(connection: RBXScriptConnection)
	table.insert(self._connections, connection)
	return connection
end

function CrateRollController:_trackTween(tween: Tween)
	table.insert(self._tweens, tween)
	return tween
end

function CrateRollController:_cancelTweens()
	for _, tween in ipairs(self._tweens) do
		tween:Cancel()
	end
	table.clear(self._tweens)
end

function CrateRollController:_disconnectRender()
	if self._renderConnection then
		self._renderConnection:Disconnect()
		self._renderConnection = nil
	end
end

function CrateRollController:_bindUi(): boolean
	if self._root
		and self._root.Parent
		and self._trackViewport
		and self._trackViewport.Parent
		and self._trackFrame
		and self._trackFrame.Parent
	then
		return true
	end

	local hud = PlayerGui:WaitForChild(HUD_NAME, 10)
	local root = hud and hud:WaitForChild(CRATE_ROLL_NAME, 10)
	if not (root and root:IsA("Frame")) then
		warn("[CrateRollController] Missing PlayerGui.HUD.CrateRoll")
		return false
	end

	local scroller = root:FindFirstChild("ScrollingFrame")
	local skipButton = root:FindFirstChild("SkipButton")
	local result = root:FindFirstChild("Result")
	local centerMarker = root:FindFirstChild("Frame")
	if not (scroller and scroller:IsA("ScrollingFrame")) then
		warn("[CrateRollController] Missing CrateRoll.ScrollingFrame")
		return false
	end
	if not (skipButton and skipButton:IsA("GuiButton")) then
		warn("[CrateRollController] Missing CrateRoll.SkipButton")
		return false
	end
	if not (result and result:IsA("Frame")) then
		warn("[CrateRollController] Missing CrateRoll.Result")
		return false
	end
	if not (centerMarker and centerMarker:IsA("GuiObject")) then
		warn("[CrateRollController] Missing CrateRoll center marker Frame")
		return false
	end

	local layout = scroller:FindFirstChildOfClass("UIListLayout")
	if not layout then
		warn("[CrateRollController] Missing CrateRoll.ScrollingFrame.UIListLayout")
		return false
	end

	local templateWrapper = nil
	table.clear(self._templateWrappers)
	for _, child in ipairs(scroller:GetChildren()) do
		if child:IsA("GuiObject") and child:FindFirstChild("CommonTemplate") then
			table.insert(self._templateWrappers, child)
			if not templateWrapper then
				templateWrapper = child
			end
		end
	end

	if not templateWrapper then
		warn("[CrateRollController] Missing CommonTemplate reward card wrapper")
		return false
	end

	if self._root ~= root then
		if self._skipConnection then
			self._skipConnection:Disconnect()
			self._skipConnection = nil
		end
		if self._privateTemplateWrapper then
			self._privateTemplateWrapper:Destroy()
			self._privateTemplateWrapper = nil
		end
		table.clear(self._edgeFades)
		self._speedStreak = nil
		self._markerStroke = nil
		self._centerMarkerScale = nil
		self._trackViewport = nil
		self._trackFrame = nil
		self._reelMetrics = nil
		self._sourceTemplateWrapper = nil
	end

	self._root = root
	self._scroller = scroller
	self._layout = layout
	self._skipButton = skipButton
	self._result = result
	self._resultLabel = findTextLabel(result, "Label")
	self._centerMarker = centerMarker
	self._rootScale = getOrCreateScale(root, CONTROLLER_SCALE_NAME)
	self._resultScale = getOrCreateScale(result, RESULT_SCALE_NAME)
	self._centerMarkerScale = getOrCreateScale(centerMarker, MARKER_SCALE_NAME)
	self._sourceTemplateWrapper = templateWrapper

	scroller.ScrollingEnabled = false
	scroller.ScrollBarThickness = 0
	scroller.ScrollBarImageTransparency = 1
	scroller.CanvasPosition = Vector2.new(0, 0)
	result.Visible = false

	for _, wrapper in ipairs(self._templateWrappers) do
		wrapper.Visible = false
	end
	if not self._privateTemplateWrapper then
		local privateTemplate = templateWrapper:Clone()
		privateTemplate.Name = "CrateRollPrivateTemplate"
		privateTemplate:SetAttribute(GENERATED_ATTR, true)
		privateTemplate.Visible = false
		privateTemplate.Parent = nil
		self._privateTemplateWrapper = privateTemplate
	end
	self._templateWrapper = self._privateTemplateWrapper

	local oldScrollerTrack = scroller:FindFirstChild(TRACK_NAME)
	if oldScrollerTrack then
		oldScrollerTrack:Destroy()
	end

	local trackViewport = root:FindFirstChild(TRACK_VIEWPORT_NAME)
	if not (trackViewport and trackViewport:IsA("Frame")) then
		trackViewport = Instance.new("Frame")
		trackViewport.Name = TRACK_VIEWPORT_NAME
		trackViewport:SetAttribute(POLISH_ATTR, true)
		trackViewport.BackgroundTransparency = 1
		trackViewport.BorderSizePixel = 0
		trackViewport.ClipsDescendants = true
		trackViewport.Parent = root
	end
	trackViewport.AnchorPoint = scroller.AnchorPoint
	trackViewport.Position = scroller.Position
	trackViewport.Size = scroller.Size
	trackViewport.Visible = true
	trackViewport.ZIndex = math.max(scroller.ZIndex, 2)
	self._trackViewport = trackViewport

	local trackFrame = trackViewport:FindFirstChild(TRACK_NAME)
	if not (trackFrame and trackFrame:IsA("Frame")) then
		trackFrame = Instance.new("Frame")
		trackFrame.Name = TRACK_NAME
		trackFrame:SetAttribute(POLISH_ATTR, true)
		trackFrame.BackgroundTransparency = 1
		trackFrame.BorderSizePixel = 0
		trackFrame.ClipsDescendants = false
		trackFrame.Parent = trackViewport
	end
	trackFrame.AnchorPoint = Vector2.new(0, 0)
	trackFrame.Position = UDim2.fromOffset(0, 0)
	trackFrame.Size = UDim2.fromOffset(0, math.max(1, trackViewport.AbsoluteSize.Y))
	trackFrame.Visible = true
	trackFrame.ZIndex = trackViewport.ZIndex
	self._trackFrame = trackFrame

	self:_ensurePolish()
	self:_bindSkipButton()

	return true
end

function CrateRollController:_bindSkipButton()
	local skipButton = self._skipButton
	if not skipButton or self._skipConnection then
		return
	end

	self._skipConnection = skipButton.Activated:Connect(function()
		self:_requestSkip()
	end)
end

function CrateRollController:_ensurePolish()
	local root = self._root
	local scroller = self._scroller
	local centerMarker = self._centerMarker
	if not (root and scroller and centerMarker) then
		return
	end

	if #self._edgeFades == 0 then
		for _, side in ipairs({ "Left", "Right" }) do
			local fade = Instance.new("Frame")
			fade.Name = "CrateRoll" .. side .. "Fade"
			fade:SetAttribute(POLISH_ATTR, true)
			fade.Active = false
			fade.AnchorPoint = if side == "Left" then Vector2.new(0, 0.5) else Vector2.new(1, 0.5)
			fade.BackgroundColor3 = root.BackgroundColor3
			fade.BackgroundTransparency = 0.1
			fade.BorderSizePixel = 0
			fade.Position = if side == "Left" then UDim2.fromScale(0, 0.5) else UDim2.fromScale(1, 0.5)
			fade.Size = UDim2.fromScale(0.16, 1)
			fade.Visible = true
			fade.ZIndex = math.max(root.ZIndex + 20, 20)
			fade.Parent = root

			local gradient = Instance.new("UIGradient")
			gradient.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.05),
				NumberSequenceKeypoint.new(1, 1),
			})
			gradient.Rotation = if side == "Left" then 0 else 180
			gradient.Parent = fade

			table.insert(self._edgeFades, fade)
		end
	end

	if not (self._speedStreak and self._speedStreak.Parent) then
		local streak = Instance.new("Frame")
		streak.Name = "CrateRollSpeedStreak"
		streak:SetAttribute(POLISH_ATTR, true)
		streak.AnchorPoint = Vector2.new(0.5, 0.5)
		streak.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		streak.BackgroundTransparency = 1
		streak.BorderSizePixel = 0
		streak.Position = UDim2.fromScale(0.5, 0.5)
		streak.Size = UDim2.fromScale(0.94, 0.84)
		streak.Visible = true
		streak.ZIndex = math.max(root.ZIndex + 18, 18)
		streak.Parent = root

		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(143, 212, 255))
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, 0.88),
			NumberSequenceKeypoint.new(0.5, 0.96),
			NumberSequenceKeypoint.new(0.8, 0.88),
			NumberSequenceKeypoint.new(1, 1),
		})
		gradient.Rotation = 0
		gradient.Parent = streak

		self._speedStreak = streak
	end

	if not (self._markerStroke and self._markerStroke.Parent) then
		local stroke = Instance.new("UIStroke")
		stroke.Name = "CrateRollMarkerGlow"
		stroke:SetAttribute(POLISH_ATTR, true)
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = Color3.fromRGB(255, 245, 186)
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Thickness = 2
		stroke.Transparency = 0.2
		stroke.Parent = centerMarker
		self._markerStroke = stroke
	end

	centerMarker.ZIndex = math.max(centerMarker.ZIndex, 25)
	scroller.ZIndex = math.max(scroller.ZIndex, 2)
end

function CrateRollController:_clearGeneratedCards()
	local scroller = self._scroller
	local trackFrame = self._trackFrame
	if not scroller then
		return
	end

	if trackFrame then
		for _, child in ipairs(trackFrame:GetChildren()) do
			if child:GetAttribute(GENERATED_ATTR) == true then
				child:Destroy()
			end
		end
	end

	for _, child in ipairs(scroller:GetChildren()) do
		if child ~= trackFrame and child:GetAttribute(GENERATED_ATTR) == true then
			child:Destroy()
		end
	end

	table.clear(self._cards)
	self._winningCard = nil
	self._reelMetrics = nil
	self._lastTickIndex = nil
	self._tickPulseStartedAt = -math.huge
	self._tickPulseStrength = 0
end

function CrateRollController:_resetUiForRoll()
	local root = self._root
	local scroller = self._scroller
	local result = self._result
	local skipButton = self._skipButton
	local rootScale = self._rootScale
	local resultScale = self._resultScale

	if root then
		root.Visible = true
	end
	if scroller then
		scroller.CanvasPosition = Vector2.new(0, 0)
		scroller.ScrollingEnabled = false
	end
	if self._trackFrame then
		self._trackFrame.Position = UDim2.fromOffset(0, 0)
	end
	if result then
		result.Visible = false
		result.BackgroundTransparency = 0.6
	end
	if skipButton then
		skipButton.Active = true
		skipButton.Interactable = true
		skipButton.AutoButtonColor = true
		skipButton.Visible = true
	end
	if rootScale then
		rootScale.Scale = 1
	end
	if resultScale then
		resultScale.Scale = 0.72
	end
	if self._centerMarkerScale then
		self._centerMarkerScale.Scale = 1
	end
	if self._speedStreak then
		self._speedStreak.BackgroundTransparency = 1
	end
	self._tickPulseStartedAt = -math.huge
	self._tickPulseStrength = 0
end

function CrateRollController:_cancelActiveRoll()
	self._currentRollId += 1
	self._rolling = false
	self._finishing = false
	self._skipRequested = false
	self:_disconnectRender()
	self:_cancelTweens()
	self:_clearGeneratedCards()
end

function CrateRollController:_buildRewards(winningReward: SkinReward): ({ SkinReward }, number)
	local rewardType = winningReward.rewardType or CrateRollConfig.RewardTypes.BombSkin
	local catalogIds = getRewardCatalogIds(rewardType)
	local rewards = table.create(CARD_COUNT)
	local winIndex = self._rng:NextInteger(WIN_INDEX_MIN, WIN_INDEX_MAX)
	local winRank = getRarityRank(winningReward.rarity)
	local excludedItemId = winningReward.itemId

	for index = 1, CARD_COUNT do
		if index == winIndex then
			rewards[index] = winningReward
		else
			rewards[index] = getRandomRewardExcluding(rewardType, catalogIds, self._rng, excludedItemId)
		end
	end

	if winIndex - 2 >= 1 then
		rewards[winIndex - 2] = getRandomRewardByRarities(rewardType, catalogIds, self._rng, {
			getRarityAtRank(math.max(3, winRank - 1)),
			getRarityAtRank(math.max(3, winRank)),
		}, excludedItemId)
	end
	if winIndex - 1 >= 1 then
		rewards[winIndex - 1] = getRandomRewardByRarities(rewardType, catalogIds, self._rng, {
			getRarityAtRank(math.min(#RARITY_SEQUENCE, winRank + 1)),
			getRarityAtRank(math.max(3, winRank)),
			getRarityAtRank(math.max(3, winRank - 1)),
		}, excludedItemId)
	end
	if winIndex + 1 <= CARD_COUNT then
		rewards[winIndex + 1] = getRandomRewardByRarities(rewardType, catalogIds, self._rng, {
			getRarityAtRank(math.max(3, winRank)),
			getRarityAtRank(math.max(3, winRank - 1)),
		}, excludedItemId)
	end

	return rewards, winIndex
end

function CrateRollController:_configureCard(wrapper: GuiObject, reward: SkinReward, index: number, isWinningCard: boolean): CardRecord?
	local button = wrapper:FindFirstChild("CommonTemplate")
	if not (button and button:IsA("GuiObject")) then
		wrapper:Destroy()
		return nil
	end

	local label = findTextLabel(button, "Label")
	local icon = findImageLabel(button, "Icon")
	local back = findImageLabel(button, "Back")
	local style = getStyle(reward.rarity)
	local templateIconImage = getTemplateIconImage(self._templateWrapper)

	wrapper.Name = ("RewardCard_%02d"):format(index)
	wrapper:SetAttribute(GENERATED_ATTR, true)
	wrapper:SetAttribute(WINNING_CARD_ATTR, isWinningCard)
	wrapper.Visible = true
	wrapper.LayoutOrder = index

	button.Active = false
	button.Selectable = false
	button:SetAttribute(WINNING_CARD_ATTR, isWinningCard)
	setCardGuiZIndex(button, icon, label, back, 4)

	local scale = getOrCreateScale(button, CARD_SCALE_NAME)
	scale.Scale = 0.88

	if label then
		label.Text = reward.displayName
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextTransparency = 0.18
	end

	if icon then
		icon.Image = reward.iconImage or templateIconImage or icon.Image
		icon.ImageColor3 = Color3.fromRGB(205, 213, 225)
		icon.ImageTransparency = 0.18
	end

	if back then
		back.BackgroundColor3 = style.dark
		back.BackgroundTransparency = 0.12
	end

	local strokes = collectStrokes(button, label)
	for _, strokeState in ipairs(strokes) do
		strokeState.stroke.Color = style.color
		strokeState.stroke.Transparency = math.max(0.25, strokeState.transparency)
	end

	return {
		wrapper = wrapper,
		button = button,
		icon = icon,
		label = label,
		back = back,
		scale = scale,
		baseButtonPosition = button.Position,
		baseIconTransparency = icon and icon.ImageTransparency or 0,
		baseIconColor = icon and icon.ImageColor3 or Color3.new(1, 1, 1),
		baseLabelTransparency = label and label.TextTransparency or nil,
		baseBackColor = back and back.BackgroundColor3 or nil,
		baseBackTransparency = back and back.BackgroundTransparency or nil,
		strokes = strokes,
		reward = reward,
		index = index,
	}
end

function CrateRollController:_buildCards(winningReward: SkinReward): number?
	local trackFrame = self._trackFrame
	local templateWrapper = self._templateWrapper
	if not (trackFrame and templateWrapper) then
		return nil
	end

	local rewards, winIndex = self:_buildRewards(winningReward)
	local metrics = self:_getReelMetrics(#rewards)
	if not metrics then
		return nil
	end
	self._reelMetrics = metrics
	trackFrame.Position = UDim2.fromOffset(0, 0)
	trackFrame.Size = UDim2.fromOffset(metrics.trackWidth, metrics.cardHeight)

	local preloadItems = {}
	local preloadItemSet = {}

	for index, reward in ipairs(rewards) do
		local clone = templateWrapper:Clone()
		clone.Parent = trackFrame
		clone.AnchorPoint = Vector2.new(0, 0)
		clone.Position = UDim2.fromOffset((index - 1) * metrics.cardStep, 0)
		clone.Size = UDim2.fromOffset(metrics.cardWidth, metrics.cardHeight)

		local card = self:_configureCard(clone, reward, index, index == winIndex)
		if card then
			table.insert(self._cards, card)
			if index == winIndex then
				self._winningCard = card
			end

			if card.icon and card.icon.Image ~= "" then
				local image = card.icon.Image
				if not preloadItemSet[image] then
					preloadItemSet[image] = true
					table.insert(preloadItems, image)
				end
			end
		end
	end

	if #preloadItems > 0 then
		pcall(function()
			ContentProvider:PreloadAsync(preloadItems)
		end)
	end

	return winIndex
end

function CrateRollController:_waitForLayout()
	for _ = 1, 3 do
		RunService.RenderStepped:Wait()
	end
end

local function resolveGuiWidth(gui: GuiObject, parentWidth: number): number
	local absoluteWidth = gui.AbsoluteSize.X
	if absoluteWidth > 1 then
		return absoluteWidth
	end

	local sizeX = gui.Size.X
	local scaledWidth = sizeX.Scale * parentWidth
	if scaledWidth > 1 then
		return scaledWidth + sizeX.Offset
	end

	return math.max(1, sizeX.Offset)
end

function CrateRollController:_getReelMetrics(cardCount: number): ReelMetrics?
	local scroller = self._scroller
	local trackViewport = self._trackViewport
	local templateWrapper = self._sourceTemplateWrapper or self._templateWrapper
	if not (scroller and trackViewport and templateWrapper) then
		return nil
	end

	local cardWidth = resolveGuiWidth(templateWrapper, scroller.AbsoluteSize.X)
	local cardHeight = math.max(1, trackViewport.AbsoluteSize.Y)
	local spacing = 0
	local layout = self._layout
	if layout then
		spacing = math.max(0, getUDimPixels(layout.Padding, scroller.AbsoluteSize.X))
	end

	local cardStep = math.max(1, cardWidth + spacing)
	local trackWidth = math.max(cardWidth, ((math.max(cardCount, 1) - 1) * cardStep) + cardWidth)
	return {
		cardWidth = cardWidth,
		cardHeight = cardHeight,
		cardStep = cardStep,
		trackWidth = trackWidth,
		viewportCenterX = trackViewport.AbsoluteSize.X * 0.5,
	}
end

local function getCardCenterLocalX(metrics: ReelMetrics, cardIndex: number): number
	return ((cardIndex - 1) * metrics.cardStep) + (metrics.cardWidth * 0.5)
end

local function getRollbackOvershootPixels(metrics: ReelMetrics): number
	return math.clamp(
		metrics.cardWidth * ROLLBACK_OVERSHOOT_FRACTION,
		ROLLBACK_OVERSHOOT_MIN,
		ROLLBACK_OVERSHOOT_MAX
	)
end

function CrateRollController:_calculateTargetX(): number?
	local winningCard = self._winningCard
	local metrics = self._reelMetrics
	if not (winningCard and winningCard.wrapper.Parent and metrics) then
		return nil
	end

	return metrics.viewportCenterX - getCardCenterLocalX(metrics, winningCard.index)
end

function CrateRollController:_findCenteredCard(): CardRecord?
	local trackViewport = self._trackViewport
	if not trackViewport then
		return nil
	end

	local centerX = getGuiCenterX(trackViewport)
	local bestCard = nil :: CardRecord?
	local bestDistance = math.huge
	for _, card in ipairs(self._cards) do
		if card.wrapper.Parent then
			local distance = math.abs(getGuiCenterX(card.button) - centerX)
			if distance < bestDistance then
				bestDistance = distance
				bestCard = card
			end
		end
	end

	return bestCard
end

function CrateRollController:_findCenteredCardIndex(): number?
	local centeredCard = self:_findCenteredCard()
	return if centeredCard then centeredCard.index else nil
end

function CrateRollController:_updateCardFocus(lockWinner: boolean?)
	local trackViewport = self._trackViewport
	if not trackViewport then
		return
	end

	local centerX = getGuiCenterX(trackViewport)
	local focusRange = math.max(1, trackViewport.AbsoluteSize.X * 0.34)
	local closestCard = nil :: CardRecord?
	local closestDistance = math.huge

	for _, card in ipairs(self._cards) do
		if card.wrapper.Parent then
			local distance = math.abs(getGuiCenterX(card.button) - centerX)
			local focus = 1 - math.clamp(distance / focusRange, 0, 1)
			local style = getStyle(card.reward.rarity)
			local isWinner = lockWinner and card == self._winningCard
			if isWinner then
				focus = 1
			end

			local zIndex = if isWinner then 18 else math.floor(4 + focus * 8)
			card.wrapper.ZIndex = zIndex
			setCardGuiZIndex(card.button, card.icon, card.label, card.back, zIndex)

			if card.icon then
				card.icon.ImageTransparency = if isWinner then 0 else lerpNumber(0.32, 0, focus)
				card.icon.ImageColor3 = lerpColor(Color3.fromRGB(160, 168, 181), Color3.new(1, 1, 1), focus)
			end

			if card.label and card.baseLabelTransparency then
				card.label.TextTransparency = if isWinner then 0 else lerpNumber(0.36, card.baseLabelTransparency, focus)
				card.label.TextColor3 = if isWinner then style.color else Color3.new(1, 1, 1)
			end

			if card.back then
				card.back.BackgroundColor3 = lerpColor(style.dark, style.color, if isWinner then 0.5 else focus * 0.28)
				card.back.BackgroundTransparency = if isWinner then 0 else lerpNumber(0.28, 0.08, focus)
			end

			for _, strokeState in ipairs(card.strokes) do
				local stroke = strokeState.stroke
				if stroke.Parent then
					stroke.Color = style.color
					if strokeState.isLabelStroke then
						stroke.Transparency = math.max(0.12, strokeState.transparency)
					else
						stroke.Transparency = if isWinner then 0.02 else lerpNumber(0.62, 0.16, focus)
					end
				end
			end

			if distance < closestDistance then
				closestDistance = distance
				closestCard = card
			end
		end
	end

	if closestCard then
		local zIndex = math.max(closestCard.button.ZIndex, 14)
		closestCard.wrapper.ZIndex = zIndex
		setCardGuiZIndex(closestCard.button, closestCard.icon, closestCard.label, closestCard.back, zIndex)
	end
end

function CrateRollController:_updateTickSound(progress: number?)
	local centeredIndex = self:_findCenteredCardIndex()
	if not centeredIndex or centeredIndex == self._lastTickIndex then
		return
	end

	self._lastTickIndex = centeredIndex
	playFirstAvailableSound(TICK_SOUND_NAMES, self._root, getTickPlaybackSpeed(progress))

	self._tickPulseStartedAt = os.clock()
	self._tickPulseStrength = lerpNumber(0.55, 1, smoothstep(progress or 0))
end

function CrateRollController:_updatePolish(progress: number)
	local now = os.clock()
	local markerStroke = self._markerStroke
	if markerStroke and markerStroke.Parent then
		local pulse = (math.sin(now * MARKER_PULSE_SPEED) + 1) * 0.5
		markerStroke.Transparency = lerpNumber(0.42, 0.08, pulse)
	end

	local tickAlpha = math.clamp((now - self._tickPulseStartedAt) / TICK_PULSE_SECONDS, 0, 1)
	if tickAlpha < 1 then
		local tickPop = math.sin(tickAlpha * math.pi) * self._tickPulseStrength
		if self._centerMarkerScale then
			self._centerMarkerScale.Scale = 1 + tickPop * TICK_MARKER_POP_SCALE
		end
	else
		if self._centerMarkerScale then
			self._centerMarkerScale.Scale = 1
		end
	end

	if self._speedStreak then
		local fastAlpha = if progress < 0.4 then math.sin(math.clamp(progress / 0.4, 0, 1) * math.pi) else 0
		self._speedStreak.BackgroundTransparency = lerpNumber(1, 0.88, fastAlpha)
	end
end

function CrateRollController:_playWinnerLockAnimation()
	local winningCard = self._winningCard
	if not (winningCard and winningCard.wrapper.Parent) then
		return
	end

	winningCard.scale.Scale = 1.18
	local popTween = self:_trackTween(TweenService:Create(winningCard.scale, WINNER_POP_TWEEN, {
		Scale = 1.28,
	}))
	popTween.Completed:Connect(function()
		if not (winningCard.wrapper.Parent and winningCard.scale.Parent) then
			return
		end

		local settleTween = self:_trackTween(TweenService:Create(winningCard.scale, WINNER_SETTLE_TWEEN, {
			Scale = 1.16,
		}))
		settleTween:Play()
	end)
	popTween:Play()

	for _, strokeState in ipairs(winningCard.strokes) do
		if not strokeState.isLabelStroke and strokeState.stroke.Parent then
			local stroke = strokeState.stroke
			stroke.Transparency = 0
			local flashTween = self:_trackTween(TweenService:Create(stroke, WINNER_FLASH_TWEEN, {
				Transparency = 0.04,
			}))
			flashTween:Play()
		end
	end
end

function CrateRollController:_completeRoll(rollId: number)
	if rollId ~= self._currentRollId then
		return
	end

	self:_disconnectRender()
	self._rolling = false
	self._finishing = false
	self._skipRequested = false
	self:_updateCardFocus(true)
	self:_playWinnerLockAnimation()
	playFirstAvailableSound(LOCK_SOUND_NAMES, self._root)

	task.delay(FINAL_REVEAL_DELAY, function()
		if rollId ~= self._currentRollId then
			return
		end
		self:_showResult()
		self:_scheduleAutoClose(rollId)
	end)
end

function CrateRollController:_startFinisher(rollId: number)
	if rollId ~= self._currentRollId or self._finishing then
		return
	end

	local trackFrame = self._trackFrame
	if not trackFrame then
		self:_completeRoll(rollId)
		return
	end

	self:_disconnectRender()
	self._rolling = false
	self._finishing = true
	self._skipRequested = true

	local skipButton = self._skipButton
	if skipButton then
		skipButton.Active = false
		skipButton.Interactable = false
		skipButton.AutoButtonColor = false
	end

	local startX = getTrackOffsetX(trackFrame)
	local finishX = self:_calculateTargetX() or self._targetX
	self._targetX = finishX

	if math.abs(finishX - startX) <= FINISHER_PIXEL_EPSILON then
		trackFrame.Position = UDim2.fromOffset(finishX, 0)
		self:_completeRoll(rollId)
		return
	end

	local startTime = os.clock()
	self._renderConnection = RunService.RenderStepped:Connect(function()
		if rollId ~= self._currentRollId then
			self:_disconnectRender()
			return
		end

		local alpha = math.clamp((os.clock() - startTime) / FINISHER_DURATION, 0, 1)
		local progress = easeOutBack(alpha)
		local nextX = startX + (finishX - startX) * progress
		trackFrame.Position = UDim2.fromOffset(nextX, 0)

		self:_updateCardFocus(false)
		self:_updateTickSound(1)
		self:_updatePolish(1)

		if alpha >= 1 then
			trackFrame.Position = UDim2.fromOffset(finishX, 0)
			self:_completeRoll(rollId)
		end
	end)
end

function CrateRollController:_finishRoll(rollId: number)
	self:_startFinisher(rollId)
end

function CrateRollController:_showResult()
	local result = self._result
	local resultLabel = self._resultLabel
	local resultScale = self._resultScale
	local skipButton = self._skipButton
	local winningCard = self._winningCard
	if not (result and resultScale and winningCard) then
		return
	end

	if skipButton then
		skipButton.Active = false
		skipButton.Interactable = false
		skipButton.AutoButtonColor = false
		skipButton.Visible = false
	end

	local style = getStyle(winningCard.reward.rarity)
	if resultLabel then
		resultLabel.Text = winningCard.reward.displayName
		resultLabel.TextColor3 = style.color
	end
	result.BackgroundColor3 = style.dark
	result.BackgroundTransparency = 0.54
	resultScale.Scale = 0.76
	result.Visible = true

	local tween = self:_trackTween(TweenService:Create(resultScale, RESULT_TWEEN, {
		Scale = 1,
	}))
	tween:Play()
end

function CrateRollController:_scheduleAutoClose(rollId: number)
	task.delay(RESULT_REVIEW_SECONDS, function()
		if rollId ~= self._currentRollId then
			return
		end

		self:_closeRollFrame(rollId)
	end)
end

function CrateRollController:_closeRollFrame(rollId: number)
	if rollId ~= self._currentRollId then
		return
	end

	local root = self._root
	local result = self._result
	local skipButton = self._skipButton
	local rootScale = self._rootScale
	local resultScale = self._resultScale
	if not root then
		return
	end

	if skipButton then
		skipButton.Active = false
		skipButton.Interactable = false
		skipButton.AutoButtonColor = false
		skipButton.Visible = false
	end
	if rootScale then
		rootScale.Scale = 1
	end

	local remainingTweens = 0
	local closed = false
	local function finishClose()
		if closed or rollId ~= self._currentRollId then
			return
		end

		remainingTweens -= 1
		if remainingTweens > 0 then
			return
		end

		closed = true
		root.Visible = false
		if result then
			result.Visible = false
		end
		if rootScale then
			rootScale.Scale = 1
		end
		if resultScale then
			resultScale.Scale = 1
		end
	end

	if rootScale then
		remainingTweens += 1
		local tween = self:_trackTween(TweenService:Create(rootScale, AUTO_CLOSE_TWEEN, {
			Scale = 0.92,
		}))
		tween.Completed:Connect(finishClose)
		tween:Play()
	end
	if result and result.Visible then
		remainingTweens += 1
		local tween = self:_trackTween(TweenService:Create(result, AUTO_CLOSE_TWEEN, {
			BackgroundTransparency = 1,
		}))
		tween.Completed:Connect(finishClose)
		tween:Play()
	end
	if resultScale then
		remainingTweens += 1
		local tween = self:_trackTween(TweenService:Create(resultScale, AUTO_CLOSE_TWEEN, {
			Scale = 0.9,
		}))
		tween.Completed:Connect(finishClose)
		tween:Play()
	end

	if remainingTweens == 0 then
		remainingTweens = 1
		finishClose()
	end
end

function CrateRollController:_startMainAnimation(rollId: number, startX: number, targetX: number, duration: number)
	local trackFrame = self._trackFrame
	if not trackFrame then
		return
	end

	self:_disconnectRender()
	self._rolling = true
	self._finishing = false
	self._skipRequested = false
	self._lastTickIndex = nil

	local startTime = os.clock()
	local totalDistance = targetX - startX
	playFirstAvailableSound(WHOOSH_SOUND_NAMES, self._root)

	self._renderConnection = RunService.RenderStepped:Connect(function()
		if rollId ~= self._currentRollId then
			self:_disconnectRender()
			return
		end

		local elapsed = os.clock() - startTime
		local alpha = math.clamp(elapsed / duration, 0, 1)
		local progress = getMainProgress(alpha)
		local nextX = startX + totalDistance * progress
		trackFrame.Position = UDim2.fromOffset(nextX, 0)

		self:_updateCardFocus(false)
		self:_updateTickSound(progress)
		self:_updatePolish(progress)

		if alpha >= 1 then
			self:_finishRoll(rollId)
		end
	end)
end

function CrateRollController:_requestSkip()
	if self._skipRequested or not self._rolling then
		return
	end

	local trackFrame = self._trackFrame
	local skipButton = self._skipButton
	if not trackFrame then
		return
	end

	self._skipRequested = true
	if skipButton then
		skipButton.Active = false
		skipButton.Interactable = false
		skipButton.AutoButtonColor = false
	end

	local rollId = self._currentRollId
	local startX = getTrackOffsetX(trackFrame)
	local targetX = self._targetX
	local startTime = os.clock()

	self:_disconnectRender()
	self._renderConnection = RunService.RenderStepped:Connect(function()
		if rollId ~= self._currentRollId then
			self:_disconnectRender()
			return
		end

		local alpha = math.clamp((os.clock() - startTime) / SKIP_DURATION, 0, 1)
		local progress = easeOutCubic(alpha)
		local nextX = startX + (targetX - startX) * progress
		trackFrame.Position = UDim2.fromOffset(nextX, 0)

		self:_updateCardFocus(false)
		self:_updateTickSound(1)
		self:_updatePolish(1)

		if alpha >= 1 then
			self:_finishRoll(rollId)
		end
	end)
end

function CrateRollController:_playRollResponse(responsePayload): boolean
	if typeof(responsePayload) ~= "table" then
		return false
	end
	if responsePayload.ok == false then
		warn("[CrateRollController] Crate roll rejected: " .. tostring(responsePayload.message or responsePayload.code))
		return false
	end

	local reward = responsePayload.reward
	if typeof(reward) ~= "table" and typeof(responsePayload.roll) == "table" then
		reward = responsePayload.roll.reward or responsePayload.roll
	end
	if typeof(reward) ~= "table" then
		return false
	end

	local durationSeconds = if playerHasInstantSpin() then SKIP_DURATION else nil
	return self:PlayRoll(reward, durationSeconds)
end

function CrateRollController:_bindBackendRemotes()
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild(CrateRollConfig.RemotesFolderName, 15)
		if not (remotes and remotes:IsA("Folder")) then
			return
		end

		self._requestRemote = getCrateRequestRemote()
		local resultRemote = getCrateResultRemote()
		if not resultRemote then
			local child = remotes:WaitForChild(CrateRollConfig.ResultRemoteName, 15)
			resultRemote = if child and child:IsA("RemoteEvent") then child else nil
		end
		if not resultRemote then
			return
		end

		self._resultRemote = resultRemote
		self:_trackConnection(resultRemote.OnClientEvent:Connect(function(responsePayload)
			self:_playRollResponse(responsePayload)
		end))
	end)
end

function CrateRollController:RequestCashRoll(crateId: string): (boolean, any?)
	local remote = self._requestRemote or getCrateRequestRemote()
	if not remote then
		return false, nil
	end

	self._requestRemote = remote
	local ok, responsePayload = pcall(function()
		return remote:InvokeServer({
			action = CrateRollConfig.Actions.RollCash,
			crateId = crateId,
		})
	end)
	if not ok then
		warn("[CrateRollController] Cash roll request failed: " .. tostring(responsePayload))
		return false, nil
	end

	local played = self:_playRollResponse(responsePayload)
	return played, responsePayload
end

function CrateRollController:GetCrateState()
	local remote = self._requestRemote or getCrateRequestRemote()
	if not remote then
		return nil
	end

	self._requestRemote = remote
	local ok, responsePayload = pcall(function()
		return remote:InvokeServer({
			action = CrateRollConfig.Actions.GetState,
		})
	end)
	if not ok or typeof(responsePayload) ~= "table" or responsePayload.ok ~= true then
		return nil
	end

	return responsePayload.state
end

function CrateRollController:PlayRoll(rawReward: any, durationSeconds: number?): boolean
	if not self:_bindUi() then
		return false
	end

	self:_cancelActiveRoll()
	local rollId = self._currentRollId
	local root = self._root
	local scroller = self._scroller
	local trackFrame = self._trackFrame
	local rootScale = self._rootScale
	if not (root and scroller and trackFrame and rootScale) then
		return false
	end

	self:_resetUiForRoll()

	local winningReward = normalizeReward(rawReward)
	self:_buildCards(winningReward)
	self:_waitForLayout()

	if rollId ~= self._currentRollId then
		return false
	end

	local centerTargetX = self:_calculateTargetX()
	local metrics = self._reelMetrics
	if not (centerTargetX and metrics) then
		warn("[CrateRollController] Could not calculate winning card target")
		return false
	end
	local overshootTargetX = centerTargetX - getRollbackOvershootPixels(metrics)

	self._targetX = centerTargetX
	rootScale.Scale = 1

	self:_updateCardFocus(false)
	self:_startMainAnimation(rollId, getTrackOffsetX(trackFrame), overshootTargetX, durationSeconds or DEFAULT_ROLL_DURATION)

	return true
end

function CrateRollController:CancelRoll(hideRoot: boolean?)
	self:_cancelActiveRoll()
	local root = self._root
	local result = self._result
	local scroller = self._scroller

	if scroller then
		scroller.CanvasPosition = Vector2.new(0, 0)
	end
	if result then
		result.Visible = false
	end
	if hideRoot and root then
		root.Visible = false
	end
end

function CrateRollController:IsRolling(): boolean
	return self._rolling or self._finishing
end

function CrateRollController:OnStart()
	if self._started then
		return
	end

	self._started = true
	task.defer(function()
		self:_bindUi()
	end)
	self:_bindBackendRemotes()
end

return CrateRollController
