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

POTGCutsceneConfig.DefaultCutsceneId = "HollowPurple"
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
		bombAttachmentNames = table.freeze({ "RightGripAttachment", "BombGripAttachment" }),
		bombHandleNames = table.freeze({ "RightHandle", "RIghtHandle", "Bomb" }),
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
		bombAttachmentNames = table.freeze({ "RightGripAttachment", "BombGripAttachment" }),
		bombHandleNames = table.freeze({ "RightHandle", "RIghtHandle", "Bomb" }),
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
