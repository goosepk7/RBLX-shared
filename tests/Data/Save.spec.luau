--!strict
local Log = require("@shared/Util/Log")
local T = require("@shared/Test")
local World = require("./World")

local expect = T.expect

local logs: { Log.Entry } = {}
local restoreLog: () -> () = function() end
T.beforeEach(function()
	logs, restoreLog = Log.capture()
end)
T.afterEach(function()
	restoreLog()
end)

local function logged(level: Log.Level, text: string): boolean
	for _, entry in logs do
		if entry.level == level and string.find(entry.message, text, 1, true) then
			return true
		end
	end
	return false
end

T.describe("Data.Store saving", function()
	T.it("autosaves every 60 seconds and refreshes the lock's heartbeat", function()
		local world = World.new()
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		profile.data.coins = 10
		world.clock:advance(59)
		expect(world:stored(1).data.coins).toBe(0)
		world.clock:advance(1)
		local stored = world:stored(1)
		expect(stored.data.coins).toBe(10)
		expect(stored.meta.session.heartbeatAt).toBe(world.clock:now())
		expect(stored.meta.updatedAt).toBe(world.clock:now())
		profile.data.coins = 20
		world.clock:advance(60)
		expect(world:stored(1).data.coins).toBe(20)
		local diag = a:counters()
		expect(diag.counters.saves).toBe(2)
		expect(diag.profiles[1].saveCount).toBe(2)
		expect(diag.profiles[1].lastSaveAt).toBe(world.clock:now())
	end)

	T.it("keeps autosaving after a failed save", function()
		local world = World.new()
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		profile.data.coins = 3
		-- The autosave's three tries all fail; the next one a minute later goes through.
		world.dss:failNext("UpdateAsync", { times = 3 })
		world.clock:advance(64)
		expect(world:stored(1).data.coins).toBe(0)
		expect(a:counters().counters.saveFailures).toBe(1)
		expect(a:counters().profiles[1].failedSaves).toBe(1)
		world.clock:advance(60)
		expect(world:stored(1).data.coins).toBe(3)
		expect(profile:isActive()).toBe(true)
	end)

	T.it("saves on demand", function()
		local world = World.new()
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		profile.data.coins = 99
		local ok, err = profile:saveAsync()
		expect(ok).toBe(true)
		expect(err).toBeNil()
		expect(world:stored(1).data.coins).toBe(99)
	end)

	T.it("saves and hands back the lock when the player leaves", function()
		local world = World.new()
		local a = world:server("A")
		a.store:bindPlayers()
		local player = a:join(1)
		local profile = a.store:get(player)
		assert(profile, "expected a profile")
		profile.data.coins = 42
		local reasons: { string } = {}
		profile.Released:Connect(function(reason: string)
			table.insert(reasons, reason)
		end)
		a:leave(player)
		expect(reasons).toEqual({ "left" })
		local stored = world:stored(1)
		expect(stored.data.coins).toBe(42)
		expect(stored.meta.session).toBeNil()
		expect(a.store:get(player)).toBeNil()
		expect(profile:isActive()).toBe(false)
		expect(player:wasKicked()).toBe(false)
		-- No autosave is left behind for the released profile.
		expect(world.clock:pending()).toBe(0)
		-- Changes after the release are not saved.
		profile.data.coins = 1000
		local ok = profile:saveAsync()
		expect(ok).toBe(false)
		expect(world:stored(1).data.coins).toBe(42)
	end)

	T.it("keeps the lock and retries the release while the DataStore is down", function()
		local world = World.new()
		local a = world:server("A")
		local player = a:join(1)
		local profile = a.store:loadAsync(player)
		assert(profile, "expected a profile")
		profile.data.coins = 5
		world.dss:failNext("UpdateAsync", { times = 8 })
		-- Five tries over 15 seconds, all failing.
		local ok = a.store:releaseAsync(player)
		expect(ok).toBe(false)
		expect(profile:isActive()).toBe(true)
		expect(world:stored(1).meta.session.sessionId).toBe("session-A")
		-- The retry 10 seconds later gets through after three more failures.
		world.clock:advance(30)
		expect(profile:isActive()).toBe(false)
		local stored = world:stored(1)
		expect(stored.data.coins).toBe(5)
		expect(stored.meta.session).toBeNil()
		expect(world.clock:pending()).toBe(0)
	end)

	T.it("flushes every profile on BindToClose and refuses new loads", function()
		local world = World.new()
		local a = world:server("A")
		a.store:bindPlayers()
		local first, second = a:join(1), a:join(2)
		local p1, p2 = a.store:get(first), a.store:get(second)
		assert(p1 and p2, "expected two profiles")
		p1.data.coins = 1
		p2.data.coins = 2
		expect(#a.closers).toBe(1)
		-- One save fails twice before going through; shutdown waits for it.
		world.dss:failNext("UpdateAsync", { key = "Player_2", times = 2 })
		a.closers[1]()
		expect(world.clock:clock()).toBeLessThan(25)
		expect(world:stored(1).data.coins).toBe(1)
		expect(world:stored(2).data.coins).toBe(2)
		expect(world:stored(1).meta.session).toBeNil()
		expect(world:stored(2).meta.session).toBeNil()
		expect(first:wasKicked()).toBe(false)

		local third = a:join(3)
		expect(third:wasKicked()).toBe(false)
		local profile, err = a.store:loadAsync(third)
		expect(profile).toBeNil()
		expect(err).toBe("closing")
		expect(world:stored(3)).toBeNil()
		expect(a:counters().closing).toBe(true)
	end)

	T.it("gives up on shutdown after 25 seconds and says which profiles weren't saved", function()
		local world = World.new()
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		world.dss:failNext("UpdateAsync", { times = 100 })
		a.store:closeAsync()
		expect(world.clock:clock()).toBeNear(25, 0.3)
		expect(profile:isActive()).toBe(true)
		expect(logged("error", "1 profile(s) were not saved before shutdown")).toBe(true)
	end)

	T.it("never writes data a DataStore can't hold, and names the path", function()
		local world = World.new()
		local a = world:server("A")
		local player = a:join(1)
		local profile = a.store:loadAsync(player)
		assert(profile, "expected a profile")
		profile.data.coins = 5
		assert(profile:saveAsync(), "expected the first save to work")
		local version = world:version(1)

		profile.data.stats = { speed = 0 / 0 }
		local ok, err = profile:saveAsync()
		expect(ok).toBe(false)
		expect(err).toContain("data.stats.speed")
		expect(err).toContain("NaN")
		expect(world:version(1)).toBe(version)
		expect(logged("error", "data.stats.speed")).toBe(true)
		local diag = a:counters()
		expect(diag.counters.unstorable).toBe(1)
		expect(diag.profiles[1].lastError).toContain("data.stats.speed")

		-- Leaving still hands the lock back, keeping the last good save.
		profile.data.coins = 6
		local released = a.store:releaseAsync(player)
		expect(released).toBe(false)
		expect(profile:isActive()).toBe(false)
		local stored = world:stored(1)
		expect(stored.meta.session).toBeNil()
		expect(stored.data.coins).toBe(5)
		expect(stored.data.stats).toBeNil()
	end)

	T.it("checks the data that is actually written, even if it changes during a retry", function()
		local world = World.new()
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		profile.data.coins = 5
		-- The autosave's first try fails and backs off for a second; the game writes NaN meanwhile.
		world.dss:failNext("UpdateAsync", { times = 1 })
		world.clock:advance(60)
		profile.data.speed = 0 / 0
		world.clock:advance(1)
		local stored = world:stored(1)
		expect(stored.data.coins).toBe(0)
		expect(stored.data.speed).toBeNil()
		local diag = a:counters()
		expect(diag.counters.unstorable).toBe(1)
		expect(diag.profiles[1].lastError).toContain("data.speed")
	end)

	T.it("refuses mixed tables before the DataStore would mangle them", function()
		local world = World.new()
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		local mixed: any = { "sword" }
		mixed.equipped = "sword"
		profile.data.inventory = mixed
		local ok, err = profile:saveAsync()
		expect(ok).toBe(false)
		expect(err).toContain("data.inventory")
		expect(err).toContain("mixes")
	end)

	T.it("warns once when a profile passes half the size limit", function()
		local world = World.new()
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		profile.data.blob = string.rep("x", 2_200_000)
		assert(profile:saveAsync(), "expected the save to work")
		assert(profile:saveAsync(), "expected the save to work")
		local warnings = 0
		for _, entry in logs do
			if entry.level == "warn" and string.find(entry.message, "half the 4 MB", 1, true) then
				warnings += 1
			end
		end
		expect(warnings).toBe(1)
		expect(a:counters().profiles[1].sizeShare).toBeGreaterThan(0.5)

		profile.data.blob = string.rep("x", 4_200_000)
		local ok, err = profile:saveAsync()
		expect(ok).toBe(false)
		expect(err).toContain("4 MB")
	end)

	T.it("hands the lock straight back when the player leaves during the load", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(3)))
		local a = world:server("A")
		a.store:bindPlayers()
		-- The load backs off for a second; the player leaves meanwhile.
		world.dss:failNext("UpdateAsync", { times = 1 })
		local player = a:join(1)
		a:leave(player)
		world.clock:advance(2)
		expect(a.store:get(player)).toBeNil()
		local stored = world:stored(1)
		expect(stored.meta.session).toBeNil()
		expect(stored.data.coins).toBe(3)
		expect(a:counters().counters.loadFailures).toBe(0)
	end)

	T.it("lets a quick rejoin wait for the old session to hand back", function()
		local world = World.new()
		local a = world:server("A")
		a.store:bindPlayers()
		local first = a:join(1)
		local old = a.store:get(first)
		assert(old, "expected a profile")
		old.data.coins = 9
		-- The release backs off for a second, and the player is already back.
		world.dss:failNext("UpdateAsync", { times = 1 })
		a:leave(first)
		local second = a:join(1)
		world.clock:advance(2)
		local profile = a.store:get(second)
		assert(profile, "expected the rejoin to load")
		expect(profile).never.toBe(old)
		expect(profile.data.coins).toBe(9)
		expect(old:isActive()).toBe(false)
		expect(world:stored(1).meta.session.sessionId).toBe("session-A")
	end)
end)
