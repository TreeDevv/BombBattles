local EmoteEffect = require(script.Parent.Parent.EmoteEffect)

local CatDance = EmoteEffect.Create("Cat Dance", { catalogOrder = 5 })

function CatDance:Begin(_character: Model, runtime)
	local root = runtime:GetRoot()
	local sound = runtime:PlaySound(runtime:GetChild(runtime.vfxModule, "CatDance"), root)
	if not (root and sound) then
		return
	end

	local colors = {
		Color3.new(1, 0.317647, 0),
		Color3.new(1, 0, 0),
		Color3.new(0, 0.14902, 1),
		Color3.new(0.831373, 1, 0),
		Color3.new(0, 0.815686, 1),
		Color3.new(0.466667, 1, 0.705882),
	}

	task.spawn(function()
		while runtime.running and root:FindFirstChild("CatDance") do
			runtime:SpawnBodyAfterimage(colors[math.random(1, #colors)], 1.2)
			task.wait(0.3)
		end
	end)
end

function CatDance:Finish(_character: Model, runtime)
	runtime:DestroyChild(runtime:GetRoot(), "CatDance")
end

return CatDance
