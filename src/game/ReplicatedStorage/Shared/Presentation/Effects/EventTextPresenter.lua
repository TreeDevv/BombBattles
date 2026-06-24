local WorldTextConstants = require(script.Parent.WorldTextConstants)
local WorldTextEffect = require(script.Parent.WorldTextEffect)

local EventTextPresenter = {}

local KINDS = WorldTextConstants.Kinds
local MAX_ACTIVE = 80
local DAMAGE_TEMPLATE_NAME = "DamageNumber"
local DAMAGE_COALESCE_SECONDS = 0.1
local random = Random.new()
local pendingDamage = {}

local TEXT_WHIPS = table.freeze({
	kill = table.freeze({ "ELIMINATED", "KO" }),
})

local STYLES = table.freeze({
	elimination = table.freeze({
		lifetime = 1.2,
		offset = Vector3.new(0, 2.5, 0),
	}),
	damageLight = table.freeze({
		lifetime = 0.78,
		offset = Vector3.new(0, 2.35, 0),
		lift = Vector3.new(0, 2.15, 0),
		sizeScale = 0.86,
		textColor = Color3.fromRGB(255, 214, 184),
		strokeColor = Color3.fromRGB(99, 39, 31),
	}),
	damageMedium = table.freeze({
		lifetime = 0.84,
		offset = Vector3.new(0, 2.45, 0),
		lift = Vector3.new(0, 2.35, 0),
		sizeScale = 1,
		textColor = Color3.fromRGB(255, 232, 204),
		strokeColor = Color3.fromRGB(111, 44, 31),
	}),
	damageHeavy = table.freeze({
		lifetime = 0.9,
		offset = Vector3.new(0, 2.6, 0),
		lift = Vector3.new(0, 2.6, 0),
		sizeScale = 1.16,
		textColor = Color3.fromRGB(255, 238, 134),
		strokeColor = Color3.fromRGB(116, 46, 21),
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

local function getDamageAmount(event): number?
	if typeof(event) ~= "table" or not isFiniteNumber(event.amount) or event.amount <= 0 then
		return nil
	end
	return event.amount
end

local function getDamageStyle(amount: number)
	if amount >= 85 then
		return STYLES.damageHeavy
	end
	if amount >= 45 then
		return STYLES.damageMedium
	end
	return STYLES.damageLight
end

local function getDamageText(amount: number): string
	return tostring(math.max(1, math.floor(amount + 0.5)))
end

local function getDamageJitter(): Vector3
	return Vector3.new(random:NextNumber(-0.35, 0.35), random:NextNumber(-0.08, 0.08), 0)
end

local function buildDamageDescriptor(event, position: Vector3)
	local amount = getDamageAmount(event)
	if not amount then
		return nil
	end

	local style = getDamageStyle(amount)
	return {
		templateName = DAMAGE_TEMPLATE_NAME,
		position = position + style.offset + getDamageJitter(),
		lifetime = style.lifetime,
		lift = style.lift,
		maxActive = MAX_ACTIVE,
		maxDistance = 180,
		text = getDamageText(amount),
		textLabelName = "Value",
		textColor = style.textColor,
		textStrokeColor = style.strokeColor,
		textStrokeTransparency = 0.08,
		strokeColor = style.strokeColor,
		strokeTransparency = 0.1,
		sizeScale = style.sizeScale,
	}
end

local function getDamageCoalesceKey(event): string?
	if typeof(event) ~= "table" then
		return nil
	end
	if isFiniteNumber(event.victimUserId) then
		return "victim:" .. tostring(math.floor(event.victimUserId))
	end
	return nil
end

local function playLiveDamageEvent(parent: Instance, payload)
	local position = getPosition(payload, nil)
	local amount = getDamageAmount(payload)
	if not (position and amount) then
		return nil
	end

	local key = getDamageCoalesceKey(payload)
	if not key then
		return WorldTextEffect.Play(parent, buildDamageDescriptor(payload, position))
	end

	local record = pendingDamage[key]
	if record then
		record.amount += amount
		record.position = position
		record.payload.amount = record.amount
		record.payload.position = position
		return nil
	end

	record = {
		parent = parent,
		position = position,
		amount = amount,
		payload = table.clone(payload),
	}
	pendingDamage[key] = record

	task.delay(DAMAGE_COALESCE_SECONDS, function()
		local pending = pendingDamage[key]
		if pending ~= record then
			return
		end
		pendingDamage[key] = nil
		if not (pending.parent and pending.parent.Parent) then
			return
		end
		WorldTextEffect.Play(pending.parent, buildDamageDescriptor(pending.payload, pending.position))
	end)

	return nil
end

local function buildDescriptor(event, options)
	local kind = getEventKind(event)
	local position = getPosition(event, options)
	if not position then
		return nil
	end

	local templateName = nil
	local style = nil
	if kind == KINDS.PlayerKilled then
		templateName = chooseVariant(TEXT_WHIPS.kill)
		style = STYLES.elimination
	elseif kind == KINDS.PlayerDamaged then
		return buildDamageDescriptor(event, position)
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
	if getEventKind(payload) == KINDS.PlayerDamaged then
		return playLiveDamageEvent(parent, payload)
	end

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
