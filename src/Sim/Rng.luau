--!strict
--[[
	Deterministic random numbers for sims and generators (xoshiro128**, seeded with splitmix32).

	Pure integer math on 32-bit words, so a given seed yields the same sequence under lune, in
	Studio, and on live servers. Never use math.random or Random.new in sims or generators.

	  local rng = Rng.new("stilts:balance:v1")
	  rng:next()            -- float in [0, 1)
	  rng:int(1, 6)         -- inclusive
	  rng:fork("player-7")  -- independent child stream

	fork(label) derives from the seed, not from the current position, so adding draws to one
	stream never changes another stream's numbers. This keeps sims comparable across edits.
]]

export type Rng = {
	seed: string,
	nextU32: (self: Rng) -> number,
	next: (self: Rng) -> number,
	range: (self: Rng, min: number, max: number) -> number,
	int: (self: Rng, min: number, max: number) -> number,
	chance: (self: Rng, probability: number) -> boolean,
	pick: <T>(self: Rng, list: { T }) -> T,
	weighted: <K>(self: Rng, weights: { [K]: number }) -> K,
	shuffle: <T>(self: Rng, list: { T }) -> { T },
	normal: (self: Rng, mean: number?, stddev: number?) -> number,
	exponential: (self: Rng, mean: number) -> number,
	jitter: (self: Rng, value: number, fraction: number) -> number,
	fork: (self: Rng, label: string | number) -> Rng,
	clone: (self: Rng) -> Rng,
	getState: (self: Rng) -> { number },
	setState: (self: Rng, state: { number }) -> (),
}

local TWO_32 = 4294967296

local Rng = {}

-- 32-bit multiply modulo 2^32 without losing precision in doubles.
local function imul(a: number, b: number): number
	local aHigh = bit32.rshift(a, 16)
	local aLow = bit32.band(a, 0xFFFF)
	local low = (aLow * b) % TWO_32
	local high = ((aHigh * b) % 65536) * 65536
	return (low + high) % TWO_32
end
Rng.imul = imul

-- FNV-1a over the bytes of a string.
local function hashString(text: string): number
	local hash = 2166136261
	for i = 1, #text do
		hash = imul(bit32.bxor(hash, string.byte(text, i)), 16777619)
	end
	return hash
end
Rng.hashString = hashString

local function splitmix32(state: number): (number, number)
	state = (state + 0x9E3779B9) % TWO_32
	local z = state
	z = imul(bit32.bxor(z, bit32.rshift(z, 16)), 0x85EBCA6B)
	z = imul(bit32.bxor(z, bit32.rshift(z, 13)), 0xC2B2AE35)
	z = bit32.bxor(z, bit32.rshift(z, 16))
	return z, state
end

local function seedText(seed: string | number): string
	if type(seed) == "number" then
		assert(seed == seed and math.abs(seed) ~= math.huge, "Rng seed must be a finite number")
		if seed == math.floor(seed) then
			return string.format("%d", seed)
		end
		return string.format("%.17g", seed)
	end
	return seed
end

function Rng.new(seed: (string | number)?): Rng
	local text = seedText(seed or 0)
	local s0, s1, s2, s3
	local state = hashString(text)
	s0, state = splitmix32(state)
	s1, state = splitmix32(state)
	s2, state = splitmix32(state)
	s3, state = splitmix32(state)
	if s0 == 0 and s1 == 0 and s2 == 0 and s3 == 0 then
		s0 = 1 -- all-zero state is the one invalid xoshiro state
	end

	local self = { seed = text } :: Rng

	function self.nextU32(_self: Rng): number
		local result = imul(bit32.lrotate(imul(s1, 5), 7), 9)
		local t = bit32.lshift(s1, 9)
		s2 = bit32.bxor(s2, s0)
		s3 = bit32.bxor(s3, s1)
		s1 = bit32.bxor(s1, s2)
		s0 = bit32.bxor(s0, s3)
		s2 = bit32.bxor(s2, t)
		s3 = bit32.lrotate(s3, 11)
		return result
	end

	function self.next(r: Rng): number
		-- 53 bits of randomness from two draws: 27 high + 26 low.
		local a = bit32.rshift(r:nextU32(), 5)
		local b = bit32.rshift(r:nextU32(), 6)
		return (a * 67108864 + b) / 9007199254740992
	end

	function self.range(r: Rng, min: number, max: number): number
		return min + (max - min) * r:next()
	end

	function self.int(r: Rng, min: number, max: number): number
		assert(max >= min, "Rng:int expects max >= min")
		return min + math.floor(r:next() * (max - min + 1))
	end

	function self.chance(r: Rng, probability: number): boolean
		return r:next() < probability
	end

	function self.pick<T>(r: Rng, list: { T }): T
		assert(#list > 0, "Rng:pick on an empty list")
		return list[r:int(1, #list)]
	end

	function self.weighted<K>(r: Rng, weights: { [K]: number }): K
		-- Keys are sorted so the result does not depend on table iteration order.
		local keys: { K } = {}
		local total = 0
		for key, weight in weights do
			assert(weight >= 0, "Rng:weighted weights must be non-negative")
			if weight > 0 then
				table.insert(keys, key)
				total += weight
			end
		end
		assert(total > 0, "Rng:weighted needs at least one positive weight")
		table.sort(keys, function(a: any, b: any)
			if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then
				return a < b
			end
			return tostring(a) < tostring(b)
		end)
		local roll = r:next() * total
		for _, key in keys do
			roll -= weights[key]
			if roll < 0 then
				return key
			end
		end
		return keys[#keys]
	end

	function self.shuffle<T>(r: Rng, list: { T }): { T }
		for i = #list, 2, -1 do
			local j = r:int(1, i)
			list[i], list[j] = list[j], list[i]
		end
		return list
	end

	function self.normal(r: Rng, mean: number?, stddev: number?): number
		local u1 = 1 - r:next() -- (0, 1]
		local u2 = r:next()
		local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
		return (mean or 0) + z * (stddev or 1)
	end

	function self.exponential(r: Rng, mean: number): number
		return -mean * math.log(1 - r:next())
	end

	-- value * (1 ± fraction), uniform.
	function self.jitter(r: Rng, value: number, fraction: number): number
		return value * (1 + r:range(-fraction, fraction))
	end

	function self.fork(r: Rng, label: string | number): Rng
		return Rng.new(r.seed .. "/" .. seedText(label))
	end

	function self.getState(_self: Rng): { number }
		return { s0, s1, s2, s3 }
	end

	function self.setState(_self: Rng, state: { number })
		s0, s1, s2, s3 = state[1], state[2], state[3], state[4]
	end

	function self.clone(r: Rng): Rng
		local copy = Rng.new(r.seed)
		copy:setState(r:getState())
		return copy
	end

	return self
end

return Rng
