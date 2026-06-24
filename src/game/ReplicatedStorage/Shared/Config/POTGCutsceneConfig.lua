local POTGCutsceneConfig = {}

local function cf(
	x: number,
	y: number,
	z: number,
	lookX: number,
	lookY: number,
	lookZ: number,
	upX: number,
	upY: number,
	upZ: number
): CFrame
	local position = Vector3.new(x, y, z)
	return CFrame.lookAt(position, position + Vector3.new(lookX, lookY, lookZ), Vector3.new(upX, upY, upZ))
end

POTGCutsceneConfig.DefaultCutsceneId = "TooFast"
POTGCutsceneConfig.FallbackCutsceneId = "DefaultHighlightIntro"

POTGCutsceneConfig.AnimationSourceTypes = table.freeze({
	AnimationId = "AnimationId",
	KeyframeSequence = "KeyframeSequence",
})

POTGCutsceneConfig.Cutscenes = table.freeze({
	DefaultHighlightIntro = table.freeze({
		id = "DefaultHighlightIntro",
		assetFolderName = "Default",
		replicatedAssetName = "DefaultHighlightIntro",
		characterRigName = "TemplateR6",
		cameraRigName = "CamRigWithLetterBox1",
		cameraBoneName = "cameraBone",
		pivotPartName = "Pivot",
		characterAnimation = table.freeze({
			type = POTGCutsceneConfig.AnimationSourceTypes.AnimationId,
			animationId = "rbxassetid://92968462721009",
		}),
		cameraAnimation = table.freeze({
			type = POTGCutsceneConfig.AnimationSourceTypes.AnimationId,
			animationId = "rbxassetid://72801775878605",
		}),
		durationSeconds = 2.45,
		cameraFovKeys = table.freeze({
			table.freeze({ time = 0, value = 20 }),
			table.freeze({ time = 17 / 60, value = 70, easingStyle = Enum.EasingStyle.Quint, easingDirection = Enum.EasingDirection.In }),
			table.freeze({ time = 126 / 60, value = 60 }),
		}),
		dof = table.freeze({
			enabled = true,
			farIntensity = 10,
			focusDistance = 0,
			nearIntensity = 0,
			inFocusRadiusKeys = table.freeze({
				table.freeze({ time = 0, value = 0 }),
				table.freeze({ time = 16 / 60, value = 10 }),
				table.freeze({ time = 115 / 60, value = 4 }),
			}),
		}),
		events = table.freeze({
			table.freeze({ time = 0, type = "Emit", effectName = "Explosion" }),
			table.freeze({ time = 67 / 60, type = "Emit", effectName = "Explosion2" }),
		}),
	}),

	HollowPurple = table.freeze({
		id = "HollowPurple",
		assetFolderName = "Hollow Purple",
		replicatedAssetName = "HollowPurpleHighlightIntro",
		characterRigName = "TemplateR6",
		cameraRigName = "CamRigWithLetterBox1",
		cameraBoneName = "cameraBone",
		pivotPartName = "Pivot",
		motionSourcePivotCFrame = cf(23.875103, 3.05721, -18.511501, 0.013962141, 0, 0.999902546, 0, 1, 0),
		characterAnimation = table.freeze({
			type = POTGCutsceneConfig.AnimationSourceTypes.AnimationId,
			animationId = "rbxassetid://116571629519352",
		}),
		cameraAnimation = table.freeze({
			type = POTGCutsceneConfig.AnimationSourceTypes.AnimationId,
			animationId = "rbxassetid://101227359542051",
		}),
		durationSeconds = 2.666667,
		cameraFovKeys = table.freeze({
			table.freeze({ time = 0, value = 50 }),
			table.freeze({ time = 27 / 60, value = 70 }),
			table.freeze({ time = 300 / 60, value = 70 }),
		}),
		dof = table.freeze({
			enabled = false,
		}),
		events = table.freeze({
			table.freeze({
				time = 58 / 60,
				type = "Code",
				effectName = "SpawnVFX",
				code = [[
local EmitModule = require(game.ReplicatedStorage.VFXHandler)
EmitModule:Emit(workspace.HighlightIntros["Hollow Purple"].SpawnVFX)
				]],
			}),
			table.freeze({
				time = 85 / 60,
				type = "Code",
				frames = 2,
				color = Color3.fromRGB(195, 155, 255),
				code = [[
local EmitModule = require(game.ReplicatedStorage.VFXHandler)
EmitModule:ImpactFrames(2, Color3.fromRGB(195, 155, 255))
				]],
			}),
			table.freeze({
				time = 107 / 60,
				type = "Code",
				effectName = "Burst",
				code = [[
local EmitModule = require(game.ReplicatedStorage.VFXHandler)
EmitModule:Emit(workspace.HighlightIntros["Hollow Purple"].Burst)
				]],
			}),
		}),
		motionTracks = table.freeze({
			table.freeze({
				path = "RedBluePart",
				apply = "WorldCFrame",
				keys = table.freeze({
					table.freeze({ time = 0, cframe = cf(23.320, 3.000, -17.630, 0, 0, -1, 0, 1, 0) }),
					table.freeze({ time = 22 / 60, cframe = cf(23.320, 3.302, -17.305, 0, 0, -1, 0, 1, 0) }),
					table.freeze({ time = 47 / 60, cframe = cf(23.320, 10.092, -9.986, 0, 0, -1, 0, 1, 0) }),
					table.freeze({
						time = 59 / 60,
						cframe = cf(23.320, 11.597, -11.519, 0, 0, -1, 0, 1, 0),
						easingStyle = "Constant",
					}),
					table.freeze({ time = 86 / 60, cframe = cf(23.320, -10.805, -11.519, 0, 0, -1, 0, 1, 0) }),
				}),
			}),
			table.freeze({
				path = "RedBluePart.Attachment.Blue",
				apply = "LocalCFrame",
				keys = table.freeze({
					table.freeze({ time = 0, cframe = cf(5.390, 0, 0, 0, 0, -1, 0, 1, 0) }),
					table.freeze({ time = 12 / 60, cframe = cf(6.593, 0, 0, 0, 0, -1, 0, 1, 0) }),
					table.freeze({
						time = 23 / 60,
						cframe = cf(10.000, 0, 0, 0, 0, -1, 0, 1, 0),
						easingStyle = Enum.EasingStyle.Quad,
						easingDirection = Enum.EasingDirection.In,
					}),
					table.freeze({ time = 74 / 60, cframe = cf(0, 0, 0, 0, 0, -1, 0, 1, 0) }),
				}),
			}),
			table.freeze({
				path = "RedBluePart.Attachment.Red",
				apply = "LocalCFrame",
				keys = table.freeze({
					table.freeze({ time = 0, cframe = cf(-8.000, 0, 0, 0, 0, -1, 0, 1, 0) }),
					table.freeze({ time = 12 / 60, cframe = cf(-8.522, 0, 0, 0, 0, -1, 0, 1, 0) }),
					table.freeze({
						time = 23 / 60,
						cframe = cf(-10.000, 0, 0, 0, 0, -1, 0, 1, 0),
						easingStyle = Enum.EasingStyle.Quad,
						easingDirection = Enum.EasingDirection.Out,
					}),
					table.freeze({ time = 74 / 60, cframe = cf(0, 0, 0, 0, 0, -1, 0, 1, 0) }),
				}),
			}),
			table.freeze({
				path = "RedBluePart.Attachment",
				apply = "LocalCFrame",
				keys = table.freeze({
					table.freeze({
						time = 0,
						cframe = cf(0, 0, 0, 0, 0, -1, 0, 1, 0),
						easingStyle = Enum.EasingStyle.Quad,
						easingDirection = Enum.EasingDirection.InOut,
					}),
					table.freeze({ time = 21 / 60, cframe = cf(0, 0, 0, 0, 0, 1, 0, 1, 0) }),
					table.freeze({ time = 30 / 60, cframe = cf(0, 0, 0, 0, 0, -1, 0, -1, 0) }),
					table.freeze({ time = 40 / 60, cframe = cf(0, 0, 0, 0, 0, -1, 1, 0, 0) }),
					table.freeze({ time = 60 / 60, cframe = cf(0, 0, 0, 0, 0, -1, 0, 1, 0) }),
					table.freeze({ time = 78 / 60, cframe = cf(0, 0, 0, 0, 0, -1, -1, 0, 0) }),
				}),
			}),
			table.freeze({
				path = "Purple",
				apply = "WorldCFrame",
				keys = table.freeze({
					table.freeze({
						time = 0,
						cframe = cf(26.190, -1000.000, -12.300, 0, 0, -1, 0, 1, 0),
						easingStyle = "Constant",
					}),
					table.freeze({ time = 28 / 60, cframe = cf(26.190, -1000.000, -12.300, 0, 0, -1, 0, 1, 0) }),
					table.freeze({
						time = 85 / 60,
						cframe = cf(23.240, 12.136, -12.018, 0, 0, -1, 0, 1, 0),
						easingStyle = Enum.EasingStyle.Quad,
						easingDirection = Enum.EasingDirection.In,
					}),
					table.freeze({ time = 107 / 60, cframe = cf(23.240, 12.022, -12.411, 0, -0.004, -1, 0, 1, -0.004) }),
					table.freeze({ time = 145 / 60, cframe = cf(23.240, 5.738, -34.117, 0, -0.210, -0.978, 0, 0.978, -0.210) }),
				}),
			}),
			table.freeze({
				path = "SpawnVFX",
				apply = "WorldCFrame",
				keys = table.freeze({
					table.freeze({ time = 0, cframe = cf(24.642, 12.043, -12.071, -0.017, 0.017, -1, -0.017, 1, 0.018) }),
					table.freeze({ time = 83 / 60, cframe = cf(23.336, 11.732, -11.750, -0.017, 0.017, -1, -0.017, 1, 0.018) }),
				}),
			}),
			table.freeze({
				path = "Burst",
				apply = "WorldCFrame",
				keys = table.freeze({
					table.freeze({ time = 0, cframe = cf(22.808, 7.740, -16.726, 0, 0, -1, 0, 1, 0) }),
					table.freeze({ time = 21 / 60, cframe = cf(23.456, 13.215, -7.154, 0, -0.305, -0.952, 0, 0.952, -0.305) }),
				}),
			}),
		}),
	}),

	TooFast = table.freeze({
		id = "TooFast",
		assetFolderName = "Too Fast",
		replicatedAssetName = "TooFastHighlightIntro",
		characterRigName = "TemplateR6",
		cameraRigName = "CamRigWithLetterBox1",
		cameraBoneName = "cameraBone",
		pivotPartName = "Pivot",
		motionSourcePivotCFrame = cf(
			-35.645168,
			2.840100,
			-19.513357,
			0.062199350,
			0.471390247,
			0.879728615,
			-0.388809651,
			0.823245466,
			-0.413634658
		),
		characterAnimation = table.freeze({
			type = POTGCutsceneConfig.AnimationSourceTypes.AnimationId,
			animationId = "rbxassetid://137853408176426",
		}),
		cameraAnimation = table.freeze({
			type = POTGCutsceneConfig.AnimationSourceTypes.AnimationId,
			animationId = "rbxassetid://132172183490412",
		}),
		durationSeconds = 5,
		cameraFovKeys = table.freeze({
			table.freeze({ time = 0, value = 60 }),
			table.freeze({ time = 11 / 60, value = 70 }),
			table.freeze({ time = 300 / 60, value = 70 }),
		}),
		dof = table.freeze({
			enabled = false,
		}),
		events = table.freeze({
			table.freeze({
				time = 7 / 60,
				type = "Code",
				effectName = "Explosion",
				code = [[
local EmitModule = require(game.ReplicatedStorage.VFXHandler)
EmitModule:Emit(workspace.HighlightIntros["Too Fast"].Explosion)
				]],
			}),
			table.freeze({
				time = 22 / 60,
				type = "Code",
				effectName = "Explosion2",
				code = [[
local EmitModule = require(game.ReplicatedStorage.VFXHandler)
EmitModule:Emit(workspace.HighlightIntros["Too Fast"].Explosion2)
				]],
			}),
			table.freeze({
				time = 50 / 60,
				type = "Code",
				effectName = "Explosion3",
				code = [[
local EmitModule = require(game.ReplicatedStorage.VFXHandler)
EmitModule:Emit(workspace.HighlightIntros["Too Fast"].Explosion3)
				]],
			}),
			table.freeze({
				time = 105 / 60,
				type = "Code",
				effectName = "Explosion4",
				code = [[
local EmitModule = require(game.ReplicatedStorage.VFXHandler)
EmitModule:Emit(workspace.HighlightIntros["Too Fast"].Explosion4)
				]],
			}),
		}),
		motionTracks = table.freeze({
			table.freeze({
				path = "Bomb",
				apply = "WorldCFrame",
				keys = table.freeze({
					table.freeze({
						time = 0,
						cframe = cf(-24.928884, 3.624886, -14.968243, 1, 0, 0, 0, 0.998629510, 0.052335940),
						easingStyle = Enum.EasingStyle.Linear,
					}),
					table.freeze({ time = 5 / 60, cframe = cf(-28.816070, -2.932691, -0.727367, 1, 0, 0, 0, 0.998629510, 0.052335940) }),
				}),
			}),
			table.freeze({
				path = "Bomb2",
				apply = "WorldCFrame",
				keys = table.freeze({
					table.freeze({
						time = 0,
						cframe = cf(-34.834693, 7.251448, -20.115728, 1, 0, 0, 0, 0.998629510, 0.052335940),
						easingStyle = Enum.EasingStyle.Linear,
					}),
					table.freeze({ time = 22 / 60, cframe = cf(-38.401822, -2.199681, 2.677660, 1, 0, 0, 0, 0.998629510, 0.052335940) }),
				}),
			}),
			table.freeze({
				path = "Bomb3",
				apply = "WorldCFrame",
				keys = table.freeze({
					table.freeze({
						time = 0,
						cframe = cf(-30.851001, 3.539335, -24.918444, 1, 0, 0, 0, 0.998629510, 0.052335940),
						easingStyle = Enum.EasingStyle.Linear,
					}),
					table.freeze({
						time = 29 / 60,
						cframe = cf(-36.688536, 3.251975, -24.519615, 1, 0, 0, 0, 0.998629570, 0.052335944),
						easingStyle = Enum.EasingStyle.Linear,
					}),
					table.freeze({ time = 55 / 60, cframe = cf(-54.388889, -2.791458, 1.963671, 1, 0, 0, 0, 0.830796480, 0.556576312) }),
				}),
			}),
		}),
	}),
})

function POTGCutsceneConfig.GetCutscene(cutsceneId: any)
	if typeof(cutsceneId) == "string" and cutsceneId ~= "" then
		local cutscene = POTGCutsceneConfig.Cutscenes[cutsceneId]
		if cutscene then
			return cutscene
		end
	end

	return POTGCutsceneConfig.Cutscenes[POTGCutsceneConfig.FallbackCutsceneId]
end

function POTGCutsceneConfig.GetDefaultCutscene()
	return POTGCutsceneConfig.GetCutscene(POTGCutsceneConfig.DefaultCutsceneId)
end

return table.freeze(POTGCutsceneConfig)
