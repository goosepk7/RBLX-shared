--!strict
-- The Studio smoke's describer and its loopback expectations (studio/NetSmoke/Probes.luau). If
-- describe could not tell these values apart, a wire mismatch in Studio would pass unseen.
local Net = require("@shared/Net")
local Probes = require("@studio/NetSmoke/Probes")
local T = require("@shared/Test")

local expect = T.expect

-- Stands in for workspace: a userdata whose tostring is its name, like an Instance key.
local fakeInstance = newproxy(true)
getmetatable(fakeInstance).__tostring = function()
	return "Workspace"
end

local ENV: Probes.Env = { instance = fakeInstance }

local function expected(name: string): string
	local probe = Probes.get(name)
	assert(probe, "no probe named " .. name)
	return Probes.expected(Probes.viaLoopback(Net.Loopback), probe, ENV)
end

T.describe("NetSmoke.Probes.describe", function()
	T.it("sorts keys, number keys first, and quotes strings", function()
		-- selene: allow(mixed_table)
		local mixed = { b = true, a = "x", 20, 10 }
		expect(Probes.describe(mixed)).toBe('{[1]=20, [2]=10, ["a"]="x", ["b"]=true}')
		expect(Probes.describe({})).toBe("{}")
		expect(Probes.describe(nil)).toBe("nil")
		expect(Probes.describe(1.5)).toBe("1.5")
	end)

	T.it("marks repeated tables, cycles and metatables", function()
		local inner = { 1 }
		expect(Probes.describe({ a = inner, b = inner })).toBe('{["a"]={[1]=1}, ["b"]=<ref 2>}')
		expect(Probes.describe({ a = { 1 }, b = { 1 } })).toBe('{["a"]={[1]=1}, ["b"]={[1]=1}}')
		local cycle: { [string]: any } = {}
		cycle.self = cycle
		expect(Probes.describe(cycle)).toBe('{["self"]=<ref 1>}')
		expect(Probes.describe(setmetatable({ v = 1 }, {}))).toBe('mt{["v"]=1}')
	end)

	T.it("blanks memory addresses and labels other kinds", function()
		local key = tostring({})
		expect(Probes.describe({ [key] = 1 })).toBe('{["table: 0x?"]=1}')
		expect(Probes.describe({ [true] = 1 })).toBe("{[<boolean: true>]=1}")
		expect(Probes.describe(fakeInstance)).toBe("<userdata: Workspace>")
		expect(Probes.describe(print)).toMatch("^<function: ")
	end)
end)

T.describe("NetSmoke.Probes expectations", function()
	T.it("are what Net.Loopback delivers under each rule it claims", function()
		expect(expected("nested")).toBe(
			'{["inst"]=<userdata: Workspace>, ["list"]={[1]=1, [2]=2, [3]=3}, ["map"]={["a"]="x", ["b"]=true}, ["n"]=1.5}'
		)
		expect(expected("shared")).toBe('{["a"]={[1]=1}, ["b"]={[1]=1}}')
		expect(expected("functions")).toBe('{["keep"]=1}')
		expect(expected("threads")).toBe('{["keep"]=1}')
		expect(expected("keys")).toBe('{["Workspace"]="instance", ["table: 0x?"]="table", ["true"]="boolean"}')
		expect(expected("mixed")).toBe("{[1]=10, [2]=20}")
		expect(expected("metatable")).toBe('{["v"]=1}')
		expect(expected("cyclic")).toBe(Probes.ERROR)
		expect(expected("sparse")).toBe('{[1]="a", [3]="c"}')
	end)

	T.it("names every probe once and gives it a rule", function()
		local names: { [string]: boolean } = {}
		for _, probe in Probes.LIST do
			expect(names[probe.name]).toBeNil()
			names[probe.name] = true
			expect(#probe.rule).toBeGreaterThan(0)
			expect(Probes.get(probe.name)).toBe(probe)
		end
		expect(Probes.get("missing")).toBeNil()
	end)
end)
