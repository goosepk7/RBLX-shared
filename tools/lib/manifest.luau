--!strict
--[[
	assets/manifest.json: load, validate, hash, save, and render AssetIds.luau.

	Entry fields:
	  name        unique snake_case id used in code: Assets.get(name)
	  kind        image | audio | animation | mesh | video
	  path        repo-relative file to upload (PNG/OGG/FBX/...); optional for creator-store
	  sourceFile  optional editable source (SVG, synth script) the file is built from
	  source      generated | creator-store | manual (default generated)
	  status      pending | uploaded
	  assetId     number once uploaded, else null
	  sha256      hash of `path` as uploaded (uploaded) or as it should be (pending)
	  displayName optional name shown on Roblox (default: name)
	  meta        optional free-form table (bpm, key, loop, notes)
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")

export type Entry = {
	name: string,
	kind: string,
	path: string?,
	sourceFile: string?,
	source: string?,
	status: string,
	assetId: number?,
	sha256: string?,
	displayName: string?,
	meta: { [string]: any }?,
}

export type Manifest = { version: number, assets: { Entry } }

export type Problem = { name: string, level: "error" | "warning", message: string }

local Manifest = {}

Manifest.KINDS = { image = true, audio = true, animation = true, mesh = true, video = true }
Manifest.SOURCES = { generated = true, ["creator-store"] = true, manual = true }

local FIELD_ORDER =
	{ "name", "kind", "path", "sourceFile", "source", "status", "assetId", "sha256", "displayName", "meta" }

function Manifest.load(path: string): Manifest
	if not fs.isFile(path) then
		error(string.format("manifest not found: %s", path))
	end
	local decoded = serde.decode("json", fs.readFile(path))
	assert(type(decoded) == "table", "manifest must be a JSON object")
	assert(decoded.version == 1, "unsupported manifest version " .. tostring(decoded.version))
	local assets = decoded.assets or {}
	for _, entry in assets do
		if entry.assetId == nil or entry.assetId == serde.decode("json", "null") then
			entry.assetId = nil
		end
	end
	return { version = 1, assets = assets }
end

function Manifest.hashFile(path: string): string?
	if not fs.isFile(path) then
		return nil
	end
	return serde.hash("sha256", fs.readFile(path))
end

-- Validates structure and files. `checkHashes` compares sha256 to the file on disk.
function Manifest.validate(manifest: Manifest, checkHashes: boolean): { Problem }
	local problems: { Problem } = {}
	local function add(name: string, level: "error" | "warning", message: string)
		table.insert(problems, { name = name, level = level, message = message })
	end
	local seen: { [string]: boolean } = {}
	for index, entry in manifest.assets do
		local name = if type(entry.name) == "string" then entry.name else ("#" .. index)
		if type(entry.name) ~= "string" or not string.match(entry.name, "^[a-z][a-z0-9_]*$") then
			add(name, "error", "name must be snake_case ([a-z][a-z0-9_]*)")
		end
		if seen[name] then
			add(name, "error", "duplicate name")
		end
		seen[name] = true
		if not Manifest.KINDS[entry.kind] then
			add(name, "error", "unknown kind " .. tostring(entry.kind))
		end
		local source = entry.source or "generated"
		if not Manifest.SOURCES[source] then
			add(name, "error", "unknown source " .. tostring(source))
		end
		if entry.status ~= "pending" and entry.status ~= "uploaded" then
			add(name, "error", "status must be pending or uploaded")
		end
		if entry.status == "uploaded" then
			if type(entry.assetId) ~= "number" or entry.assetId <= 0 or entry.assetId ~= math.floor(entry.assetId) then
				add(name, "error", "uploaded entries need a positive integer assetId")
			end
		elseif entry.assetId ~= nil then
			add(name, "error", "pending entries must have assetId null")
		end
		if source == "creator-store" then
			if entry.status ~= "uploaded" then
				add(name, "error", "creator-store entries reference an existing id and must be uploaded")
			end
		else
			if type(entry.path) ~= "string" then
				add(name, "error", "path is required")
			elseif not fs.isFile(entry.path) then
				add(name, "error", "file not found: " .. entry.path)
			elseif checkHashes then
				local actual = Manifest.hashFile(entry.path)
				if entry.sha256 == nil or entry.sha256 == "" then
					add(name, "error", "sha256 missing (run: lune run tools/verify_assets --fix-hashes)")
				elseif actual ~= entry.sha256 then
					if entry.status == "uploaded" then
						add(name, "error", "file changed since upload (run: lune run tools/upload_assets --all)")
					else
						add(name, "error", "sha256 is stale (run: lune run tools/verify_assets --fix-hashes)")
					end
				end
			end
			if entry.sourceFile ~= nil and not fs.isFile(entry.sourceFile) then
				add(name, "error", "sourceFile not found: " .. entry.sourceFile)
			end
		end
	end
	return problems
end

-- Stable, diff-friendly JSON: fixed field order, sorted assets, two-space indent.
function Manifest.encode(manifest: Manifest): string
	local entries = table.clone(manifest.assets)
	table.sort(entries, function(a, b)
		return a.name < b.name
	end)
	local lines = { "{", '  "assets": [' }
	for i, entry in entries do
		local fields = {}
		for _, key in FIELD_ORDER do
			local value = (entry :: any)[key]
			if value ~= nil or key == "assetId" then
				local encoded = if value == nil then "null" else serde.encode("json", value, false)
				table.insert(fields, string.format('      "%s": %s', key, encoded))
			end
		end
		table.insert(lines, "    {")
		table.insert(lines, table.concat(fields, ",\n"))
		table.insert(lines, if i < #entries then "    }," else "    }")
	end
	table.insert(lines, "  ],")
	table.insert(lines, string.format('  "version": %d', manifest.version))
	table.insert(lines, "}")
	return table.concat(lines, "\n") .. "\n"
end

function Manifest.save(path: string, manifest: Manifest)
	fs.writeFile(path, Manifest.encode(manifest))
end

function Manifest.find(manifest: Manifest, name: string): Entry?
	for _, entry in manifest.assets do
		if entry.name == name then
			return entry
		end
	end
	return nil
end

-- The generated AssetIds.luau module consumed by Assets.register.
function Manifest.renderIds(manifest: Manifest, manifestPath: string): string
	local entries = table.clone(manifest.assets)
	table.sort(entries, function(a, b)
		return a.name < b.name
	end)
	local lines = {
		"--!strict",
		string.format("-- GENERATED by tools/gen_asset_ids.luau from %s. Do not edit by hand.", manifestPath),
		"-- Regenerate: lune run tools/gen_asset_ids",
		"",
		"export type Entry = { kind: string, status: string, assetId: number? }",
		"",
	}
	if #entries == 0 then
		table.insert(lines, "local ids: { [string]: Entry } = {}")
	else
		table.insert(lines, "local ids: { [string]: Entry } = {")
		for _, entry in entries do
			table.insert(
				lines,
				string.format(
					'\t%s = { kind = "%s", status = "%s", assetId = %s },',
					entry.name,
					entry.kind,
					entry.status,
					if entry.assetId then string.format("%d", entry.assetId) else "nil"
				)
			)
		end
		table.insert(lines, "}")
	end
	table.insert(lines, "")
	table.insert(lines, "return ids")
	return table.concat(lines, "\n") .. "\n"
end

return Manifest
