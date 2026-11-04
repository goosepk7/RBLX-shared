--!strict
local Data = require("@shared/Data")
local Log = require("@shared/Util/Log")
local T = require("@shared/Test")
local World = require("./World")

local expect = T.expect

local logs: { Log.Entry } = {}
local restoreLog: () -> () = function() end
T.beforeEach(function()
	logs, restoreLog = Log.capture()
end)
T.afterEach(function()
	restoreLog()
end)

local function logged(level: Log.Level, text: string): boolean
	for _, entry in logs do
		if entry.level == level and string.find(entry.message, text, 1, true) then
			return true
		end
	end
	return false
end

type Shop = {
	world: World.World,
	server: World.Server,
	grants: { string },
	-- Routes MarketplaceService.ProcessReceipt to `server`.
	use: (self: Shop, server: World.Server) -> (),
}

local COINS_PRODUCT = 1001

local function shop(): Shop
	local world = World.new()
	local result: Shop
	result = {
		world = world,
		server = world:server("A"),
		grants = {},
		use = function(self: Shop, server: World.Server)
			self.server = server
		end,
	}
	world.mps.ProcessReceipt = function(receipt: any)
		return result.server.store:processReceipt(receipt, function(profile: any, r: any)
			table.insert(result.grants, r.PurchaseId)
			profile.data.coins += 100
			return true
		end)
	end
	result.server.store:bindPlayers()
	return result
end

T.describe("Data.Store purchases", function()
	T.it("grants once, saves, then confirms; a replay is confirmed without a second grant", function()
		local s = shop()
		local player = s.server:join(1)
		local confirmed: { string } = {}
		s.server.store.ReceiptGranted:Connect(function(who: any, _profile: any, receipt: any)
			expect(who).toBe(player)
			table.insert(confirmed, receipt.PurchaseId)
		end)
		local receipt, decision = s.world.mps:purchaseProduct(player, COINS_PRODUCT)
		expect(decision).toBe(s.world.mps.Decision.PurchaseGranted)
		expect(#s.grants).toBe(1)
		-- Saved before Roblox was told.
		local stored = s.world:stored(1)
		expect(stored.data.coins).toBe(100)
		expect(stored.meta.receipts[1].purchaseId).toBe(receipt.PurchaseId)
		expect(stored.meta.receipts[1].productId).toBe(COINS_PRODUCT)
		expect(confirmed).toEqual({ receipt.PurchaseId })

		expect((s.world.mps:replay(receipt))).toBe(s.world.mps.Decision.PurchaseGranted)
		expect(#s.grants).toBe(1)
		local profile = s.server.store:get(player)
		assert(profile, "expected a profile")
		expect(profile.data.coins).toBe(100)
		expect(profile:hasReceipt(receipt.PurchaseId)).toBe(true)
		expect(#confirmed).toBe(1)
		local counters = s.server:counters().counters
		expect(counters.receiptsGranted).toBe(1)
		expect(counters.receiptsDuplicate).toBe(1)
		expect(logged("info", receipt.PurchaseId)).toBe(true)
	end)

	T.it("holds the confirmation until the grant is saved", function()
		local s = shop()
		local player = s.server:join(1)
		s.world.dss:failNext("UpdateAsync", { times = 3 })
		local receipt, decision = s.world.mps:purchaseProduct(player, COINS_PRODUCT)
		expect(decision).toBe(s.world.mps.Decision.NotProcessedYet)
		local profile = s.server.store:get(player)
		assert(profile, "expected a profile")
		-- Granted in memory and remembered, but not on disk yet.
		expect(profile.data.coins).toBe(100)
		expect(s.world:stored(1).data.coins).toBe(0)
		expect(s.server:counters().profiles[1].unsavedReceipts).toBe(1)

		-- Roblox asks again: the grant isn't repeated, only saved.
		local results = s.world.mps:retryPending()
		expect(results[1].decision).toBe(s.world.mps.Decision.PurchaseGranted)
		expect(#s.grants).toBe(1)
		expect(s.world:stored(1).data.coins).toBe(100)
		expect(s.world:stored(1).meta.receipts[1].purchaseId).toBe(receipt.PurchaseId)
		expect(s.server:counters().profiles[1].unsavedReceipts).toBe(0)
	end)

	T.it("lets the autosave persist a grant whose own save failed", function()
		local s = shop()
		local player = s.server:join(1)
		s.world.dss:failNext("UpdateAsync", { times = 3 })
		local receipt = s.world.mps:purchaseProduct(player, COINS_PRODUCT)
		s.world.clock:advance(60)
		expect(s.world:stored(1).data.coins).toBe(100)
		expect((s.world.mps:replay(receipt))).toBe(s.world.mps.Decision.PurchaseGranted)
		expect(#s.grants).toBe(1)
		expect(s.server:counters().counters.receiptsDuplicate).toBe(1)
	end)

	T.it("confirms a purchase that lands mid-save only once its own save is stored", function()
		local s = shop()
		local player = s.server:join(1)
		local hooked = false
		local second: any = nil
		s.world.dss:setBeforeCommit(function()
			if hooked then
				return
			end
			hooked = true
			-- A second purchase arrives while the first one's save is between read and commit,
			-- and its own save is going to fail.
			s.world.dss:failNext("UpdateAsync", { times = 3 })
			s.world.clock.task.spawn(function()
				local _, decision = s.world.mps:purchaseProduct(player, COINS_PRODUCT, { purchaseId = "second" })
				second = decision
			end)
		end)
		local _, first = s.world.mps:purchaseProduct(player, COINS_PRODUCT, { purchaseId = "first" })
		expect(first).toBe(s.world.mps.Decision.PurchaseGranted)
		-- The first save stored the state from before the second grant.
		local stored = s.world:stored(1)
		expect(#stored.meta.receipts).toBe(1)
		expect(stored.data.coins).toBe(100)

		s.world.clock:advance(5)
		s.world.dss:setBeforeCommit(nil)
		expect(second).toBe(s.world.mps.Decision.NotProcessedYet)
		-- Roblox asks again, and hears back only after "second" is on disk.
		local results = s.world.mps:retryPending()
		expect(results[1].receipt.PurchaseId).toBe("second")
		expect(results[1].decision).toBe(s.world.mps.Decision.PurchaseGranted)
		stored = s.world:stored(1)
		expect(#stored.meta.receipts).toBe(2)
		expect(stored.meta.receipts[2].purchaseId).toBe("second")
		expect(stored.data.coins).toBe(200)
		expect(#s.grants).toBe(2)
	end)

	T.it("is not granted again when Roblox replays it on another server", function()
		local s = shop()
		local player = s.server:join(1)
		-- A grants and saves, then crashes before Roblox hears back.
		local receipt: any = {
			PlayerId = 1,
			ProductId = COINS_PRODUCT,
			PurchaseId = "lost-ack",
			CurrencySpent = 25,
			CurrencyType = "Robux",
			PlaceIdWherePurchased = 1,
		}
		local decision = s.server.store:processReceipt(receipt, function(profile: any)
			profile.data.coins += 100
			return true
		end)
		expect(decision).toBe(s.world.mps.Decision.PurchaseGranted)
		s.server:leave(player)

		local b = s.world:server("B")
		b.store:bindPlayers()
		s:use(b)
		b:join(1)
		expect((s.world.mps:replay(receipt))).toBe(s.world.mps.Decision.PurchaseGranted)
		expect(#s.grants).toBe(0)
		local profile = b.store:getByUserId(1)
		assert(profile, "expected B to load")
		expect(profile.data.coins).toBe(100)
	end)

	T.it("declines when the profile isn't loaded here or is being released", function()
		local s = shop()
		local receipt, decision = s.world.mps:purchaseProduct({ UserId = 99 }, COINS_PRODUCT)
		expect(decision).toBe(s.world.mps.Decision.NotProcessedYet)
		expect(#s.grants).toBe(0)
		expect(#s.world.mps:pending()).toBe(1)
		expect(receipt.PlayerId).toBe(99)

		local player = s.server:join(1)
		s.world.dss:failNext("UpdateAsync", { times = 5 })
		-- The release is stuck retrying: a purchase now would be lost with the profile.
		s.world.clock.task.spawn(function()
			s.server.store:releaseAsync(player)
		end)
		local _, late = s.world.mps:purchaseProduct(player, COINS_PRODUCT)
		expect(late).toBe(s.world.mps.Decision.NotProcessedYet)
		expect(#s.grants).toBe(0)
		expect(s.server:counters().counters.receiptsDeferred).toBe(2)
	end)

	T.it("waits for a profile that is still loading", function()
		local s = shop()
		s.world.dss:failNext("UpdateAsync", { times = 1 })
		local player = s.server:join(1)
		expect(s.server.store:isLoaded(player)).toBe(false)
		local _, decision = s.world.mps:purchaseProduct(player, COINS_PRODUCT)
		expect(decision).toBe(s.world.mps.Decision.PurchaseGranted)
		expect(#s.grants).toBe(1)
	end)

	T.it("declines and records nothing when the grant errors or says no", function()
		local s = shop()
		local player = s.server:join(1)
		local receipt: any = {
			PlayerId = 1,
			ProductId = 5,
			PurchaseId = "p-1",
			CurrencySpent = 5,
			CurrencyType = "Robux",
			PlaceIdWherePurchased = 1,
		}
		local decision = s.server.store:processReceipt(receipt, function(_profile: any): boolean?
			error("unknown product 5")
		end)
		expect(decision).toBe(s.world.mps.Decision.NotProcessedYet)
		expect(logged("error", "unknown product 5")).toBe(true)
		decision = s.server.store:processReceipt(receipt, function(_profile: any): boolean?
			return false
		end)
		expect(decision).toBe(s.world.mps.Decision.NotProcessedYet)
		local profile = s.server.store:get(player)
		assert(profile, "expected a profile")
		expect(profile:hasReceipt("p-1")).toBe(false)
		expect(#profile.meta.receipts).toBe(0)
		-- A later successful grant still goes through.
		decision = s.server.store:processReceipt(receipt, function(_profile: any): boolean?
			return nil
		end)
		expect(decision).toBe(s.world.mps.Decision.PurchaseGranted)
		expect(profile:hasReceipt("p-1")).toBe(true)
	end)

	T.it("keeps the newest receipts, up to Data.MAX_RECEIPTS", function()
		local s = shop()
		local player = s.server:join(1)
		for i = 1, Data.MAX_RECEIPTS + 5 do
			s.world.mps:purchaseProduct(player, COINS_PRODUCT, { purchaseId = "p-" .. tostring(i) })
		end
		local receipts = s.world:stored(1).meta.receipts
		expect(#receipts).toBe(Data.MAX_RECEIPTS)
		expect(receipts[1].purchaseId).toBe("p-6")
		expect(receipts[#receipts].purchaseId).toBe("p-" .. tostring(Data.MAX_RECEIPTS + 5))
		expect(s.world:stored(1).data.coins).toBe(100 * (Data.MAX_RECEIPTS + 5))
	end)
end)
