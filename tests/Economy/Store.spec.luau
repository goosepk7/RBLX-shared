--!strict
-- Economy wired to Data the way a game does it: bindStore on a real Data.Store over the fakes.
local Economy = require("@shared/Economy")
local Log = require("@shared/Util/Log")
local T = require("@shared/Test")
local Types = require("@shared/Types")
local World = require("../Data/World")

local expect = T.expect

local restoreLog: () -> () = function() end
T.beforeEach(function()
	local _
	_, restoreLog = Log.capture()
end)
T.afterEach(function()
	restoreLog()
end)

local CURRENCIES: { Types.Currency } = {
	{ id = "Wins", displayName = "Wins" },
}

local function economyFor(world: World.World, server: World.Server): Economy.Economy
	local economy = Economy.new({
		currencies = CURRENCIES,
		reasons = { challenge = "earn" },
		task = world.clock.task,
		now = function()
			return world.clock:now()
		end,
		clock = function()
			return world.clock:clock()
		end,
		players = server.players,
	})
	economy:bindStore(server.store)
	server.store:bindPlayers()
	return economy
end

T.describe("Economy with Data", function()
	T.it("attaches each loaded profile, and the wallet saves and loads with it", function()
		local world = World.new()
		local a = world:server("A")
		local economy = economyFor(world, a)
		local player = a:join(1)
		expect(economy:isAttached(player)).toBe(true)
		economy:earn(player, "Wins", 5, "challenge")
		economy:addBoost(player, "boost.2x", 2, 1800)
		world.clock:advance(600)
		a:leave(player)
		expect(economy:isAttached(1)).toBe(false)
		local stored = world:stored(1)
		expect(stored.data.wallet.currencies.Wins.balance).toBe(5)
		expect(stored.data.wallet.boosts["boost.2x"].remaining).toBe(1200)

		-- Next session, on another server, after an hour offline.
		world.clock:advance(3600)
		local b = world:server("B")
		local economyB = economyFor(world, b)
		local again = b:join(1)
		expect(economyB:balance(again, "Wins")).toBe(5)
		expect(economyB:getBoosts(again)[1].remaining).toBe(1200)
		expect((economyB:earn(again, "Wins", 1, "challenge"))).toBe(2)
	end)

	T.it("attaches profiles that loaded before bindStore, and only detaches its own profile", function()
		local world = World.new()
		local a = world:server("A")
		a.store:bindPlayers()
		local early = a:join(1)
		assert(a.store:get(early), "expected the profile to load")
		local economy = Economy.new({
			currencies = CURRENCIES,
			reasons = { challenge = "earn" },
			task = world.clock.task,
			players = a.players,
		})
		economy:bindStore(a.store)
		expect(economy:isAttached(early)).toBe(true)

		-- A release of some other profile object for the same player leaves the wallet attached.
		local released = 0
		a.store.Released:Connect(function()
			released += 1
		end)
		local profile = a.store:get(early)
		assert(profile, "expected a profile")
		economy:attach(early, { other = true })
		a.store:releaseAsync(early)
		expect(released).toBe(1)
		expect(economy:isAttached(early)).toBe(true)
		expect(profile.data.wallet).never.toBeNil()
	end)

	T.it("keeps multipliers set at join until the player leaves", function()
		local world = World.new()
		local a = world:server("A")
		local economy = economyFor(world, a)
		local passCheck = a.players.PlayerAdded:Connect(function(player: any)
			-- A pass check that finishes before the profile loads.
			economy:setMultiplier(player, "pass.2xWins", { group = "pass", factor = 2 })
		end)
		local player = a:join(1)
		expect((economy:earn(player, "Wins", 3, "challenge"))).toBe(6)
		a:leave(player)
		expect(economy:getDiagnostics().players).toEqual({})

		-- Back without the pass (say it was refunded): last session's multiplier is gone.
		passCheck:Disconnect()
		local back = a:join(1)
		expect((economy:earn(back, "Wins", 3, "challenge"))).toBe(3)
	end)

	T.it("grants a Wins pack through processReceipt without raising lifetime Wins", function()
		local world = World.new()
		local a = world:server("A")
		local economy = economyFor(world, a)
		world.mps.ProcessReceipt = function(receipt: any)
			return a.store:processReceipt(receipt, function(profile: any, _r: any)
				local granted = economy:earn(profile.userId, "Wins", 500, "purchase")
				return granted > 0
			end)
		end
		local player = a:join(1)
		economy:setMultiplier(player, "pass.2xWins", { group = "pass", factor = 2 })
		local _, decision = world.mps:purchaseProduct(player, 2001)
		expect(decision).toBe(world.mps.Decision.PurchaseGranted)
		expect(economy:balance(player, "Wins")).toBe(500)
		expect(economy:lifetime(player, "Wins")).toBe(0)
		local stored = world:stored(1)
		expect(stored.data.wallet.currencies.Wins.balance).toBe(500)
		expect(stored.data.wallet.currencies.Wins.lifetime).toBe(0)
	end)
end)
