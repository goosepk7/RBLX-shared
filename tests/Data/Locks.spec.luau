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

T.describe("Data.Store session locks", function()
	T.it("asks the owner to release, and the owner hands over at once", function()
		local world = World.new()
		local a, b = world:server("A"), world:server("B")
		a.store:bindPlayers()
		b.store:bindPlayers()
		local onA = a:join(1)
		local profileA = a.store:get(onA)
		assert(profileA, "expected A to load")
		profileA.data.coins = 77 -- not saved yet
		world.clock:advance(10)

		-- The player teleports to B before A noticed they left.
		local onB = b:join(1)
		expect(onA:wasKicked()).toBe(true)
		expect(onA:kickMessage()).toContain("another server")
		expect(profileA:isActive()).toBe(false)
		expect(world.messaging.published).toBe(1)

		-- B tries again after lockRetryInterval and takes the released lock.
		world.clock:advance(5)
		local profileB = b.store:get(onB)
		assert(profileB, "expected B to load")
		expect(profileB.data.coins).toBe(77)
		expect(world:stored(1).meta.session.sessionId).toBe("session-B")
		expect(world:stored(1).meta.forceRelease).toBeNil()
		expect(a:counters().counters.forceReleases).toBe(1)
		expect(b:counters().counters.lockWaits).toBe(1)
		expect(b:counters().counters.locksStolen).toBe(0)
		expect(onB:wasKicked()).toBe(false)
	end)

	T.it("hands over with the last good save when its own data can't be stored", function()
		local world = World.new()
		local a, b = world:server("A"), world:server("B")
		a.store:bindPlayers()
		b.store:bindPlayers()
		local onA = a:join(1)
		local profileA = a.store:get(onA)
		assert(profileA, "expected A to load")
		profileA.data.coins = 5
		assert(profileA:saveAsync(), "expected A's save to work")
		profileA.data.coins = 6
		profileA.data.position = { x = 0 / 0 }
		local onB = b:join(1)
		expect(onA:wasKicked()).toBe(true)
		world.clock:advance(5)
		local profileB = b.store:get(onB)
		assert(profileB, "expected B to load")
		expect(profileB.data.coins).toBe(5)
		expect(profileB.data.position).toBeNil()
		expect(b:counters().counters.locksStolen).toBe(0)
		expect(a:counters().counters.unstorable).toBe(1)
	end)

	T.it("without MessagingService, the owner answers on its next autosave", function()
		local world = World.new()
		local a = world:server("A", { messagingService = false })
		local b = world:server("B", { messagingService = false })
		a.store:bindPlayers()
		b.store:bindPlayers()
		local onA = a:join(1)
		local profileA = a.store:get(onA)
		assert(profileA, "expected A to load")
		world.clock:advance(30)
		profileA.data.coins = 8
		local onB = b:join(1)
		expect(world:stored(1).meta.forceRelease.sessionId).toBe("session-B")
		expect(onA:wasKicked()).toBe(false)
		-- A's autosave at 60 s sees the request and hands over, long before B would take it (120 s).
		world.clock:advance(30)
		expect(onA:wasKicked()).toBe(true)
		world.clock:advance(5)
		local profileB = b.store:get(onB)
		assert(profileB, "expected B to load")
		expect(profileB.data.coins).toBe(8)
		expect(b:counters().counters.locksStolen).toBe(0)
	end)

	T.it("never takes the lock before the owner's next autosave, so a lost ping loses nothing", function()
		-- The worst case for a lost ping: the request lands 1 s after the owner's autosave. The default
		-- wait (autosaveInterval + 30) has to outlast the owner's next one, whatever the interval.
		for _, interval in { 60, 120 } do
			local world = World.new()
			local options = { messagingService = false, autosaveInterval = interval }
			local a = world:server("A", options)
			local b = world:server("B", options)
			a.store:bindPlayers()
			b.store:bindPlayers()
			local onA = a:join(1)
			local profileA = a.store:get(onA)
			assert(profileA, "expected A to load")
			world.clock:advance(interval)
			expect(a:counters().counters.saves).toBe(1)
			world.clock:advance(1)
			profileA.data.coins = 42
			local onB = b:join(1)
			expect(world:stored(1).meta.forceRelease.sessionId).toBe("session-B")

			-- A answers from its next autosave; B takes the lock on its next try.
			world.clock:advance(interval + 10)
			expect(onA:wasKicked()).toBe(true)
			expect(a:counters().counters.forceReleases).toBe(1)
			local profileB = b.store:get(onB)
			assert(profileB, "expected B to load")
			expect(profileB.data.coins).toBe(42)
			expect(b:counters().counters.locksStolen).toBe(0)
			expect(world:stored(1).meta.session.sessionId).toBe("session-B")
		end
	end)

	T.it("takes the lock when the owner ignores the request for forceReleaseTimeout seconds", function()
		local world = World.new()
		-- A can't hear pings and only saves every 5 minutes: it holds the lock but won't answer.
		local a = world:server("A", { messagingService = false, autosaveInterval = 300 })
		local b = world:server("B", { autosaveInterval = 60, forceReleaseTimeout = 90 })
		a.store:bindPlayers()
		b.store:bindPlayers()
		local onA = a:join(1)
		local profileA = a.store:get(onA)
		assert(profileA, "expected A to load")
		profileA.data.coins = 10
		assert(profileA:saveAsync(), "expected A's save to work")
		world.clock:advance(10)

		local onB = b:join(1)
		world.clock:advance(89)
		expect(b.store:get(onB)).toBeNil()
		world.clock:advance(1)
		local profileB = b.store:get(onB)
		assert(profileB, "expected B to take the lock after 90 s")
		expect(profileB.data.coins).toBe(10)
		expect(b:counters().counters.locksStolen).toBe(1)

		-- A keeps playing on stale data; none of it may land on top of B's. A's next save is at 300 s.
		profileA.data.coins = 999
		profileB.data.coins = 11
		world.clock:advance(200)
		expect(profileA:isActive()).toBe(false)
		expect(onA:wasKicked()).toBe(true)
		expect(a:counters().counters.locksLost).toBe(1)
		local stored = world:stored(1)
		expect(stored.data.coins).toBe(11)
		expect(stored.meta.session.sessionId).toBe("session-B")
		expect(profileB:isActive()).toBe(true)
	end)

	T.it("takes a dead server's lock at once", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(4), { session = world:lock("crashed", 700) }))
		local b = world:server("B")
		local profile = b.store:loadAsync(b:join(1))
		assert(profile, "expected B to load")
		expect(profile.data.coins).toBe(4)
		expect(b:counters().counters.locksTakenFromDead).toBe(1)
		expect(b:counters().counters.lockWaits).toBe(0)
		expect(world.clock:clock()).toBe(0)
	end)

	T.it("gives up with 'locked' when it never gets its turn, without touching the data", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(4), { session = world:lock("Z") }))
		local b = world:server("B", { autosaveInterval = 60, forceReleaseTimeout = 90 })
		b.store:bindPlayers()
		-- A third server keeps replacing B's release request with its own, so B's never ages.
		-- B gives up forceReleaseTimeout + 60 s after it started.
		world.dss:setBeforeCommit(function(ctx)
			if ctx.attempt == 1 then
				local value = world:stored(1)
				value.meta.forceRelease = { sessionId = "session-C", requestedAt = world.clock:now() }
				world:seed(1, value)
			end
		end)
		local player = b:join(1)
		world.clock:advance(149)
		expect(player:wasKicked()).toBe(false)
		world.clock:advance(1)
		world.dss:setBeforeCommit(nil)
		expect(b.store:get(player)).toBeNil()
		expect(player:wasKicked()).toBe(true)
		expect(b:counters().loadFailuresByReason.locked).toBe(1)
		local stored = world:stored(1)
		expect(stored.meta.session.sessionId).toBe("session-Z")
		expect(stored.data.coins).toBe(4)
	end)

	T.it("a save that races a lock steal is cancelled, not written", function()
		local world = World.new()
		local a = world:server("A")
		a.store:bindPlayers()
		local onA = a:join(1)
		local profile = a.store:get(onA)
		assert(profile, "expected A to load")
		profile.data.coins = 5
		local reasons: { string } = {}
		profile.Released:Connect(function(reason: string)
			table.insert(reasons, reason)
		end)
		world.dss:setBeforeCommit(function(ctx)
			if ctx.attempt == 1 then
				-- Server B takes the lock while A's autosave is between its read and its commit.
				local stolen = world:stored(1)
				stolen.data.coins = 50
				stolen.meta.session = world:lock("B")
				world:seed(1, stolen)
			end
		end)
		world.clock:advance(60)
		world.dss:setBeforeCommit(nil)

		-- The transform ran again on B's value, saw the lock was gone and cancelled.
		expect(#world.dss:calls("UpdateAsync.conflict")).toBe(1)
		local stored = world:stored(1)
		expect(stored.data.coins).toBe(50)
		expect(stored.meta.session.sessionId).toBe("session-B")
		expect(reasons).toEqual({ "lockLost" })
		expect(profile:isActive()).toBe(false)
		expect(onA:wasKicked()).toBe(true)
		expect(a:counters().counters.locksLost).toBe(1)
		expect(world.clock:pending()).toBe(0)
	end)

	T.it("a load that races another server's load never overwrites it", function()
		local world = World.new()
		local a, b = world:server("A"), world:server("B")
		b.store:bindPlayers()
		local onB: any = nil
		world.dss:setBeforeCommit(function(ctx)
			if ctx.attempt == 1 and onB == nil then
				-- The player lands on B, loads and earns coins while A's create is in flight.
				onB = b:join(1)
				local profileB = b.store:get(onB)
				assert(profileB, "expected B to load")
				profileB.data.coins = 25
				assert(profileB:saveAsync(), "expected B's save to work")
			end
		end)
		local profileA = a.store:loadAsync(a:join(1))
		world.dss:setBeforeCommit(nil)

		-- A's create saw B's profile on the retry, asked B to release and took it over.
		assert(profileA, "expected A to load")
		expect(profileA.data.coins).toBe(25)
		expect(a:counters().counters.newProfiles).toBe(0)
		expect(b:counters().counters.newProfiles).toBe(1)
		expect(onB:wasKicked()).toBe(true)
		expect(world:stored(1).meta.session.sessionId).toBe("session-A")
		expect(world:stored(1).data.coins).toBe(25)
	end)

	T.it("a release request reaches the owner even when publishing fails", function()
		local world = World.new()
		local a, b = world:server("A"), world:server("B")
		a.store:bindPlayers()
		b.store:bindPlayers()
		local onA = a:join(1)
		world.clock:advance(50)
		world.messaging.failPublish = true
		local onB = b:join(1)
		expect(onA:wasKicked()).toBe(false)
		-- A's autosave at 60 s answers instead.
		world.clock:advance(15)
		expect(onA:wasKicked()).toBe(true)
		expect(b.store:get(onB)).never.toBeNil()
	end)

	T.it("ignores its own pings and pings for profiles it doesn't hold", function()
		local world = World.new()
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected A to load")
		local saves = a:counters().counters.saves
		world.messaging:PublishAsync("RBLXShared.Data.Profiles", { key = "Player_1", from = "session-A" })
		world.messaging:PublishAsync("RBLXShared.Data.Profiles", { key = "Player_2", from = "session-B" })
		world.messaging:PublishAsync("RBLXShared.Data.Profiles", "garbage")
		expect(a:counters().counters.saves).toBe(saves)
		expect(profile:isActive()).toBe(true)
	end)
end)
