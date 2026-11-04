--!strict
local Net = require("@shared/Net")
local T = require("@shared/Test")

local expect = T.expect

T.describe("Net.RateLimiter", function()
	T.it("allows the burst immediately, then refills at the rate", function()
		local clock = T.Clock.new()
		local limiter = Net.RateLimiter.new({ rate = 2, burst = 3 }, function()
			return clock:clock()
		end)
		expect(limiter:allow("p")).toBe(true)
		expect(limiter:allow("p")).toBe(true)
		expect(limiter:allow("p")).toBe(true)
		expect(limiter:allow("p")).toBe(false)
		clock:advance(0.5) -- one token at 2/s
		expect(limiter:allow("p")).toBe(true)
		expect(limiter:allow("p")).toBe(false)
		clock:advance(10) -- refill caps at burst
		expect(limiter:available("p")).toBe(3)
	end)

	T.it("keeps keys independent and forgets removed keys", function()
		local clock = T.Clock.new()
		local limiter = Net.RateLimiter.new({ rate = 1, burst = 1 }, function()
			return clock:clock()
		end)
		expect(limiter:allow("a")).toBe(true)
		expect(limiter:allow("a")).toBe(false)
		expect(limiter:allow("b")).toBe(true)
		limiter:remove("a")
		expect(limiter:allow("a")).toBe(true)
	end)

	T.it("supports weighted costs", function()
		local limiter = Net.RateLimiter.new({ rate = 1, burst = 5 }, function()
			return 0
		end)
		expect(limiter:allow("p", 4)).toBe(true)
		expect(limiter:allow("p", 2)).toBe(false)
		expect(limiter:allow("p", 1)).toBe(true)
	end)

	T.it("rejects nonsense limits", function()
		expect(function()
			Net.RateLimiter.new({ rate = 0, burst = 1 }, os.clock)
		end).toThrow("rate")
		expect(function()
			Net.RateLimiter.new({ rate = 1, burst = 0 }, os.clock)
		end).toThrow("burst")
	end)
end)
