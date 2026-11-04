--!strict
--[[
	The v0.2 modules over a loopback Net: one server context, one client context per player,
	so these specs go through the same schemas, rate limits and handlers a real server uses.
]]
local Badges = require("@shared/Badges")
local Codes = require("@shared/Codes")
local Daily = require("@shared/Daily")
local Events = require("@shared/Events")
local Leaderboards = require("@shared/Leaderboards")
local Net = require("@shared/Net")
local Progression = require("@shared/Progression")
local Rebirth = require("@shared/Rebirth")
local Remotes = require("@shared/Remotes")
local Rig = require("../Progression/Rig")
local Shop = require("@shared/Shop")
local T = require("@shared/Test")

local expect = T.expect

local rig: Rig.Rig
local loop: Net.Loopback
local server: Net.Context
local contexts: { [any]: Net.Context } = {}

T.beforeEach(function()
	rig = Rig.new()
	contexts = {}
	loop = Net.Loopback.new()
	server = Net.newContext({
		side = "server",
		transport = loop.server,
		task = rig.clock.task,
		clock = function()
			return rig.clock:clock()
		end,
		now = rig.now,
	})
end)
T.afterEach(function()
	rig.restore()
	-- A handler that errors is logged, not thrown; none of these flows should log one.
	for _, entry in rig.logs do
		if entry.level == "error" then
			error("unexpected error log: " .. entry.message)
		end
	end
end)

-- One client context per player, as on a real client.
local function clientContext(player: any): Net.Context
	if contexts[player] then
		return contexts[player]
	end
	contexts[player] = Net.newContext({
		side = "client",
		transport = loop:connect(player),
		task = rig.clock.task,
		clock = function()
			return rig.clock:clock()
		end,
	})
	return contexts[player]
end

-- A client binding of `module` for `player`, plus every payload each of its server events sent.
local function client(module: string, player: any): (any, { [string]: { any } })
	local remotes = Remotes.client(module, clientContext(player))
	local got: { [string]: { any } } = {}
	for name, remote in remotes do
		if remote.kind == "ServerEvent" then
			got[name] = {}
			remote:connect(function(payload: any)
				table.insert(got[name], payload)
			end)
		end
	end
	return remotes, got
end

local function newShop(): Shop.Shop
	return Shop.new({
		economy = rig.economy,
		items = {
			{ id = "skin_neon", category = "Cosmetics", slot = "skin", price = { currency = "Wins", amount = 50 } },
		},
		marketplace = T.Fakes.MarketplaceService.new(),
		policy = false,
		task = rig.clock.task,
		now = rig.now,
		players = rig.players,
	})
end

T.describe("Remotes definitions", function()
	T.it("has a namespace and a factory for every module", function()
		local namespaces: { [string]: string } = Remotes.NAMESPACES :: any
		for module, namespace in namespaces do
			expect(string.sub(namespace, 1, 6)).toBe("Shared")
			expect(type(Remotes.bind)).toBe("function")
			expect(function()
				Remotes.bind(
					module,
					Net.newContext({ side = "client", transport = loop:connect({ UserId = 99 } :: any) })
				)
			end).never.toThrow()
		end
		expect(function()
			Remotes.bind("Nope")
		end).toThrow("unknown module")
	end)

	T.it("caches the client binding per context", function()
		local ctx = clientContext({ UserId = 5 })
		expect(Remotes.client("Shop", ctx)).toBe(Remotes.client("Shop", ctx))
	end)
end)

T.describe("Remotes: Shop", function()
	T.it("buys, equips and pushes state; the server decides the outcome", function()
		local shop = newShop()
		shop:bindNet(server)
		local player = rig:join(1, { shop })
		local remotes, got = client("Shop", player)

		local first = remotes.Buy:invokeAsync("skin_neon")
		expect(first.ok).toBe(true)
		expect(first.value.ok).toBe(false)
		expect(first.value.failure).toBe("insufficient")

		rig.economy:earn(player, "Wins", 60, "stage")
		local bought = remotes.Buy:invokeAsync("skin_neon")
		expect(bought.value.ok).toBe(true)
		expect(rig.economy:balance(player, "Wins")).toBe(10)
		expect((remotes.Equip:invokeAsync("skin_neon")).value.ok).toBe(true)
		expect(shop:equipped(player, "skin")).toBe("skin_neon")

		local state = remotes.GetState:invokeAsync()
		expect(state.value.owned.skin_neon).toBe(1)
		expect(state.value.equipped.skin).toBe("skin_neon")
		expect(#got.State > 0).toBe(true)
		expect(got.State[#got.State].equipped.skin).toBe("skin_neon")

		expect((remotes.Unequip:invokeAsync("skin")).value.ok).toBe(true)
		expect(shop:equipped(player, "skin")).toBeNil()
	end)

	T.it("rejects malformed requests before they reach the module", function()
		local shop = newShop()
		shop:bindNet(server)
		local player = rig:join(1, { shop })
		local remotes = client("Shop", player)
		local result = remotes.Buy:invokeAsync("not an id!")
		expect(result.ok).toBe(false)
		expect(result.error).toBe("invalid")
		local prompt = remotes.Prompt:invokeAsync({ kind = "robux", key = "x" })
		expect(prompt.ok).toBe(false)
		-- The client refused to send both and logged why.
		expect(#rig.logs).toBe(2)
		table.clear(rig.logs)
	end)

	T.it("answers notLoaded before the profile is attached", function()
		local shop = newShop()
		shop:bindNet(server)
		local player = rig.players:join({ UserId = 3, Name = "three" })
		local remotes = client("Shop", player)
		expect((remotes.GetState:invokeAsync()).value).toBeNil()
		expect((remotes.Buy:invokeAsync("skin_neon")).value.failure).toBe("notLoaded")
		expect((remotes.Unequip:invokeAsync("skin")).value.failure).toBe("notLoaded")
	end)
end)

T.describe("Remotes: Daily and Codes", function()
	T.it("tells the player a claim is open on load, then claims", function()
		local daily = Daily.new({
			economy = rig.economy,
			days = { { currencies = { Wins = 5 } }, { currencies = { Wins = 10 } } },
			now = rig.now,
			players = rig.players,
		})
		daily:bindNet(server)
		local player = rig.players:join({ UserId = 1, Name = "one" })
		local remotes, got = client("Daily", player)
		local data = { wallet = {} }
		rig.economy:attach(player, data)
		daily:attach(player, data)
		expect(#got.Available).toBe(1)
		expect(got.Available[1].day).toBe(1)
		local claim = remotes.Claim:invokeAsync()
		expect(claim.value.ok).toBe(true)
		expect(claim.value.applied.currencies.Wins).toBe(5)
		expect(claim.value.status.canClaim).toBe(false)
		expect((remotes.Claim:invokeAsync()).value.failure).toBe("claimed")
	end)

	T.it("redeems a code through the remote", function()
		local codes = Codes.new({
			economy = rig.economy,
			codes = { { code = "RELEASE", reward = { currencies = { Wins = 50 } } } },
			dataStoreService = false,
			messagingService = false,
			task = rig.clock.task,
			now = rig.now,
			players = rig.players,
		})
		codes:bindNet(server)
		local player = rig:join(1, { codes })
		local remotes = client("Codes", player)
		local result = remotes.Redeem:invokeAsync(" release ")
		expect(result.value.ok).toBe(true)
		expect(result.value.applied.currencies.Wins).toBe(50)
		expect((remotes.Redeem:invokeAsync("RELEASE")).value.failure).toBe("redeemed")
	end)
end)

T.describe("Remotes: Progression and Rebirth", function()
	T.it("serves state, pushes changes and announces rebirths to everyone", function()
		local progression = Progression.new({
			stages = { { id = "a", reward = { currency = "Wins", amount = 1 } } },
			gates = { { id = "one" }, { id = "two", requires = { lifetime = { currency = "Wins", amount = 10 } } } } :: any,
			economy = rig.economy,
			now = rig.now,
			players = rig.players,
		})
		local rebirth = Rebirth.new({
			economy = rig.economy,
			progression = progression,
			requires = { lifetime = { currency = "Wins", amount = 10 } },
			resets = { currencies = { "Wins" } },
			bonuses = { wins = { perRebirth = 0.25, currencies = { "Wins" } } },
			now = rig.now,
			players = rig.players,
			task = rig.clock.task,
		} :: any)
		progression:bindNet(server)
		rebirth:bindNet(server)
		local modules: { any } = { progression, rebirth }
		local player = rig:join(1, modules)
		local watcher = rig:join(2, modules)
		local progressionRemotes, progressionGot = client("Progression", player)
		local rebirthRemotes = client("Rebirth", player)
		local _, watcherGot = client("Rebirth", watcher)

		local state = progressionRemotes.GetState:invokeAsync()
		expect(state.value.gates.two.unlocked).toBe(false)
		rig.economy:earn(player, "Wins", 10, "stage")
		expect(#progressionGot.State > 0).toBe(true)
		expect(progressionGot.State[#progressionGot.State].gates.two.unlocked).toBe(true)

		local preview = rebirthRemotes.Preview:invokeAsync()
		expect(preview.value.canRebirth).toBe(true)
		local done = rebirthRemotes.Rebirth:invokeAsync()
		expect(done.value.ok).toBe(true)
		expect(done.value.summary.count).toBe(1)
		expect(watcherGot.Rebirthed[1]).toEqual({ userId = 1, name = "player1", count = 1 })
		expect((rebirthRemotes.Rebirth:invokeAsync()).value.failure).toBe("requirements")
	end)
end)

T.describe("Remotes: Leaderboards and Badges", function()
	T.it("serves a board with the asker's rank and announces badges marked announce", function()
		local dss = T.Fakes.DataStoreService.new()
		local boards = Leaderboards.new({
			boards = { { id = "wins" } },
			dataStoreService = dss,
			userService = {
				GetUserInfosByUserIdsAsync = function(_self: any, ids: { number })
					local out = {}
					for _, id in ids do
						table.insert(out, { Id = id, Username = "u" .. id, DisplayName = "U" .. id })
					end
					return out
				end,
			},
			players = rig.players,
			task = rig.clock.task,
			now = rig.now,
		})
		boards:bindNet(server)
		local player = rig:join(1)
		local remotes, got = client("Leaderboards", player)
		boards:submit(player, "wins", 30)
		boards:flushAsync()
		boards:refreshAsync("wins")
		expect(got.Updated[#got.Updated]).toBe("wins")
		local answer = remotes.Get:invokeAsync("wins")
		expect(answer.value.board.entries[1].userId).toBe(1)
		expect(answer.value.you.rank).toBe(1)
		expect(answer.value.you.value).toBe(30)
		expect((remotes.Get:invokeAsync("nope")).value).toBeNil()

		local badges = Badges.new({
			badges = { { key = "FirstWin", id = 0 }, { key = "Rebirth1", id = 0, announce = true } },
			badgeService = { AwardBadge = function() end, UserHasBadgeAsync = function() end },
			task = rig.clock.task,
			now = rig.now,
		})
		badges:bindNet(server)
		badges:attach(player, {})
		local _, mine = client("Badges", player)
		local other = rig:join(2)
		local _, theirs = client("Badges", other)
		badges:award(player, "FirstWin")
		badges:award(player, "Rebirth1")
		expect(mine.Earned).toEqual({ { key = "FirstWin" }, { key = "Rebirth1" } })
		expect(#theirs.Earned).toBe(0)
		expect(theirs.Announced).toEqual({ { key = "Rebirth1", userId = 1, name = "player1" } })
	end)
end)

T.describe("Remotes: Events", function()
	T.it("joins and leaves the lobby and tells the player when the lobby empties", function()
		local events = Events.new({
			events = { { id = "race", durationSeconds = 30, minPlayers = 2 } },
			mode = "lobby",
			every = 600,
			economy = rig.economy,
			players = rig.players,
			task = rig.clock.task,
			now = rig.now,
		})
		events:bindNet(server)
		local player = rig:join(1)
		local remotes, got = client("Events", player)
		events:start()
		expect((remotes.Join:invokeAsync()).value.failure).toBe("closed")
		events:trigger("race")
		expect(got.State[#got.State].phase).toBe("lobby")
		local joined = remotes.Join:invokeAsync()
		expect(joined.value.ok).toBe(true)
		expect(joined.value.state.joined).toBe(true)
		expect(got.Joined).toEqual({ true })
		expect((remotes.GetState:invokeAsync()).value.participants).toBe(1)
		expect((remotes.Leave:invokeAsync()).value.state.joined).toBe(false)
		remotes.Join:invokeAsync()
		-- Too few players: cancelled, back to idle, and the player is out.
		rig.clock:advance(90)
		expect(got.State[#got.State].phase).toBe("idle")
		expect(got.Joined).toEqual({ true, false, true, false })
		expect(got.Finished[1].cancelled).toBe(true)
		expect(got.Finished[1].participants).toEqual({ 1 })
	end)
end)
