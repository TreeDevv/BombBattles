local RoundEndFlowConfig = {
	Remotes = table.freeze({
		POTGIntro = "RoundPOTGIntro",
		POTGIntroComplete = "RoundPOTGIntroComplete",
	}),

	CutsceneModes = table.freeze({
		FullAnimation = "FullAnimation",
	}),

	DefaultPOTGIntroCutsceneId = "TooFast",
	POTGAttachmentName = "HighlightIntroPoint",
	WinnerBeatSeconds = 1.5,
	ResultsSeconds = 8,
	POTGIntroLeadInSeconds = 2,
	POTGIntroClientTimeoutSeconds = 6,
}

return table.freeze(RoundEndFlowConfig)
