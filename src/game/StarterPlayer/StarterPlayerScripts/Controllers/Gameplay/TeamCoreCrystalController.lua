local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RoundConfig = require(ReplicatedStorage.Shared.Config.RoundConfig)

local CRYSTAL_NAME = "Crystal"
local ROTATION_SPEED_RADIANS = math.rad(168)
local BOB_AMPLITUDE = 0.38
local BOB_SPEED_RADIANS = math.pi * 2 * 1.15
local TAU = math.pi * 2
local CHILD_AXES = {
	Vector3.xAxis,
	Vector3.yAxis,
	Vector3.zAxis,
	Vector3.new(1, 1, 0).Unit,
	Vector3.new(0, 1, 1).Unit,
	Vector3.new(1, 0, 1).Unit,
}

type ChildRecord = {
	instance: PVInstance,
	localPivot: CFrame,
	axis: Vector3,
	speed: number,
	phase: number,
}

type CrystalRecord = {
	crystal: PVInstance,
	basePivot: CFrame,
	elapsed: number,
	bobPhase: number,
	children: { ChildRecord },
}

local TeamCoreCrystalController = {}

local records: { [Instance]: CrystalRecord } = {}
local retryConnections: { [Instance]: RBXScriptConnection } = {}
local renderConnection: RBXScriptConnection? = nil
local tagAddedConnection: RBXScriptConnection? = nil
local tagRemovedConnection: RBXScriptConnection? = nil
local trackCore: (Instance) -> ()

local function hasBasePartDescendant(instance: Instance): boolean
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			return true
		end
	end
	return false
end

local function getCrystal(core: Instance): PVInstance?
	if not core:IsA("Model") then
		return nil
	end

	local crystal = core:FindFirstChild(CRYSTAL_NAME)
	if crystal and crystal:IsA("PVInstance") then
		return crystal
	end

	return nil
end

local function getCorePhase(core: Instance): number
	local teamName = core:GetAttribute("Team")
	if teamName == "Blue" then
		return math.pi
	end
	return 0
end

local function collectCrystalChildren(crystal: PVInstance, basePivot: CFrame): { ChildRecord }
	local children = {}
	for _, child in ipairs(crystal:GetChildren()) do
		if child:IsA("PVInstance") then
			local index = #children + 1
			local direction = if index % 2 == 0 then -1 else 1
			local axis = CHILD_AXES[((index - 1) % #CHILD_AXES) + 1]

			table.insert(children, {
				instance = child,
				localPivot = basePivot:ToObjectSpace(child:GetPivot()),
				axis = axis,
				speed = ROTATION_SPEED_RADIANS * (1.05 + (index % 4) * 0.2) * direction,
				phase = index * math.pi * 0.37,
			})
		end
	end

	return children
end

local function untrackCore(core: Instance)
	records[core] = nil
	local retryConnection = retryConnections[core]
	if retryConnection then
		retryConnection:Disconnect()
		retryConnections[core] = nil
	end
end

local function retryWhenPartsArrive(core: Instance, crystal: PVInstance)
	if retryConnections[core] then
		return
	end

	retryConnections[core] = crystal.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			untrackCore(core)
			trackCore(core)
		end
	end)
end

trackCore = function(core: Instance)
	if not core:IsDescendantOf(workspace) then
		untrackCore(core)
		return
	end

	local crystal = getCrystal(core)
	if not crystal then
		untrackCore(core)
		return
	end
	if not hasBasePartDescendant(crystal) then
		records[core] = nil
		retryWhenPartsArrive(core, crystal)
		return
	end

	untrackCore(core)
	local basePivot = crystal:GetPivot()
	records[core] = {
		crystal = crystal,
		basePivot = basePivot,
		elapsed = 0,
		bobPhase = getCorePhase(core),
		children = collectCrystalChildren(crystal, basePivot),
	}
end

local function stepCrystals(deltaTime: number)
	for core, record in pairs(records) do
		local crystal = record.crystal
		if not core.Parent
			or not core:IsDescendantOf(workspace)
			or not crystal.Parent
			or not CollectionService:HasTag(core, RoundConfig.Tags.TeamCore)
		then
			untrackCore(core)
			continue
		end

		record.elapsed = (record.elapsed + deltaTime) % 120
		local angle = (record.elapsed * ROTATION_SPEED_RADIANS) % TAU
		local bobOffset = math.sin(record.elapsed * BOB_SPEED_RADIANS + record.bobPhase) * BOB_AMPLITUDE
		local crystalPivot = record.basePivot * CFrame.new(0, bobOffset, 0) * CFrame.Angles(0, angle, 0)
		crystal:PivotTo(crystalPivot)

		for _, childRecord in ipairs(record.children) do
			if childRecord.instance.Parent == crystal then
				local childAngle = (record.elapsed * childRecord.speed + childRecord.phase) % TAU
				childRecord.instance:PivotTo(
					crystalPivot * childRecord.localPivot * CFrame.fromAxisAngle(childRecord.axis, childAngle)
				)
			end
		end
	end
end

local function trackExistingCores()
	for _, core in ipairs(CollectionService:GetTagged(RoundConfig.Tags.TeamCore)) do
		trackCore(core)
	end
end

function TeamCoreCrystalController:OnStart()
	trackExistingCores()

	tagAddedConnection = CollectionService:GetInstanceAddedSignal(RoundConfig.Tags.TeamCore):Connect(trackCore)
	tagRemovedConnection = CollectionService:GetInstanceRemovedSignal(RoundConfig.Tags.TeamCore):Connect(untrackCore)
	renderConnection = RunService.RenderStepped:Connect(stepCrystals)
end

function TeamCoreCrystalController:Destroy()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	if tagAddedConnection then
		tagAddedConnection:Disconnect()
		tagAddedConnection = nil
	end
	if tagRemovedConnection then
		tagRemovedConnection:Disconnect()
		tagRemovedConnection = nil
	end
	table.clear(records)
end

return TeamCoreCrystalController
