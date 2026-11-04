--!strict
local Progression = require("@shared/Progression")
local Rebirth = require("@shared/Rebirth")
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

type Setup = { progression: Progression.Progression, rebirth: Rebirth.Rebirth, shop: Shop.Shop }

local function setup(extra: { [string]: any }?): Setup
	local progression = Progression.new({
		stages = { { id = "a", group = "one", reward = { currency = "Wins", amount = 1 } } },
		gates = {
			{ id = "one" },
			{ id = "two", requires = { lifetime = { currency = "Wins", amount = 100 } }, fastTrack = { factor = 0.5 } },
			{ id = "three", requires = { lifetime = { currency = "Wins", amount = 200 } } },
		} :: any,
		economy = rig.economy,
		now = rig.now,
		players = rig.players,
		rebirths = function(_who: any): number
			return 0
		end,
	})
	local shop = Shop.new({
		economy = rig.economy,
		items = { { id = "stilt_bamboo", category = "Cosmetics", slot = "skin" } },
		task = rig.clock.task,
		marketplace = T.Fakes.MarketplaceService.new(),
		policy = false,
	})
	local options: any = {
		economy = rig.economy,
		progression = progression,
		shop = shop,
		requires = { lifetime = { currency = "Wins", amount = 250 }, gates = { "three" } },
		resets = { currencies = { "Wins" }, gates = {} },
		bonuses = {
			wins = { perRebirth = 0.25, linearUntil = 10, decay = 0.85, currencies = { "Wins" } },
			height = { perRebirth = 0.05, max = 0.5 },
		},
		milestones = { [1] = { items = { "stilt_bamboo" } } },
		now = rig.now,
		players = rig.players,
	}
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return { progression = progression, rebirth = Rebirth.new(options), shop = shop }
end

T.describe("Rebirth curves", function()
	T.it("adds 25% per rebirth up to 10, then diminishes toward its limit", function()
		local curve: Rebirth.Curve = { perRebirth = 0.25, linearUntil = 10, decay = 0.85 }
		expect(Rebirth.factor(curve, 0)).toBe(1)
		expect(Rebirth.factor(curve, 1)).toBe(1.25)
		expect(Rebirth.factor(curve, 10)).toBe(3.5)
		expect(Rebirth.factor(curve, 11)).toBeNear(3.5 + 0.25 * 0.85)
		expect(Rebirth.factor(curve, 12)).toBeNear(3.5 + 0.25 * (0.85 + 0.85 ^ 2))
		expect(Rebirth.factor(curve, 1000)).toBeNear(1 + 0.25 * (10 + 0.85 / 0.15))
		-- Every rebirth still helps, a little less each time.
		local last = 0
		for n = 1, 40 do
			local f = Rebirth.factor(curve, n)
			expect(f > last).toBe(true)
			last = f
		end
	end)

	T.it("caps a curve at its max", function()
		local curve: Rebirth.Curve = { perRebirth = 0.05, max = 0.5 }
		expect(Rebirth.factor(curve, 4)).toBeNear(1.2)
		expect(Rebirth.factor(curve, 30)).toBe(1.5)
	end)
end)

T.describe("Rebirth", function()
	T.it("refuses until every requirement is met and reports progress", function()
		local s = setup()
		local player = rig:join(1, { s.progression, s.rebirth, s.shop } :: { any })
		rig.economy:earn(player, "Wins", 150, "stage")
		local fraction, parts = s.rebirth:progress(player)
		expect(fraction).toBe(0) -- gate "three" not unlocked yet
		expect(#parts).toBe(2)
		local ok, failure = s.rebirth:perform(player)
		expect(ok).toBe(false)
		expect(failure).toBe("requirements")
		rig.economy:earn(player, "Wins", 60, "stage")
		expect((s.rebirth:progress(player))).toBeNear(210 / 250)
	end)

	T.it("resets the currency and gates, keeps records, applies the bonus and grants the milestone", function()
		local s = setup()
		local player = rig:join(1, { s.progression, s.rebirth, s.shop } :: { any })
		rig.economy:earn(player, "Wins", 260, "stage")
		local attempt = s.progression:begin(player, "a") :: Progression.Attempt
		s.progression:finish(player, attempt.attemptId, { completed = true })
		expect(s.progression:isUnlocked(player, "three")).toBe(true)

		local preview = s.rebirth:preview(player) :: Rebirth.Preview
		expect(preview.canRebirth).toBe(true)
		expect(preview.bonuses.wins).toEqual({ before = 1, after = 1.25 })
		expect(preview.milestone).toEqual({ items = { "stilt_bamboo" } })

		local fired: { number } = {}
		s.rebirth.Rebirthed:Connect(function(_p: any, _id: number, summary: Rebirth.Summary)
			table.insert(fired, summary.count)
		end)
		local ok, failure, summary = s.rebirth:perform(player)
		expect(failure).toBeNil()
		expect(ok).toBe(true)
		expect(fired).toEqual({ 1 })
		expect((summary :: Rebirth.Summary).reset.Wins).toBe(261)
		expect(rig.economy:balance(player, "Wins")).toBe(0)
		expect(rig.economy:lifetime(player, "Wins")).toBe(0)
		expect(rig.economy:allTime(player, "Wins")).toBe(261)
		expect(s.progression:isUnlocked(player, "two")).toBe(false)
		expect(s.progression:isUnlocked(player, "one")).toBe(true)
		expect((s.progression:record(player, "a") :: any).clears).toBe(1)
		expect(s.rebirth:count(player)).toBe(1)
		expect(player:GetAttribute("Rebirths")).toBe(1)
		expect(s.shop:hasItem(player, "stilt_bamboo")).toBe(true)
		expect(s.rebirth:factor(player, "height")).toBeNear(1.05)
		-- The Wins bonus is an Economy multiplier now.
		expect((rig.economy:earn(player, "Wins", 4, "stage"))).toBe(5)
	end)

	T.it("restores the multiplier when the player loads again", function()
		local s = setup()
		local player, data = rig:join(1, { s.progression, s.rebirth, s.shop } :: { any })
		data.rebirth.count = 4
		rig.economy:clearMultipliers(player)
		s.rebirth:attach(player, data)
		expect(rig.economy:multiplier(player, "Wins", "stage")).toBe(2)
	end)

	T.it("lets a product force a rebirth past requirements, but not past the cap", function()
		local s = setup({ maxRebirths = 1 })
		local player = rig:join(1, { s.progression, s.rebirth, s.shop } :: { any })
		local ok = s.rebirth:perform(player, { force = true, reason = "product" })
		expect(ok).toBe(true)
		local again, failure = s.rebirth:perform(player, { force = true })
		expect(again).toBe(false)
		expect(failure).toBe("maxed")
	end)

	T.it("runs the game's own resets with the profile data", function()
		local seen: { any } = {}
		local s = setup({
			onRebirth = function(_who: any, count: number, data: any)
				table.insert(seen, count)
				data.upgrades = { lunge = 0 }
			end,
		})
		local player, data = rig:join(1, { s.progression, s.rebirth, s.shop } :: { any })
		data.upgrades = { lunge = 3 }
		s.rebirth:perform(player, { force = true })
		expect(seen).toEqual({ 1 })
		expect(data.upgrades.lunge).toBe(0)
	end)

	T.it("is not loaded for a player it never attached", function()
		local s = setup()
		local ok, failure = s.rebirth:perform(99)
		expect(ok).toBe(false)
		expect(failure).toBe("notLoaded")
		expect(s.rebirth:preview(99)).toBeNil()
	end)

	T.it("rejects bad configs", function()
		expect(function()
			Rebirth.new({ economy = rig.economy, resets = { currencies = { "Coins" } } })
		end).toThrow("unknown currency")
		expect(function()
			Rebirth.new({ economy = rig.economy, requires = { gates = { "x" } } })
		end).toThrow("need a progression")
		expect(function()
			Rebirth.new({ economy = rig.economy, bonuses = { wins = { perRebirth = 0.25, decay = 1.5 } } })
		end).toThrow("decay")
	end)
end)
