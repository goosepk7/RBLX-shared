--!strict
--[[
	Sim runner shell: one sim definition runs headlessly under lune, from the Studio command
	bar, or as an Open Cloud Luau Execution task, with the same pass/fail output.

	Define a sim (game repos keep these in sims/):

		return Runner.define({
			name = "stilts.economy",
			description = "14-day progression for 500 synthetic players",
			seed = "stilts-economy-v1",
			run = function(ctx)
				local players = Sim.Population.generate(ctx.rng, ctx.params.players or 500)
				...
				ctx.recorder:set("firstWin.p50", value)
				ctx.targets:check("first win (s)", value, { max = 60 })
			end,
		})

	Run it:
		lune:          lune run sims [name-filter]          (sims/init.luau, writes sims/out/)
		Studio:        require(path.To.RunSims).studio()    (prints [SIM PASS]/[SIM FAIL])
		Open Cloud:    return require(path.To.RunSims).openCloud()  (JSON-able result table)

	A sim fails if it errors or any target fails. Errors are caught per sim so one broken sim
	never hides the results of the others.
]]

local Recorder = require("./Recorder")
local Rng = require("./Rng")
local Targets = require("./Targets")

export type Context = {
	name: string,
	seed: string,
	rng: Rng.Rng,
	recorder: Recorder.Recorder,
	targets: Targets.Targets,
	params: { [string]: any },
	-- Free-form notes for the report (findings, caveats).
	note: (self: Context, text: string) -> (),
	log: (self: Context, ...any) -> (),
	-- Extra text artifacts (markdown, csv) keyed by file name; lune writes them to sims/out/<name>/.
	artifact: (self: Context, fileName: string, content: string) -> (),
}

export type Definition = {
	name: string,
	description: string?,
	seed: string?,
	-- "lune" sims are pure; "studio" sims need a live DataModel; "both" run anywhere.
	environment: ("lune" | "studio" | "both")?,
	params: { [string]: any }?,
	run: (ctx: Context) -> (),
}

export type Result = {
	name: string,
	description: string,
	seed: string,
	ok: boolean,
	error: string?,
	durationMs: number,
	targets: { Targets.Result },
	notes: { string },
	metrics: { [string]: any },
	recorder: Recorder.Recorder,
	artifacts: { [string]: string },
}

export type RunOptions = {
	seed: string?,
	params: { [string]: any }?,
	-- Called with each log line instead of print.
	output: ((line: string) -> ())?,
	quiet: boolean?,
}

local Runner = {}

function Runner.define(definition: Definition): Definition
	assert(type(definition.name) == "string" and definition.name ~= "", "sim needs a name")
	assert(type(definition.run) == "function", "sim needs a run function")
	return definition
end

local function joinArgs(...: any): string
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	return table.concat(parts, " ")
end

function Runner.run(definition: Definition, options: RunOptions?): Result
	local opts: RunOptions = options or {}
	local out: (string) -> () = if opts.output then opts.output else print
	local seed = opts.seed or definition.seed or definition.name
	local params: { [string]: any } = table.clone(definition.params or {})
	local overrides: { [string]: any } = opts.params or {}
	for key, value in overrides do
		params[key] = value
	end

	local recorder = Recorder.new()
	local targets = Targets.new()
	local notes: { string } = {}
	local artifacts: { [string]: string } = {}

	local ctx = {
		name = definition.name,
		seed = seed,
		rng = Rng.new(seed),
		recorder = recorder,
		targets = targets,
		params = params,
	} :: Context

	function ctx.note(_self: Context, text: string)
		table.insert(notes, text)
	end

	function ctx.log(_self: Context, ...: any)
		if not opts.quiet then
			out(string.format("[%s] %s", definition.name, joinArgs(...)))
		end
	end

	function ctx.artifact(_self: Context, fileName: string, content: string)
		assert(not string.find(fileName, "[/\\]"), "artifact names must be plain file names")
		artifacts[fileName] = content
	end

	local started = os.clock()
	local ok, err = pcall(function()
		definition.run(ctx)
	end)
	local durationMs = (os.clock() - started) * 1000

	local result: Result = {
		name = definition.name,
		description = definition.description or "",
		seed = seed,
		ok = ok and targets:passed(),
		error = if ok then nil else tostring(err),
		durationMs = durationMs,
		targets = targets:results(),
		notes = notes,
		metrics = recorder:metrics(),
		recorder = recorder,
		artifacts = artifacts,
	}

	if not opts.quiet then
		for _, line in Runner.format(result) do
			out(line)
		end
	end
	return result
end

-- Output-window friendly lines: a banner, each target, notes, and the error if any.
function Runner.format(result: Result): { string }
	local lines = {
		string.format(
			"[SIM %s] %s (seed %s, %.0f ms)",
			if result.ok then "PASS" else "FAIL",
			result.name,
			result.seed,
			result.durationMs
		),
	}
	for _, target in result.targets do
		table.insert(
			lines,
			string.format("    %s  %s: %s", if target.ok then "ok  " else "FAIL", target.name, target.text)
		)
	end
	for _, note in result.notes do
		table.insert(lines, "    note: " .. note)
	end
	if result.error then
		table.insert(lines, "    ERROR: " .. result.error)
	end
	return lines
end

export type Summary = { ok: boolean, passed: number, failed: number, results: { Result } }

function Runner.runAll(definitions: { Definition }, options: RunOptions?, filter: string?): Summary
	local results: { Result } = {}
	local passed, failed = 0, 0
	for _, definition in definitions do
		if filter == nil or string.find(definition.name, filter, 1, true) then
			local result = Runner.run(definition, options)
			table.insert(results, result)
			if result.ok then
				passed += 1
			else
				failed += 1
			end
		end
	end
	local out: (string) -> () = if options and options.output then options.output else print
	if not (options and options.quiet) then
		out(
			string.format(
				"[SIM %s] %d passed, %d failed",
				if failed == 0 then "SUMMARY PASS" else "SUMMARY FAIL",
				passed,
				failed
			)
		)
	end
	return { ok = failed == 0, passed = passed, failed = failed, results = results }
end

-- Plain data for Open Cloud Luau Execution (the task's return value) or JSON files.
function Runner.serialize(summary: Summary): { [string]: any }
	local results = {}
	for _, r in summary.results do
		local targets = {}
		for _, t in r.targets do
			table.insert(
				targets,
				{ name = t.name, ok = t.ok, value = t.value, min = t.min, max = t.max, text = t.text }
			)
		end
		table.insert(results, {
			name = r.name,
			description = r.description,
			seed = r.seed,
			ok = r.ok,
			error = r.error,
			durationMs = math.floor(r.durationMs),
			targets = targets,
			notes = r.notes,
			metrics = r.metrics,
		})
	end
	return { ok = summary.ok, passed = summary.passed, failed = summary.failed, results = results }
end

-- Entry points for a game's RunSims module:
--   studio(): run in the command bar or a plugin button; prints results.
--   openCloud(): return value of a Luau Execution task.
function Runner.entryPoints(definitions: { Definition }): {
	studio: (filter: string?) -> Summary,
	openCloud: (filter: string?) -> { [string]: any },
}
	return {
		studio = function(filter: string?): Summary
			return Runner.runAll(definitions, nil, filter)
		end,
		openCloud = function(filter: string?): { [string]: any }
			return Runner.serialize(Runner.runAll(definitions, nil, filter))
		end,
	}
end

return Runner
