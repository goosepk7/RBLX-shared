--!strict
local T = require("@shared/Test")
local Sim = require("@shared/Sim")
local expect = T.expect
local Population = Sim.Population

T.describe("Sim.Population", function()
	T.it("quotas split exactly by largest remainder", function()
		expect(Population.quotas({ 0.4, 0.4, 0.2 }, 500)).toEqual({ 200, 200, 100 })
		expect(Population.quotas({ 1, 1, 1 }, 10)).toEqual({ 4, 3, 3 })
	end)

	T.it("generates the brief's default mix deterministically", function()
		local a = Population.generate(Sim.Rng.new("pop"), 100)
		local b = Population.generate(Sim.Rng.new("pop"), 100)
		local counts: { [string]: number } = {}
		for i, p in a do
			counts[p.profile] = (counts[p.profile] or 0) + 1
			expect(p.profile).toBe(b[i].profile)
			expect(p.skill).toBe(b[i].skill)
			expect(p.pattern).toBe(b[i].pattern)
			expect(p.skill > 0 and p.skill < 1).toBe(true)
			expect(({ short = 3, medium = 12, long = 40 })[p.pattern]).toBe(p.sessionMinutes)
		end
		expect(counts).toEqual({ casual = 40, average = 40, grinder = 20 })
	end)

	T.it("daily sessions are deterministic, ordered, non-overlapping, inside the day", function()
		local players = Population.generate(Sim.Rng.new("sessions"), 50)
		for _, p in players do
			for day = 1, 5 do
				local s1 = Population.sessionsForDay(p, day)
				local s2 = Population.sessionsForDay(p, day)
				expect(#s1).toBe(#s2)
				if day == 1 then
					expect(#s1).toBeGreaterThanOrEqual(1)
				end
				local cursor = 0
				for i, s in s1 do
					expect(s.start).toBe(s2[i].start)
					expect(s.start).toBeGreaterThanOrEqual(cursor)
					expect(s.absoluteStart).toBe((day - 1) * 86400 + s.start)
					cursor = s.start + s.duration
				end
			end
		end
	end)

	T.it("play() accumulates play time and mark() records first milestones", function()
		local players = Population.generate(Sim.Rng.new("play"), 30)
		local sessionCount = 0
		local total = 0
		Population.play(players, { days = 3 }, function(player, session)
			sessionCount += 1
			total += session.duration
			expect(session.playStart).toBe(player.playSeconds)
			-- milestone 30 s into the first session
			Population.mark(player, "firstWin", session, 30)
			expect(Population.mark(player, "firstWin", session, 31)).toBe(false)
		end)
		local sum = 0
		local played = 0
		for _, p in players do
			sum += p.playSeconds
			played += p.sessionsPlayed
			local m = p.milestones.firstWin
			expect(m.playSeconds).toBe(30)
			expect(m.day).toBe(1)
			expect(m.session).toBe(1)
			expect(m.dayMinute).toBe(0.5)
		end
		expect(sum).toBeNear(total, 1e-6)
		expect(played).toBe(sessionCount)
	end)

	T.it("milestoneReport summarizes per profile with 'all' first", function()
		local players = Population.generate(Sim.Rng.new("report"), 10)
		Population.play(players, { days = 1 }, function(player, session)
			if player.profile ~= "casual" then
				Population.mark(player, "x", session, 60)
			end
		end)
		local rows = Population.milestoneReport(players, { "x" })
		expect(rows[1].profile).toBe("all")
		expect(rows[1].reached).toBe(6)
		for _, row in rows do
			if row.profile == "casual" then
				expect(row.reached).toBe(0)
				expect(row.playMinutes).toBeNil()
			elseif row.profile == "grinder" then
				expect((row.playMinutes :: any).p50).toBe(1)
			end
		end
	end)
end)
