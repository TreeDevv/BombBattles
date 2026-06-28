local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombHeldVisualFactory = require(ReplicatedStorage.Shared.Effects.BombHeldVisualFactory)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local ReplayHeldBombVisual = {}

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function getHeldBombState(snapshot)
	local animationState = if typeof(snapshot) == "table" and typeof(snapshot.animationState) == "table"
		then snapshot.animationState
		else nil
	if typeof(animationState) ~= "table" then
		return nil
	end

	if typeof(animationState.heldBomb) == "table" then
		return animationState.heldBomb
	end
	if animationState.bombCooking ~= true then
		return nil
	end

	local fuseStartedAt = if isFiniteNumber(animationState.bombCookStartedAt) then animationState.bombCookStartedAt else nil
	return {
		bombType = BombConfig.RuntimeBombName,
		bombSkinId = animationState.bombSkinId,
		fuseStartedAt = fuseStartedAt,
		fuseEndsAt = if fuseStartedAt then fuseStartedAt + BombConfig.FuseSeconds else nil,
		visualScale = BombConfig.HeldVisualScale,
		sizeScale = BombConfig.HeldVisualScale,
	}
end

local function getReplayHandCFrame(model: Model?): CFrame?
	if not model then
		return nil
	end
	local hand = model:FindFirstChild("RightHand", true)
		or model:FindFirstChild("Right Arm", true)
		or model:FindFirstChild("RightLowerArm", true)
		or model:FindFirstChild("RightUpperArm", true)
	if hand and hand:IsA("BasePart") then
		return hand.CFrame
	end
	return nil
end

local function createFallbackHeldBombVisual(visual, skinId: any, visualScale: number?, deps)
	local instance, rootPart, resolvedSkinId = BombVisualUtil.CreateBombVisual(skinId, "ReplayHeldBombVisual", {
		anchored = true,
		canCollide = false,
		canQuery = false,
		massless = true,
		effectState = {
			vfx = true,
			fuseSpark = true,
			trail = false,
		},
		visualScale = visualScale or BombConfig.HeldVisualScale,
	})
	local records, preparedRootPart = deps.prepareReplayClone(instance)
	rootPart = BombVisualUtil.GetRootPart(instance) or preparedRootPart or rootPart
	if not (rootPart and #records > 0) then
		instance:Destroy()
		return nil
	end

	instance.Parent = visual.model
	local heldBomb = {
		instance = instance,
		rootPart = rootPart,
		skinId = resolvedSkinId,
		visualScale = visualScale,
		fallback = true,
	}
	deps.attachReplayBombPulse(heldBomb, instance, rootPart)
	return heldBomb
end

local function ensureReplayHeldBomb(visual, heldBombState, deps)
	if not (visual and visual.model and typeof(heldBombState) == "table") then
		return nil
	end

	local skinId = if typeof(heldBombState.bombSkinId) == "string" and heldBombState.bombSkinId ~= ""
		then heldBombState.bombSkinId
		else visual.bombSkinId
	local visualScale = if isFiniteNumber(heldBombState.visualScale)
		then heldBombState.visualScale
		elseif isFiniteNumber(heldBombState.sizeScale)
		then heldBombState.sizeScale
		else BombConfig.HeldVisualScale
	local current = visual.heldBomb
	if current and current.instance and current.instance.Parent and current.skinId == skinId then
		return current
	end

	ReplayHeldBombVisual.Destroy(visual)
	local heldBomb = BombHeldVisualFactory.Create(visual.model, skinId, visualScale)
	if heldBomb then
		deps.attachReplayBombPulse(heldBomb, heldBomb.instance, heldBomb.rootPart)
	else
		heldBomb = createFallbackHeldBombVisual(visual, skinId, visualScale, deps)
	end
	if heldBomb then
		visual.heldBomb = heldBomb
		RuntimeProfiler.Count("Client/Replay/HeldBombVisualsCreated")
	else
		RuntimeProfiler.Count("Client/Replay/HeldBombVisualsFailed")
	end
	return heldBomb
end

function ReplayHeldBombVisual.Destroy(visual)
	local heldBomb = visual and visual.heldBomb
	if not heldBomb then
		return
	end

	if heldBomb.instance and heldBomb.instance.Parent then
		heldBomb.instance:Destroy()
	end
	visual.heldBomb = nil
end

function ReplayHeldBombVisual.Update(visual, alive: boolean?, snapshot, replayTime: number, deps): boolean
	local heldBombState = getHeldBombState(snapshot)
	if alive == false or not heldBombState then
		ReplayHeldBombVisual.Destroy(visual)
		return false
	end

	local heldBomb = ensureReplayHeldBomb(visual, heldBombState, deps)
	if not heldBomb then
		return false
	end

	if heldBomb.fallback and heldBomb.rootPart then
		local handCFrame = getReplayHandCFrame(visual.model)
		if handCFrame then
			deps.pivotReplayInstance(heldBomb.instance, handCFrame)
		end
	end
	BombVisualUtil.SetEffectState(heldBomb.instance, {
		vfx = true,
		fuseSpark = true,
		trail = false,
	})
	deps.updateReplayBombPulse(heldBomb, heldBombState, replayTime)
	RuntimeProfiler.Count("Client/Replay/HeldBombVisualFrames")
	return true
end

return table.freeze(ReplayHeldBombVisual)
