--!strict
local Badges = require("@shared/Badges")
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

type FakeBadgeService = {
	owned: { [string]: boolean },
	failures: number,
	awardCalls: number,
	AwardBadge: (self: FakeBadgeService, userId: number, id: number) -> boolean,
	UserHasBadgeAsync: (self: FakeBadgeService, userId: number, id: number) -> boolean,
}

local function badgeService(): FakeBadgeService
	local service = { owned = {}, failures = 0, awardCalls = 0 } :: FakeBadgeService
	function service.AwardBadge(self: FakeBadgeService, userId: number, id: number): boolean
		self.awardCalls += 1
		if self.failures > 0 then
			self.failures -= 1
			error("HTTP 500 (injected)")
		end
		local key = userId .. ":" .. id
		if self.owned[key] then
			return false
		end
		self.owned[key] = true
		return true
	end
	function service.UserHasBadgeAsync(self: FakeBadgeService, userId: number, id: number): boolean
		return self.owned[userId .. ":" .. id] == true
	end
	return service
end

local function setup(ids: { [string]: number }?): (Badges.Badges, FakeBadgeService, any, any)
	local clock = T.Clock.new()
	local service = badgeService()
	local idMap: { [string]: number } = ids or {}
	local badges = Badges.new({
		badges = {
			{ key = "FirstWin", id = idMap.FirstWin or 11, icon = "icon_wins" },
			{ key = "Rebirth1", id = idMap.Rebirth1 or 0, announce = true },
		},
		badgeService = service,
		task = clock.task,
		now = function()
			return clock:now()
		end,
	})
	local player = T.Fakes.Players.newPlayer({ UserId = 7, Name = "seven" })
	return badges, service, clock, player
end

T.describe("Badges", function()
	T.it("earns once, fires Earned once and delivers to Roblox", function()
		local badges, service, clock, player = setup()
		local data = {}
		badges:attach(player, data)
		local earned: { string } = {}
		badges.Earned:Connect(function(_p: any, _id: number, def: Badges.BadgeDef)
			table.insert(earned, def.key)
		end)
		expect(badges:award(player, "FirstWin")).toBe(true)
		expect(badges:award(player, "FirstWin")).toBe(false)
		clock:flush()
		expect(earned).toEqual({ "FirstWin" })
		expect(service.owned["7:11"]).toBe(true)
		expect((data :: any).badges.awarded.FirstWin).never.toBeNil()
	end)

	T.it("keeps a badge without an id earned and delivers it once the id exists", function()
		local badges, service, clock, player = setup()
		local data = {}
		badges:attach(player, data)
		expect(badges:award(player, "Rebirth1")).toBe(true)
		clock:flush()
		expect(service.awardCalls).toBe(0)
		expect(badges:has(player, "Rebirth1")).toBe(true)

		-- After launch the owner pastes the id; the next join delivers it.
		local later, laterService, laterClock = setup({ Rebirth1 = 22 })
		later:attach(player, data)
		laterClock:flush()
		expect(laterService.owned["7:22"]).toBe(true)
	end)

	T.it("retries failed deliveries and tries again on the next join", function()
		local badges, service, clock, player = setup()
		local data = {}
		badges:attach(player, data)
		service.failures = 3
		badges:award(player, "FirstWin")
		clock:advance(30)
		expect(service.owned["7:11"]).toBeNil()
		expect((data :: any).badges.awarded.FirstWin).toBeNil()
		badges:attach(player, data)
		clock:advance(30)
		expect(service.owned["7:11"]).toBe(true)
	end)

	T.it("treats an already-owned Roblox badge as delivered", function()
		local badges, service, clock, player = setup()
		service.owned["7:11"] = true
		local data = {}
		badges:attach(player, data)
		badges:award(player, "FirstWin")
		clock:flush()
		expect((data :: any).badges.awarded.FirstWin).never.toBeNil()
	end)

	T.it("ignores unknown badges and players it doesn't know", function()
		local badges = setup()
		expect(badges:award(99, "FirstWin")).toBe(false)
		expect(badges:award(99, "Nope")).toBe(false)
	end)
end)
