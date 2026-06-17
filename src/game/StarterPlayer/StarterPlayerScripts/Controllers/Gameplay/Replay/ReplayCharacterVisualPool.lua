local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local ReplayCharacterVisualPool = {}

local LOCAL_REPLAY_ATTR = "BombBattlesLocalReplay"
local POOL_FOLDER_NAME = "_LocalReplayVisualPool"
local MAX_POOLED_VISUALS = 18

local LocalPlayer = Players.LocalPlayer
local pooledVisuals = {}
local pooledVisualCount = 0

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function setPartVisible(part: BasePart, visible: boolean, transparency: number?)
	part.LocalTransparencyModifier = 0
	part.Transparency = if visible then (transparency or 0) else 1
end

local function pivotInstance(instance: Instance, cframe: CFrame)
	if instance:IsA("Model") then
		instance:PivotTo(cframe)
	elseif instance:IsA("BasePart") then
		instance.CFrame = cframe
	end
end

local function getPoolFolder(): Folder
	local name = POOL_FOLDER_NAME .. "_" .. tostring(LocalPlayer.UserId)
	local existing = workspace:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder:SetAttribute(LOCAL_REPLAY_ATTR, true)
	folder.Parent = workspace
	return folder
end

local function hideVisual(visual)
	for _, record in ipairs(visual.parts or {}) do
		local part = record.part
		if part and part.Parent then
			setPartVisible(part, false, record.transparency)
		end
	end
	if visual.nameplate then
		visual.nameplate.Enabled = false
	end
	if visual.highlight then
		visual.highlight.Enabled = false
	end
	if visual.animationDriver and type(visual.animationDriver.Reset) == "function" then
		pcall(function()
			visual.animationDriver:Reset()
		end)
	end
	if visual.hipBomb then
		if type(visual.hipBomb.Reset) == "function" then
			pcall(function()
				visual.hipBomb:Reset()
			end)
		else
			pcall(function()
				visual.hipBomb:SetVisible(false)
			end)
		end
	end
	visual.lastCFrame = nil
	if visual.model and visual.model.Parent then
		pivotInstance(visual.model, CFrame.new(0, -10000, 0))
	end
end

local function destroyVisual(visual)
	if visual.animationDriver then
		pcall(function()
			visual.animationDriver:Destroy()
		end)
		visual.animationDriver = nil
	end
	if visual.hipBomb then
		pcall(function()
			visual.hipBomb:Destroy()
		end)
		visual.hipBomb = nil
	end
	if visual.model then
		visual.model:Destroy()
	end
end

local function trimPool()
	while pooledVisualCount > MAX_POOLED_VISUALS do
		local removed = false
		for key, bucket in pairs(pooledVisuals) do
			local visual = table.remove(bucket, 1)
			if visual then
				pooledVisualCount -= 1
				destroyVisual(visual)
				removed = true
				break
			end
			if #bucket == 0 then
				pooledVisuals[key] = nil
			end
		end
		if not removed then
			break
		end
	end
end

function ReplayCharacterVisualPool.BuildKey(kind: string, userId: any, teamName: any, bombSkinId: any, displayName: any): string
	return table.concat({
		kind,
		tostring(if isFiniteNumber(userId) then math.floor(userId) else userId),
		tostring(teamName),
		tostring(bombSkinId),
		tostring(displayName),
	}, "|")
end

function ReplayCharacterVisualPool.Take(kind: string, parent: Instance, userId: any, teamName: any, bombSkinId: any, displayName: any)
	local key = ReplayCharacterVisualPool.BuildKey(kind, userId, teamName, bombSkinId, displayName)
	local bucket = pooledVisuals[key]
	local visual = bucket and table.remove(bucket)
	if not visual then
		return nil
	end
	pooledVisualCount = math.max(pooledVisualCount - 1, 0)
	if visual.model and visual.model.Parent then
		visual.model.Parent = parent
	end
	visual.replayPoolKey = key
	RuntimeProfiler.Count("Client/Replay/CharacterVisualPoolHits")
	return visual
end

function ReplayCharacterVisualPool.Release(visual): boolean
	local model = visual and visual.model
	local key = visual and visual.replayPoolKey
	if not (model and key and model.Parent) then
		return false
	end

	hideVisual(visual)
	model.Parent = getPoolFolder()
	local bucket = pooledVisuals[key]
	if not bucket then
		bucket = {}
		pooledVisuals[key] = bucket
	end
	table.insert(bucket, visual)
	pooledVisualCount += 1
	RuntimeProfiler.Count("Client/Replay/CharacterVisualPoolReleases")
	trimPool()
	return true
end

return table.freeze(ReplayCharacterVisualPool)
