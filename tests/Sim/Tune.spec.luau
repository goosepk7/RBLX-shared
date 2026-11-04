--!strict
local T = require("@shared/Test")
local Sim = require("@shared/Sim")
local expect = T.expect

T.describe("Sim.Tune.solve", function()
	T.it("leaves a passing value alone", function()
		local r = Sim.Tune.solve({
			name = "x",
			min = 0,
			max = 10,
			current = 5,
			evaluate = function(x)
				return x * 2
			end,
			target = { max = 20 },
		})
		expect(r.ok).toBe(true)
		expect(r.changed).toBe(false)
	end)

	T.it("finds the minimal change for a decreasing metric", function()
		-- metric = 100 / x; want <= 10 -> x >= 10. Current 4.
		local r = Sim.Tune.solve({
			name = "rate",
			min = 1,
			max = 50,
			current = 4,
			step = 0.5,
			evaluate = function(x)
				return 100 / x
			end,
			target = { max = 10 },
		})
		expect(r.ok).toBe(true)
		expect(r.value).toBe(10)
		expect(r.metric).toBe(10)
	end)

	T.it("handles increasing metrics and min targets", function()
		-- metric = x^2; want >= 50 -> x >= 7.07. Current 2.
		local r = Sim.Tune.solve({
			name = "x",
			min = 0,
			max = 10,
			current = 2,
			step = 0.1,
			evaluate = function(x)
				return x * x
			end,
			target = { min = 50 },
		})
		expect(r.ok).toBe(true)
		expect(r.value).toBeNear(7.1, 1e-9)
	end)

	T.it("band targets: lands on the near edge when the far end overshoots the band", function()
		-- metric = 10x; want 400..450. Current 1 (10); the far end (100 -> 1000) overshoots.
		local up = Sim.Tune.solve({
			name = "x",
			min = 0,
			max = 100,
			current = 1,
			step = 0.5,
			evaluate = function(x)
				return 10 * x
			end,
			target = { min = 400, max = 450 },
		})
		expect(up.ok).toBe(true)
		expect(up.value).toBe(40)
		expect(up.metric).toBe(400)

		-- Decreasing: metric = 1000 / x; want 40..50. Current 1 (1000); far end 100 -> 10.
		local down = Sim.Tune.solve({
			name = "y",
			min = 1,
			max = 100,
			current = 1,
			step = 0.5,
			evaluate = function(x)
				return 1000 / x
			end,
			target = { min = 40, max = 50 },
		})
		expect(down.ok).toBe(true)
		expect(down.value).toBe(20)
		expect(down.metric).toBe(50)

		-- minimalChange = false still has to bisect when the far end is outside the band.
		local far = Sim.Tune.solve({
			name = "z",
			min = 0,
			max = 100,
			current = 1,
			minimalChange = false,
			evaluate = function(x)
				return 10 * x
			end,
			target = { min = 400, max = 450 },
		})
		expect(far.ok).toBe(true)
		expect(far.metric >= 400 and far.metric <= 450).toBe(true)
	end)

	T.it("band targets: reports a metric that jumps over the whole band", function()
		local r = Sim.Tune.solve({
			name = "gate",
			min = 0,
			max = 10,
			current = 1,
			evaluate = function(x)
				return if x < 5 then 0 else 100
			end,
			target = { min = 40, max = 60 },
		})
		expect(r.ok).toBe(false)
		expect(r.changed).toBe(false)
		expect(r.reason).toContain("jumps over the band")
	end)

	T.it("reports when bounds cannot reach the target, and never exceeds them", function()
		local evaluated: { number } = {}
		local r = Sim.Tune.solve({
			name = "cost",
			min = 10,
			max = 20,
			current = 15,
			evaluate = function(x)
				table.insert(evaluated, x)
				return x
			end,
			target = { max = 5 },
		})
		expect(r.ok).toBe(false)
		expect(r.changed).toBe(false)
		expect(r.reason).toContain("cannot reach target")
		for _, x in evaluated do
			expect(x >= 10 and x <= 20).toBe(true)
		end
		expect(Sim.Tune.describe({ r })).toContain("cannot fix within bounds")
	end)
end)

T.describe("Sim.Runner", function()
	T.it("runs a definition, collects targets, and catches errors", function()
		local lines: { string } = {}
		local ok = Sim.Runner.run(
			Sim.Runner.define({
				name = "demo.pass",
				seed = "s",
				run = function(ctx)
					ctx.recorder:set("v", ctx.rng:int(1, 1))
					ctx.targets:check("v", ctx.recorder:get("v"), { min = 1, max = 1 })
				end,
			}),
			{
				output = function(line)
					table.insert(lines, line)
				end,
			}
		)
		expect(ok.ok).toBe(true)
		expect(lines[1]).toMatch("^%[SIM PASS%] demo.pass")

		local broken = Sim.Runner.run(
			Sim.Runner.define({
				name = "demo.error",
				run = function()
					error("model exploded")
				end,
			}),
			{ quiet = true }
		)
		expect(broken.ok).toBe(false)
		expect(broken.error).toContain("model exploded")
	end)

	T.it("runAll filters and serializes to plain data", function()
		local defs = {
			Sim.Runner.define({
				name = "a.one",
				run = function(ctx)
					ctx.targets:check("t", 1, { max = 0 })
				end,
			}),
			Sim.Runner.define({ name = "b.two", run = function() end }),
		}
		local summary = Sim.Runner.runAll(defs, { quiet = true })
		expect(summary.passed).toBe(1)
		expect(summary.failed).toBe(1)
		local data = Sim.Runner.serialize(summary)
		expect(data.ok).toBe(false)
		expect(data.results[1].targets[1].ok).toBe(false)
		-- JSON-able (no functions or recorder objects)
		expect(type(Sim.Json.encode(data))).toBe("string")
		local only = Sim.Runner.runAll(defs, { quiet = true }, "b.")
		expect(#only.results).toBe(1)
		local entry = Sim.Runner.entryPoints(defs)
		expect(type(entry.openCloud)).toBe("function")
	end)
end)
