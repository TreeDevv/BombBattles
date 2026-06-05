local CountryTimezoneOffsets = {}

CountryTimezoneOffsets.DefaultOffsetMinutes = 0

CountryTimezoneOffsets.Offsets = {
	US = -6 * 60,
	CA = -5 * 60,
	MX = -6 * 60,
	BR = -3 * 60,
	AR = -3 * 60,
	CL = -4 * 60,
	GB = 0,
	IE = 0,
	PT = 0,
	FR = 1 * 60,
	DE = 1 * 60,
	ES = 1 * 60,
	IT = 1 * 60,
	NL = 1 * 60,
	BE = 1 * 60,
	SE = 1 * 60,
	NO = 1 * 60,
	DK = 1 * 60,
	FI = 2 * 60,
	PL = 1 * 60,
	TR = 3 * 60,
	RU = 3 * 60,
	ZA = 2 * 60,
	AE = 4 * 60,
	IN = 5 * 60 + 30,
	CN = 8 * 60,
	HK = 8 * 60,
	SG = 8 * 60,
	MY = 8 * 60,
	PH = 8 * 60,
	ID = 7 * 60,
	TH = 7 * 60,
	VN = 7 * 60,
	JP = 9 * 60,
	KR = 9 * 60,
	AU = 10 * 60,
	NZ = 12 * 60,
}

function CountryTimezoneOffsets.GetOffsetMinutes(countryCode: any): number
	if typeof(countryCode) ~= "string" then
		return CountryTimezoneOffsets.DefaultOffsetMinutes
	end

	local normalized = string.upper(countryCode)
	local offset = CountryTimezoneOffsets.Offsets[normalized]
	if typeof(offset) == "number" then
		return offset
	end

	return CountryTimezoneOffsets.DefaultOffsetMinutes
end

return CountryTimezoneOffsets
