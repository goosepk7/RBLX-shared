--!strict
--[[
	Uploads pending assets from assets/manifest.json through Roblox Open Cloud, writes the new
	ids back to the manifest, and regenerates AssetIds.luau.

	  lune run tools/upload_assets --all              pending + changed-since-upload entries
	  lune run tools/upload_assets --name icon_wins   one entry (repeat --name for more)
	  lune run tools/upload_assets --all --dry-run    show the plan, upload nothing

	Environment (never commit these):
	  ROBLOX_API_KEY            Open Cloud key with asset:read + asset:write
	  ROBLOX_CREATOR_USER_ID    upload as this user, or
	  ROBLOX_CREATOR_GROUP_ID   upload as this group (takes precedence)

	Without ROBLOX_API_KEY the tool always does a dry run. The manifest is saved after every
	successful upload, so an interrupted run loses nothing; rerun to continue.

	Animations cannot be uploaded through the Assets API: the tool lists them with the manual
	steps instead of failing.

	Images upload as Decals. The Decal id is kept as `decalId` and the Image id it wraps is
	resolved (tools/lib/decal.luau) before the entry becomes "uploaded"; assetId is always the
	Image id. If resolution fails the entry is saved as "unresolved" (renders as pending) and
	tools/resolve_decals finishes it without re-uploading. Not yet verified against live Roblox:
	spot-check one icon in Studio after the first real run.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local Args = require("./lib/args")
local Decal = require("./lib/decal")
local Manifest = require("./lib/manifest")
local OpenCloud = require("./lib/opencloud")
local Paths = require("./lib/paths")

local ASSET_TYPES: { [string]: string } = {
	image = "Decal",
	audio = "Audio",
	mesh = "Model",
	video = "Video",
}

local CONTENT_TYPES: { [string]: string } = {
	png = "image/png",
	jpg = "image/jpeg",
	jpeg = "image/jpeg",
	bmp = "image/bmp",
	tga = "image/tga",
	ogg = "audio/ogg",
	mp3 = "audio/mpeg",
	wav = "audio/wav",
	flac = "audio/flac",
	fbx = "model/fbx",
	gltf = "model/gltf+json",
	glb = "model/gltf-binary",
	mp4 = "video/mp4",
	mov = "video/mov",
}

local POLL_INTERVAL = tonumber(process.env.UPLOAD_POLL_INTERVAL) or 1
local POLL_TIMEOUT = 120

local args = Args.parse(process.args, { "manifest", "out", "name" })
local paths = Paths.resolve(args:string("manifest"), args:string("out"))
local manifest = Manifest.load(paths.manifest)

local selected: { [string]: boolean } = {}
local wantAll = args:has("all")
for i, arg in process.args do
	if arg == "--name" and process.args[i + 1] then
		selected[process.args[i + 1]] = true
	end
end
if not wantAll and next(selected) == nil then
	print("usage: lune run tools/upload_assets --all | --name <asset> [--name <asset>...] [--dry-run]")
	process.exit(2)
end

local apiKey = process.env.ROBLOX_API_KEY
local groupId = process.env.ROBLOX_CREATOR_GROUP_ID
local userId = process.env.ROBLOX_CREATOR_USER_ID
local dryRun = args:has("dry-run") or apiKey == nil or apiKey == ""

-- Structural problems must be fixed before uploading anything.
local blocking = {}
for _, problem in Manifest.validate(manifest, false) do
	if problem.level == "error" then
		table.insert(blocking, problem)
	end
end
if #blocking > 0 then
	for _, problem in blocking do
		print(string.format("FAIL  %s: %s", problem.name, problem.message))
	end
	print("Fix the manifest first (lune run tools/verify_assets shows everything).")
	process.exit(1)
end

type Planned = { entry: Manifest.Entry, reason: string }

local plan: { Planned } = {}
local manual: { Manifest.Entry } = {}
for _, entry in manifest.assets do
	local chosen = selected[entry.name] or wantAll
	if chosen and entry.source ~= "creator-store" then
		local hash = if entry.path then Manifest.hashFile(entry.path) else nil
		local reason: string? = nil
		if entry.status == "pending" then
			reason = "pending"
		elseif hash ~= entry.sha256 then
			reason = "file changed since upload"
		elseif selected[entry.name] then
			reason = "requested by name"
		end
		if reason then
			if entry.kind == "animation" then
				table.insert(manual, entry)
			else
				table.insert(plan, { entry = entry, reason = reason })
			end
		end
	end
end
for name in selected do
	if not Manifest.find(manifest, name) then
		print(string.format("FAIL  %s: not in %s", name, paths.manifest))
		process.exit(1)
	end
end

print(string.format("%d asset(s) to upload%s", #plan, if dryRun then " (dry run)" else ""))
for _, item in plan do
	print(string.format("  %-32s %-6s %s (%s)", item.entry.name, item.entry.kind, item.entry.path or "?", item.reason))
end
for _, entry in manifest.assets do
	if entry.status == "unresolved" then
		print(
			string.format("note: %s is unresolved (decal %d); run tools/resolve_decals", entry.name, entry.decalId or 0)
		)
	end
end
if #manual > 0 then
	print(string.format("%d animation(s) need manual upload:", #manual))
	for _, entry in manual do
		print(string.format("  %s (%s)", entry.name, entry.path or "?"))
	end
	print("  In Studio: import the .rbxm, open it in the Animation Editor, Publish to Roblox, then put")
	print('  the id in the manifest entry ("status": "uploaded", "assetId": <id>) and run gen_asset_ids.')
end

if dryRun then
	if apiKey == nil or apiKey == "" then
		print("ROBLOX_API_KEY is not set, so nothing was uploaded.")
	end
	process.exit(0)
end

if groupId == nil and userId == nil then
	print("FAIL  set ROBLOX_CREATOR_GROUP_ID or ROBLOX_CREATOR_USER_ID")
	process.exit(1)
end

local creator = if groupId then { groupId = groupId } else { userId = userId }
local client = OpenCloud.new({ apiKey = apiKey :: string, log = print })

local function extension(path: string): string
	return string.lower(string.match(path, "%.([%w]+)$") or "")
end

local function upload(entry: Manifest.Entry): (number?, string?)
	local path = entry.path :: string
	local assetType = ASSET_TYPES[entry.kind]
	local contentType = CONTENT_TYPES[extension(path)]
	if not assetType then
		return nil, "kind " .. entry.kind .. " is not uploadable through Open Cloud"
	end
	if not contentType then
		return nil, "unsupported file type ." .. extension(path)
	end
	local displayName = string.sub(entry.displayName or entry.name, 1, 50)
	local requestJson = serde.encode("json", {
		assetType = assetType,
		displayName = displayName,
		description = string.sub("Asset " .. entry.name, 1, 1000),
		creationContext = { creator = creator },
	}, false)
	local res = client:multipart(OpenCloud.BASE .. "/assets/v1/assets", {
		{ name = "request", contentType = "application/json", content = requestJson },
		{
			name = "fileContent",
			filename = string.match(path, "([^/\\]+)$") or path,
			contentType = contentType,
			content = fs.readFile(path),
		},
	})
	if not res.ok or type(res.json) ~= "table" then
		return nil, string.format("create failed (HTTP %d): %s", res.status, string.sub(res.body, 1, 300))
	end
	local operation = res.json
	local waited = 0
	while not operation.done do
		if waited >= POLL_TIMEOUT then
			return nil, "timed out waiting for operation " .. tostring(operation.path)
		end
		task.wait(POLL_INTERVAL)
		waited += POLL_INTERVAL
		local poll = client:request("GET", OpenCloud.BASE .. "/assets/v1/" .. tostring(operation.path))
		if not poll.ok or type(poll.json) ~= "table" then
			return nil, string.format("operation poll failed (HTTP %d): %s", poll.status, string.sub(poll.body, 1, 300))
		end
		operation = poll.json
	end
	if operation.error then
		return nil, "upload rejected: " .. serde.encode("json", operation.error, false)
	end
	local assetId = operation.response and tonumber(operation.response.assetId)
	if not assetId then
		return nil, "operation finished without an assetId: " .. serde.encode("json", operation, false)
	end
	return assetId, nil
end

local failures, unresolved = 0, 0
for index, item in plan do
	local entry = item.entry
	stdio.write(string.format("[%d/%d] %s ... ", index, #plan, entry.name))
	local createdId, err = upload(entry)
	if createdId then
		entry.sha256 = Manifest.hashFile(entry.path :: string)
		if entry.kind == "image" then
			entry.decalId = createdId
			local imageId, resolveErr = Decal.resolve(client, createdId)
			if imageId then
				entry.status = "uploaded"
				entry.assetId = imageId
				print(string.format("ok (image %d, decal %d)", imageId, createdId))
			else
				entry.status = "unresolved"
				entry.assetId = nil
				unresolved += 1
				print(string.format("UNRESOLVED (decal %d)\n      %s", createdId, tostring(resolveErr)))
			end
		else
			entry.status = "uploaded"
			entry.assetId = createdId
			print(string.format("ok (%d)", createdId))
		end
		Manifest.save(paths.manifest, manifest)
	else
		failures += 1
		print("FAILED\n      " .. tostring(err))
	end
end

fs.writeFile(paths.idsModule, Manifest.renderIds(manifest, paths.manifest))
print(string.format("wrote %s", paths.idsModule))
local done = #plan - failures - unresolved
local verdict = if failures > 0 or unresolved > 0 then "FAIL" else "PASS"
print(string.format("%s  %d uploaded, %d unresolved, %d failed", verdict, done, unresolved, failures))
if unresolved > 0 then
	print("Unresolved images were uploaded as Decals; finish them with: lune run tools/resolve_decals")
end
if failures > 0 or unresolved > 0 then
	process.exit(1)
end
