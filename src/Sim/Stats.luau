--!strict
--[[
	Summary statistics for sim outputs. Percentiles use linear interpolation between closest
	ranks (same as numpy's default), on a sorted copy; inputs are never mutated.
]]

export type Summary = {
	count: number,
	mean: number,
	stddev: number,
	min: number,
	p10: number,
	p25: number,
	p50: number,
	p75: number,
	p90: number,
	max: number,
}

local Stats = {}

local function sorted(values: { number }): { number }
	local copy = table.clone(values)
	table.sort(copy)
	return copy
end

function Stats.sum(values: { number }): number
	local total = 0
	for _, v in values do
		total += v
	end
	return total
end

function Stats.mean(values: { number }): number
	if #values == 0 then
		return 0 / 0
	end
	return Stats.sum(values) / #values
end

-- Sample standard deviation (n - 1). 0 for fewer than two values.
function Stats.stddev(values: { number }): number
	local n = #values
	if n < 2 then
		return 0
	end
	local mean = Stats.mean(values)
	local acc = 0
	for _, v in values do
		acc += (v - mean) ^ 2
	end
	return math.sqrt(acc / (n - 1))
end

local function percentileSorted(s: { number }, p: number): number
	local n = #s
	if n == 0 then
		return 0 / 0
	end
	if n == 1 then
		return s[1]
	end
	local rank = math.clamp(p, 0, 100) / 100 * (n - 1) + 1
	local lower = math.floor(rank)
	local frac = rank - lower
	if lower >= n then
		return s[n]
	end
	return s[lower] + (s[lower + 1] - s[lower]) * frac
end

-- p in [0, 100].
function Stats.percentile(values: { number }, p: number): number
	return percentileSorted(sorted(values), p)
end

function Stats.median(values: { number }): number
	return Stats.percentile(values, 50)
end

function Stats.summarize(values: { number }): Summary
	local s = sorted(values)
	return {
		count = #s,
		mean = Stats.mean(s),
		stddev = Stats.stddev(s),
		min = if #s > 0 then s[1] else 0 / 0,
		p10 = percentileSorted(s, 10),
		p25 = percentileSorted(s, 25),
		p50 = percentileSorted(s, 50),
		p75 = percentileSorted(s, 75),
		p90 = percentileSorted(s, 90),
		max = if #s > 0 then s[#s] else 0 / 0,
	}
end

-- Counts values into buckets [edges[i], edges[i+1]); values outside go to the first/last bucket.
function Stats.histogram(values: { number }, edges: { number }): { number }
	assert(#edges >= 2, "histogram needs at least two edges")
	local counts = table.create(#edges - 1, 0)
	for _, v in values do
		local index = #edges - 1
		for i = 1, #edges - 1 do
			if v < edges[i + 1] then
				index = i
				break
			end
		end
		counts[index] += 1
	end
	return counts
end

-- Share of each key in a { [key]: amount } table, as fractions summing to 1.
function Stats.shares(amounts: { [string]: number }): { [string]: number }
	local total = 0
	for _, v in amounts do
		total += v
	end
	local out = {}
	for key, v in amounts do
		out[key] = if total > 0 then v / total else 0
	end
	return out
end

-- Groups values by a key function, e.g. by skill profile.
function Stats.groupBy<T>(items: { T }, key: (T) -> string, value: (T) -> number?): { [string]: { number } }
	local groups: { [string]: { number } } = {}
	for _, item in items do
		local v = value(item)
		if v ~= nil then
			local k = key(item)
			local list = groups[k]
			if not list then
				list = {}
				groups[k] = list
			end
			table.insert(list, v)
		end
	end
	return groups
end

return Stats
