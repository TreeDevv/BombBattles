local RoundEndFlowConfig = {
	Remotes = table.freeze({
		POTGIntro = "RoundPOTGIntro",
		POTGIntroComplete = "RoundPOTGIntroComplete",
	}),

	CutsceneModes = table.freeze({
		FullAnimation = "FullAnimation",
	}),

	POTGAttachmentName = "HighlightIntroPoint",
	WinnerBeatSeconds = 1.5,
	ResultsSeconds = 8,
	POTGIntroMaxSeconds = 60,
}

return table.freeze(RoundEndFlowConfig)
