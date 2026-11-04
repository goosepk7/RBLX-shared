--!strict
local serde = require("@lune/serde")

local Backup = require("@tools/lib/backup")
local OpenCloud = require("@tools/lib/opencloud")
local T = require("@shared/Test")

local expect = T.expect

type Request =
	{ method: string, url: string, query: { [string]: string }?, body: string?, headers: { [string]: string } }
type Reply = { status: number, json: any? }

-- A fake Open Cloud: `route` answers each request; every request is recorded.
local function fakeTarget(
	route: (request: Request) -> Reply,
	overrides: { [string]: any }?
): (Backup.Target, { Request })
	local sent: { Request } = {}
	local client = OpenCloud.new({
		apiKey = "test-key",
		maxAttempts = 2,
		send = function(params: any)
			local request: Request = {
				method = params.method,
				url = params.url,
				query = params.query,
				body = params.body,
				headers = params.headers,
			}
			table.insert(sent, request)
			local reply = route(request)
			return {
				ok = reply.status < 400,
				statusCode = reply.status,
				statusMessage = "",
				headers = {},
				body = if reply.json ~= nil then serde.encode("json", reply.json, false) else "",
			}
		end,
		sleep = function() end,
	})
	local target: any = {
		client = client,
		universeId = "123",
		dataStore = "Stilts_Profiles",
		base = "https://cloud.test",
	}
	local extra: { [string]: any } = overrides or {}
	for key, value in extra do
		target[key] = value
	end
	return target :: Backup.Target, sent
end

local function profile(coins: number, meta: { [string]: any }?): any
	local base: any = { schemaVersion = 1, loadCount = 3, receipts = { { purchaseId = "old", productId = 1 } } }
	local extra: { [string]: any } = meta or {}
	for key, value in extra do
		base[key] = value
	end
	return { data = { coins = coins }, meta = base }
end

local ENTRIES = "https://cloud.test/cloud/v2/universes/123/data-stores/Stilts_Profiles/entries"

T.describe("tools/lib/backup", function()
	T.it("builds entry URLs, encoding names and adding non-global scopes", function()
		local target = fakeTarget(function()
			return { status = 200 }
		end, { dataStore = "My Store/1", scope = "beta" })
		expect(Backup.entriesUrl(target)).toBe(
			"https://cloud.test/cloud/v2/universes/123/data-stores/My%20Store%2F1/scopes/beta/entries"
		)
		expect(Backup.encode("Player_1-a.b~")).toBe("Player_1-a.b~")
	end)

	T.it("lists every page and keeps only keys with the prefix", function()
		local target, sent = fakeTarget(function(request)
			if request.query and request.query.pageToken == "p2" then
				return {
					status = 200,
					json = { dataStoreEntries = { { path = "universes/123/data-stores/x/entries/Player_3" } } },
				}
			end
			return {
				status = 200,
				json = {
					dataStoreEntries = { { id = "Player_1" }, { id = "Settings" }, { id = "Player_2" } },
					nextPageToken = "p2",
				},
			}
		end, { prefix = "Player_", pageSize = 500 })
		local ok, ids = Backup.listKeys(target)
		expect(ok).toBe(true)
		expect(ids).toEqual({ "Player_1", "Player_2", "Player_3" })
		expect(#sent).toBe(2)
		expect(sent[1].url).toBe(ENTRIES)
		expect(sent[1].headers["x-api-key"]).toBe("test-key")
		-- Page size is clamped to the API's maximum.
		expect((sent[1].query :: any).maxPageSize).toBe("256")
	end)

	T.it("treats an empty data store as no keys, and an unknown response shape as an error", function()
		local target = fakeTarget(function()
			return { status = 200, json = {} }
		end)
		local ok, ids = Backup.listKeys(target)
		expect(ok).toBe(true)
		expect(ids).toEqual({})

		local odd = fakeTarget(function()
			return { status = 200, json = { entries = { { id = "Player_1" } } } }
		end)
		local listed, why = Backup.listKeys(odd)
		expect(listed).toBe(false)
		expect(why).toContain("unexpected response fields (entries)")

		local denied = fakeTarget(function()
			return { status = 403, json = { message = "Insufficient scope" } }
		end)
		local allowed, reason = Backup.listKeys(denied)
		expect(allowed).toBe(false)
		expect(reason).toContain("HTTP 403: Insufficient scope")
	end)

	T.it("run writes one NDJSON line per entry and reports the ones it couldn't read", function()
		local target = fakeTarget(function(request)
			if request.url == ENTRIES then
				return { status = 200, json = { dataStoreEntries = { { id = "Player_1" }, { id = "Player_2" } } } }
			elseif request.url == ENTRIES .. "/Player_1" then
				return {
					status = 200,
					json = {
						id = "Player_1",
						revisionId = "r1",
						etag = "e1",
						users = { "users/1" },
						attributes = {},
						value = profile(5),
					},
				}
			end
			return { status = 500, json = { message = "internal" } }
		end)
		local lines: { string } = {}
		local summary = Backup.run(target, function(line)
			table.insert(lines, line)
		end)
		expect(summary.listed).toBe(2)
		expect(summary.saved).toBe(1)
		expect(summary.ok).toBe(false)
		expect(summary.failed[1].id).toBe("Player_2")
		expect(summary.failed[1].error).toContain("HTTP 500")
		expect(#lines).toBe(1)
		expect(string.sub(lines[1], -1)).toBe("\n")
		expect(summary.bytes).toBe(#lines[1])

		local entries, bad = Backup.parse(table.concat(lines) .. "not json\n")
		expect(bad).toEqual({ 2 })
		local entry = entries.Player_1
		expect(entry.revisionId).toBe("r1")
		expect(entry.scope).toBe("global")
		expect(entry.users).toEqual({ "users/1" })
		expect(entry.value.data.coins).toBe(5)
	end)

	T.it("run stops before writing anything when the key list can't be read", function()
		local target = fakeTarget(function()
			return { status = 401, json = { message = "Invalid API key" } }
		end)
		local writes = 0
		local summary = Backup.run(target, function()
			writes += 1
		end)
		expect(writes).toBe(0)
		expect(summary.ok).toBe(false)
		expect(summary.listError).toContain("Invalid API key")
	end)

	T.it("restore writes the backup over an offline player, clearing its lock and keeping the etag", function()
		local now = 1_700_000_000
		local current = profile(1, {
			session = { sessionId = "s", heartbeatAt = now - 5000 },
			receipts = { { purchaseId = "old" }, { purchaseId = "after-backup" } },
		})
		local target, sent = fakeTarget(function(request)
			if request.method == "GET" then
				return { status = 200, json = { id = "Player_1", etag = "e9", value = current } }
			end
			return { status = 200, json = { id = "Player_1" } }
		end)
		local entry: Backup.Entry = {
			id = "Player_1",
			scope = "global",
			revisionId = "r1",
			users = { "users/1" },
			attributes = {},
			value = profile(50, { session = { sessionId = "old-session", heartbeatAt = now - 90000 } }),
		}
		local ok, message, lost = Backup.restoreEntry(target, entry, { now = now })
		expect(ok).toBe(true)
		expect(message).toContain("revision r1")
		expect(lost).toEqual({ "after-backup" })
		local write = sent[2]
		expect(write.method).toBe("PATCH")
		expect(write.url).toBe(ENTRIES .. "/Player_1")
		expect((write.query :: any).allowMissing).toBe("true")
		local body = serde.decode("json", write.body :: string)
		expect(body.etag).toBe("e9")
		expect(body.users).toEqual({ "users/1" })
		expect(body.value.data.coins).toBe(50)
		expect(body.value.meta.session).toBeNil()
		-- The caller's entry is untouched.
		expect(entry.value.meta.session.sessionId).toBe("old-session")
	end)

	T.it("restore refuses while the player is online, unless forced", function()
		local now = 1_700_000_000
		local target, sent = fakeTarget(function(request)
			if request.method == "GET" then
				return {
					status = 200,
					json = { value = profile(1, { session = { sessionId = "s", heartbeatAt = now - 30 } }) },
				}
			end
			return { status = 200, json = {} }
		end)
		local entry: Backup.Entry =
			{ id = "Player_1", scope = "global", users = {}, attributes = {}, value = profile(50) }
		local ok, message = Backup.restoreEntry(target, entry, { now = now })
		expect(ok).toBe(false)
		expect(message).toContain("online")
		expect(#sent).toBe(1)
		local forced = Backup.restoreEntry(target, entry, { now = now, force = true })
		expect(forced).toBe(true)
	end)

	T.it("restore recreates a deleted entry", function()
		local target, sent = fakeTarget(function(request)
			if request.method == "GET" then
				return { status = 404, json = { message = "not found" } }
			end
			return { status = 200, json = {} }
		end)
		local entry: Backup.Entry =
			{ id = "Player_1", scope = "global", users = {}, attributes = {}, value = profile(7) }
		local ok, _, lost = Backup.restoreEntry(target, entry, { now = 0 })
		expect(ok).toBe(true)
		expect(lost).toEqual({})
		local body = serde.decode("json", sent[2].body :: string)
		expect(body.etag).toBeNil()
		expect(body.value.data.coins).toBe(7)
	end)
end)
