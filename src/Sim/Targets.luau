--!strict
--[[
	Pass/fail targets for sims (brief §9.2 "Targets"), with a readable report.

	  local targets = Targets.new()
	  targets:check("first win, seconds (p50, all)", firstWinP50, { max = 60 })
	  targets:check("rebirth 1 day (grinder p50)", day, { min = 2, max = 4 })
	  targets:check("largest income share", share, { max = 0.55, format = "%.0f%%", scale = 100 })
	  if not targets:passed() then ... end
	  print(targets:markdown())

	A NaN or nil value fails its target (e.g. nobody reached the milestone).
]]

export type Bounds = {
	min: number?,
	max: number?,
	-- Display only: string.format pattern and multiplier for the value and bounds.
	format: string?,
	scale: number?,
	-- Free-text note shown in the report (e.g. which Config value drives it).
	note: string?,
}

export type Result = {
	name: string,
	value: number?,
	min: number?,
	max: number?,
	ok: boolean,
	text: string,
	note: string?,
}

export type Targets = {
	check: (self: Targets, name: string, value: number?, bounds: Bounds) -> boolean,
	results: (self: Targets) -> { Result },
	failures: (self: Targets) -> { Result },
	passed: (self: Targets) -> boolean,
	markdown: (self: Targets) -> string,
	lines: (self: Targets) -> { string },
}

local Targets = {}

local function fmt(value: number?, bounds: Bounds): string
	if value == nil or value ~= value then
		return "n/a"
	end
	return string.format(bounds.format or "%.4g", value * (bounds.scale or 1))
end

function Targets.new(): Targets
	local list: { Result } = {}
	local self = {} :: Targets

	function self.check(_self: Targets, name: string, value: number?, bounds: Bounds): boolean
		assert(bounds.min ~= nil or bounds.max ~= nil, "Targets:check needs min and/or max")
		local ok = value ~= nil and value == value
		if ok and bounds.min ~= nil and (value :: number) < bounds.min then
			ok = false
		end
		if ok and bounds.max ~= nil and (value :: number) > bounds.max then
			ok = false
		end
		local range
		if bounds.min ~= nil and bounds.max ~= nil then
			range = string.format("%s..%s", fmt(bounds.min, bounds), fmt(bounds.max, bounds))
		elseif bounds.min ~= nil then
			range = ">= " .. fmt(bounds.min, bounds)
		else
			range = "<= " .. fmt(bounds.max, bounds)
		end
		table.insert(list, {
			name = name,
			value = value,
			min = bounds.min,
			max = bounds.max,
			ok = ok,
			text = string.format("%s (target %s)", fmt(value, bounds), range),
			note = bounds.note,
		})
		return ok
	end

	function self.results(_self: Targets): { Result }
		return table.clone(list)
	end

	function self.failures(_self: Targets): { Result }
		local out = {}
		for _, r in list do
			if not r.ok then
				table.insert(out, r)
			end
		end
		return out
	end

	function self.passed(_self: Targets): boolean
		for _, r in list do
			if not r.ok then
				return false
			end
		end
		return true
	end

	function self.lines(_self: Targets): { string }
		local out = {}
		for _, r in list do
			table.insert(out, string.format("%s  %s: %s", if r.ok then "PASS" else "FAIL", r.name, r.text))
		end
		return out
	end

	function self.markdown(_self: Targets): string
		local out = { "| | Target | Result | Note |", "|---|---|---|---|" }
		for _, r in list do
			table.insert(
				out,
				string.format(
					"| %s | %s | %s | %s |",
					if r.ok then "PASS" else "**FAIL**",
					r.name,
					r.text,
					r.note or ""
				)
			)
		end
		return table.concat(out, "\n") .. "\n"
	end

	return self
end

return Targets
