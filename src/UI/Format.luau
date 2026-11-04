--!strict
--[[
	Number formatting for UI surfaces (pills, stats, number pops).

	Loc wraps these for locale separators (`loc:compact`, `loc:grouped`). The
	kit shows numbers through `Format.show*`, which pass the English text
	through the localizer that `loc:bindKit()` installs, so pills, stats,
	badges and number pops follow the player's language ("1,2K" in pt-br).
]]

local Format = {}

local localizer: ((string) -> string)? = nil

--- Installs (or with nil removes) the function that turns Format's English
--- separators into the active locale's. Loc's `bindKit` calls this.
function Format.setLocalizer(fn: ((string) -> string)?)
	localizer = fn
end

function Format.localize(text: string): string
	local fn = localizer
	return if fn then fn(text) else text
end

local SUFFIXES = { "K", "M", "B", "T", "Qa", "Qi" }

local function trim(s: string): string
	-- "1.0" -> "1", "12.50" -> "12.5"
	local out = string.gsub(s, "%.?0+$", "")
	return out
end

--- 950 -> "950", 1234 -> "1.2K", 12345 -> "12.3K", 123456 -> "123K", 3.4e6 -> "3.4M".
function Format.compact(n: number): string
	if n ~= n then
		return "0"
	end
	local sign = if n < 0 then "-" else ""
	local v = math.abs(n)
	if v < 1000 then
		return sign .. tostring(math.floor(v))
	end
	local tier = 0
	while v >= 1000 and tier < #SUFFIXES do
		v /= 1000
		tier += 1
	end
	-- Truncate (never round up a displayed balance past what the player has).
	local text = if v >= 100 then tostring(math.floor(v)) else trim(string.format("%.1f", math.floor(v * 10) / 10))
	return sign .. text .. SUFFIXES[tier]
end

--- 1234567 -> "1,234,567".
function Format.grouped(n: number): string
	local sign = if n < 0 then "-" else ""
	local digits = tostring(math.floor(math.abs(n)))
	local out = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	out = string.gsub(out, "^,", "")
	return sign .. out
end

--- "+12", "+1.2K"; used by NumberPop.
function Format.delta(n: number): string
	if n >= 0 then
		return "+" .. Format.compact(n)
	end
	return Format.compact(n)
end

--- Kit display helpers: Format's text through the installed localizer.
function Format.showCompact(n: number): string
	return Format.localize(Format.compact(n))
end

function Format.showGrouped(n: number): string
	return Format.localize(Format.grouped(n))
end

function Format.showDelta(n: number): string
	return Format.localize(Format.delta(n))
end

--- True when a gain is "big" (>= ratio of the value before the gain).
function Format.isBigGain(before: number, gain: number, ratio: number): boolean
	if gain <= 0 then
		return false
	end
	if before <= 0 then
		return true
	end
	return gain >= before * ratio
end

return Format
