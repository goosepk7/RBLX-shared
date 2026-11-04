--!strict
local T = require("@shared/Test")
local Sim = require("@shared/Sim")
local expect = T.expect
local Rng = Sim.Rng

T.describe("Sim.Rng", function()
	T.it("matches golden values (xoshiro128** seeded by FNV-1a + splitmix32)", function()
		-- Cross-checked against an independent Python implementation. If this changes, every
		-- recorded sim result and generated stage changes: treat it as a breaking change.
		local r = Rng.new("golden")
		expect(r:nextU32()).toBe(3310866602)
		expect(r:nextU32()).toBe(654173328)
		expect(r:nextU32()).toBe(661307974)
		local f = Rng.new(42)
		expect(f:next()).toBeNear(0.79533299096927135, 1e-15)
		expect(f:next()).toBeNear(0.82851652465322112, 1e-15)
	end)

	T.it("imul and hashString are exact 32-bit operations", function()
		expect(Rng.imul(0xFFFFFFFF, 0xFFFFFFFF)).toBe(1)
		expect(Rng.imul(0x9E3779B9, 0x85EBCA6B)).toBe(3238976083)
		expect(Rng.hashString("abc")).toBe(440920331)
	end)

	T.it("same seed, same sequence; different seeds differ", function()
		local a, b, c = Rng.new("x"), Rng.new("x"), Rng.new("y")
		local sameAll, anyDiff = true, false
		for _ = 1, 100 do
			local va, vb, vc = a:next(), b:next(), c:next()
			sameAll = sameAll and va == vb
			anyDiff = anyDiff or va ~= vc
		end
		expect(sameAll).toBe(true)
		expect(anyDiff).toBe(true)
	end)

	T.it("fork depends on the seed and label, not on draws already taken", function()
		local a = Rng.new("root")
		local b = Rng.new("root")
		for _ = 1, 50 do
			b:next()
		end
		expect(a:fork("p1"):next()).toBe(b:fork("p1"):next())
		expect(a:fork("p1"):next()).never.toBe(a:fork("p2"):next())
	end)

	T.it("next() is in [0, 1) and roughly uniform", function()
		local r = Rng.new("uniform")
		local buckets = table.create(10, 0)
		for _ = 1, 20000 do
			local v = r:next()
			expect(v >= 0 and v < 1).toBe(true)
			local i = math.floor(v * 10) + 1
			buckets[i] += 1
		end
		for _, count in buckets do
			expect(count).toBeGreaterThan(1800)
			expect(count).toBeLessThan(2200)
		end
	end)

	T.it("int is inclusive and covers the range", function()
		local r = Rng.new("dice")
		local seen = {}
		for _ = 1, 600 do
			local v = r:int(1, 6)
			expect(v >= 1 and v <= 6 and v == math.floor(v)).toBe(true)
			seen[v] = true
		end
		for face = 1, 6 do
			expect(seen[face]).toBe(true)
		end
	end)

	T.it("weighted respects weights and ignores table order", function()
		local r = Rng.new("weights")
		local counts = { a = 0, b = 0, c = 0 }
		for _ = 1, 10000 do
			local k = r:weighted({ a = 1, b = 3, c = 0 })
			counts[k] += 1
		end
		expect(counts.c).toBe(0)
		expect(counts.b / counts.a).toBeNear(3, 0.3)
		-- Same seed, keys inserted in a different order: same picks.
		local x, y = Rng.new("order"), Rng.new("order")
		local w1: { [string]: number } = {}
		w1.p = 1
		w1.q = 2
		local w2: { [string]: number } = {}
		w2.q = 2
		w2.p = 1
		for _ = 1, 20 do
			expect(x:weighted(w1)).toBe(y:weighted(w2))
		end
	end)

	T.it("normal has the requested mean and spread", function()
		local r = Rng.new("normal")
		local values = {}
		for i = 1, 5000 do
			values[i] = r:normal(10, 2)
		end
		expect(Sim.Stats.mean(values)).toBeNear(10, 0.1)
		expect(Sim.Stats.stddev(values)).toBeNear(2, 0.1)
	end)

	T.it("shuffle is a permutation; clone continues identically", function()
		local r = Rng.new("shuffle")
		local list = r:shuffle({ 1, 2, 3, 4, 5, 6, 7, 8 })
		local sortedList = table.clone(list)
		table.sort(sortedList)
		expect(sortedList).toEqual({ 1, 2, 3, 4, 5, 6, 7, 8 })
		local copy = r:clone()
		expect(copy:nextU32()).toBe(r:nextU32())
	end)
end)
