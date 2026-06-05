local ReplayConstants = {}

ReplayConstants.BUFFER_SECONDS = 12
ReplayConstants.SAMPLE_RATE = 15
ReplayConstants.SAMPLE_INTERVAL = 1 / ReplayConstants.SAMPLE_RATE

ReplayConstants.KILL_REPLAY_PRE_SECONDS = 4
ReplayConstants.KILL_REPLAY_POST_SECONDS = 1

ReplayConstants.POTG_PRE_SECONDS = 6
ReplayConstants.POTG_POST_SECONDS = 3

ReplayConstants.MAX_REPLAY_PLAYERS = 16
ReplayConstants.MAX_REPLAY_BOMBS = 64

ReplayConstants.REMOTES_FOLDER_NAME = "Remotes"
ReplayConstants.REMOTES = table.freeze({
	KillReplay = "ReplayKillReplay",
	KillReplayRequest = "ReplayKillReplayRequest",
	PlayOfTheGame = "ReplayPlayOfTheGame",
	Cancel = "ReplayCancel",
	Debug = "ReplayDebug",
	AnimationState = "ReplayAnimationState",
})

return table.freeze(ReplayConstants)
