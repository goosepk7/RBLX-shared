--!strict
--[[
	Test: a small describe/it runner that works the same under lune (CI) and in Studio.

	Spec files (tests/**/*.spec.luau) register cases when required:

		local T = require("@shared/Test")
		T.describe("Economy.earn", function()
			T.beforeEach(function() ... end)
			T.it("adds to the balance", function()
				T.expect(balance).toBe(10)
			end)
		end)

	The lune entry point (`lune run tests`) finds spec files, calls T.beginFile(path) before
	requiring each one, then T.run() and exits non-zero on any failure.

	Fakes for Roblox services live in T.Fakes; the virtual clock / `task` emulation in T.Clock.
]]

local Clock = require("@self/Clock")
local Expect = require("@self/Expect")
local Fakes = require("@self/Fakes")
local Signal = require("@self/Signal")

export type Expectation = Expect.Expectation

export type CaseResult = {
	file: string,
	name: string,
	status: "passed" | "failed" | "skipped",
	message: string?,
	durationMs: number,
}

export type RunResult = {
	passed: number,
	failed: number,
	skipped: number,
	cases: { CaseResult },
	failures: { CaseResult },
	durationMs: number,
	ok: boolean,
}

export type RunOptions = {
	-- Only run cases whose full name contains this substring.
	filter: string?,
	-- Called with each finished case. Default prints one line per failure and a summary.
	onCase: ((result: CaseResult) -> ())?,
	-- Print nothing (the caller formats results). Default false.
	quiet: boolean?,
}

type Hook = () -> ()

type Suite = {
	name: string,
	parent: Suite?,
	beforeEach: { Hook },
	afterEach: { Hook },
	beforeAll: { Hook },
	afterAll: { Hook },
	children: { Node },
	file: string,
}

type Case = {
	kind: "case",
	name: string,
	fn: () -> (),
	suite: Suite,
	skip: boolean,
	only: boolean,
}

type Node = Case | { kind: "suite", suite: Suite }

local Test = {}

Test.Clock = Clock
Test.Fakes = Fakes
Test.Signal = Signal
Test.Expect = Expect

local currentFile = "<inline>"
local root: Suite
local current: Suite
local hasOnly = false

local function newSuite(name: string, parent: Suite?): Suite
	return {
		name = name,
		parent = parent,
		beforeEach = {},
		afterEach = {},
		beforeAll = {},
		afterAll = {},
		children = {},
		file = currentFile,
	}
end

function Test.reset()
	root = newSuite("", nil)
	current = root
	hasOnly = false
end
Test.reset()

-- Tags subsequently registered cases with a file path (used by the lune runner).
function Test.beginFile(path: string)
	currentFile = path
	local fileSuite = newSuite("", root)
	fileSuite.file = path
	table.insert(root.children, { kind = "suite", suite = fileSuite })
	current = fileSuite
end

function Test.describe(name: string, body: () -> ())
	local suite = newSuite(name, current)
	table.insert(current.children, { kind = "suite", suite = suite })
	local previous = current
	current = suite
	local ok, err = pcall(body :: any)
	current = previous
	if not ok then
		-- A describe body that errors is a registration failure: report it as a failing case.
		local message = tostring(err)
		table.insert(
			suite.children,
			{
				kind = "case",
				name = "(describe body)",
				fn = function()
					Expect.fail("describe block errored while registering: " .. message)
				end,
				suite = suite,
				skip = false,
				only = false,
			} :: Case
		)
	end
end

local function addCase(name: string, fn: () -> (), skip: boolean, only: boolean)
	assert(type(name) == "string" and type(fn) == "function", "T.it(name, fn) expects a string and a function")
	if only then
		hasOnly = true
	end
	table.insert(
		current.children,
		{
			kind = "case",
			name = name,
			fn = fn,
			suite = current,
			skip = skip,
			only = only,
		} :: Case
	)
end

function Test.it(name: string, fn: () -> ())
	addCase(name, fn, false, false)
end
Test.test = Test.it

-- Registers a case that is reported as skipped. Use sparingly; a skipped test is a TODO.
function Test.skip(name: string, fn: () -> ())
	addCase(name, fn, true, false)
end

-- Runs only `only` cases (across all files) while any exist. CI fails if one is committed.
function Test.only(name: string, fn: () -> ())
	addCase(name, fn, false, true)
end

function Test.beforeEach(fn: Hook)
	table.insert(current.beforeEach, fn)
end

function Test.afterEach(fn: Hook)
	table.insert(current.afterEach, fn)
end

function Test.beforeAll(fn: Hook)
	table.insert(current.beforeAll, fn)
end

function Test.afterAll(fn: Hook)
	table.insert(current.afterAll, fn)
end

function Test.expect(value: any): Expectation
	return Expect.new(value)
end

function Test.fail(message: string): never
	return Expect.fail(message)
end

Test.deepEqual = Expect.deepEqual

local function fullName(suite: Suite, caseName: string): string
	local parts = { caseName }
	local node: Suite? = suite
	while node do
		if node.name ~= "" then
			table.insert(parts, 1, node.name)
		end
		node = node.parent
	end
	return table.concat(parts, " > ")
end

local function errorText(err: any): string
	if type(err) == "table" and err.__testFailure then
		return tostring(err.message)
	end
	return "error: " .. tostring(err)
end

local function chain(suite: Suite): { Suite }
	local list = {}
	local node: Suite? = suite
	while node do
		table.insert(list, 1, node)
		node = node.parent
	end
	return list
end

function Test.usesOnly(): boolean
	return hasOnly
end

function Test.run(options: RunOptions?): RunResult
	local opts: RunOptions = options or {}
	local result: RunResult = {
		passed = 0,
		failed = 0,
		skipped = 0,
		cases = {},
		failures = {},
		durationMs = 0,
		ok = true,
	}
	local runStart = os.clock()

	local function report(caseResult: CaseResult)
		table.insert(result.cases, caseResult)
		if caseResult.status == "passed" then
			result.passed += 1
		elseif caseResult.status == "skipped" then
			result.skipped += 1
		else
			result.failed += 1
			table.insert(result.failures, caseResult)
		end
		if opts.onCase then
			opts.onCase(caseResult)
		end
	end

	local function runCase(case: Case)
		local name = fullName(case.suite, case.name)
		if opts.filter and not string.find(name, opts.filter, 1, true) then
			return
		end
		if case.skip or (hasOnly and not case.only) then
			report({ file = case.suite.file, name = name, status = "skipped", durationMs = 0 })
			return
		end
		local suites = chain(case.suite)
		local started = os.clock()
		local message: string? = nil
		local ok, err = pcall(function()
			for _, suite in suites do
				for _, hook in suite.beforeEach do
					hook()
				end
			end
			case.fn()
		end)
		if not ok then
			message = errorText(err)
		end
		-- afterEach always runs (innermost first) so fakes and globals are restored.
		for i = #suites, 1, -1 do
			for _, hook in suites[i].afterEach do
				local hookOk, hookErr = pcall(hook :: any)
				if not hookOk and message == nil then
					message = "afterEach: " .. errorText(hookErr)
				end
			end
		end
		report({
			file = case.suite.file,
			name = name,
			status = if message then "failed" else "passed",
			message = message,
			durationMs = (os.clock() - started) * 1000,
		})
	end

	local function runSuite(suite: Suite)
		local setupError: string? = nil
		for _, hook in suite.beforeAll do
			local ok, err = pcall(hook :: any)
			if not ok then
				setupError = errorText(err)
				break
			end
		end
		for _, child in suite.children do
			if child.kind == "case" then
				local case = child :: Case
				if setupError then
					report({
						file = suite.file,
						name = fullName(suite, case.name),
						status = "failed",
						message = "beforeAll: " .. setupError,
						durationMs = 0,
					})
				else
					runCase(case)
				end
			else
				runSuite((child :: any).suite)
			end
		end
		for _, hook in suite.afterAll do
			local ok, err = pcall(hook :: any)
			if not ok then
				report({
					file = suite.file,
					name = fullName(suite, "(afterAll)"),
					status = "failed",
					message = errorText(err),
					durationMs = 0,
				})
			end
		end
	end

	runSuite(root)

	result.durationMs = (os.clock() - runStart) * 1000
	result.ok = result.failed == 0

	if not opts.quiet then
		for _, failure in result.failures do
			print(
				string.format("FAIL  %s\n      %s\n      (%s)", failure.name, tostring(failure.message), failure.file)
			)
		end
		print(
			string.format(
				"%s  %d passed, %d failed, %d skipped (%.0f ms)",
				if result.ok then "PASS" else "FAIL",
				result.passed,
				result.failed,
				result.skipped,
				result.durationMs
			)
		)
	end

	return result
end

return Test
