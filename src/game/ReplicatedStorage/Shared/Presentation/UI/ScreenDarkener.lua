local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ScreenDarkener = {}
ScreenDarkener.__index = ScreenDarkener

local function getCanvasGroup()
	local player = Players.LocalPlayer
	if not player then
		return nil
	end

	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end

	local visuals = playerGui:FindFirstChild("Visuals")
	if not visuals then
		return nil
	end

	local canvasGroup = visuals:FindFirstChild("CanvasGroup")
	if canvasGroup and canvasGroup:IsA("CanvasGroup") then
		return canvasGroup
	end

	return nil
end

function ScreenDarkener.New(padding: number?, tweenTime: number?)
	local self = setmetatable({}, ScreenDarkener)

	self.Player = Players.LocalPlayer
	self.Camera = workspace.CurrentCamera
	self.CanvasGroup = getCanvasGroup()
	self.TopFrame = self.CanvasGroup and self.CanvasGroup:FindFirstChild("Top") or nil
	self.BottomFrame = self.CanvasGroup and self.CanvasGroup:FindFirstChild("Bottom") or nil
	self.LeftFrame = self.CanvasGroup and self.CanvasGroup:FindFirstChild("Left") or nil
	self.RightFrame = self.CanvasGroup and self.CanvasGroup:FindFirstChild("Right") or nil
	self.Padding = padding or 5
	self.TweenTime = tweenTime or 0.2
	self.Tweens = {}
	self.LastGoal = {}
	self.Target = nil
	self.Connection = nil

	return self
end

function ScreenDarkener:IsReady(): boolean
	return self.CanvasGroup ~= nil
		and self.TopFrame ~= nil
		and self.BottomFrame ~= nil
		and self.LeftFrame ~= nil
		and self.RightFrame ~= nil
end

function ScreenDarkener:TweenFrame(frame: GuiObject, goal)
	local currentTween = self.Tweens[frame]
	if currentTween then
		currentTween:Cancel()
	end

	self.Tweens[frame] = TweenService:Create(frame, TweenInfo.new(self.TweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	self.Tweens[frame]:Play()
end

function ScreenDarkener:OffScreenGoals()
	if not self:IsReady() then
		return {}
	end

	local screenWidth = self.CanvasGroup.AbsoluteSize.X
	local screenHeight = self.CanvasGroup.AbsoluteSize.Y

	return {
		[self.TopFrame] = { Position = UDim2.fromOffset(0, 0), Size = UDim2.fromOffset(screenWidth, 0) },
		[self.BottomFrame] = { Position = UDim2.fromOffset(0, screenHeight), Size = UDim2.fromOffset(screenWidth, 0) },
		[self.LeftFrame] = { Position = UDim2.fromOffset(0, 0), Size = UDim2.fromOffset(0, screenHeight) },
		[self.RightFrame] = { Position = UDim2.fromOffset(screenWidth, 0), Size = UDim2.fromOffset(0, screenHeight) },
	}
end

function ScreenDarkener:UpdateLoop()
	if not self:IsReady() then
		return
	end

	self.Connection = RunService.RenderStepped:Connect(function()
		if not self.Target or not self:IsReady() then
			return
		end

		local screenWidth = self.CanvasGroup.AbsoluteSize.X
		local screenHeight = self.CanvasGroup.AbsoluteSize.Y
		local goals = {}
		local minX, minY, maxX, maxY
		local anyOnScreen = true

		local guiService = game:GetService("GuiService")
		local inset = guiService:GetGuiInset()

		if self.Target:IsA("GuiObject") then
			local absPos = self.Target.AbsolutePosition
			local absSize = self.Target.AbsoluteSize
			local parent = self.Target.Parent
			while parent do
				if parent:IsA("ScrollingFrame") then
					absPos -= Vector2.new(parent.CanvasPosition.X, parent.CanvasPosition.Y)
				end
				parent = parent.Parent
			end

			minX = absPos.X + inset.X - self.Padding
			minY = absPos.Y + inset.Y - self.Padding
			maxX = absPos.X + inset.X + absSize.X + self.Padding
			maxY = absPos.Y + inset.Y + absSize.Y + self.Padding
		elseif self.Target:IsA("BasePart") and self.Camera then
			local part = self.Target
			local corners = {
				part.Position + Vector3.new(part.Size.X / 2, part.Size.Y / 2, part.Size.Z / 2),
				part.Position + Vector3.new(-part.Size.X / 2, part.Size.Y / 2, part.Size.Z / 2),
				part.Position + Vector3.new(part.Size.X / 2, -part.Size.Y / 2, part.Size.Z / 2),
				part.Position + Vector3.new(-part.Size.X / 2, -part.Size.Y / 2, part.Size.Z / 2),
				part.Position + Vector3.new(part.Size.X / 2, part.Size.Y / 2, -part.Size.Z / 2),
				part.Position + Vector3.new(-part.Size.X / 2, part.Size.Y / 2, -part.Size.Z / 2),
				part.Position + Vector3.new(part.Size.X / 2, -part.Size.Y / 2, -part.Size.Z / 2),
				part.Position + Vector3.new(-part.Size.X / 2, -part.Size.Y / 2, -part.Size.Z / 2),
			}

			minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
			anyOnScreen = false

			for _, corner in ipairs(corners) do
				local screenPos, onScreen = self.Camera:WorldToViewportPoint(corner)
				if onScreen then
					anyOnScreen = true
					minX = math.min(minX, screenPos.X)
					maxX = math.max(maxX, screenPos.X)
					minY = math.min(minY, screenPos.Y)
					maxY = math.max(maxY, screenPos.Y)
				end
			end

			if not anyOnScreen then
				goals = self:OffScreenGoals()
			end
		else
			goals = self:OffScreenGoals()
			anyOnScreen = false
		end

		if anyOnScreen then
			goals[self.TopFrame] = {
				Position = UDim2.fromOffset(0, 0),
				Size = UDim2.fromOffset(screenWidth, math.max(math.ceil(minY), 0)),
			}
			goals[self.BottomFrame] = {
				Position = UDim2.fromOffset(0, math.min(maxY, screenHeight)),
				Size = UDim2.fromOffset(screenWidth, screenHeight - maxY),
			}
			goals[self.LeftFrame] = {
				Position = UDim2.fromOffset(0, 0),
				Size = UDim2.fromOffset(math.max(math.ceil(minX), 0), screenHeight),
			}
			goals[self.RightFrame] = {
				Position = UDim2.fromOffset(math.min(maxX, screenWidth), 0),
				Size = UDim2.fromOffset(screenWidth - maxX, screenHeight),
			}
		end

		for frame, goal in pairs(goals) do
			local last = self.LastGoal[frame]
			if not last or last.Position ~= goal.Position or last.Size ~= goal.Size then
				self:TweenFrame(frame, goal)
				self.LastGoal[frame] = goal
			end
		end
	end)
end

function ScreenDarkener:Activate(target, padding: number?)
	if not self:IsReady() then
		return
	end

	self.CanvasGroup.Visible = true

	for frame, goal in pairs(self:OffScreenGoals()) do
		frame.Position = goal.Position
		frame.Size = goal.Size
	end

	if padding then
		self.Padding = padding
	end

	self.Target = target

	if self.Connection then
		self.Connection:Disconnect()
	end

	self:UpdateLoop()
end

function ScreenDarkener:Deactivate()
	if self.Connection then
		self.Connection:Disconnect()
		self.Connection = nil
	end

	for frame, goal in pairs(self:OffScreenGoals()) do
		self:TweenFrame(frame, goal)
	end
end

function ScreenDarkener:Switch(newTarget, padding: number?)
	if padding then
		self.Padding = padding
	end

	self.Target = newTarget
end

return ScreenDarkener
