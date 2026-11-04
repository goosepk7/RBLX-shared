--!strict
--[[
	Daily player-profile backups through Roblox Open Cloud (brief §3.2).

	  lune run tools/backup_profiles --universe 1234567 --datastore Stilts_Profiles
	  lune run tools/backup_profiles ... --scope global --prefix Player_ --out backups
	  lune run tools/backup_profiles ... --restore backups/Stilts_Profiles/2026-11-04 --key Player_42

	A backup writes <out>/<datastore>/<UTC date>/entries.ndjson (one entry per line, with its
	value, users and attributes) and summary.json, and exits 1 if any entry couldn't be read.
	A restore writes one key back from a backup folder (or its entries.ndjson). It refuses while
	the player is online unless --force, and lists purchases made after the backup, which the
	restored save won't have.

	Environment (never commit these):
	  ROBLOX_API_KEY       Open Cloud key with universe-datastores.objects:list and :read
	                       (and :update to restore) on the experience
	  ROBLOX_UNIVERSE_ID   default for --universe

	The scheduled GitHub Actions job that runs this every day is in docs/TOOLING.md.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Args = require("./lib/args")
local Backup = require("./lib/backup")
local OpenCloud = require("./lib/opencloud")

local USAGE = [[
usage:
  lune run tools/backup_profiles --universe <id> --datastore <name> [--scope global] [--prefix Player_] [--out backups]
  lune run tools/backup_profiles --universe <id> --datastore <name> --restore <backup folder or entries.ndjson> --key <key> [--force]
environment: ROBLOX_API_KEY (required), ROBLOX_UNIVERSE_ID (default for --universe)]]

local args =
	Args.parse(process.args, { "universe", "datastore", "scope", "prefix", "out", "restore", "key", "page-size" })

local function fail(message: string, code: number?): never
	print(message)
	return process.exit(code or 1)
end

local function say(line: string)
	print(line)
end

local universeArg = args:string("universe", process.env.ROBLOX_UNIVERSE_ID)
local dataStoreArg = args:string("datastore")
if universeArg == nil or dataStoreArg == nil or args:has("help") then
	fail(USAGE, 2)
end
local universeId = universeArg :: string
local dataStore = dataStoreArg :: string
local apiKey = process.env.ROBLOX_API_KEY
if apiKey == nil or apiKey == "" then
	fail("ROBLOX_API_KEY is not set: create an Open Cloud key (see docs/TOOLING.md) and export it first.", 2)
end
local scope = args:string("scope", "global") :: string

local target: Backup.Target = {
	client = OpenCloud.new({ apiKey = apiKey :: string, log = say }),
	universeId = universeId,
	dataStore = dataStore,
	scope = scope,
	prefix = args:string("prefix", ""),
	pageSize = args:number("page-size", 100),
	log = say,
}

local restorePath = args:string("restore")
if restorePath then
	local keyArg = args:string("key")
	if keyArg == nil then
		fail("--restore needs --key <key>: restores are one player at a time.\n" .. USAGE, 2)
	end
	local key = keyArg :: string
	local file = if fs.isDir(restorePath) then restorePath .. "/entries.ndjson" else restorePath
	if not fs.isFile(file) then
		fail("no backup at " .. file, 2)
	end
	local entries, bad = Backup.parse(fs.readFile(file))
	if #bad > 0 then
		print(string.format("warning: %d unreadable line(s) in %s (first: line %d)", #bad, file, bad[1]))
	end
	local found = entries[key]
	if found == nil then
		fail(key .. " is not in " .. file, 1)
	end
	local entry = found :: Backup.Entry
	local ok, message, lost = Backup.restoreEntry(target, entry, { now = os.time(), force = args:has("force") })
	print((if ok then "OK  " else "FAIL  ") .. message)
	if #lost > 0 then
		print("purchases made after the backup, not in the restored save (grant these again by hand):")
		for _, purchaseId in lost do
			print("  " .. purchaseId)
		end
	end
	process.exit(if ok then 0 else 1)
end

local outRoot = args:string("out", "backups") :: string
local folder = string.format("%s/%s/%s", outRoot, dataStore, os.date("!%Y-%m-%d"))
fs.writeDir(folder)
local lines: { string } = {}

print(string.format("backing up %s (%s) in universe %s to %s", dataStore, scope, universeId, folder))
local summary = Backup.run(target, function(line: string)
	table.insert(lines, line)
end)
-- One write at the end: entries are a few KB each, so even 100k players fit comfortably in memory.
fs.writeFile(folder .. "/entries.ndjson", table.concat(lines))
fs.writeFile(folder .. "/summary.json", serde.encode("json", summary, true))

if summary.listError then
	fail("FAIL  " .. summary.listError)
end
local line = string.format("%d of %d entries, %d bytes", summary.saved, summary.listed, summary.bytes)
if not summary.ok then
	fail(string.format("FAIL  %s; %d failed (see %s/summary.json)", line, #summary.failed, folder))
end
print("OK  " .. line)
