--!strict
--[[
	Data.Retry: calls a yielding DataStore operation with exponential backoff.

	  local ok, result = Retry.call(function()
	  	return store:UpdateAsync(key, transform)
	  end, { attempts = 5, baseDelay = 1, wait = task.wait })

	Errors that retrying can't fix (bad key, unstorable value, value too large, no API access)
	stop at once. Everything else (throttling, 5xx, network) is retried after 1, 2, 4, ...
	seconds, capped at `maxDelay`.
]]

export type Options = {
	-- Total tries, including the first. Default 5.
	attempts: number?,
	-- Seconds before the first retry; doubles each time. Default 1.
	baseDelay: number?,
	-- Longest pause between tries. Default 16.
	maxDelay: number?,
	-- Yields for the given seconds (task.wait, or a Test.Clock's clock.task.wait).
	wait: (seconds: number) -> any,
	-- Called before each retry, for logging and diagnostics.
	onRetry: ((attempt: number, err: string, delay: number) -> ())?,
}

local Retry = {}

-- Leading numeric code of a Roblox DataStore error ("502: API Services rejected ..."), if any.
function Retry.errorCode(err: string): number?
	local code = string.match(err, "^%s*(%d%d%d):")
	return if code then tonumber(code) else nil
end

--[[
	1xx are request errors (bad key, unstorable or oversized value), 4xx are access errors (for
	example Studio without API access, or a server that is shutting down), and 511-513 are
	metadata and user ID errors. None of these change on a retry. 3xx (throttled), other 5xx and
	uncoded errors are worth retrying.
]]
function Retry.isRetryable(err: string): boolean
	local code = Retry.errorCode(err)
	if code == nil then
		return true
	end
	if code < 200 or (code >= 400 and code < 500) or (code >= 511 and code <= 513) then
		return false
	end
	return true
end

-- Returns (true, results...) on success, or (false, lastError).
function Retry.call(fn: () -> ...any, options: Options): (boolean, ...any)
	local attempts = options.attempts or 5
	local delay = options.baseDelay or 1
	local maxDelay = options.maxDelay or 16
	local attempt = 0
	while true do
		attempt += 1
		local packed = table.pack(pcall(fn))
		if packed[1] then
			return table.unpack(packed, 1, packed.n)
		end
		local err = tostring(packed[2])
		if attempt >= attempts or not Retry.isRetryable(err) then
			return false, err
		end
		local pause = math.min(delay, maxDelay)
		local onRetry = options.onRetry
		if onRetry then
			onRetry(attempt, err, pause)
		end
		options.wait(pause)
		delay *= 2
	end
end

return Retry
