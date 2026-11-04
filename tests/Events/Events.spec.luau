--!strict
local Events = require("@shared/Events")
local Rig = require("../Progression/Rig")
local T = require("@shared/Test")

local expect = T.expect

local rig: Rig.Rig
T.beforeEach(function()
	rig = Rig.new()
end)
T.afterEach(function()
	rig.restore()
end)

local function lobbyEvents(extra: { [string]: any }?): Events.Events
	local defs: { Events.EventDef } = {
		{
			id = "race",
			durationSeconds = 60,
			minPlayers = 2,
			rewards = {
				participation = { currencies = { Wins = 2 } },
				placements = { { currencies = { Wins = 10 } }, { currencies = { Wins = 6 } } },
			},
		},
		{ id = "king", durationSeconds = 45, minPlayers = 1, maxPlayers = 2 },
	}
	local options: any = {
		events = defs,
		mode = "lobby",
		every = 720,
		lobbySeconds = 90,
		economy = rig.economy,
		players = rig.players,
		task = rig.clock.task,
		now = rig.now,
	}
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return Events.new(options)
end

local function toNextSlot(every: number)
	local t = rig.now()
	rig.clock:advance((math.floor(t / every) + 1) * every - t)
end

T.describe("Events (lobby)", function()
	T.it("opens on the clock-aligned slot, runs with joined players and pays placements", function()
		local events = lobbyEvents({
			events = {
				{
					id = "race",
					durationSeconds = 60,
					minPlayers = 2,
					rewards = {
						participation = { currencies = { Wins = 2 } },
						placements = { { currencies = { Wins = 10 } }, { currencies = { Wins = 6 } } },
					},
					run = function(ctx: Events.Context)
						rig.clock.task.delay(30, function()
							ctx.finish({ placements = { ctx.participants[2].UserId, ctx.participants[1].UserId } })
						end)
					end,
				},
			},
		})
		local a = rig:join(1)
		local b = rig:join(2)
		local c = rig:join(3)
		events:start()
		expect(events:state().phase).toBe("idle")
		expect(events:state().nextEventId).toBe("race")
		toNextSlot(720)
		local state = events:state()
		expect(state.phase).toBe("lobby")
		expect(state.endsAt).toBe(rig.now() + 90)
		expect((events:join(a))).toBe(true)
		expect((events:join(b))).toBe(true)
		expect(events:state().participants).toBe(2)

		local outcomes: { Events.Outcome } = {}
		events.Finished:Connect(function(outcome: Events.Outcome)
			table.insert(outcomes, outcome)
		end)
		rig.clock:advance(90)
		expect(events:state().phase).toBe("running")
		expect((select(2, events:join(c)))).toBe("closed")
		rig.clock:advance(30)
		expect(events:state().phase).toBe("results")
		expect(outcomes[1].placements).toEqual({ 2, 1 })
		expect(rig.economy:balance(b, "Wins")).toBe(12)
		expect(rig.economy:balance(a, "Wins")).toBe(8)
		expect(rig.economy:balance(c, "Wins")).toBe(0)
		rig.clock:advance(10)
		expect(events:state().phase).toBe("idle")
	end)

	T.it("cancels when too few joined and goes back to idle", function()
		local events = lobbyEvents()
		local a = rig:join(1)
		events:start()
		toNextSlot(720)
		events:join(a)
		local cancelled = false
		events.Finished:Connect(function(outcome: Events.Outcome)
			cancelled = outcome.cancelled
		end)
		rig.clock:advance(90)
		expect(cancelled).toBe(true)
		expect(events:state().phase).toBe("idle")
		expect(rig.economy:balance(a, "Wins")).toBe(0)
	end)

	T.it("ends at durationSeconds with participation rewards when the game never finishes", function()
		local events = lobbyEvents()
		local a = rig:join(1)
		local b = rig:join(2)
		events:start()
		toNextSlot(720)
		events:join(a)
		events:join(b)
		rig.clock:advance(90 + 60)
		expect(events:state().phase).toBe("results")
		expect(rig.economy:balance(a, "Wins")).toBe(2)
	end)

	T.it("rotates events in sequence by slot and respects maxPlayers", function()
		local events = lobbyEvents()
		local a = rig:join(1)
		local b = rig:join(2)
		local c = rig:join(3)
		events:start()
		toNextSlot(720)
		local first = events:state().eventId
		rig.clock:advance(90 + 60 + 10)
		toNextSlot(720)
		local second = events:state().eventId
		expect(first).never.toBe(second)
		if second == "king" then
			events:join(a)
			events:join(b)
			expect((select(2, events:join(c)))).toBe("full")
		end
	end)

	T.it("lets players leave the lobby and drops players who quit the game", function()
		local events = lobbyEvents()
		local a = rig:join(1)
		local b = rig:join(2)
		events:start()
		toNextSlot(720)
		events:join(a)
		events:join(b)
		expect((events:leave(a))).toBe(true)
		expect(events:state().participants).toBe(1)
		rig.players:leave(b)
		expect(events:state().participants).toBe(0)
	end)

	T.it("pays per-player rewards from the reward function", function()
		local events = lobbyEvents({
			events = {
				{
					id = "flood",
					durationSeconds = 30,
					reward = function(player: any, _outcome: Events.Outcome, _place: number?)
						return { currencies = { Wins = player.UserId * 3 } }
					end,
				},
			},
		})
		local a = rig:join(1)
		local b = rig:join(2)
		events:start()
		toNextSlot(720)
		events:join(a)
		events:join(b)
		rig.clock:advance(120)
		expect(rig.economy:balance(a, "Wins")).toBe(3)
		expect(rig.economy:balance(b, "Wins")).toBe(6)
	end)

	T.it("triggers an event on demand when idle", function()
		local events = lobbyEvents()
		events:start()
		expect((events:trigger("king"))).toBe(true)
		expect(events:state().eventId).toBe("king")
		expect((select(2, events:trigger("race")))).toBe("busy")
	end)

	T.it("reports a run that errors and still ends the event", function()
		local events = lobbyEvents({
			events = {
				{
					id = "broken",
					durationSeconds = 30,
					run = function()
						error("boom")
					end,
				},
			},
		})
		local a = rig:join(1)
		events:start()
		events:trigger("broken")
		events:join(a)
		rig.clock:advance(90)
		expect(events:state().phase).toBe("results")
		local reported = false
		for _, entry in rig.logs do
			if string.find(entry.message, "boom", 1, true) then
				reported = true
			end
		end
		expect(reported).toBe(true)
	end)
end)

T.describe("Events (ambient)", function()
	T.it("warns, then includes everyone in the server, on a random gap within bounds", function()
		local events = Events.new({
			events = {
				{ id = "flood", durationSeconds = 40, rewards = { participation = { currencies = { Wins = 1 } } } },
			},
			mode = "ambient",
			between = { min = 360, max = 600 },
			warningSeconds = 10,
			economy = rig.economy,
			players = rig.players,
			task = rig.clock.task,
			now = rig.now,
		})
		local a = rig:join(1)
		local b = rig:join(2)
		events:start()
		local _, at = events:upcoming()
		local gap = (at :: number) - rig.now()
		expect(gap >= 360 and gap <= 600).toBe(true)
		expect((select(2, events:join(a)))).toBe("notOptIn")
		rig.clock:advance((at :: number) - rig.now())
		expect(events:state().phase).toBe("warning")
		rig.clock:advance(10)
		expect(events:state().phase).toBe("running")
		expect(events:state().participants).toBe(2)
		rig.clock:advance(40)
		expect(rig.economy:balance(a, "Wins")).toBe(1)
		expect(rig.economy:balance(b, "Wins")).toBe(1)
	end)
end)

T.describe("Events picks", function()
	T.it("random rotation is the same on every server for a slot", function()
		local defs: { Events.EventDef } = {
			{ id = "a", durationSeconds = 1 },
			{ id = "b", durationSeconds = 1, weight = 3 },
		}
		local counts: { [string]: number } = { a = 0, b = 0 }
		for slot = 1, 400 do
			local pick = Events.randomPick(defs, slot, "s")
			expect(Events.randomPick(defs, slot, "s").id).toBe(pick.id)
			counts[pick.id] += 1
		end
		expect(counts.b > counts.a * 2).toBe(true)
	end)
end)
