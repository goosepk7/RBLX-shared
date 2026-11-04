--!strict
local Log = require("@shared/Util/Log")
local T = require("@shared/Test")
local World = require("./World")

local expect = T.expect

local restoreLog: () -> () = function() end
T.beforeEach(function()
	local _
	_, restoreLog = Log.capture()
end)
T.afterEach(function()
	restoreLog()
end)

local PLAYERS = 12

T.describe("Data.Store request budgets", function()
	T.it("a full 12-player server stays inside its budget over 10 minutes of autosave", function()
		local world = World.new()
		world.dss:enableBudgets({ players = PLAYERS })
		local a = world:server("A")
		a.store:bindPlayers()
		local everyone: { any } = {}
		for userId = 1, PLAYERS do
			table.insert(everyone, a:join(userId))
		end
		local lowest = math.huge
		for _ = 1, 10 do
			for _, player in everyone do
				local profile = a.store:get(player)
				assert(profile, "expected every player to stay loaded")
				profile.data.coins += 1
			end
			for _ = 1, 60 do
				world.clock:advance(1)
				lowest = math.min(lowest, world.dss:GetRequestBudgetForRequestType("SetIncrementAsync"))
			end
		end
		for _, player in everyone do
			a:leave(player)
		end

		local diag = a:counters()
		-- One load, ten autosaves and one release per player, with nothing throttled or retried.
		expect(diag.counters.loads).toBe(PLAYERS)
		expect(diag.counters.saves).toBe(PLAYERS * 11)
		expect(diag.counters.retries).toBe(0)
		expect(diag.counters.saveFailures).toBe(0)
		for _, call in world.dss:calls() do
			expect(call.ok).toBe(true)
		end
		-- 180 requests a minute for 12 players; autosave uses 12 of them.
		expect(lowest).toBeGreaterThan(150)
		for userId = 1, PLAYERS do
			local stored = world:stored(userId)
			expect(stored.data.coins).toBe(10)
			expect(stored.meta.session).toBeNil()
		end
	end)

	T.it("a join wave and a mass leave fit in the same budget", function()
		local world = World.new()
		world.dss:enableBudgets({ players = PLAYERS })
		local a = world:server("A")
		a.store:bindPlayers()
		local everyone: { any } = {}
		for userId = 1, PLAYERS do
			table.insert(everyone, a:join(userId))
		end
		world.clock:advance(60)
		for _, player in everyone do
			a:leave(player)
		end
		local b = world:server("B")
		b.store:bindPlayers()
		for userId = 1, PLAYERS do
			b:join(userId)
		end
		b.closers[1]()
		expect(a:counters().counters.retries).toBe(0)
		expect(b:counters().counters.retries).toBe(0)
		expect(b:counters().counters.loads).toBe(PLAYERS)
		for userId = 1, PLAYERS do
			expect(world:stored(userId).meta.session).toBeNil()
		end
	end)

	T.it("backs off when throttled and succeeds once the budget refills", function()
		local world = World.new()
		world.dss:enableBudgets({ players = 1 })
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		profile.data.coins = 3
		-- The server spent its budget elsewhere.
		world.dss:setBudget(0)
		local ok = profile:saveAsync()
		expect(ok).toBe(true)
		expect(world:stored(1).data.coins).toBe(3)
		local diag = a:counters()
		expect(diag.counters.retries).toBe(1)
		expect(diag.recentErrors[1].message).toContain("throttled")
		expect(diag.budgets.GetAsync).toBeType("number")
		expect(diag.budgets.UpdateAsync).toBe(math.min(diag.budgets.GetAsync, diag.budgets.SetIncrementAsync))
	end)
end)
