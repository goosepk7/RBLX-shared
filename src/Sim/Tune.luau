--!strict
--[[
	Helpers for the sim auto-fix loop (brief §9.2): search a Config value within documented
	bounds until a metric hits its target, and report honestly when the bounds cannot do it.

	  local result = Tune.solve({
	      name = "STUDS_PER_WIN",
	      min = 0.15, max = 0.40,          -- the documented bounds, never exceeded
	      current = 0.25,
	      evaluate = function(x) return runSim({ studsPerWin = x }).world2MinutesP50 end,
	      target = { max = 25 },           -- want metric <= 25
	  })
	  -- result.ok, result.value (recommended), result.metric, result.before, result.steps

	solve() assumes the metric is monotonic in the parameter over [min, max] (it checks the
	direction from the endpoints). For non-monotonic cases use Tune.grid and pick by hand.
]]

export type Target = { min: number?, max: number? }

export type Step = { value: number, metric: number }

export type SolveSpec = {
	name: string,
	min: number,
	max: number,
	current: number,
	evaluate: (value: number) -> number,
	target: Target,
	-- Stop when the bracket is narrower than this. Default (max - min) / 1000.
	tolerance: number?,
	maxSteps: number?,
	-- Round recommendations, e.g. to 0.01 or to whole numbers. Default no rounding.
	step: number?,
	-- Prefer the value closest to `current` that meets the target (default true), so retunes
	-- are minimal rather than jumping to an extreme.
	minimalChange: boolean?,
}

export type SolveResult = {
	name: string,
	ok: boolean,
	changed: boolean,
	before: { value: number, metric: number },
	value: number,
	metric: number,
	steps: { Step },
	reason: string,
}

local Tune = {}

local function meets(metric: number, target: Target): boolean
	if metric ~= metric then
		return false
	end
	if target.min ~= nil and metric < target.min then
		return false
	end
	if target.max ~= nil and metric > target.max then
		return false
	end
	return true
end
Tune.meets = meets

local function round(value: number, step: number?): number
	if not step or step <= 0 then
		return value
	end
	return math.floor(value / step + 0.5) * step
end

function Tune.solve(spec: SolveSpec): SolveResult
	assert(spec.max > spec.min, "Tune.solve: max must exceed min")
	assert(spec.current >= spec.min and spec.current <= spec.max, "Tune.solve: current is outside its bounds")
	local tolerance = spec.tolerance or (spec.max - spec.min) / 1000
	local maxSteps = spec.maxSteps or 40
	local steps: { Step } = {}

	local function eval(x: number): number
		local metric = spec.evaluate(x)
		table.insert(steps, { value = x, metric = metric })
		return metric
	end

	local before = eval(spec.current)
	if meets(before, spec.target) then
		return {
			name = spec.name,
			ok = true,
			changed = false,
			before = { value = spec.current, metric = before },
			value = spec.current,
			metric = before,
			steps = steps,
			reason = "already meets target",
		}
	end

	-- Which side of the target are we on, and which way must the parameter move?
	local tooHigh = spec.target.max ~= nil and before > spec.target.max
	local atMin = eval(spec.min)
	local atMax = eval(spec.max)
	local increasing = atMax >= atMin
	-- To lower the metric move toward the end that gives the lower metric, and vice versa.
	local moveUp = if tooHigh then not increasing else increasing
	local far = if moveUp then spec.max else spec.min
	local farMetric = if moveUp then atMax else atMin

	-- The edge of the target the metric reaches first on the way from `current` to `far`. With a
	-- band target ({ min, max }) `far` may overshoot the band, so bisect against this edge rather
	-- than against `meets`: the first value past the near edge is the minimal change.
	local function crossed(metric: number): boolean
		if metric ~= metric then
			return false
		end
		if tooHigh then
			return metric <= (spec.target.max :: number)
		end
		return spec.target.min == nil or metric >= spec.target.min
	end

	local function cannotReach(detail: string): SolveResult
		return {
			name = spec.name,
			ok = false,
			changed = false,
			before = { value = spec.current, metric = before },
			value = spec.current,
			metric = before,
			steps = steps,
			reason = "cannot reach target within bounds: " .. detail,
		}
	end

	if not crossed(farMetric) then
		return cannotReach(string.format("best at %s = %.4g gives %.4g", spec.name, far, farMetric))
	end

	-- Bisect between current (not yet crossed) and far (crossed) for the crossing closest to
	-- current. With minimalChange = false and a far end inside the target, take the far end.
	local failing = spec.current
	local passing = far
	local passingMetric = farMetric
	local bisect = spec.minimalChange ~= false or not meets(farMetric, spec.target)
	local count = 0
	while bisect and math.abs(passing - failing) > tolerance and count < maxSteps do
		count += 1
		local mid = (failing + passing) / 2
		local metric = eval(mid)
		if crossed(metric) then
			passing, passingMetric = mid, metric
		else
			failing = mid
		end
	end
	if not meets(passingMetric, spec.target) then
		-- The metric jumps over the whole band between two values closer than `tolerance`.
		return cannotReach(
			string.format(
				"the metric jumps over the band near %s = %.4g (%.4g); no value in bounds lands inside it",
				spec.name,
				passing,
				passingMetric
			)
		)
	end

	local recommended = math.clamp(round(passing, spec.step), spec.min, spec.max)
	local recommendedMetric = passingMetric
	if recommended ~= passing then
		recommendedMetric = eval(recommended)
		if not meets(recommendedMetric, spec.target) then
			-- Rounding crossed the boundary; step one increment further toward `far`.
			local stepSize = spec.step or 0
			local nudged = math.clamp(recommended + (if moveUp then stepSize else -stepSize), spec.min, spec.max)
			recommended = nudged
			recommendedMetric = eval(nudged)
		end
	end

	return {
		name = spec.name,
		ok = meets(recommendedMetric, spec.target),
		changed = recommended ~= spec.current,
		before = { value = spec.current, metric = before },
		value = recommended,
		metric = recommendedMetric,
		steps = steps,
		reason = string.format(
			"%s %.4g -> %.4g moves metric %.4g -> %.4g",
			spec.name,
			spec.current,
			recommended,
			before,
			recommendedMetric
		),
	}
end

-- Evaluates every value in `values` (or `count` evenly spaced values in [min, max]).
function Tune.grid(min: number, max: number, count: number, evaluate: (number) -> number): { Step }
	assert(count >= 2, "Tune.grid needs count >= 2")
	local out: { Step } = {}
	for i = 0, count - 1 do
		local value = min + (max - min) * i / (count - 1)
		table.insert(out, { value = value, metric = evaluate(value) })
	end
	return out
end

-- Markdown lines for TUNING.md / commit messages.
function Tune.describe(results: { SolveResult }): string
	local out =
		{ "| Parameter | Before | After | Metric before | Metric after | Status |", "|---|---|---|---|---|---|" }
	for _, r in results do
		table.insert(
			out,
			string.format(
				"| %s | %.4g | %.4g | %.4g | %.4g | %s |",
				r.name,
				r.before.value,
				r.value,
				r.before.metric,
				r.metric,
				if not r.ok then "**cannot fix within bounds**" elseif r.changed then "retuned" else "ok"
			)
		)
	end
	return table.concat(out, "\n") .. "\n"
end

return Tune
