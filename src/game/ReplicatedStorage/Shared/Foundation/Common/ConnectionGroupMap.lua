local ConnectionGroupMap = {}
ConnectionGroupMap.__index = ConnectionGroupMap

function ConnectionGroupMap.new()
	return setmetatable({
		_groups = {},
	}, ConnectionGroupMap)
end

function ConnectionGroupMap:Reset(key: any)
	self:Disconnect(key)
	self._groups[key] = {}
end

function ConnectionGroupMap:Add(key: any, connection: RBXScriptConnection)
	local group = self._groups[key]
	if group then
		table.insert(group, connection)
	else
		connection:Disconnect()
	end
end

function ConnectionGroupMap:Disconnect(key: any)
	local group = self._groups[key]
	if not group then
		return
	end

	for _, connection in ipairs(group) do
		connection:Disconnect()
	end
	self._groups[key] = nil
end

function ConnectionGroupMap:DisconnectAll()
	for key in pairs(self._groups) do
		self:Disconnect(key)
	end
end

return ConnectionGroupMap
