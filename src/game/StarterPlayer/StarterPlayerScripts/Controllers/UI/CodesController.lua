local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CodeConfig = require(ReplicatedStorage.Shared.Config.CodeConfig)
local Notify = require(ReplicatedStorage.Shared.UI.Notify)

local FrameController = require(script.Parent:WaitForChild("FrameController"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local FRAME_NAME = CodeConfig.FrameName

local CodesController = {}

CodesController._connections = {} :: { RBXScriptConnection }
CodesController._frameConnections = {} :: { RBXScriptConnection }
CodesController._frame = nil :: GuiObject?
CodesController._textBox = nil :: TextBox?
CodesController._confirmButton = nil :: GuiButton?
CodesController._requestRemote = nil :: RemoteFunction?
CodesController._submitting = false
CodesController._rebindQueued = false
CodesController._warnedMissingFrame = false

local function track(list: { RBXScriptConnection }, connection: RBXScriptConnection?)
	if connection then
		table.insert(list, connection)
	end
end

local function disconnectAll(list: { RBXScriptConnection })
	for _, connection in ipairs(list) do
		connection:Disconnect()
	end
	table.clear(list)
end

local function findImageButton(parent: Instance?, name: string): ImageButton?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("ImageButton") then child else nil
end

local function findTextBox(parent: Instance?, name: string): TextBox?
	local child = parent and parent:FindFirstChild(name)
	return if child and child:IsA("TextBox") then child else nil
end

local function waitForRemoteFunction(remoteName: string): RemoteFunction?
	local remotesFolder = ReplicatedStorage:WaitForChild(CodeConfig.RemotesFolderName, 10)
	if not remotesFolder then
		return nil
	end

	local remote = remotesFolder:WaitForChild(remoteName, 10)
	return if remote and remote:IsA("RemoteFunction") then remote else nil
end

local function setButtonEnabled(button: GuiButton?, enabled: boolean)
	if not button then
		return
	end

	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
end

function CodesController:_showResponse(response: any)
	if typeof(response) ~= "table" then
		Notify.Show("Codes are unavailable right now.", { color = "Red" })
		return
	end

	local message = tostring(response.message or "Codes are unavailable right now.")
	local color = response.color
	if not color then
		color = if response.ok == true then "Green" else "Red"
	end
	Notify.Show(message, { color = color })
end

function CodesController:_submit()
	if self._submitting then
		return
	end

	local remote = self._requestRemote
	local textBox = self._textBox
	if not textBox then
		return
	end
	if not remote then
		Notify.Show("Codes are unavailable right now.", { color = "Red" })
		return
	end

	local code = CodeConfig.NormalizeCode(textBox.Text)
	if code == "" then
		Notify.Show("Enter a code first.", { color = "Red" })
		return
	end

	self._submitting = true
	setButtonEnabled(self._confirmButton, false)

	task.spawn(function()
		local ok, response = pcall(function()
			return remote:InvokeServer({
				action = CodeConfig.Actions.Redeem,
				code = code,
			})
		end)

		self._submitting = false
		setButtonEnabled(self._confirmButton, true)

		if not ok then
			warn("[CodesController] Redeem request failed: " .. tostring(response))
			Notify.Show("Codes are unavailable right now.", { color = "Red" })
			return
		end

		self:_showResponse(response)
		if typeof(response) == "table" and response.ok == true and self._textBox then
			self._textBox.Text = ""
		end
	end)
end

function CodesController:_ensureFrameRegistered(frame: GuiObject)
	if not CollectionService:HasTag(frame, FrameController.FrameTag) then
		CollectionService:AddTag(frame, FrameController.FrameTag)
	end

	if frame:GetAttribute(FrameController.ExclusiveAttribute) ~= true then
		frame:SetAttribute(FrameController.ExclusiveAttribute, true)
	end
end

function CodesController:_bindFrame(frame: Instance?)
	disconnectAll(self._frameConnections)
	self._frame = nil
	self._textBox = nil
	self._confirmButton = nil
	self._submitting = false

	if not (frame and frame:IsA("GuiObject")) then
		return
	end

	self._frame = frame
	self:_ensureFrameRegistered(frame)

	local closeButton = findImageButton(frame, "CloseButton")
	track(self._frameConnections, closeButton and closeButton.Activated:Connect(function()
		FrameController:CloseFrame(FRAME_NAME)
	end))

	self._confirmButton = findImageButton(frame, "ConfirmButton")
	track(self._frameConnections, self._confirmButton and self._confirmButton.Activated:Connect(function()
		self:_submit()
	end))

	local box = frame:FindFirstChild("Box")
	self._textBox = findTextBox(box, "TextBox")
	track(self._frameConnections, self._textBox and self._textBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			self:_submit()
		end
	end))

	setButtonEnabled(self._confirmButton, true)
end

function CodesController:_scheduleRebind()
	if self._rebindQueued then
		return
	end

	self._rebindQueued = true
	task.defer(function()
		self._rebindQueued = false
		if PlayerGui.Parent then
			self:_bindPlayerGui(PlayerGui)
		end
	end)
end

function CodesController:_bindPlayerGui(root: Instance?)
	if not root then
		self:_bindFrame(nil)
		return
	end

	local frame = root:FindFirstChild(FRAME_NAME, true)
	self:_bindFrame(frame)
	if frame then
		self._warnedMissingFrame = false
	elseif not self._warnedMissingFrame then
		self._warnedMissingFrame = true
		warn(("[CodesController] Could not find %s under PlayerGui."):format(FRAME_NAME))
	end
end

function CodesController:OnStart()
	self:_bindPlayerGui(PlayerGui)
	track(self._connections, PlayerGui.DescendantAdded:Connect(function(descendant)
		if descendant.Name == FRAME_NAME or descendant.Name == "TextBox" or descendant.Name == "ConfirmButton" then
			self:_scheduleRebind()
		end
	end))

	task.spawn(function()
		self._requestRemote = waitForRemoteFunction(CodeConfig.RequestRemoteName)
		if not self._requestRemote then
			warn("[CodesController] Code redeem remote was not found.")
		end
	end)
end

return CodesController
