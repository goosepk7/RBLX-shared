--!strict
local Analytics = require("@shared/Analytics")
local Economy = require("@shared/Economy")
local Log = require("@shared/Util/Log")
local T = require("@shared/Test")
local World = require("../Data/World")

local expect = T.expect

local logs: { Log.Entry } = {}
local restoreLog: () -> () = function() end
T.beforeEach(function()
	logs, restoreLog = Log.capture()
end)
T.afterEach(function()
	restoreLog()
end)

type Sent = { player: any, event: Analytics.Event }

local function setup(options: { [string]: any }?)
	local world = World.new()
	local server = world:server("A")
	local sent: { Sent } = {}
	local opts: any = {
		sink = function(player: any, event: Analytics.Event)
			table.insert(sent, { player = player, event = event })
		end,
		task = world.clock.task,
		now = function()
			return world.clock:now()
		end,
		clock = function()
			return world.clock:clock()
		end,
		players = server.players,
	}
	for key, value in options or {} :: { [string]: any } do
		opts[key] = value
	end
	local analytics = Analytics.new(opts)
	analytics:bindStore(server.store)
	server.store:bindPlayers()
	return world, server, analytics, sent
end

local function named(sent: { Sent }, name: string): { Analytics.Event }
	local out: { Analytics.Event } = {}
	for _, item in sent do
		if item.event.name == name then
			table.insert(out, item.event)
		end
	end
	return out
end

T.describe("Analytics", function()
	T.it("logs join and session length, and keeps play time in the profile", function()
		local world, server, analytics, sent = setup()
		local player = server:join(1)
		world.clock:advance(6)
		local joins = named(sent, "join")
		expect(#joins).toBe(1)
		expect(joins[1].value).toBe(1)
		expect((joins[1].fields :: any).new).toBe("true")
		world.clock:advance(294)
		expect(analytics:playSeconds(player)).toBe(300)
		server:leave(player)
		world.clock:advance(1)
		local lengths = named(sent, "session_length")
		expect(#lengths).toBe(1)
		expect(lengths[1].value).toBe(300)
		expect(world:stored(1).data.analytics.playSeconds).toBe(300)
		expect(world:stored(1).data.analytics.sessions).toBe(1)

		-- Second session on another server continues the totals.
		local b = world:server("B")
		local sentB: { Sent } = {}
		local analyticsB = Analytics.new({
			sink = function(p: any, e: Analytics.Event)
				table.insert(sentB, { player = p, event = e })
			end,
			task = world.clock.task,
			clock = function()
				return world.clock:clock()
			end,
			players = b.players,
		})
		analyticsB:bindStore(b.store)
		b.store:bindPlayers()
		local again = b:join(1)
		world.clock:advance(60)
		expect(analyticsB:playSeconds(again)).toBe(360)
		expect((named(sentB, "join")[1].fields :: any).new).toBe("false")
	end)

	T.it("logs a first milestone once per player, with seconds played as the value", function()
		local world, server, analytics, sent = setup()
		local player = server:join(1)
		world.clock:advance(42)
		expect(analytics:first(player, "win")).toBe(true)
		expect(analytics:first(player, "win")).toBe(false)
		expect(analytics:hasFirst(player, "win")).toBe(true)
		world.clock:advance(6)
		local firsts = named(sent, "first_win")
		expect(#firsts).toBe(1)
		expect(firsts[1].value).toBe(42)
		server:leave(player)
		world.clock:advance(1)
		expect(world:stored(1).data.analytics.firsts.win).toBeTruthy()
	end)

	T.it("counts each onboarding step once, in order", function()
		local world, server, analytics, sent = setup()
		local player = server:join(1)
		expect(analytics:onboarding(player, 1, "Moved")).toBe(true)
		expect(analytics:onboarding(player, 2, "SteppedGap")).toBe(true)
		expect(analytics:onboarding(player, 2, "SteppedGap")).toBe(false)
		expect(analytics:onboarding(player, 1, "Moved")).toBe(false)
		world.clock:advance(6)
		local steps = named(sent, "onboarding")
		expect(#steps).toBe(2)
		expect(steps[2].stepName).toBe("SteppedGap")
	end)

	T.it("logs purchases from ReceiptGranted, once per purchase, and the first purchase", function()
		local world, server, analytics, sent = setup()
		world.mps.ProcessReceipt = function(receipt: any)
			return server.store:processReceipt(receipt, function(profile: any)
				profile.data.coins += 100
				return true
			end)
		end
		local player = server:join(1)
		world.mps:purchaseProduct(player, 77, { purchaseId = "p1" })
		world.clock:advance(1)
		world.mps:purchaseProduct(player, 77, { purchaseId = "p2" })
		world.clock:advance(6)
		expect(#named(sent, "purchase")).toBe(2)
		expect(#named(sent, "first_purchase")).toBe(1)
		expect((analytics:getState(player) :: Analytics.State).purchases).toBe(2)
	end)

	T.it("maps economy transactions to sources and sinks, and skips adjustments", function()
		local world, server, analytics, sent = setup()
		local economy = Economy.new({
			currencies = { { id = "Wins", displayName = "Wins" } },
			reasons = { challenge = "earn", shop = "spend" },
			task = world.clock.task,
			players = server.players,
		})
		economy:bindStore(server.store)
		analytics:bindEconomy(economy)
		local player = server:join(1)
		economy:earn(player, "Wins", 10, "challenge")
		economy:spend(player, "Wins", 4, "shop")
		economy:set(player, "Wins", 0, "admin")
		world.clock:advance(6)
		local events = named(sent, "Wins")
		expect(#events).toBe(2)
		expect(events[1].flow).toBe("source")
		expect(events[1].transactionType).toBe("Gameplay")
		expect(events[1].sku).toBe("challenge")
		expect(events[2].flow).toBe("sink")
		expect(events[2].amount).toBe(4)
		expect(events[2].balance).toBe(6)
		expect(events[2].transactionType).toBe("Shop")
	end)

	T.it("sends within the per-minute budget and keeps the rest queued", function()
		local world, server, analytics, sent = setup({ budgetBase = 12, budgetPerPlayer = 0 })
		local player = server:join(1)
		for i = 1, 30 do
			analytics:progression(player, "World1", "fail", i)
		end
		analytics:flush()
		expect(#sent).toBe(12)
		expect(analytics:getDiagnostics().queued).toBe(19) -- 30 + join - 12
		world.clock:advance(60)
		expect(#sent).toBe(24)
		world.clock:advance(60)
		expect(#sent).toBe(31)
	end)

	T.it("drops the oldest event when the queue is full, and counts it", function()
		local _world, server, analytics, _sent = setup({ queueLimit = 5, budgetBase = 0, budgetPerPlayer = 0 })
		local player = server:join(1)
		for i = 1, 10 do
			analytics:track(player, "tick", i)
		end
		local diagnostics = analytics:getDiagnostics()
		expect(diagnostics.queued).toBe(5)
		expect(diagnostics.dropped).toBe(6) -- the join and the first five ticks
	end)

	T.it("reports sink errors instead of swallowing them, and keeps going", function()
		local calls = 0
		local world, server, analytics = setup({
			sink = function()
				calls += 1
				if calls == 2 then
					error("AnalyticsService throttled")
				end
			end,
		})
		local player = server:join(1)
		analytics:track(player, "a")
		analytics:track(player, "b")
		world.clock:advance(6)
		local diagnostics = analytics:getDiagnostics()
		expect(diagnostics.sent).toBe(2)
		expect(diagnostics.failed).toBe(1)
		expect(diagnostics.lastError).toMatch("throttled")
		local reported = false
		for _, entry in logs do
			if entry.level == "error" and string.find(entry.message, "throttled", 1, true) then
				reported = true
			end
		end
		expect(reported).toBe(true)
	end)

	T.it("keeps a ring buffer, newest first, filterable by player, even when sending is off", function()
		local _world, server, analytics, sent = setup({ bufferSize = 3, enabled = false })
		local a = server:join(1)
		local b = server:join(2)
		analytics:track(a, "x", 1)
		analytics:track(b, "y", 2)
		analytics:track(a, "z", 3)
		local recent = analytics:getRecent()
		expect(#recent).toBe(3)
		expect(recent[1].name).toBe("z")
		expect(recent[3].name).toBe("x") -- both joins fell out
		local forA = analytics:getRecent(10, 1)
		expect(#forA).toBe(2)
		expect(analytics:getRecent(1, 1)[1].name).toBe("z")
		expect(#sent).toBe(0)
	end)

	T.it("rejects event names Roblox would split into new dashboards by accident", function()
		local _world, server, analytics = setup()
		local player = server:join(1)
		expect(function()
			analytics:track(player, "stage " .. "47 cleared")
		end).toThrow("event name")
		expect(function()
			analytics:track(player, string.rep("a", 51))
		end).toThrow("event name")
	end)
end)

T.describe("Analytics.RobloxSink", function()
	local function fakeEnum(): any
		local function item(name: string)
			return { Name = name }
		end
		return {
			AnalyticsCustomFieldKeys = {
				CustomField01 = item("CustomField01"),
				CustomField02 = item("CustomField02"),
				CustomField03 = item("CustomField03"),
			},
			AnalyticsEconomyFlowType = { Source = item("Source"), Sink = item("Sink") },
		}
	end

	T.it("calls the AnalyticsService method for each kind, with fields in sorted key order", function()
		local calls: { { any } } = {}
		local service = setmetatable({}, {
			__index = function(_, method: string)
				return function(_self: any, ...: any)
					table.insert(calls, { method, ... })
				end
			end,
		})
		local sink = Analytics.RobloxSink.new(service, fakeEnum())
		local player = { UserId = 1 }
		sink(player, { kind = "custom", at = 0, userId = 1, name = "join", value = 2, fields = { b = "2", a = "1" } })
		sink(player, { kind = "progression", at = 0, userId = 1, name = "World1", status = "fail", level = 3 })
		sink(player, {
			kind = "economy",
			at = 0,
			userId = 1,
			name = "Wins",
			flow = "sink",
			currency = "Wins",
			amount = 4,
			balance = 6,
			transactionType = "Shop",
			sku = "shop",
		})
		expect(calls[1][1]).toBe("LogCustomEvent")
		expect(calls[1][5]).toEqual({ CustomField01 = "1", CustomField02 = "2" })
		expect(calls[2][1]).toBe("LogProgressionFailEvent")
		expect(calls[2][4]).toBe(3)
		expect(calls[3][1]).toBe("LogEconomyEvent")
		expect(calls[3][3].Name).toBe("Sink")
		expect(calls[3][7]).toBe("Shop")
	end)
end)
