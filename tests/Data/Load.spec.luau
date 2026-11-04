--!strict
local Data = require("@shared/Data")
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

T.describe("Data.Store loading", function()
	T.it("creates a profile only when a successful read finds nothing", function()
		local world = World.new()
		local a = world:server("A")
		local profile, err = a.store:loadAsync(a:join(1))
		expect(err).toBeNil()
		assert(profile, "expected a profile")
		expect(profile.data).toEqual(World.TEMPLATE)
		expect(profile.key).toBe("Player_1")
		expect(profile:isActive()).toBe(true)

		-- Each player gets their own copy of the template.
		profile.data.inventory[1] = "sword"
		local other = a.store:loadAsync(a:join(2))
		assert(other, "expected a second profile")
		expect(#other.data.inventory).toBe(0)

		local stored = world:stored(1)
		expect(stored.meta.session.sessionId).toBe("session-A")
		expect(stored.meta.loadCount).toBe(1)
		expect(stored.meta.schemaVersion).toBe(1)
		expect(a:counters().counters.newProfiles).toBe(2)
	end)

	T.it("loads existing data, counts the load and takes the lock", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(500), { loadCount = 4 }))
		local a = world:server("A")
		local player = a:join(1)
		local profile = a.store:loadAsync(player)
		assert(profile, "expected a profile")
		expect(profile.data).toEqual(World.progress(500))
		local stored = world:stored(1)
		expect(stored.meta.loadCount).toBe(5)
		expect(stored.meta.session.sessionId).toBe("session-A")
		expect(stored.meta.createdAt).toBe(1_699_000_000)
		expect(a:counters().counters.newProfiles).toBe(0)
		-- Loading again in the same server returns the same profile without another request.
		local calls = #world.dss:calls("UpdateAsync")
		expect((a.store:loadAsync(player))).toBe(profile)
		expect(#world.dss:calls("UpdateAsync")).toBe(calls)
	end)

	T.it("treats a failed read as a failed load, never as a new player", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(500)))
		local before = world:version(1)
		local a = world:server("A")
		a.store:bindPlayers()
		world.dss:failNext("UpdateAsync", { code = 502, times = 5 })
		local player = a:join(1)
		-- The load retries after 1, 2, 4 and 8 seconds, then gives up.
		world.clock:advance(14)
		expect(player:wasKicked()).toBe(false)
		world.clock:advance(1)
		expect(player:wasKicked()).toBe(true)
		expect(player:kickMessage()).toContain("Nothing was lost")
		expect(a.store:get(player)).toBeNil()
		expect(world:version(1)).toBe(before)
		expect(world:stored(1).data.coins).toBe(500)
		local diag = a:counters()
		expect(diag.counters.loadFailures).toBe(1)
		expect(diag.loadFailuresByReason.dataStore).toBe(1)
		expect(diag.counters.newProfiles).toBe(0)
		expect(diag.counters.retries).toBe(4)
		expect(logged("error", "failed to load")).toBe(true)
	end)

	T.it("never creates a profile for a new player whose read failed", function()
		local world = World.new()
		local a = world:server("A")
		world.dss:failNext("UpdateAsync", { code = 502, times = 5 })
		local profile, err = a.store:loadAsync(a:join(1))
		expect(profile).toBeNil()
		expect(err).toBe("dataStore")
		expect(world:stored(1)).toBeNil()
	end)

	T.it("retries a flaky DataStore with backoff and loads the saved data", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(500)))
		local a = world:server("A")
		world.dss:failNext("UpdateAsync", { code = 301, times = 2 })
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		expect(profile.data.coins).toBe(500)
		-- 1 s then 2 s of backoff.
		expect(world.clock:clock()).toBe(3)
		expect(a:counters().counters.retries).toBe(2)
	end)

	T.it("stops at once on errors a retry can't fix", function()
		local world = World.new()
		local a = world:server("A")
		world.dss:failNext("UpdateAsync", { code = 403, message = "Cannot write to DataStore from Studio" })
		local profile, err = a.store:loadAsync(a:join(1))
		expect(profile).toBeNil()
		expect(err).toBe("dataStore")
		expect(world.clock:clock()).toBe(0)
		expect(#world.dss:calls("UpdateAsync")).toBe(1)
		expect(Data.isRetryable("403: Cannot write to DataStore from Studio")).toBe(false)
		expect(Data.isRetryable("502: API Services rejected request")).toBe(true)
		expect(Data.isRetryable("no code at all")).toBe(true)
	end)

	T.it("loads players who were already in the server when bound", function()
		local world = World.new()
		local a = world:server("A")
		local early = a:join(1)
		a.store:bindPlayers()
		expect(a.store:isLoaded(early)).toBe(true)
		local late = a:join(2)
		local profile = a.store:waitForProfileAsync(late)
		assert(profile, "expected a profile")
		expect(profile.userId).toBe(2)
		local loaded: { number } = {}
		a.store.Loaded:Connect(function(player: any)
			table.insert(loaded, player.UserId)
		end)
		a:join(3)
		expect(loaded).toEqual({ 3 })
	end)

	T.it("waitForProfileAsync also waits when called before the load starts", function()
		local world = World.new()
		local a = world:server("A")
		local player = a:join(1)
		local got: any = nil
		world.clock.task.spawn(function()
			got = a.store:waitForProfileAsync(player)
		end)
		world.clock:advance(1)
		a.store:bindPlayers()
		world.clock:advance(1)
		expect(got).never.toBeNil()
		expect(got).toBe(a.store:get(player))
	end)

	T.it("shows a load as under way from its first yield", function()
		local world = World.new()
		-- MessagingService takes a second to subscribe, as it does in a real server.
		local subscribes = 0
		local slowMessaging = {
			SubscribeAsync = function(_self: any, topic: string, callback: (any) -> ())
				subscribes += 1
				world.clock.task.wait(1)
				return world.messaging:SubscribeAsync(topic, callback)
			end,
			PublishAsync = function(_self: any, topic: string, data: any)
				world.messaging:PublishAsync(topic, data)
			end,
		}
		local a = world:server("A", { messagingService = slowMessaging })
		a.store:bindPlayers()
		local player = a:join(1)
		expect(a:counters().loading).toBe(1)
		local decision = a.store:processReceipt({
			PlayerId = 1,
			ProductId = 1,
			PurchaseId = "early",
			CurrencySpent = 1,
			CurrencyType = "Robux",
			PlaceIdWherePurchased = 1,
		}, function(profile: any): boolean?
			profile.data.coins += 1
			return true
		end)
		expect(decision).toBe(world.mps.Decision.PurchaseGranted)
		expect(a.store:get(player)).never.toBeNil()
		a:join(2)
		expect(subscribes).toBe(1)
	end)

	T.it("subscribes again later when MessagingService was down at first", function()
		local world = World.new()
		local attempts = 0
		local flakyMessaging = {
			SubscribeAsync = function(_self: any, topic: string, callback: (any) -> ())
				attempts += 1
				if attempts == 1 then
					error("MessagingService is not available")
				end
				return world.messaging:SubscribeAsync(topic, callback)
			end,
			PublishAsync = function(_self: any, topic: string, data: any)
				world.messaging:PublishAsync(topic, data)
			end,
		}
		local a = world:server("A", { messagingService = flakyMessaging })
		a.store:loadAsync(a:join(1))
		expect(logged("warn", "release pings unavailable")).toBe(true)
		a.store:loadAsync(a:join(2))
		expect(attempts).toBe(1)
		world.clock:advance(60)
		a.store:loadAsync(a:join(3))
		expect(attempts).toBe(2)
		a.store:loadAsync(a:join(4))
		expect(attempts).toBe(2)
	end)

	T.it("waitForProfileAsync waits for a slow load and gives up on a failed one", function()
		local world = World.new()
		local a = world:server("A")
		a.store:bindPlayers()
		world.dss:failNext("UpdateAsync", { times = 1 })
		local slow = a:join(1)
		expect(a.store:isLoaded(slow)).toBe(false)
		local profile = a.store:waitForProfileAsync(slow)
		assert(profile, "expected the slow load to finish")
		expect(world.clock:clock()).toBeGreaterThanOrEqual(1)

		world.dss:failNext("UpdateAsync", { code = 403 })
		local failed = a:join(2)
		expect(a.store:waitForProfileAsync(failed)).toBeNil()
		expect(failed:wasKicked()).toBe(true)
	end)
end)

T.describe("Data.Store schema versions", function()
	T.it("migrates older data inside the load, then fills in new template keys", function()
		local world = World.new()
		world:seed(1, World.document({ gold = 7, inventory = { "sword" } }))
		local migrations: { [number]: (any) -> any } = {
			-- In place...
			[2] = function(data: any)
				data.coins = data.gold
				data.gold = nil
				return nil
			end,
			-- ...or by returning new data.
			[3] = function(data: any)
				return { coins = data.coins * 10, inventory = data.inventory }
			end,
		}
		local a = world:server("A", { version = 3, migrations = migrations })
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		expect(profile.data).toEqual({ coins = 70, inventory = { "sword" }, settings = { music = true } })
		expect(profile.meta.schemaVersion).toBe(3)
		local stored = world:stored(1)
		expect(stored.meta.schemaVersion).toBe(3)
		expect(stored.data.coins).toBe(70)
		expect(stored.data.gold).toBeNil()
	end)

	T.it("can skip reconciling when the game wants exact data", function()
		local world = World.new()
		world:seed(1, World.document({ coins = 1 }))
		local a = world:server("A", { reconcile = false })
		local profile = a.store:loadAsync(a:join(1))
		assert(profile, "expected a profile")
		expect(profile.data).toEqual({ coins = 1 })
	end)

	T.it("refuses data when a migration fails, and leaves it untouched", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(500)))
		local before = world:version(1)
		local a = world:server("A", {
			version = 2,
			migrations = {
				[2] = function(_data: any)
					error("inventory format unknown")
				end,
			},
		})
		a.store:bindPlayers()
		local player = a:join(1)
		expect(a.store:get(player)).toBeNil()
		expect(player:wasKicked()).toBe(true)
		expect(world:version(1)).toBe(before)
		expect(world:stored(1).meta.schemaVersion).toBe(1)
		expect(a:counters().loadFailuresByReason.migration).toBe(1)
		expect(logged("error", "inventory format unknown")).toBe(true)
	end)

	T.it("refuses a migration whose result can't be stored", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(500)))
		local before = world:version(1)
		local a = world:server("A", {
			version = 2,
			migrations = {
				[2] = function(data: any)
					data.ratio = math.huge
					return nil
				end,
			},
		})
		local profile, err = a.store:loadAsync(a:join(1))
		expect(profile).toBeNil()
		expect(err).toBe("migration")
		expect(world:version(1)).toBe(before)
		expect(logged("error", "data.ratio")).toBe(true)
	end)

	T.it("refuses data saved by a newer version and asks the player to rejoin", function()
		local world = World.new()
		world:seed(1, World.document(World.progress(500), { schemaVersion = 4 }))
		local before = world:version(1)
		local a = world:server("A", {
			version = 3,
			migrations = {
				[2] = function(data: any)
					return data
				end,
				[3] = function(data: any)
					return data
				end,
			},
		})
		a.store:bindPlayers()
		local player = a:join(1)
		expect(player:wasKicked()).toBe(true)
		expect(player:kickMessage()).toContain("older version")
		expect(world:version(1)).toBe(before)
		expect(a:counters().loadFailuresByReason.newerVersion).toBe(1)
	end)

	T.it("refuses a profile whose data isn't a table", function()
		local world = World.new()
		world:seed(1, World.document(42))
		local a = world:server("A")
		local profile, err = a.store:loadAsync(a:join(1))
		expect(profile).toBeNil()
		expect(err).toBe("corrupt")
		expect(world:stored(1).data).toBe(42)
	end)

	T.it("refuses a value that isn't a profile, and leaves it untouched", function()
		local world = World.new()
		world:seed(1, { coins = 12 })
		world:seed(2, "legacy string save")
		local a = world:server("A")
		local profile, err = a.store:loadAsync(a:join(1))
		expect(profile).toBeNil()
		expect(err).toBe("corrupt")
		expect(world:stored(1)).toEqual({ coins = 12 })
		local _, err2 = a.store:loadAsync(a:join(2))
		expect(err2).toBe("corrupt")
		expect(world:stored(2)).toBe("legacy string save")
		expect(a:counters().loadFailuresByReason.corrupt).toBe(2)
	end)
end)

T.describe("Data.Store.new", function()
	T.it("checks its options up front", function()
		local world = World.new()
		expect(function()
			world:server("A", { version = 2 })
		end).toThrow("missing migration to version 2")
		expect(function()
			world:server("A", {
				migrations = {
					[2] = function(data: any)
						return data
					end,
				},
			})
		end).toThrow("migration keys")
		expect(function()
			world:server("A", { template = { speed = 0 / 0 } })
		end).toThrow("template.speed")
		expect(function()
			world:server("A", { name = string.rep("x", 51) })
		end).toThrow("1-50 characters")
		expect(function()
			world:server("A", { version = 1.5 })
		end).toThrow("integer")
	end)

	T.it("uses a custom key and scope", function()
		local world = World.new()
		local a = world:server("A", {
			scope = "beta",
			key = function(userId: number): string
				return "u" .. tostring(userId)
			end,
		})
		local profile = a.store:loadAsync(a:join(7))
		assert(profile, "expected a profile")
		expect(profile.key).toBe("u7")
		expect(world.dss:inspect(World.STORE, "u7", "beta")).never.toBeNil()
		expect(world:stored(7)).toBeNil()
		expect(a:counters().scope).toBe("beta")
	end)
end)
