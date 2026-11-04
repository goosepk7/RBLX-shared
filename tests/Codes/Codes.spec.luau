--!strict
local Codes = require("@shared/Codes")
local Rig = require("../Progression/Rig")
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

type Messaging = {
	subscribers: { (any) -> () },
	SubscribeAsync: (self: Messaging, topic: string, fn: (any) -> ()) -> any,
	PublishAsync: (self: Messaging, topic: string, data: any) -> (),
}

local function messaging(): Messaging
	local service = { subscribers = {} } :: Messaging
	function service.SubscribeAsync(self: Messaging, _topic: string, fn: (any) -> ())
		table.insert(self.subscribers, fn)
		return { Disconnect = function() end }
	end
	function service.PublishAsync(self: Messaging, _topic: string, data: any)
		for _, fn in self.subscribers do
			fn({ Data = data })
		end
	end
	return service
end

type Setup = { codes: Codes.Codes, shop: Shop.Shop, dss: any, messaging: Messaging }

local function setup(extra: { [string]: any }?, shared: { dss: any, messaging: Messaging }?): Setup
	local dss = if shared then shared.dss else T.Fakes.DataStoreService.new()
	local bus = if shared then shared.messaging else messaging()
	local shop = Shop.new({
		economy = rig.economy,
		items = { { id = "trail_spark", category = "Cosmetics", slot = "trail" } },
		marketplace = T.Fakes.MarketplaceService.new(),
		task = rig.clock.task,
	})
	local configCodes: { Codes.CodeDef } = {
		{ code = "RELEASE", reward = { currencies = { Wins = 50 } }, expiresAt = rig.now() + 3600 },
		{ code = "TALLER", reward = { items = { "trail_spark" } }, maxUses = 2 },
		{ code = "LATER", reward = { currencies = { Wins = 1 } }, startsAt = rig.now() + 60 },
		{
			code = "VETERAN",
			reward = { currencies = { Wins = 5 } },
			requires = function(who: any)
				return rig.economy:lifetime(who, "Wins") >= 100, "tooNew"
			end,
		},
	}
	local options: any = {
		economy = rig.economy,
		shop = shop,
		codes = configCodes,
		dataStoreService = dss,
		messagingService = bus,
		task = rig.clock.task,
		now = rig.now,
		clock = function()
			return rig.clock:clock()
		end,
		players = rig.players,
		maxFailures = 3,
		lockoutSeconds = 60,
	}
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	local codes = Codes.new(options)
	return { codes = codes, shop = shop, dss = dss, messaging = bus }
end

T.describe("Codes.normalize", function()
	T.it("trims, upper-cases and checks the shape", function()
		expect(Codes.normalize("  release ")).toBe("RELEASE")
		expect(Codes.normalize("Taller_2")).toBe("TALLER_2")
		expect(Codes.normalize("ab")).toBeNil()
		expect(Codes.normalize("has space")).toBeNil()
		expect(Codes.normalize("émoji")).toBeNil()
		expect(Codes.normalize(string.rep("A", 25))).toBeNil()
	end)
end)

T.describe("Codes", function()
	T.it("redeems once per player with an exact reward that doesn't raise lifetime", function()
		local s = setup()
		local player = rig:join(1, { s.codes, s.shop } :: { any })
		local ok, failure, applied = s.codes:redeemAsync(player, "release")
		expect(failure).toBeNil()
		expect(ok).toBe(true)
		expect((applied :: any).currencies.Wins).toBe(50)
		expect(rig.economy:balance(player, "Wins")).toBe(50)
		expect(rig.economy:lifetime(player, "Wins")).toBe(0)
		local again, why = s.codes:redeemAsync(player, "RELEASE")
		expect(again).toBe(false)
		expect(why).toBe("redeemed")
	end)

	T.it("refuses expired, not-yet-started and unknown codes", function()
		local s = setup()
		local player = rig:join(1, { s.codes, s.shop } :: { any })
		expect((select(2, s.codes:redeemAsync(player, "LATER")))).toBe("unknown")
		rig.clock:advance(3600)
		expect((select(2, s.codes:redeemAsync(player, "RELEASE")))).toBe("expired")
		expect((s.codes:redeemAsync(player, "LATER"))).toBe(true)
		expect((select(2, s.codes:redeemAsync(player, "NOPE")))).toBe("unknown")
	end)

	T.it("checks a code's requirement", function()
		local s = setup()
		local player = rig:join(1, { s.codes, s.shop } :: { any })
		expect((select(2, s.codes:redeemAsync(player, "VETERAN")))).toBe("tooNew")
		rig.economy:earn(player, "Wins", 100, "stage")
		expect((s.codes:redeemAsync(player, "VETERAN"))).toBe(true)
	end)

	T.it("enforces a global use limit across players and servers", function()
		local s = setup()
		local other = setup(nil, { dss = s.dss, messaging = s.messaging })
		local a = rig:join(1, { s.codes, s.shop } :: { any })
		local b = rig:join(2, { other.codes, other.shop } :: { any })
		local c = rig:join(3, { s.codes, s.shop } :: { any })
		expect((s.codes:redeemAsync(a, "TALLER"))).toBe(true)
		expect((other.codes:redeemAsync(b, "TALLER"))).toBe(true)
		local ok, failure = s.codes:redeemAsync(c, "TALLER")
		expect(ok).toBe(false)
		expect(failure).toBe("exhausted")
		-- An exhausted attempt doesn't mark the code as redeemed for that player.
		expect(s.codes:hasRedeemed(c, "TALLER")).toBe(false)
		expect(s.shop:hasItem(a, "trail_spark")).toBe(true)
	end)

	T.it("says unavailable and lets the player retry when the DataStore fails", function()
		local s = setup()
		local player = rig:join(1, { s.codes, s.shop } :: { any })
		s.dss:failNext("UpdateAsync", { times = 1 })
		local ok, failure = s.codes:redeemAsync(player, "TALLER")
		expect(ok).toBe(false)
		expect(failure).toBe("unavailable")
		expect((s.codes:redeemAsync(player, "TALLER"))).toBe(true)
	end)

	T.it("locks a player out after too many wrong guesses", function()
		local s = setup()
		local player = rig:join(1, { s.codes, s.shop } :: { any })
		for _ = 1, 3 do
			s.codes:redeemAsync(player, "WRONG")
		end
		expect((select(2, s.codes:redeemAsync(player, "RELEASE")))).toBe("tooManyAttempts")
		rig.clock:advance(61)
		expect((s.codes:redeemAsync(player, "RELEASE"))).toBe(true)
	end)

	T.it("adds runtime codes without a deploy, visible on every server", function()
		local s = setup()
		local other = setup(nil, { dss = s.dss, messaging = s.messaging })
		s.codes:start()
		other.codes:start()
		local ok, err = s.codes:createAsync({ code = "sorry", reward = { currencies = { Wins = 100 } } })
		expect(err).toBeNil()
		expect(ok).toBe(true)
		local player = rig:join(2, { other.codes, other.shop } :: { any })
		-- The other server heard the ping and refreshed.
		expect(other.codes:lookup("SORRY")).never.toBeNil()
		expect((other.codes:redeemAsync(player, "Sorry"))).toBe(true)
		expect(rig.economy:balance(player, "Wins")).toBe(100)

		expect((s.codes:disableAsync("SORRY"))).toBe(true)
		local late = rig:join(3, { other.codes, other.shop } :: { any })
		expect((select(2, other.codes:redeemAsync(late, "SORRY")))).toBe("unknown")
	end)

	T.it("finds a code created elsewhere on a miss even without a ping", function()
		local s = setup({ messagingService = false })
		local other = setup({ messagingService = false }, { dss = s.dss, messaging = s.messaging })
		other.codes:start()
		s.codes:createAsync({ code = "FRESH", reward = { currencies = { Wins = 7 } } })
		rig.clock:advance(11)
		local player = rig:join(1, { other.codes, other.shop } :: { any })
		expect((other.codes:redeemAsync(player, "FRESH"))).toBe(true)
	end)

	T.it("validates runtime codes and refuses clashes with config codes", function()
		local s = setup()
		expect((select(2, s.codes:createAsync({ code = "RELEASE", reward = { currencies = { Wins = 1 } } })))).toMatch(
			"config code"
		)
		expect((select(2, s.codes:createAsync({ code = "X", reward = { currencies = { Wins = 1 } } })))).toMatch(
			"3%-24"
		)
		expect((select(2, s.codes:createAsync({ code = "EMPTY", reward = {} })))).toMatch("empty")
		expect((select(2, s.codes:createAsync({ code = "BADITEM", reward = { items = { "nope" } } })))).toMatch(
			"unknown item"
		)
	end)

	T.it("lists config and runtime codes with use counts", function()
		local s = setup()
		local player = rig:join(1, { s.codes, s.shop } :: { any })
		s.codes:redeemAsync(player, "TALLER")
		s.codes:createAsync({ code = "EXTRA", reward = { currencies = { Wins = 1 } }, maxUses = 5 })
		local list = s.codes:listAsync()
		local byCode: { [string]: any } = {}
		for _, entry in list do
			byCode[entry.def.code] = entry
		end
		expect(byCode.TALLER.uses).toBe(1)
		expect(byCode.EXTRA.uses).toBe(0)
		expect(byCode.EXTRA.def.source).toBe("runtime")
		expect(byCode.RELEASE.uses).toBeNil()
	end)

	T.it("refuses invalid config at startup", function()
		expect(function()
			Codes.new({
				economy = rig.economy,
				codes = { { code = "bad code", reward = { currencies = { Wins = 1 } } } },
			})
		end).toThrow("upper-case")
	end)
end)
