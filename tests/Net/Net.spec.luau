--!strict
local AntiExploit = require("@shared/AntiExploit")
local Log = require("@shared/Util/Log")
local Net = require("@shared/Net")
local T = require("@shared/Test")

local S = Net.Schema
local expect = T.expect

type World = {
	clock: any,
	loop: Net.Loopback,
	registry: AntiExploit.Registry,
	server: Net.Context,
	serverRemotes: any,
	clientRemotes: any,
	player: any,
	clientFor: (player: any) -> any,
}

local function defs()
	return {
		Lunge = Net.clientEvent(S.number({ min = 0, max = 1 }), { rateLimit = { rate = 2, burst = 3 } }),
		Equip = Net.clientEvent(S.struct({ slot = S.enum({ "skin", "cap" }), id = S.string({ maxLength = 16 }) })),
		Guarded = Net.clientEvent(S.none(), {
			guard = function(player: Player)
				return player.UserId == 1
			end,
		}),
		Banner = Net.serverEvent(S.string({ maxLength = 32 })),
		Buy = Net.clientFunction(S.string({ maxLength = 16 }), S.integer()),
		Slow = Net.clientFunction(S.integer(), S.integer(), { timeout = 5 }),
		Unhandled = Net.clientFunction(S.none(), S.any()),
	}
end

local function setup(): World
	local clock = T.Clock.new()
	local loop = Net.Loopback.new()
	local registry = AntiExploit.newRegistry({
		now = function()
			return clock:now()
		end,
	})
	local monotonic = function()
		return clock:clock()
	end
	local server = Net.newContext({
		side = "server",
		transport = loop.server,
		task = clock.task,
		clock = monotonic,
		now = function()
			return clock:now()
		end,
		strikes = registry,
	})
	local serverRemotes = Net.namespace("Test", defs(), { context = server })

	local function clientFor(player: any): any
		local ctx = Net.newContext({
			side = "client",
			transport = loop:connect(player),
			task = clock.task,
			clock = monotonic,
		})
		return Net.namespace("Test", defs(), { context = ctx })
	end

	local player = T.Fakes.Players.newPlayer({ UserId = 1, Name = "one" })
	return {
		clock = clock,
		loop = loop,
		registry = registry,
		server = server,
		serverRemotes = serverRemotes,
		clientRemotes = clientFor(player),
		player = player,
		clientFor = clientFor,
	}
end

local function metricsOf(world: World, name: string): Net.RemoteMetrics
	return world.server:getMetrics()["Test." .. name]
end

T.describe("Net client events", function()
	T.it("delivers validated payloads to server handlers with the sender", function()
		local world = setup()
		local got: { any } = {}
		world.serverRemotes.Lunge:connect(function(player: Player, charge: number)
			table.insert(got, { player.UserId, charge })
		end)
		expect(world.clientRemotes.Lunge:fire(0.5)).toBe(true)
		expect(got).toEqual({ { 1, 0.5 } })
		local metrics = metricsOf(world, "Lunge")
		expect(metrics.received).toBe(1)
		expect(metrics.accepted).toBe(1)
	end)

	T.it("names remotes after their namespace", function()
		local world = setup()
		expect(world.serverRemotes.Lunge.name).toBe("Test.Lunge")
		expect(world.clientRemotes.Buy.name).toBe("Test.Buy")
	end)

	T.it("drops malformed payloads from a modified client, counts them and strikes", function()
		local world = setup()
		local handled = 0
		world.serverRemotes.Equip:connect(function()
			handled += 1
		end)
		local flagged = 0
		world.registry.Flagged:Connect(function()
			flagged += 1
		end)
		world.loop:injectFromClient(world.player, "Test.Equip", { slot = "admin", id = "x" })
		world.loop:injectFromClient(world.player, "Test.Equip", "not a table")
		expect(world.registry:isFlagged(world.player)).toBe(false)
		world.loop:injectFromClient(world.player, "Test.Equip", { slot = "skin", id = "x", extra = 1 })
		expect(handled).toBe(0)
		expect(metricsOf(world, "Equip").dropped.malformed).toBe(3)
		expect(world.registry:isFlagged(world.player)).toBe(true)
		expect(flagged).toBe(1)
		local record = world.registry:getRecord(world.player)
		assert(record, "expected a strike record")
		expect(record.byCategory["net.malformed"]).toBe(3)
		expect(record.recent[1].detail).toContain("Test.Equip")
	end)

	T.it("treats extra arguments as malformed", function()
		local world = setup()
		world.serverRemotes.Lunge:connect(function() end)
		world.loop:injectFromClient(world.player, "Test.Lunge", 0.5, "extra")
		expect(metricsOf(world, "Lunge").dropped.malformed).toBe(1)
		expect(metricsOf(world, "Lunge").accepted).toBe(0)
	end)

	T.it("rejects NaN from a modified client", function()
		local world = setup()
		world.serverRemotes.Lunge:connect(function() end)
		world.loop:injectFromClient(world.player, "Test.Lunge", 0 / 0)
		expect(metricsOf(world, "Lunge").dropped.malformed).toBe(1)
	end)

	T.it("the client refuses to send an invalid payload instead of earning a strike", function()
		local world = setup()
		local entries, restore = Log.capture()
		local sent = world.clientRemotes.Lunge:fire(2)
		restore()
		expect(sent).toBe(false)
		expect(#entries).toBe(1)
		expect(entries[1].message).toContain("not sending invalid Test.Lunge")
		expect(metricsOf(world, "Lunge").received).toBe(0)
		expect(world.registry:getRecord(world.player)).toBeNil()
	end)

	T.it("rate-limits per player on the server", function()
		local world = setup()
		local handled = 0
		world.serverRemotes.Lunge:connect(function()
			handled += 1
		end)
		for _ = 1, 5 do
			world.loop:injectFromClient(world.player, "Test.Lunge", 0.1)
		end
		expect(handled).toBe(3)
		expect(metricsOf(world, "Lunge").dropped.rateLimited).toBe(2)
		world.clock:advance(1) -- two tokens back at 2/s
		world.loop:injectFromClient(world.player, "Test.Lunge", 0.1)
		world.loop:injectFromClient(world.player, "Test.Lunge", 0.1)
		world.loop:injectFromClient(world.player, "Test.Lunge", 0.1)
		expect(handled).toBe(5)

		local other = T.Fakes.Players.newPlayer({ UserId = 2 }) :: any
		world.clientFor(other)
		world.loop:injectFromClient(other, "Test.Lunge", 0.1)
		expect(handled).toBe(6)
	end)

	T.it("the client self-limits to the same rate", function()
		local world = setup()
		world.serverRemotes.Lunge:connect(function() end)
		expect(world.clientRemotes.Lunge:fire(0.1)).toBe(true)
		expect(world.clientRemotes.Lunge:fire(0.1)).toBe(true)
		expect(world.clientRemotes.Lunge:fire(0.1)).toBe(true)
		expect(world.clientRemotes.Lunge:fire(0.1)).toBe(false)
		expect(metricsOf(world, "Lunge").dropped.rateLimited).toBe(0)
	end)

	T.it("a sustained flood earns one strike per window, not one per message", function()
		local world = setup()
		world.serverRemotes.Lunge:connect(function() end)
		-- burst 3, flood factor 10: the 30th drop in a 10 s window is a strike.
		for _ = 1, 200 do
			world.loop:injectFromClient(world.player, "Test.Lunge", 0.1)
		end
		local record = world.registry:getRecord(world.player)
		assert(record, "expected a strike record")
		expect(record.byCategory["net.flood"]).toBe(1)
		world.clock:advance(11)
		for _ = 1, 200 do
			world.loop:injectFromClient(world.player, "Test.Lunge", 0.1)
		end
		record = world.registry:getRecord(world.player)
		assert(record, "expected a strike record")
		expect(record.byCategory["net.flood"]).toBe(2)
	end)

	T.it("forgets a player's rate-limit state when they leave", function()
		local world = setup()
		world.serverRemotes.Lunge:connect(function() end)
		for _ = 1, 3 do
			world.loop:injectFromClient(world.player, "Test.Lunge", 0.1)
		end
		world.loop:disconnect(world.player)
		world.clientFor(world.player)
		world.loop:injectFromClient(world.player, "Test.Lunge", 0.1)
		expect(metricsOf(world, "Lunge").dropped.rateLimited).toBe(0)
	end)

	T.it("guards drop without a strike", function()
		local world = setup()
		local handled = 0
		world.serverRemotes.Guarded:connect(function()
			handled += 1
		end)
		local stranger = T.Fakes.Players.newPlayer({ UserId = 99 }) :: any
		world.clientFor(stranger)
		world.loop:injectFromClient(stranger, "Test.Guarded")
		world.loop:injectFromClient(world.player, "Test.Guarded")
		expect(handled).toBe(1)
		expect(metricsOf(world, "Guarded").dropped.unauthorized).toBe(1)
		expect(world.registry:getRecord(stranger)).toBeNil()
	end)

	T.it("reports handler errors without breaking the remote", function()
		local world = setup()
		world.serverRemotes.Lunge:connect(function()
			error("handler bug")
		end)
		local entries, restore = Log.capture()
		world.clientRemotes.Lunge:fire(0.1)
		world.clientRemotes.Lunge:fire(0.2)
		restore()
		expect(metricsOf(world, "Lunge").handlerErrors).toBe(2)
		expect(#entries).toBe(2)
		expect(entries[1].message).toContain("handler bug")
	end)

	T.it("counts valid messages with no handler", function()
		local world = setup()
		world.clientRemotes.Lunge:fire(0.1)
		expect(metricsOf(world, "Lunge").dropped.noHandler).toBe(1)
	end)

	T.it("disconnecting a handler stops delivery", function()
		local world = setup()
		local handled = 0
		local connection = world.serverRemotes.Lunge:connect(function()
			handled += 1
		end)
		world.clientRemotes.Lunge:fire(0.1)
		connection:Disconnect()
		world.clientRemotes.Lunge:fire(0.1)
		expect(handled).toBe(1)
	end)
end)

T.describe("Net kill switch", function()
	T.it("drops traffic for a disabled remote and tells the client", function()
		local world = setup()
		local handled = 0
		world.serverRemotes.Lunge:connect(function()
			handled += 1
		end)
		local entries, restore = Log.capture()
		world.server:setEnabled("Test.Lunge", false, "exploit")
		restore()
		expect(#entries).toBe(1)
		expect(world.loop:isEnabled("Test.Lunge")).toBe(false)
		expect(world.clientRemotes.Lunge:fire(0.1)).toBe(false)
		world.loop:injectFromClient(world.player, "Test.Lunge", 0.1)
		expect(handled).toBe(0)
		expect(metricsOf(world, "Lunge").dropped.disabled).toBe(1)
		expect(world.server:getDisabled()["Test.Lunge"].reason).toBe("exploit")

		world.server:setEnabled("Test.Lunge", true)
		expect(world.clientRemotes.Lunge:fire(0.1)).toBe(true)
		expect(handled).toBe(1)
	end)

	T.it("supports namespace wildcards and the global switch", function()
		local world = setup()
		local _, restore = Log.capture()
		world.server:setEnabled("Test.*", false)
		expect(world.server:isEnabled("Test.Equip")).toBe(false)
		expect(world.server:isEnabled("Other.Thing")).toBe(true)
		world.server:setEnabled("Test.*", true)
		world.server:setAllEnabled(false, "maintenance")
		expect(world.server:isEnabled("Other.Thing")).toBe(false)
		expect(world.loop:isEnabled("Test.Buy")).toBe(false)
		world.server:setAllEnabled(true)
		restore()
		expect(world.loop:isEnabled("Test.Buy")).toBe(true)
	end)

	T.it("disabled functions answer 'disabled'", function()
		local world = setup()
		world.serverRemotes.Buy:handle(function()
			return 1
		end)
		local _, restore = Log.capture()
		world.server:setEnabled("Test.Buy", false)
		restore()
		local result = world.clientRemotes.Buy:invokeAsync("x")
		expect(result.ok).toBe(false)
		expect(result.error).toBe("disabled")
	end)

	T.it("is server-only", function()
		local world = setup()
		local clientContext = Net.newContext({
			side = "client",
			transport = world.loop:connect(T.Fakes.Players.newPlayer({ UserId = 5 }) :: any),
		})
		expect(function()
			clientContext:setEnabled("Test.Lunge", false)
		end).toThrow("server-only")
	end)
end)

T.describe("Net server events", function()
	T.it("fire, fireAll, fireExcept and fireList reach the right clients", function()
		local world = setup()
		local second = T.Fakes.Players.newPlayer({ UserId = 2 })
		local secondRemotes = world.clientFor(second)
		local firstGot: { string } = {}
		local secondGot: { string } = {}
		world.clientRemotes.Banner:connect(function(text: string)
			table.insert(firstGot, text)
		end)
		secondRemotes.Banner:connect(function(text: string)
			table.insert(secondGot, text)
		end)
		world.serverRemotes.Banner:fire(world.player, "solo")
		world.serverRemotes.Banner:fireAll("all")
		world.serverRemotes.Banner:fireExcept(world.player, "except")
		world.serverRemotes.Banner:fireList({ second }, "list")
		expect(firstGot).toEqual({ "solo", "all" })
		expect(secondGot).toEqual({ "all", "except", "list" })
		expect(metricsOf(world, "Banner").sent).toBe(4)
	end)

	T.it("refuses to send an invalid server payload while validating outgoing traffic", function()
		local world = setup()
		expect(function()
			world.serverRemotes.Banner:fireAll(string.rep("x", 100))
		end).toThrow("refusing to send an invalid Test.Banner payload")
	end)

	T.it("strikes a client that fires a server-to-client remote", function()
		local world = setup()
		world.loop:injectFromClient(world.player, "Test.Banner", "spoof")
		expect(metricsOf(world, "Banner").dropped.wrongDirection).toBe(1)
		local record = world.registry:getRecord(world.player)
		assert(record, "expected a strike record")
		expect(record.byCategory["net.wrongDirection"]).toBe(1)
	end)

	T.it("client handlers can disconnect", function()
		local world = setup()
		local count = 0
		local connection = world.clientRemotes.Banner:connect(function()
			count += 1
		end)
		world.serverRemotes.Banner:fireAll("a")
		connection:Disconnect()
		world.serverRemotes.Banner:fireAll("b")
		expect(count).toBe(1)
	end)
end)

T.describe("Net client functions", function()
	T.it("returns the handler's value", function()
		local world = setup()
		world.serverRemotes.Buy:handle(function(player: Player, item: string)
			return #item + player.UserId
		end)
		local result = world.clientRemotes.Buy:invokeAsync("lamp")
		expect(result.ok).toBe(true)
		expect(result.value).toBe(5)
	end)

	T.it("maps failures to error codes", function()
		local world = setup()
		world.serverRemotes.Buy:handle(function(_player: Player, item: string): number
			if item == "boom" then
				error("shop bug")
			end
			return 1
		end)
		local entries, restore = Log.capture()
		local failed = world.clientRemotes.Buy:invokeAsync("boom")
		restore()
		expect(failed.ok).toBe(false)
		expect(failed.error).toBe("error")
		expect(#entries).toBe(1)
		expect(entries[1].message).toContain("shop bug")

		local unhandled = world.clientRemotes.Unhandled:invokeAsync(nil)
		expect(unhandled.ok).toBe(false)
		expect(unhandled.error).toBe("unavailable")

		local injected = { world.loop:injectInvoke(world.player, "Test.Buy", 12) }
		expect(injected).toEqual({ false, "invalid" } :: { any })
		expect(metricsOf(world, "Buy").dropped.malformed).toBe(1)
	end)

	T.it("rejects a response that breaks the response schema", function()
		local world = setup()
		world.serverRemotes.Buy:handle(function(): any
			return "not an integer"
		end)
		local entries, restore = Log.capture()
		local result = world.clientRemotes.Buy:invokeAsync("x")
		restore()
		expect(result.ok).toBe(false)
		expect(result.error).toBe("error")
		expect(entries[1].message).toContain("invalid response")
	end)

	T.it("only one handler is allowed", function()
		local world = setup()
		world.serverRemotes.Buy:handle(function()
			return 1
		end)
		expect(function()
			world.serverRemotes.Buy:handle(function()
				return 2
			end)
		end).toThrow("already has a handler")
	end)

	T.it("times out a slow server and ignores the late answer", function()
		local world = setup()
		world.serverRemotes.Slow:handle(function(_player: Player, n: number)
			world.clock.task.wait(20)
			return n
		end)
		local result: any = nil
		world.clock.task.spawn(function()
			result = world.clientRemotes.Slow:invokeAsync(7)
		end)
		expect(result).toBeNil()
		world.clock:advance(5)
		expect(result).toEqual({ ok = false, error = "timeout" })
		world.clock:advance(20)
		expect(result).toEqual({ ok = false, error = "timeout" })
	end)

	T.it("an answer inside the timeout wins", function()
		local world = setup()
		world.serverRemotes.Slow:handle(function(_player: Player, n: number)
			world.clock.task.wait(2)
			return n * 2
		end)
		local result: any = nil
		world.clock.task.spawn(function()
			result = world.clientRemotes.Slow:invokeAsync(21)
		end)
		world.clock:advance(3)
		expect(result).toEqual({ ok = true, value = 42 })
		world.clock:advance(10)
		expect(world.clock:pending()).toBe(0)
	end)
end)

T.describe("Net binding rules", function()
	T.it("methods are side-specific and unbound remotes say so", function()
		local world = setup()
		expect(function()
			world.serverRemotes.Lunge:fire(0.5)
		end).toThrow("client-only")
		expect(function()
			world.clientRemotes.Lunge:connect(function() end)
		end).toThrow("server-only")
		local loose = Net.clientEvent(S.none())
		expect(function()
			loose:fire(nil)
		end).toThrow("unbound remote")
	end)

	T.it("rejects duplicate namespaces, rebinding and non-remotes", function()
		local world = setup()
		expect(function()
			Net.namespace("Test", {}, { context = world.server })
		end).toThrow("already bound")
		local remote = Net.clientEvent(S.none())
		Net.namespace("A", { R = remote }, { context = world.server })
		expect(function()
			Net.namespace("B", { R = remote }, { context = world.server })
		end).toThrow("already bound")
		expect(function()
			Net.namespace("C", { R = 5 } :: any, { context = world.server })
		end).toThrow("not a Net remote definition")
		expect(function()
			Net.namespace("bad name", {}, { context = world.server })
		end).toThrow("identifier")
	end)

	T.it("has no default context outside Roblox", function()
		Net.setDefaultContext(nil)
		expect(function()
			Net.getDefaultContext()
		end).toThrow("no default context outside Roblox")
	end)

	T.it("applies the default rate limit when a remote declares none", function()
		local world = setup()
		world.serverRemotes.Equip:connect(function() end)
		for _ = 1, 25 do
			world.loop:injectFromClient(world.player, "Test.Equip", { slot = "cap", id = "a" })
		end
		expect(metricsOf(world, "Equip").accepted).toBe(20)
		expect(metricsOf(world, "Equip").dropped.rateLimited).toBe(5)
	end)
end)
