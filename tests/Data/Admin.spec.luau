--!strict
local Data = require("@shared/Data")
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

T.describe("Data.Store support tools", function()
	T.it("viewAsync reads a stored profile without locking it", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(5)))
		local a = world:server("A")
		local doc = a.store:viewAsync(1)
		assert(doc, "expected a document")
		expect(doc.data.coins).toBe(5)
		expect(world:stored(1).meta.session).toBeNil()
		local missing, err = a.store:viewAsync(2)
		expect(missing).toBeNil()
		expect(err).toBeNil()
		world.dss:failNext("GetAsync", { code = 403 })
		local _, failed = a.store:viewAsync(1)
		expect(failed).toContain("403")
	end)

	T.it("updateOfflineAsync edits an offline player's save", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(5)))
		local a = world:server("A")
		local ok, err = a.store:updateOfflineAsync(1, function(data: any): boolean?
			data.coins += 50 -- a support refund
			return nil
		end)
		expect(ok).toBe(true)
		expect(err).toBeNil()
		expect(world:stored(1).data.coins).toBe(55)
		expect(world:stored(1).meta.updatedAt).toBe(world.clock:now())
	end)

	T.it("updateOfflineAsync migrates first and refuses what it can't safely change", function()
		local world = World.new()
		local a = world:server("A", {
			version = 2,
			migrations = {
				[2] = function(data: any)
					data.gems = 0
					return nil
				end,
			},
		})
		world:seed(1, World.document(World.progress(5)))
		expect((a.store:updateOfflineAsync(1, function(data: any): boolean?
			data.gems += 1
			return nil
		end))).toBe(true)
		local stored = world:stored(1)
		expect(stored.data.gems).toBe(1)
		expect(stored.meta.schemaVersion).toBe(2)

		local function noop(): boolean?
			return nil
		end
		local _, missing = a.store:updateOfflineAsync(2, noop)
		expect(missing).toBe("notFound")
		world:seed(3, World.document(World.progress(1), { session = world:lock("B", 30) }))
		local _, locked = a.store:updateOfflineAsync(3, noop)
		expect(locked).toContain("locked")
		world:seed(4, World.document(World.progress(1), { schemaVersion = 9 }))
		local _, newer = a.store:updateOfflineAsync(4, noop)
		expect(newer).toBe("newerVersion")
		world:seed(5, "not a profile")
		local _, corrupt = a.store:updateOfflineAsync(5, noop)
		expect(corrupt).toContain("corrupt")
		local _, cancelled = a.store:updateOfflineAsync(1, function(): boolean?
			return false
		end)
		expect(cancelled).toBe("cancelled")
		local _, errored = a.store:updateOfflineAsync(1, function(): boolean?
			error("bad edit")
		end)
		expect(errored).toContain("bad edit")
		expect(world:stored(1).data.gems).toBe(1)
	end)

	T.it("updateOfflineAsync refuses an edit that can't be stored", function()
		local world = World.new()
		local a = world:server("A")
		world:seed(1, World.document(World.progress(5)))
		local before = world:version(1)
		local ok, err = a.store:updateOfflineAsync(1, function(data: any): boolean?
			data.coins = 0 / 0
			return nil
		end)
		expect(ok).toBe(false)
		expect(err).toContain("data.coins")
		expect(world:version(1)).toBe(before)
	end)

	T.it("updateOfflineAsync takes a dead server's lock into account", function()
		local world = World.new()
		local a = world:server("A")
		world:seed(1, World.document(World.progress(5), { session = world:lock("crashed", 700) }))
		local ok = a.store:updateOfflineAsync(1, function(data: any): boolean?
			data.coins = 6
			return nil
		end)
		expect(ok).toBe(true)
		expect(world:stored(1).data.coins).toBe(6)
	end)

	T.it("updateOfflineAsync edits a profile loaded in this server in memory, then saves", function()
		local world = World.new()
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		local ok = a.store:updateOfflineAsync(1, function(data: any): boolean?
			data.coins = 70
			return nil
		end)
		expect(ok).toBe(true)
		expect(profile.data.coins).toBe(70)
		expect(world:stored(1).data.coins).toBe(70)
		expect(world:stored(1).meta.session.sessionId).toBe("session-A")
	end)

	T.it("removeAsync erases the save and releases a loaded profile", function()
		local world = World.new()
		local a = world:server("A")
		a.store:bindPlayers()
		local player = a:join(1)
		local profile = a.store:get(player)
		assert(profile, "expected a profile")
		local ok = a.store:removeAsync(1)
		expect(ok).toBe(true)
		expect(world:stored(1)).toBeNil()
		expect(profile:isActive()).toBe(false)
		expect(player:wasKicked()).toBe(true)
		expect(player:kickMessage()).toContain("removed")
		-- Nothing writes it back afterwards.
		world.clock:advance(120)
		expect(world:stored(1)).toBeNil()
	end)
end)

T.describe("Data diagnostics", function()
	T.it("reports loaded profiles, counters, recent errors and budgets", function()
		local world = World.new()
		local a = world:server("A", { name = "Diag_Profiles" })
		local profile = a.store:loadAsync(a:join(2))
		assert(profile, "expected a profile")
		a.store:loadAsync(a:join(1))
		world.dss:failNext("UpdateAsync", { times = 1 })
		assert(profile:saveAsync(), "expected the save to work after a retry")

		local diag = a:counters()
		expect(diag.name).toBe("Diag_Profiles")
		expect(diag.scope).toBe("global")
		expect(diag.sessionId).toBe("session-A")
		expect(diag.version).toBe(1)
		expect(diag.autosaveInterval).toBe(60)
		expect(diag.loaded).toBe(2)
		expect(diag.loading).toBe(0)
		expect(diag.profiles[1].userId).toBe(1)
		expect(diag.profiles[2].userId).toBe(2)
		local entry = diag.profiles[2]
		expect(entry.key).toBe("Player_2")
		expect(entry.saveCount).toBe(1)
		expect(entry.size).toBeGreaterThan(10)
		expect(entry.sizeShare).toBeLessThan(0.001)
		expect(entry.schemaVersion).toBe(1)
		expect(entry.loadCount).toBe(1)
		expect(entry.releasing).toBe(false)
		expect(diag.counters.retries).toBe(1)
		expect(#diag.recentErrors).toBe(1)
		expect(diag.recentErrors[1].op).toBe("save")
		expect(diag.recentErrors[1].key).toBe("Player_2")
		expect(diag.budgets.GetAsync).toBeType("number")

		-- Diagnostics are a snapshot the panel can't use to change the store.
		diag.counters.saves = 1000
		expect(a:counters().counters.saves).toBe(1)

		local found = false
		for _, store in Data.getDiagnostics() do
			if store.name == "Diag_Profiles" then
				found = true
			end
		end
		expect(found).toBe(true)
	end)

	T.it("keeps only the 20 most recent errors", function()
		local world = World.new()
		local a = world:server("A")
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		world.dss:failNext("UpdateAsync", { times = 30 })
		for _ = 1, 10 do
			profile:saveAsync()
		end
		local errors = a:counters().recentErrors
		expect(#errors).toBe(20)
		expect(errors[#errors].at).toBe(world.clock:now())
	end)
end)
