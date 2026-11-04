--!strict
-- The v0.2 modules against the real Analytics module: every call they make must pass its name
-- and argument checks (stage ids like "pier:gap:easy" aren't valid analytics paths as they are).
local Analytics = require("@shared/Analytics")
local Daily = require("@shared/Daily")
local Events = require("@shared/Events")
local Progression = require("@shared/Progression")
local Rig = require("./Rig")
local T = require("@shared/Test")
local Tutorial = require("@shared/Tutorial")

local expect = T.expect

local rig: Rig.Rig
local sent: { any }
local analytics: Analytics.Analytics
T.beforeEach(function()
	rig = Rig.new()
	sent = {}
	analytics = Analytics.new({
		sink = function(_player: any, event: Analytics.Event)
			table.insert(sent, event)
		end,
		task = rig.clock.task,
		now = rig.now,
		clock = function()
			return rig.clock:clock()
		end,
		players = rig.players,
	} :: any)
end)
T.afterEach(function()
	rig.restore()
end)

local function events(kind: string): { any }
	analytics:flush()
	local out: { any } = {}
	for _, event in sent do
		if event.kind == kind or event.name == kind then
			table.insert(out, event)
		end
	end
	return out
end

T.describe("v0.2 modules with Analytics", function()
	T.it("progression, daily, events and tutorial calls are accepted", function()
		local progression = Progression.new({
			stages = { { id = "pier:gap:easy", reward = { currency = "Wins", amount = 1 } } },
			economy = rig.economy,
			analytics = analytics,
			now = rig.now,
			clock = function()
				return rig.clock:clock()
			end,
			players = rig.players,
		})
		local daily = Daily.new({
			economy = rig.economy,
			days = { { currencies = { Wins = 1 } } },
			analytics = analytics,
			now = rig.now,
		})
		local tutorial = Tutorial.new({ steps = { "move", "jump" }, analytics = analytics })
		local lobby = Events.new({
			events = { { id = "race", durationSeconds = 10, minPlayers = 1 } },
			mode = "lobby",
			every = 600,
			economy = rig.economy,
			analytics = analytics,
			players = rig.players,
			task = rig.clock.task,
			now = rig.now,
		})
		local modules: { any } = { progression, daily, tutorial }
		local player = rig:join(1, modules)

		local attempt = progression:begin(player, "pier:gap:easy") :: Progression.Attempt
		rig.clock:advance(8)
		expect((progression:finish(player, attempt.attemptId, { completed = true }))).never.toBeNil()
		expect((daily:claim(player))).toBe(true)
		expect((tutorial:complete(player, "jump"))).toBe(true)
		lobby:start()
		lobby:trigger("race")
		lobby:join(player)
		rig.clock:advance(90 + 10)

		local paths: { [string]: boolean } = {}
		for _, event in events("progression") do
			paths[tostring(event.path or event.name)] = true
		end
		expect(paths["pier.gap.easy"]).toBe(true)
		expect(paths["daily"]).toBe(true)
		expect(paths["event.race"]).toBe(true)
		expect(#events("onboarding")).toBe(2)
		for _, entry in rig.logs do
			expect(entry.level == "error" and entry.message or "").toBe("")
		end
	end)
end)
