local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local POTGCutsceneConfig = require(ReplicatedStorage.Shared.Config.POTGCutsceneConfig)
local RemoteUtil = require(ReplicatedStorage.Shared.Common.RemoteUtil)

local RoundPOTGIntroRuntime = {}

local ASSETS_FOLDER_NAME = "Assets"
local CUTSCENES_FOLDER_NAME = "Cutscenes"
local HIGHLIGHT_INTROS_FOLDER_NAME = "HighlightIntros"
local PREPARED_HIGHLIGHT_INTROS_FOLDER_NAME = "PreparedHighlightIntros"

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function getOrCreateAssetsFolder(): Folder
	return RemoteUtil.EnsureFolder(ReplicatedStorage, ASSETS_FOLDER_NAME)
end

local function getPreparedHighlightIntrosFolder(): Folder
	return RemoteUtil.EnsureFolder(getOrCreateAssetsFolder(), PREPARED_HIGHLIGHT_INTROS_FOLDER_NAME)
end

local function getHighlightIntroTemplate(cutsceneSpec): Instance?
	local assets = ReplicatedStorage:FindFirstChild(ASSETS_FOLDER_NAME)
	local cutscenes = assets and assets:FindFirstChild(CUTSCENES_FOLDER_NAME)
	local replicatedTemplate = cutscenes and cutscenes:FindFirstChild(cutsceneSpec.replicatedAssetName)
	if replicatedTemplate and (replicatedTemplate:IsA("Folder") or replicatedTemplate:IsA("Model")) then
		return replicatedTemplate
	end

	local highlightIntros = workspace:FindFirstChild(HIGHLIGHT_INTROS_FOLDER_NAME)
	local template = highlightIntros and highlightIntros:FindFirstChild(cutsceneSpec.assetFolderName)
	return if template and (template:IsA("Folder") or template:IsA("Model")) then template else nil
end

local function getHighlightIntroCharacterRig(root: Instance, cutsceneSpec): Model?
	local rig = root:FindFirstChild(cutsceneSpec.characterRigName)
	if rig and rig:IsA("Model") then
		return rig
	end

	rig = root:FindFirstChild("CharacterRig")
	return if rig and rig:IsA("Model") then rig else nil
end

local function sanitizeDescriptionForRig(description: HumanoidDescription, humanoid: Humanoid)
	if humanoid.RigType ~= Enum.HumanoidRigType.R6 then
		return
	end

	local ok, headAssetId = pcall(function()
		return description.Head
	end)
	if ok and isFiniteNumber(headAssetId) and headAssetId ~= 0 then
		pcall(function()
			description.Head = 0
		end)
	end
end

local function captureHighlightIntroBombMotor(root: Instance, cutsceneSpec)
	local rig = getHighlightIntroCharacterRig(root, cutsceneSpec)
	local rightArm = rig and rig:FindFirstChild("Right Arm")
	local bombMotor = rightArm and rightArm:FindFirstChild("Bomb")
	if not (bombMotor and bombMotor:IsA("Motor6D")) then
		return nil
	end

	return {
		c0 = bombMotor.C0,
		c1 = bombMotor.C1,
		name = bombMotor.Name,
	}
end

local function restoreHighlightIntroBombMotor(root: Instance, cutsceneSpec, snapshot)
	if not snapshot then
		return
	end

	local rig = getHighlightIntroCharacterRig(root, cutsceneSpec)
	local rightArm = rig and rig:FindFirstChild("Right Arm")
	local bomb = root:FindFirstChild("Bomb")
	if not (rightArm and rightArm:IsA("BasePart") and bomb and bomb:IsA("BasePart")) then
		return
	end

	local bombMotor = rightArm:FindFirstChild(snapshot.name)
	if not (bombMotor and bombMotor:IsA("Motor6D")) then
		bombMotor = Instance.new("Motor6D")
		bombMotor.Name = snapshot.name
		bombMotor.Parent = rightArm
	end
	bombMotor.Part0 = rightArm
	bombMotor.Part1 = bomb
	bombMotor.C0 = snapshot.c0
	bombMotor.C1 = snapshot.c1
end

local function getRelativePath(root: Instance, descendant: Instance): { string }?
	if descendant == root then
		return {}
	end
	if not descendant:IsDescendantOf(root) then
		return nil
	end

	local path = {}
	local current: Instance? = descendant
	while current and current ~= root do
		table.insert(path, 1, current.Name)
		current = current.Parent
	end
	return path
end

local function findByRelativePath(root: Instance, path: { string }?): Instance?
	if not path then
		return nil
	end

	local current: Instance? = root
	for _, name in ipairs(path) do
		current = current and current:FindFirstChild(name) or nil
		if not current then
			return nil
		end
	end
	return current
end

local function captureHighlightIntroExternalRigJoints(root: Instance, cutsceneSpec)
	local rig = getHighlightIntroCharacterRig(root, cutsceneSpec)
	if not rig then
		return {}
	end

	local snapshots = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if not descendant:IsA("JointInstance") then
			continue
		end

		local part0 = descendant.Part0
		local part1 = descendant.Part1
		if not (part0 and part1 and part0:IsDescendantOf(root) and part1:IsDescendantOf(root)) then
			continue
		end

		local part0InRig = part0:IsDescendantOf(rig)
		local part1InRig = part1:IsDescendantOf(rig)
		if part0InRig == part1InRig then
			continue
		end

		table.insert(snapshots, {
			className = descendant.ClassName,
			name = descendant.Name,
			parentPath = getRelativePath(root, descendant.Parent),
			part0Path = getRelativePath(root, part0),
			part1Path = getRelativePath(root, part1),
			c0 = descendant.C0,
			c1 = descendant.C1,
		})
	end

	return snapshots
end

local function restoreHighlightIntroExternalRigJoints(root: Instance, snapshots)
	for _, snapshot in ipairs(snapshots or {}) do
		local parent = findByRelativePath(root, snapshot.parentPath)
		local part0 = findByRelativePath(root, snapshot.part0Path)
		local part1 = findByRelativePath(root, snapshot.part1Path)
		if not (parent and part0 and part0:IsA("BasePart") and part1 and part1:IsA("BasePart")) then
			continue
		end

		local joint: JointInstance? = nil
		local existing = parent:FindFirstChild(snapshot.name)
		if existing and existing:IsA("JointInstance") and existing.ClassName == snapshot.className then
			joint = existing
		end

		if not joint then
			local ok, created = pcall(function()
				return Instance.new(snapshot.className)
			end)
			if not (ok and created and created:IsA("JointInstance")) then
				continue
			end
			joint = created
			joint.Name = snapshot.name
			joint.Parent = parent
		end

		joint.Part0 = part0
		joint.Part1 = part1
		joint.C0 = snapshot.c0
		joint.C1 = snapshot.c1
	end
end

function RoundPOTGIntroRuntime.CleanupClone(clones: { Instance }, clone: Instance?)
	if not clone then
		return
	end

	for index = #clones, 1, -1 do
		if clones[index] == clone then
			table.remove(clones, index)
		end
	end

	if clone.Parent then
		clone:Destroy()
	end
end

function RoundPOTGIntroRuntime.Cleanup(clones: { Instance })
	for index = #clones, 1, -1 do
		local clone = clones[index]
		table.remove(clones, index)
		if clone and clone.Parent then
			clone:Destroy()
		end
	end
end

function RoundPOTGIntroRuntime.Prepare(payload, options): Instance?
	if typeof(payload) ~= "table" or not isFiniteNumber(payload.potgPlayerUserId) then
		return nil
	end
	if typeof(options) ~= "table" then
		options = {}
	end

	local clones = if typeof(options.clones) == "table" then options.clones else {}
	local roundId = options.roundId
	local serial = if isFiniteNumber(options.serial) then math.floor(options.serial) else #clones + 1
	local userId = math.floor(payload.potgPlayerUserId)
	if userId == 0 then
		return nil
	end

	local cutsceneSpec = POTGCutsceneConfig.GetCutscene(payload.cutsceneId)
	if not cutsceneSpec then
		return nil
	end

	local template = getHighlightIntroTemplate(cutsceneSpec)
	if not template then
		warn(("[RoundPOTGIntroRuntime] Missing highlight intro template for %s"):format(tostring(cutsceneSpec.id)))
		return nil
	end

	local clone = template:Clone()
	clone.Name = ("POTGIntro_%s_%s_%d"):format(tostring(roundId), tostring(userId), serial)

	local rig = getHighlightIntroCharacterRig(clone, cutsceneSpec)
	local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		clone:Destroy()
		warn(("[RoundPOTGIntroRuntime] Prepared highlight intro %s is missing %s.Humanoid"):format(
			tostring(cutsceneSpec.id),
			tostring(cutsceneSpec.characterRigName)
		))
		return nil
	end
	local head = rig and rig:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then
		clone:Destroy()
		warn(("[RoundPOTGIntroRuntime] Prepared highlight intro %s is missing %s.Head"):format(
			tostring(cutsceneSpec.id),
			tostring(cutsceneSpec.characterRigName)
		))
		return nil
	end

	local okDescription, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
	end)
	if not (okDescription and description) then
		clone:Destroy()
		warn(("[RoundPOTGIntroRuntime] Failed to get POTG intro appearance for userId %s: %s"):format(
			tostring(userId),
			tostring(description)
		))
		return nil
	end
	sanitizeDescriptionForRig(description, humanoid)

	local bombMotorSnapshot = captureHighlightIntroBombMotor(clone, cutsceneSpec)
	local externalJointSnapshots = captureHighlightIntroExternalRigJoints(clone, cutsceneSpec)
	local okApply, applyErr = pcall(function()
		humanoid:ApplyDescription(description)
	end)
	restoreHighlightIntroBombMotor(clone, cutsceneSpec, bombMotorSnapshot)
	restoreHighlightIntroExternalRigJoints(clone, externalJointSnapshots)
	description:Destroy()

	if not okApply then
		clone:Destroy()
		warn(("[RoundPOTGIntroRuntime] Failed to apply POTG intro appearance for userId %s: %s"):format(
			tostring(userId),
			tostring(applyErr)
		))
		return nil
	end

	clone.Parent = getPreparedHighlightIntrosFolder()
	table.insert(clones, clone)

	local lifetimeSeconds = if isFiniteNumber(options.lifetimeSeconds) then math.max(options.lifetimeSeconds, 0) else 65
	task.delay(lifetimeSeconds, function()
		RoundPOTGIntroRuntime.CleanupClone(clones, clone)
	end)

	return clone
end

return table.freeze(RoundPOTGIntroRuntime)
