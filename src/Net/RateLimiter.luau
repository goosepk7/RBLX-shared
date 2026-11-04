--!strict
--[[
	Token-bucket rate limiter keyed by player (or any key).

	  local limiter = RateLimiter.new({ rate = 5, burst = 10 }, os.clock)
	  if limiter:allow(player) then ... end

	`rate` tokens are added per second up to `burst`; each call spends `cost` (default 1). A new
	key starts full, so a player can always send `burst` requests immediately.
]]

export type RateLimit = {
	-- Sustained requests per second.
	rate: number,
	-- Bucket size: requests allowed back to back.
	burst: number,
}

export type RateLimiter = {
	limit: RateLimit,
	allow: (self: RateLimiter, key: any, cost: number?) -> boolean,
	-- Tokens currently available for a key (after refill).
	available: (self: RateLimiter, key: any) -> number,
	remove: (self: RateLimiter, key: any) -> (),
	clear: (self: RateLimiter) -> (),
}

type Bucket = { tokens: number, last: number }

local RateLimiter = {}

function RateLimiter.validate(limit: RateLimit)
	assert(type(limit) == "table", "rate limit must be a table { rate, burst }")
	assert(type(limit.rate) == "number" and limit.rate > 0 and limit.rate < math.huge, "rate limit: rate must be > 0")
	assert(
		type(limit.burst) == "number" and limit.burst >= 1 and limit.burst < math.huge,
		"rate limit: burst must be >= 1"
	)
end

function RateLimiter.new(limit: RateLimit, clock: () -> number): RateLimiter
	RateLimiter.validate(limit)
	local rate, burst = limit.rate, limit.burst
	local buckets: { [any]: Bucket } = {}

	local function refill(key: any): Bucket
		local now = clock()
		local bucket = buckets[key]
		if bucket == nil then
			bucket = { tokens = burst, last = now }
			buckets[key] = bucket
			return bucket
		end
		local elapsed = now - bucket.last
		if elapsed > 0 then
			bucket.tokens = math.min(burst, bucket.tokens + elapsed * rate)
			bucket.last = now
		end
		return bucket
	end

	local limiter = { limit = table.freeze({ rate = rate, burst = burst }) } :: RateLimiter

	function limiter.allow(_self: RateLimiter, key: any, cost: number?): boolean
		local spend = cost or 1
		local bucket = refill(key)
		if bucket.tokens >= spend then
			bucket.tokens -= spend
			return true
		end
		return false
	end

	function limiter.available(_self: RateLimiter, key: any): number
		return refill(key).tokens
	end

	function limiter.remove(_self: RateLimiter, key: any)
		buckets[key] = nil
	end

	function limiter.clear(_self: RateLimiter)
		table.clear(buckets)
	end

	return limiter
end

return RateLimiter
