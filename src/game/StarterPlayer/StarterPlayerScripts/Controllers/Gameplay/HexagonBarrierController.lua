local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local DistanceFade = require(ReplicatedStorage.Shared.Effects.DistanceFade)

local BARRIER_PATH = "HexagonBarrier"
local TWEEN_INFO = TweenInfo.new(6, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false)

local HexagonBarrierController = {}

local distanceFade = nil
local heartbeatConnection: RBXScriptConnection? = nil
local tweenValue: Vector3Value? = nil
local tween = nil

local distanceFadeSettings = {
	["EdgeDistanceCalculations"] = true,
	["Texture"] = "rbxassetid://18852900044",
	["TextureTransparency"] = 0.25,
	["BackgroundTransparency"] = 0.95,
	["TextureColor"] = Color3.fromRGB(115, 248, 255),
	["BackgroundColor"] = Color3.fromRGB(0, 153, 255),
	["TextureSize"] = Vector2.new(6, 5.5),
	["TextureOffset"] = Vector2.new(0, 0.5),
	["Brightness"] = 3,
}

local baseOffsetsX = {
	["1"] = -3,
	["2"] = -2,
	["3"] = -1,
	["4"] = 0,
	["5"] = 1,
	["6"] = 2,
	["7"] = 3,
}

local function disconnect()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	if tween then
		tween:Cancel()
		tween = nil
	end
	if tweenValue then
		tweenValue:Destroy()
		tweenValue = nil
	end
	if distanceFade then
		distanceFade:Clear()
		distanceFade = nil
	end
end

local function getBarrierFolder(): Instance?
	return workspace:FindFirstChild(BARRIER_PATH)
end

function HexagonBarrierController:OnStart()
	disconnect()

	local folder = getBarrierFolder() or workspace:WaitForChild(BARRIER_PATH, 30)
	if not folder then
		warn("[HexagonBarrierController] Missing Workspace.HexagonBarrier")
		return
	end

	local part = folder:WaitForChild("1", 30)
	if not (part and part:IsA("BasePart")) then
		warn("[HexagonBarrierController] Missing Workspace.HexagonBarrier.1")
		return
	end

	distanceFade = DistanceFade.new()
	distanceFade:UpdateSettings(distanceFadeSettings)

	local partsToAdd = {
		part,
	}

	for _, basePart in partsToAdd do
		distanceFade:AddFace(basePart, Enum.NormalId.Front)
		distanceFade:AddFace(basePart, Enum.NormalId.Back)
	end

	tweenValue = Instance.new("Vector3Value")
	tween = TweenService:Create(tweenValue, TWEEN_INFO, { Value = Vector3.new(-6, 5.5) })
	tween:Play()

	heartbeatConnection = RunService.Heartbeat:Connect(function()
		for _, basePart in partsToAdd do
			if not basePart.Parent then
				continue
			end

			local offsetX = baseOffsetsX[basePart.Name]
			if offsetX == nil then
				continue
			end

			local offsetY = tweenValue and tweenValue.Value.Y or 0.5
			distanceFade:UpdateFaceSettings(basePart, Enum.NormalId.Front, {
				["TextureOffset"] = Vector2.new(offsetX, offsetY),
			})
			distanceFade:UpdateFaceSettings(basePart, Enum.NormalId.Back, {
				["TextureOffset"] = Vector2.new(-offsetX, offsetY),
			})
		end

		distanceFade:Step()
	end)
end

function HexagonBarrierController:Destroy()
	disconnect()
end

return HexagonBarrierController
