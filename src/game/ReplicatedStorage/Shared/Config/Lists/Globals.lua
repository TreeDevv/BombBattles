local suffixes = {
	{ 1e15, "Q" },
	{ 1e12, "T" },
	{ 1e9, "B" },
	{ 1e6, "M" },
}

return {
	SCOPE = "Data_1",

	formatNumber = function(n: number, abbreviate: boolean?, cashPrefix: boolean?)
		n = math.round(n)

		local function addCommas(s: string): string
			while true do
				local formatted, count = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2", 1)
				if count == 0 then
					return formatted
				end
				s = formatted
			end
		end

		if abbreviate then
			for _, info in ipairs(suffixes) do
				local value, suffix = info[1], info[2]
				if math.abs(n) >= value then
					local short = n / value
					local text = string.format("%.2f", short):gsub("%.?0+$", "")
					return "$" .. text .. suffix
				end
			end
		end

		local intPart, fracPart = math.modf(n)
		local formatted = addCommas(tostring(intPart))

		if fracPart ~= 0 then
			formatted ..= string.format("%.2f", fracPart):sub(2)
		end

		return (if cashPrefix then "$" else "") .. formatted
	end,

	create = function(className: string, properties: { [string]: any }): Instance
		local instance = Instance.new(className)
		for key, value in pairs(properties) do
			if key ~= "Parent" then
				instance[key] = value
			end
		end
		instance.Parent = properties.Parent or nil
		return instance
	end,

	find = function(t: { [any]: any }, item: any)
		for key, value in pairs(t) do
			if value == item then
				return key
			end
		end
		return nil
	end,
}
