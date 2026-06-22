local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BombConfig = require(ReplicatedStorage.Shared.Config.BombConfig)
local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local BombFusePulse = {}

local FROZEN_COLOR = Color3.fromRGB(91, 226, 255)
local FROZEN_FILL_TRANSPARENCY = 0.18
local FROZEN_OUTLINE_TRANSPARENCY = 0.02

local function getProgress(visual, now: number): (number, number)
	local fuseStartedAt = visual.fuseStartedAt or now
	local fuseEndsAt = visual.fuseEndsAt or (fuseStartedAt + BombConfig.FuseSeconds)
	local fuseDuration = math.max(fuseEndsAt - fuseStartedAt, 0.001)
	local elapsed = math.clamp(now - fuseStartedAt, 0, fuseDuration)
	return elapsed / fuseDuration, elapsed
end

type PulseStyle = {
	baseColor: Color3,
	pulseColor: Color3?,
	fillStart: number,
	outlineStart: number,
}

local function getPulseColor(baseColor: Color3, pulseColor: Color3?, fuseProgress: number?, elapsed: number?): Color3
	local progress = if typeof(fuseProgress) == "number" then math.clamp(fuseProgress, 0, 1) else 0
	local pulseElapsed = if typeof(elapsed) == "number" then math.max(elapsed, 0) else 0
	local startHz = math.max(BombConfig.PulseStartHz, 0.01)
	local endHz = math.max(BombConfig.PulseEndHz, startHz)
	local cycles = (startHz * pulseElapsed) + (0.5 * (endHz - startHz) * progress * pulseElapsed)
	local alpha = (1 - math.cos(cycles * math.pi * 2)) * 0.5
	local targetColor = if typeof(pulseColor) == "Color3" then pulseColor else BombConfig.PulseRed
	return baseColor:Lerp(targetColor, alpha)
end

function BombFusePulse.Update(visual, getStyle: (any) -> PulseStyle, now: number?)
	local highlight = visual.highlight
	if not (highlight and highlight.Parent) then
		return
	end

	if visual.frozen == true then
		highlight.FillColor = FROZEN_COLOR
		highlight.OutlineColor = FROZEN_COLOR
		highlight.FillTransparency = FROZEN_FILL_TRANSPARENCY
		highlight.OutlineTransparency = FROZEN_OUTLINE_TRANSPARENCY
		return
	end

	local style = getStyle(visual)
	local fuseProgress, elapsed = getProgress(visual, now or workspace:GetServerTimeNow())
	local color = getPulseColor(style.baseColor, style.pulseColor, fuseProgress, elapsed)
	local fillTransparency = style.fillStart
		+ ((BombConfig.PulseEndFillTransparency - BombConfig.PulseStartFillTransparency) * fuseProgress)
	local outlineTransparency = style.outlineStart
		+ ((BombConfig.PulseEndOutlineTransparency - BombConfig.PulseStartOutlineTransparency) * fuseProgress)

	highlight.FillColor = color
	highlight.OutlineColor = color
	highlight.FillTransparency = math.clamp(fillTransparency, 0, 1)
	highlight.OutlineTransparency = math.clamp(outlineTransparency, 0, 1)
end

function BombFusePulse.Stop(visual)
	if visual.pulseConnection then
		visual.pulseConnection:Disconnect()
		visual.pulseConnection = nil
	end
	if visual.highlight and visual.highlight.Parent then
		visual.highlight:Destroy()
	end
	visual.highlight = nil
end

function BombFusePulse.Start(
	visual,
	adornee: Instance,
	fuseStartedAt: number,
	fuseEndsAt: number,
	getStyle: (any) -> PulseStyle
)
	BombFusePulse.Stop(visual)

	local highlight = Instance.new("Highlight")
	highlight.Name = "BombFuseHighlight"
	highlight.Adornee = adornee
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillTransparency = BombConfig.PulseStartFillTransparency
	highlight.OutlineTransparency = BombConfig.PulseStartOutlineTransparency
	highlight.Parent = adornee

	visual.highlight = highlight
	visual.fuseStartedAt = fuseStartedAt
	visual.fuseEndsAt = fuseEndsAt
	BombFusePulse.Update(visual, getStyle)

	visual.pulseConnection = RunService.RenderStepped:Connect(function()
		local token = RuntimeProfiler.Begin("Client/BombController/BombPulse")
		BombFusePulse.Update(visual, getStyle)
		RuntimeProfiler.End("Client/BombController/BombPulse", token)
	end)
end

return table.freeze(BombFusePulse)
