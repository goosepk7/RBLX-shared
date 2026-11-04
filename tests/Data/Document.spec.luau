--!strict
local Document = require("@shared/Data/Document")
local T = require("@shared/Test")

local expect = T.expect

local function ctx(overrides: { [string]: any }?): Document.LoadContext
	local base: any = {
		sessionId = "me",
		jobId = "job",
		placeId = 1,
		now = 1000,
		version = 2,
		lockTimeout = 600,
		forceReleaseTimeout = 40,
	}
	local extra: { [string]: any } = overrides or {}
	for key, value in extra do
		base[key] = value
	end
	return base
end

local function doc(meta: { [string]: any }?): any
	local base: any = { schemaVersion = 2, createdAt = 1, updatedAt = 1, loadCount = 1, receipts = {} }
	local extra: { [string]: any } = meta or {}
	for key, value in extra do
		base[key] = value
	end
	return { data = { coins = 1 }, meta = base }
end

T.describe("Data.Document.decideLoad", function()
	T.it("creates only when there is no value", function()
		expect((Document.decideLoad(nil, ctx()))).toBe("create")
	end)

	T.it("refuses values that aren't profiles and newer schema versions", function()
		local decision, why = Document.decideLoad("garbage", ctx())
		expect(decision).toBe("corrupt")
		expect(why).toContain("string")
		expect((Document.decideLoad({ meta = {} }, ctx()))).toBe("corrupt")
		decision, why = Document.decideLoad(doc({ schemaVersion = 3 }), ctx())
		expect(decision).toBe("newer")
		expect(why).toContain("3")
	end)

	T.it("takes free, own and dead locks", function()
		expect((Document.decideLoad(doc(), ctx()))).toBe("take")
		expect((Document.decideLoad(doc({ session = { sessionId = "me", heartbeatAt = 999 } }), ctx()))).toBe("take")
		local decision, detail =
			Document.decideLoad(doc({ session = { sessionId = "other", heartbeatAt = 400 } }), ctx())
		expect(decision).toBe("take")
		expect(detail).toBe("dead")
	end)

	T.it("asks a live owner to release, waits, then steals after the timeout", function()
		local live = { sessionId = "other", heartbeatAt = 990 }
		expect((Document.decideLoad(doc({ session = live }), ctx()))).toBe("request")
		local pending = doc({ session = live, forceRelease = { sessionId = "me", requestedAt = 980 } })
		expect((Document.decideLoad(pending, ctx()))).toBe("wait")
		expect((Document.decideLoad(pending, ctx({ now = 1020 })))).toBe("steal")
		-- Someone else's request doesn't count as ours.
		local theirs = doc({ session = live, forceRelease = { sessionId = "third", requestedAt = 0 } })
		expect((Document.decideLoad(theirs, ctx()))).toBe("request")
	end)
end)

T.describe("Data.Document.decideSave", function()
	T.it("saves while we own the lock and hands it back on request or release", function()
		local mine = doc({ session = { sessionId = "me", heartbeatAt = 1 } })
		expect((Document.decideSave(mine, "me", false))).toBe("saved")
		expect((Document.decideSave(mine, "me", true))).toBe("released")
		mine.meta.forceRelease = { sessionId = "other", requestedAt = 5 }
		expect((Document.decideSave(mine, "me", false))).toBe("forceReleased")
	end)

	T.it("never writes once the lock is gone or the value was deleted", function()
		expect((Document.decideSave(nil, "me", false))).toBe("lockLost")
		expect((Document.decideSave(doc({ session = { sessionId = "other", heartbeatAt = 1 } }), "me", false))).toBe(
			"lockLost"
		)
		expect((Document.decideSave(doc(), "me", true))).toBe("lockLost")
	end)

	T.it("forSave keeps bookkeeping, refreshes the heartbeat and keeps pending requests", function()
		local old = doc({
			createdAt = 5,
			loadCount = 7,
			session = { sessionId = "me", jobId = "j", placeId = 1, lockedAt = 10, heartbeatAt = 10 },
			forceRelease = { sessionId = "other", requestedAt = 20 },
		})
		local memory: any = { schemaVersion = 2, receipts = { { purchaseId = "p", productId = 1, grantedAt = 3 } } }
		local kept = Document.forSave(old, { coins = 9 }, memory, 30, true)
		expect(kept.data.coins).toBe(9)
		expect(kept.meta.createdAt).toBe(5)
		expect(kept.meta.loadCount).toBe(7)
		expect(kept.meta.updatedAt).toBe(30)
		local session = kept.meta.session
		assert(session, "expected a session")
		expect(session.heartbeatAt).toBe(30)
		expect(session.lockedAt).toBe(10)
		expect(kept.meta.receipts[1].purchaseId).toBe("p")
		expect(kept.meta.forceRelease).toEqual({ sessionId = "other", requestedAt = 20 })
		-- The stored lock table isn't mutated.
		expect(old.meta.session.heartbeatAt).toBe(10)

		local released = Document.forSave(old, { coins = 9 }, memory, 30, false)
		expect(released.meta.session).toBeNil()
	end)
end)

T.describe("Data.Document.migrate / reconcile", function()
	T.it("runs each step in order, in place or by return value", function()
		local ok, data = Document.migrate({ coins = 5 }, 1, 3, {
			[2] = function(d)
				d.gems = 0
				return nil
			end,
			[3] = function(d)
				return { cash = d.coins, gems = d.gems }
			end,
		})
		expect(ok).toBe(true)
		expect(data).toEqual({ cash = 5, gems = 0 })
	end)

	T.it("reports a missing or failing step", function()
		local ok, why = Document.migrate({}, 1, 2, {})
		expect(ok).toBe(false)
		expect(why).toContain("no migration to schema version 2")
		ok, why = Document.migrate({}, 1, 2, {
			[2] = function()
				error("bad step")
			end,
		})
		expect(ok).toBe(false)
		expect(why).toContain("bad step")
	end)

	T.it("adds missing template keys without touching existing values or arrays", function()
		local data: any = { coins = 3, settings = { music = false }, owned = { "a" } }
		Document.reconcile(data, {
			coins = 0,
			gems = 0,
			settings = { music = true, sfx = true },
			owned = { "default" },
			stats = { deaths = 0 },
		})
		expect(data).toEqual({
			coins = 3,
			gems = 0,
			settings = { music = false, sfx = true },
			owned = { "a" },
			stats = { deaths = 0 },
		})
	end)
end)
