--!strict
--[[
	End-to-end: runs tools/backup_profiles against a local mock of the Open Cloud data stores
	API, then restores one key from the backup it wrote.
]]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local T = require("@shared/Test")
local expect = T.expect

local TMP = "build/test-tmp/backup"
local PREFIX = "/cloud/v2/universes/777/data-stores/Stilts_Profiles/entries"

local function profile(coins: number, heartbeatAt: number?): any
	return {
		data = { coins = coins },
		meta = {
			schemaVersion = 1,
			loadCount = 2,
			receipts = {},
			session = if heartbeatAt then { sessionId = "s", heartbeatAt = heartbeatAt } else nil,
		},
	}
end

local function run(port: number, extra: { string }, env: { [string]: string }?): process.ExecResult
	local args =
		{ "run", process.cwd .. "/tools/backup_profiles", "--universe", "777", "--datastore", "Stilts_Profiles" }
	for _, arg in extra do
		table.insert(args, arg)
	end
	local environment: { [string]: string } = {
		ROBLOX_API_KEY = "test-key",
		ROBLOX_OPEN_CLOUD_BASE = string.format("http://127.0.0.1:%d", port),
	}
	local overrides: { [string]: string } = env or {}
	for key, value in overrides do
		environment[key] = value
	end
	return process.exec("lune", args, { cwd = TMP, env = environment })
end

T.describe("tools/backup_profiles (mock Open Cloud)", function()
	T.it("backs up every page of keys, retrying a 429, then restores one key", function()
		if fs.isDir(TMP) then
			fs.removeDir(TMP)
		end
		fs.writeDir(TMP)

		local stored: { [string]: any } = {
			Player_1 = profile(10),
			Player_2 = profile(20),
			Player_3 = profile(30),
		}
		local requests: { { method: string, path: string, key: string? } } = {}
		local throttled = false
		local written: any = nil
		local port = 48000 + (os.time() % 1000)
		local server = net.serve(port, function(request)
			table.insert(requests, {
				method = request.method :: string,
				path = request.path,
				key = request.headers["x-api-key"] :: string?,
			})
			if request.method == "GET" and request.path == PREFIX then
				if request.query.pageToken == "page2" then
					return { status = 200, body = '{"dataStoreEntries":[{"id":"Player_3"}]}' }
				end
				return {
					status = 200,
					body = '{"dataStoreEntries":[{"id":"Player_1"},{"id":"Player_2"}],"nextPageToken":"page2"}',
				}
			end
			local id = if string.sub(request.path, 1, #PREFIX + 1) == PREFIX .. "/"
				then string.sub(request.path, #PREFIX + 2)
				else nil
			if id and request.method == "GET" then
				if id == "Player_2" and not throttled then
					throttled = true
					return { status = 429, headers = { ["Retry-After"] = "0" }, body = "" }
				end
				local value = stored[id]
				if value == nil then
					return { status = 404, body = '{"message":"not found"}' }
				end
				return {
					status = 200,
					body = serde.encode("json", {
						id = id,
						revisionId = "rev-" .. id,
						etag = "etag-" .. id,
						users = { "users/" .. string.sub(id, 8) },
						attributes = {},
						value = value,
					}),
				}
			elseif id and request.method == "PATCH" then
				written = serde.decode("json", request.body)
				return { status = 200, body = "{}" }
			end
			return { status = 404, body = "not found" }
		end)

		local backup = run(port, { "--out", "backups" })
		-- The player plays on after the backup.
		stored.Player_2 = profile(5)
		local restore =
			run(port, { "--restore", "backups/Stilts_Profiles/" .. os.date("!%Y-%m-%d"), "--key", "Player_2" })
		local missing = run(port, {}, { ROBLOX_API_KEY = "" })
		server:stop()

		if not backup.ok then
			print(backup.stdout, backup.stderr)
		end
		expect(backup.ok).toBe(true)
		expect(backup.stdout).toContain("OK  3 of 3 entries")
		local folder = TMP .. "/backups/Stilts_Profiles/" .. os.date("!%Y-%m-%d")
		local lines = string.split(fs.readFile(folder .. "/entries.ndjson"), "\n")
		expect(#lines).toBe(4) -- three entries and the trailing newline
		local first = serde.decode("json", lines[1])
		expect(first.id).toBe("Player_1")
		expect(first.value.data.coins).toBe(10)
		local summary = serde.decode("json", fs.readFile(folder .. "/summary.json"))
		expect(summary.saved).toBe(3)
		expect(summary.failed).toEqual({})
		expect(throttled).toBe(true)

		if not restore.ok then
			print(restore.stdout, restore.stderr)
		end
		expect(restore.ok).toBe(true)
		expect(restore.stdout).toContain("restored Player_2 from revision rev-Player_2")
		expect(written.value.data.coins).toBe(20)
		expect(written.etag).toBe("etag-Player_2")

		expect(missing.ok).toBe(false)
		expect(missing.stdout).toContain("ROBLOX_API_KEY is not set")
		for _, request in requests do
			expect(request.key).toBe("test-key")
		end
		-- The key never appears in the tool's output or the files it wrote.
		for _, text in { backup.stdout, backup.stderr, restore.stdout, fs.readFile(folder .. "/entries.ndjson") } do
			expect(text).never.toContain("test-key")
		end
	end)
end)
