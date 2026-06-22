local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FinisherConfig = require(ReplicatedStorage.Shared.Config.FinisherConfig)
local EmitService = require(ReplicatedStorage.Shared.Effects.EmitService)

local FinisherVFX = {}

local CLONE_LIFETIME_SECONDS = 8

local function prepBasePart(part: BasePart, hideAnchor: boolean)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	if hideAnchor then
		part.Transparency = 1
	end
end

local function placeClone(clone: Instance, cframe: CFrame)
	if clone:IsA("BasePart") then
		clone.CFrame = cframe
		prepBasePart(clone, true)
		return
	end

	if clone:IsA("Model") then
		clone:PivotTo(cframe)
		for _, descendant in ipairs(clone:GetDescendants()) do
			if descendant:IsA("BasePart") then
				prepBasePart(descendant, false)
			end
		end
		return
	end

	local part = clone:FindFirstChildWhichIsA("BasePart", true)
	if part then
		part.CFrame = cframe
	end
end

function FinisherVFX.PlayAt(finisherId: any, position: Vector3, options): boolean
	if typeof(position) ~= "Vector3" then
		return false
	end

	local source = FinisherConfig.GetAsset(finisherId)
	if not source then
		return false
	end

	if not EmitService.EnsureInitialized("[FinisherVFX]") then
		return false
	end

	local parent = if typeof(options) == "table" and typeof(options.parent) == "Instance"
		then options.parent
		else workspace.Terrain
	local clone = source:Clone()
	clone.Name = "Finisher_" .. FinisherConfig.NormalizeFinisherId(finisherId)
	placeClone(clone, CFrame.new(position))
	clone.Parent = parent

	if not EmitService.Emit(clone, "[FinisherVFX]") then
		clone:Destroy()
		return false
	end

	Debris:AddItem(clone, CLONE_LIFETIME_SECONDS)
	return true
end

return table.freeze(FinisherVFX)
