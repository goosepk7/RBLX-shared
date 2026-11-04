--!strict
--[[
	Verifies assets/manifest.json against the repo and (optionally) Roblox.

	  lune run tools/verify_assets                 structure, files, hashes, AssetIds sync
	  lune run tools/verify_assets --fix-hashes    fill/refresh sha256 for pending entries
	  lune run tools/verify_assets --remote        also confirm each uploaded id exists on
	                                               Roblox (needs ROBLOX_API_KEY)
	  lune run tools/verify_assets --release       also fail if anything is still pending
	                                               (the pre-launch gate)

	Exit 1 on any error. Options: --manifest <path>, --out <ids module path>.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local Args = require("./lib/args")
local Manifest = require("./lib/manifest")
local OpenCloud = require("./lib/opencloud")
local Paths = require("./lib/paths")

local args = Args.parse(process.args, { "manifest", "out" })
local paths = Paths.resolve(args:string("manifest"), args:string("out"))
local manifest = Manifest.load(paths.manifest)

if args:has("fix-hashes") then
	local fixed = 0
	for _, entry in manifest.assets do
		if entry.status == "pending" and entry.path and fs.isFile(entry.path) then
			local hash = Manifest.hashFile(entry.path)
			if hash ~= entry.sha256 then
				entry.sha256 = hash
				fixed += 1
			end
		end
	end
	Manifest.save(paths.manifest, manifest)
	print(string.format("updated %d hash(es) in %s", fixed, paths.manifest))
end

local problems = Manifest.validate(manifest, true)

local expectedIds = Manifest.renderIds(manifest, paths.manifest)
local currentIds = if fs.isFile(paths.idsModule) then fs.readFile(paths.idsModule) else ""
if currentIds ~= expectedIds then
	table.insert(problems, {
		name = paths.idsModule,
		level = "error",
		message = "out of date with the manifest (run: lune run tools/gen_asset_ids)",
	})
end

local pendingCount, uploadedCount = 0, 0
for _, entry in manifest.assets do
	if entry.status ~= "uploaded" then
		pendingCount += 1
		if args:has("release") then
			local message = if entry.status == "unresolved"
				then "uploaded as a Decal but the Image id is unresolved (run: lune run tools/resolve_decals)"
				else "still pending upload"
			table.insert(problems, { name = entry.name, level = "error", message = message })
		end
	else
		uploadedCount += 1
	end
end

if args:has("remote") then
	local apiKey = process.env.ROBLOX_API_KEY
	if apiKey == nil or apiKey == "" then
		table.insert(problems, { name = "--remote", level = "error", message = "ROBLOX_API_KEY is not set" })
	else
		local client = OpenCloud.new({ apiKey = apiKey, log = print })
		for _, entry in manifest.assets do
			if entry.status == "uploaded" and entry.source ~= "creator-store" and entry.assetId then
				local res =
					client:request("GET", string.format("%s/assets/v1/assets/%d", OpenCloud.BASE, entry.assetId))
				if not res.ok then
					table.insert(problems, {
						name = entry.name,
						level = "error",
						message = string.format("asset %d not readable on Roblox (HTTP %d)", entry.assetId, res.status),
					})
				elseif res.json and entry.kind == "image" and res.json.assetType and res.json.assetType ~= "Image" then
					table.insert(problems, {
						name = entry.name,
						level = "warning",
						message = string.format(
							"asset %d has type %s; ImageLabels need the Image id",
							entry.assetId,
							tostring(res.json.assetType)
						),
					})
				end
			end
		end
	end
end

local errors = 0
for _, problem in problems do
	if problem.level == "error" then
		errors += 1
	end
	print(
		string.format("%s  %s: %s", if problem.level == "error" then "FAIL" else "WARN", problem.name, problem.message)
	)
end
print(
	string.format(
		"%s  %d assets (%d uploaded, %d pending), %d error(s)",
		if errors == 0 then "PASS" else "FAIL",
		#manifest.assets,
		uploadedCount,
		pendingCount,
		errors
	)
)
if errors > 0 then
	process.exit(1)
end
