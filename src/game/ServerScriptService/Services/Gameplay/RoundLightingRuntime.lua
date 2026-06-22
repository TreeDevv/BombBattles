local Lighting = game:GetService("Lighting")

local RoundLightingRuntime = {}

local MAP_LIGHTING_ATTR = "RoundMapLighting"
local DEFAULT_LIGHTING_ATTR = "RoundDefaultLighting"

local defaultLightingTemplates: { Instance }? = nil
local originalDefaultChildren: { [Instance]: boolean } = {}

local function snapshotDefaultLighting()
	if defaultLightingTemplates then
		return
	end

	defaultLightingTemplates = {}
	table.clear(originalDefaultChildren)
	for _, child in ipairs(Lighting:GetChildren()) do
		originalDefaultChildren[child] = true
		local clone = child:Clone()
		clone:SetAttribute(DEFAULT_LIGHTING_ATTR, true)
		table.insert(defaultLightingTemplates, clone)
	end
end

local function isManagedLightingChild(child: Instance): boolean
	return child:GetAttribute(MAP_LIGHTING_ATTR) == true
		or child:GetAttribute(DEFAULT_LIGHTING_ATTR) == true
		or originalDefaultChildren[child] == true
end

local function clearManagedLighting()
	snapshotDefaultLighting()
	for _, child in ipairs(Lighting:GetChildren()) do
		if isManagedLightingChild(child) then
			child:Destroy()
		end
	end
end

local function cloneLightingChildren(sourceFolder: Instance, attributeName: string)
	for _, child in ipairs(sourceFolder:GetChildren()) do
		local clone = child:Clone()
		clone:SetAttribute(attributeName, true)
		clone.Parent = Lighting
	end
end

function RoundLightingRuntime.Initialize()
	snapshotDefaultLighting()
end

function RoundLightingRuntime.ApplyMapLighting(map: Model?)
	if not map then
		return false
	end

	local lightingFolder = map:FindFirstChild("Lighting")
	if not (lightingFolder and lightingFolder:IsA("Folder")) then
		RoundLightingRuntime.RestoreDefaultLighting()
		return false
	end

	clearManagedLighting()
	cloneLightingChildren(lightingFolder, MAP_LIGHTING_ATTR)
	return true
end

function RoundLightingRuntime.RestoreDefaultLighting()
	snapshotDefaultLighting()
	clearManagedLighting()

	for _, template in ipairs(defaultLightingTemplates or {}) do
		local clone = template:Clone()
		clone:SetAttribute(DEFAULT_LIGHTING_ATTR, true)
		clone.Parent = Lighting
	end
end

return table.freeze(RoundLightingRuntime)
