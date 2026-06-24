local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BombTrajectory = require(ReplicatedStorage.Shared.Common.BombTrajectory)
local BombVisualUtil = require(ReplicatedStorage.Shared.Effects.BombVisualUtil)
local InstanceUtil = require(ReplicatedStorage.Shared.Common.InstanceUtil)

local BombTrajectoryPreview = {}
BombTrajectoryPreview.__index = BombTrajectoryPreview

local DEFAULT_FOLDER_NAME = "BombPreview"
local DEFAULT_TEMPLATE_PATH = { "Assets", "VFX", "Trajectory", "TrajectoryLine" }
local DEFAULT_PREVIEW_NAME = "BombTrajectoryPreview"
local BEAM_CURVE_EPSILON = 1e-4

type TrajectoryPreview = {
	model: Model,
	startPart: BasePart,
	endPart: BasePart,
	startAttachment: Attachment,
	endAttachment: Attachment,
	beams: { Beam },
	emitters: { ParticleEmitter },
	custom: boolean,
}

local warnedCustomTrajectorySkins: { [string]: boolean } = {}

local function getNamedBasePart(parent: Instance, childName: string): BasePart?
	local child = parent:FindFirstChild(childName)
	return if child and child:IsA("BasePart") then child else nil
end

local function getNamedAttachment(parent: Instance, childName: string): Attachment?
	local child = parent:FindFirstChild(childName)
	return if child and child:IsA("Attachment") then child else nil
end

local function collectTrajectoryPreviewDescendants(model: Model): ({ Beam }, { ParticleEmitter })
	local beams: { Beam } = {}
	local emitters: { ParticleEmitter } = {}

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("Beam") then
			table.insert(beams, descendant)
		elseif descendant:IsA("ParticleEmitter") then
			table.insert(emitters, descendant)
		end
	end

	return beams, emitters
end

local function setTrajectoryPreviewEnabled(preview: TrajectoryPreview, enabled: boolean)
	for _, beam in ipairs(preview.beams) do
		beam.Enabled = enabled
	end
	for _, emitter in ipairs(preview.emitters) do
		emitter.Enabled = enabled
	end
end

local function tintTrajectoryPreview(preview: TrajectoryPreview, color: Color3)
	local colorSequence = ColorSequence.new(color)
	for _, beam in ipairs(preview.beams) do
		beam.Color = colorSequence
	end
	for _, emitter in ipairs(preview.emitters) do
		emitter.Color = colorSequence
	end
end

local function getUnitOrFallback(vector: Vector3, fallback: Vector3): Vector3
	if vector.Magnitude > BEAM_CURVE_EPSILON then
		return vector.Unit
	end
	if fallback.Magnitude > BEAM_CURVE_EPSILON then
		return fallback.Unit
	end
	return Vector3.xAxis
end

local function cframeFromRightVector(position: Vector3, rightVector: Vector3): CFrame
	local right = getUnitOrFallback(rightVector, Vector3.xAxis)
	local upReference = if math.abs(right:Dot(Vector3.yAxis)) < 0.95 then Vector3.yAxis else Vector3.zAxis
	local back = right:Cross(upReference)
	if back.Magnitude <= BEAM_CURVE_EPSILON then
		back = Vector3.zAxis
	else
		back = back.Unit
	end
	local up = back:Cross(right).Unit

	return CFrame.fromMatrix(position, right, up, back)
end

local function warnMalformedCustomTrajectory(skinId: string, reason: string)
	if warnedCustomTrajectorySkins[skinId] then
		return
	end

	warnedCustomTrajectorySkins[skinId] = true
	warn(("[BombTrajectoryPreview] Bomb skin %s has a malformed trajectory Beam asset (%s); using the default"):format(skinId, reason))
end

local function normalizeTrajectoryTemplateClone(clone: Instance): (Model?, string)
	if clone:IsA("Model") then
		return clone, ""
	end

	if clone:IsA("BasePart") then
		local startAttachment = getNamedAttachment(clone, "Start")
		local endAttachment = getNamedAttachment(clone, "End")
		if not (startAttachment and endAttachment) then
			clone:Destroy()
			return nil, "expected Start and End attachments on the Beam part"
		end

		local model = Instance.new("Model")
		model.Name = clone.Name

		local startPart = Instance.new("Part")
		startPart.Name = "Start"
		startPart.Size = Vector3.one
		startAttachment.Parent = startPart
		startPart.Parent = model

		local endPart = Instance.new("Part")
		endPart.Name = "End"
		endPart.Size = Vector3.one
		endAttachment.Parent = endPart
		endPart.Parent = model

		clone:Destroy()
		return model, ""
	end

	clone:Destroy()
	return nil, "expected a Model or BasePart"
end

local function assembleTrajectoryPreview(clone: Model, custom: boolean): (TrajectoryPreview?, string)
	local startPart = getNamedBasePart(clone, "Start")
	local endPart = getNamedBasePart(clone, "End")
	if not (startPart and endPart) then
		clone:Destroy()
		return nil, "expected Start and End BasePart children"
	end

	local startAttachment = getNamedAttachment(startPart, "Start")
	local endAttachment = getNamedAttachment(endPart, "End")
	if not (startAttachment and endAttachment) then
		clone:Destroy()
		return nil, "expected Start.Start and End.End attachments"
	end

	local beams, emitters = collectTrajectoryPreviewDescendants(clone)
	if #beams == 0 then
		clone:Destroy()
		return nil, "expected at least one Beam descendant"
	end

	for _, part in ipairs({ startPart, endPart }) do
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
	end

	startAttachment.CFrame = CFrame.new()
	endAttachment.CFrame = CFrame.new()

	for _, beam in ipairs(beams) do
		beam.Attachment0 = endAttachment
		beam.Attachment1 = startAttachment
	end

	return {
		model = clone,
		startPart = startPart,
		endPart = endPart,
		startAttachment = startAttachment,
		endAttachment = endAttachment,
		beams = beams,
		emitters = emitters,
		custom = custom,
	}, ""
end

function BombTrajectoryPreview.new(options)
	local self = setmetatable({}, BombTrajectoryPreview)
	self._folder = nil :: Folder?
	self._primary = nil :: TrajectoryPreview?
	self._extra = {} :: { TrajectoryPreview }
	self._skinId = nil :: string?
	self._warnedMissing = false
	self._folderName = options and options.folderName or DEFAULT_FOLDER_NAME
	self._templatePath = options and options.templatePath or DEFAULT_TEMPLATE_PATH
	self._previewName = options and options.previewName or DEFAULT_PREVIEW_NAME
	self._getSkinId = options and options.getSkinId
	self._findHit = options and options.findHit
	return self
end

function BombTrajectoryPreview:_getSkinId(): string
	local getSkinId = self._getSkinId
	if typeof(getSkinId) ~= "function" then
		return ""
	end

	local skinId = getSkinId()
	return if typeof(skinId) == "string" then skinId else ""
end

function BombTrajectoryPreview:_getPreviewFolder(): Folder
	if self._folder and self._folder.Parent then
		return self._folder
	end

	local folder = Instance.new("Folder")
	folder.Name = self._folderName
	folder.Parent = workspace
	self._folder = folder
	return folder
end

function BombTrajectoryPreview:_warnMissing(reason: string)
	if self._warnedMissing then
		return
	end

	self._warnedMissing = true
	warn("[BombTrajectoryPreview] Missing or malformed trajectory preview VFX: " .. reason)
end

function BombTrajectoryPreview:_createPreview(name: string): TrajectoryPreview?
	local preview: TrajectoryPreview?
	local skinId = self:_getSkinId()
	local customTemplate = BombVisualUtil.GetSkinTrajectoryBeamTemplate(skinId)
	if customTemplate then
		local clone, normalizeReason = normalizeTrajectoryTemplateClone(customTemplate:Clone())
		if clone then
			clone.Name = name
			local assembled, assembleReason = assembleTrajectoryPreview(clone, true)
			if assembled then
				preview = assembled
			else
				warnMalformedCustomTrajectory(skinId, assembleReason)
			end
		else
			warnMalformedCustomTrajectory(skinId, normalizeReason)
		end
	end

	if not preview then
		local template = InstanceUtil.GetByPath(ReplicatedStorage, self._templatePath)
		if not (template and template:IsA("Model")) then
			self:_warnMissing("ReplicatedStorage.Assets.VFX.Trajectory.TrajectoryLine was not found")
			return nil
		end

		local clone = template:Clone()
		clone.Name = name
		local assembled, assembleReason = assembleTrajectoryPreview(clone, false)
		if not assembled then
			self:_warnMissing(assembleReason)
			return nil
		end
		preview = assembled
	end

	setTrajectoryPreviewEnabled(preview, false)
	preview.model.Parent = self:_getPreviewFolder()
	return preview
end

function BombTrajectoryPreview:Destroy()
	if self._primary then
		self._primary.model:Destroy()
		self._primary = nil
	end

	for _, preview in pairs(self._extra) do
		preview.model:Destroy()
	end
	table.clear(self._extra)
end

function BombTrajectoryPreview:_refreshSkin()
	local skinId = self:_getSkinId()
	if self._skinId == skinId then
		return
	end

	self._skinId = skinId
	self:Destroy()
end

function BombTrajectoryPreview:_ensureAt(index: number): TrajectoryPreview?
	if index <= 1 then
		self:_refreshSkin()
		if self._primary and self._primary.model.Parent then
			return self._primary
		end
		self._primary = self:_createPreview(self._previewName)
		return self._primary
	end

	self:_refreshSkin()
	local existing = self._extra[index - 1]
	if existing and existing.model.Parent then
		return existing
	end

	local preview = self:_createPreview(self._previewName .. tostring(index))
	self._extra[index - 1] = preview
	return preview
end

function BombTrajectoryPreview:EnsurePrimary(): TrajectoryPreview?
	return self:_ensureAt(1)
end

function BombTrajectoryPreview:HideExtra(startIndex: number?)
	local first = math.max(startIndex or 1, 1)
	for index = first, #self._extra do
		local preview = self._extra[index]
		if preview then
			setTrajectoryPreviewEnabled(preview, false)
		end
	end
end

function BombTrajectoryPreview:HideAll()
	if self._primary then
		setTrajectoryPreviewEnabled(self._primary, false)
	end
	self:HideExtra(1)
end

function BombTrajectoryPreview:Show(
	trajectory: BombTrajectory.Path,
	maxPreviewTime: number,
	color: Color3,
	previewIndex: number?
): boolean
	local index = math.max(math.floor(previewIndex or 1), 1)
	maxPreviewTime = math.min(maxPreviewTime, trajectory.duration)
	if maxPreviewTime <= 0 then
		local existing = if index <= 1 then self._primary else self._extra[index - 1]
		if existing then
			setTrajectoryPreviewEnabled(existing, false)
		end
		return false
	end

	local preview = self:_ensureAt(index)
	if not preview then
		return false
	end

	local findHit = self._findHit
	local hit, endElapsed, displayEndPosition
	if typeof(findHit) == "function" then
		hit, endElapsed, displayEndPosition = findHit(trajectory, maxPreviewTime)
	end
	endElapsed = if typeof(endElapsed) == "number" then endElapsed else maxPreviewTime

	local origin = trajectory.origin
	local endAlpha = math.clamp(endElapsed / trajectory.duration, 0, 1)
	local endPosition = if typeof(displayEndPosition) == "Vector3"
		then displayEndPosition
		elseif hit
		then hit.Position
		else BombTrajectory.Evaluate(trajectory, endAlpha)
	local startVelocity = BombTrajectory.GetVelocity(trajectory, 0)
	local endVelocity = BombTrajectory.GetVelocity(trajectory, endAlpha)
	local reversePathDirection = origin - endPosition

	preview.startPart.CFrame = cframeFromRightVector(origin, getUnitOrFallback(-startVelocity, reversePathDirection))
	preview.endPart.CFrame = cframeFromRightVector(endPosition, getUnitOrFallback(-endVelocity, reversePathDirection))

	local startCurveSize = startVelocity.Magnitude * endElapsed / 3
	local endCurveSize = endVelocity.Magnitude * endElapsed / 3
	for _, beam in ipairs(preview.beams) do
		beam.CurveSize0 = endCurveSize
		beam.CurveSize1 = startCurveSize
	end

	if not preview.custom then
		tintTrajectoryPreview(preview, color)
	end
	setTrajectoryPreviewEnabled(preview, true)
	return true
end

return BombTrajectoryPreview
