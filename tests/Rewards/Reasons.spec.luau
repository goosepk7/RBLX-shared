--!strict
-- An Economy reason that isn't declared makes earn pay 0. Every module that pays with a
-- configured reason must refuse to start without it, and Rewards.apply must refuse rather than
-- report a paid claim.
local Daily = require("@shared/Daily")
local Economy = require("@shared/Economy")
local Events = require("@shared/Events")
local Progression = require("@shared/Progression")
local Rebirth = require("@shared/Rebirth")
local Rewards = require("@shared/Rewards")
local Shop = require("@shared/Shop")
local T = require("@shared/Test")

local expect = T.expect

local function economyWith(reasons: { [string]: any }?): Economy.Economy
	return Economy.new({
		currencies = { { id = "Wins", displayName = "Wins" } },
		reasons = reasons,
		task = T.Clock.new().task,
	})
end

T.describe("Economy reasons", function()
	T.it("reasonKind reports declared and built-in kinds", function()
		local economy = economyWith({ stage = "earn" })
		expect(economy:reasonKind("stage")).toBe("earn")
		expect(economy:reasonKind("code")).toBe("grant")
		expect(economy:reasonKind("rebirth")).toBe("adjust")
		expect(economy:reasonKind("daily")).toBeNil()
	end)

	T.it("every paying module refuses to start with an undeclared reason", function()
		local economy = economyWith()
		local reward = { currencies = { Wins = 1 } }
		expect(function()
			Daily.new({ economy = economy, days = { reward } })
		end).toThrow('Daily.new: Economy reason "daily" must be declared as earn or grant')
		expect(function()
			Progression.new({
				economy = economy,
				stages = { { id = "a", reward = { currency = "Wins", amount = 1 } } },
			})
		end).toThrow('Progression.new: Economy reason "stage"')
		expect(function()
			Events.new({
				economy = economy,
				events = { { id = "race", durationSeconds = 10, rewards = { participation = reward } } },
				every = 600,
			})
		end).toThrow('Events.new: Economy reason "event"')
		expect(function()
			Rebirth.new({
				economy = economy,
				requires = { lifetime = { currency = "Wins", amount = 10 } },
				resets = { currencies = { "Wins" } },
				milestones = { [1] = reward },
			} :: any)
		end).toThrow('Rebirth.new: Economy reason "rebirthReward"')
		expect(function()
			Shop.new({ economy = economy, marketplace = T.Fakes.MarketplaceService.new() })
		end).toThrow('Shop.new: Economy reason "shop" must be declared as spend')
	end)

	T.it("a reason with the wrong kind is refused too", function()
		local economy = economyWith({ daily = "spend" })
		expect(function()
			Daily.new({ economy = economy, days = { { currencies = { Wins = 1 } } } })
		end).toThrow('(it is "spend")')
	end)

	T.it("modules that never pay don't need the reason", function()
		local economy = economyWith()
		expect(function()
			Progression.new({ economy = economy, stages = { { id = "a" } } })
			Events.new({ economy = economy, events = { { id = "race", durationSeconds = 10 } }, every = 600 })
		end).never.toThrow()
	end)

	T.it("Rewards.apply refuses an undeclared reason without changing anything", function()
		local economy = economyWith()
		local data = { wallet = Economy.newWallet() }
		economy:attach(1, data)
		local applied = Rewards.apply({ economy = economy }, 1, { currencies = { Wins = 5 } }, "daily")
		expect(applied.ok).toBe(false)
		expect(applied.failure).toBe("unknownReason")
		expect(economy:balance(1, "Wins")).toBe(0)
		expect((Rewards.apply({ economy = economy }, 1, { currencies = { Wins = 5 } }, "code")).ok).toBe(true)
	end)
end)
