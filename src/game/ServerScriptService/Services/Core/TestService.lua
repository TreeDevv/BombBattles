local TestService = {}

function TestService:OnStart()
	print("TestService initialized!")
end

function TestService:OnPlayerAdded(player: Player)
	print("TestService recognized new player", player)
end

function TestService:OnPlayerRemoving(player: Player)
	print("TestService recognized player disconnect", player)
end

return TestService
