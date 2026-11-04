--!strict
--[[
	Assertions for the Test runner. `expect(value).toBe(other)`; negate with `.never`.
	Failures raise a table { __testFailure = true, message = string } so the runner can tell an
	assertion failure from an unexpected error.
]]

export type Expectation = {
	never: Expectation,
	toBe: (expected: any) -> (),
	toEqual: (expected: any) -> (),
	toBeNear: (expected: number, epsilon: number?) -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toBeNil: () -> (),
	toBeType: (typeName: string) -> (),
	toBeGreaterThan: (n: number) -> (),
	toBeGreaterThanOrEqual: (n: number) -> (),
	toBeLessThan: (n: number) -> (),
	toBeLessThanOrEqual: (n: number) -> (),
	toContain: (item: any) -> (),
	toHaveLength: (n: number) -> (),
	toMatch: (pattern: string) -> (),
	toThrow: (messageSubstring: string?) -> (),
}

local Expect = {}

local function describeValue(value: any, depth: number?): string
	local d = depth or 0
	local kind = type(value)
	if kind == "string" then
		return string.format("%q", value)
	elseif kind == "table" then
		if d >= 2 then
			return "{...}"
		end
		local parts = {}
		local count = 0
		local keys = {}
		for key in value do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, key in keys do
			count += 1
			if count > 8 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, string.format("%s = %s", tostring(key), describeValue(value[key], d + 1)))
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	return tostring(value)
end
Expect.describeValue = describeValue

function Expect.fail(message: string): never
	error({ __testFailure = true, message = message }, 2)
end

-- Returns nil when equal, otherwise a path + reason describing the first difference.
local function deepDiff(actual: any, expected: any, path: string, seen: { [any]: any }): string?
	if actual == expected then
		return nil
	end
	if type(actual) ~= type(expected) then
		return string.format(
			"%s: expected %s (%s), got %s (%s)",
			path,
			describeValue(expected),
			type(expected),
			describeValue(actual),
			type(actual)
		)
	end
	if type(actual) == "number" and actual ~= actual and expected ~= expected then
		return nil -- NaN == NaN for equality purposes
	end
	if type(actual) ~= "table" then
		return string.format("%s: expected %s, got %s", path, describeValue(expected), describeValue(actual))
	end
	if seen[actual] == expected then
		return nil
	end
	seen[actual] = expected
	for key, value in expected do
		local diff = deepDiff(actual[key], value, path .. "." .. tostring(key), seen)
		if diff then
			return diff
		end
	end
	for key, value in actual do
		if expected[key] == nil then
			return string.format("%s.%s: unexpected key with value %s", path, tostring(key), describeValue(value))
		end
	end
	return nil
end

function Expect.deepEqual(a: any, b: any): boolean
	return deepDiff(a, b, "value", {}) == nil
end

function Expect.new(actual: any, negated: boolean?): Expectation
	local isNegated = negated == true
	local self = {} :: Expectation

	local function check(passed: boolean, message: string, negatedMessage: string)
		if isNegated then
			if passed then
				Expect.fail(negatedMessage)
			end
		elseif not passed then
			Expect.fail(message)
		end
	end

	local shown = describeValue(actual)

	function self.toBe(expected: any)
		check(
			actual == expected,
			string.format("expected %s to be %s", shown, describeValue(expected)),
			string.format("expected %s not to be %s", shown, describeValue(expected))
		)
	end

	function self.toEqual(expected: any)
		local diff = deepDiff(actual, expected, "value", {})
		check(
			diff == nil,
			"not deeply equal: " .. tostring(diff),
			"expected values to differ, but they are deeply equal"
		)
	end

	function self.toBeNear(expected: number, epsilon: number?)
		local eps = epsilon or 1e-6
		local ok = type(actual) == "number" and math.abs(actual - expected) <= eps
		check(
			ok,
			string.format("expected %s to be within %s of %s", shown, tostring(eps), tostring(expected)),
			string.format("expected %s not to be within %s of %s", shown, tostring(eps), tostring(expected))
		)
	end

	function self.toBeTruthy()
		check(
			not not actual,
			string.format("expected %s to be truthy", shown),
			string.format("expected %s to be falsy", shown)
		)
	end

	function self.toBeFalsy()
		check(
			not actual,
			string.format("expected %s to be falsy", shown),
			string.format("expected %s to be truthy", shown)
		)
	end

	function self.toBeNil()
		check(actual == nil, string.format("expected %s to be nil", shown), "expected value not to be nil")
	end

	function self.toBeType(typeName: string)
		check(
			type(actual) == typeName,
			string.format("expected type %s, got %s (%s)", typeName, type(actual), shown),
			string.format("expected value not to be of type %s", typeName)
		)
	end

	local function compare(op: string, n: number, passed: boolean)
		check(
			type(actual) == "number" and passed,
			string.format("expected %s %s %s", shown, op, tostring(n)),
			string.format("expected %s not %s %s", shown, op, tostring(n))
		)
	end

	function self.toBeGreaterThan(n: number)
		compare(">", n, type(actual) == "number" and actual > n)
	end

	function self.toBeGreaterThanOrEqual(n: number)
		compare(">=", n, type(actual) == "number" and actual >= n)
	end

	function self.toBeLessThan(n: number)
		compare("<", n, type(actual) == "number" and actual < n)
	end

	function self.toBeLessThanOrEqual(n: number)
		compare("<=", n, type(actual) == "number" and actual <= n)
	end

	function self.toContain(item: any)
		local found = false
		if type(actual) == "string" and type(item) == "string" then
			found = string.find(actual, item, 1, true) ~= nil
		elseif type(actual) == "table" then
			for _, value in actual do
				if value == item or Expect.deepEqual(value, item) then
					found = true
					break
				end
			end
		end
		check(
			found,
			string.format("expected %s to contain %s", shown, describeValue(item)),
			string.format("expected %s not to contain %s", shown, describeValue(item))
		)
	end

	function self.toHaveLength(n: number)
		local length = if type(actual) == "string" or type(actual) == "table" then #actual else -1
		check(
			length == n,
			string.format("expected length %d, got %d (%s)", n, length, shown),
			string.format("expected length not to be %d", n)
		)
	end

	function self.toMatch(pattern: string)
		local ok = type(actual) == "string" and string.match(actual, pattern) ~= nil
		check(
			ok,
			string.format("expected %s to match pattern %q", shown, pattern),
			string.format("expected %s not to match pattern %q", shown, pattern)
		)
	end

	function self.toThrow(messageSubstring: string?)
		assert(type(actual) == "function", "toThrow expects a function")
		local ok, err = pcall(actual)
		local text = if type(err) == "table" and err.message then tostring(err.message) else tostring(err)
		local matched = not ok and (messageSubstring == nil or string.find(text, messageSubstring, 1, true) ~= nil)
		local wanted = if messageSubstring then string.format(" containing %q", messageSubstring) else ""
		local got = if ok then "it did not throw" else "it threw: " .. text
		check(
			matched,
			string.format("expected function to throw%s, but %s", wanted, got),
			string.format("expected function not to throw%s, but it threw: %s", wanted, text)
		)
	end

	if not isNegated then
		self.never = Expect.new(actual, true)
	else
		self.never = self
	end

	return self
end

return Expect
