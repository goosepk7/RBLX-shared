--!strict
local Daily = require("@shared/Daily")
local Rig = require("./Rig")
local Shop = require("@shared/Shop")
local T = require("@shared/Test")

local expect = T.expect

local rig: Rig.Rig
T.beforeEach(function()
	rig = Rig.new()
end)
T.afterEach(function()
	rig.restore()
end)

local DAY = 86400

local function days(): { any }
	return {
		{ currencies = { Wins = 1 } },
		{ currencies = { Wins = 2 } },
		{ currencies = { Wins = 3 } },
		{ items = { "skin_candy" }, ifOwned = { Wins = 40 } },
	}
end

local function setup(extra: { [string]: any }?): (Daily.Daily, Shop.Shop)
	local shop = Shop.new({
		economy = rig.economy,
		items = { { id = "skin_candy", category = "Cosmetics", slot = "skin" } },
		marketplace = T.Fakes.MarketplaceService.new(),
		task = rig.clock.task,
	})
	local options: any = { economy = rig.economy, shop = shop, days = days(), now = rig.now, players = rig.players }
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return Daily.new(options), shop
end

T.describe("Daily.position", function()
	T.it("walks the strip, then repeats from repeatFrom", function()
		local positions: { number } = {}
		for streak = 1, 9 do
			table.insert(positions, Daily.position(streak, 4, 2))
		end
		expect(positions).toEqual({ 1, 2, 3, 4, 2, 3, 4, 2, 3 })
		expect(Daily.position(5, 4)).toBe(1)
	end)
end)

T.describe("Daily", function()
	T.it("pays one claim per day and walks the streak on consecutive days", function()
		local daily = setup()
		local player = rig:join(1, { daily })
		local status = daily:status(player) :: Daily.Status
		expect(status.canClaim).toBe(true)
		expect(status.day).toBe(1)
		expect((daily:claim(player))).toBe(true)
		local again, failure = daily:claim(player)
		expect(again).toBe(false)
		expect(failure).toBe("claimed")
		local after = daily:status(player) :: Daily.Status
		expect(after.canClaim).toBe(false)
		expect(after.nextAt - rig.now() <= DAY).toBe(true)

		rig.clock:advance(DAY)
		expect((daily:status(player) :: Daily.Status).day).toBe(2)
		daily:claim(player)
		expect(rig.economy:balance(player, "Wins")).toBe(3)
	end)

	T.it("starts again at day 1 after a missed day", function()
		local daily = setup()
		local player = rig:join(1, { daily })
		daily:claim(player)
		rig.clock:advance(DAY)
		daily:claim(player)
		rig.clock:advance(DAY * 2)
		local status = daily:status(player) :: Daily.Status
		expect(status.broken).toBe(true)
		expect(status.day).toBe(1)
	end)

	T.it("keeps a streak through grace days", function()
		local daily = setup({ graceDays = 1 })
		local player = rig:join(1, { daily })
		daily:claim(player)
		rig.clock:advance(DAY * 2)
		expect((daily:status(player) :: Daily.Status).day).toBe(2)
	end)

	T.it("grants the item on the last day and pays ifOwned when it is already owned", function()
		local daily, shop = setup()
		local player = rig:join(1, { daily, shop } :: { any })
		for _ = 1, 4 do
			daily:claim(player)
			rig.clock:advance(DAY)
		end
		expect(shop:hasItem(player, "skin_candy")).toBe(true)
		expect(shop:equipped(player, "skin")).toBe("skin_candy")
		local before = rig.economy:balance(player, "Wins")
		-- Days 1-3 again, then day 4 pays the duplicate compensation.
		for _ = 1, 4 do
			daily:claim(player)
			rig.clock:advance(DAY)
		end
		expect(rig.economy:balance(player, "Wins") - before).toBe(1 + 2 + 3 + 40)
	end)

	T.it("turns the day over at resetHourUtc", function()
		local daily = setup({ resetHourUtc = 6 })
		local start = rig.now()
		local base = math.floor(start / DAY) * DAY
		expect(daily:dayIndex(base + 5 * 3600)).toBe(daily:dayIndex(base - 3600))
		expect(daily:dayIndex(base + 7 * 3600)).toBe(daily:dayIndex(base + 5 * 3600) + 1)
	end)

	T.it("refuses reward tables that don't validate", function()
		expect(function()
			Daily.new({ economy = rig.economy, days = { { currencies = { Coins = 5 } } } })
		end).toThrow("unknown currency")
		expect(function()
			Daily.new({ economy = rig.economy, days = { { items = { "x" } } } })
		end).toThrow("no shop")
	end)
end)
