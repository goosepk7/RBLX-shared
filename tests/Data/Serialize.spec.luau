--!strict
local Data = require("@shared/Data")
local T = require("@shared/Test")

local expect = T.expect

local function problem(value: any): (string?, string?)
	local ok, path, reason = Data.check(value, "data")
	expect(ok).toBe(false)
	return path, reason
end

T.describe("Data.check", function()
	T.it("accepts plain data and estimates its JSON size", function()
		local ok, path, _, size = Data.check({ coins = 12, name = "ok", flags = { true, false }, nested = {} }, "data")
		expect(ok).toBe(true)
		expect(path).toBeNil()
		-- {"coins":12,"name":"ok","flags":[true,false],"nested":[]} is about 55 characters.
		expect(size).toBeGreaterThan(40)
		expect(size).toBeLessThan(70)
	end)

	T.it("names the path of NaN and infinity", function()
		local path, reason = problem({ stats = { speed = 0 / 0 } })
		expect(path).toBe("data.stats.speed")
		expect(reason).toContain("NaN")
		path, reason = problem({ list = { 1, math.huge } })
		expect(path).toBe("data.list[2]")
		expect(reason).toContain("infinity")
	end)

	T.it("rejects mixed tables, holes and non-string keys", function()
		local mixed: any = { 1, 2 }
		mixed.extra = 3
		local path, reason = problem({ inventory = mixed })
		expect(path).toBe("data.inventory")
		expect(reason).toContain("mixes")

		local sparse: any = {}
		sparse[1] = "a"
		sparse[3] = "c"
		path = problem({ slots = sparse })
		expect(path).toBe("data.slots")

		path = problem({ byId = { [101] = "x" } })
		expect(path).toBe("data.byId")
	end)

	T.it("rejects cycles, metatables, functions and invalid UTF-8", function()
		local cyclic: any = {}
		cyclic.self = cyclic
		local path, reason = problem({ loop = cyclic })
		expect(path).toBe("data.loop.self")
		expect(reason).toContain("contains itself")

		path, reason = problem({ obj = setmetatable({}, {}) })
		expect(path).toBe("data.obj")
		expect(reason).toContain("metatable")

		path = problem({ callback = function() end })
		expect(path).toBe("data.callback")

		path, reason = problem({ name = string.char(255, 254) })
		expect(path).toBe("data.name")
		expect(reason).toContain("UTF-8")
	end)

	T.it("allows the same table twice when it isn't a cycle", function()
		local shared = { 1 }
		expect((Data.check({ a = shared, b = shared }))).toBe(true)
	end)

	T.it("estimateSize returns nil for unstorable values", function()
		expect(Data.estimateSize({ bad = 0 / 0 })).toBeNil()
		expect(Data.estimateSize("abc")).toBe(5)
	end)
end)
