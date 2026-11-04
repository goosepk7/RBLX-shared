--!strict
local Log = require("@shared/Util/Log")
local Net = require("@shared/Net")
local Remotes = require("@shared/Remotes")
local T = require("@shared/Test")
local Tutorial = require("@shared/Tutorial")

local expect = T.expect

type Sink = { calls: { { any } }, onboarding: (self: Sink, player: any, step: number, name: string) -> () }

local function sink(): Sink
	local s = { calls = {} } :: Sink
	function s.onboarding(self: Sink, player: any, step: number, name: string)
		table.insert(self.calls, { player.UserId, step, name })
	end
	return s
end

local function setup(): (Tutorial.Tutorial, Sink, any, any)
	local analytics = sink()
	local players = T.Fakes.Players.new()
	local tutorial = Tutorial.new({
		steps = { "move", "jump", "shop", "win" },
		analytics = analytics,
		players = players,
		now = function()
			return 1_000
		end,
	})
	local player = players:join({ UserId = 1, Name = "one" })
	local data = {}
	tutorial:attach(player, data)
	return tutorial, analytics, player, data
end

T.describe("Tutorial", function()
	T.it("completes steps in order and reports each to analytics once", function()
		local tutorial, analytics, player = setup()
		expect((tutorial:status(player) :: any).next).toBe("move")
		expect((tutorial:complete(player, "move"))).toBe(true)
		expect((tutorial:complete(player, "move"))).toBe(true)
		expect(analytics.calls).toEqual({ { 1, 1, "move" } :: { any } })
		local status = tutorial:status(player) :: Tutorial.Status
		expect(status.step).toBe(1)
		expect(status.next).toBe("jump")
		expect(status.done).toBe(false)
	end)

	T.it("completing a later step completes the ones before it, then finishes", function()
		local tutorial, analytics, player, data = setup()
		local finished: { boolean } = {}
		tutorial.Finished:Connect(function(_p: any, _id: number, skipped: boolean)
			table.insert(finished, skipped)
		end)
		tutorial:complete(player, "shop")
		expect(#analytics.calls).toBe(3)
		expect(analytics.calls[3]).toEqual({ 1, 3, "shop" } :: { any })
		tutorial:complete(player, "win")
		expect(finished).toEqual({ false })
		local status = tutorial:status(player) :: Tutorial.Status
		expect(status.done).toBe(true)
		expect(status.next).toBeNil()
		expect((data :: any).tutorial.doneAt).toBe(1_000)
	end)

	T.it("skips without reporting more steps, and a reset never reports twice", function()
		local tutorial, analytics, player = setup()
		tutorial:complete(player, "jump")
		expect((tutorial:skip(player))).toBe(true)
		local status = tutorial:status(player) :: Tutorial.Status
		expect(status.done).toBe(true)
		expect(status.skipped).toBe(true)
		expect(#analytics.calls).toBe(2)
		tutorial:reset(player)
		expect((tutorial:status(player) :: any).next).toBe("move")
		tutorial:complete(player, "shop")
		expect(#analytics.calls).toBe(3)
		expect(analytics.calls[3][3]).toBe("shop")
	end)

	T.it("refuses unknown steps and unloaded players", function()
		local tutorial, _, player = setup()
		expect((select(2, tutorial:complete(player, "fly")))).toBe("unknown")
		expect((select(2, tutorial:complete(99, "move")))).toBe("notLoaded")
		expect(tutorial:status(99)).toBeNil()
	end)

	T.it("repairs bad saved state", function()
		local state = Tutorial.repair({ step = -3, skipped = "yes", doneAt = 0 / 0 })
		expect(state.step).toBe(0)
		expect(state.skipped).toBe(false)
		expect(state.doneAt).toBeNil()
	end)

	T.it("rejects bad step lists", function()
		expect(function()
			Tutorial.new({ steps = {} })
		end).toThrow("non-empty")
		expect(function()
			Tutorial.new({ steps = { "a", "a" } })
		end).toThrow("duplicate")
		expect(function()
			Tutorial.new({ steps = { "has space" } })
		end).toThrow("bad step id")
	end)

	T.it("works over the remotes", function()
		local tutorial, analytics, player = setup()
		local clock = T.Clock.new()
		local loop = Net.Loopback.new()
		local server = Net.newContext({ side = "server", transport = loop.server, task = clock.task })
		tutorial:bindNet(server)
		local client = Remotes.client(
			"Tutorial",
			Net.newContext({ side = "client", transport = loop:connect(player), task = clock.task })
		)
		expect((client.GetState:invokeAsync()).value.next).toBe("move")
		local step = client.Step:invokeAsync("move")
		expect(step.value.ok).toBe(true)
		expect(step.value.status.next).toBe("jump")
		local logs, restore = Log.capture()
		expect((client.Step:invokeAsync("nope!")).ok).toBe(false)
		restore()
		expect(#logs).toBe(1)
		expect((client.Skip:invokeAsync()).value.status.skipped).toBe(true)
		expect(#analytics.calls).toBe(1)
	end)
end)
