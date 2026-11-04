--!strict
local Admin = require("@shared/Admin")
local AntiExploit = require("@shared/AntiExploit")
local Economy = require("@shared/Economy")
local Log = require("@shared/Util/Log")
local Net = require("@shared/Net")
local Sim = require("@shared/Sim")
local T = require("@shared/Test")
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

local OWNER = 1

local lastContext: any = nil

local function setup()
	local world = World.new()
	local server = world:server("A")
	local registry = AntiExploit.newRegistry({
		now = function()
			return world.clock:now()
		end,
	})
	local loop = Net.Loopback.new()
	local ctx = Net.newContext({
		side = "server",
		transport = loop.server,
		task = world.clock.task,
		clock = function()
			return world.clock:clock()
		end,
		strikes = registry,
	})
	lastContext = ctx
	local economy = Economy.new({
		currencies = { { id = "Wins", displayName = "Wins" } },
		task = world.clock.task,
		players = server.players,
	})
	economy:bindStore(server.store)
	server.store:bindPlayers()
	local sims = {
		Sim.Runner.define({
			name = "demo.ok",
			run = function(simCtx)
				simCtx.targets:check("answer", 42, { min = 40, max = 50 })
			end,
		}),
	}
	local admin = Admin.Server.new({
		owners = { OWNER },
		store = server.store,
		economy = economy,
		antiExploit = registry,
		players = server.players,
		context = ctx,
		sims = sims,
		chatCommands = false,
		isStudio = function()
			return false
		end,
		now = function()
			return world.clock:now()
		end,
	})
	local function client(player: any): any
		local clientCtx = Net.newContext({
			side = "client",
			transport = loop:connect(player),
			task = world.clock.task,
			clock = function()
				return world.clock:clock()
			end,
		})
		return Admin.remotes({ context = clientCtx })
	end
	return world, server, admin, economy, registry, client
end

T.describe("Admin.parse", function()
	T.it("splits words, keeps quoted text, drops the /admin prefix", function()
		expect(Admin.parse('/admin kick bob "too many lunges"')).toEqual({ "kick", "bob", "too many lunges" })
		expect(Admin.parse("  grant   me Wins 5 ")).toEqual({ "grant", "me", "Wins", "5" })
		expect(Admin.parse("")).toEqual({})
	end)
end)

T.describe("Admin.findPlayer", function()
	local list = {
		{ UserId = 1, Name = "Bruce", DisplayName = "Bruce" },
		{ UserId = 2, Name = "Brian", DisplayName = "B" },
		{ UserId = 3, Name = "Cara", DisplayName = "Cara" },
	}
	T.it("finds by me, id, exact or unique prefix", function()
		expect((Admin.findPlayer(list, "me", list[3]))).toBe(list[3])
		expect((Admin.findPlayer(list, "2", nil))).toBe(list[2])
		expect((Admin.findPlayer(list, "cA", nil))).toBe(list[3])
		expect((Admin.findPlayer(list, "bruce", nil))).toBe(list[1])
	end)
	T.it("refuses ambiguous and unknown names", function()
		local p, err = Admin.findPlayer(list, "br", nil)
		expect(p).toBeNil()
		expect(err).toMatch("matches 2")
		expect((select(2, Admin.findPlayer(list, "zed", nil)))).toMatch("no player")
	end)
end)

T.describe("Admin commands", function()
	T.it("grants and takes currency, never below zero", function()
		local _world, server, admin, economy = setup()
		local owner = server:join(OWNER)
		local ok, message = admin:run(owner, "grant me wins 500")
		expect(ok).toBe(true)
		expect(message).toMatch("0 %-> 500")
		expect(economy:balance(owner, "Wins")).toBe(500)
		admin:run(owner, "grant me Wins -9999")
		expect(economy:balance(owner, "Wins")).toBe(0)
		local bad = { admin:run(owner, "grant me Gems 5") }
		expect(bad[1]).toBe(false)
		expect(bad[2]).toMatch("unknown currency")
	end)

	T.it("refuses non-owners and logs the attempt", function()
		local _world, server, admin, economy = setup()
		local other = server:join(2)
		local ok = admin:run(other, "grant me Wins 500")
		expect(ok).toBe(false)
		expect(economy:balance(other, "Wins")).toBe(0)
		local audit = admin:getAudit()
		expect(audit[1].ok).toBe(false)
		expect(audit[1].userId).toBe(2)
	end)

	T.it("reset needs confirm, then erases the save and kicks", function()
		local world, server, admin = setup()
		local owner = server:join(OWNER)
		local target = server:join(2)
		world.clock:advance(61)
		expect(world:stored(2)).toBeTruthy()
		expect((admin:run(owner, "reset 2"))).toBe(false)
		expect((admin:run(owner, "reset 2 confirm"))).toBe(true)
		world.clock:advance(1)
		expect(world:stored(2)).toBeNil()
		expect(server.players:GetPlayerByUserId(2)).toBeNil()
		local _ = target
	end)

	T.it("reports usage for missing and extra arguments", function()
		local _world, server, admin = setup()
		local owner = server:join(OWNER)
		local _, missing = admin:run(owner, "grant me")
		expect(missing).toMatch("Usage: grant <player> <currency> <amount>")
		local _, extra = admin:run(owner, "kick")
		expect(extra).toMatch("missing player")
		local _, unknown = admin:run(owner, "fly")
		expect(unknown).toMatch("unknown command")
	end)

	T.it("runs a registered sim and returns its verdict", function()
		local _world, server, admin = setup()
		local owner = server:join(OWNER)
		local ok, message = admin:run(owner, "sim demo.ok")
		expect(ok).toBe(true)
		expect(message).toMatch("SIM PASS")
		expect((admin:run(owner, "sim nope"))).toBe(false)
	end)

	T.it("turns a remote off in this server", function()
		local _world, server, admin = setup()
		local owner = server:join(OWNER)
		expect((admin:run(owner, "remote Stilts.Lunge off"))).toBe(true)
		expect(lastContext:isEnabled("Stilts.Lunge")).toBe(false)
	end)

	T.it("reports a command that errors instead of crashing", function()
		local _world, server, admin = setup()
		local owner = server:join(OWNER)
		admin:register({
			name = "boom",
			description = "always errors",
			run = function()
				error("kaboom")
			end,
		})
		local ok, message = admin:run(owner, "boom")
		expect(ok).toBe(false)
		expect(message).toMatch("kaboom")
	end)
end)

T.describe("Admin queries and remotes", function()
	T.it("inspects live and saved profiles", function()
		local world, server, admin = setup()
		local owner = server:join(OWNER)
		local live = admin:query(owner, "inspect", "me")
		expect(live.source).toBe("live")
		expect(live.document.data.coins).toBe(0)
		world:seed(77, World.document({ coins = 12, inventory = {}, settings = {} }))
		local saved = admin:query(owner, "inspect", 77)
		expect(saved.source).toBe("saved")
		expect(saved.document.data.coins).toBe(12)
		expect(admin:query(owner, "inspect", 99).error).toMatch("No profile")
	end)

	T.it("lists players with strikes and returns diagnostics", function()
		local _world, server, admin, _economy, registry = setup()
		local owner = server:join(OWNER)
		local other = server:join(2)
		registry:strike(other, "test", "x")
		local players = admin:query(owner, "players", nil)
		expect(#players).toBe(2)
		local diagnostics = admin:query(owner, "diagnostics", nil)
		expect(diagnostics.data).toBeTruthy()
		expect(diagnostics.economy).toBeTruthy()
		expect(#admin:query(owner, "sims", nil)).toBe(1)
	end)

	T.it("answers owners over the remotes and strikes anyone else", function()
		local world, server, _admin, _economy, registry, client = setup()
		local owner = server:join(OWNER)
		local other = server:join(2)
		local ownerRemotes = client(owner)
		local otherRemotes = client(other)
		local results: { any } = {}
		world.clock.task.spawn(function()
			table.insert(results, ownerRemotes.Run:invokeAsync("help"))
		end)
		world.clock:advance(1)
		expect(results[1].ok).toBe(true)
		expect(results[1].value.message).toMatch("grant")
		world.clock.task.spawn(function()
			table.insert(results, otherRemotes.Run:invokeAsync("grant me Wins 9"))
		end)
		world.clock:advance(31)
		expect(results[2].ok).toBe(false)
		expect((registry:getRecord(other) :: any).byCategory["admin.unauthorized"]).toBe(1)
	end)

	T.it("snapshots data safely for the wire", function()
		local deep: any = { a = { b = { c = { d = 1 } } } }
		local snap = Admin.snapshot(deep, 2)
		expect(snap.a.b).toBe("{…}")
		local big: any = {}
		for i = 1, 50 do
			big["k" .. i] = i
		end
		local cut = Admin.snapshot(big, 8, 10)
		expect(cut["…"]).toBe("truncated")
	end)
end)

T.describe("Admin.Panel.flatten", function()
	T.it("flattens nested tables into sorted paths and honors the limit", function()
		local pairs_ = Admin.Panel.flatten({ b = { y = 2, x = 1 }, a = true, e = {} } :: any)
		expect(#pairs_).toBe(4)
		expect(pairs_[1].path).toBe("a")
		expect(pairs_[1].value).toBe("true")
		expect(pairs_[2].path).toBe("b.x")
		expect(pairs_[3].path).toBe("b.y")
		expect(pairs_[4].path).toBe("e")
		expect(pairs_[4].value).toBe("{}")
		local list = Admin.Panel.flatten({ "p", "q" } :: any)
		expect(list[1].path).toBe("1")
		expect(list[2].value).toBe("q")
		expect(#Admin.Panel.flatten({ a = 1, b = 2, c = 3 } :: any, 2)).toBe(2)
	end)
end)
