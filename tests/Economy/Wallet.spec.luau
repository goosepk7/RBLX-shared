--!strict
local Economy = require("@shared/Economy")
local T = require("@shared/Test")
local Types = require("@shared/Types")

local expect = T.expect
local Wallet = Economy.Wallet

local WINS: Types.Currency = { id = "Wins", displayName = "Wins" }
local GEMS: Types.Currency = { id = "Gems", displayName = "Gems", max = 100, starting = 5 }
local SPEED: Types.Currency = { id = "Speed", displayName = "Speed", integer = false }
local ALL = { WINS, GEMS, SPEED }

local function fresh(): Types.Wallet
	local wallet = Wallet.new()
	Wallet.normalize(wallet, ALL)
	return wallet
end

T.describe("Economy.Wallet.normalize", function()
	T.it("adds missing currencies at their starting balance", function()
		local wallet = fresh()
		expect(wallet.currencies.Wins).toEqual({ balance = 0, lifetime = 0, allTime = 0, carry = 0 })
		expect(wallet.currencies.Gems.balance).toBe(5)
		expect(wallet.boosts).toEqual({})
	end)

	T.it("repairs values a bad write could leave, and says what it fixed", function()
		local wallet: any = {
			currencies = {
				Wins = { balance = 0 / 0, lifetime = -4, allTime = 12.7, carry = 3 },
				Gems = { balance = 250, lifetime = 1, allTime = 1, carry = 0.5 },
				Speed = { balance = 1.5, lifetime = math.huge, allTime = 2.25, carry = 0 },
				Retired = { balance = 9 },
			},
			boosts = {
				ok = { factor = 2, remaining = 60 },
				broken = { factor = 0 / 0, remaining = 60 },
				wrongList = { factor = 2, remaining = 60, currencies = "Wins" },
				notATable = 5,
			},
		}
		local problems = Wallet.normalize(wallet, ALL)
		expect(wallet.currencies.Wins).toEqual({ balance = 0, lifetime = 0, allTime = 12, carry = 0 })
		expect(wallet.currencies.Gems.balance).toBe(100)
		expect(wallet.currencies.Gems.carry).toBe(0.5)
		expect(wallet.currencies.Speed).toEqual({ balance = 1.5, lifetime = 0, allTime = 2.25, carry = 0 })
		-- Currencies the game no longer defines are kept, not deleted.
		expect(wallet.currencies.Retired).toEqual({ balance = 9 })
		expect(wallet.boosts.ok).never.toBeNil()
		expect(wallet.boosts.broken).toBeNil()
		expect(wallet.boosts.wrongList).toBeNil()
		expect(wallet.boosts.notATable).toBeNil()
		expect(problems[1]).toMatch("^Wins%.balance was %-?nan, set to 0$")
		expect(problems).toContain("Wins.lifetime was -4, set to 0")
		expect(problems).toContain("Gems.balance was 250, set to 100")
		expect(#problems).toBe(8)
	end)

	T.it("replaces tables that aren't tables", function()
		local wallet: any = { currencies = "oops", boosts = 3 }
		local problems = Wallet.normalize(wallet, ALL)
		expect(wallet.currencies.Wins.balance).toBe(0)
		expect(wallet.boosts).toEqual({})
		expect(#problems).toBe(2)
		local repeated = Wallet.normalize(wallet, ALL)
		expect(#repeated).toBe(0)
	end)
end)

T.describe("Economy.Wallet.earn", function()
	T.it("carries fractions on whole-number currencies so totals match the multiplier", function()
		local wallet = fresh()
		local first = Wallet.earn(wallet, WINS, 2, 1.25, true)
		expect(first.granted).toBe(2)
		expect(wallet.currencies.Wins.carry).toBe(0.5)
		local second = Wallet.earn(wallet, WINS, 2, 1.25, true)
		expect(second.granted).toBe(3)
		expect(wallet.currencies.Wins.carry).toBe(0)

		local long = fresh()
		for _ = 1, 100 do
			Wallet.earn(long, WINS, 1, 1.1, true)
		end
		expect(long.currencies.Wins.balance).toBe(110)
	end)

	T.it("pays out fractions that only add up to a whole with rounding error", function()
		local wallet = fresh()
		Wallet.earn(wallet, WINS, 0.1, 1, true)
		Wallet.earn(wallet, WINS, 0.2, 1, true)
		local last = Wallet.earn(wallet, WINS, 0.7, 1, true)
		expect(last.granted).toBe(1)
		expect(wallet.currencies.Wins.balance).toBe(1)
	end)

	T.it("keeps exact fractions on fractional currencies", function()
		local wallet = fresh()
		Wallet.earn(wallet, SPEED, 0.5, 1.5, true)
		expect(wallet.currencies.Speed.balance).toBe(0.75)
		expect(wallet.currencies.Speed.carry).toBe(0)
	end)

	T.it("stops the balance at the cap but counts the whole earning toward lifetime", function()
		local wallet = fresh()
		Wallet.set(wallet, GEMS, 95)
		local result = Wallet.earn(wallet, GEMS, 10, 1, true)
		expect(result).toEqual({ earned = 10, granted = 5, clamped = 5, balance = 100 })
		expect(wallet.currencies.Gems.lifetime).toBe(10)
		expect(wallet.currencies.Gems.allTime).toBe(10)
		local full = Wallet.earn(wallet, GEMS, 3, 1.5, true)
		expect(full.granted).toBe(0)
		expect(full.clamped).toBe(4)
		-- The fraction that didn't fit isn't carried either.
		expect(wallet.currencies.Gems.carry).toBe(0)
	end)

	T.it("never passes MAX_BALANCE, however large the earning", function()
		local wallet = fresh()
		local result = Wallet.earn(wallet, WINS, math.huge, 100, true)
		expect(result.balance).toBe(Wallet.MAX_BALANCE)
		expect(wallet.currencies.Wins.lifetime).toBe(Wallet.MAX_BALANCE)
		Wallet.earn(wallet, WINS, 1e15, 100, true)
		expect(wallet.currencies.Wins.balance).toBe(Wallet.MAX_BALANCE)
		expect(wallet.currencies.Wins.allTime).toBe(Wallet.MAX_BALANCE)
	end)

	T.it("adds to lifetime only when asked; allTime always grows", function()
		local wallet = fresh()
		Wallet.earn(wallet, WINS, 7, 1, false)
		expect(wallet.currencies.Wins.balance).toBe(7)
		expect(wallet.currencies.Wins.lifetime).toBe(0)
		expect(wallet.currencies.Wins.allTime).toBe(7)
	end)
end)

T.describe("Economy.Wallet spending and setting", function()
	T.it("checks amounts", function()
		expect(Wallet.validAmount(WINS, 3)).toBe(true)
		expect(Wallet.validAmount(WINS, 0)).toBe(true)
		expect(Wallet.validAmount(WINS, 2.5)).toBe(false)
		expect(Wallet.validAmount(WINS, -1)).toBe(false)
		expect(Wallet.validAmount(WINS, 0 / 0)).toBe(false)
		expect(Wallet.validAmount(WINS, math.huge)).toBe(false)
		expect(Wallet.validAmount(WINS, "3")).toBe(false)
		expect(Wallet.validAmount(SPEED, 2.5)).toBe(true)
	end)

	T.it("spends what the balance covers", function()
		local wallet = fresh()
		Wallet.earn(wallet, WINS, 10, 1, true)
		expect(Wallet.canAfford(wallet, WINS, 10)).toBe(true)
		expect(Wallet.canAfford(wallet, WINS, 11)).toBe(false)
		expect(Wallet.spend(wallet, WINS, 4)).toBe(6)
		-- Spending never lowers lifetime: Stilts height stays.
		expect(wallet.currencies.Wins.lifetime).toBe(10)
	end)

	T.it("sets balances within the cap, optionally resets lifetime, and drops the carry", function()
		local wallet = fresh()
		Wallet.earn(wallet, WINS, 3, 1.5, true)
		expect(wallet.currencies.Wins.carry).toBe(0.5)
		expect(Wallet.set(wallet, WINS, 0, 0)).toBe(0)
		expect(wallet.currencies.Wins).toEqual({ balance = 0, lifetime = 0, allTime = 4, carry = 0 })
		expect(Wallet.set(wallet, GEMS, 500)).toBe(100)
		expect(Wallet.set(wallet, WINS, 7.9)).toBe(7)
	end)
end)
