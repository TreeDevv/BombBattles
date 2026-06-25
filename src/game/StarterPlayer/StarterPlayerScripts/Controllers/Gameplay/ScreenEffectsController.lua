local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local LocalPlayer = Players.LocalPlayer
local ROUND_ALIVE_ATTR = "RoundAlive"
local ROUND_RESPAWN_ENDS_AT_ATTR = "RoundRespawnEndsAt"

local function isPendingRoundRespawn(): boolean
	if LocalPlayer:GetAttribute(ROUND_ALIVE_ATTR) ~= false then
		return false
	end

	local respawnEndsAt = LocalPlayer:GetAttribute(ROUND_RESPAWN_ENDS_AT_ATTR)
	return typeof(respawnEndsAt) == "number" and respawnEndsAt > workspace:GetServerTimeNow()
end

type ColorCorrectionConfig = {
	name: string,
	tweenInTime: number,
	tweenOutTime: number,
	inProperties: { [string]: any },
	outProperties: { [string]: any },
}

type BlurConfig = {
	name: string,
	tweenInTime: number,
	tweenOutTime: number,
	inProperties: { [string]: any },
	outProperties: { [string]: any },
}

type PresetConfig = {
	frontOffset: CFrame,
	cleanupDelay: number?,
	screenFit: boolean?,
	requiresEffectPart: boolean?,
	colorCorrection: ColorCorrectionConfig?,
	blur: BlurConfig?,
	burnFlash: boolean?,
	explosionAssetName: string?,
	minRateScale: number?,
	maxRateScale: number?,
}

type ActiveEffect = {
	presetName: string,
	endTime: number,
	runId: number,
	effectPart: BasePart?,
	renderConn: RBXScriptConnection?,
	colorCorrection: ColorCorrectionEffect?,
	colorCorrectionTween: Tween?,
	blur: BlurEffect?,
	blurTween: Tween?,
	hasStarted: boolean,
	baseIntensity: number,
	intensity: number,
	emitterRates: { [ParticleEmitter]: number },
}

local DEFAULT_CLEANUP_DELAY = 1.5
local CC_OUT_PROPERTIES = {
	TintColor = Color3.new(1, 1, 1),
	Contrast = 0,
	Saturation = 0,
	Brightness = 0,
}

local PRESETS: { [string]: PresetConfig } = {
	Corrupted = {
		frontOffset = CFrame.new(0, 0, -2),
		screenFit = true,
	},
	Magma = {
		frontOffset = CFrame.new(0, 0, -1.8),
		screenFit = true,
	},
	Diamond = {
		frontOffset = CFrame.new(0, 0, -2),
		screenFit = true,
	},
	Prismatic = {
		frontOffset = CFrame.new(0, 0, -2),
		screenFit = true,
	},
	Bleed = {
		frontOffset = CFrame.new(0, 0, -1.4),
		colorCorrection = {
			name = "BleedColorCorrection",
			tweenInTime = 0.35,
			tweenOutTime = 0.4,
			inProperties = {
				TintColor = Color3.fromRGB(255, 126, 126),
				Contrast = 0.25,
				Saturation = -0.15,
				Brightness = -0.1,
			},
			outProperties = CC_OUT_PROPERTIES,
		},
	},
	Burn = {
		frontOffset = CFrame.new(0, 0, -1.4),
		burnFlash = true,
		explosionAssetName = "Explosion",
		colorCorrection = {
			name = "BurnColorCorrection",
			tweenInTime = 0.35,
			tweenOutTime = 0.4,
			inProperties = {
				TintColor = Color3.fromRGB(255, 223, 201),
				Contrast = 0.25,
				Saturation = 0.15,
				Brightness = -0.05,
			},
			outProperties = CC_OUT_PROPERTIES,
		},
	},
	Holy = {
		frontOffset = CFrame.new(0, 0, -1.4),
		colorCorrection = {
			name = "HolyColorCorrection",
			tweenInTime = 0.35,
			tweenOutTime = 0.4,
			inProperties = {
				TintColor = Color3.fromRGB(255, 239, 189),
				Contrast = 0.1,
				Brightness = 0.1,
			},
			outProperties = CC_OUT_PROPERTIES,
		},
	},
	Relic = {
		frontOffset = CFrame.new(0, 0, -1.4),
		colorCorrection = {
			name = "RelicColorCorrection",
			tweenInTime = 0.35,
			tweenOutTime = 0.4,
			inProperties = {
				TintColor = Color3.fromRGB(205, 190, 255),
				Contrast = 0.2,
				Saturation = 0.5,
				Brightness = -0.1,
			},
			outProperties = CC_OUT_PROPERTIES,
		},
	},
	Speed = {
		frontOffset = CFrame.new(0, 0, -1.4),
		minRateScale = 0.45,
		maxRateScale = 1.35,
	},
	Acid = {
		frontOffset = CFrame.new(0, 0, -1.4),
		cleanupDelay = 0.75,
		requiresEffectPart = false,
		colorCorrection = {
			name = "AcidColorCorrection",
			tweenInTime = 0.16,
			tweenOutTime = 0.45,
			inProperties = {
				TintColor = Color3.fromRGB(184, 255, 128),
				Contrast = 0.18,
				Saturation = -0.25,
				Brightness = -0.05,
			},
			outProperties = CC_OUT_PROPERTIES,
		},
		blur = {
			name = "AcidBlur",
			tweenInTime = 0.16,
			tweenOutTime = 0.45,
			inProperties = {
				Size = 14,
			},
			outProperties = {
				Size = 0,
			},
		},
	},
}

local ScreenEffectsController = {}

ScreenEffectsController._activeEffects = {} :: { [string]: ActiveEffect }
ScreenEffectsController._heartbeatConnection = nil :: RBXScriptConnection?

local function getAssetsRoot(): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end

	local vfx = assets:FindFirstChild("VFX")
	return vfx and vfx:FindFirstChild("ScreenEffects")
end

local function getPresetAssetFolder(presetName: string): Instance?
	local root = getAssetsRoot()
	if not root then
		return nil
	end

	return root:FindFirstChild(presetName)
end

local function setVisualPartProperties(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
end

local function setEmittersEnabled(root: Instance, enabled: boolean)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = enabled
		elseif descendant:IsA("Beam") and not enabled then
			descendant.Transparency = NumberSequence.new(1)
		end
	end
end

local function emitDescendantParticles(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant:Emit(descendant:GetAttribute("EmitCount") or 0)
		end
	end
end

local function captureEmitterRates(root: Instance): { [ParticleEmitter]: number }
	local rates = {}
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			rates[descendant] = descendant.Rate
		end
	end
	return rates
end

local function getScaledIntensity(baseIntensity: number): number
	return math.clamp(baseIntensity, 0, 1)
end

local function updatePartForCamera(part: BasePart, camera: Camera, config: PresetConfig, originalSize: Vector3)
	if config.screenFit then
		local depth = math.abs(config.frontOffset.Z)
		local height = 2 * math.tan(math.rad(camera.FieldOfView) / 2) * depth
		local width = height * (camera.ViewportSize.X / camera.ViewportSize.Y)
		part.Size = Vector3.new(width, height, originalSize.Z)
	end

	part.CFrame = camera.CFrame * config.frontOffset
end

local function playBurnFlash(camera: Camera)
	local flash = Instance.new("ColorCorrectionEffect")
	flash.Name = "BurnFlashCC"
	flash.TintColor = Color3.fromRGB(255, 240, 220)
	flash.Contrast = 0.6
	flash.Saturation = 0.3
	flash.Brightness = 0.15
	flash.Parent = camera

	local tweenIn = TweenService:Create(
		flash,
		TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Brightness = 0.25 }
	)
	local tweenOut = TweenService:Create(
		flash,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		CC_OUT_PROPERTIES
	)

	tweenIn:Play()
	tweenIn.Completed:Once(function()
		tweenOut:Play()
	end)
	tweenOut.Completed:Once(function()
		if flash.Parent then
			flash:Destroy()
		end
	end)
end

function ScreenEffectsController:_applyIntensity(active: ActiveEffect, config: PresetConfig)
	local intensity = math.clamp(active.intensity, 0, 1)
	local minRateScale = config.minRateScale or 1
	local maxRateScale = config.maxRateScale or 1
	local rateScale = if intensity <= 0 then 0 else minRateScale + (maxRateScale - minRateScale) * intensity

	for emitter, baseRate in pairs(active.emitterRates) do
		if emitter.Parent then
			emitter.Rate = baseRate * rateScale
		else
			active.emitterRates[emitter] = nil
		end
	end

end

function ScreenEffectsController:_startHeartbeat()
	if self._heartbeatConnection then
		return
	end

	self._heartbeatConnection = RunService.Heartbeat:Connect(function()
		local token = RuntimeProfiler.Begin("Client/ScreenEffectsController/Heartbeat")
		local now = os.clock()
		local activeCount = 0
		for presetName, active in pairs(self._activeEffects) do
			activeCount += 1
			if now >= active.endTime then
				self:Stop(presetName)
			end
		end
		RuntimeProfiler.Gauge("Client/ScreenEffectsController/ActiveEffects", activeCount)
		RuntimeProfiler.End("Client/ScreenEffectsController/Heartbeat", token)
	end)
end

function ScreenEffectsController:_stopHeartbeatIfIdle()
	if next(self._activeEffects) ~= nil or not self._heartbeatConnection then
		return
	end

	self._heartbeatConnection:Disconnect()
	self._heartbeatConnection = nil
end

function ScreenEffectsController:_startPreset(presetName: string, config: PresetConfig, active: ActiveEffect): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end

	local presetFolder = getPresetAssetFolder(presetName)
	local template = presetFolder and presetFolder:FindFirstChild("EffectPart")
	if template and not template:IsA("BasePart") then
		warn(("[ScreenEffectsController] Missing EffectPart for preset %s"):format(presetName))
		return false
	end

	local part: BasePart? = nil
	if template and template:IsA("BasePart") then
		part = template:Clone()
		part.Name = presetName .. "Effect"
		setVisualPartProperties(part)
		part.Parent = camera

		local originalSize = template.Size
		active.effectPart = part
		active.renderConn = RunService.RenderStepped:Connect(function()
			local token = RuntimeProfiler.Begin("Client/ScreenEffectsController/EffectRender")
			if part and part.Parent and workspace.CurrentCamera then
				updatePartForCamera(part, workspace.CurrentCamera, config, originalSize)
			end
			RuntimeProfiler.End("Client/ScreenEffectsController/EffectRender", token)
		end)

		updatePartForCamera(part, camera, config, originalSize)
		setEmittersEnabled(part, true)
		active.emitterRates = captureEmitterRates(part)
	elseif config.requiresEffectPart ~= false or not (config.colorCorrection or config.blur) then
		warn(("[ScreenEffectsController] Missing EffectPart for preset %s"):format(presetName))
		return false
	end

	local colorCorrectionConfig = config.colorCorrection
	if colorCorrectionConfig then
		local colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Name = colorCorrectionConfig.name
		for property, value in pairs(colorCorrectionConfig.outProperties) do
			(colorCorrection :: any)[property] = value
		end
		colorCorrection.Parent = camera

		active.colorCorrection = colorCorrection
		active.colorCorrectionTween = TweenService:Create(
			colorCorrection,
			TweenInfo.new(colorCorrectionConfig.tweenInTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			colorCorrectionConfig.inProperties
		)
		active.colorCorrectionTween:Play()
	end

	local blurConfig = config.blur
	if blurConfig then
		local blur = Instance.new("BlurEffect")
		blur.Name = blurConfig.name
		for property, value in pairs(blurConfig.outProperties) do
			(blur :: any)[property] = value
		end
		blur.Parent = Lighting

		active.blur = blur
		active.blurTween = TweenService:Create(
			blur,
			TweenInfo.new(blurConfig.tweenInTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			blurConfig.inProperties
		)
		active.blurTween:Play()
	end

	self:_applyIntensity(active, config)

	if config.burnFlash and not active.hasStarted then
		active.hasStarted = true
		playBurnFlash(camera)

		local explosionAssetName = config.explosionAssetName
		local explosionTemplate = explosionAssetName and presetFolder and presetFolder:FindFirstChild(explosionAssetName)
		if explosionTemplate and part then
			local explosion = explosionTemplate:Clone()
			explosion.Parent = part
			emitDescendantParticles(explosion)
			task.delay(2, function()
				if explosion.Parent then
					explosion:Destroy()
				end
			end)
		end
	end

	return true
end

function ScreenEffectsController:Apply(presetName: string, duration: number, options: any?): boolean
	if typeof(presetName) ~= "string" or presetName == "" then
		warn("[ScreenEffectsController] Preset name must be a non-empty string")
		return false
	end
	if typeof(duration) ~= "number" or duration <= 0 or duration ~= duration then
		warn("[ScreenEffectsController] Duration must be a positive number")
		return false
	end

	local config = PRESETS[presetName]
	if not config then
		warn(("[ScreenEffectsController] Status effect preset not found: %s"):format(presetName))
		return false
	end
	options = if typeof(options) == "table" then options else {}
	local baseIntensity = math.clamp(tonumber(options.intensity) or 1, 0, 1)
	local scaledIntensity = baseIntensity

	local now = os.clock()
	local active = self._activeEffects[presetName]
	if active then
		if typeof(options) == "table" and options.refresh == true then
			active.endTime = math.max(active.endTime, now + duration)
		else
			active.endTime += duration
		end
		if typeof(options) == "table" and typeof(options.intensity) == "number" then
			active.baseIntensity = baseIntensity
			active.intensity = scaledIntensity
			self:_applyIntensity(active, config)
		end
		return true
	end

	active = {
		presetName = presetName,
		endTime = now + duration,
		runId = 0,
		effectPart = nil,
		renderConn = nil,
		colorCorrection = nil,
		colorCorrectionTween = nil,
		blur = nil,
		blurTween = nil,
		hasStarted = false,
		baseIntensity = baseIntensity,
		intensity = scaledIntensity,
		emitterRates = {},
	}
	self._activeEffects[presetName] = active
	active.runId += 1

	if not self:_startPreset(presetName, config, active) then
		self._activeEffects[presetName] = nil
		self:_stopHeartbeatIfIdle()
		return false
	end

	self:_startHeartbeat()
	return true
end

function ScreenEffectsController:Enable(presetName: string, options: any?): boolean
	return self:Apply(presetName, math.huge, options)
end

function ScreenEffectsController:SetIntensity(presetName: string, intensity: number): boolean
	local active = self._activeEffects[presetName]
	local config = PRESETS[presetName]
	if not (active and config) then
		return false
	end

	active.baseIntensity = math.clamp(intensity, 0, 1)
	active.intensity = getScaledIntensity(active.baseIntensity)
	self:_applyIntensity(active, config)
	return true
end

function ScreenEffectsController:Stop(presetName: string): boolean
	local active = self._activeEffects[presetName]
	if not active then
		return false
	end

	local config = PRESETS[presetName]
	local cleanupDelay = (config and config.cleanupDelay) or DEFAULT_CLEANUP_DELAY
	local runId = active.runId
	local part = active.effectPart
	local colorCorrection = active.colorCorrection
	local blur = active.blur
	local renderConn = active.renderConn

	self._activeEffects[presetName] = nil
	active.effectPart = nil
	active.renderConn = nil
	active.colorCorrection = nil
	active.blur = nil

	if part then
		setEmittersEnabled(part, false)
	end

	if active.colorCorrectionTween then
		active.colorCorrectionTween:Cancel()
		active.colorCorrectionTween = nil
	end
	if active.blurTween then
		active.blurTween:Cancel()
		active.blurTween = nil
	end

	if colorCorrection and config and config.colorCorrection then
		local tweenOut = TweenService:Create(
			colorCorrection,
			TweenInfo.new(config.colorCorrection.tweenOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			config.colorCorrection.outProperties
		)
		tweenOut:Play()
	end
	if blur and config and config.blur then
		local tweenOut = TweenService:Create(
			blur,
			TweenInfo.new(config.blur.tweenOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			config.blur.outProperties
		)
		tweenOut:Play()
	end

	task.delay(cleanupDelay, function()
		if active.runId ~= runId then
			return
		end
		if part and part.Parent then
			part:Destroy()
		end
		if renderConn then
			renderConn:Disconnect()
		end
		if colorCorrection and colorCorrection.Parent then
			colorCorrection:Destroy()
		end
		if blur and blur.Parent then
			blur:Destroy()
		end
	end)

	self:_stopHeartbeatIfIdle()
	return true
end

function ScreenEffectsController:Clear(presetName: string): boolean
	return self:Stop(presetName)
end

function ScreenEffectsController:ClearMany(presetNames: { string })
	for _, presetName in ipairs(presetNames) do
		self:Stop(presetName)
	end
end

function ScreenEffectsController:StopAll()
	for presetName in pairs(self._activeEffects) do
		self:Stop(presetName)
	end
end

function ScreenEffectsController:ClearAll()
	self:StopAll()
end

function ScreenEffectsController:OnStart()
	self:StopAll()

	LocalPlayer.CharacterRemoving:Connect(function()
		if isPendingRoundRespawn() then
			return
		end

		self:StopAll()
	end)
end

return ScreenEffectsController
