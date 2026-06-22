local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)

local EmoteEffect = {}

type Runtime = {
	emoteId: string,
	character: Model,
	assetFolder: Instance,
	vfxModule: ModuleScript?,
	vfxFolder: Instance?,
	instances: { Instance },
	connections: { RBXScriptConnection },
	tracks: { AnimationTrack },
	running: boolean,
}

local RuntimeMethods = {}
RuntimeMethods.__index = RuntimeMethods

local cameraShaker = nil :: any
local cameraShakerModule = nil :: any

local function getChild(parent: Instance?, name: string): Instance?
	return if parent then parent:FindFirstChild(name) else nil
end

local function safeDestroy(instance: Instance?)
	if instance and instance.Parent then
		instance:Destroy()
	end
end

local function getFxParent(): Instance
	return workspace:FindFirstChild("FX") or workspace:FindFirstChild("fx") or workspace
end

local function isBodyPart(instance: Instance): boolean
	return instance:IsA("BasePart") and instance.Name ~= "HumanoidRootPart"
end

local function getCameraShaker(): any?
	if cameraShakerModule then
		return cameraShakerModule
	end

	local ok, result = pcall(function()
		return require(ReplicatedStorage.Shared.Camera.CameraShaker)
	end)
	if not ok then
		warn("[EmoteVFX] Failed to require CameraShaker: " .. tostring(result))
		return nil
	end

	cameraShakerModule = result
	return cameraShakerModule
end

function RuntimeMethods:Track(instance: Instance?): Instance?
	if instance then
		table.insert(self.instances, instance)
	end
	return instance
end

function RuntimeMethods:TrackConnection(connection: RBXScriptConnection?): RBXScriptConnection?
	if connection then
		table.insert(self.connections, connection)
	end
	return connection
end

function RuntimeMethods:TrackAnimation(trackObject: AnimationTrack?): AnimationTrack?
	if trackObject then
		table.insert(self.tracks, trackObject)
	end
	return trackObject
end

function RuntimeMethods:GetChild(parent: Instance?, name: string): Instance?
	return getChild(parent, name)
end

function RuntimeMethods:FindPart(name: string): BasePart?
	local instance = self.character:FindFirstChild(name)
	return if instance and instance:IsA("BasePart") then instance else nil
end

function RuntimeMethods:GetRoot(): BasePart?
	return self:FindPart("HumanoidRootPart") or self:FindPart("Torso") or self:FindPart("UpperTorso")
end

function RuntimeMethods:GetHead(): BasePart?
	return self:FindPart("Head")
end

function RuntimeMethods:GetHumanoid(): Humanoid?
	return self.character:FindFirstChildOfClass("Humanoid")
end

function RuntimeMethods:GetAnimator(): Animator?
	local humanoid = self:GetHumanoid()
	if not humanoid then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	return animator
end

function RuntimeMethods:GetVfxFolder(): Instance?
	return self.vfxFolder
end

function RuntimeMethods:GetVfxChild(name: string): Instance?
	return getChild(self.vfxFolder, name)
end

function RuntimeMethods:GetVfxDescendant(path: { string }): Instance?
	local cursor = self.vfxFolder
	for _, name in ipairs(path) do
		cursor = getChild(cursor, name)
		if not cursor then
			return nil
		end
	end
	return cursor
end

function RuntimeMethods:CloneTo(source: Instance?, parent: Instance?): Instance?
	if not (source and parent) then
		return nil
	end

	local clone = source:Clone()
	clone.Parent = parent
	return self:Track(clone)
end

function RuntimeMethods:CloneVfxChildTo(name: string, parent: Instance?): Instance?
	return self:CloneTo(self:GetVfxChild(name), parent)
end

function RuntimeMethods:CloneVfxDescendantTo(path: { string }, parent: Instance?): Instance?
	return self:CloneTo(self:GetVfxDescendant(path), parent)
end

function RuntimeMethods:PlaySound(source: Instance?, parent: Instance?): Sound?
	if not (source and source:IsA("Sound") and parent) then
		return nil
	end

	local sound = source:Clone()
	sound.Parent = parent
	self:Track(sound)
	sound:Play()
	return sound
end

function RuntimeMethods:DestroyChild(parent: Instance?, name: string)
	safeDestroy(getChild(parent, name))
end

function RuntimeMethods:SafeDestroy(instance: Instance?)
	safeDestroy(instance)
end

function RuntimeMethods:AddDebris(instance: Instance?, delaySeconds: number)
	if instance then
		Debris:AddItem(instance, delaySeconds)
	end
end

function RuntimeMethods:Emit(instance: Instance?)
	if instance then
		EmitService.Emit(instance, "[EmoteVFX]")
	end
end

function RuntimeMethods:GetAnimation(name: string): Animation?
	local animations = self.assetFolder:FindFirstChild("Animations")
	local animation = animations and animations:FindFirstChild(name)
	return if animation and animation:IsA("Animation") then animation else nil
end

function RuntimeMethods:LoadTrack(animation: Animation?): AnimationTrack?
	local animator = self:GetAnimator()
	if not (animator and animation) then
		return nil
	end

	local ok, result = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok or not result then
		warn(("[EmoteVFX] Failed to load %s animation: %s"):format(self.emoteId, tostring(result)))
		return nil
	end

	return self:TrackAnimation(result :: AnimationTrack)
end

function RuntimeMethods:PlayAnimation(name: string, fadeTime: number?, looped: boolean?): AnimationTrack?
	local trackObject = self:LoadTrack(self:GetAnimation(name))
	if not trackObject then
		return nil
	end

	if looped ~= nil then
		trackObject.Looped = looped
	end
	trackObject:Play(fadeTime or 0.1)
	return trackObject
end

function RuntimeMethods:MakeMotor(parent: Instance, name: string, part0: BasePart?, part1: BasePart?, c0: CFrame?): Motor6D?
	if not (part0 and part1) then
		return nil
	end

	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	if c0 then
		motor.C0 = c0
	end
	motor.Parent = parent
	return self:Track(motor) :: Motor6D
end

function RuntimeMethods:SpawnBodyAfterimage(color: Color3, scale: number)
	local parent = getFxParent()
	for _, bodyPart in ipairs(self.character:GetChildren()) do
		if isBodyPart(bodyPart) then
			local source = bodyPart :: BasePart
			local part = Instance.new("Part")
			part.Size = if source.Name == "Head" then Vector3.new(1.5, 1.5, 1.5) else source.Size
			part.CFrame = source.CFrame
			part.Material = Enum.Material.Neon
			part.Color = color
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Transparency = 0.8
			part.Parent = parent

			TweenService:Create(
				part,
				TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ Size = part.Size * scale, Transparency = 1 }
			):Play()
			self:AddDebris(part, 0.3)
		end
	end
end

function RuntimeMethods:SpawnGamblerAfterimage()
	local parent = getFxParent()
	for _, bodyPart in ipairs(self.character:GetChildren()) do
		if bodyPart:IsA("Part") and bodyPart.Name ~= "HumanoidRootPart" then
			local source = bodyPart :: Part
			local clone = Instance.new("Part")
			clone.Size = source.Size
			clone.CFrame = source.CFrame
			clone.Material = Enum.Material.Neon
			clone.Transparency = 0.7
			clone.Color = Color3.fromRGB(0, 255, 30)
			clone.Anchored = true
			clone.CanCollide = false
			clone.CanQuery = false
			clone.CanTouch = false
			clone.Parent = parent

			TweenService:Create(
				clone,
				TweenInfo.new(0.3, Enum.EasingStyle.Quint),
				{ Size = source.Size * 2, Transparency = 1 }
			):Play()
			self:AddDebris(clone, 0.3)
		end
	end
end

function RuntimeMethods:PlaySmallCameraShake()
	if not RunService:IsClient() then
		return
	end

	if not cameraShaker then
		local cameraShakerClass = getCameraShaker()
		if not cameraShakerClass then
			return
		end

		cameraShaker = cameraShakerClass.new(Enum.RenderPriority.Camera.Value + 2, function(shakeCFrame: CFrame)
			local camera = workspace.CurrentCamera
			if camera then
				camera.CFrame *= shakeCFrame
			end
		end)
		cameraShaker:Start()
	end

	cameraShaker:ShakeOnce(
		0.6,
		10,
		0.02,
		0.22,
		Vector3.new(0.03, 0.03, 0.03),
		Vector3.new(0.35, 0.18, 0.25)
	)
end

function RuntimeMethods:Destroy()
	self.running = false

	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	for _, trackObject in ipairs(self.tracks) do
		pcall(function()
			trackObject:Stop(0.1)
			trackObject:Destroy()
		end)
	end
	for _, instance in ipairs(self.instances) do
		safeDestroy(instance)
	end

	table.clear(self.connections)
	table.clear(self.tracks)
	table.clear(self.instances)
end

local function findVfxModule(assetFolder: Instance): ModuleScript?
	local vfx = assetFolder:FindFirstChild("VFX")
	return if vfx and vfx:IsA("ModuleScript") then vfx else nil
end

function EmoteEffect.Create(emoteId: string, metadata: any?): any
	local effect = {}
	if typeof(metadata) == "table" then
		for key, value in pairs(metadata) do
			effect[key] = value
		end
	end
	effect.id = emoteId
	effect.displayName = effect.displayName or emoteId
	return effect
end

function EmoteEffect.CreateRuntime(emoteId: string, character: Model, assetFolder: Instance): Runtime
	local vfxModule = findVfxModule(assetFolder)
	local runtime = {
		emoteId = emoteId,
		character = character,
		assetFolder = assetFolder,
		vfxModule = vfxModule,
		vfxFolder = if vfxModule then vfxModule:FindFirstChild("VFX") else nil,
		instances = {},
		connections = {},
		tracks = {},
		running = true,
	}
	return setmetatable(runtime, RuntimeMethods) :: Runtime
end

function EmoteEffect.GetLocalPlayer(): Player?
	return Players.LocalPlayer
end

return EmoteEffect
