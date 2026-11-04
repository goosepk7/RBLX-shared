--!strict
--[[
	Harness self-test: a toy idle economy that exercises every Sim piece end to end
	(population, sessions, milestones, recorder, targets, tuning). It is not a game model.
	It doubles as the worked example for game sim threads.
]]

local Sim = require("@shared/Sim")

type Params = { coinsPerMinute: number, itemCost: number }

local function simulate(rng: Sim.Rng, count: number, params: Params): { Sim.SimPlayer }
	local players = Sim.Population.generate(rng, count)
	Sim.Population.play(players, { days = 14 }, function(player, session)
		local coins = player.state.coins or 0
		local rate = params.coinsPerMinute * (0.5 + player.skill) / 60 -- per second
		local before = coins
		coins += rate * session.duration
		if before < params.itemCost and coins >= params.itemCost then
			Sim.Population.mark(player, "firstPurchase", session, (params.itemCost - before) / rate)
		end
		player.state.coins = coins
	end)
	return players
end

local function p50Minutes(players: { Sim.SimPlayer }, profile: string): number
	for _, row in Sim.Population.milestoneReport(players, { "firstPurchase" }) do
		if row.profile == profile and row.playMinutes then
			return row.playMinutes.p50
		end
	end
	return 0 / 0
end

return Sim.Runner.define({
	name = "shared.harness_selftest",
	description = "Toy idle economy exercising Population, Recorder, Targets and Tune.",
	seed = "harness-selftest-v1",
	params = { players = 200, coinsPerMinute = 4, itemCost = 100 },
	run = function(ctx)
		local params: Params = { coinsPerMinute = ctx.params.coinsPerMinute, itemCost = ctx.params.itemCost }

		-- Auto-fix demo: find the smallest change to coinsPerMinute (bounds 2..20) that gets the
		-- average player's first purchase under 10 play-minutes.
		local tune = Sim.Tune.solve({
			name = "coinsPerMinute",
			min = 2,
			max = 20,
			current = params.coinsPerMinute,
			step = 0.5,
			target = { max = 10 },
			evaluate = function(x)
				return p50Minutes(
					simulate(ctx.rng:fork("tune"), 60, { coinsPerMinute = x, itemCost = params.itemCost }),
					"average"
				)
			end,
		})
		ctx:note(tune.reason)
		params.coinsPerMinute = tune.value

		local players = simulate(ctx.rng:fork("final"), ctx.params.players, params)
		for _, row in Sim.Population.milestoneReport(players, { "firstPurchase" }) do
			ctx.recorder:row("milestones", {
				milestone = row.milestone,
				profile = row.profile,
				reached = row.reached,
				total = row.total,
				p50Minutes = if row.playMinutes then row.playMinutes.p50 else -1,
				p90Minutes = if row.playMinutes then row.playMinutes.p90 else -1,
			})
		end
		local average = p50Minutes(players, "average")
		ctx.recorder:set("coinsPerMinute", params.coinsPerMinute)
		ctx.recorder:set("firstPurchase.average.p50Minutes", average)
		ctx:artifact("tuning.md", Sim.Tune.describe({ tune }))

		ctx.targets:check("tuner found a value within bounds", if tune.ok then 1 else 0, { min = 1 })
		ctx.targets:check("first purchase, average p50 (play min)", average, { max = 10 })
		ctx.targets:check("everyone reaches first purchase by day 14 (share)", #players > 0 and (function()
			local reached = 0
			for _, p in players do
				if p.milestones.firstPurchase then
					reached += 1
				end
			end
			return reached / #players
		end)() or 0, { min = 0.99 })
	end,
})
