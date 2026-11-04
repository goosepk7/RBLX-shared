--!strict
local Leaderboards = require("@shared/Leaderboards")
local Log = require("@shared/Util/Log")
local T = require("@shared/Test")

local expect = T.expect

local restoreLog: () -> () = function() end
T.beforeEach(function()
	local _
	_, restoreLog = Log.capture()
end)
T.afterEach(function()
	restoreLog()
end)

type Setup = {
	clock: any,
	dss: any,
	players: any,
	boards: Leaderboards.Leaderboards,
	values: { [number]: number },
	userService: any,
}

local function setup(shared: { clock: any, dss: any }?): Setup
	local clock = if shared then shared.clock else T.Clock.new({ start = 1_700_000_000 })
	local dss = if shared then shared.dss else T.Fakes.DataStoreService.new()
	local players = T.Fakes.Players.new()
	local values: { [number]: number } = {}
	local userService = {
		calls = 0,
		GetUserInfosByUserIdsAsync = function(self: any, ids: { number })
			self.calls += 1
			local out = {}
			for _, id in ids do
				table.insert(out, { Id = id, Username = "user" .. id, DisplayName = "User " .. id })
			end
			return out
		end,
	}
	local boards = Leaderboards.new({
		boards = {
			{
				id = "wins",
				value = function(who: any)
					return values[who.UserId]
				end,
			},
			{ id = "best:gap", mode = "min", scale = 1000, format = "time" },
			{ id = "today", period = "daily" },
			{ id = "gauntlet", period = "weekly" },
			{ id = "current", mode = "set" },
		},
		dataStoreService = dss,
		userService = userService,
		players = players,
		task = clock.task,
		now = function()
			return clock:now()
		end,
	})
	return { clock = clock, dss = dss, players = players, boards = boards, values = values, userService = userService }
end

T.describe("Leaderboards pure rules", function()
	T.it("compares by mode", function()
		expect(Leaderboards.better("max", 5, 4)).toBe(true)
		expect(Leaderboards.better("max", 4, 4)).toBe(false)
		expect(Leaderboards.better("min", 3, 4)).toBe(true)
		expect(Leaderboards.better("set", 4, 5)).toBe(true)
		expect(Leaderboards.better("min", 9, nil)).toBe(true)
	end)

	T.it("starts weeks on Monday 00:00 UTC", function()
		-- 2023-11-13 00:00 UTC was a Monday.
		local monday = 1_699_833_600
		local index, endsAt = Leaderboards.period("weekly", monday)
		local before = Leaderboards.period("weekly", monday - 1)
		expect(index).toBe((before :: number) + 1)
		expect(endsAt).toBe(monday + 7 * 86400)
		local _, dayEnd = Leaderboards.period("daily", monday + 5)
		expect(dayEnd).toBe(monday + 86400)
	end)

	T.it("stores scaled whole numbers", function()
		local def: Leaderboards.BoardDef = { id = "t", scale = 1000 }
		expect(Leaderboards.encode(def, 12.3456)).toBe(12346)
		expect(Leaderboards.decode(def, 12346)).toBe(12.346)
	end)
end)

T.describe("Leaderboards", function()
	T.it("writes the best value per player and reads the top with names and ranks", function()
		local s = setup()
		local a = s.players:join({ UserId = 1, Name = "one" })
		local b = s.players:join({ UserId = 2, Name = "two" })
		s.boards:start()
		s.clock:flush()
		s.boards:submit(a, "best:gap", 14.2)
		s.boards:submit(a, "best:gap", 12.5)
		s.boards:submit(a, "best:gap", 13)
		s.boards:submit(b, "best:gap", 20)
		s.boards:flushAsync()
		s.boards:refreshAsync("best:gap")
		local snapshot = s.boards:get("best:gap")
		expect(#snapshot.entries).toBe(2)
		expect(snapshot.entries[1].userId).toBe(1)
		expect(snapshot.entries[1].value).toBe(12.5)
		expect(snapshot.entries[1].name).toBe("one")
		expect(s.boards:rankOf(b, "best:gap")).toBe(2)
		expect(s.boards:valueOf(a, "best:gap")).toBe(12.5)

		-- A worse time later never overwrites the stored best.
		s.boards:submit(a, "best:gap", 30)
		s.boards:flushAsync()
		expect(s.dss:GetOrderedDataStore("LB_best:gap"):GetAsync("1")).toBe(12500)
	end)

	T.it("samples value boards for everyone in the server at each write", function()
		local s = setup()
		local a = s.players:join({ UserId = 1, Name = "one" })
		s.boards:start()
		s.values[1] = 40
		s.clock:advance(60)
		expect(s.dss:GetOrderedDataStore("LB_wins"):GetAsync("1")).toBe(40)
		s.values[1] = 55
		s.players:leave(a)
		s.clock:flush()
		expect(s.dss:GetOrderedDataStore("LB_wins"):GetAsync("1")).toBe(55)
	end)

	T.it("doesn't rewrite values that aren't better than the stored one", function()
		local s = setup()
		local other = setup({ clock = s.clock, dss = s.dss })
		s.dss:GetOrderedDataStore("LB_wins"):SetAsync("1", 100)
		local a = other.players:join({ UserId = 1, Name = "one" })
		other.boards:start()
		s.clock:flush()
		local before = #s.dss:calls()
		other.boards:submit(a, "wins", 80)
		other.boards:flushAsync(a)
		-- Known to be worse after the join read: no write was spent.
		expect(#s.dss:calls()).toBe(before)
		expect(other.boards:valueOf(a, "wins")).toBe(100)
	end)

	T.it("keeps daily boards per day and reports when the period ends", function()
		local s = setup()
		local a = s.players:join({ UserId = 1, Name = "one" })
		s.boards:submit(a, "today", 10)
		s.boards:flushAsync()
		local first = s.boards:storeName("today")
		s.boards:refreshAsync("today")
		expect(#s.boards:get("today").entries).toBe(1)
		local endsAt = s.boards:periodEndsAt("today") :: number
		s.clock:advance(endsAt + 1 - s.clock:now())
		expect(s.boards:storeName("today")).never.toBe(first)
		-- Yesterday's cached top doesn't show as today's.
		expect(#s.boards:get("today").entries).toBe(0)
		s.boards:submit(a, "today", 3)
		s.boards:flushAsync()
		expect(s.dss:GetOrderedDataStore(s.boards:storeName("today")):GetAsync("1")).toBe(3)
	end)

	T.it("set mode replaces the stored value", function()
		local s = setup()
		local a = s.players:join({ UserId = 1, Name = "one" })
		s.boards:submit(a, "current", 10)
		s.boards:flushAsync()
		s.boards:submit(a, "current", 4)
		s.boards:flushAsync()
		expect(s.dss:GetOrderedDataStore("LB_current"):GetAsync("1")).toBe(4)
	end)

	T.it("keeps a failed write for the next flush", function()
		local s = setup()
		local a = s.players:join({ UserId = 1, Name = "one" })
		s.boards:submit(a, "best:gap", 9)
		s.dss:failNext("UpdateAsync", { times = 1 })
		s.boards:flushAsync()
		expect(s.dss:GetOrderedDataStore("LB_best:gap"):GetAsync("1")).toBeNil()
		s.boards:flushAsync()
		expect(s.dss:GetOrderedDataStore("LB_best:gap"):GetAsync("1")).toBe(9000)
	end)

	T.it("looks names up once in a batch and caches them", function()
		local s = setup()
		for id = 10, 14 do
			s.dss:GetOrderedDataStore("LB_wins"):SetAsync(tostring(id), id)
		end
		s.boards:refreshAsync("wins")
		s.boards:refreshAsync("wins")
		expect(s.userService.calls).toBe(1)
		local top = s.boards:get("wins").entries[1]
		expect(top.userId).toBe(14)
		expect(top.displayName).toBe("User 14")
	end)

	T.it("removes a player from a board", function()
		local s = setup()
		s.dss:GetOrderedDataStore("LB_wins"):SetAsync("1", 50)
		s.dss:GetOrderedDataStore("LB_wins"):SetAsync("2", 40)
		s.boards:refreshAsync("wins")
		expect((s.boards:removeAsync("wins", 1))).toBe(true)
		local entries = s.boards:get("wins").entries
		expect(#entries).toBe(1)
		expect(entries[1].rank).toBe(1)
		expect(s.dss:GetOrderedDataStore("LB_wins"):GetAsync("1")).toBeNil()
	end)

	T.it("rejects bad board configs", function()
		expect(function()
			Leaderboards.new({ boards = { { id = "a b" } } })
		end).toThrow("board id")
		expect(function()
			Leaderboards.new({ boards = { { id = "a", size = 500 } } })
		end).toThrow("size")
	end)
end)
