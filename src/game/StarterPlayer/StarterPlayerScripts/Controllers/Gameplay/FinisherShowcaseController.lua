local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationConfig = require(ReplicatedStorage.Shared.Config.AnimationConfig)
local CrateRollConfig = require(ReplicatedStorage.Shared.Config.CrateRollConfig)
local FinisherConfig = require(ReplicatedStorage.Shared.Config.FinisherConfig)
local FinisherVFX = require(ReplicatedStorage.Shared.Effects.FinisherVFX)

local LocalPlayer = Players.LocalPlayer

local SHOWCASE_SPECS = table.freeze({
	table.freeze({
		crateId = "FinisherBasic",
		initialDelay = 0,
		path = table.freeze({
			"Lobby",
			"MonetizationArea",
			"NormalFinisherCrate",
			"NormalFinisherShowcaseRig",
		}),
	}),
	table.freeze({
		crateId = "FinisherPremium",
		initialDelay = 2.5,
		path = table.freeze({
			"Lobby",
			"MonetizationArea",
			"PremiumFinisherCrate",
			"PremiumFinisherShowcaseRig",
		}),
	}),
})

local TEMPLATE_WAIT_SECONDS = 30
local PREVIEW_SECONDS = 5
local RESPAWN_SECONDS = 2
local LOCAL_CLONE_SUFFIX = "_LocalFinisherPreview"
local SHOWCASE_BILLBOARD_NAME = "BillboardGui"
local FINISHER_LABEL_NAME = "Header"
local TIMER_LABEL_NAME = "Timer"
local rng = Random.new()

local FinisherShowcaseController = {}

FinisherShowcaseController._started = false
FinisherShowcaseController._runToken = 0
FinisherShowcaseController._description = nil :: HumanoidDescription?
FinisherShowcaseController._connections = {} :: { RBXScriptConnection }
FinisherShowcaseController._showcaseBags = {} :: { [string]: { string } }
FinisherShowcaseController._lastShowcaseFinisherIds = {} :: { [string]: string }

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function waitForPath(root: Instance, path: { string }, timeoutSeconds: number): Instance?
	local startedAt = os.clock()
	local current: Instance? = root
	for _, childName in ipairs(path) do
		if not current then
			return nil
		end

		local remaining = timeoutSeconds - (os.clock() - startedAt)
		if remaining <= 0 then
			return nil
		end

		current = current:WaitForChild(childName, remaining)
	end

	return current
end

local function getAnimator(humanoid: Humanoid): Animator
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

local function stopExistingTracks(humanoid: Humanoid)
	local animator = getAnimator(humanoid)
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		track:Stop(0)
		track:Destroy()
	end
end

local function playIdle(humanoid: Humanoid): AnimationTrack?
	local idleConfig = AnimationConfig.Animations.Idle
	if not idleConfig or typeof(idleConfig.AnimationId) ~= "string" or idleConfig.AnimationId == "" then
		return nil
	end

	stopExistingTracks(humanoid)

	local animation = Instance.new("Animation")
	animation.AnimationId = idleConfig.AnimationId

	local ok, track = pcall(function()
		return getAnimator(humanoid):LoadAnimation(animation)
	end)
	animation:Destroy()
	if not ok or not track then
		return nil
	end

	track.Looped = idleConfig.Looped == true
	track.Priority = idleConfig.Priority or Enum.AnimationPriority.Idle
	track:Play(0.12, idleConfig.Weight or 1, idleConfig.SpeedMultiplier or 1)
	return track
end

local function removeCloneRuntimeInstances(model: Model)
	local toDestroy = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BaseScript") or descendant:IsA("BillboardGui") then
			table.insert(toDestroy, descendant)
		end
	end

	for _, descendant in ipairs(toDestroy) do
		descendant:Destroy()
	end
end

local function prepClone(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = 0
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
		elseif descendant:IsA("Humanoid") then
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			descendant.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			descendant.BreakJointsOnDeath = false
		end
	end
end

local function setTemplateHidden(template: Model)
	for _, descendant in ipairs(template:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = 1
		elseif descendant:IsA("Humanoid") then
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			descendant.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		end
	end
end

local function findTextLabel(parent: Instance?, name: string): TextLabel?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextLabel") then child else nil
end

local function findLabelByText(root: Instance, text: string): TextLabel?
	local targetText = string.upper(text)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("TextLabel") and string.upper(descendant.Text) == targetText then
			return descendant
		end
	end
	return nil
end

local function getBillboardAdornee(template: Model): BasePart?
	local head = template:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end

	local rootPart = template:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end

	return template.PrimaryPart
end

local function getShowcaseBillboard(template: Model): BillboardGui?
	local billboard = template:FindFirstChild(SHOWCASE_BILLBOARD_NAME)
	if billboard and billboard:IsA("BillboardGui") then
		billboard.Adornee = billboard.Adornee or getBillboardAdornee(template)
		return billboard
	end

	billboard = template:FindFirstChildWhichIsA("BillboardGui")
	if billboard then
		billboard.Adornee = billboard.Adornee or getBillboardAdornee(template)
	end
	return billboard
end

local function getShowcaseLabels(template: Model): (TextLabel?, TextLabel?)
	local billboard = getShowcaseBillboard(template)
	if not billboard then
		return nil, nil
	end

	local header = findTextLabel(billboard, FINISHER_LABEL_NAME) or findLabelByText(billboard, "Finisher")
	local timer = findTextLabel(billboard, TIMER_LABEL_NAME) or findLabelByText(billboard, tostring(PREVIEW_SECONDS))
	return header, timer
end

local function getFinisherDisplayName(finisherId: string): string
	local definition = FinisherConfig.GetDefinition(finisherId)
	if definition and typeof(definition.displayName) == "string" and definition.displayName ~= "" then
		return definition.displayName
	end
	return finisherId
end

local function waitForRun(controller, runToken: number, seconds: number): boolean
	local endTime = os.clock() + seconds
	while runToken == controller._runToken and os.clock() < endTime do
		task.wait(math.min(0.1, endTime - os.clock()))
	end
	return runToken == controller._runToken
end

local function addUniqueFinisherId(finisherIds: { string }, seen: { [string]: boolean }, finisherId: any)
	local normalizedFinisherId = FinisherConfig.NormalizeFinisherId(finisherId)
	if normalizedFinisherId == "" or seen[normalizedFinisherId] then
		return
	end

	if not FinisherConfig.GetDefinition(normalizedFinisherId) then
		return
	end

	table.insert(finisherIds, normalizedFinisherId)
	seen[normalizedFinisherId] = true
end

local function buildFallbackShowcaseFinisherIds(crateDefinition): { string }
	local candidates = {}
	local seen = {}
	local rarityWeights = crateDefinition.rarityWeights or {}
	for _, finisherId in ipairs(FinisherConfig.GetCatalogIds()) do
		local definition = FinisherConfig.GetDefinition(finisherId)
		local rarity = definition and definition.rarity
		if rarity and (tonumber(rarityWeights[rarity]) or 0) > 0 then
			addUniqueFinisherId(candidates, seen, finisherId)
		end
	end
	return candidates
end

local function getShowcaseFinisherIds(crateId: string): { string }
	local crateDefinition = CrateRollConfig.GetDefinition(crateId)
	if not crateDefinition then
		return FinisherConfig.GetCatalogIds()
	end

	local finisherIds = {}
	local seen = {}
	for _, finisherId in ipairs(crateDefinition.showcaseFinisherIds or {}) do
		addUniqueFinisherId(finisherIds, seen, finisherId)
	end

	if #finisherIds > 0 then
		return finisherIds
	end

	return buildFallbackShowcaseFinisherIds(crateDefinition)
end

local function shuffleFinisherIds(finisherIds: { string }): { string }
	local shuffled = table.clone(finisherIds)
	for index = #shuffled, 2, -1 do
		local swapIndex = rng:NextInteger(1, index)
		shuffled[index], shuffled[swapIndex] = shuffled[swapIndex], shuffled[index]
	end
	return shuffled
end

local function buildShowcaseBag(crateId: string, lastFinisherId: string?): { string }
	local bag = shuffleFinisherIds(getShowcaseFinisherIds(crateId))
	if #bag > 1 and lastFinisherId and bag[1] == lastFinisherId then
		for index = 2, #bag do
			if bag[index] ~= lastFinisherId then
				bag[1], bag[index] = bag[index], bag[1]
				break
			end
		end
	end
	return bag
end

function FinisherShowcaseController:_nextShowcaseFinisherId(crateId: string): string
	local bag = self._showcaseBags[crateId]
	if not bag or #bag <= 0 then
		bag = buildShowcaseBag(crateId, self._lastShowcaseFinisherIds[crateId])
		self._showcaseBags[crateId] = bag
	end

	local finisherId = table.remove(bag, 1) or ""
	self._lastShowcaseFinisherIds[crateId] = finisherId
	return finisherId
end

function FinisherShowcaseController:_getDescription(): HumanoidDescription?
	if self._description then
		return self._description:Clone()
	end

	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local ok, description = pcall(function()
			return humanoid:GetAppliedDescription()
		end)
		if ok and description then
			self._description = description
			return description:Clone()
		end
	end

	local ok, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(LocalPlayer.UserId)
	end)
	if ok and description then
		self._description = description
		return description:Clone()
	end

	return nil
end

function FinisherShowcaseController:_applyLocalAppearance(humanoid: Humanoid)
	local description = self:_getDescription()
	if not description then
		return
	end

	pcall(function()
		humanoid:ApplyDescription(description)
	end)
	description:Destroy()
end

function FinisherShowcaseController:_makeClone(template: Model): Model?
	if not template.Parent then
		return nil
	end

	local clone = template:Clone()
	clone.Name = template.Name .. LOCAL_CLONE_SUFFIX
	removeCloneRuntimeInstances(clone)
	prepClone(clone)
	clone:PivotTo(template:GetPivot())
	clone.Parent = template.Parent

	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if humanoid then
		self:_applyLocalAppearance(humanoid)
		prepClone(clone)
		playIdle(humanoid)
	end

	return clone
end

function FinisherShowcaseController:_setBillboardState(template: Model, finisherId: string, remainingSeconds: number)
	local header, timer = getShowcaseLabels(template)
	if header then
		header.Text = getFinisherDisplayName(finisherId)
	end
	if timer then
		timer.Text = tostring(remainingSeconds)
	end
end

function FinisherShowcaseController:_countDownToExplosion(template: Model, finisherId: string, runToken: number): boolean
	for remaining = PREVIEW_SECONDS, 1, -1 do
		self:_setBillboardState(template, finisherId, remaining)
		if not waitForRun(self, runToken, 1) then
			return false
		end
	end

	self:_setBillboardState(template, finisherId, 0)
	return true
end

function FinisherShowcaseController:_runShowcase(spec, template: Model, runToken: number)
	task.spawn(function()
		local initialDelay = tonumber(spec.initialDelay) or 0
		if initialDelay > 0 and not waitForRun(self, runToken, initialDelay) then
			return
		end

		while runToken == self._runToken and template.Parent do
			setTemplateHidden(template)

			local finisherId = self:_nextShowcaseFinisherId(spec.crateId)
			local clone = self:_makeClone(template)
			if not self:_countDownToExplosion(template, finisherId, runToken) then
				if clone then
					clone:Destroy()
				end
				return
			end

			local rootPart = clone and clone:FindFirstChild("HumanoidRootPart")
			local position = if rootPart and rootPart:IsA("BasePart") then rootPart.Position else template:GetPivot().Position
			if finisherId ~= "" then
				FinisherVFX.PlayAt(finisherId, position)
			end

			if clone then
				clone:Destroy()
			end

			if not waitForRun(self, runToken, RESPAWN_SECONDS) then
				return
			end
		end
	end)
end

function FinisherShowcaseController:_start()
	self._runToken += 1
	local runToken = self._runToken

	for _, spec in ipairs(SHOWCASE_SPECS) do
		task.spawn(function()
			local template = waitForPath(workspace, spec.path, TEMPLATE_WAIT_SECONDS)
			if runToken ~= self._runToken then
				return
			end
			if not (template and template:IsA("Model")) then
				warn("[FinisherShowcaseController] Missing showcase rig for crate " .. tostring(spec.crateId))
				return
			end

			setTemplateHidden(template)
			self:_runShowcase(spec, template, runToken)
		end)
	end
end

function FinisherShowcaseController:OnStart()
	if self._started then
		return
	end
	self._started = true

	table.insert(self._connections, LocalPlayer.CharacterAppearanceLoaded:Connect(function()
		self._description = nil
	end))
	table.insert(self._connections, LocalPlayer.CharacterAdded:Connect(function()
		self._description = nil
	end))

	self:_start()
end

function FinisherShowcaseController:OnStop()
	self._runToken += 1
	disconnectAll(self._connections)
end

return FinisherShowcaseController
