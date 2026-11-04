--!strict
-- Shop wired the way a game does it: Data store + Economy + Shop over the fakes, receipts
-- through the MarketplaceService fake.
local Economy = require("@shared/Economy")
local Log = require("@shared/Util/Log")
local Shop = require("@shared/Shop")
local T = require("@shared/Test")
local World = require("../Data/World")

local expect = T.expect

local restoreLog: () -> () = function() end
local logs: { Log.Entry } = {}
T.beforeEach(function()
	logs, restoreLog = Log.capture()
end)
T.afterEach(function()
	restoreLog()
end)

local PASS_2X = 1001
local PASS_VIP = 1002
local PRODUCT_WINS = 2001
local PRODUCT_CRATE = 2002
local PRODUCT_SKIP = 2003
local PRODUCT_BOOST = 2004

type Game = {
	world: World.World,
	server: World.Server,
	economy: Economy.Economy,
	shop: Shop.Shop,
	policy: any,
	skipAllowed: { value: boolean },
	skips: { number },
}

local function items(): { Shop.ItemDef }
	return {
		{ id = "skin_wood", category = "Cosmetics", slot = "skin", default = true },
		{
			id = "skin_neon",
			category = "Cosmetics",
			slot = "skin",
			price = { currency = "Wins", amount = 50 },
			featured = true,
		},
		{
			id = "skin_gold",
			category = "Cosmetics",
			slot = "skin",
			price = { currency = "Wins", amount = 500 },
			featured = true,
		},
		{
			id = "trail_spark",
			category = "Cosmetics",
			slot = "trail",
			price = { currency = "Wins", amount = 20 },
			featured = true,
		},
		{
			id = "lunge",
			category = "Boosts",
			levels = { { currency = "Wins", amount = 10 }, { currency = "Wins", amount = 25 } },
		},
		{
			id = "lamp",
			category = "Boosts",
			price = { currency = "Wins", amount = 5 },
			available = function(_who: any)
				return false, "locked"
			end,
		},
	}
end

local function newGame(name: string?, existing: World.World?): Game
	local world = existing or World.new()
	local server = world:server(name or "A", {
		template = { coins = 0, wallet = Economy.newWallet() },
	})
	local economy = Economy.new({
		currencies = { { id = "Wins", displayName = "Wins" } },
		reasons = { shop = "spend", stage = "earn" },
		task = world.clock.task,
		now = function()
			return world.clock:now()
		end,
		players = server.players,
	})
	economy:bindStore(server.store)
	local skipAllowed = { value = true }
	local skips: { number } = {}
	local policy = {
		restricted = {} :: { [number]: boolean },
		delay = 0,
		failures = 0,
		GetPolicyInfoForPlayerAsync = function(self: any, player: any)
			if self.delay > 0 then
				world.clock.task.wait(self.delay)
			end
			if self.failures > 0 then
				self.failures -= 1
				error("PolicyService unavailable")
			end
			return { ArePaidRandomItemsRestricted = self.restricted[player.UserId] == true }
		end,
	}
	local passes: { Shop.PassDef } = {
		{
			key = "DoubleWins",
			id = PASS_2X,
			price = 399,
			multipliers = { { group = "pass", factor = 2, currencies = { "Wins" } } },
		},
		{ key = "VIP", id = PASS_VIP, price = 499, multipliers = { { group = "pass", factor = 1.25 } } },
		{ key = "Later", id = 0, price = 99 },
	}
	local products: { Shop.ProductDef } = {
		{ key = "WinsSmall", id = PRODUCT_WINS, price = 99, reward = { currencies = { Wins = 100 } } },
		{
			key = "SkinCrate",
			id = PRODUCT_CRATE,
			price = 99,
			crate = {
				pool = { { item = "skin_neon", weight = 3 }, { item = "skin_gold", weight = 1 } },
				ifOwned = { Wins = 30 },
			},
		},
		{
			key = "SkipWorld",
			id = PRODUCT_SKIP,
			price = 199,
			canPurchase = function(_who: any)
				if skipAllowed.value then
					return true
				end
				return false, "tooEarly"
			end,
			grant = function(ctx: Shop.GrantContext)
				table.insert(skips, ctx.userId)
				ctx.details.world = 2
				return true
			end,
		},
		{
			key = "Boost2x",
			id = PRODUCT_BOOST,
			price = 49,
			reward = { boosts = { { id = "boost.2x", factor = 2, seconds = 1800 } } },
		},
		{ key = "NotYet", id = 0, price = 1, reward = { currencies = { Wins = 1 } } },
	}
	local shop = Shop.new({
		economy = economy,
		items = items(),
		categories = { "Boosts", "Cosmetics" },
		passes = passes,
		products = products,
		marketplace = world.mps,
		policy = policy,
		players = server.players,
		task = world.clock.task,
		now = function()
			return world.clock:now()
		end,
	})
	shop:bindStore(server.store)
	server.store:bindPlayers()
	return {
		world = world,
		server = server,
		economy = economy,
		shop = shop,
		policy = policy,
		skipAllowed = skipAllowed,
		skips = skips,
	}
end

T.describe("Shop catalog", function()
	T.it("gives default items, buys, equips and levels upgrades", function()
		local g = newGame()
		local player = g.server:join(1)
		expect(g.shop:hasItem(player, "skin_wood")).toBe(true)
		expect(g.shop:equipped(player, "skin")).toBe("skin_wood")
		expect(player:GetAttribute("Equipped_skin")).toBe("skin_wood")

		local ok, failure = g.shop:buy(player, "skin_neon")
		expect(ok).toBe(false)
		expect(failure).toBe("insufficient")
		g.economy:earn(player, "Wins", 100, "stage")
		expect((g.shop:buy(player, "skin_neon"))).toBe(true)
		expect(g.economy:balance(player, "Wins")).toBe(50)
		-- The slot was taken, so the new skin isn't auto-equipped.
		expect(g.shop:equipped(player, "skin")).toBe("skin_wood")
		expect((g.shop:equip(player, "skin_neon"))).toBe(true)
		expect(player:GetAttribute("Equipped_skin")).toBe("skin_neon")
		local _, owned = g.shop:buy(player, "skin_neon")
		expect(owned).toBe("owned")

		-- Trail slot was empty: auto-equipped.
		g.shop:buy(player, "trail_spark")
		expect(g.shop:equipped(player, "trail")).toBe("trail_spark")

		expect(g.shop:priceOf(player, "lunge")).toEqual({ currency = "Wins", amount = 10 })
		local _, _, level = g.shop:buy(player, "lunge")
		expect(level).toBe(1)
		expect(g.shop:priceOf(player, "lunge")).toEqual({ currency = "Wins", amount = 25 })
		g.economy:earn(player, "Wins", 100, "stage")
		g.shop:buy(player, "lunge")
		local _, maxed = g.shop:buy(player, "lunge")
		expect(maxed).toBe("maxed")
		expect(g.shop:level(player, "lunge")).toBe(2)
	end)

	T.it("refuses unavailable items, non-equippable equips and unowned equips", function()
		local g = newGame()
		local player = g.server:join(1)
		g.economy:earn(player, "Wins", 100, "stage")
		local _, failure = g.shop:buy(player, "lamp")
		expect(failure).toBe("locked")
		expect((select(2, g.shop:equip(player, "lunge")))).toBe("notEquippable")
		expect((select(2, g.shop:equip(player, "skin_gold")))).toBe("notOwned")
		expect((select(2, g.shop:buy(player, "nope")))).toBe("unknown")
	end)

	T.it("lists items by category in config order", function()
		local g = newGame()
		local ids: { string } = {}
		for _, item in g.shop:items("Boosts") do
			table.insert(ids, item.id)
		end
		expect(ids).toEqual({ "lunge", "lamp" })
		expect(g.shop:categories()).toEqual({ "Boosts", "Cosmetics" })
	end)

	T.it("rotates featured items deterministically per period", function()
		local a = newGame()
		local b = newGame("B", a.world)
		local now = a.world.clock:now()
		local picks, endsAt = a.shop:featured(now)
		expect(#picks).toBe(3)
		expect((b.shop:featured(now))).toEqual(picks)
		expect(endsAt > now).toBe(true)
		expect(endsAt - now <= 6 * 3600).toBe(true)
	end)

	T.it("drops equips of items that are no longer owned when loading", function()
		local g = newGame()
		g.world:seed(
			5,
			World.document({
				coins = 0,
				wallet = Economy.newWallet(),
				shop = { owned = { skin_wood = 1 }, equipped = { skin = "skin_gold", hat = "gone" }, passes = {} },
			})
		)
		local player = g.server:join(5)
		expect(g.shop:equipped(player, "skin")).toBeNil()
		expect(g.shop:equipped(player, "hat")).toBeNil()
	end)
end)

T.describe("Shop passes", function()
	T.it("applies owned passes as multipliers and caches ownership", function()
		local g = newGame()
		g.world.mps:grantPass(1, PASS_2X)
		g.world.mps:grantPass(1, PASS_VIP)
		local player = g.server:join(1)
		g.world.clock:flush()
		expect(g.shop:ownsPass(player, "DoubleWins")).toBe(true)
		expect(player:GetAttribute("Pass_VIP")).toBe(true)
		-- 2x and +25% add inside the pass group: 2.25x.
		expect((g.economy:earn(player, "Wins", 4, "stage"))).toBe(9)
		g.server:leave(player)
		expect(g.world:stored(1).data.shop.passes.DoubleWins).toBe(true)
	end)

	T.it("keeps cached passes when the ownership check fails, and drops them when it says no", function()
		local g = newGame()
		g.world.mps:grantPass(1, PASS_2X)
		local player = g.server:join(1)
		g.world.clock:flush()
		g.server:leave(player)

		local again = newGame("B", g.world)
		g.world.mps:failOwnershipChecks(6)
		local back = again.server:join(1)
		g.world.clock:advance(30)
		expect(again.shop:ownsPass(back, "DoubleWins")).toBe(true)
		again.server:leave(back)

		local third = newGame("C", g.world)
		g.world.mps:revokePass(1, PASS_2X)
		local revoked = third.server:join(1)
		g.world.clock:flush()
		expect(third.shop:ownsPass(revoked, "DoubleWins")).toBe(false)
		expect(revoked:GetAttribute("Pass_DoubleWins")).toBeNil()
		expect(third.economy:multiplier(revoked, "Wins", "stage")).toBe(1)
	end)

	T.it("applies a pass bought in the session and confirms it", function()
		local g = newGame()
		local player = g.server:join(1)
		g.world.clock:flush()
		local confirmed: { string } = {}
		g.shop.Confirmed:Connect(function(_p: any, _id: number, kind: string, key: string)
			table.insert(confirmed, kind .. ":" .. key)
		end)
		expect((g.shop:prompt(player, "pass", "DoubleWins"))).toBe(true)
		g.world.mps:completeGamePassPrompt(player, PASS_2X, true)
		expect(g.shop:ownsPass(player, "DoubleWins")).toBe(true)
		expect(confirmed).toEqual({ "pass:DoubleWins" })
		expect((select(2, g.shop:prompt(player, "pass", "DoubleWins")))).toBe("owned")
		expect((select(2, g.shop:prompt(player, "pass", "Later")))).toBe("notCreated")
	end)
end)

T.describe("Shop products", function()
	T.it("grants a currency pack exactly once per receipt, without raising lifetime", function()
		local g = newGame()
		g.world.mps:grantPass(1, PASS_2X)
		local player = g.server:join(1)
		g.world.clock:flush()
		local confirmed = 0
		g.shop.Confirmed:Connect(function()
			confirmed += 1
		end)
		local receipt, decision = g.world.mps:purchaseProduct(player, PRODUCT_WINS)
		expect(decision).toBe(g.world.mps.Decision.PurchaseGranted)
		g.world.mps:replay(receipt)
		-- Exact (the 2x pass doesn't double a pack) and once.
		expect(g.economy:balance(player, "Wins")).toBe(100)
		expect(g.economy:lifetime(player, "Wins")).toBe(0)
		expect(confirmed).toBe(1)
		expect((g.shop:snapshot(player) :: Shop.Snapshot).owned.skin_wood).toBe(1)
	end)

	T.it("rolls a crate from the PurchaseId, so a retry rolls the same item", function()
		local g = newGame()
		local player = g.server:join(1)
		g.world.clock:flush()
		local details: { any } = {}
		g.shop.Confirmed:Connect(function(_p: any, _id: number, _kind: string, _key: string, d: any)
			table.insert(details, d)
		end)
		g.world.mps:purchaseProduct(player, PRODUCT_CRATE, { purchaseId = "crate-1" })
		local first = details[1].item
		expect(g.shop:hasItem(player, first)).toBe(true)

		-- The same purchase on a fresh shop (another server after a crash) rolls the same item.
		local Rng = require("@shared/Sim/Rng")
		local crate = (g.shop:product("SkinCrate") :: Shop.ProductDef).crate :: Shop.CrateDef
		expect(Shop.rollCrate(crate, Rng.new("receipt:crate-1"):next())).toBe(first)
	end)

	T.it("pays the crate's ifOwned when the rolled item is already owned", function()
		local g = newGame()
		local player = g.server:join(1)
		g.world.clock:flush()
		g.shop:grantItem(player, "skin_neon", "admin")
		g.shop:grantItem(player, "skin_gold", "admin")
		g.world.mps:purchaseProduct(player, PRODUCT_CRATE)
		expect(g.economy:balance(player, "Wins")).toBe(30)
	end)

	T.it("shows crate odds that sum to 1", function()
		local g = newGame()
		local odds = g.shop:odds("SkinCrate")
		expect(odds).toEqual({ { item = "skin_neon", chance = 0.75 }, { item = "skin_gold", chance = 0.25 } })
	end)

	T.it("hides and refuses crates where paid random items are restricted", function()
		local g = newGame()
		g.policy.restricted[2] = true
		local allowed = g.server:join(1)
		local restricted = g.server:join(2)
		g.world.clock:flush()
		expect((g.shop:canPurchase(allowed, "SkinCrate"))).toBe(true)
		expect((select(2, g.shop:canPurchase(restricted, "SkinCrate")))).toBe("restricted")
		expect((g.shop:snapshot(restricted) :: Shop.Snapshot).blocked.SkinCrate).toBe("restricted")
		expect((select(2, g.shop:prompt(restricted, "product", "SkinCrate")))).toBe("restricted")
	end)

	T.it("counts random items as restricted until the policy answers", function()
		local g = newGame()
		g.policy.delay = 2
		local player = g.server:join(1)
		expect(g.shop:randomItemsAllowed(player)).toBe(false)
		g.world.clock:advance(3)
		expect(g.shop:randomItemsAllowed(player)).toBe(true)
	end)

	T.it("retries a failed policy lookup once", function()
		local g = newGame()
		g.policy.failures = 1
		local logs, restore = Log.capture()
		local player = g.server:join(1)
		g.world.clock:flush()
		expect(g.shop:randomItemsAllowed(player)).toBe(false)
		g.world.clock:advance(5)
		restore()
		expect(g.shop:randomItemsAllowed(player)).toBe(true)
		expect(#logs).toBe(1)
	end)

	T.it("checks canPurchase before prompting, and runs custom grants", function()
		local g = newGame()
		local player = g.server:join(1)
		g.world.clock:flush()
		g.skipAllowed.value = false
		expect((select(2, g.shop:prompt(player, "product", "SkipWorld")))).toBe("tooEarly")
		g.skipAllowed.value = true
		expect((g.shop:prompt(player, "product", "SkipWorld"))).toBe(true)
		local prompts = g.world.mps:prompts()
		expect(prompts[#prompts].id).toBe(PRODUCT_SKIP)
		g.world.mps:purchaseProduct(player, PRODUCT_SKIP)
		expect(g.skips).toEqual({ 1 })
		expect((select(2, g.shop:prompt(player, "product", "NotYet")))).toBe("notCreated")
	end)

	T.it("grants a boost product", function()
		local g = newGame()
		local player = g.server:join(1)
		g.world.mps:purchaseProduct(player, PRODUCT_BOOST)
		expect(g.economy:multiplier(player, "Wins", "stage")).toBe(2)
	end)

	T.it("leaves receipts for unknown products unprocessed and says so", function()
		local g = newGame()
		local player = g.server:join(1)
		local _, decision = g.world.mps:purchaseProduct(player, 9999)
		expect(decision).toBe(g.world.mps.Decision.NotProcessedYet)
		local found = false
		for _, entry in logs do
			if string.find(entry.message, "unknown product", 1, true) then
				found = true
			end
		end
		expect(found).toBe(true)
	end)

	T.it("rejects configs with two grant kinds or unknown crate items", function()
		local clock = T.Clock.new()
		local economy = Economy.new({
			currencies = { { id = "Wins", displayName = "Wins" } },
			reasons = { shop = "spend" },
			task = clock.task,
		})
		expect(function()
			Shop.new({
				economy = economy,
				products = {
					{
						key = "x",
						id = 1,
						price = 1,
						reward = {},
						grant = function()
							return true
						end,
					},
				},
			})
		end).toThrow("exactly one")
		expect(function()
			Shop.new({
				economy = economy,
				products = { { key = "x", id = 1, price = 1, crate = { pool = { { item = "nope", weight = 1 } } } } },
			})
		end).toThrow("unknown item")
	end)
end)
