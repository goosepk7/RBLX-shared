--!strict
local Loc = require("@shared/Loc")
local Models = require("@shared/Screens/Models")
local Shop = require("@shared/Shop")
local Strings = require("@shared/Strings")
local T = require("@shared/Test")

local expect = T.expect

local GAME = {
	en = {
		["currency.Wins"] = "Wins",
		["currency.Gems"] = "Gems",
		["item.skin_neon"] = "Neon Stilts",
		["item.skin_candy"] = "Candy Stilts",
		["item.trail_spark"] = "Spark Trail",
		["pass.VIP"] = "VIP",
		["product.WinsSmall"] = "Bag of Wins",
		["product.SkinCrate"] = "Skin Crate",
		["board.wins"] = "Most Wins",
		["event.race"] = "Pier Race",
		["badge.FirstWin"] = "First Win",
		["badge.FirstWin.description"] = "Win your first round",
		["bonus.wins"] = "Wins bonus",
		["fail.tooNew"] = "Play a little longer first.",
		["boost.wins2x"] = "2x Wins",
		["onboarding.move"] = "Drag to move",
	},
	["pt-br"] = { ["currency.Wins"] = "Vitórias" },
}

local function newLoc(locale: string?): Loc.Loc
	local loc = Loc.new({ tables = Loc.merge(Strings, GAME :: any) })
	if locale then
		loc:setLocale(locale)
	end
	-- Missing-key warnings are part of what these specs check against; keep them quiet.
	return loc
end

local ITEMS: { Shop.ItemDef } = {
	{
		id = "skin_neon",
		category = "Cosmetics",
		slot = "skin",
		price = { currency = "Wins", amount = 50 },
		icon = "icon_skin",
	},
	{ id = "skin_candy", category = "Cosmetics", slot = "skin", price = { currency = "Wins", amount = 500 } },
	{
		id = "trail_spark",
		category = "Cosmetics",
		levels = { { currency = "Wins", amount = 10 }, { currency = "Wins", amount = 20 } },
	},
	{ id = "secret", category = "Cosmetics" },
	{ id = "lunge", category = "Boosts", levels = { { currency = "Wins", amount = 20 } } },
}
local PASSES: { Shop.PassDef } = {
	{ key = "VIP", id = 11, price = 199 },
	{ key = "NotYet", id = 0, price = 99 },
}
local PRODUCTS: { Shop.ProductDef } = {
	{ key = "WinsSmall", id = 21, price = 25, reward = { currencies = { Wins = 100 } } },
	{
		key = "SkinCrate",
		id = 22,
		price = 49,
		crate = { pool = { { item = "skin_neon", weight = 3 }, { item = "skin_candy", weight = 1 } } },
	},
	{ key = "Hidden", id = 0, price = 5, reward = { currencies = { Wins = 1 } } },
}
local CATALOG: Models.Catalog =
	{ items = ITEMS, passes = PASSES, products = PRODUCTS, currencyIcons = { Wins = "icon_wins" } }

local function snapshot(extra: { [string]: any }?): any
	local base: { [string]: any } = {
		owned = {},
		equipped = {},
		passes = {},
		blocked = {},
		unavailable = {},
		featured = { "pass:VIP", "item:skin_neon", "product:Hidden" },
		featuredEndsAt = 1_000 + 3 * 3600 + 5 * 60,
		randomItemsAllowed = true,
	}
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		base[key] = value
	end
	return base
end

local function byKey(cards: { Models.ShopCard }): { [string]: Models.ShopCard }
	local out: { [string]: Models.ShopCard } = {}
	for _, card in cards do
		out[card.key] = card
	end
	return out
end

T.describe("Screens.Models text helpers", function()
	T.it("formats durations, percents and multipliers for the locale", function()
		local loc = newLoc()
		expect(Models.duration(loc, 2 * 86400 + 3 * 3600 + 59)).toBe("2d 3h")
		expect(Models.duration(loc, 3600 + 5 * 60)).toBe("1h 05m")
		expect(Models.duration(loc, 4 * 60 + 9)).toBe("4m 09s")
		expect(Models.duration(loc, 11.2)).toBe("12s")
		expect(Models.duration(loc, -5)).toBe("0s")
		expect(Models.percent(loc, 0.25)).toBe("25%")
		expect(Models.percent(loc, 1 / 3)).toBe("33.3%")
		expect(Models.percent(loc, 0.0004)).toBe("0.04%")
		expect(Models.percent(loc, 0.000001)).toBe("0.01%")
		expect(Models.multiplier(loc, 1.25)).toBe("x1.25")
		local pt = newLoc("pt-br")
		expect(Models.percent(pt, 1 / 3)).toBe("33,3%")
		expect(Models.decimal(pt, 1234.5, 2)).toBe("1.234,5")
		expect(Models.duration(pt, 3600)).toBe("1h 00min")
	end)

	T.it("turns failures into the most specific sentence there is", function()
		local loc = newLoc()
		expect(Models.failure(loc, "codes", "expired")).toBe("That code has expired.")
		expect(Models.failure(loc, "codes", "tooNew")).toBe("Play a little longer first.")
		expect(Models.failure(loc, "codes", "rate_limited")).toBe("Slow down a little and try again.")
		expect(Models.failure(loc, "codes", "whatever")).toBe("Something went wrong. Try again in a moment.")
		local ok, message = Models.answer(loc, "shop", { ok = false, error = "timeout" })
		expect(ok).toBe(false)
		expect(message).toBe("The server didn't answer. Try again.")
		local fine, value = Models.answer(loc, "shop", { ok = true, value = { ok = true, level = 1 } })
		expect(fine).toBe(true)
		expect(value.level).toBe(1)
	end)

	T.it("lists what a reward or an applied result gives", function()
		local loc = newLoc()
		expect(Models.rewardLines(loc, {
			currencies = { Wins = 1500, Gems = 0 },
			items = { "skin_neon" },
			boosts = { { id = "wins2x", factor = 2, seconds = 1800 } },
		}, CATALOG)).toEqual({ "+1,500 Wins", "Neon Stilts", "2x Wins for 30m 00s" })
		expect(Models.rewardLines(loc, {
			ok = true,
			currencies = { Wins = 40 },
			items = {},
			duplicates = { "skin_candy" },
			boosts = { "wins2x" },
		}, CATALOG)).toEqual({ "+40 Wins", "Candy Stilts (already owned)", "2x Wins" })
		expect(Models.rewardLines(loc, nil)).toEqual({})
	end)
end)

T.describe("Screens.Models.shop", function()
	T.it("splits tabs, hides uncreated passes and products, and shows crate odds", function()
		local loc = newLoc()
		local model = Models.shop(loc, CATALOG, snapshot(), 1_000)
		expect(#model.tabs).toBe(3)
		expect(model.tabs[1].label).toBe("Boosts")
		local boosts = byKey(model.cards.boosts)
		expect(boosts.Hidden).toBeNil()
		expect(boosts.lunge.action).toBe("buy")
		expect(byKey(model.cards.cosmetics).lunge).toBeNil()
		expect(boosts.WinsSmall.price).toBe(utf8.char(0xE002) .. " 25")
		expect(boosts.WinsSmall.subtitle).toBe("+100 Wins")
		expect(boosts.SkinCrate.odds).toEqual({ "Neon Stilts: 75%", "Candy Stilts: 25%" })
		expect(boosts.SkinCrate.actionLabel).toBe("Buy crate")
		expect(byKey(model.cards.passes).NotYet).toBeNil()
		-- Items with no price that the player doesn't own aren't shown.
		expect(byKey(model.cards.cosmetics).secret).toBeNil()
		-- Featured follows the server's refs; a hidden product is dropped.
		expect(#model.featured).toBe(2)
		expect(model.featured[1].key).toBe("VIP")
		expect(model.featuredEnds).toBe("New picks in 3h 05m")
	end)

	T.it("walks an item from buy to equip to unequip, and an upgradable item to max", function()
		local loc = newLoc()
		local fresh = byKey(Models.shop(loc, CATALOG, snapshot(), 0, { Wins = 60 }).cards.cosmetics)
		expect(fresh.skin_neon.action).toBe("buy")
		expect(fresh.skin_neon.price).toBe("50")
		expect(fresh.skin_neon.priceIcon).toBe("icon_wins")
		expect(fresh.skin_neon.disabled).toBe(false)
		expect(fresh.skin_candy.disabled).toBe(true)
		expect(fresh.skin_candy.reason).toBe("You can't afford this yet.")

		local owned = byKey(
			Models.shop(loc, CATALOG, snapshot({ owned = { skin_neon = 1, trail_spark = 1 } }), 0).cards.cosmetics
		)
		expect(owned.skin_neon.action).toBe("equip")
		expect(owned.trail_spark.action).toBe("upgrade")
		expect(owned.trail_spark.price).toBe("20")
		expect(owned.trail_spark.subtitle).toBe("Level 1")

		local equipped = byKey(
			Models.shop(
				loc,
				CATALOG,
				snapshot({ owned = { skin_neon = 1, trail_spark = 2 }, equipped = { skin = "skin_neon" } }),
				0
			).cards.cosmetics
		)
		expect(equipped.skin_neon.action).toBe("unequip")
		expect(equipped.skin_neon.subtitle).toBe("Equipped")
		expect(equipped.trail_spark.action).toBe("none")
		expect(equipped.trail_spark.disabled).toBe(true)
	end)

	T.it("shows why a product or item can't be bought", function()
		local loc = newLoc()
		local model = Models.shop(
			loc,
			CATALOG,
			snapshot({
				blocked = { SkinCrate = "restricted" },
				unavailable = { skin_candy = "locked" },
				passes = { VIP = true },
			}),
			0
		)
		local crate = byKey(model.cards.boosts).SkinCrate
		expect(crate.disabled).toBe(true)
		expect(crate.reason).toBe("Crates aren't available for your account.")
		expect(byKey(model.cards.cosmetics).skin_candy.reason).toBe("Unlock it by playing first.")
		local vip = byKey(model.cards.passes).VIP
		expect(vip.action).toBe("none")
		expect(vip.actionLabel).toBe("Owned")
	end)
end)

T.describe("Screens.Models screens", function()
	T.it("rebirth: what's lost and kept, bonuses before and after, what's missing", function()
		local loc = newLoc()
		local model = Models.rebirth(loc, {
			count = 2,
			progress = 0.4,
			parts = {
				{ kind = "lifetime", have = 400, need = 1000, currency = "Wins" },
				{ kind = "gates", have = 1, need = 1 },
			} :: { any },
			canRebirth = false,
			failure = "requirements",
			bonuses = { wins = { before = 1.5, after = 1.75 } },
			resetsCurrencies = { "Wins" },
			resetsGates = true,
			keepsGates = { "pier" },
			milestone = { items = { "skin_candy" } },
		}, CATALOG)
		expect(model.count).toBe("Rebirths: 2")
		expect(model.lose).toEqual({ "All your Wins", "Unlocked areas" })
		expect(model.keep).toEqual({ "Cosmetics, passes, badges and best times", "Some unlocked areas" })
		expect(model.bonuses[1].line).toBe("Wins bonus: x1.5 -> x1.75")
		expect(model.parts).toEqual({ "Earn 1,000 Wins in total (400/1,000)" })
		expect(model.progressText).toBe("40% of the way there")
		expect(model.milestone).toEqual({ "Candy Stilts" })
		expect(model.failure).toBe("You're not ready to rebirth yet.")
		expect(model.canRebirth).toBe(false)
	end)

	T.it("codes: success lists the reward, failures say why", function()
		local loc = newLoc()
		local variant, message = Models.codeResult(
			loc,
			{ ok = true, value = { ok = true, applied = { currencies = { Wins = 50 }, items = {} } } },
			CATALOG
		)
		expect(variant).toBe("Success")
		expect(message).toBe("Code redeemed! +50 Wins")
		local bad, why = Models.codeResult(loc, { ok = true, value = { ok = false, failure = "redeemed" } })
		expect(bad).toBe("Danger")
		expect(why).toBe("You've already used this code.")
		expect((select(2, Models.codeResult(loc, { ok = false, error = "rate_limited" })))).toBe(
			"Slow down a little and try again."
		)
	end)

	T.it("leaderboards: medals, your pinned row, time boards, the reset countdown", function()
		local loc = newLoc()
		local answer = {
			board = {
				entries = {
					{ rank = 1, userId = 5, name = "five", displayName = "Five", value = 12.3456 },
					{ rank = 2, userId = 7, name = "seven", displayName = "Seven", value = 13 },
					{ rank = 4, userId = 9, name = "nine", displayName = "Nine", value = 20 },
				},
				endsAt = 100 + 90,
			},
			you = { rank = 2, value = 13 },
		}
		local model = Models.leaderboard(loc, { id = "best:gap", format = "time" }, answer, 100, 7)
		expect(model.rows[1].variant).toBe("Gold")
		expect(model.rows[1].value).toBe("12.35s")
		expect(model.rows[1].subtitle).toBe("@five")
		expect(model.rows[2].variant).toBe("Pinned")
		expect(model.rows[3].variant).toBe("Default")
		expect(model.you.rank).toBe(2)
		expect(model.you.title).toBe("You")
		expect(model.resetsIn).toBe("Resets in 1m 30s")
		local empty = Models.leaderboard(loc, { id = "wins" }, { board = { entries = {} }, you = {} }, 0, 1)
		expect(empty.title).toBe("Most Wins")
		expect(empty.empty).toBe("No scores yet. Be the first!")
		expect(empty.you.subtitle).toBe("Not ranked yet")
		expect(empty.you.value).toBe("-")
	end)

	T.it("daily: claimed, today and upcoming days, then the countdown", function()
		local loc = newLoc()
		local days: { any } =
			{ { currencies = { Wins = 5 } }, { currencies = { Wins = 10 } }, { items = { "skin_neon" } } }
		local open = Models.daily(
			loc,
			{ canClaim = true, day = 2, streak = 2, broken = false, nextAt = 0, days = days },
			0,
			CATALOG
		)
		expect(open.days[1].state).toBe("claimed")
		expect(open.days[2].state).toBe("today")
		expect(open.days[2].label).toBe("Today")
		expect(open.days[3].label).toBe("Day 3")
		expect(open.days[3].lines).toEqual({ "Neon Stilts" })
		expect(open.days[1].icon).toBe("icon_wins")
		expect(open.buttonLabel).toBe("Claim")
		expect(open.streak).toBe("2 day streak")
		local done =
			Models.daily(loc, { canClaim = false, day = 2, streak = 2, broken = false, nextAt = 3600, days = days }, 0)
		expect(done.days[2].state).toBe("claimed")
		expect(done.nextIn).toBe("Next reward in 1h 00m")
		expect(done.canClaim).toBe(false)
		local broken =
			Models.daily(loc, { canClaim = true, day = 1, streak = 1, broken = true, nextAt = 0, days = days }, 0)
		expect(broken.broken).toBe("Streak reset. Starting again at day 1.")
	end)

	T.it("events: lobby join and leave, idle countdown, results", function()
		local loc = newLoc()
		local lobby = Models.event(loc, {
			phase = "lobby",
			eventId = "race",
			endsAt = 50,
			participants = 1,
			minPlayers = 2,
			maxPlayers = 8,
			joined = false,
		}, 0)
		expect(lobby.eventName).toBe("Pier Race")
		expect(lobby.status).toBe("Starts in 50s")
		expect(lobby.players).toBe("1/8 players")
		expect(lobby.needs).toBe("Needs 2 to start")
		expect(lobby.action).toBe("join")
		local joined = Models.event(
			loc,
			{ phase = "lobby", eventId = "race", endsAt = 50, participants = 2, minPlayers = 2, joined = true },
			0
		)
		expect(joined.action).toBe("leave")
		expect(joined.needs).toBeNil()
		expect(joined.players).toBe("2 players")
		local idle = Models.event(
			loc,
			{ phase = "idle", participants = 0, minPlayers = 0, nextEventId = "race", endsAt = 120 },
			0
		)
		expect(idle.status).toBe("Next: Pier Race in 2m 00s")
		expect(idle.action).toBe("none")
		expect(idle.joined).toBe(false)
		local results = Models.event(
			loc,
			{ phase = "results", eventId = "race", participants = 2, minPlayers = 2, placements = { 7, 5 } },
			0,
			nil,
			{ [7] = "Seven" }
		)
		expect(results.placements).toEqual({ "#1 Seven", "#2 5" })
	end)

	T.it("badges and purchases: own toast vs announcement, confirmation lines", function()
		local loc = newLoc()
		local own = Models.badgeToast(
			loc,
			{ FirstWin = { key = "FirstWin", icon = "icon_star" } },
			{ key = "FirstWin" },
			1
		)
		expect(own.title).toBe("Badge earned!")
		expect(own.text).toBe("First Win: Win your first round")
		expect(own.icon).toBe("icon_star")
		local other = Models.badgeToast(loc, nil, { key = "FirstWin", userId = 2, name = "two" }, 1)
		expect(other.text).toBe("two earned First Win!")
		expect(Models.purchaseConfirmed(loc, CATALOG, { kind = "pass", key = "VIP" })).toBe("VIP is yours!")
		expect(
			Models.purchaseConfirmed(
				loc,
				CATALOG,
				{ kind = "product", key = "SkinCrate", details = { item = "skin_candy" } }
			)
		).toBe("Bought Candy Stilts!")
		expect(Models.purchaseConfirmed(loc, CATALOG, { kind = "product", key = "WinsSmall", details = {} })).toBe(
			"Thanks! Your purchase is in."
		)
	end)

	T.it("tutorial: counter and the last step's button", function()
		local loc = newLoc()
		local steps: { Models.TutorialStep } =
			{ { id = "move", textKey = "onboarding.move" }, { id = "b", textKey = "onboarding.move" } }
		local first = Models.tutorialStep(loc, steps, 1)
		expect(first.text).toBe("Drag to move")
		expect(first.counter).toBe("1/2")
		expect(first.next).toBe("Next")
		expect(Models.tutorialStep(loc, steps, 2).next).toBe("Got it!")
	end)
end)
