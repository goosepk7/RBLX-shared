--!strict
local AntiExploit = require("@shared/AntiExploit")
local Progression = require("@shared/Progression")
local Rig = require("./Rig")
local T = require("@shared/Test")

local expect = T.expect

local rig: Rig.Rig
T.beforeEach(function()
	rig = Rig.new()
end)
T.afterEach(function()
	rig.restore()
end)

local STAGES: { Progression.StageDef } = {
	{
		id = "pier:gap:easy",
		group = "pier",
		par = 25,
		minSeconds = 5,
		awards = { "clear", "underPar", "noDismount" },
		reward = { currency = "Wins", amount = 1, firstClearMultiplier = 2, speedBonus = 0.5 },
	},
	{
		id = "pier:limbo:normal",
		group = "pier",
		par = 40,
		awards = { "clear", "underPar" },
		reward = { currency = "Wins", amount = 2, firstClearMultiplier = 2 },
	},
	{
		id = "quarry:gap:hard",
		group = "quarry",
		par = 60,
		gate = "quarry",
		reward = { currency = "Wins", amount = 4 },
	},
}

local GATES: { Progression.GateDef } = {
	{ id = "pier" },
	{
		id = "quarry",
		requires = { lifetime = { currency = "Wins", amount = 60 }, awards = { count = 3, group = "pier" } },
		fastTrack = { factor = 0.5 },
	},
	{ id = "frost", requires = { gates = { "quarry" }, clears = { count = 1, group = "quarry" } } },
}

local function make(extra: { [string]: any }?): Progression.Progression
	local options: any = {
		stages = STAGES,
		gates = GATES,
		economy = rig.economy,
		now = rig.now,
		clock = function()
			return rig.clock:clock()
		end,
		players = rig.players,
	}
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return Progression.new(options)
end

local function run(
	progression: Progression.Progression,
	player: any,
	stageId: string,
	seconds: number,
	flags: { [string]: boolean }?
): Progression.Outcome
	local attempt = progression:begin(player, stageId)
	assert(attempt, "expected the stage to begin")
	rig.clock:advance(seconds)
	local outcome, failure = progression:finish(player, attempt.attemptId, { completed = true, flags = flags })
	assert(outcome, "finish failed: " .. tostring(failure))
	return outcome
end

T.describe("Progression pure rules", function()
	T.it("pays the speed bonus linearly from par down to the full-bonus time", function()
		local reward: Progression.StageReward = { currency = "Wins", amount = 1, speedBonus = 0.5 }
		expect(Progression.speedBonus(reward, 20, 25)).toBe(0)
		expect(Progression.speedBonus(reward, 20, 20)).toBe(0)
		expect(Progression.speedBonus(reward, 20, 15)).toBeNear(0.25)
		expect(Progression.speedBonus(reward, 20, 10)).toBe(0.5)
		expect(Progression.speedBonus(reward, 20, 2)).toBe(0.5)
		expect(Progression.speedBonus(reward, nil, 2)).toBe(0)
	end)

	T.it("derives awards from completion, par and flags, only those the stage declares", function()
		local stage = STAGES[1]
		local result: any =
			{ completed = true, durationSeconds = 20, awards = {}, flags = { noDismount = true, other = true } }
		expect(Progression.awardsFor(stage, result)).toEqual({ "clear", "underPar", "noDismount" })
		result.durationSeconds = 30
		result.flags = {}
		expect(Progression.awardsFor(stage, result)).toEqual({ "clear" })
		result.completed = false
		expect(Progression.awardsFor(stage, result)).toEqual({})
	end)

	T.it("multiplies first clear, featured and award bonuses into the payout", function()
		local stage: Progression.StageDef = {
			id = "s",
			par = 10,
			reward = { currency = "Wins", amount = 4, firstClearMultiplier = 2, awardBonus = 0.25 },
		}
		local result: any =
			{ completed = true, durationSeconds = 12, awards = { "clear", "underPar", "untouched" }, flags = {} }
		expect((Progression.payout(stage, result, false))).toBe(4 * 1.5)
		expect((Progression.payout(stage, result, true))).toBe(4 * 1.5 * 2)
		expect((Progression.payout(stage, result, true, 2))).toBe(4 * 1.5 * 2 * 2)
		result.flags = { noSpeedBonus = true }
		expect((Progression.payout(stage, result, false))).toBe(6)
	end)

	T.it("repairs damaged saved state without losing valid records", function()
		local state = Progression.repair({
			records = {
				good = { clears = 2, attempts = 3, bestTime = 12.5, awards = { clear = true, bad = 1 } },
				broken = "x",
				[3] = { clears = 1 },
			},
			unlocked = { quarry = 1_700_000_000, nope = "yes" },
		})
		expect(state.records.good).toEqual({ clears = 2, attempts = 3, bestTime = 12.5, awards = { clear = true } })
		expect(state.records.broken).toBeNil()
		expect(state.unlocked).toEqual({ quarry = 1_700_000_000 })
	end)
end)

T.describe("Progression attempts", function()
	T.it("records a first clear with server-measured time, awards and doubled reward", function()
		local progression = make({ rewardReason = "stage" })
		local player = rig:join(1, { progression })
		local outcome = run(progression, player, "pier:gap:easy", 15, { noDismount = true })
		expect(outcome.firstClear).toBe(true)
		expect(outcome.newBest).toBe(true)
		expect(outcome.result.durationSeconds).toBe(15)
		expect(outcome.newAwards).toEqual({ "clear", "underPar", "noDismount" })
		-- 1 Win x (1 + 0.5 x 10/12.5 speed) x 2 first clear = 2.8, carried to whole Wins.
		expect(outcome.payout).toBeNear(2.8)
		expect(outcome.rewards.Wins).toBe(2)
		expect(rig.economy:balance(player, "Wins")).toBe(2)
		expect(progression:count(player)).toBe(3)

		local again = run(progression, player, "pier:gap:easy", 30)
		expect(again.firstClear).toBe(false)
		expect(again.newBest).toBe(false)
		expect(again.previousBest).toBe(15)
		expect(again.newAwards).toEqual({})
		local record = progression:record(player, "pier:gap:easy")
		assert(record, "expected a record")
		expect(record.clears).toBe(2)
		expect(record.attempts).toBe(2)
		expect(record.bestTime).toBe(15)
	end)

	T.it("lets the game report a shorter time from its own start line, never a longer one", function()
		local progression = make()
		local player = rig:join(1, { progression })
		local attempt = progression:begin(player, "pier:limbo:normal") :: Progression.Attempt
		rig.clock:advance(30)
		local outcome = progression:finish(player, attempt.attemptId, { completed = true, durationSeconds = 28 })
		expect((outcome :: Progression.Outcome).result.durationSeconds).toBe(28)

		local second = progression:begin(player, "pier:limbo:normal") :: Progression.Attempt
		rig.clock:advance(30)
		local longer = progression:finish(player, second.attemptId, { completed = true, durationSeconds = 90 })
		expect((longer :: Progression.Outcome).result.durationSeconds).toBe(30)
	end)

	T.it("refuses implausibly fast clears and strikes the player", function()
		local registry = AntiExploit.newRegistry({ now = rig.now })
		local progression = make({ strikes = registry })
		local player = rig:join(1, { progression })
		local attempt = progression:begin(player, "pier:gap:easy") :: Progression.Attempt
		rig.clock:advance(2)
		local outcome, failure = progression:finish(player, attempt.attemptId, { completed = true })
		expect(outcome).toBeNil()
		expect(failure).toBe("implausible")
		expect((registry:getRecord(player) :: any).byCategory["progression.tooFast"]).toBe(1)
		expect(rig.economy:balance(player, "Wins")).toBe(0)
	end)

	T.it("needs a matching attempt to finish, and a new begin abandons the old attempt", function()
		local progression = make()
		local player = rig:join(1, { progression })
		local _, failure = progression:finish(player, "nope", { completed = true })
		expect(failure).toBe("noAttempt")
		local first = progression:begin(player, "pier:gap:easy") :: Progression.Attempt
		progression:begin(player, "pier:limbo:normal")
		local _, stale = progression:finish(player, first.attemptId, { completed = true })
		expect(stale).toBe("noAttempt")
	end)

	T.it("records failed runs as attempts without awards or rewards", function()
		local progression = make()
		local player = rig:join(1, { progression })
		local attempt = progression:begin(player, "pier:gap:easy") :: Progression.Attempt
		rig.clock:advance(10)
		local outcome = progression:finish(player, attempt.attemptId, { completed = false }) :: Progression.Outcome
		expect(outcome.result.completed).toBe(false)
		expect(outcome.newAwards).toEqual({})
		expect(outcome.payout).toBe(0)
		local record = progression:record(player, "pier:gap:easy") :: Progression.StageRecord
		expect(record.attempts).toBe(1)
		expect(record.clears).toBe(0)
	end)

	T.it("rejects submitted results for another player or a malformed result", function()
		local progression = make()
		local player = rig:join(1, { progression })
		local _, failure = progression:submit(player, {
			stageId = "pier:gap:easy",
			userId = 2,
			attemptId = "x",
			completed = true,
			startedAt = 0,
			durationSeconds = 10,
			awards = {},
			flags = {},
		})
		expect(failure).toBe("invalid")
		local _, missing = progression:submit(player, {
			stageId = "pier:gap:easy",
			userId = 1,
			attemptId = "x",
			completed = true,
			startedAt = 0,
			awards = {},
			flags = {},
		})
		expect(missing).toBe("invalid")
	end)

	T.it("calls analytics on start, complete and fail", function()
		local calls: { string } = {}
		local analytics = {
			progression = function(_self: any, _player: any, stageId: string, status: string, n: number)
				table.insert(calls, stageId .. ":" .. status .. ":" .. n)
			end,
		}
		local progression = make({ analytics = analytics })
		local player = rig:join(1, { progression })
		run(progression, player, "pier:gap:easy", 10)
		progression:begin(player, "pier:gap:easy")
		progression:abandon(player)
		expect(calls).toEqual({
			"pier.gap.easy:start:1",
			"pier.gap.easy:complete:1",
			"pier.gap.easy:start:2",
			"pier.gap.easy:fail:2",
		})
	end)
end)

T.describe("Progression gates", function()
	T.it("keeps a gated stage locked until lifetime and award requirements are both met", function()
		local progression = make()
		local player = rig:join(1, { progression })
		expect(progression:isUnlocked(player, "pier")).toBe(true)
		local ok, failure = progression:canBegin(player, "quarry:gap:hard")
		expect(ok).toBe(false)
		expect(failure).toBe("locked")

		rig.economy:earn(player, "Wins", 60, "stage")
		expect(progression:isUnlocked(player, "quarry")).toBe(false)
		local fraction, parts = progression:gateProgress(player, "quarry")
		expect(fraction).toBe(0)
		expect(#parts).toBe(2)

		local unlocked: { string } = {}
		progression.Unlocked:Connect(function(_p: any, _id: number, gateId: string)
			table.insert(unlocked, gateId)
		end)
		local outcome = run(progression, player, "pier:gap:easy", 10, { noDismount = true })
		expect(outcome.unlocked).toEqual({ "quarry" })
		expect(unlocked).toEqual({ "quarry" })
		expect(progression:isUnlocked(player, "quarry")).toBe(true)
		expect((progression:canBegin(player, "quarry:gap:hard"))).toBe(true)
	end)

	T.it("opens a gate as soon as an earning meets it", function()
		local progression = make()
		local player = rig:join(1, { progression })
		run(progression, player, "pier:gap:easy", 10, { noDismount = true })
		expect(progression:isUnlocked(player, "quarry")).toBe(false)
		rig.economy:earn(player, "Wins", 100, "stage")
		expect(progression:isUnlocked(player, "quarry")).toBe(true)
	end)

	T.it("reports the least-complete requirement as the gate's progress", function()
		local progression = make()
		local player = rig:join(1, { progression })
		rig.economy:earn(player, "Wins", 30, "stage")
		run(progression, player, "pier:gap:easy", 10, { noDismount = true })
		-- 3 of 3 awards, but only 30 + 3 (1 x 1.5 speed x 2 first clear) of 60 Wins.
		expect((progression:gateProgress(player, "quarry"))).toBeNear(33 / 60)
	end)

	T.it("halves the lifetime requirement after a rebirth (fast track)", function()
		local rebirths = 0
		local progression = make({
			rebirths = function()
				return rebirths
			end,
		})
		local player = rig:join(1, { progression })
		run(progression, player, "pier:gap:easy", 10, { noDismount = true })
		progression:resetGates(player)
		rig.economy:set(player, "Wins", 0, "rebirth", { lifetime = 0 })
		rebirths = 1
		rig.economy:earn(player, "Wins", 30, "stage")
		expect(progression:isUnlocked(player, "quarry")).toBe(true)
	end)

	T.it("chains gates that require other gates in one pass", function()
		local progression = make()
		local player = rig:join(1, { progression })
		progression:unlock(player, "quarry", "product")
		expect(progression:isUnlocked(player, "frost")).toBe(false)
		run(progression, player, "quarry:gap:hard", 20)
		expect(progression:isUnlocked(player, "frost")).toBe(true)
	end)

	T.it("resets every gate except the kept ones, and default gates stay open", function()
		local progression = make()
		local player = rig:join(1, { progression })
		progression:unlock(player, "quarry", "admin")
		progression:unlock(player, "frost", "admin")
		progression:resetGates(player, { "frost" })
		expect(progression:isUnlocked(player, "pier")).toBe(true)
		expect(progression:isUnlocked(player, "quarry")).toBe(false)
		expect(progression:isUnlocked(player, "frost")).toBe(true)
		-- Records (medals) survive.
		expect((progression:getState(player) :: Progression.State).records).toEqual({})
	end)

	T.it("rejects configs that point at unknown gates or currencies", function()
		expect(function()
			Progression.new({ stages = { { id = "a", gate = "nope" } } })
		end).toThrow("unknown gate")
		expect(function()
			Progression.new({
				stages = { { id = "a", reward = { currency = "Coins", amount = 1 } } },
				economy = rig.economy,
			})
		end).toThrow("unknown currency")
		expect(function()
			Progression.new({ stages = { { id = "a" }, { id = "a" } } })
		end).toThrow("duplicate")
	end)
end)

T.describe("Progression featured stages", function()
	T.it("picks the same stages all period from what the player has unlocked, and pays double", function()
		local progression = make({ featured = { count = 2, factor = 2 } })
		local player = rig:join(1, { progression })
		local picks, endsAt = progression:featured(player)
		expect(#picks).toBe(2)
		expect(table.find(picks, "quarry:gap:hard")).toBeNil()
		expect(endsAt % 86400).toBe(0)
		-- Unlocking more mid-period doesn't reshuffle today's picks.
		progression:unlock(player, "quarry", "admin")
		expect((progression:featured(player))).toEqual(picks)

		local outcome = run(progression, player, picks[1], 39)
		expect(outcome.featured).toBe(true)
		rig.clock:advance(86400)
		local tomorrow = progression:featured(player)
		expect(#tomorrow).toBe(2)
	end)

	T.it("is deterministic per player and period", function()
		local a = make({ featured = { count = 1 } })
		local b = make({ featured = { count = 1 } })
		local p1 = rig:join(1, { a })
		local _, data = rig:join(2, {})
		b:attach(p1, data)
		expect((a:featured(p1))).toEqual((b:featured(p1)))
	end)
end)
