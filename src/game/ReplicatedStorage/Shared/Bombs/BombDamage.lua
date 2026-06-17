local BombConfig = require(script.Parent.Parent.Config.BombConfig)

local BombDamage = {}

local function readNumber(source, key: string, fallback: number, minimum: number?): number
	local value = if typeof(source) == "table" then source[key] else nil
	if typeof(value) ~= "number" or value ~= value then
		value = fallback
	end
	if typeof(minimum) == "number" then
		value = math.max(value, minimum)
	end
	return value
end

function BombDamage.CalculateFalloffDamage(
	distance: number,
	innerRadius: number,
	nearRadius: number,
	outerRadius: number,
	directDamage: number,
	nearMax: number,
	nearMin: number,
	outerMax: number,
	outerMin: number
): number
	distance = if typeof(distance) == "number" and distance == distance then math.max(distance, 0) else math.huge
	innerRadius = math.max(innerRadius, 0.001)
	nearRadius = math.max(nearRadius, innerRadius + 0.001)
	outerRadius = math.max(outerRadius, nearRadius + 0.001)

	if distance <= innerRadius then
		return directDamage
	end
	if distance <= nearRadius then
		local alpha = (distance - innerRadius) / math.max(nearRadius - innerRadius, 0.001)
		return nearMax + (nearMin - nearMax) * alpha
	end
	if distance <= outerRadius then
		local alpha = (distance - nearRadius) / math.max(outerRadius - nearRadius, 0.001)
		return outerMax + (outerMin - outerMax) * alpha
	end

	return 0
end

function BombDamage.GetPlayerDamageForDistance(distance: number, explosionConfig): number
	return BombDamage.CalculateFalloffDamage(
		distance,
		readNumber(explosionConfig, "innerRadius", BombConfig.InnerRadius, 0.001),
		readNumber(explosionConfig, "nearRadius", BombConfig.NearRadius, 0.001),
		readNumber(explosionConfig, "outerRadius", BombConfig.OuterRadius, 0.001),
		readNumber(explosionConfig, "playerDirectDamage", BombConfig.PlayerDirectDamage, 0),
		readNumber(explosionConfig, "playerNearDamageMax", BombConfig.PlayerNearDamageMax, 0),
		readNumber(explosionConfig, "playerNearDamageMin", BombConfig.PlayerNearDamageMin, 0),
		readNumber(explosionConfig, "playerOuterDamageMax", BombConfig.PlayerOuterDamageMax, 0),
		readNumber(explosionConfig, "playerOuterDamageMin", BombConfig.PlayerOuterDamageMin, 0)
	)
end

function BombDamage.GetAnchorDamageForDistance(distance: number, explosionConfig): number
	return BombDamage.CalculateFalloffDamage(
		distance,
		readNumber(explosionConfig, "innerRadius", BombConfig.InnerRadius, 0.001),
		readNumber(explosionConfig, "nearRadius", BombConfig.NearRadius, 0.001),
		readNumber(explosionConfig, "outerRadius", BombConfig.OuterRadius, 0.001),
		readNumber(explosionConfig, "anchorDirectDamage", BombConfig.AnchorDirectDamage, 0),
		readNumber(explosionConfig, "anchorNearDamageMax", BombConfig.AnchorNearDamageMax, 0),
		readNumber(explosionConfig, "anchorNearDamageMin", BombConfig.AnchorNearDamageMin, 0),
		readNumber(explosionConfig, "anchorOuterDamageMax", BombConfig.AnchorOuterDamageMax, 0),
		readNumber(explosionConfig, "anchorOuterDamageMin", BombConfig.AnchorOuterDamageMin, 0)
	)
end

return table.freeze(BombDamage)
