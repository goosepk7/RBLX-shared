--!strict
--[[
	Data.Document: the stored shape of a profile, and the decisions made inside UpdateAsync
	transforms. Everything here is pure: transforms must not yield and may run more than once.

	Every key holds:
	  { data = <the game's data>, meta = Types.ProfileMeta }

	Session lock rules (ProfileStore-style):
	  * No value: a brand-new player. Only a successful read can say so; a failed read never does.
	  * Unlocked, already ours, or the owner's heartbeat is older than lockTimeout: take it.
	  * Owned by a live session: write a release request into meta.forceRelease. The owner sees
	    it on its next save (or at once, from the MessagingService ping) and hands the lock back.
	  * Our request has waited forceReleaseTimeout with no answer: take it anyway. The old owner
	    can't overwrite us afterwards, because every save checks ownership in its transform.
]]

local Deep = require("../Util/Deep")
local Types = require("../Types")

export type Document = { data: any, meta: Types.ProfileMeta }

export type LoadContext = {
	sessionId: string,
	jobId: string,
	placeId: number,
	-- Unix seconds.
	now: number,
	-- The code's schema version.
	version: number,
	lockTimeout: number,
	forceReleaseTimeout: number,
}

-- create: no value yet. take: free, ours, or dead (detail "dead"). steal: the live owner ignored
-- our request. request: ask the owner to release. wait: our request is pending.
-- corrupt / newer: refuse, and leave the value untouched.
export type LoadDecision = "create" | "take" | "steal" | "request" | "wait" | "corrupt" | "newer"

-- saved: written, lock kept. released: written, lock handed back. forceReleased: written and
-- handed back because another server asked. lockLost: not written; we no longer own it.
export type SaveDecision = "saved" | "released" | "forceReleased" | "lockLost"

local Document = {}

-- Checks that a stored value is a profile document. Tolerates missing optional meta fields.
function Document.check(value: any): (boolean, string?)
	if type(value) ~= "table" then
		return false, "stored value is a " .. typeof(value) .. ", not a profile"
	end
	if value.data == nil then
		return false, "profile has no data field"
	end
	local meta = value.meta
	if type(meta) ~= "table" then
		return false, "profile has no meta table"
	end
	if type(meta.schemaVersion) ~= "number" then
		return false, "profile meta has no schemaVersion"
	end
	local session = meta.session
	if session ~= nil and (type(session) ~= "table" or type(session.sessionId) ~= "string") then
		return false, "profile meta has an unreadable session lock"
	end
	if meta.receipts ~= nil and type(meta.receipts) ~= "table" then
		return false, "profile meta.receipts is not a list"
	end
	return true, nil
end

-- Fills meta fields an older writer may have left out. Only call on a checked document.
function Document.normalize(doc: Document, now: number)
	local meta = doc.meta :: any
	meta.createdAt = if type(meta.createdAt) == "number" then meta.createdAt else now
	meta.updatedAt = if type(meta.updatedAt) == "number" then meta.updatedAt else now
	meta.loadCount = if type(meta.loadCount) == "number" then meta.loadCount else 0
	meta.receipts = if type(meta.receipts) == "table" then meta.receipts else {}
end

function Document.session(ctx: LoadContext): Types.SessionLock
	return {
		sessionId = ctx.sessionId,
		jobId = ctx.jobId,
		placeId = ctx.placeId,
		lockedAt = ctx.now,
		heartbeatAt = ctx.now,
	}
end

function Document.new(data: any, ctx: LoadContext): Document
	return {
		data = data,
		meta = {
			schemaVersion = ctx.version,
			createdAt = ctx.now,
			updatedAt = ctx.now,
			loadCount = 1,
			session = Document.session(ctx),
			forceRelease = nil,
			receipts = {},
		},
	}
end

-- What a load should do with the value currently stored. `detail` explains corrupt/newer/take.
function Document.decideLoad(old: any, ctx: LoadContext): (LoadDecision, string?)
	if old == nil then
		return "create", nil
	end
	local ok, why = Document.check(old)
	if not ok then
		return "corrupt", why
	end
	local meta = old.meta
	if meta.schemaVersion > ctx.version then
		return "newer", "saved with schema version " .. tostring(meta.schemaVersion)
	end
	local session = meta.session
	if session == nil or session.sessionId == ctx.sessionId then
		return "take", nil
	end
	local heartbeat = if type(session.heartbeatAt) == "number" then session.heartbeatAt else 0
	if ctx.now - heartbeat >= ctx.lockTimeout then
		return "take", "dead"
	end
	local request = meta.forceRelease
	if type(request) == "table" and request.sessionId == ctx.sessionId then
		local requestedAt = if type(request.requestedAt) == "number" then request.requestedAt else ctx.now
		if ctx.now - requestedAt >= ctx.forceReleaseTimeout then
			return "steal", nil
		end
		return "wait", nil
	end
	return "request", nil
end

--[[
	Runs migrations[v] for every v in (from, to]. Each takes the data at version v - 1 and returns
	the data at version v (or nil after changing it in place). Returns (true, data) or
	(false, reason). A migration that errors, yields or is missing fails the whole load.
]]
function Document.migrate(
	data: any,
	from: number,
	to: number,
	migrations: { [number]: (data: any) -> any }
): (boolean, any)
	local current = data
	for version = from + 1, to do
		local step = migrations[version]
		if step == nil then
			return false, "no migration to schema version " .. tostring(version)
		end
		local ok, result = pcall(step, current)
		if not ok then
			return false, "migration to schema version " .. tostring(version) .. " errored: " .. tostring(result)
		end
		if result ~= nil then
			current = result
		end
	end
	return true, current
end

--[[
	Adds template keys that `data` is missing (deep copies), recursing into dictionaries that
	exist on both sides. Existing values are never changed, and arrays are left alone.
]]
function Document.reconcile(data: any, template: any)
	if type(data) ~= "table" or type(template) ~= "table" then
		return
	end
	for key, default in template do
		local current = data[key]
		if current == nil then
			data[key] = Deep.copy(default)
		elseif type(current) == "table" and type(default) == "table" and not Deep.isArray(default) then
			Document.reconcile(current, default)
		end
	end
end

-- What a save should do with the value currently stored.
function Document.decideSave(old: any, sessionId: string, release: boolean): (SaveDecision, string?)
	if old == nil then
		return "lockLost", "the profile was deleted"
	end
	local ok, why = Document.check(old)
	if not ok then
		return "lockLost", why
	end
	local session = old.meta.session
	if session == nil or session.sessionId ~= sessionId then
		return "lockLost", "another server took the session lock"
	end
	if release then
		return "released", nil
	end
	local request = old.meta.forceRelease
	if type(request) == "table" and request.sessionId ~= sessionId then
		return "forceReleased", nil
	end
	return "saved", nil
end

--[[
	The document a save writes: our data and receipts, the stored bookkeeping, and either a fresh
	heartbeat (keepLock) or no session. A pending release request from another server is kept so
	that server knows it was answered.
]]
function Document.forSave(old: Document, data: any, meta: Types.ProfileMeta, now: number, keepLock: boolean): Document
	local stored = old.meta
	local session: Types.SessionLock? = nil
	local current = stored.session
	if keepLock and current then
		local fresh = table.clone(current)
		fresh.heartbeatAt = now
		session = fresh
	end
	return {
		data = data,
		meta = {
			schemaVersion = meta.schemaVersion,
			createdAt = stored.createdAt,
			updatedAt = now,
			loadCount = stored.loadCount,
			session = session,
			forceRelease = stored.forceRelease,
			receipts = meta.receipts,
		},
	}
end

return Document
