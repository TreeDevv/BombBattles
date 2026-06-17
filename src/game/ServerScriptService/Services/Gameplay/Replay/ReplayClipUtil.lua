local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ReplayClipPolicy = require(ReplicatedStorage.Shared.Replay.ReplayClipPolicy)

local ReplayClipUtil = {}

function ReplayClipUtil.GetKillClipCaps()
	return ReplayClipPolicy.GetKillClipCaps()
end

function ReplayClipUtil.GetPOTGClipCaps()
	return ReplayClipPolicy.GetPOTGClipCaps()
end

function ReplayClipUtil.EstimateClipPayloadSize(clip)
	return ReplayClipPolicy.EstimateClipPayloadSize(clip)
end

function ReplayClipUtil.IsClipWithinCaps(clip, minFrames: number, caps): boolean
	return ReplayClipPolicy.IsClipWithinCaps(clip, minFrames, caps)
end

return ReplayClipUtil
