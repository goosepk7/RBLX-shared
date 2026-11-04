--!strict
local Log = require("@shared/Util/Log")
local Net = require("@shared/Net")
local T = require("@shared/Test")

local S = Net.Schema
local expect = T.expect

local function ok(schema: Net.Schema<any>, value: any): boolean
	return (schema.check(value))
end

local function reason(schema: Net.Schema<any>, value: any): string
	local _, why = schema.check(value)
	return tostring(why)
end

T.describe("Net.Schema.number", function()
	T.it("accepts finite numbers in range", function()
		local schema = S.number({ min = 0, max = 1 })
		expect(ok(schema, 0)).toBe(true)
		expect(ok(schema, 0.5)).toBe(true)
		expect(ok(schema, 1)).toBe(true)
	end)

	T.it("rejects NaN and infinities even without a range", function()
		local schema = S.number()
		expect(ok(schema, 0 / 0)).toBe(false)
		expect(ok(schema, math.huge)).toBe(false)
		expect(ok(schema, -math.huge)).toBe(false)
		expect(reason(schema, 0 / 0)).toContain("finite")
	end)

	T.it("rejects NaN that would slip past a naive range check", function()
		-- NaN < min and NaN > max are both false; the schema must not rely on them.
		local schema = S.number({ min = 0, max = 10 })
		expect(ok(schema, 0 / 0)).toBe(false)
	end)

	T.it("rejects out-of-range values and other types", function()
		local schema = S.number({ min = 0, max = 1 })
		expect(ok(schema, -0.01)).toBe(false)
		expect(ok(schema, 1.01)).toBe(false)
		expect(ok(schema, "0.5")).toBe(false)
		expect(ok(schema, nil)).toBe(false)
		expect(reason(schema, 2)).toContain("out-of-range")
	end)

	T.it("integer() rejects fractions", function()
		local schema = S.integer({ min = 1, max = 99 })
		expect(ok(schema, 3)).toBe(true)
		expect(ok(schema, 3.5)).toBe(false)
		expect(ok(schema, 0)).toBe(false)
	end)

	T.it("refuses an inverted range at definition time", function()
		expect(function()
			S.number({ min = 5, max = 1 })
		end).toThrow("min is greater than max")
	end)
end)

T.describe("Net.Schema.string", function()
	T.it("enforces byte length with a default cap of 256", function()
		local schema = S.string()
		expect(ok(schema, "")).toBe(true)
		expect(ok(schema, string.rep("a", 256))).toBe(true)
		expect(ok(schema, string.rep("a", 257))).toBe(false)
		local bounded = S.string({ minLength = 2, maxLength = 4 })
		expect(ok(bounded, "a")).toBe(false)
		expect(ok(bounded, "abcd")).toBe(true)
		expect(ok(bounded, "abcde")).toBe(false)
	end)

	T.it("rejects invalid UTF-8", function()
		expect(ok(S.string(), string.char(255, 254))).toBe(false)
		expect(ok(S.string(), "héllo")).toBe(true)
	end)

	T.it("applies an optional pattern", function()
		local code = S.string({ maxLength = 16, pattern = "^%u+$" })
		expect(ok(code, "RELEASE")).toBe(true)
		expect(ok(code, "release")).toBe(false)
	end)

	T.it("never echoes the received string in its reason", function()
		local secret = string.rep("x", 300)
		expect(reason(S.string(), secret)).never.toContain("xxxx")
	end)
end)

T.describe("Net.Schema.enum / literal / boolean / none / any", function()
	T.it("enum accepts only listed values", function()
		local schema = S.enum({ "wood", "steel" })
		expect(ok(schema, "wood")).toBe(true)
		expect(ok(schema, "carbon")).toBe(false)
		expect(ok(schema, 1)).toBe(false)
	end)

	T.it("literal, boolean, none, any", function()
		expect(ok(S.literal("x"), "x")).toBe(true)
		expect(ok(S.literal("x"), "y")).toBe(false)
		expect(ok(S.boolean(), false)).toBe(true)
		expect(ok(S.boolean(), 0)).toBe(false)
		expect(ok(S.none(), nil)).toBe(true)
		expect(ok(S.none(), 1)).toBe(false)
		expect(ok(S.any(), { 1, 2 })).toBe(true)
	end)

	T.it("optional accepts nil or the inner schema", function()
		local schema = S.optional(S.integer())
		expect(ok(schema, nil)).toBe(true)
		expect(ok(schema, 4)).toBe(true)
		expect(ok(schema, 4.5)).toBe(false)
	end)
end)

T.describe("Net.Schema collections", function()
	T.it("array requires 1..n keys, bounds and valid items", function()
		local schema = S.array(S.integer(), { maxLength = 3 })
		expect(ok(schema, {})).toBe(true)
		expect(ok(schema, { 1, 2, 3 })).toBe(true)
		expect(ok(schema, { 1, 2, 3, 4 })).toBe(false)
		expect(ok(schema, { 1, 2.5 })).toBe(false)
		expect(ok(schema, { [1] = 1, [3] = 3 })).toBe(false)
		expect(ok(schema, { a = 1 })).toBe(false)
		expect(reason(schema, { 1, "x" } :: { any })).toContain("item 2")
	end)

	T.it("array stops scanning hostile tables at the limit", function()
		local huge = {}
		for i = 1, 10000 do
			huge["k" .. i] = i
		end
		expect(ok(S.array(S.any(), { maxLength = 8 }), huge)).toBe(false)
	end)

	T.it("map validates keys and values and caps entries", function()
		local schema = S.map(S.string({ maxLength = 8 }), S.integer(), { maxEntries = 2 })
		expect(ok(schema, { a = 1, b = 2 })).toBe(true)
		expect(ok(schema, { a = 1, b = 2, c = 3 })).toBe(false)
		expect(ok(schema, { a = "x" })).toBe(false)
		expect(ok(schema, { [1] = 1 })).toBe(false)
	end)

	T.it("struct checks every field and rejects unknown keys by default", function()
		local schema = S.struct({ item = S.string({ maxLength = 8 }), qty = S.integer({ min = 1, max = 9 }) })
		expect(ok(schema, { item = "lamp", qty = 2 })).toBe(true)
		expect(ok(schema, { item = "lamp" })).toBe(false)
		expect(ok(schema, { item = "lamp", qty = 2, admin = true })).toBe(false)
		expect(reason(schema, { item = "lamp", qty = 20 })).toContain("field 'qty'")
		expect(reason(schema, { item = "lamp", qty = 2, admin = true })).toContain("unexpected field")
	end)

	T.it("struct allowExtra and optional fields", function()
		local schema = S.struct({ id = S.string(), note = S.optional(S.string()) }, { allowExtra = true })
		expect(ok(schema, { id = "a" })).toBe(true)
		expect(ok(schema, { id = "a", other = 1 })).toBe(true)
		expect(ok(schema, { note = "n" })).toBe(false)
	end)

	T.it("union accepts any matching branch", function()
		local schema = S.union(S.literal("auto"), S.integer({ min = 1, max = 3 }))
		expect(ok(schema, "auto")).toBe(true)
		expect(ok(schema, 2)).toBe(true)
		expect(ok(schema, 4)).toBe(false)
	end)
end)

T.describe("Net.Schema.custom", function()
	T.it("uses the check and reports one that errors instead of trusting it", function()
		local even = S.custom("even integer", function(value: any)
			return type(value) == "number" and value % 2 == 0, "not even"
		end)
		expect(ok(even, 4)).toBe(true)
		expect(reason(even, 3)).toBe("not even")

		local entries, restore = Log.capture()
		local broken = S.custom("broken", function(_value: any): (boolean, string?)
			error("bug in check")
		end)
		local passed = ok(broken, 1)
		restore()
		expect(passed).toBe(false)
		expect(#entries).toBe(1)
		expect(entries[1].level).toBe("error")
	end)
end)
