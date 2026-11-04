--!strict
--[[
	Profile backups through the Open Cloud data stores API (v2), for tools/backup_profiles.

	  local client = OpenCloud.new({ apiKey = process.env.ROBLOX_API_KEY })
	  local target = { client = client, universeId = "123", dataStore = "Stilts_Profiles" }
	  local summary = Backup.run(target, function(line) file:write(line) end)

	Every entry is read with its value and written as one NDJSON line:
	  {"id":"Player_1","scope":"global","revisionId":"...","users":["users/1"],"attributes":{},"value":{...}}

	The API key needs universe-datastores.objects:list and universe-datastores.objects:read on the
	experience (and universe-datastores.objects:update for restores).

	Not yet verified against live Roblox: check the first real run's summary.json, where `saved`
	should match the number of players who have ever played.
]]

local serde = require("@lune/serde")

local OpenCloud = require("./opencloud")

export type Target = {
	client: OpenCloud.Client,
	universeId: string,
	dataStore: string,
	-- Default "global".
	scope: string?,
	-- Only keys that start with this. Default "" (every key).
	prefix: string?,
	-- Keys per list request, at most 256. Default 100.
	pageSize: number?,
	-- Default OpenCloud.BASE.
	base: string?,
	log: ((line: string) -> ())?,
}

export type Entry = {
	id: string,
	scope: string,
	revisionId: string?,
	revisionCreateTime: string?,
	createTime: string?,
	etag: string?,
	users: { any },
	attributes: { [string]: any },
	value: any,
}

export type Failure = { id: string, error: string }

export type Summary = {
	universeId: string,
	dataStore: string,
	scope: string,
	startedAt: string,
	finishedAt: string,
	listed: number,
	saved: number,
	bytes: number,
	failed: { Failure },
	-- Set when the key list itself couldn't be read; nothing was backed up.
	listError: string?,
	ok: boolean,
}

export type RestoreOptions = {
	-- Unix seconds, for judging whether a session lock is live.
	now: number,
	-- A lock with a heartbeat newer than this many seconds means the player is online. Default 600.
	lockTimeout: number?,
	-- Restore even over a live session lock. Default false.
	force: boolean?,
}

local Backup = {}

-- Percent-encodes everything except RFC 3986 unreserved characters.
function Backup.encode(text: string): string
	return (
		string.gsub(text, "[^%w%-%._~]", function(char: string): string
			return string.format("%%%02X", string.byte(char))
		end)
	)
end

function Backup.entriesUrl(target: Target): string
	local base = target.base or OpenCloud.BASE
	local scope = target.scope or "global"
	local url = base
		.. "/cloud/v2/universes/"
		.. Backup.encode(target.universeId)
		.. "/data-stores/"
		.. Backup.encode(target.dataStore)
	if scope ~= "global" then
		url ..= "/scopes/" .. Backup.encode(scope)
	end
	return url .. "/entries"
end

local function describe(response: OpenCloud.Response): string
	local detail = response.body
	if type(response.json) == "table" and type(response.json.message) == "string" then
		detail = response.json.message
	end
	if #detail > 200 then
		detail = string.sub(detail, 1, 200) .. "..."
	end
	local status = if response.status == 0 then "network error" else "HTTP " .. tostring(response.status)
	return status .. ": " .. detail
end

local function lastSegment(path: any): string?
	if type(path) ~= "string" then
		return nil
	end
	return string.match(path, "([^/]+)$")
end

local function keyNames(body: { [any]: any }): string
	local names: { string } = {}
	for key in body do
		table.insert(names, tostring(key))
	end
	table.sort(names)
	return table.concat(names, ", ")
end

-- (true, ids) or (false, reason). Follows nextPageToken to the end.
function Backup.listKeys(target: Target): (boolean, any)
	local url = Backup.entriesUrl(target)
	local prefix = target.prefix or ""
	local pageSize = math.clamp(target.pageSize or 100, 1, 256)
	local ids: { string } = {}
	local token: string? = nil
	local pages = 0
	repeat
		local query: { [string]: string } = { maxPageSize = tostring(pageSize) }
		if token then
			query.pageToken = token
		end
		local response = target.client:request("GET", url, { query = query })
		if not response.ok then
			return false, "listing keys failed: " .. describe(response)
		end
		local body = response.json
		if type(body) ~= "table" then
			return false, "listing keys failed: the response is not a JSON object"
		end
		local entries = body.dataStoreEntries
		if entries == nil and next(body) ~= nil and body.nextPageToken == nil then
			-- Fail loudly rather than back up nothing if the API's shape ever changes.
			return false, "listing keys failed: unexpected response fields (" .. keyNames(body) .. ")"
		end
		local list: { any } = if type(entries) == "table" then entries else {}
		for _, entry in list do
			local id = if type(entry) == "table" then (entry.id or lastSegment(entry.path)) else nil
			if type(id) == "string" and string.sub(id, 1, #prefix) == prefix then
				table.insert(ids, id)
			end
		end
		pages += 1
		local nextToken = body.nextPageToken
		token = if type(nextToken) == "string" and nextToken ~= "" then nextToken else nil
	until token == nil
	if target.log then
		target.log(string.format("listed %d key(s) in %d page(s)", #ids, pages))
	end
	return true, ids
end

-- (true, entry) or (false, reason).
function Backup.getEntry(target: Target, id: string): (boolean, any)
	local response = target.client:request("GET", Backup.entriesUrl(target) .. "/" .. Backup.encode(id))
	if not response.ok then
		return false, describe(response)
	end
	local body = response.json
	if type(body) ~= "table" then
		return false, "the entry response is not a JSON object"
	end
	local entry: Entry = {
		id = if type(body.id) == "string" then body.id else id,
		scope = target.scope or "global",
		revisionId = body.revisionId,
		revisionCreateTime = body.revisionCreateTime,
		createTime = body.createTime,
		etag = body.etag,
		users = if type(body.users) == "table" then body.users else {},
		attributes = if type(body.attributes) == "table" then body.attributes else {},
		value = body.value,
	}
	return true, entry
end

local function timestamp(): string
	return os.date("!%Y-%m-%dT%H:%M:%SZ") :: string
end

-- Backs up every key: `write` receives one NDJSON line (with its newline) per entry.
function Backup.run(target: Target, write: (line: string) -> ()): Summary
	local summary: Summary = {
		universeId = target.universeId,
		dataStore = target.dataStore,
		scope = target.scope or "global",
		startedAt = timestamp(),
		finishedAt = "",
		listed = 0,
		saved = 0,
		bytes = 0,
		failed = {},
		listError = nil,
		ok = false,
	}
	local listed, result = Backup.listKeys(target)
	if not listed then
		summary.listError = result
		summary.finishedAt = timestamp()
		return summary
	end
	local ids: { string } = result
	summary.listed = #ids
	for index, id in ids do
		local ok, entry = Backup.getEntry(target, id)
		if ok then
			local line = serde.encode("json", entry, false) .. "\n"
			write(line)
			summary.saved += 1
			summary.bytes += #line
		else
			table.insert(summary.failed, { id = id, error = entry })
			if target.log then
				target.log("  FAIL " .. id .. ": " .. entry)
			end
		end
		if target.log and index % 500 == 0 then
			target.log(string.format("  %d/%d", index, #ids))
		end
	end
	summary.finishedAt = timestamp()
	summary.ok = #summary.failed == 0
	return summary
end

-- Reads an entries.ndjson file's text. Returns entries by id, and the numbers of unreadable lines.
function Backup.parse(text: string): ({ [string]: Entry }, { number })
	local entries: { [string]: Entry } = {}
	local bad: { number } = {}
	local lineNumber = 0
	for line in string.gmatch(text, "[^\n]+") do
		lineNumber += 1
		local ok, entry = pcall(serde.decode, "json" :: any, line)
		if ok and type(entry) == "table" and type(entry.id) == "string" then
			entries[entry.id] = entry
		else
			table.insert(bad, lineNumber)
		end
	end
	return entries, bad
end

local function purchaseIds(value: any): { [string]: boolean }
	local ids: { [string]: boolean } = {}
	local meta = if type(value) == "table" then value.meta else nil
	local receipts = if type(meta) == "table" then meta.receipts else nil
	if type(receipts) == "table" then
		for _, receipt in receipts do
			if type(receipt) == "table" and type(receipt.purchaseId) == "string" then
				ids[receipt.purchaseId] = true
			end
		end
	end
	return ids
end

--[[
	Writes a backed-up entry back. Refuses while a server holds a live session lock on the
	current value (the player is online) unless `force`, and clears the backup's own lock so the
	next server loads it at once. Returns (ok, message, purchaseIds) where purchaseIds lists
	purchases in the current value that the backup doesn't have: grant those again by hand.
]]
function Backup.restoreEntry(target: Target, entry: Entry, options: RestoreOptions): (boolean, string, { string })
	local url = Backup.entriesUrl(target) .. "/" .. Backup.encode(entry.id)
	local lost: { string } = {}
	local current = target.client:request("GET", url)
	if not current.ok and current.status ~= 404 then
		return false, "reading the current value failed: " .. describe(current), lost
	end
	local currentBody: any = if current.ok then current.json else nil
	local currentValue = if type(currentBody) == "table" then currentBody.value else nil
	if type(currentValue) == "table" and type(currentValue.meta) == "table" then
		local session = currentValue.meta.session
		local heartbeat = if type(session) == "table" then session.heartbeatAt else nil
		local live = type(heartbeat) == "number" and options.now - heartbeat < (options.lockTimeout or 600)
		if live and not options.force then
			return false,
				"the player is online (a server holds the session lock); try again after they leave, or pass --force",
				lost
		end
		local kept = purchaseIds(entry.value)
		for purchaseId in purchaseIds(currentValue) do
			if not kept[purchaseId] then
				table.insert(lost, purchaseId)
			end
		end
		table.sort(lost)
	end

	local value: any = serde.decode("json", serde.encode("json", entry.value, false))
	if type(value) == "table" and type(value.meta) == "table" then
		value.meta.session = nil
		value.meta.forceRelease = nil
	end
	local body: { [string]: any } = { value = value, users = entry.users, attributes = entry.attributes }
	if type(currentBody) == "table" and type(currentBody.etag) == "string" then
		-- Fails instead of overwriting if the entry changes between our read and this write.
		body.etag = currentBody.etag
	end
	local written = target.client:request("PATCH", url, { query = { allowMissing = "true" }, json = body })
	if not written.ok then
		return false, "writing failed: " .. describe(written), lost
	end
	return true, "restored " .. entry.id .. " from revision " .. tostring(entry.revisionId), lost
end

return Backup
