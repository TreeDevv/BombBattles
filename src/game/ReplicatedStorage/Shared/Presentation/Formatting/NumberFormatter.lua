local NumberFormatter = {}

local SUFFIXES = {
	{ value = 1e90, suffix = "TG" },
	{ value = 1e87, suffix = "NV" },
	{ value = 1e84, suffix = "OV" },
	{ value = 1e81, suffix = "SPV" },
	{ value = 1e78, suffix = "SXV" },
	{ value = 1e75, suffix = "PV" },
	{ value = 1e72, suffix = "QV" },
	{ value = 1e69, suffix = "TV" },
	{ value = 1e66, suffix = "DV" },
	{ value = 1e63, suffix = "UV" },
	{ value = 1e60, suffix = "VG" },
	{ value = 1e57, suffix = "ND" },
	{ value = 1e54, suffix = "OD" },
	{ value = 1e51, suffix = "SP" },
	{ value = 1e48, suffix = "SX" },
	{ value = 1e45, suffix = "QN" },
	{ value = 1e42, suffix = "QD" },
	{ value = 1e39, suffix = "TD" },
	{ value = 1e36, suffix = "DD" },
	{ value = 1e33, suffix = "UD" },
	{ value = 1e30, suffix = "DE" },
	{ value = 1e27, suffix = "NO" },
	{ value = 1e24, suffix = "OT" },
	{ value = 1e21, suffix = "ST" },
	{ value = 1e18, suffix = "QT" },
	{ value = 1e15, suffix = "QD" },
	{ value = 1e12, suffix = "T" },
	{ value = 1e9, suffix = "B" },
	{ value = 1e6, suffix = "M" },
	{ value = 1e3, suffix = "K" },
}

function NumberFormatter.Format(n: number): string
	local negative = n < 0
	n = math.abs(n)

	for _, entry in ipairs(SUFFIXES) do
		if n >= entry.value then
			local short = n / entry.value
			local formatted = if short % 1 == 0 then ("%d"):format(short) else ("%.1f"):format(short)
			return (if negative then "-" else "") .. formatted .. entry.suffix
		end
	end

	return (if negative then "-" else "") .. tostring(math.floor(n + 0.5))
end

return NumberFormatter
