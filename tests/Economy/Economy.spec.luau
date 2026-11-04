--!strict
local ClockModule = require("@shared/Test/Clock")
local Economy = require("@shared/Economy")
local Log = require("@shared/Util/Log")
local T = require("@shared/Test")
local Types = require("@shared/Types")

local expect = T.expect

local logs: { Log.Entry } = {}
local restoreLog: () -> () = function() end
T.beforeEach(function()
	logs, restoreLog = Log.capture()
end)
T.afterEach(function()
	restoreLog()
end)

local function logged(level: Log.Level, text: string): boolean
	for _, entry in logs do
		if entry.level == level and string.find(entry.message, text, 1, true) then
			return true
		end
	end
	return false
end

local CURRENCIES: { Types.Currency } = {
	{ id = "Wins", displayName = "Wins", leaderstat = true, icon = "icon_wins" },
	{ id = "Gems", displayName = "Gems", max = 1000 },
	{ id = "Speed", displayName = "Speed", integer = false },
}

type Rig = {
	clock: ClockModule.Clock,
	players: any,
	economy: Economy.Economy,
	stats: { [string]: { Value: number } },
	join: (self: Rig, userId: number, data: any?) -> (any, any),
}

local function rig(overrides: { [string]: any }?): Rig
	local clock = T.Clock.new()
	local players = T.Fakes.Players.new()
	local stats: { [string]: { Value: number } } = {}
	local options: any = {
		currencies = CURRENCIES,
		reasons = {
			challenge = "earn",
			event = "earn",
			daily = { kind = "earn", lifetime = false },
			shop = "spend",
			starterPack = { kind = "grant", lifetime = true },
		},
		task = clock.task,
		now = function()
			return clock:now()
		end,
		clock = function()
			return clock:clock()
		end,
		players = players,
		createLeaderstat = function(player: any, currency: Types.Currency): any
			local stat = { Value = -1 }
			stats[tostring(player.UserId) .. ":" .. currency.id] = stat
			return stat
		end,
	}
	local extra: { [string]: any } = overrides or {}
	for key, value in extra do
		options[key] = value
	end
	local r = {
		clock = clock,
		players = players,
		economy = Economy.new(options),
		stats = stats,
	} :: Rig
	function r.join(self: Rig, userId: number, data: any?): (any, any)
		local player = self.players:join({ UserId = userId, Name = "player" .. tostring(userId) })
		local profileData = data or {}
		self.economy:attach(player, profileData)
		return player, profileData
	end
	return r
end

T.describe("Economy earning", function()
	T.it("earns with the player's multipliers and keeps whole numbers", function()
		local r = rig()
		local player, data = r:join(1)
		expect((r.economy:earn(player, "Wins", 4, "challenge"))).toBe(4)
		r.economy:setMultiplier(player, "pass.2xWins", { group = "pass", factor = 2 })
		expect((r.economy:earn(player, "Wins", 4, "challenge"))).toBe(8)
		-- VIP shares the pass group: 2x and +25% make 2.25x.
		r.economy:setMultiplier(player, "pass.vip", { group = "pass", factor = 1.25 })
		expect((r.economy:earn(player, "Wins", 2, "challenge"))).toBe(4)
		expect(data.wallet.currencies.Wins.carry).toBe(0.5)
		expect((r.economy:earn(player, "Wins", 2, "challenge"))).toBe(5)
		expect(r.economy:balance(player, "Wins")).toBe(21)
		expect(r.economy:lifetime(player, "Wins")).toBe(21)
		expect(r.economy:allTime(1, "Wins")).toBe(21)
	end)

	T.it("multiplies rebirth x pass x event x boost", function()
		local r = rig()
		local player = r:join(1)
		r.economy:setMultiplier(player, "rebirth", { group = "rebirth", factor = 1.5 })
		r.economy:setMultiplier(player, "pass.2xWins", { group = "pass", factor = 2, currencies = { "Wins" } })
		r.economy:setGlobalMultiplier("weekend", { group = "event", factor = 2, expiresAt = r.clock:now() + 3600 })
		r.economy:addBoost(player, "boost.2x", 2, 1800)
		local total, groups = r.economy:multiplierBreakdown(player, "Wins", "challenge")
		expect(groups).toEqual({ rebirth = 1.5, pass = 2, event = 2, boost = 2 })
		expect(total).toBe(12)
		expect((r.economy:earn(player, "Wins", 10, "challenge"))).toBe(120)
		-- The pass is for Wins only.
		expect(r.economy:multiplier(player, "Gems", "challenge")).toBe(6)
		-- The weekend event ends on time.
		r.clock:advance(3600)
		expect(r.economy:multiplier(player, "Gems", "challenge")).toBe(1.5)
	end)

	T.it("limits a source to its reasons (Lucky Events doubles event rewards only)", function()
		local r = rig()
		local player = r:join(1)
		r.economy:setMultiplier(player, "pass.lucky", { group = "lucky", factor = 2, reasons = { "event" } })
		expect((r.economy:earn(player, "Wins", 5, "challenge"))).toBe(5)
		expect((r.economy:earn(player, "Wins", 5, "event"))).toBe(10)
	end)

	T.it("grants exact, whole amounts that never count toward lifetime", function()
		local r = rig()
		local player = r:join(1)
		r.economy:setMultiplier(player, "pass.2xWins", { group = "pass", factor = 2 })
		r.economy:addBoost(player, "boost.2x", 2, 1800)
		expect((r.economy:earn(player, "Wins", 500, "purchase"))).toBe(500)
		expect(r.economy:balance(player, "Wins")).toBe(500)
		-- Nothing sold raises a lifetime gate (Stilts height).
		expect(r.economy:lifetime(player, "Wins")).toBe(0)
		expect(r.economy:allTime(player, "Wins")).toBe(500)
		local granted, failure = r.economy:earn(player, "Wins", 2.5, "code")
		expect(granted).toBe(0)
		expect(failure).toBe("invalidAmount")
		-- A grant reason can opt into lifetime, and an earn reason out of it.
		r.economy:earn(player, "Wins", 10, "starterPack")
		r.economy:earn(player, "Wins", 10, "daily")
		expect(r.economy:lifetime(player, "Wins")).toBe(10)
		-- daily is still multiplied (2x pass, 2x boost): 10 + 40.
		expect(r.economy:balance(player, "Wins")).toBe(550)
	end)

	T.it("stops at the cap, counts the overflow, and warns", function()
		local r = rig()
		local player = r:join(1)
		expect((r.economy:earn(player, "Gems", 990, "challenge"))).toBe(990)
		expect((r.economy:earn(player, "Gems", 25, "challenge"))).toBe(10)
		expect(r.economy:balance(player, "Gems")).toBe(1000)
		expect(r.economy:lifetime(player, "Gems")).toBe(1015)
		expect(logged("warn", "Gems is at its cap; 15 not added")).toBe(true)
		local ledger = r.economy:getLedger(player)
		expect(ledger[2].delta).toBe(10)
		expect(ledger[2].clamped).toBe(15)
		expect(r.economy:getTotals().Gems.clamped).toBe(15)
		-- At the cap an earning still lands in the ledger, with nothing added.
		expect((r.economy:earn(player, "Gems", 5, "challenge"))).toBe(0)
		expect(#r.economy:getLedger(player)).toBe(3)
	end)

	T.it("keeps fractions on fractional currencies and carries them on whole ones", function()
		local r = rig()
		local player, data = r:join(1)
		expect((r.economy:earn(player, "Speed", 0.25, "challenge"))).toBe(0.25)
		expect((r.economy:earn(player, "Wins", 0.5, "challenge"))).toBe(0)
		expect(#r.economy:getLedger(player)).toBe(1)
		expect(data.wallet.currencies.Wins.carry).toBe(0.5)
		expect((r.economy:earn(player, "Wins", 0.5, "challenge"))).toBe(1)
	end)
end)

T.describe("Economy spending and setting", function()
	T.it("spends only what the player has", function()
		local r = rig()
		local player = r:join(1)
		r.economy:earn(player, "Wins", 30, "challenge")
		expect(r.economy:canAfford(player, "Wins", 30)).toBe(true)
		expect(r.economy:canAfford(player, "Wins", 31)).toBe(false)
		local ok, failure = r.economy:spend(player, "Wins", 31, "shop")
		expect(ok).toBe(false)
		expect(failure).toBe("insufficient")
		expect(r.economy:balance(player, "Wins")).toBe(30)
		expect(logged("warn", "insufficient")).toBe(false)
		expect((r.economy:spend(player, "Wins", 12, "shop"))).toBe(true)
		expect(r.economy:balance(player, "Wins")).toBe(18)
		-- Spending never lowers lifetime.
		expect(r.economy:lifetime(player, "Wins")).toBe(30)
		expect((r.economy:spend(player, "Wins", 0, "shop"))).toBe(true)
		expect(#r.economy:getLedger(player)).toBe(2)
		for _, amount in { -1, 2.5, 0 / 0, math.huge } do
			local spent, why = r.economy:spend(player, "Wins", amount, "shop")
			expect(spent).toBe(false)
			expect(why).toBe("invalidAmount")
		end
		expect(r.economy:balance(player, "Wins")).toBe(18)
	end)

	T.it("spendMany takes every cost or none", function()
		local r = rig()
		local player = r:join(1)
		r.economy:earn(player, "Wins", 50, "challenge")
		r.economy:earn(player, "Gems", 3, "challenge")
		local ok, failure = r.economy:spendMany(player, { Wins = 20, Gems = 5 }, "shop")
		expect(ok).toBe(false)
		expect(failure).toBe("insufficient")
		expect(r.economy:balance(player, "Wins")).toBe(50)
		expect(r.economy:balance(player, "Gems")).toBe(3)

		-- Handlers run after every cost is taken, so they see the whole purchase.
		local seen: { string } = {}
		r.economy.Changed:Connect(function(_player: any, _userId: number, currency: string, balance: number)
			table.insert(
				seen,
				string.format(
					"%s=%d (Wins %d, Gems %d)",
					currency,
					balance,
					r.economy:balance(player, "Wins"),
					r.economy:balance(player, "Gems")
				)
			)
		end)
		expect((r.economy:spendMany(player, { Wins = 20, Gems = 3 }, "shop"))).toBe(true)
		expect(seen).toEqual({ "Gems=0 (Wins 30, Gems 0)", "Wins=30 (Wins 30, Gems 0)" })
		local unknown, why = r.economy:spendMany(player, { Wins = 1, Tokens = 1 }, "shop")
		expect(unknown).toBe(false)
		expect(why).toBe("unknownCurrency")
		expect(r.economy:balance(player, "Wins")).toBe(30)
	end)

	T.it("sets balances outright for rebirths and admin tools", function()
		local r = rig()
		local player = r:join(1)
		r.economy:earn(player, "Wins", 250, "challenge")
		r.economy:spend(player, "Wins", 40, "shop")
		expect((r.economy:set(player, "Wins", 0, "rebirth", { lifetime = 0 }))).toBe(true)
		expect(r.economy:balance(player, "Wins")).toBe(0)
		expect(r.economy:lifetime(player, "Wins")).toBe(0)
		expect(r.economy:allTime(player, "Wins")).toBe(250)
		local entry = r.economy:getLedger(player, 1)[1]
		expect(entry.kind).toBe("adjust")
		expect(entry.delta).toBe(-210)
		expect((r.economy:set(player, "Gems", 5000, "admin"))).toBe(true)
		expect(r.economy:balance(player, "Gems")).toBe(1000)
		local ok, failure = r.economy:set(player, "Wins", 1.5, "admin")
		expect(ok).toBe(false)
		expect(failure).toBe("invalidAmount")
		local wrong, why = r.economy:set(player, "Wins", 5, "challenge")
		expect(wrong).toBe(false)
		expect(why).toBe("wrongReasonKind")
	end)

	T.it("reports bad calls without changing anything", function()
		local r = rig()
		local player = r:join(1)
		local stranger = r.players:join({ UserId = 2 })
		local cases: { { any } } = {
			{ stranger, "Wins", 1, "challenge", "notLoaded" },
			{ player, "Tokens", 1, "challenge", "unknownCurrency" },
			{ player, "Wins", 1, "jackpot", "unknownReason" },
			{ player, "Wins", 1, "shop", "wrongReasonKind" },
			{ player, "Wins", -3, "challenge", "invalidAmount" },
			{ player, "Wins", 0 / 0, "challenge", "invalidAmount" },
			{ player, "Wins", math.huge, "challenge", "invalidAmount" },
		}
		for _, case in cases do
			local granted, failure = r.economy:earn(case[1], case[2], case[3], case[4])
			expect(granted).toBe(0)
			expect(failure).toBe(case[5])
		end
		expect(r.economy:balance(player, "Wins")).toBe(0)
		expect(#r.economy:getLedger(player)).toBe(0)
		expect(logged("warn", "notLoaded: no wallet attached for 2")).toBe(true)
		expect(logged("warn", "unknownReason: jackpot")).toBe(true)
		local spent, failure = r.economy:spend(player, "Wins", 1, "challenge")
		expect(spent).toBe(false)
		expect(failure).toBe("wrongReasonKind")
		expect(r.economy:balance(stranger, "Wins")).toBe(0)
		expect(r.economy:canAfford(stranger, "Wins", 0)).toBe(false)
		expect(r.economy:multiplier(stranger, "Wins", "challenge")).toBe(1)
	end)
end)

T.describe("Economy boosts", function()
	T.it("count down in play time only, and live in the saved wallet", function()
		local r = rig()
		local player, data = r:join(1)
		local changes = 0
		r.economy.BoostsChanged:Connect(function()
			changes += 1
		end)
		expect(r.economy:addBoost(player, "boost.2x", 2, 1800)).toBe(1800)
		expect(changes).toBe(1)
		expect((r.economy:earn(player, "Wins", 3, "challenge"))).toBe(6)
		r.clock:advance(900)
		expect(r.economy:getBoosts(player)).toEqual({ { id = "boost.2x", factor = 2, remaining = 900 } })

		-- The player leaves; the wallet (as Data would save it) keeps the time left.
		r.economy:detach(player)
		expect(data.wallet.boosts["boost.2x"].remaining).toBe(900)
		r.clock:advance(3600)
		r.economy:attach(player, data)
		expect(r.economy:getBoosts(player)[1].remaining).toBe(900)
		r.clock:advance(899)
		expect(r.economy:multiplier(player, "Wins", "challenge")).toBe(2)
		r.clock:advance(5)
		expect(r.economy:getBoosts(player)).toEqual({})
		expect(data.wallet.boosts["boost.2x"]).toBeNil()
		expect(changes).toBe(2)
		expect((r.economy:earn(player, "Wins", 3, "challenge"))).toBe(3)
	end)

	T.it("adds time to a boost bought again, and can limit it to some currencies", function()
		local r = rig()
		local player = r:join(1)
		r.economy:addBoost(player, "boost.2x", 2, 1800)
		r.clock:advance(600)
		expect(r.economy:addBoost(player, "boost.2x", 2, 1800)).toBe(3000)
		r.economy:addBoost(player, "boost.gems", 3, 60, { "Gems" })
		expect(r.economy:multiplier(player, "Wins", "challenge")).toBe(2)
		-- Two boosts share the boost group: their bonuses add (2x and 3x make 4x).
		expect(r.economy:multiplier(player, "Gems", "challenge")).toBe(4)
		r.economy:removeBoost(player, "boost.2x")
		expect(r.economy:multiplier(player, "Wins", "challenge")).toBe(1)
		expect(function()
			r.economy:addBoost(player, "bad", 0, 60)
		end).toThrow("factor")
		expect(function()
			r.economy:addBoost(player, "bad", 2, 0 / 0)
		end).toThrow("seconds")
	end)

	T.it("shows each boost's end time to the client and clears it when it ends", function()
		local r = rig()
		local player = r:join(1)
		local started = r.clock:now()
		r.economy:addBoost(player, "boost.2x", 2, 60)
		local name = Economy.boostAttributeName("boost.2x")
		expect(name).toBe("Boost_boost_2x")
		expect(player:GetAttribute(name)).toBe(started + 60)
		r.clock:advance(65)
		expect(player:GetAttribute(name)).toBeNil()
	end)
end)

T.describe("Economy for clients and analytics", function()
	T.it("mirrors balances into attributes and leaderstats", function()
		local r = rig()
		local player = r:join(1)
		expect(player:GetAttribute("Currency_Wins")).toBe(0)
		expect(r.stats["1:Wins"].Value).toBe(0)
		expect(r.stats["1:Gems"]).toBeNil()
		r.economy:earn(player, "Wins", 7, "challenge")
		r.economy:spend(player, "Wins", 2, "shop")
		expect(player:GetAttribute(Economy.attributeName("Wins"))).toBe(5)
		expect(player:GetAttribute(Economy.lifetimeAttributeName("Wins"))).toBe(7)
		expect(r.stats["1:Wins"].Value).toBe(5)

		local seen: { number } = {}
		local connection = Economy.observe(player, "Wins", function(balance: number)
			table.insert(seen, balance)
		end)
		r.economy:earn(player, "Wins", 1, "challenge")
		connection:Disconnect()
		r.economy:earn(player, "Wins", 1, "challenge")
		expect(seen).toEqual({ 5, 6 })
	end)

	T.it("keeps the newest ledger entries and sums totals by reason", function()
		local r = rig({ ledgerSize = 3 })
		local player = r:join(1)
		local other = r:join(2)
		local entries: { Types.LedgerEntry } = {}
		r.economy.Transaction:Connect(function(entry: Types.LedgerEntry)
			table.insert(entries, entry)
			entry.delta = 999 -- a copy: the ledger is unaffected
		end)
		r.economy:setMultiplier(player, "pass", { group = "pass", factor = 2 })
		r.economy:earn(player, "Wins", 5, "challenge")
		r.economy:earn(player, "Wins", 3, "event")
		r.economy:earn(other, "Wins", 4, "challenge")
		r.economy:spend(player, "Wins", 6, "shop")
		r.economy:earn(player, "Gems", 100, "purchase")
		r.economy:set(player, "Gems", 40, "admin")

		local ledger = r.economy:getLedger(player)
		expect(#ledger).toBe(3)
		expect(ledger[1].reason).toBe("shop")
		expect(ledger[1].delta).toBe(-6)
		expect(ledger[1].balance).toBe(10)
		expect(ledger[3].kind).toBe("adjust")
		expect(ledger[3].delta).toBe(-60)
		expect(#r.economy:getLedger(player, 1)).toBe(1)
		expect(#entries).toBe(6)
		expect(entries[1].base).toBe(5)
		expect(entries[1].multiplier).toBe(2)
		expect(entries[1].userId).toBe(1)
		expect(entries[1].at).toBe(r.clock:now())

		local totals = r.economy:getTotals()
		expect(totals.Wins.earned).toEqual({ challenge = 14, event = 6 })
		expect(totals.Wins.spent).toEqual({ shop = 6 })
		expect(totals.Gems.earned).toEqual({ purchase = 100 })
		expect(totals.Gems.adjusted).toEqual({ admin = -60 })
		totals.Wins.earned.challenge = 0
		expect(r.economy:getTotals().Wins.earned.challenge).toBe(14)
	end)

	T.it("reports diagnostics for the Admin panel", function()
		local r = rig()
		local player = r:join(1)
		r:join(2)
		r.economy:setMultiplier(player, "pass", { group = "pass", factor = 2 })
		r.economy:setGlobalMultiplier("weekend", { group = "event", factor = 2 })
		r.economy:addBoost(player, "boost.2x", 2, 60)
		r.economy:earn(player, "Wins", 1, "challenge")
		local diag = r.economy:getDiagnostics()
		expect(diag.currencies).toEqual({ "Wins", "Gems", "Speed" })
		expect(diag.attached).toBe(2)
		expect(diag.globalMultipliers.weekend.factor).toBe(2)
		expect(diag.players[1].userId).toBe(1)
		expect(diag.players[1].balances.Wins).toBe(8)
		expect(diag.players[1].lifetimes.Wins).toBe(8)
		expect(diag.players[1].multipliers.pass.factor).toBe(2)
		expect(diag.players[1].boosts[1].id).toBe("boost.2x")
		expect(diag.players[2].balances.Wins).toBe(0)
		expect(diag.totals.Wins.earned.challenge).toBe(8)
		r.economy:setGlobalMultiplier("weekend", nil)
		expect(r.economy:getDiagnostics().globalMultipliers).toEqual({})
	end)
end)

T.describe("Economy wallets", function()
	T.it("creates a wallet in the profile data and repairs a damaged one", function()
		local r = rig()
		local _, data = r:join(1, { coins = 3 })
		expect(data.wallet.currencies.Wins.balance).toBe(0)
		expect(data.coins).toBe(3)

		local damaged: any = {
			wallet = { currencies = { Wins = { balance = 0 / 0, lifetime = 5, allTime = 5, carry = 0 } }, boosts = {} },
		}
		local player = r:join(2, damaged)
		expect(r.economy:balance(player, "Wins")).toBe(0)
		expect(r.economy:lifetime(player, "Wins")).toBe(5)
		expect(logged("error", "wallet of 2: Wins.balance was")).toBe(true)

		-- Game code that replaces the wallet doesn't break the economy.
		damaged.wallet = nil
		expect((r.economy:earn(player, "Wins", 2, "challenge"))).toBe(2)
		expect(damaged.wallet.currencies.Wins.balance).toBe(2)
	end)

	T.it("uses a custom wallet field, and the same wallet a second time keeps its ledger", function()
		local r = rig({ walletField = "money" })
		local player, data = r:join(1)
		r.economy:earn(player, "Wins", 2, "challenge")
		expect(data.money.currencies.Wins.balance).toBe(2)
		r.economy:attach(player, data)
		expect(#r.economy:getLedger(player)).toBe(1)
		expect(r.economy:isAttached(1)).toBe(true)
		r.economy:detach(1)
		expect(r.economy:isAttached(player)).toBe(false)
		expect(r.economy:getLedger(player)).toEqual({})

		-- A sim's stand-in player (no attributes) works too.
		local standIn = { UserId = 9 }
		r.economy:attach(standIn, {})
		expect((r.economy:earn(standIn, "Wins", 3, "challenge"))).toBe(3)
	end)

	T.it("keeps multipliers set before the wallet loads", function()
		local r = rig()
		local player = r.players:join({ UserId = 1 })
		r.economy:setMultiplier(player, "pass.2xWins", { group = "pass", factor = 2 })
		r.economy:attach(player, {})
		expect((r.economy:earn(player, "Wins", 1, "challenge"))).toBe(2)
		r.economy:setMultiplier(player, "pass.2xWins", nil)
		expect(r.economy:multiplier(player, "Wins", "challenge")).toBe(1)
		r.economy:setMultiplier(player, "pass.vip", { group = "pass", factor = 1.25 })
		r.economy:clearMultipliers(player)
		expect(r.economy:multiplier(player, "Wins", "challenge")).toBe(1)
		expect(function()
			r.economy:setMultiplier(player, "bad", { group = "pass", factor = -1 })
		end).toThrow("greater than 0")
	end)
end)

T.describe("Economy.new", function()
	T.it("checks its options up front", function()
		local function make(options: any)
			return function()
				options.task = T.Clock.new().task
				Economy.new(options)
			end
		end
		expect(make({ currencies = {} })).toThrow("non-empty list")
		expect(make({ currencies = { { id = "Wins Total", displayName = "Wins" } } })).toThrow("letters, digits")
		expect(make({ currencies = { { id = "Wins", displayName = "Wins" }, { id = "Wins", displayName = "W" } } })).toThrow(
			"duplicate currency Wins"
		)
		expect(make({ currencies = { { id = "Wins" } } })).toThrow("needs a displayName")
		expect(make({ currencies = { { id = "Wins", displayName = "Wins", max = 1e16 } } })).toThrow("MAX_BALANCE")
		expect(make({ currencies = CURRENCIES, reasons = { win = "earnz" } })).toThrow("unknown kind earnz")
		expect(make({ currencies = CURRENCIES, reasons = { win = 5 } })).toThrow("must be a kind")
		expect(make({ currencies = CURRENCIES, maxMultiplier = 0.5 })).toThrow("maxMultiplier")
		expect(make({ currencies = CURRENCIES, ledgerSize = 2.5 })).toThrow("ledgerSize")
		expect(make({ currencies = CURRENCIES, tickInterval = 0 })).toThrow("tickInterval")
		expect(make({ currencies = CURRENCIES })).never.toThrow()
	end)

	T.it("caps the total multiplier", function()
		local r = rig({ maxMultiplier = 10 })
		local player = r:join(1)
		r.economy:setMultiplier(player, "a", { group = "a", factor = 5 })
		r.economy:setMultiplier(player, "b", { group = "b", factor = 5 })
		expect((r.economy:earn(player, "Wins", 1, "challenge"))).toBe(10)
	end)
end)
