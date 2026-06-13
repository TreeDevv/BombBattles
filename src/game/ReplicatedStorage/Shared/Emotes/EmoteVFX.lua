local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EmoteConfig = require(script.Parent.EmoteConfig)

local EmoteVFX = {}

local emitModule = nil
local emitModuleInitialized = false
local warnedMissingEmitModule = false

type Runtime = {
	emoteId: string,
	character: Model,
	instances: { Instance },
	connections: { RBXScriptConnection },
}

local TARGET_BY_NAME = {
	Aura = "HumanoidRootPart",
	Att = "HumanoidRootPart",
	BeanBag = "HumanoidRootPart",
	BartoCola = "Right Arm",
	BartoColaPower = "Right Arm",
	Chips = "Right Arm",
	Deer = "HumanoidRootPart",
	Mic = "Left Arm",
	SleepParticle = "Head",
}

local function getEmitModule()
	if emitModule then
		return emitModule
	end

	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local moduleScript = packages and packages:FindFirstChild("EmitModule")
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		if not warnedMissingEmitModule then
			warn("[EmoteVFX] Missing ReplicatedStorage.Packages.EmitModule")
			warnedMissingEmitModule = true
		end
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	if not ok then
		if not warnedMissingEmitModule then
			warn("[EmoteVFX] Failed to require EmitModule: " .. tostring(result))
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
	if type(module.init) ~= "function" then
		emitModuleInitialized = true
		return true
	end

	local ok, err = pcall(function()
		module.init()
	end)
	if not ok then
		warn("[EmoteVFX] Failed to initialize EmitModule: " .. tostring(err))
		return false
	end

	emitModuleInitialized = true
	return true
end

local function emit(instance: Instance)
	local module = getEmitModule()
	if not (module and ensureEmitModuleInitialized(module) and type(module.emit) == "function") then
		return
	end

	local ok, err = pcall(function()
		module.emit(instance)
	end)
	if not ok then
		warn("[EmoteVFX] EmitModule emit failed for " .. instance:GetFullName() .. ": " .. tostring(err))
	end
end

local function findTarget(character: Model, targetName: string?): BasePart?
	local names = {}
	if targetName then
		table.insert(names, targetName)
	end
	table.insert(names, "HumanoidRootPart")
	table.insert(names, "Torso")
	table.insert(names, "UpperTorso")
	table.insert(names, "Head")

	for _, name in ipairs(names) do
		local target = character:FindFirstChild(name)
		if target and target:IsA("BasePart") then
			return target
		end
	end

	return nil
end

local function getRootPart(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		if instance.PrimaryPart then
			return instance.PrimaryPart
		end
		local part = instance:FindFirstChildWhichIsA("BasePart", true)
		if part then
			instance.PrimaryPart = part
			return part
		end
	end
	return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function prepParts(instance: Instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end
	if instance:IsA("BasePart") then
		instance.Anchored = false
		instance.CanCollide = false
		instance.CanQuery = false
		instance.CanTouch = false
		instance.Massless = true
	end
end

local function setEnabledRecursive(instance: Instance, enabled: boolean)
	if instance:IsA("ParticleEmitter") or instance:IsA("Beam") or instance:IsA("Trail") then
		instance.Enabled = enabled
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = enabled
		end
	end
end

local function track(runtime: Runtime, instance: Instance)
	table.insert(runtime.instances, instance)
end

local function cloneSound(runtime: Runtime, source: Sound, target: BasePart?)
	if not target then
		return
	end

	local sound = source:Clone()
	sound.Parent = target
	track(runtime, sound)
	sound:Play()
end

local function cloneEmitter(runtime: Runtime, source: ParticleEmitter, target: BasePart?)
	if not target then
		return
	end

	local emitter = source:Clone()
	emitter.Enabled = true
	emitter.Parent = target
	track(runtime, emitter)
	emit(emitter)
end

local function cloneAttachment(runtime: Runtime, source: Attachment, target: BasePart?)
	if not target then
		return
	end

	local attachment = source:Clone()
	attachment.Parent = target
	track(runtime, attachment)
	setEnabledRecursive(attachment, true)
	emit(attachment)
end

local function weldToTarget(instance: Instance, target: BasePart)
	local root = getRootPart(instance)
	if not root then
		return
	end

	prepParts(instance)
	if instance:IsA("Model") then
		instance:PivotTo(target.CFrame)
	elseif root then
		root.CFrame = target.CFrame
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = descendant
			weld.Parent = root
		end
	end

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = target
	weld.Part1 = root
	weld.Parent = root
end

local function cloneVisual(runtime: Runtime, source: Instance, target: BasePart?)
	if not target then
		return
	end

	local clone = source:Clone()
	clone.Parent = runtime.character
	track(runtime, clone)

	if clone:IsA("Attachment") then
		clone.Parent = target
	else
		weldToTarget(clone, target)
	end

	setEnabledRecursive(clone, true)
	emit(clone)
end

local function getSourceRoot(assetFolder: Instance): Instance?
	local vfx = assetFolder:FindFirstChild("VFX")
	if not vfx then
		return nil
	end
	local nested = vfx:FindFirstChild("VFX")
	return nested or vfx
end

local function processSource(runtime: Runtime, source: Instance)
	local targetName = TARGET_BY_NAME[source.Name]
	local target = findTarget(runtime.character, targetName)
	local rootTarget = findTarget(runtime.character, "HumanoidRootPart")
	local headTarget = findTarget(runtime.character, "Head")

	if source:IsA("Sound") then
		cloneSound(runtime, source, rootTarget)
	elseif source:IsA("ParticleEmitter") then
		cloneEmitter(runtime, source, headTarget or rootTarget)
	elseif source:IsA("Attachment") then
		cloneAttachment(runtime, source, target or rootTarget)
	elseif source:IsA("BasePart") or source:IsA("Model") then
		cloneVisual(runtime, source, target or rootTarget)
	elseif source:IsA("Folder") then
		for _, child in ipairs(source:GetChildren()) do
			processSource(runtime, child)
		end
	end
end

function EmoteVFX.Start(character: Model, emoteId: string): any?
	local assetFolder = EmoteConfig.GetAssetFolder(emoteId)
	if not (assetFolder and character and character.Parent) then
		return nil
	end

	local runtime: Runtime = {
		emoteId = emoteId,
		character = character,
		instances = {},
		connections = {},
	}

	local sourceRoot = getSourceRoot(assetFolder)
	if sourceRoot then
		for _, source in ipairs(sourceRoot:GetChildren()) do
			processSource(runtime, source)
		end
	end

	local vfx = assetFolder:FindFirstChild("VFX")
	if vfx then
		for _, source in ipairs(vfx:GetChildren()) do
			if source ~= sourceRoot then
				processSource(runtime, source)
			end
		end
	end

	return {
		Destroy = function()
			for _, connection in ipairs(runtime.connections) do
				connection:Disconnect()
			end
			for _, instance in ipairs(runtime.instances) do
				if instance.Parent then
					instance:Destroy()
				end
			end
			table.clear(runtime.connections)
			table.clear(runtime.instances)
		end,
	}
end

return EmoteVFX
