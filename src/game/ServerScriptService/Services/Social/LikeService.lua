local HttpService = game:GetService("HttpService")

local PROXY_URL = "https://like-proxy.hpaulbus.workers.dev"
local TOKEN = "K4HmA_xvQIBGzvUKi19Un__TPJ48qfBjGRPSUACgQUg"
local CACHE_TTL_SECONDS = 8

local LikeService = {}
local cachedLikes: number? = nil
local cachedAt = 0
local inFlightRequest: BindableEvent? = nil
local inFlightLikes: number? = nil
local inFlightError: string? = nil

local function sanitizeInteger(value: any): number
	local numberValue = tonumber(value) or 0
	if numberValue ~= numberValue or numberValue == math.huge or numberValue == -math.huge then
		return 0
	end

	return math.max(0, math.floor(numberValue + 0.5))
end

local function decodeLikePayload(responseBody: string): number?
	local decoded = HttpService:JSONDecode(responseBody)
	if typeof(decoded) ~= "table" then
		return nil
	end

	local likes = decoded.likes
	if tonumber(likes) == nil then
		return nil
	end

	return sanitizeInteger(likes)
end

local function isCacheFresh(): boolean
	return cachedLikes ~= nil and os.clock() - cachedAt < CACHE_TTL_SECONDS
end

local function requestLikesFromProxy(): (number?, string?)
	local success, response = pcall(function()
		return HttpService:RequestAsync({
			Url = PROXY_URL,
			Method = "GET",
			Headers = {
				Authorization = "Bearer " .. TOKEN,
			},
		})
	end)
	if not success then
		return nil, tostring(response)
	end

	if typeof(response) ~= "table" then
		return nil, "RequestAsync returned an invalid response"
	end

	if not response.Success then
		local statusCode = tonumber(response.StatusCode) or 0
		local statusMessage = tostring(response.StatusMessage or "HTTP request failed")
		return nil, ("%d %s"):format(statusCode, statusMessage)
	end

	local decodeSuccess, likes = pcall(function()
		return decodeLikePayload(tostring(response.Body or ""))
	end)
	if not decodeSuccess then
		return nil, tostring(likes)
	end
	if likes == nil then
		return nil, "Response did not include likes"
	end

	return likes, nil
end

function LikeService.FetchLikes(): (number?, string?)
	if isCacheFresh() then
		return cachedLikes, nil
	end

	local activeRequest = inFlightRequest
	if activeRequest then
		activeRequest.Event:Wait()
		if isCacheFresh() then
			return cachedLikes, nil
		end
		return inFlightLikes, inFlightError
	end

	local requestCompleted = Instance.new("BindableEvent")
	inFlightRequest = requestCompleted
	inFlightLikes = nil
	inFlightError = nil

	local likes, err = requestLikesFromProxy()
	if likes ~= nil then
		cachedLikes = likes
		cachedAt = os.clock()
	end

	inFlightLikes = likes
	inFlightError = err
	inFlightRequest = nil
	requestCompleted:Fire()
	requestCompleted:Destroy()

	return likes, err
end

return LikeService
