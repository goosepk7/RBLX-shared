--!strict
--[[
	Economy.Multipliers: how multiplier sources combine (pure).

	Sources in the same group add their bonuses, groups multiply:
	  rebirth +50% (1.5) and +25% (1.25) -> rebirth group 1.75
	  pass 2x (2) and VIP +25% (1.25)    -> pass group 2.25
	  total = 1.75 x 2.25 x event x boost ...
	A group listed in `multiplyWithin` multiplies its own sources instead (2 and 2 make 4). A factor
	below 1 is a penalty (0.5 takes half off its group); no group goes below 0. The total is capped
	at `maxMultiplier`.
]]

local Types = require("../Types")

export type Spec = Types.MultiplierSpec

local Multipliers = {}

local function listed(list: { string }?, value: string): boolean
	if list == nil then
		return true
	end
	return table.find(list, value) ~= nil
end

-- Whether `spec` applies to an earn of `currency` for `reason` at unix time `now`.
function Multipliers.applies(spec: Spec, currency: string, reason: string, now: number): boolean
	if spec.expiresAt ~= nil and now >= spec.expiresAt then
		return false
	end
	return listed(spec.currencies, currency) and listed(spec.reasons, reason)
end

local function isStringList(list: any): boolean
	if type(list) ~= "table" then
		return false
	end
	for key, value in list do
		if type(key) ~= "number" or type(value) ~= "string" then
			return false
		end
	end
	return true
end

-- Checks a spec from game code. The error describes the problem.
function Multipliers.validate(spec: any): (boolean, string?)
	if type(spec) ~= "table" then
		return false, "a multiplier must be a table"
	end
	if type(spec.group) ~= "string" or spec.group == "" then
		return false, 'a multiplier needs a group (e.g. "pass")'
	end
	local factor = spec.factor
	if type(factor) ~= "number" or factor ~= factor or factor <= 0 or factor == math.huge then
		return false, "a multiplier's factor must be a number greater than 0"
	end
	for _, field in { "currencies", "reasons" } do
		local list = spec[field]
		if list ~= nil and not isStringList(list) then
			return false, "a multiplier's " .. field .. " must be a list of names"
		end
	end
	local expiresAt = spec.expiresAt
	if expiresAt ~= nil and (type(expiresAt) ~= "number" or expiresAt ~= expiresAt) then
		return false, "a multiplier's expiresAt must be a unix time"
	end
	return true, nil
end

--[[
	Combines every spec in `sources` (any number of lists) that applies. Returns the total, capped
	at `maxMultiplier`, and the factor of each group that contributed.
]]
function Multipliers.combine(
	sources: { { Spec } },
	currency: string,
	reason: string,
	now: number,
	multiplyWithin: { [string]: boolean },
	maxMultiplier: number
): (number, { [string]: number })
	local groups: { [string]: number } = {}
	for _, list in sources do
		for _, spec in list do
			if Multipliers.applies(spec, currency, reason, now) then
				local current = groups[spec.group]
				if multiplyWithin[spec.group] then
					groups[spec.group] = (current or 1) * spec.factor
				else
					groups[spec.group] = (current or 1) + (spec.factor - 1)
				end
			end
		end
	end
	local total = 1
	for group, factor in groups do
		local clamped = math.max(factor, 0)
		groups[group] = clamped
		total *= clamped
	end
	return math.min(total, maxMultiplier), groups
end

return Multipliers
