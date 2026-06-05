local WorldTextConstants = require(script.Parent.WorldTextConstants)
local WorldTextEffect = require(script.Parent.WorldTextEffect)

local EventTextPresenter = {}

local KINDS = WorldTextConstants.Kinds
local MAX_ACTIVE = 80

local STYLES = table.freeze({
	throw = table.freeze({
		color = Color3.fromRGB(255, 226, 112),
		lifetime = 0.7,
		offset = Vector3.new(0, 0.6, 0),
		textSize = 18,
	}),
	explosion = table.freeze({
		color = Color3.fromRGB(255, 216, 96),
		lifetime = 0.85,
		offset = Vector3.new(0, 1.5, 0),
		textSize = 22,
	}),
	damage = table.freeze({
		color = Color3.fromRGB(255, 92, 92),
		lifetime = 0.8,
		offset = Vector3.new(0, 1.4, 0),
		textSize = 20,
	}),
	elimination = table.freeze({
		color = Color3.fromRGB(255, 235, 235),
		lifetime = 1.2,
		offset = Vector3.new(0, 2.5, 0),
		textSize = 22,
	}),
	ability = table.freeze({
		color = Color3.fromRGB(150, 235, 255),
		lifetime = 1,
		offset = Vector3.new(0, 2.3, 0),
		textSize = 20,
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

local function getAbilityName(event): string
	if typeof(event) == "table" then
		if typeof(event.abilityName) == "string" and event.abilityName ~= "" then
			return event.abilityName
		end
		if typeof(event.abilityId) == "string" and event.abilityId ~= "" then
			return event.abilityId
		end
	end
	return "ABILITY"
end

local function buildDescriptor(event, options)
	local kind = getEventKind(event)
	local position = getPosition(event, options)
	if not position then
		return nil
	end

	local text = nil
	local style = nil
	if kind == KINDS.BombThrown then
		text = "THROW"
		style = STYLES.throw
	elseif kind == KINDS.BombExploded then
		text = "BOOM"
		style = STYLES.explosion
	elseif kind == KINDS.PlayerDamaged then
		text = if typeof(event) == "table" and isFiniteNumber(event.amount)
			then "-" .. tostring(math.floor(event.amount + 0.5))
			else "HIT"
		style = STYLES.damage
	elseif kind == KINDS.PlayerKilled then
		text = "ELIMINATED"
		style = STYLES.elimination
	elseif kind == KINDS.AbilityUsed then
		text = getAbilityName(event)
		style = STYLES.ability
	else
		return nil
	end

	return {
		text = text,
		position = position + style.offset,
		color = style.color,
		lifetime = style.lifetime,
		textSize = style.textSize,
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
