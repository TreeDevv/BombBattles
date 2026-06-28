local AbilityConfig = require(script.Parent.AbilityConfig)
local BombSkinConfig = require(script.Parent.BombSkinConfig)
local HighlightIntroConfig = require(script.Parent.HighlightIntroConfig)

local BundleCatalog = {}

BundleCatalog.DefaultCollectionId = "FatCollection"

BundleCatalog.UnsupportedPresenters = table.freeze({
	WeaponActionPresenter = true,
	BombThrowPresenter = true,
	ExplosionPresenter = true,
	AuraPresenter = true,
	FinisherPresenter = true,
	MontagePresenter = true,
})

BundleCatalog.UnsupportedStagePresets = table.freeze({
	CharacterAction = true,
	DualPedestalCharacter = true,
	Montage = true,
})

BundleCatalog.Collections = table.freeze({
	FatCollection = table.freeze({
		Id = "FatCollection",
		DisplayName = "Limited Time Bundles",
		ThemeId = "FatPack",
		EndsAt = 1893456000, -- 2030-01-01T00:00:00Z placeholder.
		PageIds = table.freeze({ "InfinityBundlePage", "FatPackPage" }),
		DefaultPageId = "InfinityBundlePage",
	}),
})

BundleCatalog.Pages = table.freeze({
	InfinityBundlePage = table.freeze({
		Id = "InfinityBundlePage",
		CardImage = "rbxassetid://109929651731752",
		CardTitle = "Infinity Bundle",
		OfferIds = table.freeze({ "InfinityBundleOffer" }),
		DefaultPreviewId = "InfinityBundleOverview",
	}),
	FatPackPage = table.freeze({
		Id = "FatPackPage",
		CardImage = "rbxassetid://70889136963063",
		CardTitle = "Fat Pack",
		OfferIds = table.freeze({ "FatPackOffer" }),
		DefaultPreviewId = "FatPackOverview",
	}),
})

BundleCatalog.Offers = table.freeze({
	InfinityBundleOffer = table.freeze({
		Id = "InfinityBundleOffer",
		TierStyle = "Standard",
		ProductKey = "InfinityBundle",
		CompareAtPrice = nil,
		Giftable = true,
		Contents = table.freeze({
			table.freeze({
				ItemId = "InfinityAbility",
				PreviewId = "InfinityAuraLanePreview",
			}),
			table.freeze({
				ItemId = "HollowPurpleHighlightIntro",
				PreviewId = "HollowPurpleIntroPreview",
			}),
			table.freeze({
				ItemId = "HollowPurpleBombSkin",
				PreviewId = "HollowPurpleBombLanePreview",
			}),
			table.freeze({
				ItemId = "HonoredOneEmote",
				PreviewId = "HonoredOneEmoteLanePreview",
			}),
		}),
	}),
	FatPackOffer = table.freeze({
		Id = "FatPackOffer",
		TierStyle = "Standard",
		ProductKey = "FatPack",
		CompareAtPrice = nil,
		Giftable = true,
		Contents = table.freeze({
			table.freeze({
				ItemId = "FatBomb",
				PreviewId = "FatBombLanePreview",
			}),
			table.freeze({
				ItemId = "FatGuyBombSkin",
				PreviewId = "FatGuyLanePreview",
			}),
		}),
	}),
})

BundleCatalog.Items = table.freeze({
	InfinityAbility = table.freeze({
		Id = "InfinityAbility",
		DisplayName = "Infinity",
		Category = "Ability",
		EntitlementKey = "Ability:Infinity",
		SourceId = "Infinity",
		DefaultPreviewId = "InfinityAuraLanePreview",
		Icon = (AbilityConfig.GetDefinition("Infinity") and AbilityConfig.GetDefinition("Infinity").icon) or "",
	}),
	HollowPurpleHighlightIntro = table.freeze({
		Id = "HollowPurpleHighlightIntro",
		DisplayName = "Hollow Purple Intro",
		Category = "HighlightIntro",
		EntitlementKey = "HighlightIntro:HollowPurple",
		SourceId = "HollowPurple",
		DefaultPreviewId = "HollowPurpleIntroPreview",
		Icon = HighlightIntroConfig.GetIconImage("HollowPurple") or "",
	}),
	HollowPurpleBombSkin = table.freeze({
		Id = "HollowPurpleBombSkin",
		DisplayName = "Hollow Purple",
		Category = "BombSkin",
		EntitlementKey = "BombSkin:HollowPurple",
		SourceId = "HollowPurple",
		DefaultPreviewId = "HollowPurpleBombLanePreview",
		Icon = BombSkinConfig.GetIconImage("HollowPurple") or "",
	}),
	HonoredOneEmote = table.freeze({
		Id = "HonoredOneEmote",
		DisplayName = "Honored One",
		Category = "Emote",
		EntitlementKey = "Emote:Honored One",
		SourceId = "Honored One",
		DefaultPreviewId = "HonoredOneEmoteLanePreview",
		Icon = HighlightIntroConfig.GetIconImage("HollowPurple") or "",
	}),
	FatBomb = table.freeze({
		Id = "FatBomb",
		DisplayName = "Fat Bomb",
		Category = "Ability",
		EntitlementKey = "Ability:FatBomb",
		SourceId = "FatBomb",
		DefaultPreviewId = "FatBombLanePreview",
		Icon = (AbilityConfig.GetDefinition("FatBomb") and AbilityConfig.GetDefinition("FatBomb").icon) or "",
	}),
	FatGuyBombSkin = table.freeze({
		Id = "FatGuyBombSkin",
		DisplayName = "Fat Guy",
		Category = "BombSkin",
		EntitlementKey = "BombSkin:FatGuy",
		SourceId = "FatGuy",
		DefaultPreviewId = "FatGuyLanePreview",
		Icon = BombSkinConfig.GetIconImage("FatGuy") or "",
	}),
})

BundleCatalog.PreviewRecipes = table.freeze({
	InfinityBundleOverview = table.freeze({
		Id = "InfinityBundleOverview",
		Title = "INFINITY BUNDLE",
		TextGradientTemplateId = "Gojo",
		StagePreset = "PackOverview",
		Presenter = "BundleOverviewPresenter",
		CameraPreset = "Wide",
		PreviewMode = "Scene",
		Config = table.freeze({
			Slots = table.freeze({
				table.freeze({
					Socket = "LeftDisplay",
					ItemId = "HollowPurpleBombSkin",
					Mode = "Static",
					PreviewId = "HollowPurpleBombLanePreview",
				}),
				table.freeze({
					Socket = "CenterActor",
					ItemId = "HonoredOneEmote",
					Mode = "Emote",
					PreviewId = "HonoredOneEmoteLanePreview",
					ActorYawDegrees = 0,
				}),
				table.freeze({
					Socket = "RightDisplay",
					ItemId = "InfinityAbility",
					Mode = "AbilityAura",
					PreviewId = "InfinityAuraLanePreview",
				}),
			}),
		}),
	}),
	InfinityAuraLanePreview = table.freeze({
		Id = "InfinityAuraLanePreview",
		Title = "INFINITY",
		TextGradientTemplateId = "Gojo",
		StagePreset = "SingleDisplay",
		Presenter = "AbilityAuraPresenter",
		CameraPreset = "SinglePedastal",
		PreviewMode = "Lane",
		Config = table.freeze({
			Socket = "SinglePedastal",
			LaneCameraPreset = "SinglePedastal",
			AbilityId = "Infinity",
			ActorYawDegrees = 180,
			BubbleScaleMultiplier = 0.18,
		}),
	}),
	HollowPurpleIntroPreview = table.freeze({
		Id = "HollowPurpleIntroPreview",
		Title = "HOLLOW PURPLE INTRO",
		TextGradientTemplateId = "Gojo",
		StagePreset = "FullScreen",
		Presenter = "HighlightIntroPresenter",
		CameraPreset = "Wide",
		PreviewMode = "FullScreen",
		Config = table.freeze({
			CutsceneId = "HollowPurple",
		}),
	}),
	HollowPurpleBombLanePreview = table.freeze({
		Id = "HollowPurpleBombLanePreview",
		Title = "HOLLOW PURPLE",
		TextGradientTemplateId = "Gojo",
		StagePreset = "SingleDisplay",
		Presenter = "StaticModelPresenter",
		CameraPreset = "SinglePedastal",
		PreviewMode = "Lane",
		Config = table.freeze({
			Socket = "SinglePedastal",
			LaneCameraPreset = "SinglePedastal",
			ItemId = "HollowPurpleBombSkin",
			AssetPath = table.freeze({ "Assets", "Bombs", "Hollow Purple", "Default" }),
			Scale = 1.4,
			UsePedestalAttachment = true,
			AttachmentName = "BombOrigin",
			Grounded = false,
			RotationSpeed = 0.55,
		}),
	}),
	HonoredOneEmoteLanePreview = table.freeze({
		Id = "HonoredOneEmoteLanePreview",
		Title = "HONORED ONE",
		TextGradientTemplateId = "Gojo",
		StagePreset = "SingleDisplay",
		Presenter = "EmotePresenter",
		CameraPreset = "SinglePedastal",
		PreviewMode = "Lane",
		Config = table.freeze({
			Socket = "SinglePedastal",
			LaneCameraPreset = "SinglePedastal",
			EmoteId = "Honored One",
			ActorYawDegrees = 180,
		}),
	}),
	FatPackOverview = table.freeze({
		Id = "FatPackOverview",
		Title = "FAT PACK",
		TextGradientTemplateId = "FatYellow",
		StagePreset = "PackOverview",
		Presenter = "BundleOverviewPresenter",
		CameraPreset = "Wide",
		PreviewMode = "Scene",
		Config = table.freeze({
			Slots = table.freeze({
				table.freeze({
					Socket = "LeftDisplay",
					ItemId = "FatBomb",
					Mode = "AbilityCast",
					PreviewId = "FatBombLanePreview",
				}),
				table.freeze({
					Socket = "CenterActor",
					ItemId = "PlayerActor",
					Mode = "IdleActor",
				}),
				table.freeze({
					Socket = "RightDisplay",
					ItemId = "FatGuyBombSkin",
					Mode = "Static",
					PreviewId = "FatGuyLanePreview",
				}),
			}),
		}),
	}),
	FatBombLanePreview = table.freeze({
		Id = "FatBombLanePreview",
		Title = "FAT BOMB",
		TextGradientTemplateId = "FatYellow",
		StagePreset = "EffectArena",
		Presenter = "AbilityCastPresenter",
		CameraPreset = "SinglePedastal",
		PreviewMode = "Lane",
		Config = table.freeze({
			Socket = "SinglePedastal",
			LaneCameraPreset = "SinglePedastal",
			AbilityId = "FatBomb",
			FlareAssetPath = table.freeze({ "Assets", "Abilities", "FatBomb", "Flare" }),
			FallingAssetPath = table.freeze({ "Assets", "Abilities", "FatBomb", "Fat Guy" }),
			ImpactAssetPath = table.freeze({ "Assets", "Abilities", "FatBomb", "FatImpact" }),
			FlareScale = 1,
			ImpactVfxScale = 0.08,
			ImpactHeightOffset = 0,
			LandOnPedestalBase = true,
			FallingPreviewScaleMultiplier = 0.1,
			FallingStartHeight = 6,
			LoopDelay = 4.2,
		}),
	}),
	FatGuyLanePreview = table.freeze({
		Id = "FatGuyLanePreview",
		Title = "FAT GUY",
		TextGradientTemplateId = "FatYellow",
		StagePreset = "SingleDisplay",
		Presenter = "StaticModelPresenter",
		CameraPreset = "SinglePedastal",
		PreviewMode = "Lane",
		Config = table.freeze({
			Socket = "SinglePedastal",
			LaneCameraPreset = "SinglePedastal",
			ItemId = "FatGuyBombSkin",
			AssetPath = table.freeze({ "Assets", "Bombs", "Fat Guy", "Fat Guy" }),
			Scale = 1.5,
			UsePedestalAttachment = true,
			AttachmentName = "BombOrigin",
			Grounded = false,
			RotationSpeed = 0.55,
		}),
	}),
})

local function getEntry(map, id: any)
	if typeof(id) ~= "string" or id == "" then
		return nil
	end
	return map[id]
end

function BundleCatalog.GetCollection(collectionId: any)
	return getEntry(BundleCatalog.Collections, collectionId)
end

function BundleCatalog.GetDefaultCollection()
	return BundleCatalog.GetCollection(BundleCatalog.DefaultCollectionId)
end

function BundleCatalog.GetPage(pageId: any)
	return getEntry(BundleCatalog.Pages, pageId)
end

function BundleCatalog.GetOffer(offerId: any)
	return getEntry(BundleCatalog.Offers, offerId)
end

function BundleCatalog.GetItem(itemId: any)
	return getEntry(BundleCatalog.Items, itemId)
end

function BundleCatalog.GetPreviewRecipe(previewId: any)
	return getEntry(BundleCatalog.PreviewRecipes, previewId)
end

return table.freeze(BundleCatalog)
