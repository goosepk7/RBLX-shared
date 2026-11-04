--!strict
local T = require("@shared/Test")
local Sim = require("@shared/Sim")
local expect = T.expect

T.describe("Sim.Scheduler", function()
	T.it("fires events in time order, ties in insertion order", function()
		local s = Sim.Scheduler.new()
		local log: { string } = {}
		s:at(5, function()
			table.insert(log, "a5")
		end)
		s:at(1, function()
			table.insert(log, "b1")
		end)
		s:at(5, function()
			table.insert(log, "c5")
		end)
		s:runAll()
		expect(log).toEqual({ "b1", "a5", "c5" })
		expect(s:now()).toBe(5)
	end)

	T.it("every() repeats with count and untilTime, and can be cancelled", function()
		local s = Sim.Scheduler.new()
		local times: { number } = {}
		s:every(10, function(now)
			table.insert(times, now)
		end, { count = 3 })
		local other = 0
		local handle = s:every(1, function()
			other += 1
		end, { untilTime = 100 })
		s:runUntil(4.5)
		handle:cancel()
		s:runUntil(1000)
		expect(times).toEqual({ 10, 20, 30 })
		expect(other).toBe(4)
		expect(s:pending()).toBe(0)
	end)

	T.it("events can schedule more events; runUntil stops at the horizon", function()
		local s = Sim.Scheduler.new()
		local count = 0
		local function tick()
			count += 1
			s:after(60, tick)
		end
		s:after(60, tick)
		s:runUntil(3600)
		expect(count).toBe(60)
		expect(s:now()).toBe(3600)
	end)

	T.it("handles many events efficiently and deterministically", function()
		local rng = Sim.Rng.new("sched")
		local s = Sim.Scheduler.new()
		local lastTime = -1
		local ordered = true
		for _ = 1, 20000 do
			s:at(rng:range(0, 1000), function(now)
				ordered = ordered and now >= lastTime
				lastTime = now
			end)
		end
		expect(s:runAll()).toBe(20000)
		expect(ordered).toBe(true)
	end)

	T.it("fixedStep uses integer steps without drift", function()
		local last = 0
		local steps = Sim.Scheduler.fixedStep(0.1, 1000, function(t)
			last = t
			return nil
		end)
		expect(steps).toBe(10000)
		expect(last).toBeNear(999.9, 1e-9)
		local early = Sim.Scheduler.fixedStep(1, 100, function(t)
			return t < 4
		end)
		expect(early).toBe(5)
	end)
end)
