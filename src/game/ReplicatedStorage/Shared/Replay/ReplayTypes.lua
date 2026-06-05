local ReplayTypes = {}

--[[
ReplayFrame
Expected shape for one sampled server frame:
{
	timestamp: number,
	roundId: number?,
	players: {
		[tostring(userId)]: {
			userId: number,
			position: Vector3,
			cframe: CFrame?,
			health: number,
			maxHealth: number,
			alive: boolean,
			teamName: string?,
			camera: {
				sampleTime: number?,
				cframe: CFrame,
				focus: CFrame?,
				fieldOfView: number?,
			}?,
			pose: {
				sampleTime: number?,
				joints: {
					{
						name: string,
						part0: string?,
						part1: string?,
						key: string?,
						transform: CFrame,
					},
				},
			}?,
			animationState: {
				grounded: boolean?,
				sprinting: boolean?,
				crouching: boolean?,
				sliding: boolean?,
				effectiveSpeed: number?,
				moveMagnitude: number?,
				jumpSerial: number?,
				lastJumpKind: string?,
				shiftLocked: boolean?,
				linearVelocity: Vector3?,
				bombCooking: boolean?,
				bombCookStartedAt: number?,
			}?,
		},
	},
	bombs: {
		[projectileId]: {
			bombId: string,
			ownerUserId: number?,
			position: Vector3,
			velocity: Vector3?,
			bombType: string?,
			fuseStartedAt: number?,
			fuseEndsAt: number?,
			sizeScale: number?,
		},
	},
}

ReplayEvent
Expected shape for discrete gameplay events:
{
	timestamp: number,
	roundId: number?,
	eventType: string,
	sourceUserId: number?,
	targetUserId: number?,
	projectileId: string?,
	sourceType: string?,
	sourceId: string?,
	source: string?,
	bombId: string?,
	bombType: string?,
	position: Vector3?,
	innerRadius: number?,
	outerRadius: number?,
	terrainRadius: number?,
	radius: number?,
	amount: number?,
	metadata: { [string]: any }?,
}

ReplayDestructionEvent
Expected shape for replay map reconstruction:
{
	timestamp: number,
	roundId: number?,
	sequence: number?,
	position: Vector3,
	radius: number,
	sourceType: string?,
	sourceId: string?,
	bombId: string?,
	ownerUserId: number?,
	debrisPayloads: {
		{
			sourceCFrame: CFrame,
			explosionPosition: Vector3,
			blocks: { { center: Vector3, size: Vector3 } },
			materialName: string?,
			color: Color3?,
			transparency: number?,
			reflectance: number?,
			speedMin: number?,
			speedMax: number?,
			lifetime: number?,
			useGraphicsQualitySampling: boolean?,
			automaticQualityLevel: number?,
			maxSamplingDivisor: number?,
			seed: number?,
		},
	}?,
}

ReplayClip
Expected shape for replay playback payloads:
{
	clipId: string,
	roundId: number?,
	mapId: string?,
	mapPivot: CFrame?,
	startedAt: number,
	endedAt: number,
	frames: { ReplayFrame },
	events: { ReplayEvent },
	destructionEvents: { ReplayDestructionEvent }?,
	focusUserId: number?,
	sourceEventId: string?,
}

POTGCandidate
Expected shape for highlight scoring:
{
	candidateId: string,
	roundId: number?,
	playerUserId: number,
	score: number,
	startedAt: number,
	endedAt: number,
	reasons: { string },
	sourceEvents: { ReplayEvent },
}
]]

return ReplayTypes
