--!strict
local T = require("@shared/Test")
local expect = T.expect
local Fakes = T.Fakes

T.describe("Fakes.DataStoreService", function()
	T.it("round-trips values as deep copies", function()
		local dss = Fakes.DataStoreService.new()
		local store = dss:GetDataStore("Profiles")
		local value = { coins = 5, items = { "a", "b" } }
		store:SetAsync("u_1", value)
		value.coins = 999
		local loaded, info = store:GetAsync("u_1")
		expect(loaded).toEqual({ coins = 5, items = { "a", "b" } })
		expect(info).never.toBeNil()
		expect((info :: any).Version).toBeType("string")
	end)

	T.it("distinguishes a missing key from a failure", function()
		local dss = Fakes.DataStoreService.new()
		local store = dss:GetDataStore("Profiles")
		local value, info = store:GetAsync("new_player")
		expect(value).toBeNil()
		expect(info).toBeNil()
		dss:failNext("GetAsync", { code = 503, times = 2 })
		expect(function()
			store:GetAsync("new_player")
		end).toThrow("503:")
		expect(function()
			store:GetAsync("new_player")
		end).toThrow("503:")
		expect((store:GetAsync("new_player"))).toBeNil()
	end)

	T.it("UpdateAsync passes keyInfo, honours cancel, writes metadata and userIds", function()
		local dss = Fakes.DataStoreService.new()
		local store = dss:GetDataStore("Profiles")
		local first, firstInfo = store:UpdateAsync("k", function(old, info)
			expect(old).toBeNil()
			expect(info).toBeNil()
			return { n = 1 }, { 42 }, { lock = "server-a" }
		end)
		expect(first).toEqual({ n = 1 })
		expect((firstInfo :: any):GetMetadata()).toEqual({ lock = "server-a" })
		expect((firstInfo :: any):GetUserIds()).toEqual({ 42 })

		local cancelled = store:UpdateAsync("k", function(old, info)
			expect(old).toEqual({ n = 1 })
			expect((info :: any):GetMetadata().lock).toBe("server-a")
			return nil
		end)
		expect(cancelled).toBeNil()
		expect(dss:inspect("Profiles", "k")).toEqual({ n = 1 })

		local versionBefore = dss:versionOf("Profiles", "k")
		store:UpdateAsync("k", function(old)
			old.n += 1
			return old
		end)
		expect(dss:versionOf("Profiles", "k")).never.toBe(versionBefore)
	end)

	T.it("SetAsync accepts set options with metadata", function()
		local dss = Fakes.DataStoreService.new()
		local options = dss:newSetOptions()
		options:SetMetadata({ schema = 3 })
		dss:GetDataStore("P"):SetAsync("k", 1, nil, options)
		local _, info = dss:GetDataStore("P"):GetAsync("k")
		expect((info :: any):GetMetadata()).toEqual({ schema = 3 })
	end)

	T.it("rejects values Roblox cannot store", function()
		local store = Fakes.DataStoreService.new():GetDataStore("P")
		expect(function()
			store:SetAsync("k", { f = function() end })
		end).toThrow("104:")
		expect(function()
			store:SetAsync("k", { 0 / 0 })
		end).toThrow("NaN")
		expect(function()
			store:SetAsync("k", { [1] = "a", x = "b" })
		end).toThrow("mixed")
		expect(function()
			store:SetAsync("k", string.rep("x", 4_194_304))
		end).toThrow("105:")
		expect(function()
			store:SetAsync(string.rep("k", 51), 1)
		end).toThrow("102:")
	end)

	T.it("is shared across simulated servers", function()
		local dss = Fakes.DataStoreService.new()
		dss:GetDataStore("P"):SetAsync("k", "from server A")
		local serverB = dss -- a second server gets the same service instance
		expect((serverB:GetDataStore("P"):GetAsync("k"))).toBe("from server A")
	end)

	T.it("scopes are isolated", function()
		local dss = Fakes.DataStoreService.new()
		dss:GetDataStore("P", "a"):SetAsync("k", 1)
		expect((dss:GetDataStore("P", "b"):GetAsync("k"))).toBeNil()
	end)

	T.it("failure rate injection is deterministic per seed", function()
		local function failures(seed: number): number
			local dss = Fakes.DataStoreService.new()
			dss:setFailureRate(0.3, seed)
			local store = dss:GetDataStore("P")
			local count = 0
			for i = 1, 200 do
				if not pcall(store.SetAsync, store, "k" .. i, i) then
					count += 1
				end
			end
			return count
		end
		expect(failures(7)).toBe(failures(7))
		expect(failures(7)).toBeGreaterThan(30)
		expect(failures(7)).toBeLessThan(90)
	end)

	T.it("logs calls", function()
		local dss = Fakes.DataStoreService.new()
		local store = dss:GetDataStore("P")
		store:SetAsync("k", 1)
		store:GetAsync("k")
		dss:failNext("GetAsync")
		pcall(store.GetAsync, store, "k")
		local gets = dss:calls("GetAsync")
		expect(#gets).toBe(2)
		expect(gets[2].ok).toBe(false)
		expect(gets[2].error).toContain("502:")
	end)

	T.it("UpdateAsync reruns transform when another server writes between read and commit", function()
		local dss = Fakes.DataStoreService.new()
		local store = dss:GetDataStore("Profiles")
		store:SetAsync("u_1", { lock = "server_a", coins = 1 })
		local other = dss:GetDataStore("Profiles") -- a second server sharing the backend
		local seen: { string } = {}
		dss:setBeforeCommit(function(ctx)
			if ctx.attempt == 1 then
				-- Server B steals the session lock while server A's transform is in flight.
				other:SetAsync(ctx.key, { lock = "server_b", coins = 50 })
			end
		end)
		local result = store:UpdateAsync("u_1", function(old)
			table.insert(seen, old.lock)
			if old.lock ~= "server_a" then
				return nil -- lost the lock: cancel
			end
			old.coins += 1
			return old
		end)
		-- First run saw A's lock; the rerun saw B's lock and cancelled instead of clobbering it.
		expect(seen).toEqual({ "server_a", "server_b" })
		expect(result).toBeNil()
		expect(dss:inspect("Profiles", "u_1")).toEqual({ lock = "server_b", coins = 50 })
		expect(#dss:calls("UpdateAsync.conflict")).toBe(1)
	end)

	T.it("UpdateAsync commits the rerun result and gives up after repeated conflicts", function()
		local dss = Fakes.DataStoreService.new()
		local store = dss:GetDataStore("Counters")
		store:SetAsync("k", 1)
		dss:setBeforeCommit(function(ctx)
			if ctx.attempt <= 2 then
				dss:seed("Counters", ctx.key, 100 * ctx.attempt)
			end
		end)
		local runs = 0
		local value = store:UpdateAsync("k", function(old)
			runs += 1
			return old + 1
		end)
		expect(runs).toBe(3)
		expect(value).toBe(201)

		dss:setBeforeCommit(function(ctx)
			dss:seed("Counters", ctx.key, ctx.attempt)
		end)
		expect(function()
			store:UpdateAsync("k", function(old)
				return old + 1
			end)
		end).toThrow("UpdateAsync conflict")

		-- A hook error surfaces from UpdateAsync, and the hook doesn't fire for its own writes.
		dss:setBeforeCommit(function()
			error("hook boom")
		end)
		expect(function()
			store:UpdateAsync("k", function(old)
				return old
			end)
		end).toThrow("hook boom")
		dss:setBeforeCommit(nil)
	end)

	T.it("request budgets decrement, throttle, and refill with time", function()
		local dss = Fakes.DataStoreService.new()
		local t = 0
		dss:setNow(function()
			return t
		end)
		local store = dss:GetDataStore("Profiles")
		expect(dss:GetRequestBudgetForRequestType("GetAsync")).toBe(1_000_000) -- unlimited until enabled

		dss:enableBudgets({ players = 2 }) -- 60 + 2 * 10 = 80 per minute
		expect(dss:GetRequestBudgetForRequestType("GetAsync")).toBe(80)
		store:GetAsync("a")
		store:GetAsync("b")
		expect(dss:GetRequestBudgetForRequestType({ Name = "GetAsync" })).toBe(78)
		store:UpdateAsync("a", function()
			return 1
		end)
		expect(dss:GetRequestBudgetForRequestType("GetAsync")).toBe(77)
		expect(dss:GetRequestBudgetForRequestType("Enum.DataStoreRequestType.SetIncrementAsync")).toBe(79)

		dss:setBudget(1)
		store:GetAsync("a")
		expect(function()
			store:GetAsync("a")
		end).toThrow("301: GetAsync request dropped")
		expect(dss:GetRequestBudgetForRequestType("GetAsync")).toBe(0)
		-- UpdateAsync needs both budgets; SetIncrementAsync still has 1 but GetAsync has none.
		expect(function()
			store:UpdateAsync("a", function()
				return 2
			end)
		end).toThrow("304:")
		expect(dss:GetRequestBudgetForRequestType("SetIncrementAsync")).toBe(1)

		t += 30_000 -- half a minute refills 40
		expect(dss:GetRequestBudgetForRequestType("GetAsync")).toBe(40)
		store:GetAsync("a")
		t += 60 * 60_000 -- an hour caps at 3 minutes' worth
		expect(dss:GetRequestBudgetForRequestType("GetAsync")).toBe(240)

		local ordered = dss:GetOrderedDataStore("Wins")
		dss:setBudget(0)
		expect(function()
			ordered:GetSortedAsync(false, 10)
		end).toThrow("305:")
		dss:reset()
		expect(dss:GetRequestBudgetForRequestType("GetAsync")).toBe(1_000_000)
	end)

	T.it("ordered stores sort and page", function()
		local dss = Fakes.DataStoreService.new()
		local board = dss:GetOrderedDataStore("Wins")
		for i = 1, 25 do
			board:SetAsync("u" .. i, i * 10)
		end
		local pages = board:GetSortedAsync(false, 10)
		local first = pages:GetCurrentPage()
		expect(#first).toBe(10)
		expect(first[1]).toEqual({ key = "u25", value = 250 })
		expect(pages.IsFinished).toBe(false)
		pages:AdvanceToNextPageAsync()
		pages:AdvanceToNextPageAsync()
		expect(#pages:GetCurrentPage()).toBe(5)
		expect(pages.IsFinished).toBe(true)
		expect(function()
			board:SetAsync("x", 1.5)
		end).toThrow("integers")
	end)
end)

T.describe("Fakes.MarketplaceService", function()
	local function makeShop(mps: typeof(Fakes.MarketplaceService.new()))
		local granted: { [string]: boolean } = {}
		local coins = 0
		mps.ProcessReceipt = function(receipt)
			if granted[receipt.PurchaseId] then
				return mps.Decision.PurchaseGranted
			end
			granted[receipt.PurchaseId] = true
			coins += 100
			return mps.Decision.PurchaseGranted
		end
		return function()
			return coins
		end
	end

	T.it("delivers receipts and supports replay for idempotency tests", function()
		local mps = Fakes.MarketplaceService.new()
		local coins = makeShop(mps)
		local player = { UserId = 7 }
		local receipt, decision = mps:purchaseProduct(player, 55)
		expect(decision).toBe(mps.Decision.PurchaseGranted)
		mps:replay(receipt)
		expect(coins()).toBe(100)
		expect(mps:grantedCount(receipt.PurchaseId)).toBe(2)
	end)

	T.it("keeps NotProcessedYet and erroring receipts pending until retried", function()
		local mps = Fakes.MarketplaceService.new()
		local dataReady = false
		mps.ProcessReceipt = function(_receipt)
			if not dataReady then
				error("profile not loaded")
			end
			return mps.Decision.PurchaseGranted
		end
		local _, decision, err = mps:purchaseProduct({ UserId = 1 }, 9)
		expect(decision).toBe(mps.Decision.NotProcessedYet)
		expect(err).toContain("profile not loaded")
		expect(#mps:pending()).toBe(1)
		dataReady = true
		local results = mps:retryPending()
		expect(results[1].decision).toBe(mps.Decision.PurchaseGranted)
		expect(#mps:pending()).toBe(0)
	end)

	T.it("tracks game pass ownership, prompts and ownership failures", function()
		local mps = Fakes.MarketplaceService.new()
		local player = { UserId = 3 }
		expect(mps:UserOwnsGamePassAsync(3, 100)).toBe(false)
		mps:PromptGamePassPurchase(player, 100)
		local finished: { boolean } = {}
		mps.PromptGamePassPurchaseFinished:Connect(function(_p, _id, purchased)
			table.insert(finished, purchased)
		end)
		mps:completeGamePassPrompt(player, 100, true)
		expect(finished).toEqual({ true })
		expect(mps:UserOwnsGamePassAsync(3, 100)).toBe(true)
		expect(mps:prompts()[1]).toEqual({ kind = "gamepass", userId = 3, id = 100 })
		mps:failOwnershipChecks(1)
		expect(function()
			mps:UserOwnsGamePassAsync(3, 100)
		end).toThrow("HTTP 500")
	end)
end)

T.describe("Fakes.Players", function()
	T.it("fires join and leave signals", function()
		local players = Fakes.Players.new()
		local events: { string } = {}
		players.PlayerAdded:Connect(function(p)
			table.insert(events, "+" .. p.Name)
		end)
		players.PlayerRemoving:Connect(function(p)
			table.insert(events, "-" .. p.Name)
		end)
		local a = players:join({ UserId = 1, Name = "a" })
		players:join({ UserId = 2, Name = "b" })
		expect(#players:GetPlayers()).toBe(2)
		players:leave(a)
		expect(events).toEqual({ "+a", "+b", "-a" })
		expect(players:GetPlayerByUserId(1)).toBeNil()
		expect(a.Parent).toBeNil()
	end)

	T.it("kick removes the player and records the message", function()
		local players = Fakes.Players.new()
		local removed = 0
		players.PlayerRemoving:Connect(function()
			removed += 1
		end)
		local p = players:join({ UserId = 5 })
		p:Kick("flagged")
		expect(p:wasKicked()).toBe(true)
		expect(p:kickMessage()).toBe("flagged")
		expect(removed).toBe(1)
		expect(#players:GetPlayers()).toBe(0)
	end)

	T.it("supports attributes with change signals", function()
		local p = Fakes.Players.newPlayer({ UserId = 9 })
		local changes = 0
		p:GetAttributeChangedSignal("Wins"):Connect(function()
			changes += 1
		end)
		p:SetAttribute("Wins", 3)
		p:SetAttribute("Wins", 3)
		p:SetAttribute("Wins", 4)
		expect(p:GetAttribute("Wins")).toBe(4)
		expect(changes).toBe(2)
	end)
end)
