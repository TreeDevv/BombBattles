local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AbilityConfig = require(ReplicatedStorage.Shared.Config.AbilityConfig)
local AbilityTypes = require(ReplicatedStorage.Shared.Common.AbilityTypes)
local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local BombController = require(script.Parent.Parent:WaitForChild("BombController"))

type AbilityDefinition = AbilityTypes.AbilityDefinition
type ClientActivateRequestedContext = AbilityTypes.ClientActivateRequestedContext
type ClientEffectContext = AbilityTypes.ClientEffectContext

type ThrowState = {
	slot: string,
	definition: AbilityDefinition,
}

local FireBomb = {} :: AbilityTypes.ClientBehavior
FireBomb.HandlesInputState = true

local activeThrow: ThrowState? = nil
local predictedCooldownEndsAt = 0
local previewConnection: RBXScriptConnection? = nil
local emitModule = nil
local emitModuleInitialized = false
local warnedMissingEmitModule = false
local warnedMissingTemplate = false
local warnedInvalidTemplate = false

local function getDefinitionNumber(definition: AbilityDefinition?, key: string, fallback: number): number
	local value = if definition then definition[key] else nil
	return if typeof(value) == "number" then value else fallback
end

local function getDefinitionColor(definition: AbilityDefinition?, key: string, fallback: Color3): Color3
	local value = if definition then definition[key] else nil
	return if typeof(value) == "Color3" then value else fallback
end

local function clearPreview()
	if previewConnection then
		previewConnection:Disconnect()
		previewConnection = nil
	end

	BombController:HideAbilityTrajectoryPreview()
end

local function updatePreview()
	local state = activeThrow
	if state and not BombController:IsHoldingBomb() then
		activeThrow = nil
		BombController:SetPrimaryBombInputSuppressed(false)
		clearPreview()
		return
	end

	if not state then
		clearPreview()
		return
	end

	if not BombController:GetThrowOrigin() then
		activeThrow = nil
		BombController:SetPrimaryBombInputSuppressed(false)
		BombController:CancelAbilityThrowHold()
		clearPreview()
		return
	end

	local definition = state.definition
	local speed = getDefinitionNumber(definition, "projectileLaunchSpeed", BombConfig.ProjectileLaunchSpeed)
	local gravityScale = getDefinitionNumber(definition, "projectileGravityScale", BombConfig.ProjectileGravityScale)
	local upwardVelocity = getDefinitionNumber(definition, "projectileUpwardVelocity", BombConfig.ProjectileUpwardVelocity)
	local maxFlightSeconds = math.max(
		getDefinitionNumber(definition, "projectileMaxFlightSeconds", BombConfig.FuseSeconds),
		0.05
	)
	local previewSeconds = math.min(maxFlightSeconds, BombConfig.PreviewMaxSeconds)
	local color = getDefinitionColor(definition, "previewColor", BombConfig.PreviewColor)

	BombController:ShowAbilityTrajectoryPreview({
		launchSpeed = speed,
		upwardVelocity = upwardVelocity,
		gravity = workspace.Gravity * gravityScale,
		maxFlightSeconds = maxFlightSeconds,
		maxPreviewTime = previewSeconds,
		color = color,
	})
end

local function startPreview()
	clearPreview()
	updatePreview()
	previewConnection = RunService.RenderStepped:Connect(updatePreview)
end

local function stopThrow()
	activeThrow = nil
	clearPreview()
	BombController:SetPrimaryBombInputSuppressed(false)
end

local function cancelThrow()
	BombController:CancelAbilityThrowHold()
	stopThrow()
end

local function beginThrow(context: ClientActivateRequestedContext): boolean
	local now = workspace:GetServerTimeNow()
	if context.controller:GetCooldownRemaining(context.slot) > 0 or predictedCooldownEndsAt > now then
		return true
	end
	if activeThrow then
		return true
	end
	if not BombController:BeginAbilityThrowHold() then
		return true
	end

	activeThrow = {
		slot = context.slot,
		definition = context.definition,
	}
	BombController:SetPrimaryBombInputSuppressed(true)
	startPreview()
	return true
end

local function releaseThrow(context: ClientActivateRequestedContext): boolean
	local state = activeThrow
	if not state then
		return true
	end

	clearPreview()
	local released = BombController:ReleaseAbilityThrowHold(function()
		context.controller:SendMessage(state.slot, AbilityConfig.MessageTypes.Activate, {
			aimDirection = BombController:GetThrowAimDirection(),
		})
		predictedCooldownEndsAt = workspace:GetServerTimeNow()
			+ math.max(getDefinitionNumber(state.definition, "cooldownSeconds", 0), 0)
		stopThrow()
	end)
	if not released then
		cancelThrow()
	end
	return true
end

local function getInstanceByPath(path: any): Instance?
	if typeof(path) ~= "table" then
		return nil
	end

	local current: Instance? = ReplicatedStorage
	for _, name in ipairs(path) do
		if typeof(name) ~= "string" or name == "" or not current then
			return nil
		end
		current = current:FindFirstChild(name)
	end
	return current
end

local function getFireTemplate(path: any): BasePart?
	local template = getInstanceByPath(path)
	if not template then
		if not warnedMissingTemplate then
			warn("[FireBomb] Missing ReplicatedStorage.Assets.Abilities.FireBomb.Fire")
			warnedMissingTemplate = true
		end
		return nil
	end
	if not template:IsA("BasePart") then
		if not warnedInvalidTemplate then
			warn("[FireBomb] Fire asset must be a BasePart for client VFX placement")
			warnedInvalidTemplate = true
		end
		return nil
	end

	return template
end

local function getEmitModule()
	if emitModule then
		return emitModule
	end

	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local moduleScript = packages and packages:FindFirstChild("EmitModule")
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		if not warnedMissingEmitModule then
			warn("[FireBomb] Missing ReplicatedStorage.Packages.EmitModule")
			warnedMissingEmitModule = true
		end
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	if not ok then
		if not warnedMissingEmitModule then
			warn("[FireBomb] Failed to require EmitModule: " .. tostring(result))
			warnedMissingEmitModule = true
		end
		return nil
	end

	emitModule = result
	return emitModule
end

local function ensureEmitModuleInitialized(module): boolean
	if emitModuleInitialized then
		return true
	end
	if not module then
		return false
	end

	local initFn = module.init or module.Init
	if type(initFn) == "function" then
		local ok, err = pcall(function()
			initFn()
		end)
		if not ok then
			warn("[FireBomb] Failed to initialize EmitModule: " .. tostring(err))
			return false
		end
	end

	emitModuleInitialized = true
	return true
end

local function getVfxFolder(): Folder
	local existing = workspace:FindFirstChild("FireBombVFX")
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "FireBombVFX"
	folder.Parent = workspace
	return folder
end

local function prepareVisualClone(clone: BasePart)
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanTouch = false
	clone.CanQuery = false
	clone.AssemblyLinearVelocity = Vector3.zero
	clone.AssemblyAngularVelocity = Vector3.zero

	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function cleanupAfterEmit(clone: Instance, env, cleanupSeconds: number)
	local cleaned = false
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		if clone.Parent then
			clone:Destroy()
		end
	end

	local finished = if typeof(env) == "table" then env.Finished else nil
	if finished and type(finished.finally) == "function" then
		finished:finally(cleanup)
		task.delay(cleanupSeconds, cleanup)
	else
		task.delay(cleanupSeconds, cleanup)
	end
end

local function playFireEffect(payload: any)
	local definition = AbilityConfig.GetDefinition("FireBomb")
	local position = if typeof(payload) == "table" then payload.position else nil
	if typeof(position) ~= "Vector3" then
		return
	end

	local assetPath = if typeof(payload) == "table" and typeof(payload.assetPath) == "table"
		then payload.assetPath
		else if definition then definition.assetPath else nil
	local template = getFireTemplate(assetPath)
	if not template then
		return
	end

	local cleanupSeconds = math.max(getDefinitionNumber(definition, "fireVisualCleanupSeconds", 4), 0.25)
	local clone = template:Clone()
	clone.Name = "FireBombVFX"
	prepareVisualClone(clone)
	clone.CFrame = CFrame.new(position)
	clone.Parent = getVfxFolder()

	local module = getEmitModule()
	if module and ensureEmitModuleInitialized(module) and type(module.emit) == "function" then
		local ok, env = pcall(function()
			return module.emit(clone)
		end)
		if ok then
			cleanupAfterEmit(clone, env, cleanupSeconds)
			return
		end
		warn("[FireBomb] Failed to emit Fire VFX: " .. tostring(env))
	end

	task.delay(cleanupSeconds, function()
		if clone.Parent then
			clone:Destroy()
		end
	end)
end

function FireBomb.OnActivateRequested(context: ClientActivateRequestedContext): boolean
	local inputState = context.inputState
	if inputState == nil or inputState == Enum.UserInputState.Begin then
		return beginThrow(context)
	elseif inputState == Enum.UserInputState.End then
		return releaseThrow(context)
	elseif inputState == Enum.UserInputState.Cancel then
		cancelThrow()
		return true
	end

	return true
end

function FireBomb.OnEffect(context: ClientEffectContext)
	if context.effectName ~= "FireBombAreaStarted" or context.payload.abilityId ~= "FireBomb" then
		return
	end

	playFireEffect(context.payload)
end

return FireBomb
