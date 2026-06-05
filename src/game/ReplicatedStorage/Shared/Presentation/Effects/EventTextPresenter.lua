local WorldTextConstants = require(script.Parent.WorldTextConstants)
local WorldTextEffect = require(script.Parent.WorldTextEffect)

local EventTextPresenter = {}

local KINDS = WorldTextConstants.Kinds
local MAX_ACTIVE = 80
local random = Random.new()

local TEXT_WHIPS = table.freeze({
	kill = table.freeze({ "ELIMINATED", "KO" }),
	explosion = table.freeze({ "POW", "BAM", "WHAM", "KAPOW", "BANG" }),
})

local STYLES = table.freeze({
	explosion = table.freeze({
		lifetime = 1,
		offset = Vector3.new(0, 1.5, 0),
	}),
	elimination = table.freeze({
		lifetime = 1.2,
		offset = Vector3.new(0, 2.5, 0),
	}),
})

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteVector3(value: any): boolean
	return typeof(value) == "Vector3"
		and isFiniteNumber(value.X)
		and isFiniteNumber(value.Y)
		and isFiniteNumber(value.Z)
end

local function getEventKind(event): string?
	if typeof(event) ~= "table" then
		return nil
	end
	local kind = event.kind or event.eventType
	return if typeof(kind) == "string" and kind ~= "" then kind else nil
end

local function getPosition(event, options): Vector3?
	if typeof(options) == "table" and isFiniteVector3(options.position) then
		return options.position
	end
	if typeof(event) == "table" and isFiniteVector3(event.position) then
		return event.position
	end
	return nil
end

local function chooseVariant(variants: { string }): string?
	local count = #variants
	if count <= 0 then
		return nil
	end
	return variants[random:NextInteger(1, count)]
end

local function buildDescriptor(event, options)
	local kind = getEventKind(event)
	local position = getPosition(event, options)
	if not position then
		return nil
	end

	local templateName = nil
	local style = nil
	if kind == KINDS.BombExploded then
		templateName = chooseVariant(TEXT_WHIPS.explosion)
		style = STYLES.explosion
	elseif kind == KINDS.PlayerKilled then
		templateName = chooseVariant(TEXT_WHIPS.kill)
		style = STYLES.elimination
	else
		return nil
	end

	if not templateName or not style then
		return nil
	end

	return {
		templateName = templateName,
		position = position + style.offset,
		lifetime = style.lifetime,
		maxActive = MAX_ACTIVE,
	}
end

function EventTextPresenter.BuildLiveDescriptor(payload)
	return buildDescriptor(payload, nil)
end

function EventTextPresenter.BuildReplayDescriptor(event, options)
	return buildDescriptor(event, options)
end

function EventTextPresenter.PlayDescriptor(parent: Instance, descriptor)
	return WorldTextEffect.Play(parent, descriptor)
end

function EventTextPresenter.PlayLiveEvent(parent: Instance, payload)
	local descriptor = EventTextPresenter.BuildLiveDescriptor(payload)
	if descriptor then
		return EventTextPresenter.PlayDescriptor(parent, descriptor)
	end
	return nil
end

function EventTextPresenter.PlayReplayEvent(parent: Instance, event, options)
	local descriptor = EventTextPresenter.BuildReplayDescriptor(event, options)
	if descriptor then
		return EventTextPresenter.PlayDescriptor(parent, descriptor)
	end
	return nil
end

return EventTextPresenter
