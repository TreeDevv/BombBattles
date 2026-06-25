local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RuntimeProfiler = require(ReplicatedStorage.Shared.Common.RuntimeProfiler)

local RoundVoidFallRuntime = {}

function RoundVoidFallRuntime.GetKillY(activeMap: Model?, padding: number): number?
	if activeMap then
		local pivot, size = activeMap:GetBoundingBox()
		return pivot.Position.Y - (size.Y * 0.5) - padding
	end

	local fallenPartsDestroyHeight = workspace.FallenPartsDestroyHeight
	if typeof(fallenPartsDestroyHeight) == "number" then
		return fallenPartsDestroyHeight + padding
	end

	return nil
end

function RoundVoidFallRuntime.KillPlayerForVoidFall(options): boolean
	local player: Player = options.player
	if not options.isEligible(player) then
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not (character and character.Parent and humanoid and rootPart and rootPart:IsA("BasePart")) then
		options.debugDeathFlow("Void fall death; missing character parts", player.Name)
		RuntimeProfiler.Count("Server/Round/Death/VoidFallMissingCharacters")
		if character then
			character:SetAttribute("DeathReason", "VoidFall")
		end
		if options.handleVoidDeath then
			return options.handleVoidDeath(player) == true
		end
		return false
	end
	if rootPart.Position.Y >= options.voidKillY then
		return false
	end

	options.debugDeathFlow(
		"Void fall death",
		player.Name,
		"y",
		rootPart.Position.Y,
		"threshold",
		options.voidKillY,
		"health",
		humanoid.Health
	)
	RuntimeProfiler.Count("Server/Round/Death/VoidFalls")
	character:SetAttribute("DeathReason", "VoidFall")
	options.applyDeathRagdoll(character, "VoidFall")
	if options.handleVoidDeath then
		options.handleVoidDeath(player)
	end
	if humanoid.Health > 0 then
		humanoid.Health = 0
	end
	return true
end

function RoundVoidFallRuntime.CheckVoidFalls(options)
	local voidKillY = options.getVoidKillY()
	if not voidKillY then
		return
	end

	for player in pairs(options.alivePlayers) do
		RoundVoidFallRuntime.KillPlayerForVoidFall({
			player = player,
			voidKillY = voidKillY,
			isEligible = options.isEligible,
			debugDeathFlow = options.debugDeathFlow,
			applyDeathRagdoll = options.applyDeathRagdoll,
			handleVoidDeath = options.handleVoidDeath,
		})
	end
end

return table.freeze(RoundVoidFallRuntime)
