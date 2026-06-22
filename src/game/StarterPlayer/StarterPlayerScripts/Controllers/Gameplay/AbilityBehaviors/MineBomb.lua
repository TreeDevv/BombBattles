local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityPlacementFlow = require(ReplicatedStorage.Shared.Common.AbilityPlacementFlow)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)

type AbilityControllerLike = AbilityTypes.AbilityControllerLike
type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext
type PreviewState = {
	active: boolean,
	controller: AbilityControllerLike?,
	slot: string,
	abilityId: string,
	definition: AbilityDefinition?,
	ghost: Instance?,
	inputConnection: RBXScriptConnection?,
	valid: boolean,
	surfacePosition: Vector3?,
	surfaceNormal: Vector3?,
	floorPosition: Vector3?,
	floatingPosition: Vector3?,
	facing: Vector3?,
}

local MineBomb = {} :: AbilityTypes.ClientBehavior

local PREVIEW_FOLDER_NAME = "MineBombPreview"
local RENDER_STEP_NAME = "BombBattlesMineBombPreview"
local COMMIT_ACTION_NAME = "BombBattlesMineBombCommit"
local preview: PreviewState = {
	active = false,
	controller = nil,
	slot = "",
	abilityId = "",
	definition = nil,
	ghost = nil,
	inputConnection = nil,
	valid = false,
	surfacePosition = nil,
	surfaceNormal = nil,
	floorPosition = nil,
	floatingPosition = nil,
	facing = nil,
}

local function getByPath(root: Instance, path: { string }): Instance?
	local current: Instance? = root
	for _, name in ipairs(path) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getTemplate(definition: AbilityDefinition?): Instance?
	local path = definition and definition.assetPath
	if typeof(path) ~= "table" then
		return nil
	end

	local template = getByPath(ReplicatedStorage, path)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

local function cancelPreview()
	AbilityPlacementFlow.Cancel(preview, RENDER_STEP_NAME, COMMIT_ACTION_NAME)
end

function MineBomb.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	if context.inputState and context.inputState ~= Enum.UserInputState.Begin then
		return true
	end

	if preview.active then
		local previousSlot = preview.slot
		local previousAbilityId = preview.abilityId
		cancelPreview()
		if previousSlot == context.slot and previousAbilityId == context.abilityId then
			return true
		end
	end

	if context.controller:GetCooldownRemaining(context.slot) > 0 then
		return true
	end

	local template = getTemplate(context.definition)
	if not template then
		warn("[MineBomb] Missing ReplicatedStorage.Assets.Abilities.MineBomb.Landmine")
		return true
	end

	return AbilityPlacementFlow.StartPreview({
		state = preview,
		abilityName = "MineBomb",
		previewFolderName = PREVIEW_FOLDER_NAME,
		renderStepName = RENDER_STEP_NAME,
		commitActionName = COMMIT_ACTION_NAME,
		template = template,
		context = context,
		mode = "Floor",
		requirePlacementClear = false,
	})
end

function MineBomb.OnEffect(_context: ClientEffectContext)
end

return MineBomb
