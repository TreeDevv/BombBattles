local RemoteUtil = {}

type EnsureFolderOptions = {
	dedupe: boolean?,
}

local function isClass(instance: Instance?, className: string): boolean
	return instance ~= nil and instance:IsA(className)
end

function RemoteUtil.EnsureFolder(parent: Instance, name: string, options: EnsureFolderOptions?): Folder
	local selected: Folder? = nil
	local dedupe = options and options.dedupe == true

	for _, child in ipairs(parent:GetChildren()) do
		if child.Name ~= name then
			continue
		end
		if child:IsA("Folder") and not selected then
			selected = child
		elseif dedupe or not child:IsA("Folder") then
			child:Destroy()
		end
	end

	if selected then
		return selected
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

function RemoteUtil.EnsureRemoteEvent(folder: Folder, name: string, dedupe: boolean?): RemoteEvent
	local selected: RemoteEvent? = nil

	for _, child in ipairs(folder:GetChildren()) do
		if child.Name ~= name then
			continue
		end
		if child:IsA("RemoteEvent") and not selected then
			selected = child
		elseif dedupe == true or not child:IsA("RemoteEvent") then
			child:Destroy()
		end
	end

	if selected then
		return selected
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

function RemoteUtil.GetRemoteEvent(parent: Instance, folderName: string, remoteName: string): RemoteEvent?
	local folder = parent:FindFirstChild(folderName)
	if not isClass(folder, "Folder") then
		return nil
	end

	local remote = folder:FindFirstChild(remoteName)
	return if isClass(remote, "RemoteEvent") then remote :: RemoteEvent else nil
end

function RemoteUtil.EnsureRemoteEventInFolder(parent: Instance, folderName: string, remoteName: string, dedupe: boolean?): RemoteEvent
	local folder = RemoteUtil.EnsureFolder(parent, folderName, {
		dedupe = dedupe,
	})
	return RemoteUtil.EnsureRemoteEvent(folder, remoteName, dedupe)
end

return RemoteUtil
